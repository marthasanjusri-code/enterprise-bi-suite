/*
  25_fact_work_order.sql
  dw.fact_work_order: one row per work order (72,591; work order checks: check 1).
    Source: stg.aw_work_order, cost from stg.aw_product_cost_history and stg.aw_product.
    OLTP dates are used as they are (D19). No location link: the source has none (D48).

  Rules:
    - Keys come from the dimensions by business key; not found -> -1 (D59).
      scrap_reason_key is -2 "No scrap" when nothing was scrapped.
      Keys are never NULL, except end_date_key: the source EndDate may be empty, an open
      work order (D108). 0 open work orders today (work order checks: check 4).
    - Timing (D108): days_to_finish = days from start to end; is_finished_late = 1 when the
      end date is after the due date (the measure behind the 22,790 late orders of check 4);
      days_late = days from due date to end date when late, 0 when on time. All three are
      NULL for an open work order (unknown, D17).
    - Unit cost (work order checks: cost decisions), first that applies, recorded in cost_source:
        history          the cost period that contains the start date (end date inclusive);
        carried_forward  start date after a period ended and before any later period started:
                         the latest period that started on or before the start date;
        carried_back     start date before the product's first period: the first period;
        standard_cost    no cost history: Product.StandardCost when above 0;
        unknown          else NULL (never 0, D17).
    - scrap_cost = unit_cost x scrapped_qty; 0 when nothing was scrapped; NULL when units were
      scrapped and the unit cost is unknown. Stored but hidden while coverage is low (D46).
    - Full reload in one transaction (D76, D77); refuses an empty staging and opens its own
      transaction only when the caller has none (D106).
  Audit columns: batch_id, loaded_at (D10).
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.fact_work_order') IS NULL
CREATE TABLE dw.fact_work_order (
    work_order_id      int           NOT NULL CONSTRAINT pk_fact_work_order PRIMARY KEY,
    start_date_key     int           NOT NULL CONSTRAINT fk_fact_work_order_start_date REFERENCES dw.dim_date (date_key),
    end_date_key       int           NULL     CONSTRAINT fk_fact_work_order_end_date   REFERENCES dw.dim_date (date_key),
    due_date_key       int           NOT NULL CONSTRAINT fk_fact_work_order_due_date   REFERENCES dw.dim_date (date_key),
    product_key        int           NOT NULL CONSTRAINT fk_fact_work_order_product    REFERENCES dw.dim_product (product_key),
    scrap_reason_key   int           NOT NULL CONSTRAINT fk_fact_work_order_scrap_reason REFERENCES dw.dim_scrap_reason (scrap_reason_key),
    order_qty          int           NOT NULL,
    stocked_qty        int           NOT NULL,
    scrapped_qty       smallint      NOT NULL,
    days_to_finish     int           NULL,
    days_late          int           NULL,
    is_finished_late   bit           NULL,
    unit_cost          money         NULL,
    scrap_cost         money         NULL,
    cost_source        varchar(20)   NOT NULL CONSTRAINT ck_fact_work_order_cost_source
                                              CHECK (cost_source IN ('history', 'carried_forward', 'carried_back', 'standard_cost', 'unknown')),
    batch_id           int           NOT NULL,
    loaded_at          datetime2(0)  NOT NULL
);
GO

CREATE OR ALTER PROCEDURE etl.load_fact_work_order
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_written int,
            @loaded_at datetime2(0) = SYSDATETIME(),
            @own_tran bit = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.fact_work_order', @log_id OUTPUT;

        SET @rows_read = (SELECT COUNT(*) FROM stg.aw_work_order);

        IF @rows_read = 0
            THROW 50002, 'Staging work orders are empty; dw.fact_work_order was not changed.', 1;

        -- Cost of each work order, before any key lookup.
        SELECT  w.WorkOrderID, w.ProductID, w.OrderQty, w.StockedQty, w.ScrappedQty,
                w.StartDate, w.EndDate, w.DueDate, w.ScrapReasonID,
                COALESCE(lat.StandardCost, fst.StandardCost, NULLIF(p.StandardCost, 0)) AS unit_cost,
                CASE WHEN lat.StandardCost IS NOT NULL
                          AND (lat.EndDate IS NULL OR w.StartDate <= lat.EndDate) THEN 'history'
                     WHEN lat.StandardCost IS NOT NULL                             THEN 'carried_forward'
                     WHEN fst.StandardCost IS NOT NULL                             THEN 'carried_back'
                     WHEN NULLIF(p.StandardCost, 0) IS NOT NULL                    THEN 'standard_cost'
                     ELSE 'unknown' END                                            AS cost_source
        INTO #src
        FROM stg.aw_work_order w
        LEFT JOIN stg.aw_product p ON p.ProductID = w.ProductID
        OUTER APPLY (               -- latest period that started on or before the start date
            SELECT TOP (1) ch.StandardCost, ch.EndDate
            FROM stg.aw_product_cost_history ch
            WHERE ch.ProductID = w.ProductID AND ch.StartDate <= w.StartDate
            ORDER BY ch.StartDate DESC
        ) lat
        OUTER APPLY (               -- first period, used only when no period started yet
            SELECT TOP (1) ch.StandardCost
            FROM stg.aw_product_cost_history ch
            WHERE ch.ProductID = w.ProductID
            ORDER BY ch.StartDate ASC
        ) fst;

        IF @own_tran = 1 BEGIN TRANSACTION;

        TRUNCATE TABLE dw.fact_work_order;

        INSERT INTO dw.fact_work_order (
            work_order_id, start_date_key, end_date_key, due_date_key, product_key, scrap_reason_key,
            order_qty, stocked_qty, scrapped_qty, days_to_finish, days_late, is_finished_late,
            unit_cost, scrap_cost, cost_source, batch_id, loaded_at)
        SELECT
            s.WorkOrderID,
            YEAR(s.StartDate) * 10000 + MONTH(s.StartDate) * 100 + DAY(s.StartDate),
            YEAR(s.EndDate)   * 10000 + MONTH(s.EndDate)   * 100 + DAY(s.EndDate),     -- NULL when open (D108)
            YEAR(s.DueDate)   * 10000 + MONTH(s.DueDate)   * 100 + DAY(s.DueDate),
            ISNULL(dp.product_key, -1),
            CASE WHEN s.ScrappedQty = 0 THEN -2 ELSE ISNULL(dsr.scrap_reason_key, -1) END,
            s.OrderQty,
            s.StockedQty,
            s.ScrappedQty,
            DATEDIFF(day, s.StartDate, s.EndDate),
            CASE WHEN s.EndDate IS NULL     THEN NULL
                 WHEN s.EndDate > s.DueDate THEN DATEDIFF(day, s.DueDate, s.EndDate)
                 ELSE 0 END,
            CAST(CASE WHEN s.EndDate IS NULL     THEN NULL
                      WHEN s.EndDate > s.DueDate THEN 1
                      ELSE 0 END AS bit),
            s.unit_cost,
            CASE WHEN s.ScrappedQty = 0 THEN 0 ELSE s.unit_cost * s.ScrappedQty END,
            s.cost_source,
            @batch_id,
            @loaded_at
        FROM #src s
        LEFT JOIN dw.dim_product dp       ON dp.product_id = s.ProductID
        LEFT JOIN dw.dim_scrap_reason dsr ON dsr.scrap_reason_id = s.ScrapReasonID;
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
