/*
  04_load_staging.sql
  etl.load_staging: empties and reloads all 36 staging tables for one run.
  Each table is one logged step in etl.load_log with its row count.
  On any error the current step is marked Failed with the error message,
  and the error is raised again so the pipeline stops.
  Person: employees only (types EM and SP); customer names are never copied.
*/

USE EnterpriseBI_DW;
GO

CREATE OR ALTER PROCEDURE etl.load_staging
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id    int,
            @rows      int,
            @loaded_at datetime2(0) = SYSDATETIME();

    BEGIN TRY

        -- AdventureWorks2025.Sales.SalesOrderHeader
        EXEC etl.start_step @batch_id, 'stg.aw_sales_order_header', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_sales_order_header;
        INSERT INTO stg.aw_sales_order_header (SalesOrderID, SalesOrderNumber, OrderDate, DueDate, ShipDate, Status, OnlineOrderFlag, CustomerID, SalesPersonID, TerritoryID, ShipMethodID, SubTotal, ModifiedDate, batch_id, loaded_at)
            SELECT SalesOrderID, SalesOrderNumber, OrderDate, DueDate, ShipDate, Status, OnlineOrderFlag, CustomerID, SalesPersonID, TerritoryID, ShipMethodID, SubTotal, ModifiedDate, @batch_id, @loaded_at
            FROM AdventureWorks2025.Sales.SalesOrderHeader;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Sales.SalesOrderDetail
        EXEC etl.start_step @batch_id, 'stg.aw_sales_order_detail', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_sales_order_detail;
        INSERT INTO stg.aw_sales_order_detail (SalesOrderID, SalesOrderDetailID, ProductID, SpecialOfferID, OrderQty, UnitPrice, UnitPriceDiscount, LineTotal, ModifiedDate, batch_id, loaded_at)
            SELECT SalesOrderID, SalesOrderDetailID, ProductID, SpecialOfferID, OrderQty, UnitPrice, UnitPriceDiscount, LineTotal, ModifiedDate, @batch_id, @loaded_at
            FROM AdventureWorks2025.Sales.SalesOrderDetail;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Sales.Customer
        EXEC etl.start_step @batch_id, 'stg.aw_customer', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_customer;
        INSERT INTO stg.aw_customer (CustomerID, PersonID, StoreID, TerritoryID, AccountNumber, ModifiedDate, batch_id, loaded_at)
            SELECT CustomerID, PersonID, StoreID, TerritoryID, AccountNumber, ModifiedDate, @batch_id, @loaded_at
            FROM AdventureWorks2025.Sales.Customer;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Sales.Store
        EXEC etl.start_step @batch_id, 'stg.aw_store', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_store;
        INSERT INTO stg.aw_store (BusinessEntityID, [Name], SalesPersonID, batch_id, loaded_at)
            SELECT BusinessEntityID, [Name], SalesPersonID, @batch_id, @loaded_at
            FROM AdventureWorks2025.Sales.Store;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Sales.SalesTerritory
        EXEC etl.start_step @batch_id, 'stg.aw_sales_territory', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_sales_territory;
        INSERT INTO stg.aw_sales_territory (TerritoryID, [Name], CountryRegionCode, [Group], batch_id, loaded_at)
            SELECT TerritoryID, [Name], CountryRegionCode, [Group], @batch_id, @loaded_at
            FROM AdventureWorks2025.Sales.SalesTerritory;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Sales.SalesPerson
        EXEC etl.start_step @batch_id, 'stg.aw_sales_person', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_sales_person;
        INSERT INTO stg.aw_sales_person (BusinessEntityID, TerritoryID, batch_id, loaded_at)
            SELECT BusinessEntityID, TerritoryID, @batch_id, @loaded_at
            FROM AdventureWorks2025.Sales.SalesPerson;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Sales.SalesPersonQuotaHistory
        EXEC etl.start_step @batch_id, 'stg.aw_sales_person_quota_history', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_sales_person_quota_history;
        INSERT INTO stg.aw_sales_person_quota_history (BusinessEntityID, QuotaDate, SalesQuota, batch_id, loaded_at)
            SELECT BusinessEntityID, QuotaDate, SalesQuota, @batch_id, @loaded_at
            FROM AdventureWorks2025.Sales.SalesPersonQuotaHistory;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Sales.SalesTerritoryHistory
        EXEC etl.start_step @batch_id, 'stg.aw_sales_territory_history', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_sales_territory_history;
        INSERT INTO stg.aw_sales_territory_history (BusinessEntityID, TerritoryID, StartDate, EndDate, batch_id, loaded_at)
            SELECT BusinessEntityID, TerritoryID, StartDate, EndDate, @batch_id, @loaded_at
            FROM AdventureWorks2025.Sales.SalesTerritoryHistory;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Sales.SpecialOffer
        EXEC etl.start_step @batch_id, 'stg.aw_special_offer', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_special_offer;
        INSERT INTO stg.aw_special_offer (SpecialOfferID, [Description], [Type], Category, DiscountPct, StartDate, EndDate, batch_id, loaded_at)
            SELECT SpecialOfferID, [Description], [Type], Category, DiscountPct, StartDate, EndDate, @batch_id, @loaded_at
            FROM AdventureWorks2025.Sales.SpecialOffer;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Person.Person
        EXEC etl.start_step @batch_id, 'stg.aw_person', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_person;
        INSERT INTO stg.aw_person (BusinessEntityID, PersonType, FirstName, LastName, batch_id, loaded_at)
            SELECT BusinessEntityID, PersonType, FirstName, LastName, @batch_id, @loaded_at
            FROM AdventureWorks2025.Person.Person
            WHERE PersonType IN ('EM', 'SP');
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Person.CountryRegion
        EXEC etl.start_step @batch_id, 'stg.aw_country_region', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_country_region;
        INSERT INTO stg.aw_country_region (CountryRegionCode, [Name], batch_id, loaded_at)
            SELECT CountryRegionCode, [Name], @batch_id, @loaded_at
            FROM AdventureWorks2025.Person.CountryRegion;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.HumanResources.Employee
        EXEC etl.start_step @batch_id, 'stg.aw_employee', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_employee;
        INSERT INTO stg.aw_employee (BusinessEntityID, OrganizationNode, ParentOrganizationNode, OrganizationLevel, JobTitle, BirthDate, Gender, SalariedFlag, HireDate, VacationHours, SickLeaveHours, CurrentFlag, batch_id, loaded_at)
            SELECT BusinessEntityID, OrganizationNode.ToString(), OrganizationNode.GetAncestor(1).ToString(), OrganizationLevel, JobTitle, BirthDate, Gender, SalariedFlag, HireDate, VacationHours, SickLeaveHours, CurrentFlag, @batch_id, @loaded_at
            FROM AdventureWorks2025.HumanResources.Employee;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.HumanResources.EmployeeDepartmentHistory
        EXEC etl.start_step @batch_id, 'stg.aw_employee_department_history', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_employee_department_history;
        INSERT INTO stg.aw_employee_department_history (BusinessEntityID, DepartmentID, ShiftID, StartDate, EndDate, batch_id, loaded_at)
            SELECT BusinessEntityID, DepartmentID, ShiftID, StartDate, EndDate, @batch_id, @loaded_at
            FROM AdventureWorks2025.HumanResources.EmployeeDepartmentHistory;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.HumanResources.EmployeePayHistory
        EXEC etl.start_step @batch_id, 'stg.aw_employee_pay_history', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_employee_pay_history;
        INSERT INTO stg.aw_employee_pay_history (BusinessEntityID, RateChangeDate, Rate, PayFrequency, batch_id, loaded_at)
            SELECT BusinessEntityID, RateChangeDate, Rate, PayFrequency, @batch_id, @loaded_at
            FROM AdventureWorks2025.HumanResources.EmployeePayHistory;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.HumanResources.Department
        EXEC etl.start_step @batch_id, 'stg.aw_department', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_department;
        INSERT INTO stg.aw_department (DepartmentID, [Name], GroupName, batch_id, loaded_at)
            SELECT DepartmentID, [Name], GroupName, @batch_id, @loaded_at
            FROM AdventureWorks2025.HumanResources.Department;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.HumanResources.Shift
        EXEC etl.start_step @batch_id, 'stg.aw_shift', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_shift;
        INSERT INTO stg.aw_shift (ShiftID, [Name], StartTime, EndTime, batch_id, loaded_at)
            SELECT ShiftID, [Name], StartTime, EndTime, @batch_id, @loaded_at
            FROM AdventureWorks2025.HumanResources.Shift;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Production.Product
        EXEC etl.start_step @batch_id, 'stg.aw_product', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_product;
        INSERT INTO stg.aw_product (ProductID, [Name], ProductNumber, MakeFlag, FinishedGoodsFlag, Color, SafetyStockLevel, ReorderPoint, StandardCost, ListPrice, Size, ProductLine, Class, Style, ProductSubcategoryID, SellStartDate, SellEndDate, ModifiedDate, batch_id, loaded_at)
            SELECT ProductID, [Name], ProductNumber, MakeFlag, FinishedGoodsFlag, Color, SafetyStockLevel, ReorderPoint, StandardCost, ListPrice, Size, ProductLine, Class, Style, ProductSubcategoryID, SellStartDate, SellEndDate, ModifiedDate, @batch_id, @loaded_at
            FROM AdventureWorks2025.Production.Product;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Production.ProductSubcategory
        EXEC etl.start_step @batch_id, 'stg.aw_product_subcategory', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_product_subcategory;
        INSERT INTO stg.aw_product_subcategory (ProductSubcategoryID, ProductCategoryID, [Name], batch_id, loaded_at)
            SELECT ProductSubcategoryID, ProductCategoryID, [Name], @batch_id, @loaded_at
            FROM AdventureWorks2025.Production.ProductSubcategory;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Production.ProductCategory
        EXEC etl.start_step @batch_id, 'stg.aw_product_category', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_product_category;
        INSERT INTO stg.aw_product_category (ProductCategoryID, [Name], batch_id, loaded_at)
            SELECT ProductCategoryID, [Name], @batch_id, @loaded_at
            FROM AdventureWorks2025.Production.ProductCategory;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Production.ProductCostHistory
        EXEC etl.start_step @batch_id, 'stg.aw_product_cost_history', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_product_cost_history;
        INSERT INTO stg.aw_product_cost_history (ProductID, StartDate, EndDate, StandardCost, batch_id, loaded_at)
            SELECT ProductID, StartDate, EndDate, StandardCost, @batch_id, @loaded_at
            FROM AdventureWorks2025.Production.ProductCostHistory;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Production.ProductInventory
        EXEC etl.start_step @batch_id, 'stg.aw_product_inventory', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_product_inventory;
        INSERT INTO stg.aw_product_inventory (ProductID, LocationID, Quantity, ModifiedDate, batch_id, loaded_at)
            SELECT ProductID, LocationID, Quantity, ModifiedDate, @batch_id, @loaded_at
            FROM AdventureWorks2025.Production.ProductInventory;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Production.Location
        EXEC etl.start_step @batch_id, 'stg.aw_location', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_location;
        INSERT INTO stg.aw_location (LocationID, [Name], CostRate, Availability, batch_id, loaded_at)
            SELECT LocationID, [Name], CostRate, Availability, @batch_id, @loaded_at
            FROM AdventureWorks2025.Production.Location;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Production.WorkOrder
        EXEC etl.start_step @batch_id, 'stg.aw_work_order', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_work_order;
        INSERT INTO stg.aw_work_order (WorkOrderID, ProductID, OrderQty, StockedQty, ScrappedQty, StartDate, EndDate, DueDate, ScrapReasonID, ModifiedDate, batch_id, loaded_at)
            SELECT WorkOrderID, ProductID, OrderQty, StockedQty, ScrappedQty, StartDate, EndDate, DueDate, ScrapReasonID, ModifiedDate, @batch_id, @loaded_at
            FROM AdventureWorks2025.Production.WorkOrder;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Production.ScrapReason
        EXEC etl.start_step @batch_id, 'stg.aw_scrap_reason', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_scrap_reason;
        INSERT INTO stg.aw_scrap_reason (ScrapReasonID, [Name], batch_id, loaded_at)
            SELECT ScrapReasonID, [Name], @batch_id, @loaded_at
            FROM AdventureWorks2025.Production.ScrapReason;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Purchasing.PurchaseOrderHeader
        EXEC etl.start_step @batch_id, 'stg.aw_purchase_order_header', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_purchase_order_header;
        INSERT INTO stg.aw_purchase_order_header (PurchaseOrderID, Status, EmployeeID, VendorID, ShipMethodID, OrderDate, ShipDate, SubTotal, Freight, ModifiedDate, batch_id, loaded_at)
            SELECT PurchaseOrderID, Status, EmployeeID, VendorID, ShipMethodID, OrderDate, ShipDate, SubTotal, Freight, ModifiedDate, @batch_id, @loaded_at
            FROM AdventureWorks2025.Purchasing.PurchaseOrderHeader;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Purchasing.PurchaseOrderDetail
        EXEC etl.start_step @batch_id, 'stg.aw_purchase_order_detail', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_purchase_order_detail;
        INSERT INTO stg.aw_purchase_order_detail (PurchaseOrderID, PurchaseOrderDetailID, DueDate, OrderQty, ProductID, UnitPrice, LineTotal, ReceivedQty, RejectedQty, StockedQty, ModifiedDate, batch_id, loaded_at)
            SELECT PurchaseOrderID, PurchaseOrderDetailID, DueDate, OrderQty, ProductID, UnitPrice, LineTotal, ReceivedQty, RejectedQty, StockedQty, ModifiedDate, @batch_id, @loaded_at
            FROM AdventureWorks2025.Purchasing.PurchaseOrderDetail;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Purchasing.Vendor
        EXEC etl.start_step @batch_id, 'stg.aw_vendor', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_vendor;
        INSERT INTO stg.aw_vendor (BusinessEntityID, [Name], CreditRating, PreferredVendorStatus, ActiveFlag, batch_id, loaded_at)
            SELECT BusinessEntityID, [Name], CreditRating, PreferredVendorStatus, ActiveFlag, @batch_id, @loaded_at
            FROM AdventureWorks2025.Purchasing.Vendor;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Purchasing.ProductVendor
        EXEC etl.start_step @batch_id, 'stg.aw_product_vendor', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_product_vendor;
        INSERT INTO stg.aw_product_vendor (ProductID, BusinessEntityID, AverageLeadTime, batch_id, loaded_at)
            SELECT ProductID, BusinessEntityID, AverageLeadTime, @batch_id, @loaded_at
            FROM AdventureWorks2025.Purchasing.ProductVendor;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorks2025.Purchasing.ShipMethod
        EXEC etl.start_step @batch_id, 'stg.aw_ship_method', @log_id OUTPUT;
        TRUNCATE TABLE stg.aw_ship_method;
        INSERT INTO stg.aw_ship_method (ShipMethodID, [Name], ShipBase, ShipRate, batch_id, loaded_at)
            SELECT ShipMethodID, [Name], ShipBase, ShipRate, @batch_id, @loaded_at
            FROM AdventureWorks2025.Purchasing.ShipMethod;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorksDW2025.dbo.FactFinance
        EXEC etl.start_step @batch_id, 'stg.awdw_fact_finance', @log_id OUTPUT;
        TRUNCATE TABLE stg.awdw_fact_finance;
        INSERT INTO stg.awdw_fact_finance (FinanceKey, DateKey, OrganizationKey, DepartmentGroupKey, ScenarioKey, AccountKey, Amount, [Date], batch_id, loaded_at)
            SELECT FinanceKey, DateKey, OrganizationKey, DepartmentGroupKey, ScenarioKey, AccountKey, Amount, [Date], @batch_id, @loaded_at
            FROM AdventureWorksDW2025.dbo.FactFinance;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorksDW2025.dbo.DimAccount
        EXEC etl.start_step @batch_id, 'stg.awdw_dim_account', @log_id OUTPUT;
        TRUNCATE TABLE stg.awdw_dim_account;
        INSERT INTO stg.awdw_dim_account (AccountKey, ParentAccountKey, AccountCodeAlternateKey, AccountDescription, AccountType, [Operator], ValueType, batch_id, loaded_at)
            SELECT AccountKey, ParentAccountKey, AccountCodeAlternateKey, AccountDescription, AccountType, [Operator], ValueType, @batch_id, @loaded_at
            FROM AdventureWorksDW2025.dbo.DimAccount;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorksDW2025.dbo.DimOrganization
        EXEC etl.start_step @batch_id, 'stg.awdw_dim_organization', @log_id OUTPUT;
        TRUNCATE TABLE stg.awdw_dim_organization;
        INSERT INTO stg.awdw_dim_organization (OrganizationKey, ParentOrganizationKey, OrganizationName, CurrencyKey, batch_id, loaded_at)
            SELECT OrganizationKey, ParentOrganizationKey, OrganizationName, CurrencyKey, @batch_id, @loaded_at
            FROM AdventureWorksDW2025.dbo.DimOrganization;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorksDW2025.dbo.DimDepartmentGroup
        EXEC etl.start_step @batch_id, 'stg.awdw_dim_department_group', @log_id OUTPUT;
        TRUNCATE TABLE stg.awdw_dim_department_group;
        INSERT INTO stg.awdw_dim_department_group (DepartmentGroupKey, ParentDepartmentGroupKey, DepartmentGroupName, batch_id, loaded_at)
            SELECT DepartmentGroupKey, ParentDepartmentGroupKey, DepartmentGroupName, @batch_id, @loaded_at
            FROM AdventureWorksDW2025.dbo.DimDepartmentGroup;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorksDW2025.dbo.DimScenario
        EXEC etl.start_step @batch_id, 'stg.awdw_dim_scenario', @log_id OUTPUT;
        TRUNCATE TABLE stg.awdw_dim_scenario;
        INSERT INTO stg.awdw_dim_scenario (ScenarioKey, ScenarioName, batch_id, loaded_at)
            SELECT ScenarioKey, ScenarioName, @batch_id, @loaded_at
            FROM AdventureWorksDW2025.dbo.DimScenario;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorksDW2025.dbo.DimCurrency
        EXEC etl.start_step @batch_id, 'stg.awdw_dim_currency', @log_id OUTPUT;
        TRUNCATE TABLE stg.awdw_dim_currency;
        INSERT INTO stg.awdw_dim_currency (CurrencyKey, CurrencyAlternateKey, CurrencyName, batch_id, loaded_at)
            SELECT CurrencyKey, CurrencyAlternateKey, CurrencyName, @batch_id, @loaded_at
            FROM AdventureWorksDW2025.dbo.DimCurrency;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
        SET @log_id = NULL;

        -- AdventureWorksDW2025.dbo.FactCurrencyRate
        EXEC etl.start_step @batch_id, 'stg.awdw_fact_currency_rate', @log_id OUTPUT;
        TRUNCATE TABLE stg.awdw_fact_currency_rate;
        INSERT INTO stg.awdw_fact_currency_rate (CurrencyKey, [Date], AverageRate, EndOfDayRate, batch_id, loaded_at)
            SELECT CurrencyKey, [Date], AverageRate, EndOfDayRate, @batch_id, @loaded_at
            FROM AdventureWorksDW2025.dbo.FactCurrencyRate;
        SET @rows = @@ROWCOUNT;
        EXEC etl.end_step @log_id, 'Succeeded', @rows, @rows;
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
