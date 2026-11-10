/*
  26_fact_purchase.sql
  dw.fact_purchase: one row per purchase order line (8,845 lines, 4,012 orders; purchase checks: check 1).
    Source: stg.aw_purchase_order_detail + stg.aw_purchase_order_header, lead time from
    stg.aw_product_vendor. OLTP dates are used as they are (D19).

  Rules:
    - Keys come from the dimensions by business key; not found -> -1 (D59). Keys are never NULL,
      except ship_date_key: the source ShipDate may be empty (D102). 0 missing today (check 5).
      buyer_key = the employee who placed the order (EmployeeID).
    - po_status is the text the source function dbo.ufnGetPurchaseOrderStatusText returns:
      1 Pending, 2 Approved, 3 Rejected, 4 Complete, any other code '** Invalid **' (D111).
    - Value measures from quantities, not from status (D42, purchase checks: checks 4 and B):
        ordered_value         = LineTotal (order qty x unit price)
        accepted_value        = stocked qty x unit price   (purchase spend)
        rejected_value        = rejected qty x unit price
        short_delivered_value = (order qty - received qty) x unit price
    - Freight (D44, purchase check D): each line gets its line-total share of the order freight,
      rounded to cents; the order's rounding remainder goes to its largest line, and when lines
      tie for largest (190 orders), to the one with the lowest line ID (D111). The lines of an
      order therefore add up to the header freight exactly.
    - promised_lead_days = the vendor's average lead time for the product (ProductVendor);
      NULL if the pair is missing (0 today, check 6).
    - is_due_date_invalid = 1 when the line is due before the order date (7 lines, D45).
    - Full reload in one transaction (D76, D77); refuses an empty staging and opens its own
      transaction only when the caller has none (D106).
  Audit columns: batch_id, loaded_at (D10).
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.fact_purchase') IS NULL
CREATE TABLE dw.fact_purchase (
    purchase_order_line_id  int            NOT NULL CONSTRAINT pk_fact_purchase PRIMARY KEY,
    purchase_order_id       int            NOT NULL,
    order_date_key          int            NOT NULL CONSTRAINT fk_fact_purchase_order_date  REFERENCES dw.dim_date (date_key),
    due_date_key            int            NOT NULL CONSTRAINT fk_fact_purchase_due_date    REFERENCES dw.dim_date (date_key),
    ship_date_key           int            NULL     CONSTRAINT fk_fact_purchase_ship_date   REFERENCES dw.dim_date (date_key),
    product_key             int            NOT NULL CONSTRAINT fk_fact_purchase_product     REFERENCES dw.dim_product (product_key),
    vendor_key              int            NOT NULL CONSTRAINT fk_fact_purchase_vendor      REFERENCES dw.dim_vendor (vendor_key),
    buyer_key               int            NOT NULL CONSTRAINT fk_fact_purchase_buyer       REFERENCES dw.dim_employee (employee_key),
    ship_method_key         int            NOT NULL CONSTRAINT fk_fact_purchase_ship_method REFERENCES dw.dim_ship_method (ship_method_key),
    po_status               varchar(15)    NOT NULL,
    order_qty               smallint       NOT NULL,
    received_qty            decimal(8,2)   NOT NULL,
    rejected_qty            decimal(8,2)   NOT NULL,
    stocked_qty             decimal(9,2)   NOT NULL,
    unit_price              money          NOT NULL,
    ordered_value           decimal(19,6)  NOT NULL,
    accepted_value          decimal(19,6)  NOT NULL,
    rejected_value          decimal(19,6)  NOT NULL,
    short_delivered_value   decimal(19,6)  NOT NULL,
    freight_allocated       decimal(19,4)  NOT NULL,
    promised_lead_days      int            NULL,
    is_due_date_invalid     bit            NOT NULL,
    batch_id                int            NOT NULL,
    loaded_at               datetime2(0)   NOT NULL
);
GO

CREATE OR ALTER PROCEDURE etl.load_fact_purchase
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_written int,
            @loaded_at datetime2(0) = SYSDATETIME(),
            @own_tran bit = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.fact_purchase', @log_id OUTPUT;

        SET @rows_read = (SELECT COUNT(*) FROM stg.aw_purchase_order_detail);

        IF @rows_read = 0 OR NOT EXISTS (SELECT 1 FROM stg.aw_purchase_order_header)
            THROW 50002, 'Staging purchase order lines or headers are empty; dw.fact_purchase was not changed.', 1;

        -- Freight share of each line, rounded to cents, and which line takes the remainder.
        SELECT  d.PurchaseOrderDetailID,
                ROUND(CAST(d.LineTotal AS decimal(38,10))
                      / NULLIF(SUM(CAST(d.LineTotal AS decimal(38,10))) OVER (PARTITION BY d.PurchaseOrderID), 0)
                      * CAST(h.Freight AS decimal(38,10)), 2)                                   AS freight_share,
                CAST(h.Freight AS decimal(38,10))                                              AS order_freight,
                ROW_NUMBER() OVER (PARTITION BY d.PurchaseOrderID
                                   ORDER BY d.LineTotal DESC, d.PurchaseOrderDetailID ASC)      AS size_rank
        INTO #share
        FROM stg.aw_purchase_order_detail d
        JOIN stg.aw_purchase_order_header h ON h.PurchaseOrderID = d.PurchaseOrderID;

        SELECT  s.PurchaseOrderDetailID,
                CAST(ISNULL(s.freight_share, 0)
                     + CASE WHEN s.size_rank = 1
                            THEN s.order_freight - SUM(ISNULL(s.freight_share, 0)) OVER (PARTITION BY d.PurchaseOrderID)
                            ELSE 0 END AS decimal(19,4))                                        AS freight_allocated
        INTO #freight
        FROM #share s
        JOIN stg.aw_purchase_order_detail d ON d.PurchaseOrderDetailID = s.PurchaseOrderDetailID;

        IF @own_tran = 1 BEGIN TRANSACTION;

        TRUNCATE TABLE dw.fact_purchase;

        INSERT INTO dw.fact_purchase (
            purchase_order_line_id, purchase_order_id, order_date_key, due_date_key, ship_date_key,
            product_key, vendor_key, buyer_key, ship_method_key, po_status,
            order_qty, received_qty, rejected_qty, stocked_qty, unit_price,
            ordered_value, accepted_value, rejected_value, short_delivered_value,
            freight_allocated, promised_lead_days, is_due_date_invalid, batch_id, loaded_at)
        SELECT
            d.PurchaseOrderDetailID,
            d.PurchaseOrderID,
            YEAR(h.OrderDate) * 10000 + MONTH(h.OrderDate) * 100 + DAY(h.OrderDate),
            YEAR(d.DueDate)   * 10000 + MONTH(d.DueDate)   * 100 + DAY(d.DueDate),
            YEAR(h.ShipDate)  * 10000 + MONTH(h.ShipDate)  * 100 + DAY(h.ShipDate),   -- NULL when not shipped (D102)
            ISNULL(dp.product_key, -1),
            ISNULL(dv.vendor_key, -1),
            ISNULL(de.employee_key, -1),
            ISNULL(ds.ship_method_key, -1),
            CASE h.Status WHEN 1 THEN 'Pending' WHEN 2 THEN 'Approved' WHEN 3 THEN 'Rejected'
                          WHEN 4 THEN 'Complete' ELSE '** Invalid **' END,
            d.OrderQty,
            d.ReceivedQty,
            d.RejectedQty,
            d.StockedQty,
            d.UnitPrice,
            CAST(d.LineTotal AS decimal(19,6)),
            CAST(d.StockedQty * d.UnitPrice AS decimal(19,6)),
            CAST(d.RejectedQty * d.UnitPrice AS decimal(19,6)),
            CAST((d.OrderQty - d.ReceivedQty) * d.UnitPrice AS decimal(19,6)),
            f.freight_allocated,
            pv.AverageLeadTime,
            CAST(CASE WHEN d.DueDate < h.OrderDate THEN 1 ELSE 0 END AS bit),
            @batch_id,
            @loaded_at
        FROM stg.aw_purchase_order_detail d
        JOIN stg.aw_purchase_order_header h ON h.PurchaseOrderID = d.PurchaseOrderID
        JOIN #freight f                     ON f.PurchaseOrderDetailID = d.PurchaseOrderDetailID
        LEFT JOIN stg.aw_product_vendor pv  ON pv.ProductID = d.ProductID AND pv.BusinessEntityID = h.VendorID
        LEFT JOIN dw.dim_product dp         ON dp.product_id = d.ProductID
        LEFT JOIN dw.dim_vendor dv          ON dv.vendor_id = h.VendorID
        LEFT JOIN dw.dim_employee de        ON de.employee_id = h.EmployeeID
        LEFT JOIN dw.dim_ship_method ds     ON ds.ship_method_id = h.ShipMethodID;
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
