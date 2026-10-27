/*
  01_source_profiling.sql
  Profiling of the two source databases before designing the warehouse.

    AdventureWorks2025    operational source (sales, HR, purchasing, production)
    AdventureWorksDW2025  finance source (FactFinance) and reference tables

  Read-only. Results are recorded in docs/source_inventory.xlsx.
*/


-- =====================================================================
-- Table row counts
-- =====================================================================

-- sys.partitions gives row counts without scanning each table.
-- index_id 0 or 1 = heap or clustered index, so each table is counted once.
USE AdventureWorks2025;
GO

SELECT  s.name      AS schema_name,
        t.name      AS table_name,
        SUM(p.rows) AS row_count
FROM sys.tables t
JOIN sys.schemas s    ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id
                     AND p.index_id IN (0, 1)
GROUP BY s.name, t.name
ORDER BY s.name, row_count DESC;
GO

USE AdventureWorksDW2025;
GO

SELECT  s.name      AS schema_name,
        t.name      AS table_name,
        SUM(p.rows) AS row_count
FROM sys.tables t
JOIN sys.schemas s    ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id
                     AND p.index_id IN (0, 1)
GROUP BY s.name, t.name
ORDER BY t.name;
GO


-- =====================================================================
-- Foreign keys (operational source)
-- =====================================================================

-- One row per FK column: child.column -> parent.column.
-- Person and dbo schemas skipped; only reached through other tables.
USE AdventureWorks2025;
GO

SELECT  OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.' + OBJECT_NAME(fk.parent_object_id)         AS child_table,
        cp.name                                                                                   AS child_column,
        OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.' + OBJECT_NAME(fk.referenced_object_id) AS parent_table,
        cr.name                                                                                   AS parent_column
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
JOIN sys.columns cp ON cp.object_id = fkc.parent_object_id
                   AND cp.column_id = fkc.parent_column_id
JOIN sys.columns cr ON cr.object_id = fkc.referenced_object_id
                   AND cr.column_id = fkc.referenced_column_id
WHERE OBJECT_SCHEMA_NAME(fk.parent_object_id) IN ('Sales', 'HumanResources', 'Purchasing', 'Production')
ORDER BY child_table, child_column;
GO


-- =====================================================================
-- Column inventory (both databases)
-- =====================================================================

-- Base tables only (views excluded). Exported to the inventory workbook.
SELECT  'AdventureWorks2025'       AS database_name,
        c.TABLE_SCHEMA             AS schema_name,
        c.TABLE_NAME               AS table_name,
        c.ORDINAL_POSITION         AS column_order,
        c.COLUMN_NAME              AS column_name,
        c.DATA_TYPE                AS data_type,
        c.CHARACTER_MAXIMUM_LENGTH AS max_length,
        c.IS_NULLABLE              AS is_nullable
FROM AdventureWorks2025.INFORMATION_SCHEMA.COLUMNS c
JOIN AdventureWorks2025.INFORMATION_SCHEMA.TABLES t
  ON t.TABLE_SCHEMA = c.TABLE_SCHEMA
 AND t.TABLE_NAME   = c.TABLE_NAME
WHERE t.TABLE_TYPE = 'BASE TABLE'

UNION ALL

SELECT  'AdventureWorksDW2025',
        c.TABLE_SCHEMA, c.TABLE_NAME, c.ORDINAL_POSITION,
        c.COLUMN_NAME, c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH, c.IS_NULLABLE
FROM AdventureWorksDW2025.INFORMATION_SCHEMA.COLUMNS c
JOIN AdventureWorksDW2025.INFORMATION_SCHEMA.TABLES t
  ON t.TABLE_SCHEMA = c.TABLE_SCHEMA
 AND t.TABLE_NAME   = c.TABLE_NAME
WHERE t.TABLE_TYPE = 'BASE TABLE'

ORDER BY database_name, schema_name, table_name, column_order;
GO


-- =====================================================================
-- Check: is TransactionHistoryArchive a duplicate of TransactionHistory?
-- =====================================================================

-- Result (27 Oct 2026): date and ID ranges do not overlap, 0 shared IDs.
-- Archive = older history (2022-04 to 2024-07), not a duplicate.
USE AdventureWorks2025;
GO

SELECT  'TransactionHistory'  AS source_table,
        COUNT(*)              AS row_count,
        MIN(TransactionDate)  AS first_date,
        MAX(TransactionDate)  AS last_date,
        MIN(TransactionID)    AS first_id,
        MAX(TransactionID)    AS last_id
FROM Production.TransactionHistory
UNION ALL
SELECT  'TransactionHistoryArchive',
        COUNT(*), MIN(TransactionDate), MAX(TransactionDate),
        MIN(TransactionID), MAX(TransactionID)
FROM Production.TransactionHistoryArchive;

SELECT COUNT(*) AS shared_ids
FROM Production.TransactionHistory th
JOIN Production.TransactionHistoryArchive a
  ON a.TransactionID = th.TransactionID;
GO


-- =====================================================================
-- Check: grain of sales reason tables (27,647 vs 64,515 rows)
-- =====================================================================

-- OLTP table is keyed by order; DW table is keyed by order line.
SELECT  'AdventureWorks2025.Sales.SalesOrderHeaderSalesReason' AS source_table,
        COUNT(*)                     AS row_count,
        COUNT(DISTINCT SalesOrderID) AS distinct_orders
FROM AdventureWorks2025.Sales.SalesOrderHeaderSalesReason;

SELECT  'AdventureWorksDW2025.dbo.FactInternetSalesReason' AS source_table,
        COUNT(*)                         AS row_count,
        COUNT(DISTINCT SalesOrderNumber) AS distinct_orders,
        COUNT(DISTINCT CONCAT(SalesOrderNumber, '-', SalesOrderLineNumber)) AS distinct_order_lines
FROM AdventureWorksDW2025.dbo.FactInternetSalesReason;
GO