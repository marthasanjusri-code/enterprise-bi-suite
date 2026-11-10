/*
  23_fact_sales.sql
  dw.fact_sales: one row per sales order line (D25).
    Source: stg.aw_sales_order_detail + stg.aw_sales_order_header, cost from
    stg.aw_product_cost_history. OLTP dates are used as they are (D19).

  Rules:
    - Keys come from the dimensions by business key; a value that is missing or not
      found gets -1 Unknown (D59). Online orders have no salesperson: -2 "No salesperson".
      Keys are never NULL, except ship_date_key: the source ShipDate may be empty (D102).
    - Date keys are yyyymmdd numbers and must exist in dw.dim_date (foreign keys).
    - Revenue fields (D14): gross_amount = unit price x quantity, discount_amount =
      gross_amount - line_total, line_total = the source LineTotal (after discount,
      before tax and freight). Amounts keep the source's 6 decimals, so totals equal the
      source to the cent.
    - Unit cost (D26): the latest cost period that started on or before the order date.
      Lines ordered after that period ended keep its cost and get is_cost_estimated = 1.
      A line with no period at all gets NULL cost and margin (unknown, D17).
    - order_status is the source status in words, exactly as the source's own function
      dbo.ufnGetSalesOrderStatusText returns it, including '** Invalid **' for any other
      code (D05, D104; definition recorded in fact_sales_checks.sql). All orders are Shipped
      today; Rejected and Cancelled are excluded by the revenue measure, not removed here (D28).
    - Full reload (D76): empty and reload in one transaction. If anything fails, the
      transaction is rolled back and the table keeps the last good load (D77).
      The procedure opens its own transaction only when the caller has none; inside a
      caller's transaction it leaves commit and rollback to the caller (a procedure that
      rolls back its caller's transaction makes SQL Server raise error 266).
    - The load refuses to run when the staging order lines or headers are empty, so an
      empty staging can never empty the fact (D106; the pipeline check D100 comes first).
  Audit columns: batch_id, loaded_at (D10).
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.fact_sales') IS NULL
CREATE TABLE dw.fact_sales (
    sales_order_line_id   int            NOT NULL CONSTRAINT pk_fact_sales PRIMARY KEY,
    sales_order_id        int            NOT NULL,
    sales_order_number    nvarchar(25)   NOT NULL,
    order_date_key        int            NOT NULL CONSTRAINT fk_fact_sales_order_date REFERENCES dw.dim_date (date_key),
    due_date_key          int            NOT NULL CONSTRAINT fk_fact_sales_due_date   REFERENCES dw.dim_date (date_key),
    ship_date_key         int            NULL     CONSTRAINT fk_fact_sales_ship_date  REFERENCES dw.dim_date (date_key),
    product_key           int            NOT NULL CONSTRAINT fk_fact_sales_product     REFERENCES dw.dim_product (product_key),
    customer_key          int            NOT NULL CONSTRAINT fk_fact_sales_customer    REFERENCES dw.dim_customer (customer_key),
    salesperson_key       int            NOT NULL CONSTRAINT fk_fact_sales_salesperson REFERENCES dw.dim_employee (employee_key),
    territory_key         int            NOT NULL CONSTRAINT fk_fact_sales_territory   REFERENCES dw.dim_territory (territory_key),
    promotion_key         int            NOT NULL CONSTRAINT fk_fact_sales_promotion   REFERENCES dw.dim_promotion (promotion_key),
    ship_method_key       int            NOT NULL CONSTRAINT fk_fact_sales_ship_method REFERENCES dw.dim_ship_method (ship_method_key),
    channel               varchar(10)    NOT NULL,
    order_status          varchar(15)    NOT NULL,
    order_qty             smallint       NOT NULL,
    unit_price            money          NOT NULL,
    discount_pct          decimal(9,4)   NOT NULL,
    gross_amount          decimal(19,6)  NOT NULL,
    discount_amount       decimal(19,6)  NOT NULL,
    line_total            decimal(19,6)  NOT NULL,
    unit_cost             money          NULL,
    cost_amount           decimal(19,6)  NULL,
    gross_margin          decimal(19,6)  NULL,
    is_cost_estimated     bit            NOT NULL,
    batch_id              int            NOT NULL,
    loaded_at             datetime2(0)   NOT NULL
);
GO

CREATE OR ALTER PROCEDURE etl.load_fact_sales
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_written int,
            @loaded_at datetime2(0) = SYSDATETIME(),
            @own_tran bit = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.fact_sales', @log_id OUTPUT;

        SET @rows_read = (SELECT COUNT(*) FROM stg.aw_sales_order_detail);

        IF @rows_read = 0 OR NOT EXISTS (SELECT 1 FROM stg.aw_sales_order_header)
            THROW 50002, 'Staging sales order lines or headers are empty; dw.fact_sales was not changed.', 1;

        IF @own_tran = 1 BEGIN TRANSACTION;

        TRUNCATE TABLE dw.fact_sales;

        INSERT INTO dw.fact_sales (
            sales_order_line_id, sales_order_id, sales_order_number,
            order_date_key, due_date_key, ship_date_key,
            product_key, customer_key, salesperson_key, territory_key, promotion_key, ship_method_key,
            channel, order_status, order_qty, unit_price, discount_pct,
            gross_amount, discount_amount, line_total,
            unit_cost, cost_amount, gross_margin, is_cost_estimated,
            batch_id, loaded_at)
        SELECT
            d.SalesOrderDetailID,
            d.SalesOrderID,
            h.SalesOrderNumber,
            YEAR(h.OrderDate) * 10000 + MONTH(h.OrderDate) * 100 + DAY(h.OrderDate),
            YEAR(h.DueDate)   * 10000 + MONTH(h.DueDate)   * 100 + DAY(h.DueDate),
            YEAR(h.ShipDate)  * 10000 + MONTH(h.ShipDate)  * 100 + DAY(h.ShipDate),   -- NULL when not shipped (D102)
            ISNULL(dp.product_key, -1),
            ISNULL(dc.customer_key, -1),
            CASE WHEN h.SalesPersonID IS NULL AND h.OnlineOrderFlag = 1 THEN -2      -- online: no salesperson
                 ELSE ISNULL(de.employee_key, -1) END,
            ISNULL(dt.territory_key, -1),
            ISNULL(dpr.promotion_key, -1),
            ISNULL(ds.ship_method_key, -1),
            CASE WHEN h.OnlineOrderFlag = 1 THEN 'Online' ELSE 'Reseller' END,
            CASE h.Status WHEN 1 THEN 'In process' WHEN 2 THEN 'Approved' WHEN 3 THEN 'Backordered'
                          WHEN 4 THEN 'Rejected'   WHEN 5 THEN 'Shipped'  WHEN 6 THEN 'Cancelled'
                          ELSE '** Invalid **' END,
            d.OrderQty,
            d.UnitPrice,
            d.UnitPriceDiscount,
            CAST(d.UnitPrice * d.OrderQty AS decimal(19,6)),
            CAST(d.UnitPrice * d.OrderQty AS decimal(19,6)) - CAST(d.LineTotal AS decimal(19,6)),
            CAST(d.LineTotal AS decimal(19,6)),
            c.StandardCost,
            CAST(c.StandardCost * d.OrderQty AS decimal(19,6)),
            CAST(d.LineTotal AS decimal(19,6)) - CAST(c.StandardCost * d.OrderQty AS decimal(19,6)),
            CAST(CASE WHEN c.EndDate IS NOT NULL AND h.OrderDate > c.EndDate THEN 1 ELSE 0 END AS bit),
            @batch_id,
            @loaded_at
        FROM stg.aw_sales_order_detail d
        JOIN stg.aw_sales_order_header h ON h.SalesOrderID = d.SalesOrderID
        LEFT JOIN dw.dim_product dp      ON dp.product_id = d.ProductID
        LEFT JOIN dw.dim_customer dc     ON dc.customer_id = h.CustomerID
        LEFT JOIN dw.dim_employee de     ON de.employee_id = h.SalesPersonID
        LEFT JOIN dw.dim_territory dt    ON dt.territory_code = CAST(h.TerritoryID AS varchar(60))
        LEFT JOIN dw.dim_promotion dpr   ON dpr.promotion_id = d.SpecialOfferID
        LEFT JOIN dw.dim_ship_method ds  ON ds.ship_method_id = h.ShipMethodID
        OUTER APPLY (
            SELECT TOP (1) ch.StandardCost, ch.EndDate
            FROM stg.aw_product_cost_history ch
            WHERE ch.ProductID = d.ProductID
              AND ch.StartDate <= h.OrderDate
            ORDER BY ch.StartDate DESC
        ) c;
        SET @rows_written = @@ROWCOUNT;

        IF @own_tran = 1 COMMIT TRANSACTION;

        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        IF @own_tran = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL AND XACT_STATE() <> -1      -- a doomed caller transaction cannot be written to
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
