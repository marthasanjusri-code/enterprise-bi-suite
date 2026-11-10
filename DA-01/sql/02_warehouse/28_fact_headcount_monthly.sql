/*
  28_fact_headcount_monthly.sql
  dw.fact_headcount_monthly: one row per employee per month-end, from the month of the
  employee's (shifted) hire date, within the snapshot window (D58).
    Source: stg.aw_employee, stg.aw_employee_department_history, stg.aw_employee_pay_history.
    HR dates are shifted by etl.setting hr_date_shift_days (+4,017, D21).

  Rules:
    - Snapshot window (D58): month-ends from the month of the first operational date to
      etl.setting hr_as_of_date (2025-10-31, D91). The first operational date is the earliest
      sales order, purchase order or work order start date in staging (2022-04-15, the first
      purchase order; date checks: check 1), so the first month-end is 2022-04-30.
    - An employee is counted at a month-end when the shifted hire date is on or before it.
      No employee leaves: the source has no termination dates (limitations.md).
    - Department and shift: the department history row covering the month-end, end date
      inclusive (D55; headcount checks: checks 1 and 2). Not found -> -1 (D59).
    - pay_rate, pay_frequency: the latest pay row whose shifted change date is on or before the
      month-end (D55, D56). Rate is per hour for everyone. NULL if none (unknown, D17).
    - age_at_month_end: exact age on the month-end from the shifted birth date, birthday counted,
      the same formula as dw.dim_employee_hr (D91). Birth date itself is not stored (D62).
    - tenure_months: calendar months from the hire month to the month-end month (0 in the month
      of hire). is_hired_this_month: 1 in the month of hire.
    - Keys come from the dimensions by business key; never NULL.
    - Full reload in one transaction (D76, D77); refuses an empty staging and opens its own
      transaction only when the caller has none (D106).
  Audit columns: batch_id, loaded_at (D10).
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.fact_headcount_monthly') IS NULL
CREATE TABLE dw.fact_headcount_monthly (
    employee_id           int           NOT NULL,
    month_end_date_key    int           NOT NULL CONSTRAINT fk_fact_headcount_month_end  REFERENCES dw.dim_date (date_key),
    employee_key          int           NOT NULL CONSTRAINT fk_fact_headcount_employee   REFERENCES dw.dim_employee (employee_key),
    department_key        int           NOT NULL CONSTRAINT fk_fact_headcount_department REFERENCES dw.dim_department (department_key),
    shift_key             int           NOT NULL CONSTRAINT fk_fact_headcount_shift      REFERENCES dw.dim_shift (shift_key),
    pay_rate              money         NULL,
    pay_frequency         tinyint       NULL,
    age_at_month_end      int           NULL,
    tenure_months         int           NOT NULL,
    is_hired_this_month   bit           NOT NULL,
    batch_id              int           NOT NULL,
    loaded_at             datetime2(0)  NOT NULL,
    CONSTRAINT pk_fact_headcount_monthly PRIMARY KEY (employee_id, month_end_date_key)
);
GO

CREATE OR ALTER PROCEDURE etl.load_fact_headcount_monthly
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_written int,
            @hr_shift int, @last_month_end date, @first_operational date, @first_month_end date,
            @loaded_at datetime2(0) = SYSDATETIME(),
            @own_tran bit = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.fact_headcount_monthly', @log_id OUTPUT;

        SET @rows_read = (SELECT COUNT(*) FROM stg.aw_employee);

        IF @rows_read = 0
           OR NOT EXISTS (SELECT 1 FROM stg.aw_employee_department_history)
           OR NOT EXISTS (SELECT 1 FROM stg.aw_employee_pay_history)
            THROW 50002, 'Staging employees, department history or pay history are empty; dw.fact_headcount_monthly was not changed.', 1;

        EXEC etl.get_setting_int  'hr_date_shift_days', @hr_shift OUTPUT;
        EXEC etl.get_setting_date 'hr_as_of_date', @last_month_end OUTPUT;

        SET @first_operational = (SELECT MIN(d) FROM (
                                      SELECT MIN(CAST(OrderDate AS date)) AS d FROM stg.aw_sales_order_header
                                      UNION ALL SELECT MIN(CAST(OrderDate AS date)) FROM stg.aw_purchase_order_header
                                      UNION ALL SELECT MIN(CAST(StartDate AS date)) FROM stg.aw_work_order) x);
        SET @first_month_end = EOMONTH(@first_operational);

        IF @first_month_end IS NULL OR @last_month_end <> EOMONTH(@last_month_end) OR @first_month_end > @last_month_end
            THROW 50001, 'Headcount window is not valid: check the operational dates in staging and etl.setting hr_as_of_date (must be a month-end).', 1;

        SELECT  m.full_date AS month_end, m.date_key
        INTO #months
        FROM dw.dim_date m
        WHERE m.is_month_end = 1
          AND m.full_date BETWEEN @first_month_end AND @last_month_end;

        SELECT  e.BusinessEntityID,
                DATEADD(day, @hr_shift, e.HireDate)  AS hire_date,
                DATEADD(day, @hr_shift, e.BirthDate) AS birth_date
        INTO #emp
        FROM stg.aw_employee e;

        SELECT  e.BusinessEntityID,
                m.month_end,
                m.date_key,
                e.hire_date,
                dh.DepartmentID,
                dh.ShiftID,
                pay.Rate,
                pay.PayFrequency,
                DATEDIFF(year, e.birth_date, m.month_end)
                  - CASE WHEN DATEADD(year, DATEDIFF(year, e.birth_date, m.month_end), e.birth_date) > m.month_end
                         THEN 1 ELSE 0 END                                   AS age_at_month_end
        INTO #src
        FROM #emp e
        JOIN #months m ON e.hire_date <= m.month_end
        OUTER APPLY (
            SELECT TOP (1) h.DepartmentID, h.ShiftID
            FROM stg.aw_employee_department_history h
            WHERE h.BusinessEntityID = e.BusinessEntityID
              AND DATEADD(day, @hr_shift, h.StartDate) <= m.month_end
              AND (h.EndDate IS NULL OR DATEADD(day, @hr_shift, h.EndDate) >= m.month_end)
            ORDER BY h.StartDate DESC
        ) dh
        OUTER APPLY (
            SELECT TOP (1) p.Rate, p.PayFrequency
            FROM stg.aw_employee_pay_history p
            WHERE p.BusinessEntityID = e.BusinessEntityID
              AND CAST(DATEADD(day, @hr_shift, p.RateChangeDate) AS date) <= m.month_end
            ORDER BY p.RateChangeDate DESC
        ) pay;

        IF @own_tran = 1 BEGIN TRANSACTION;

        TRUNCATE TABLE dw.fact_headcount_monthly;

        INSERT INTO dw.fact_headcount_monthly (
            employee_id, month_end_date_key, employee_key, department_key, shift_key,
            pay_rate, pay_frequency, age_at_month_end, tenure_months, is_hired_this_month,
            batch_id, loaded_at)
        SELECT
            s.BusinessEntityID,
            s.date_key,
            ISNULL(de.employee_key, -1),
            ISNULL(dd.department_key, -1),
            ISNULL(ds.shift_key, -1),
            s.Rate,
            s.PayFrequency,
            s.age_at_month_end,
            DATEDIFF(month, s.hire_date, s.month_end),
            CAST(CASE WHEN EOMONTH(s.hire_date) = s.month_end THEN 1 ELSE 0 END AS bit),
            @batch_id,
            @loaded_at
        FROM #src s
        LEFT JOIN dw.dim_employee de   ON de.employee_id = s.BusinessEntityID
        LEFT JOIN dw.dim_department dd ON dd.department_id = s.DepartmentID
        LEFT JOIN dw.dim_shift ds      ON ds.shift_id = s.ShiftID;
        SET @rows_written = @@ROWCOUNT;

        IF @own_tran = 1 COMMIT TRANSACTION;

        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        IF @own_tran = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL AND XACT_STATE() <> -1
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
