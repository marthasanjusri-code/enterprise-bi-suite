/*
  27_fact_inventory_current.sql
  dw.fact_inventory_current: current stock, one row per product per location (1,069 rows,
  inventory current checks: check 1), plus one zero-quantity row at "No stock location" for
  every product still on sale that has no inventory row (D52). The only inventory fact (D49).
    Source: stg.aw_product_inventory, stg.aw_product, last purchase price from
    stg.aw_purchase_order_detail + stg.aw_purchase_order_header.

  Rules:
    - snapshot_date_key = the latest ModifiedDate in the inventory source (2025-08-11 today,
      check 2): the date the whole current picture is "as of". Each row keeps its own
      last_modified_date; zero rows have none (NULL).
    - "Still on sale" = no SellEndDate (check D).
    - location_key: -2 "No stock location" for the zero rows; otherwise the location, -1 if not
      found (D59). Keys are never NULL.
    - Unit cost (D53, check E), recorded in cost_source: standard_cost when Product.StandardCost
      is above 0; else last_purchase_price = the unit price of the latest purchase line (latest
      order date, then highest line ID); else unknown (NULL, never 0, D17).
    - stock_value = quantity x unit cost; 0 when the quantity is 0 (a known zero); NULL when
      units exist and the cost is unknown (D111).
    - Full reload in one transaction (D76, D77); refuses an empty staging and opens its own
      transaction only when the caller has none (D106).
  Audit columns: batch_id, loaded_at (D10).
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.fact_inventory_current') IS NULL
CREATE TABLE dw.fact_inventory_current (
    product_key          int            NOT NULL CONSTRAINT fk_fact_inventory_current_product  REFERENCES dw.dim_product (product_key),
    location_key         int            NOT NULL CONSTRAINT fk_fact_inventory_current_location REFERENCES dw.dim_location (location_key),
    snapshot_date_key    int            NOT NULL CONSTRAINT fk_fact_inventory_current_snapshot REFERENCES dw.dim_date (date_key),
    product_id           int            NOT NULL,
    location_id          int            NULL,
    quantity             int            NOT NULL,
    unit_cost            money          NULL,
    stock_value          decimal(19,4)  NULL,
    cost_source          varchar(20)    NOT NULL CONSTRAINT ck_fact_inventory_current_cost_source
                                                 CHECK (cost_source IN ('standard_cost', 'last_purchase_price', 'unknown')),
    last_modified_date   date           NULL,
    is_zero_stock_row    bit            NOT NULL,
    batch_id             int            NOT NULL,
    loaded_at            datetime2(0)   NOT NULL,
    CONSTRAINT pk_fact_inventory_current PRIMARY KEY (product_key, location_key)
);
GO

CREATE OR ALTER PROCEDURE etl.load_fact_inventory_current
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_written int, @snapshot_date date,
            @loaded_at datetime2(0) = SYSDATETIME(),
            @own_tran bit = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.fact_inventory_current', @log_id OUTPUT;

        SET @rows_read = (SELECT COUNT(*) FROM stg.aw_product_inventory);

        IF @rows_read = 0 OR NOT EXISTS (SELECT 1 FROM stg.aw_product)
            THROW 50002, 'Staging inventory or products are empty; dw.fact_inventory_current was not changed.', 1;

        SET @snapshot_date = (SELECT CAST(MAX(ModifiedDate) AS date) FROM stg.aw_product_inventory);

        -- Unit cost of every product.
        WITH last_price AS (
            SELECT  d.ProductID, d.UnitPrice,
                    ROW_NUMBER() OVER (PARTITION BY d.ProductID
                                       ORDER BY h.OrderDate DESC, d.PurchaseOrderDetailID DESC) AS rn
            FROM stg.aw_purchase_order_detail d
            JOIN stg.aw_purchase_order_header h ON h.PurchaseOrderID = d.PurchaseOrderID
        )
        SELECT  p.ProductID,
                p.SellEndDate,
                CASE WHEN p.StandardCost > 0 THEN p.StandardCost ELSE lp.UnitPrice END AS unit_cost,
                CASE WHEN p.StandardCost > 0        THEN 'standard_cost'
                     WHEN lp.UnitPrice IS NOT NULL  THEN 'last_purchase_price'
                     ELSE 'unknown' END                                            AS cost_source
        INTO #cost
        FROM stg.aw_product p
        LEFT JOIN last_price lp ON lp.ProductID = p.ProductID AND lp.rn = 1;

        -- Stock rows, plus one zero row per product on sale without any inventory row (D52).
        SELECT  i.ProductID, CAST(i.LocationID AS int) AS LocationID, CAST(i.Quantity AS int) AS quantity,
                CAST(i.ModifiedDate AS date) AS last_modified_date, CAST(0 AS bit) AS is_zero_stock_row
        INTO #stock
        FROM stg.aw_product_inventory i
        UNION ALL
        SELECT  c.ProductID, NULL, 0, NULL, CAST(1 AS bit)
        FROM #cost c
        WHERE c.SellEndDate IS NULL
          AND NOT EXISTS (SELECT 1 FROM stg.aw_product_inventory i WHERE i.ProductID = c.ProductID);

        IF @own_tran = 1 BEGIN TRANSACTION;

        TRUNCATE TABLE dw.fact_inventory_current;

        INSERT INTO dw.fact_inventory_current (
            product_key, location_key, snapshot_date_key, product_id, location_id, quantity,
            unit_cost, stock_value, cost_source, last_modified_date, is_zero_stock_row, batch_id, loaded_at)
        SELECT
            ISNULL(dp.product_key, -1),
            CASE WHEN s.is_zero_stock_row = 1 THEN -2 ELSE ISNULL(dl.location_key, -1) END,
            YEAR(@snapshot_date) * 10000 + MONTH(@snapshot_date) * 100 + DAY(@snapshot_date),
            s.ProductID,
            s.LocationID,
            s.quantity,
            c.unit_cost,
            CASE WHEN s.quantity = 0 THEN 0 ELSE CAST(s.quantity * c.unit_cost AS decimal(19,4)) END,
            ISNULL(c.cost_source, 'unknown'),
            s.last_modified_date,
            s.is_zero_stock_row,
            @batch_id,
            @loaded_at
        FROM #stock s
        LEFT JOIN #cost c             ON c.ProductID = s.ProductID
        LEFT JOIN dw.dim_product dp   ON dp.product_id = s.ProductID
        LEFT JOIN dw.dim_location dl  ON dl.location_id = s.LocationID;
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
