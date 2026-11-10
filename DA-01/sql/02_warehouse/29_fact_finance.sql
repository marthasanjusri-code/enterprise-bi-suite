/*
  29_fact_finance.sql
  dw.fact_finance: one row per source finance row (39,409; finance checks: check 1). The grain
  is month x organisation x department group x account x scenario x entry type (D33, D34).
    Source: stg.awdw_fact_finance, organisation currency from stg.awdw_dim_organization +
    stg.awdw_dim_currency, rates from stg.awdw_fact_currency_rate. DW dates shifted by
    etl.setting dw_date_shift_days (+4,170, D20).

  Rules:
    - period_date_key = month-end of the shifted source date (D33); source_date keeps the
      original DW date.
    - entry_type (D34): in a period with two source dates, the date with fewer rows is
      'Year-end adjustment' (2011-12-28: 18 rows, 2012-12-27: 28 rows; query of 10 Nov 2026),
      every other row 'Regular'.
    - amount_local = the source amount, stored exactly with 2 decimals (no source amount has
      more; query of 10 Nov 2026) (D114).
    - Conversion to USD (D36), rate = USD per 1 unit of the organisation's currency, looked up on
      the ORIGINAL date:
        Income statement   monthly average rate = average of AverageRate in the original date's month;
        Balance sheet      EndOfDayRate on the original date (exists for every row; query of 10 Nov 2026);
        USD organisations  1.0;
        Statistical        not money: exchange_rate and amount_usd are NULL.
      amount_usd = amount_local x exchange_rate, 4 decimals.
    - Corporate's own rows link to its source row, shown as "Corporate (direct)" (D35).
    - Keys come from the dimensions by business key; not found -> -1 (D59). Never NULL.
    - Full reload in one transaction (D76, D77); refuses an empty staging and opens its own
      transaction only when the caller has none (D106).
  Audit columns: batch_id, loaded_at (D10).
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.fact_finance') IS NULL
CREATE TABLE dw.fact_finance (
    finance_id                     int            NOT NULL CONSTRAINT pk_fact_finance PRIMARY KEY,
    period_date_key                int            NOT NULL CONSTRAINT fk_fact_finance_period       REFERENCES dw.dim_date (date_key),
    organization_key               int            NOT NULL CONSTRAINT fk_fact_finance_organization REFERENCES dw.dim_organization (organization_key),
    finance_department_group_key   int            NOT NULL CONSTRAINT fk_fact_finance_dept_group   REFERENCES dw.dim_finance_department_group (finance_department_group_key),
    account_key                    int            NOT NULL CONSTRAINT fk_fact_finance_account      REFERENCES dw.dim_account (account_key),
    scenario_key                   int            NOT NULL CONSTRAINT fk_fact_finance_scenario     REFERENCES dw.dim_scenario (scenario_key),
    entry_type                     varchar(20)    NOT NULL CONSTRAINT ck_fact_finance_entry_type
                                                           CHECK (entry_type IN ('Regular', 'Year-end adjustment')),
    source_date                    date           NOT NULL,
    currency_code                  nvarchar(3)    NOT NULL,
    amount_local                   decimal(19,2)  NOT NULL,
    exchange_rate                  decimal(19,10) NULL,
    amount_usd                     decimal(19,4)  NULL,
    batch_id                       int            NOT NULL,
    loaded_at                      datetime2(0)   NOT NULL,
    CONSTRAINT ux_fact_finance_grain UNIQUE (period_date_key, organization_key, finance_department_group_key,
                                             account_key, scenario_key, entry_type)
);
GO

CREATE OR ALTER PROCEDURE etl.load_fact_finance
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_written int, @dw_shift int,
            @loaded_at datetime2(0) = SYSDATETIME(),
            @own_tran bit = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.fact_finance', @log_id OUTPUT;

        SET @rows_read = (SELECT COUNT(*) FROM stg.awdw_fact_finance);

        IF @rows_read = 0
           OR NOT EXISTS (SELECT 1 FROM stg.awdw_fact_currency_rate)
           OR NOT EXISTS (SELECT 1 FROM stg.awdw_dim_organization)
           OR NOT EXISTS (SELECT 1 FROM stg.awdw_dim_currency)
            THROW 50002, 'Staging finance, rates, organisations or currencies are empty; dw.fact_finance was not changed.', 1;

        EXEC etl.get_setting_int 'dw_date_shift_days', @dw_shift OUTPUT;

        -- Rows per source date and per period, to find the adjustment dates (D34).
        SELECT  CAST(f.[Date] AS date)                           AS source_date,
                EOMONTH(DATEADD(day, @dw_shift, f.[Date]))       AS period_end,
                COUNT(*)                                         AS rows_on_date
        INTO #dates
        FROM stg.awdw_fact_finance f
        GROUP BY CAST(f.[Date] AS date), EOMONTH(DATEADD(day, @dw_shift, f.[Date]));

        SELECT  d.source_date,
                d.period_end,
                CASE WHEN d.rows_on_date < MAX(d.rows_on_date) OVER (PARTITION BY d.period_end)
                     THEN 'Year-end adjustment' ELSE 'Regular' END AS entry_type
        INTO #entry
        FROM #dates d;

        -- Monthly average rate per currency and calendar month (original timeline).
        SELECT  r.CurrencyKey,
                EOMONTH(r.[Date])      AS rate_month,
                AVG(r.AverageRate)     AS avg_rate
        INTO #avg_rate
        FROM stg.awdw_fact_currency_rate r
        GROUP BY r.CurrencyKey, EOMONTH(r.[Date]);

        SELECT  f.FinanceKey,
                e.period_end,
                e.entry_type,
                e.source_date,
                f.OrganizationKey, f.DepartmentGroupKey, f.AccountKey, f.ScenarioKey,
                ISNULL(CAST(cu.CurrencyAlternateKey AS nvarchar(3)), N'N/A')       AS currency_code,
                CAST(ROUND(f.Amount, 2) AS decimal(19,2))                          AS amount_local,
                CASE WHEN da.statement = 'Statistical' OR da.statement IS NULL THEN NULL
                     WHEN cu.CurrencyAlternateKey = N'USD'                       THEN CAST(1 AS decimal(19,10))
                     WHEN da.statement = 'Balance sheet'                         THEN CAST(eod.EndOfDayRate AS decimal(19,10))
                     ELSE CAST(ar.avg_rate AS decimal(19,10)) END                  AS exchange_rate
        INTO #src
        FROM stg.awdw_fact_finance f
        JOIN #entry e                        ON e.source_date = CAST(f.[Date] AS date)
        LEFT JOIN stg.awdw_dim_organization o ON o.OrganizationKey = f.OrganizationKey
        LEFT JOIN stg.awdw_dim_currency cu    ON cu.CurrencyKey = o.CurrencyKey
        LEFT JOIN dw.dim_account da           ON da.account_id = f.AccountKey
        LEFT JOIN stg.awdw_fact_currency_rate eod
               ON eod.CurrencyKey = o.CurrencyKey AND eod.[Date] = f.[Date]
        LEFT JOIN #avg_rate ar
               ON ar.CurrencyKey = o.CurrencyKey AND ar.rate_month = EOMONTH(f.[Date]);

        IF @own_tran = 1 BEGIN TRANSACTION;

        TRUNCATE TABLE dw.fact_finance;

        INSERT INTO dw.fact_finance (
            finance_id, period_date_key, organization_key, finance_department_group_key, account_key,
            scenario_key, entry_type, source_date, currency_code, amount_local, exchange_rate, amount_usd,
            batch_id, loaded_at)
        SELECT
            s.FinanceKey,
            YEAR(s.period_end) * 10000 + MONTH(s.period_end) * 100 + DAY(s.period_end),
            ISNULL(dorg.organization_key, -1),
            ISNULL(dg.finance_department_group_key, -1),
            ISNULL(da.account_key, -1),
            ISNULL(dsc.scenario_key, -1),
            s.entry_type,
            s.source_date,
            s.currency_code,
            s.amount_local,
            s.exchange_rate,
            CAST(s.amount_local * s.exchange_rate AS decimal(19,4)),
            @batch_id,
            @loaded_at
        FROM #src s
        LEFT JOIN dw.dim_organization dorg            ON dorg.organization_id = s.OrganizationKey
        LEFT JOIN dw.dim_finance_department_group dg  ON dg.department_group_id = s.DepartmentGroupKey
        LEFT JOIN dw.dim_account da                   ON da.account_id = s.AccountKey
        LEFT JOIN dw.dim_scenario dsc                 ON dsc.scenario_id = s.ScenarioKey;
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
