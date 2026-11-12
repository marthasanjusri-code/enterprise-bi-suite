/*
  30_security_user_region.sql
  dw.security_user_region: who may see which region in Power BI (D71-D73).
    Power BI reads the signed-in user's email and filters dim_territory and dim_organization
    by region_group (Regional Manager role). Executives see everything.

  Users (D117): the company's own managers from the source, not invented users.
    Query of 11 Nov 2026 on AdventureWorks2025 (HumanResources.Employee, Person.Person,
    Person.EmailAddress): employee 1 Ken Sanchez, Chief Executive Officer; 274 Stephen Jiang,
    North American Sales Manager; 285 Syed Abbas, Pacific Sales Manager; 287 Amy Alberts,
    European Sales Manager. Each manager's region group is the one all their orders are in
    (quota checks: check C).
  The table is maintained by an administrator (as in a real company), not loaded from the source:
  managers are added or moved by editing rows, not the report (D71). A user missing from the
  table sees no data (D73).
  Safe to re-run: the table is created once; the rows are merged.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.security_user_region') IS NULL
CREATE TABLE dw.security_user_region (
    user_email     nvarchar(256)  NOT NULL CONSTRAINT pk_security_user_region PRIMARY KEY,
    employee_id    int            NULL,
    full_name      nvarchar(100)  NOT NULL,
    job_title      nvarchar(50)   NOT NULL,
    security_role  varchar(20)    NOT NULL CONSTRAINT ck_security_user_region_role
                                           CHECK (security_role IN ('Executive', 'Regional Manager')),
    region_group   nvarchar(50)   NULL,
    source_note    nvarchar(200)  NOT NULL,
    CONSTRAINT ck_security_user_region_group
        CHECK ((security_role = 'Executive' AND region_group IS NULL)
            OR (security_role = 'Regional Manager' AND region_group IS NOT NULL))
);
GO

MERGE dw.security_user_region AS t
USING (VALUES
    (N'ken0@adventure-works.com',     1,   N'Ken Sánchez',   N'Chief Executive Officer',       'Executive',        CAST(NULL AS nvarchar(50))),
    (N'stephen0@adventure-works.com', 274, N'Stephen Jiang', N'North American Sales Manager',  'Regional Manager', N'North America'),
    (N'syed0@adventure-works.com',    285, N'Syed Abbas',    N'Pacific Sales Manager',         'Regional Manager', N'Pacific'),
    (N'amy0@adventure-works.com',     287, N'Amy Alberts',   N'European Sales Manager',        'Regional Manager', N'Europe')
) AS s (user_email, employee_id, full_name, job_title, security_role, region_group)
ON t.user_email = s.user_email
WHEN MATCHED THEN UPDATE SET
    employee_id = s.employee_id, full_name = s.full_name, job_title = s.job_title,
    security_role = s.security_role, region_group = s.region_group,
    source_note = N'AdventureWorks2025 employee and email address, query of 11 Nov 2026'
WHEN NOT MATCHED THEN INSERT (user_email, employee_id, full_name, job_title, security_role, region_group, source_note)
    VALUES (s.user_email, s.employee_id, s.full_name, s.job_title, s.security_role, s.region_group,
            N'AdventureWorks2025 employee and email address, query of 11 Nov 2026');
GO
