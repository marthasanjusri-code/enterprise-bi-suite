/*
  18_dim_employee_hr.sql
  dw.dim_employee_hr: sensitive HR attributes, one row per employee, using
  the SAME key as dw.dim_employee. Hidden from regional managers by
  row-level security (D62, D72).
    - gender (words), age_band, pay type (Salaried / Hourly), hire_date,
      vacation and sick leave hours (current values).
    - hire_date is shifted +hr_date_shift_days (D21).
    - age_band is the age on etl.setting hr_as_of_date (last month-end of
      the headcount snapshot), from the shifted birth date, counting
      birthdays exactly. Birth date itself is NOT stored (D62, D91).
  Special row: -1 Unknown. Loaded after dw.dim_employee.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.dim_employee_hr') IS NULL
CREATE TABLE dw.dim_employee_hr (
    employee_key       int NOT NULL CONSTRAINT pk_dim_employee_hr PRIMARY KEY,
    employee_id        int NULL,
    row_type           varchar(20) NOT NULL,
    is_in_source       bit NOT NULL,
    gender             varchar(10) NOT NULL,
    age_band           varchar(12) NOT NULL,
    pay_type           varchar(10) NOT NULL,
    hire_date          date NULL,
    vacation_hours     smallint NULL,
    sick_leave_hours   smallint NULL,
    inserted_batch_id  int NOT NULL,
    updated_batch_id   int NOT NULL,
    CONSTRAINT ck_dim_employee_hr_row_type CHECK (row_type IN ('Source', 'Unknown'))
);
GO

CREATE OR ALTER PROCEDURE etl.load_dim_employee_hr
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_updated int, @rows_inserted int, @rows_retired int,
            @hr_shift int, @as_of date;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.dim_employee_hr', @log_id OUTPUT;

        EXEC etl.get_setting_int  'hr_date_shift_days', @hr_shift OUTPUT;
        EXEC etl.get_setting_date 'hr_as_of_date',      @as_of    OUTPUT;

        IF NOT EXISTS (SELECT 1 FROM dw.dim_employee_hr WHERE employee_key = -1)
            INSERT INTO dw.dim_employee_hr (employee_key, employee_id, row_type, is_in_source, gender,
                                            age_band, pay_type, hire_date, vacation_hours,
                                            sick_leave_hours, inserted_batch_id, updated_batch_id)
            VALUES (-1, NULL, 'Unknown', 0, 'Unknown', 'Unknown', 'Unknown', NULL, NULL, NULL,
                    @batch_id, @batch_id);

        IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;

        WITH emp AS (
            SELECT  e.*,
                    DATEADD(day, @hr_shift, e.BirthDate) AS birth_shifted
            FROM stg.aw_employee e
        ),
        aged AS (
            SELECT  emp.*,
                    DATEDIFF(year, birth_shifted, @as_of)
                      - CASE WHEN DATEADD(year, DATEDIFF(year, birth_shifted, @as_of), birth_shifted) > @as_of
                             THEN 1 ELSE 0 END AS age      -- birthday not reached yet this year
            FROM emp
        )
        SELECT  d.employee_key,
                a.BusinessEntityID                                         AS employee_id,
                'Source'                                                   AS row_type,
                CASE a.Gender WHEN 'F' THEN 'Female' WHEN 'M' THEN 'Male' ELSE 'Unknown' END AS gender,
                CASE WHEN a.age IS NULL THEN 'Unknown'
                     WHEN a.age < 30    THEN 'Under 30'
                     WHEN a.age < 40    THEN '30-39'
                     WHEN a.age < 50    THEN '40-49'
                     WHEN a.age < 60    THEN '50-59'
                     ELSE                    '60 and over' END             AS age_band,
                CASE a.SalariedFlag WHEN 1 THEN 'Salaried' WHEN 0 THEN 'Hourly' ELSE 'Unknown' END AS pay_type,
                DATEADD(day, @hr_shift, a.HireDate)                        AS hire_date,
                a.VacationHours                                            AS vacation_hours,
                a.SickLeaveHours                                           AS sick_leave_hours
        INTO #src
        FROM aged a
        JOIN dw.dim_employee d ON d.employee_id = a.BusinessEntityID;
        SET @rows_read = @@ROWCOUNT;

        UPDATE h
        SET employee_id = s.employee_id, row_type = s.row_type, gender = s.gender, age_band = s.age_band,
            pay_type = s.pay_type, hire_date = s.hire_date, vacation_hours = s.vacation_hours,
            sick_leave_hours = s.sick_leave_hours,
            is_in_source = 1,
            updated_batch_id = @batch_id
        FROM dw.dim_employee_hr h
        JOIN #src s ON s.employee_key = h.employee_key
        WHERE NOT EXISTS (
            SELECT s.employee_id, s.row_type, s.gender, s.age_band, s.pay_type, s.hire_date,
                   s.vacation_hours, s.sick_leave_hours, CAST(1 AS bit)
            INTERSECT
            SELECT h.employee_id, h.row_type, h.gender, h.age_band, h.pay_type, h.hire_date,
                   h.vacation_hours, h.sick_leave_hours, h.is_in_source);
        SET @rows_updated = @@ROWCOUNT;

        INSERT INTO dw.dim_employee_hr (employee_key, employee_id, row_type, is_in_source, gender,
                                        age_band, pay_type, hire_date, vacation_hours,
                                        sick_leave_hours, inserted_batch_id, updated_batch_id)
        SELECT s.employee_key, s.employee_id, s.row_type, 1, s.gender, s.age_band, s.pay_type,
               s.hire_date, s.vacation_hours, s.sick_leave_hours, @batch_id, @batch_id
        FROM #src s
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_employee_hr h WHERE h.employee_key = s.employee_key);
        SET @rows_inserted = @@ROWCOUNT;

        UPDATE h
        SET is_in_source = 0,
            updated_batch_id = @batch_id
        FROM dw.dim_employee_hr h
        WHERE h.row_type = 'Source'
          AND h.is_in_source = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.employee_key = h.employee_key);
        SET @rows_retired = @@ROWCOUNT;

        DECLARE @rows_written int = @rows_updated + @rows_inserted + @rows_retired;
        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
