/*
  06_dim_date.sql
  dw.dim_date: one row per day, shared by every fact.
  etl.load_dim_date builds the calendar from rules and loads it with
  UPDATE (changed rows) then INSERT (new rows). Dates are never deleted.

  Rules (decisions D22-D24, D31, D83-D86):
    - Range: 1 January of the year of the earliest fact or hire date, to
      31 December of the year of the latest fact date, read from staging
      after the date shifts.
    - Weekday by arithmetic, Monday = 1 (ISO), independent of DATEFIRST.
    - Day and month names from fixed lists, independent of SET LANGUAGE.
    - Fiscal year from etl.setting (starts 1 July, named by its end year).
    - Quota periods from the quota dates in staging: from each quota date to
      the day before the next; the last ends 3 months after its start
      minus one day.
    - No unknown row and no relative columns ("current month" etc.).
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.dim_date') IS NULL
CREATE TABLE dw.dim_date (
    date_key             int          NOT NULL CONSTRAINT pk_dim_date PRIMARY KEY,
    full_date            date         NOT NULL CONSTRAINT uq_dim_date_full_date UNIQUE,
    day_of_month         tinyint      NOT NULL,
    day_name             varchar(9)   NOT NULL,
    day_short            char(3)      NOT NULL,
    day_of_week          tinyint      NOT NULL,
    is_weekend           bit          NOT NULL,
    iso_week             tinyint      NOT NULL,
    iso_year             smallint     NOT NULL,
    month_number         tinyint      NOT NULL,
    month_name           varchar(9)   NOT NULL,
    month_short          char(3)      NOT NULL,
    year_month           char(7)      NOT NULL,
    year_month_number    int          NOT NULL,
    month_start_date     date         NOT NULL,
    month_end_date       date         NOT NULL,
    is_month_end         bit          NOT NULL,
    quarter              tinyint      NOT NULL,
    quarter_label        char(2)      NOT NULL,
    year_quarter         char(7)      NOT NULL,
    year                 smallint     NOT NULL,
    fiscal_year          smallint     NOT NULL,
    fiscal_year_label    char(6)      NOT NULL,
    fiscal_quarter       tinyint      NOT NULL,
    fiscal_month         tinyint      NOT NULL,
    fiscal_year_quarter  char(9)      NOT NULL,
    quota_period_start   date         NULL,
    quota_period_end     date         NULL,
    quota_period_label   varchar(30)  NOT NULL,
    inserted_batch_id    int          NOT NULL,
    updated_batch_id     int          NOT NULL
);
GO

CREATE OR ALTER PROCEDURE etl.load_dim_date
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_updated int, @rows_inserted int,
            @hr_shift int, @dw_shift int, @fiscal_start int,
            @first_date date, @last_date date;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.dim_date', @log_id OUTPUT;

        -- GENERATE_SERIES needs compatibility level 160 or higher.
        IF (SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME()) < 160
            THROW 50002, N'dw.dim_date needs database compatibility level 160 or higher (GENERATE_SERIES).', 1;

        EXEC etl.get_setting_int 'hr_date_shift_days',      @hr_shift     OUTPUT;
        EXEC etl.get_setting_int 'dw_date_shift_days',      @dw_shift     OUTPUT;
        EXEC etl.get_setting_int 'fiscal_year_start_month', @fiscal_start OUTPUT;

        -- Range: every date a fact or a hire date can use, after the shifts.
        SELECT  @first_date = DATEFROMPARTS(YEAR(MIN(first_date)), 1, 1),
                @last_date  = DATEFROMPARTS(YEAR(MAX(last_date)), 12, 31)
        FROM (
            SELECT CAST(MIN(OrderDate) AS date), CAST(MAX(OrderDate) AS date) FROM stg.aw_sales_order_header
            UNION ALL SELECT CAST(MIN(DueDate) AS date),  CAST(MAX(DueDate) AS date)  FROM stg.aw_sales_order_header
            UNION ALL SELECT CAST(MIN(ShipDate) AS date), CAST(MAX(ShipDate) AS date) FROM stg.aw_sales_order_header
            UNION ALL SELECT CAST(MIN(QuotaDate) AS date), CAST(MAX(QuotaDate) AS date) FROM stg.aw_sales_person_quota_history
            UNION ALL SELECT CAST(MIN(OrderDate) AS date), CAST(MAX(OrderDate) AS date) FROM stg.aw_purchase_order_header
            UNION ALL SELECT CAST(MIN(ShipDate) AS date),  CAST(MAX(ShipDate) AS date)  FROM stg.aw_purchase_order_header
            UNION ALL SELECT CAST(MIN(DueDate) AS date),   CAST(MAX(DueDate) AS date)   FROM stg.aw_purchase_order_detail
            UNION ALL SELECT CAST(MIN(StartDate) AS date), CAST(MAX(StartDate) AS date) FROM stg.aw_work_order
            UNION ALL SELECT CAST(MIN(EndDate) AS date),   CAST(MAX(EndDate) AS date)   FROM stg.aw_work_order
            UNION ALL SELECT CAST(MIN(DueDate) AS date),   CAST(MAX(DueDate) AS date)   FROM stg.aw_work_order
            UNION ALL SELECT CAST(MAX(ModifiedDate) AS date), CAST(MAX(ModifiedDate) AS date) FROM stg.aw_product_inventory
            UNION ALL SELECT EOMONTH(DATEADD(day, @dw_shift, MIN([Date]))), EOMONTH(DATEADD(day, @dw_shift, MAX([Date]))) FROM stg.awdw_fact_finance
            UNION ALL SELECT DATEADD(day, @hr_shift, MIN(HireDate)), DATEADD(day, @hr_shift, MAX(HireDate)) FROM stg.aw_employee
            UNION ALL SELECT CAST(DATEADD(day, @hr_shift, MIN(StartDate)) AS date), CAST(DATEADD(day, @hr_shift, MAX(StartDate)) AS date) FROM stg.aw_employee_department_history
            UNION ALL SELECT CAST(DATEADD(day, @hr_shift, MIN(RateChangeDate)) AS date), CAST(DATEADD(day, @hr_shift, MAX(RateChangeDate)) AS date) FROM stg.aw_employee_pay_history
        ) r (first_date, last_date);

        IF @first_date IS NULL OR @last_date IS NULL
            THROW 50003, N'dw.dim_date: no dates found in staging. Load staging first.', 1;

        IF OBJECT_ID('tempdb..#calendar') IS NOT NULL DROP TABLE #calendar;

        WITH days AS (
            SELECT DATEADD(day, s.value, @first_date) AS full_date
            FROM GENERATE_SERIES(0, DATEDIFF(day, @first_date, @last_date)) s
        ),
        quota AS (
            SELECT  q.quota_start,
                    ISNULL(DATEADD(day, -1, LEAD(q.quota_start) OVER (ORDER BY q.quota_start)),
                           DATEADD(day, -1, DATEADD(month, 3, q.quota_start))) AS quota_end
            FROM (SELECT DISTINCT CAST(QuotaDate AS date) AS quota_start
                  FROM stg.aw_sales_person_quota_history) q
        ),
        base AS (
            SELECT  d.full_date,
                    (DATEDIFF(day, '19000101', d.full_date) % 7) + 1          AS dow,   -- 1900-01-01 was a Monday
                    MONTH(d.full_date)                                         AS m,
                    YEAR(d.full_date)                                          AS y,
                    ((MONTH(d.full_date) - @fiscal_start + 12) % 12) + 1       AS fm
            FROM days d
        )
        SELECT  y * 10000 + m * 100 + DAY(full_date)                                   AS date_key,
                full_date,
                CAST(DAY(full_date) AS tinyint)                                        AS day_of_month,
                CAST(CHOOSE(dow, 'Monday', 'Tuesday', 'Wednesday', 'Thursday',
                                 'Friday', 'Saturday', 'Sunday') AS varchar(9))         AS day_name,
                CAST(CHOOSE(dow, 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun') AS char(3)) AS day_short,
                CAST(dow AS tinyint)                                                   AS day_of_week,
                CAST(CASE WHEN dow IN (6, 7) THEN 1 ELSE 0 END AS bit)                 AS is_weekend,
                CAST(DATEPART(ISO_WEEK, full_date) AS tinyint)                         AS iso_week,
                CAST(YEAR(DATEADD(day, 4 - dow, full_date)) AS smallint)               AS iso_year,  -- year of the week's Thursday
                CAST(m AS tinyint)                                                     AS month_number,
                CAST(CHOOSE(m, 'January', 'February', 'March', 'April', 'May', 'June', 'July',
                               'August', 'September', 'October', 'November', 'December') AS varchar(9)) AS month_name,
                CAST(CHOOSE(m, 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul',
                               'Aug', 'Sep', 'Oct', 'Nov', 'Dec') AS char(3))          AS month_short,
                CAST(CONVERT(char(7), full_date, 23) AS char(7))                       AS year_month,
                y * 100 + m                                                            AS year_month_number,
                DATEFROMPARTS(y, m, 1)                                                 AS month_start_date,
                EOMONTH(full_date)                                                     AS month_end_date,
                CAST(CASE WHEN full_date = EOMONTH(full_date) THEN 1 ELSE 0 END AS bit) AS is_month_end,
                CAST((m - 1) / 3 + 1 AS tinyint)                                       AS quarter,
                CAST('Q' + CAST((m - 1) / 3 + 1 AS char(1)) AS char(2))                AS quarter_label,
                CAST(CAST(y AS char(4)) + '-Q' + CAST((m - 1) / 3 + 1 AS char(1)) AS char(7)) AS year_quarter,
                CAST(y AS smallint)                                                    AS year,
                CAST(CASE WHEN @fiscal_start > 1 AND m >= @fiscal_start THEN y + 1 ELSE y END AS smallint) AS fiscal_year,
                CAST('FY' + CAST(CASE WHEN @fiscal_start > 1 AND m >= @fiscal_start THEN y + 1 ELSE y END AS char(4)) AS char(6)) AS fiscal_year_label,
                CAST((fm - 1) / 3 + 1 AS tinyint)                                      AS fiscal_quarter,
                CAST(fm AS tinyint)                                                    AS fiscal_month,
                CAST('FY' + CAST(CASE WHEN @fiscal_start > 1 AND m >= @fiscal_start THEN y + 1 ELSE y END AS char(4))
                     + '-Q' + CAST((fm - 1) / 3 + 1 AS char(1)) AS char(9))             AS fiscal_year_quarter,
                q.quota_start                                                          AS quota_period_start,
                q.quota_end                                                            AS quota_period_end,
                CAST(CASE WHEN q.quota_start IS NULL THEN 'No quota period'
                          ELSE 'Quota period ' + CONVERT(char(10), q.quota_start, 23) END AS varchar(30)) AS quota_period_label
        INTO #calendar
        FROM base b
        LEFT JOIN quota q ON b.full_date BETWEEN q.quota_start AND q.quota_end;

        SET @rows_read = @@ROWCOUNT;

        -- 1. Update rows whose values changed (INTERSECT treats NULLs as equal).
        UPDATE d
        SET full_date = c.full_date, day_of_month = c.day_of_month, day_name = c.day_name,
            day_short = c.day_short, day_of_week = c.day_of_week, is_weekend = c.is_weekend,
            iso_week = c.iso_week, iso_year = c.iso_year, month_number = c.month_number,
            month_name = c.month_name, month_short = c.month_short, year_month = c.year_month,
            year_month_number = c.year_month_number, month_start_date = c.month_start_date,
            month_end_date = c.month_end_date, is_month_end = c.is_month_end, quarter = c.quarter,
            quarter_label = c.quarter_label, year_quarter = c.year_quarter, year = c.year,
            fiscal_year = c.fiscal_year, fiscal_year_label = c.fiscal_year_label,
            fiscal_quarter = c.fiscal_quarter, fiscal_month = c.fiscal_month,
            fiscal_year_quarter = c.fiscal_year_quarter, quota_period_start = c.quota_period_start,
            quota_period_end = c.quota_period_end, quota_period_label = c.quota_period_label,
            updated_batch_id = @batch_id
        FROM dw.dim_date d
        JOIN #calendar c ON c.date_key = d.date_key
        WHERE NOT EXISTS (
            SELECT c.full_date, c.day_of_month, c.day_name, c.day_short, c.day_of_week, c.is_weekend,
                   c.iso_week, c.iso_year, c.month_number, c.month_name, c.month_short, c.year_month,
                   c.year_month_number, c.month_start_date, c.month_end_date, c.is_month_end, c.quarter,
                   c.quarter_label, c.year_quarter, c.year, c.fiscal_year, c.fiscal_year_label,
                   c.fiscal_quarter, c.fiscal_month, c.fiscal_year_quarter, c.quota_period_start,
                   c.quota_period_end, c.quota_period_label
            INTERSECT
            SELECT d.full_date, d.day_of_month, d.day_name, d.day_short, d.day_of_week, d.is_weekend,
                   d.iso_week, d.iso_year, d.month_number, d.month_name, d.month_short, d.year_month,
                   d.year_month_number, d.month_start_date, d.month_end_date, d.is_month_end, d.quarter,
                   d.quarter_label, d.year_quarter, d.year, d.fiscal_year, d.fiscal_year_label,
                   d.fiscal_quarter, d.fiscal_month, d.fiscal_year_quarter, d.quota_period_start,
                   d.quota_period_end, d.quota_period_label);
        SET @rows_updated = @@ROWCOUNT;

        -- 2. Insert new dates. Existing dates are never deleted.
        INSERT INTO dw.dim_date (
            date_key, full_date, day_of_month, day_name, day_short, day_of_week, is_weekend, iso_week,
            iso_year, month_number, month_name, month_short, year_month, year_month_number,
            month_start_date, month_end_date, is_month_end, quarter, quarter_label, year_quarter,
            year, fiscal_year, fiscal_year_label, fiscal_quarter, fiscal_month, fiscal_year_quarter,
            quota_period_start, quota_period_end, quota_period_label,
            inserted_batch_id, updated_batch_id)
        SELECT
            date_key, full_date, day_of_month, day_name, day_short, day_of_week, is_weekend, iso_week,
            iso_year, month_number, month_name, month_short, year_month, year_month_number,
            month_start_date, month_end_date, is_month_end, quarter, quarter_label, year_quarter,
            year, fiscal_year, fiscal_year_label, fiscal_quarter, fiscal_month, fiscal_year_quarter,
            quota_period_start, quota_period_end, quota_period_label,
            @batch_id, @batch_id
        FROM #calendar c
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_date d WHERE d.date_key = c.date_key);
        SET @rows_inserted = @@ROWCOUNT;

        DECLARE @rows_written int = @rows_updated + @rows_inserted;
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
