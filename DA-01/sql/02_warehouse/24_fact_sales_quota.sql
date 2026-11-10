/*
  24_fact_sales_quota.sql
  dw.fact_sales_quota: one row per salesperson per quota period.
    Source: stg.aw_sales_person_quota_history, territory from stg.aw_sales_territory_history,
    region group from the salesperson's orders (stg.aw_sales_order_header + stg.aw_sales_territory).
    OLTP dates are used as they are (D19).

  Rules:
    - Grain: 163 rows = one per salesperson and quota date (quota checks: check 1).
    - The quota date is the start of a quota period; period start and end come from dw.dim_date,
      which builds the company quota calendar from the same staging dates (D30, D31).
    - Territory rule (D32), first that applies, recorded in territory_source:
        history            the territory period that covers the quota date (end date inclusive);
        nearest_history    else the salesperson's territory period nearest to the quota date
                           (distance to its start if the quota date is before it, to its end if after;
                           ties go to the later period);
        region_from_orders else, when all the salesperson's orders are in one region group,
                           the region-level territory row of that group (D61);
        unknown            else -1.
    - Keys come from the dimensions by business key; not found -> -1 (D59). Keys are never NULL.
    - Full reload in one transaction (D76, D77); refuses an empty staging and opens its own
      transaction only when the caller has none (D106).
  Audit columns: batch_id, loaded_at (D10).
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.fact_sales_quota') IS NULL
CREATE TABLE dw.fact_sales_quota (
    salesperson_id       int           NOT NULL,
    quota_date_key       int           NOT NULL CONSTRAINT fk_fact_sales_quota_date        REFERENCES dw.dim_date (date_key),
    salesperson_key      int           NOT NULL CONSTRAINT fk_fact_sales_quota_salesperson REFERENCES dw.dim_employee (employee_key),
    territory_key        int           NOT NULL CONSTRAINT fk_fact_sales_quota_territory   REFERENCES dw.dim_territory (territory_key),
    territory_source     varchar(20)   NOT NULL CONSTRAINT ck_fact_sales_quota_territory_source
                                                CHECK (territory_source IN ('history', 'nearest_history', 'region_from_orders', 'unknown')),
    quota_period_start   date          NOT NULL,
    quota_period_end     date          NOT NULL,
    sales_quota          money         NOT NULL,
    batch_id             int           NOT NULL,
    loaded_at            datetime2(0)  NOT NULL,
    CONSTRAINT pk_fact_sales_quota PRIMARY KEY (salesperson_id, quota_date_key)
);
GO

CREATE OR ALTER PROCEDURE etl.load_fact_sales_quota
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_written int,
            @loaded_at datetime2(0) = SYSDATETIME(),
            @own_tran bit = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.fact_sales_quota', @log_id OUTPUT;

        SET @rows_read = (SELECT COUNT(*) FROM stg.aw_sales_person_quota_history);

        IF @rows_read = 0
            THROW 50002, 'Staging quota history is empty; dw.fact_sales_quota was not changed.', 1;

        -- Territory of each quota row, before any key lookup.
        SELECT  q.BusinessEntityID                               AS salesperson_id,
                CAST(q.QuotaDate AS date)                        AS quota_date,
                q.SalesQuota                                     AS sales_quota,
                cov.TerritoryID                                  AS covering_territory_id,
                nea.TerritoryID                                  AS nearest_territory_id,
                reg.region_group                                 AS order_region_group
        INTO #src
        FROM stg.aw_sales_person_quota_history q
        OUTER APPLY (
            SELECT TOP (1) t.TerritoryID
            FROM stg.aw_sales_territory_history t
            WHERE t.BusinessEntityID = q.BusinessEntityID
              AND q.QuotaDate >= t.StartDate
              AND (t.EndDate IS NULL OR q.QuotaDate <= t.EndDate)
            ORDER BY t.StartDate DESC
        ) cov
        OUTER APPLY (
            SELECT TOP (1) t.TerritoryID
            FROM stg.aw_sales_territory_history t
            WHERE t.BusinessEntityID = q.BusinessEntityID
            ORDER BY CASE WHEN q.QuotaDate < t.StartDate THEN DATEDIFF(day, q.QuotaDate, t.StartDate)
                          ELSE DATEDIFF(day, t.EndDate, q.QuotaDate) END,
                     t.StartDate DESC
        ) nea
        OUTER APPLY (
            SELECT CASE WHEN COUNT(DISTINCT st.[Group]) = 1 THEN MIN(st.[Group]) END AS region_group
            FROM stg.aw_sales_order_header h
            JOIN stg.aw_sales_territory st ON st.TerritoryID = h.TerritoryID
            WHERE h.SalesPersonID = q.BusinessEntityID
        ) reg;

        IF @own_tran = 1 BEGIN TRANSACTION;

        TRUNCATE TABLE dw.fact_sales_quota;

        INSERT INTO dw.fact_sales_quota (
            salesperson_id, quota_date_key, salesperson_key, territory_key, territory_source,
            quota_period_start, quota_period_end, sales_quota, batch_id, loaded_at)
        SELECT
            s.salesperson_id,
            YEAR(s.quota_date) * 10000 + MONTH(s.quota_date) * 100 + DAY(s.quota_date),
            ISNULL(de.employee_key, -1),
            ISNULL(CASE WHEN s.covering_territory_id IS NOT NULL THEN th.territory_key
                        WHEN s.nearest_territory_id  IS NOT NULL THEN tn.territory_key
                        ELSE tr.territory_key END, -1),
            CASE WHEN s.covering_territory_id IS NOT NULL THEN 'history'
                 WHEN s.nearest_territory_id  IS NOT NULL THEN 'nearest_history'
                 WHEN s.order_region_group    IS NOT NULL THEN 'region_from_orders'
                 ELSE 'unknown' END,
            dd.quota_period_start,          -- NOT NULL column: a quota date outside the calendar stops the load
            dd.quota_period_end,
            s.sales_quota,
            @batch_id,
            @loaded_at
        FROM #src s
        LEFT JOIN dw.dim_employee de  ON de.employee_id = s.salesperson_id
        LEFT JOIN dw.dim_territory th ON th.territory_code = CAST(s.covering_territory_id AS varchar(60))
        LEFT JOIN dw.dim_territory tn ON tn.territory_code = CAST(s.nearest_territory_id AS varchar(60))
        LEFT JOIN dw.dim_territory tr ON tr.is_region_level = 1 AND tr.region_group = s.order_region_group
        LEFT JOIN dw.dim_date dd      ON dd.full_date = s.quota_date;
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
