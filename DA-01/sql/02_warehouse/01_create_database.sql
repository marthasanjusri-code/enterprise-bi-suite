/*
  01_create_database.sql
  Creates the warehouse database EnterpriseBI_DW and its three schemas:
    stg  copies of the source columns in use
    dw   star schema (facts and dimensions)
    etl  load log and data quality results
  Safe to re-run: existing objects are left as they are.
*/

USE master;
GO

IF DB_ID('EnterpriseBI_DW') IS NULL
    CREATE DATABASE EnterpriseBI_DW;
GO

-- The warehouse can always be rebuilt from the sources, so point-in-time
-- restore is not needed. SIMPLE recovery keeps the log file small.
ALTER DATABASE EnterpriseBI_DW SET RECOVERY SIMPLE;
GO

USE EnterpriseBI_DW;
GO

IF SCHEMA_ID('stg') IS NULL EXEC ('CREATE SCHEMA stg');
GO
IF SCHEMA_ID('dw')  IS NULL EXEC ('CREATE SCHEMA dw');
GO
IF SCHEMA_ID('etl') IS NULL EXEC ('CREATE SCHEMA etl');
GO