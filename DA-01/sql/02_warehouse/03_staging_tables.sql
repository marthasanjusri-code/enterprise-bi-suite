/*
  03_staging_tables.sql
  Creates the 36 staging tables in schema stg.
    stg.aw_<table>    copies from AdventureWorks2025
    stg.awdw_<table>  copies from AdventureWorksDW2025
  Only the columns in use are copied; personal data is excluded.
  Columns keep their source names and exact source types. No keys or
  constraints: staging accepts the source data as it is.
  OrganizationNode (hierarchyid) is stored as text, with its parent's path.
  Every table has batch_id and loaded_at (which run loaded the row, and when).
  Safe to re-run: tables are dropped and recreated (staging holds no
  lasting data).
*/

USE EnterpriseBI_DW;
GO

-- AdventureWorks2025.Sales.SalesOrderHeader
DROP TABLE IF EXISTS stg.aw_sales_order_header;
CREATE TABLE stg.aw_sales_order_header (
    SalesOrderID                   int NULL,
    SalesOrderNumber               nvarchar(25) NULL,
    OrderDate                      datetime NULL,
    DueDate                        datetime NULL,
    ShipDate                       datetime NULL,
    Status                         tinyint NULL,
    OnlineOrderFlag                bit NULL,
    CustomerID                     int NULL,
    SalesPersonID                  int NULL,
    TerritoryID                    int NULL,
    ShipMethodID                   int NULL,
    SubTotal                       money NULL,
    ModifiedDate                   datetime NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Sales.SalesOrderDetail
DROP TABLE IF EXISTS stg.aw_sales_order_detail;
CREATE TABLE stg.aw_sales_order_detail (
    SalesOrderID                   int NULL,
    SalesOrderDetailID             int NULL,
    ProductID                      int NULL,
    SpecialOfferID                 int NULL,
    OrderQty                       smallint NULL,
    UnitPrice                      money NULL,
    UnitPriceDiscount              money NULL,
    LineTotal                      numeric(38,6) NULL,
    ModifiedDate                   datetime NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Sales.Customer
DROP TABLE IF EXISTS stg.aw_customer;
CREATE TABLE stg.aw_customer (
    CustomerID                     int NULL,
    PersonID                       int NULL,
    StoreID                        int NULL,
    TerritoryID                    int NULL,
    AccountNumber                  varchar(10) NULL,
    ModifiedDate                   datetime NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Sales.Store
DROP TABLE IF EXISTS stg.aw_store;
CREATE TABLE stg.aw_store (
    BusinessEntityID               int NULL,
    [Name]                         nvarchar(50) NULL,
    SalesPersonID                  int NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Sales.SalesTerritory
DROP TABLE IF EXISTS stg.aw_sales_territory;
CREATE TABLE stg.aw_sales_territory (
    TerritoryID                    int NULL,
    [Name]                         nvarchar(50) NULL,
    CountryRegionCode              nvarchar(3) NULL,
    [Group]                        nvarchar(50) NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Sales.SalesPerson
DROP TABLE IF EXISTS stg.aw_sales_person;
CREATE TABLE stg.aw_sales_person (
    BusinessEntityID               int NULL,
    TerritoryID                    int NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Sales.SalesPersonQuotaHistory
DROP TABLE IF EXISTS stg.aw_sales_person_quota_history;
CREATE TABLE stg.aw_sales_person_quota_history (
    BusinessEntityID               int NULL,
    QuotaDate                      datetime NULL,
    SalesQuota                     money NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Sales.SalesTerritoryHistory
DROP TABLE IF EXISTS stg.aw_sales_territory_history;
CREATE TABLE stg.aw_sales_territory_history (
    BusinessEntityID               int NULL,
    TerritoryID                    int NULL,
    StartDate                      datetime NULL,
    EndDate                        datetime NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Sales.SpecialOffer
DROP TABLE IF EXISTS stg.aw_special_offer;
CREATE TABLE stg.aw_special_offer (
    SpecialOfferID                 int NULL,
    [Description]                  nvarchar(255) NULL,
    [Type]                         nvarchar(50) NULL,
    Category                       nvarchar(50) NULL,
    DiscountPct                    smallmoney NULL,
    StartDate                      datetime NULL,
    EndDate                        datetime NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Person.Person
DROP TABLE IF EXISTS stg.aw_person;
CREATE TABLE stg.aw_person (
    BusinessEntityID               int NULL,
    PersonType                     nchar(2) NULL,
    FirstName                      nvarchar(50) NULL,
    LastName                       nvarchar(50) NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Person.CountryRegion
DROP TABLE IF EXISTS stg.aw_country_region;
CREATE TABLE stg.aw_country_region (
    CountryRegionCode              nvarchar(3) NULL,
    [Name]                         nvarchar(50) NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.HumanResources.Employee
DROP TABLE IF EXISTS stg.aw_employee;
CREATE TABLE stg.aw_employee (
    BusinessEntityID               int NULL,
    OrganizationNode               nvarchar(4000) NULL,
    ParentOrganizationNode         nvarchar(4000) NULL,
    OrganizationLevel              smallint NULL,
    JobTitle                       nvarchar(50) NULL,
    BirthDate                      date NULL,
    Gender                         nchar(1) NULL,
    SalariedFlag                   bit NULL,
    HireDate                       date NULL,
    VacationHours                  smallint NULL,
    SickLeaveHours                 smallint NULL,
    CurrentFlag                    bit NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.HumanResources.EmployeeDepartmentHistory
DROP TABLE IF EXISTS stg.aw_employee_department_history;
CREATE TABLE stg.aw_employee_department_history (
    BusinessEntityID               int NULL,
    DepartmentID                   smallint NULL,
    ShiftID                        tinyint NULL,
    StartDate                      date NULL,
    EndDate                        date NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.HumanResources.EmployeePayHistory
DROP TABLE IF EXISTS stg.aw_employee_pay_history;
CREATE TABLE stg.aw_employee_pay_history (
    BusinessEntityID               int NULL,
    RateChangeDate                 datetime NULL,
    Rate                           money NULL,
    PayFrequency                   tinyint NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.HumanResources.Department
DROP TABLE IF EXISTS stg.aw_department;
CREATE TABLE stg.aw_department (
    DepartmentID                   smallint NULL,
    [Name]                         nvarchar(50) NULL,
    GroupName                      nvarchar(50) NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.HumanResources.Shift
DROP TABLE IF EXISTS stg.aw_shift;
CREATE TABLE stg.aw_shift (
    ShiftID                        tinyint NULL,
    [Name]                         nvarchar(50) NULL,
    StartTime                      time(7) NULL,
    EndTime                        time(7) NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Production.Product
DROP TABLE IF EXISTS stg.aw_product;
CREATE TABLE stg.aw_product (
    ProductID                      int NULL,
    [Name]                         nvarchar(50) NULL,
    ProductNumber                  nvarchar(25) NULL,
    MakeFlag                       bit NULL,
    FinishedGoodsFlag              bit NULL,
    Color                          nvarchar(15) NULL,
    SafetyStockLevel               smallint NULL,
    ReorderPoint                   smallint NULL,
    StandardCost                   money NULL,
    ListPrice                      money NULL,
    Size                           nvarchar(5) NULL,
    ProductLine                    nchar(2) NULL,
    Class                          nchar(2) NULL,
    Style                          nchar(2) NULL,
    ProductSubcategoryID           int NULL,
    SellStartDate                  datetime NULL,
    SellEndDate                    datetime NULL,
    ModifiedDate                   datetime NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Production.ProductSubcategory
DROP TABLE IF EXISTS stg.aw_product_subcategory;
CREATE TABLE stg.aw_product_subcategory (
    ProductSubcategoryID           int NULL,
    ProductCategoryID              int NULL,
    [Name]                         nvarchar(50) NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Production.ProductCategory
DROP TABLE IF EXISTS stg.aw_product_category;
CREATE TABLE stg.aw_product_category (
    ProductCategoryID              int NULL,
    [Name]                         nvarchar(50) NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Production.ProductCostHistory
DROP TABLE IF EXISTS stg.aw_product_cost_history;
CREATE TABLE stg.aw_product_cost_history (
    ProductID                      int NULL,
    StartDate                      datetime NULL,
    EndDate                        datetime NULL,
    StandardCost                   money NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Production.ProductInventory
DROP TABLE IF EXISTS stg.aw_product_inventory;
CREATE TABLE stg.aw_product_inventory (
    ProductID                      int NULL,
    LocationID                     smallint NULL,
    Quantity                       smallint NULL,
    ModifiedDate                   datetime NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Production.Location
DROP TABLE IF EXISTS stg.aw_location;
CREATE TABLE stg.aw_location (
    LocationID                     smallint NULL,
    [Name]                         nvarchar(50) NULL,
    CostRate                       smallmoney NULL,
    Availability                   decimal(8,2) NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Production.WorkOrder
DROP TABLE IF EXISTS stg.aw_work_order;
CREATE TABLE stg.aw_work_order (
    WorkOrderID                    int NULL,
    ProductID                      int NULL,
    OrderQty                       int NULL,
    StockedQty                     int NULL,
    ScrappedQty                    smallint NULL,
    StartDate                      datetime NULL,
    EndDate                        datetime NULL,
    DueDate                        datetime NULL,
    ScrapReasonID                  smallint NULL,
    ModifiedDate                   datetime NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Production.ScrapReason
DROP TABLE IF EXISTS stg.aw_scrap_reason;
CREATE TABLE stg.aw_scrap_reason (
    ScrapReasonID                  smallint NULL,
    [Name]                         nvarchar(50) NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Purchasing.PurchaseOrderHeader
DROP TABLE IF EXISTS stg.aw_purchase_order_header;
CREATE TABLE stg.aw_purchase_order_header (
    PurchaseOrderID                int NULL,
    Status                         tinyint NULL,
    EmployeeID                     int NULL,
    VendorID                       int NULL,
    ShipMethodID                   int NULL,
    OrderDate                      datetime NULL,
    ShipDate                       datetime NULL,
    SubTotal                       money NULL,
    Freight                        money NULL,
    ModifiedDate                   datetime NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Purchasing.PurchaseOrderDetail
DROP TABLE IF EXISTS stg.aw_purchase_order_detail;
CREATE TABLE stg.aw_purchase_order_detail (
    PurchaseOrderID                int NULL,
    PurchaseOrderDetailID          int NULL,
    DueDate                        datetime NULL,
    OrderQty                       smallint NULL,
    ProductID                      int NULL,
    UnitPrice                      money NULL,
    LineTotal                      money NULL,
    ReceivedQty                    decimal(8,2) NULL,
    RejectedQty                    decimal(8,2) NULL,
    StockedQty                     decimal(9,2) NULL,
    ModifiedDate                   datetime NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Purchasing.Vendor
DROP TABLE IF EXISTS stg.aw_vendor;
CREATE TABLE stg.aw_vendor (
    BusinessEntityID               int NULL,
    [Name]                         nvarchar(50) NULL,
    CreditRating                   tinyint NULL,
    PreferredVendorStatus          bit NULL,
    ActiveFlag                     bit NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Purchasing.ProductVendor
DROP TABLE IF EXISTS stg.aw_product_vendor;
CREATE TABLE stg.aw_product_vendor (
    ProductID                      int NULL,
    BusinessEntityID               int NULL,
    AverageLeadTime                int NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorks2025.Purchasing.ShipMethod
DROP TABLE IF EXISTS stg.aw_ship_method;
CREATE TABLE stg.aw_ship_method (
    ShipMethodID                   int NULL,
    [Name]                         nvarchar(50) NULL,
    ShipBase                       money NULL,
    ShipRate                       money NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorksDW2025.dbo.FactFinance
DROP TABLE IF EXISTS stg.awdw_fact_finance;
CREATE TABLE stg.awdw_fact_finance (
    FinanceKey                     int NULL,
    DateKey                        int NULL,
    OrganizationKey                int NULL,
    DepartmentGroupKey             int NULL,
    ScenarioKey                    int NULL,
    AccountKey                     int NULL,
    Amount                         float NULL,
    [Date]                         datetime NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorksDW2025.dbo.DimAccount
DROP TABLE IF EXISTS stg.awdw_dim_account;
CREATE TABLE stg.awdw_dim_account (
    AccountKey                     int NULL,
    ParentAccountKey               int NULL,
    AccountCodeAlternateKey        int NULL,
    AccountDescription             nvarchar(50) NULL,
    AccountType                    nvarchar(50) NULL,
    [Operator]                     nvarchar(50) NULL,
    ValueType                      nvarchar(50) NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorksDW2025.dbo.DimOrganization
DROP TABLE IF EXISTS stg.awdw_dim_organization;
CREATE TABLE stg.awdw_dim_organization (
    OrganizationKey                int NULL,
    ParentOrganizationKey          int NULL,
    OrganizationName               nvarchar(50) NULL,
    CurrencyKey                    int NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorksDW2025.dbo.DimDepartmentGroup
DROP TABLE IF EXISTS stg.awdw_dim_department_group;
CREATE TABLE stg.awdw_dim_department_group (
    DepartmentGroupKey             int NULL,
    ParentDepartmentGroupKey       int NULL,
    DepartmentGroupName            nvarchar(50) NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorksDW2025.dbo.DimScenario
DROP TABLE IF EXISTS stg.awdw_dim_scenario;
CREATE TABLE stg.awdw_dim_scenario (
    ScenarioKey                    int NULL,
    ScenarioName                   nvarchar(50) NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorksDW2025.dbo.DimCurrency
DROP TABLE IF EXISTS stg.awdw_dim_currency;
CREATE TABLE stg.awdw_dim_currency (
    CurrencyKey                    int NULL,
    CurrencyAlternateKey           nchar(3) NULL,
    CurrencyName                   nvarchar(50) NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO

-- AdventureWorksDW2025.dbo.FactCurrencyRate
DROP TABLE IF EXISTS stg.awdw_fact_currency_rate;
CREATE TABLE stg.awdw_fact_currency_rate (
    CurrencyKey                    int NULL,
    [Date]                         datetime NULL,
    AverageRate                    float NULL,
    EndOfDayRate                   float NULL,
    batch_id                       int NOT NULL,
    loaded_at                      datetime2(0) NOT NULL
);
GO
