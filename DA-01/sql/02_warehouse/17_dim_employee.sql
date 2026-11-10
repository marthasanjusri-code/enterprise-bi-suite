/*
  17_dim_employee.sql
  dw.dim_employee: one row per employee, plus special rows. Shared by sales
  (salesperson), purchasing (buyer) and HR. Holds only non-sensitive
  attributes; sensitive ones are in dw.dim_employee_hr (D62).
    - Name = first + last name (staging holds employees only).
    - Current department, department group and shift = the open department period.
    - is_salesperson: in the salesperson table. is_buyer: job title Buyer,
      Purchasing Assistant or Purchasing Manager (the people who place
      purchase orders).
    - manager_key, loaded in a second pass once all employees exist (D90):
        parent path found      -> that employee
        parent path is "/"     -> the top employee (the one with no node)
        top employee           -> NULL (no parent: root of the hierarchy)
        parent path not found  -> -1 (Unknown)
      Special rows also have no parent (NULL). A hierarchy root must have an
      empty parent, and no row may point to itself: Power BI's PATH function
      fails on a loop (a first version gave the top employee -2, and row -2
      pointed to itself).
  Special rows: -1 Unknown, -2 "No salesperson" (online orders).
  Same load pattern as the other source dimensions (D83, D84, D87).
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.dim_employee') IS NULL
CREATE TABLE dw.dim_employee (
    employee_key              int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_employee PRIMARY KEY,
    employee_id               int NULL,
    row_type                  varchar(20) NOT NULL,
    is_in_source              bit NOT NULL,
    employee_name             nvarchar(101) NOT NULL,
    job_title                 nvarchar(50) NOT NULL,
    organization_level        smallint NULL,
    manager_key               int NULL,
    current_department        nvarchar(50) NOT NULL,
    current_department_group  nvarchar(50) NOT NULL,
    current_shift             nvarchar(50) NOT NULL,
    is_salesperson            bit NOT NULL,
    is_buyer                  bit NOT NULL,
    inserted_batch_id         int NOT NULL,
    updated_batch_id          int NOT NULL,
    CONSTRAINT ck_dim_employee_row_type CHECK (row_type IN ('Source', 'Derived', 'Unknown', 'Not applicable'))
);
GO

-- One-time correction for tables created by the first version:
-- manager_key may be empty, and special rows have no parent.
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('dw.dim_employee') AND name = 'manager_key' AND is_nullable = 0)
    ALTER TABLE dw.dim_employee ALTER COLUMN manager_key int NULL;
GO
UPDATE dw.dim_employee SET manager_key = NULL
WHERE employee_key IN (-1, -2) AND manager_key IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_employee_employee_id' AND object_id = OBJECT_ID('dw.dim_employee'))
    CREATE UNIQUE INDEX ux_dim_employee_employee_id ON dw.dim_employee (employee_id) WHERE employee_id IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE etl.load_dim_employee
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_updated int, @rows_inserted int,
            @rows_retired int, @rows_manager int;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.dim_employee', @log_id OUTPUT;

        -- Special rows (fixed keys, created once, never changed by the load).
        SET IDENTITY_INSERT dw.dim_employee ON;
        IF NOT EXISTS (SELECT 1 FROM dw.dim_employee WHERE employee_key = -1)
            INSERT INTO dw.dim_employee (employee_key, employee_id, row_type, is_in_source, employee_name,
                                         job_title, organization_level, manager_key, current_department,
                                         current_department_group, current_shift, is_salesperson, is_buyer,
                                         inserted_batch_id, updated_batch_id)
            VALUES (-1, NULL, 'Unknown', 0, N'Unknown', N'Unknown', NULL, NULL, N'Unknown',
                    N'Unknown', N'Unknown', 0, 0, @batch_id, @batch_id);
        IF NOT EXISTS (SELECT 1 FROM dw.dim_employee WHERE employee_key = -2)
            INSERT INTO dw.dim_employee (employee_key, employee_id, row_type, is_in_source, employee_name,
                                         job_title, organization_level, manager_key, current_department,
                                         current_department_group, current_shift, is_salesperson, is_buyer,
                                         inserted_batch_id, updated_batch_id)
            VALUES (-2, NULL, 'Not applicable', 0, N'No salesperson', N'Not applicable', NULL, NULL,
                    N'Not applicable', N'Not applicable', N'Not applicable', 0, 0, @batch_id, @batch_id);
        SET IDENTITY_INSERT dw.dim_employee OFF;

        -- Source rows as they should look now (manager handled in pass 2).
        IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;

        SELECT  e.BusinessEntityID                                              AS employee_id,
                'Source'                                                        AS row_type,
                CAST(ISNULL(p.FirstName + N' ' + p.LastName, N'Unknown') AS nvarchar(101)) AS employee_name,
                e.JobTitle                                                      AS job_title,
                e.OrganizationLevel                                             AS organization_level,
                ISNULL(d.[Name], N'Unknown')                                    AS current_department,
                ISNULL(d.GroupName, N'Unknown')                                 AS current_department_group,
                ISNULL(sh.[Name], N'Unknown')                                   AS current_shift,
                CAST(CASE WHEN sp.BusinessEntityID IS NULL THEN 0 ELSE 1 END AS bit) AS is_salesperson,
                CAST(CASE WHEN e.JobTitle IN (N'Buyer', N'Purchasing Assistant', N'Purchasing Manager')
                          THEN 1 ELSE 0 END AS bit)                             AS is_buyer
        INTO #src
        FROM stg.aw_employee e
        LEFT JOIN stg.aw_person p ON p.BusinessEntityID = e.BusinessEntityID
        LEFT JOIN stg.aw_employee_department_history h
               ON h.BusinessEntityID = e.BusinessEntityID AND h.EndDate IS NULL
        LEFT JOIN stg.aw_department d   ON d.DepartmentID = h.DepartmentID
        LEFT JOIN stg.aw_shift sh       ON sh.ShiftID     = h.ShiftID
        LEFT JOIN stg.aw_sales_person sp ON sp.BusinessEntityID = e.BusinessEntityID;
        SET @rows_read = @@ROWCOUNT;

        -- 1. Update rows whose values changed, or that came back to the source.
        UPDATE d
        SET row_type = s.row_type, employee_name = s.employee_name, job_title = s.job_title,
            organization_level = s.organization_level, current_department = s.current_department,
            current_department_group = s.current_department_group, current_shift = s.current_shift,
            is_salesperson = s.is_salesperson, is_buyer = s.is_buyer,
            is_in_source = 1,
            updated_batch_id = @batch_id
        FROM dw.dim_employee d
        JOIN #src s ON s.employee_id = d.employee_id
        WHERE NOT EXISTS (
            SELECT s.row_type, s.employee_name, s.job_title, s.organization_level, s.current_department,
                   s.current_department_group, s.current_shift, s.is_salesperson, s.is_buyer, CAST(1 AS bit)
            INTERSECT
            SELECT d.row_type, d.employee_name, d.job_title, d.organization_level, d.current_department,
                   d.current_department_group, d.current_shift, d.is_salesperson, d.is_buyer, d.is_in_source);
        SET @rows_updated = @@ROWCOUNT;

        -- 2. Insert new rows (manager set to Unknown until pass 2).
        INSERT INTO dw.dim_employee (
            employee_id, row_type, is_in_source, employee_name, job_title, organization_level, manager_key,
            current_department, current_department_group, current_shift, is_salesperson, is_buyer,
            inserted_batch_id, updated_batch_id)
        SELECT
            s.employee_id, s.row_type, 1, s.employee_name, s.job_title, s.organization_level, -1,
            s.current_department, s.current_department_group, s.current_shift, s.is_salesperson, s.is_buyer,
            @batch_id, @batch_id
        FROM #src s
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_employee d WHERE d.employee_id = s.employee_id);
        SET @rows_inserted = @@ROWCOUNT;

        -- 3. Soft delete: rows no longer in the source are kept but marked.
        UPDATE d
        SET is_in_source = 0,
            updated_batch_id = @batch_id
        FROM dw.dim_employee d
        WHERE d.row_type IN ('Source', 'Derived')
          AND d.is_in_source = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.employee_id = d.employee_id);
        SET @rows_retired = @@ROWCOUNT;

        -- 4. Pass 2: manager_key, now that every employee has a key.
        IF OBJECT_ID('tempdb..#mgr') IS NOT NULL DROP TABLE #mgr;

        SELECT  e.BusinessEntityID AS employee_id,
                CASE WHEN e.OrganizationNode IS NULL OR e.OrganizationNode = N'/' THEN NULL -- top employee: root
                     WHEN m.BusinessEntityID IS NOT NULL                       THEN dm.employee_key
                     WHEN e.ParentOrganizationNode = N'/' AND r.root_id IS NOT NULL THEN dr.employee_key
                     ELSE -1 END AS manager_key
        INTO #mgr
        FROM stg.aw_employee e
        LEFT JOIN stg.aw_employee m ON m.OrganizationNode = e.ParentOrganizationNode
        LEFT JOIN dw.dim_employee dm ON dm.employee_id = m.BusinessEntityID
        CROSS JOIN (SELECT CASE WHEN COUNT(*) = 1 THEN MIN(BusinessEntityID) END AS root_id
                    FROM stg.aw_employee
                    WHERE OrganizationNode IS NULL OR OrganizationNode = N'/') r
        LEFT JOIN dw.dim_employee dr ON dr.employee_id = r.root_id;

        UPDATE d
        SET manager_key = g.manager_key,
            updated_batch_id = @batch_id
        FROM dw.dim_employee d
        JOIN #mgr g ON g.employee_id = d.employee_id
        WHERE d.manager_key IS DISTINCT FROM g.manager_key;
        SET @rows_manager = @@ROWCOUNT;

        DECLARE @rows_written int = @rows_updated + @rows_inserted + @rows_retired + @rows_manager;
        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        SET IDENTITY_INSERT dw.dim_employee OFF;
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
