/*
  22_dim_account.sql
  dw.dim_account: one row per source account (the full chart of accounts, parents and
  leaves), plus a special row.
    Source: AdventureWorksDW2025 DimAccount, copied to stg.awdw_dim_account.
    Used by fact_finance, which only ever links to leaf accounts (is_leaf = 1).

  Statement (D68): each account belongs to the statement of its top account:
    code 1 (Balance Sheet) = Balance sheet, code 4 (Net Income) = Income statement,
    code 9500 (Statistical Accounts) = Statistical. A top account with any other
    code stops the load, because profit lines and conversion rules depend on it.
  sign_to_net_income (D38): for Income statement accounts, +1 or -1 = the product of the
    operators from the account up to (not including) Net Income; revenue adds, costs
    subtract. The same sign gives every profit line below Net Income (net sales, gross
    margin, operating profit). Balance sheet and Statistical accounts, and the special
    row, are 0: they are not part of net income, so "amount x sign" can never pick them up.
  Levels (D68): level_1 to level_6 flattened from the top account down, repeating the
    account's own name where a level does not exist. More than six levels stops the load.
  Sort order: the tree in reading order, siblings sorted by account code as text. As text,
    Commissions (6100) sorts between Labor Expenses (600) and Travel Expenses (620), as in the
    source; as a number it would fall after Depreciation (680). Dense, 1 to the number of accounts.
  Account names are not unique ("Other Assets" appears twice); use account_id or account_code.

  Common pattern for all source dimensions (D59, D83, D84, D87):
    - Surrogate key account_key (identity); special row -1 Unknown.
    - Business key account_id (the source AccountKey), unique for real rows.
    - Load: UPDATE changed rows, then INSERT new rows, then mark rows that left the
      source with is_in_source = 0 (soft delete, rows are never removed).
    - Lineage: inserted_batch_id, updated_batch_id.
  Missing text becomes "N/A" (D89).
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.dim_account') IS NULL
CREATE TABLE dw.dim_account (
    account_key              int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_account PRIMARY KEY,
    account_id               int NULL,
    row_type                 varchar(20) NOT NULL,
    is_in_source             bit NOT NULL,
    account_code             varchar(20) NOT NULL,
    account_name             nvarchar(50) NOT NULL,
    account_type             nvarchar(50) NOT NULL,
    [operator]               nvarchar(50) NOT NULL,
    value_type               nvarchar(50) NOT NULL,
    statement                varchar(30) NOT NULL,
    sign_to_net_income       smallint NOT NULL,
    level_1                  nvarchar(50) NOT NULL,
    level_2                  nvarchar(50) NOT NULL,
    level_3                  nvarchar(50) NOT NULL,
    level_4                  nvarchar(50) NOT NULL,
    level_5                  nvarchar(50) NOT NULL,
    level_6                  nvarchar(50) NOT NULL,
    sort_order               int NOT NULL,
    is_leaf                  bit NOT NULL,
    inserted_batch_id        int NOT NULL,
    updated_batch_id         int NOT NULL,
    CONSTRAINT ck_dim_account_row_type CHECK (row_type IN ('Source', 'Derived', 'Unknown', 'Not applicable'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_account_account_id' AND object_id = OBJECT_ID('dw.dim_account'))
    CREATE UNIQUE INDEX ux_dim_account_account_id ON dw.dim_account (account_id) WHERE account_id IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE etl.load_dim_account
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_updated int, @rows_inserted int, @rows_retired int;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.dim_account', @log_id OUTPUT;

        -- The statement of each known top account, by account code (D68).
        IF OBJECT_ID('tempdb..#root_map') IS NOT NULL DROP TABLE #root_map;
        CREATE TABLE #root_map (account_code int NOT NULL, statement varchar(30) NOT NULL);
        INSERT INTO #root_map (account_code, statement)
        VALUES (1, 'Balance sheet'), (4, 'Income statement'), (9500, 'Statistical');

        -- Position of each account among its siblings: by account code as text (ties by key).
        IF OBJECT_ID('tempdb..#rank') IS NOT NULL DROP TABLE #rank;
        SELECT  AccountKey AS account_id,
                ROW_NUMBER() OVER (PARTITION BY ParentAccountKey
                                   ORDER BY CAST(AccountCodeAlternateKey AS varchar(20)), AccountKey) AS sibling_rank
        INTO #rank
        FROM stg.awdw_dim_account;

        -- The tree from the top accounts down: names at depth 0 to 5, statement,
        -- sign towards the top account, and a sort path made of sibling positions.
        IF OBJECT_ID('tempdb..#hier') IS NOT NULL DROP TABLE #hier;

        WITH h AS (
            SELECT  a.AccountKey AS account_id,
                    0 AS depth,
                    ISNULL(rm.statement, 'N/A') AS statement,
                    1 AS sgn,
                    CAST(ISNULL(a.AccountDescription, N'N/A') AS nvarchar(50)) AS n0,
                    CAST(NULL AS nvarchar(50)) AS n1,
                    CAST(NULL AS nvarchar(50)) AS n2,
                    CAST(NULL AS nvarchar(50)) AS n3,
                    CAST(NULL AS nvarchar(50)) AS n4,
                    CAST(NULL AS nvarchar(50)) AS n5,
                    CAST(RIGHT('000' + CAST(r.sibling_rank AS varchar(10)), 3) AS varchar(100)) AS sort_path
            FROM stg.awdw_dim_account a
            JOIN #rank r ON r.account_id = a.AccountKey
            LEFT JOIN #root_map rm ON rm.account_code = a.AccountCodeAlternateKey
            WHERE a.ParentAccountKey IS NULL
            UNION ALL
            SELECT  c.AccountKey,
                    h.depth + 1,
                    h.statement,
                    h.sgn * CASE c.[Operator] WHEN '+' THEN 1 WHEN '-' THEN -1 ELSE 0 END,
                    h.n0,
                    CASE WHEN h.depth + 1 = 1 THEN ISNULL(c.AccountDescription, N'N/A') ELSE h.n1 END,
                    CASE WHEN h.depth + 1 = 2 THEN ISNULL(c.AccountDescription, N'N/A') ELSE h.n2 END,
                    CASE WHEN h.depth + 1 = 3 THEN ISNULL(c.AccountDescription, N'N/A') ELSE h.n3 END,
                    CASE WHEN h.depth + 1 = 4 THEN ISNULL(c.AccountDescription, N'N/A') ELSE h.n4 END,
                    CASE WHEN h.depth + 1 = 5 THEN ISNULL(c.AccountDescription, N'N/A') ELSE h.n5 END,
                    CAST(h.sort_path + RIGHT('000' + CAST(r.sibling_rank AS varchar(10)), 3) AS varchar(100))
            FROM h
            JOIN stg.awdw_dim_account c ON c.ParentAccountKey = h.account_id
            JOIN #rank r ON r.account_id = c.AccountKey
        )
        SELECT account_id, depth, statement, sgn, n0, n1, n2, n3, n4, n5, sort_path
        INTO #hier
        FROM h
        OPTION (MAXRECURSION 20);

        -- The shape is a design assumption (D68). Stop if the source breaks it.
        DECLARE @accounts_in_source int = (SELECT COUNT(*) FROM stg.awdw_dim_account);
        DECLARE @accounts_reached int = (SELECT COUNT(*) FROM #hier);
        IF @accounts_reached <> @accounts_in_source
           OR EXISTS (SELECT 1 FROM #hier WHERE depth > 5)
            THROW 50001, 'dim_account supports at most six levels and every account must be reachable from a top account.', 1;

        IF EXISTS (SELECT 1 FROM #hier WHERE depth = 0 AND statement = 'N/A')
            THROW 50001, 'dim_account found a top account that is not a known statement (codes 1, 4 and 9500). Classify it in 22_dim_account.sql first.', 1;

        -- Special rows (fixed keys, created once, never changed by the load).
        SET IDENTITY_INSERT dw.dim_account ON;
        IF NOT EXISTS (SELECT 1 FROM dw.dim_account WHERE account_key = -1)
            INSERT INTO dw.dim_account (account_key, account_id, row_type, is_in_source, account_code, account_name,
                             account_type, [operator], value_type, statement, sign_to_net_income,
                             level_1, level_2, level_3, level_4, level_5, level_6, sort_order, is_leaf,
                             inserted_batch_id, updated_batch_id)
            VALUES (-1, NULL, 'Unknown', 0, 'N/A', N'Unknown',
                    N'Unknown', N'N/A', N'Unknown', 'Unknown', 0,
                    N'Unknown', N'Unknown', N'Unknown', N'Unknown', N'Unknown', N'Unknown', 0, 0,
                    @batch_id, @batch_id);
        SET IDENTITY_INSERT dw.dim_account OFF;

        -- Source rows as they should look now.
        IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;

        SELECT  a.AccountKey                                                    AS account_id,
                'Source'                                                        AS row_type,
                ISNULL(CAST(a.AccountCodeAlternateKey AS varchar(20)), 'N/A')  AS account_code,
                ISNULL(a.AccountDescription, N'N/A')                            AS account_name,
                ISNULL(a.AccountType, N'N/A')                                   AS account_type,
                ISNULL(a.[Operator], N'N/A')                                    AS [operator],
                ISNULL(a.ValueType, N'N/A')                                     AS value_type,
                h.statement                                                     AS statement,
                CAST(CASE WHEN h.statement = 'Income statement' THEN h.sgn ELSE 0 END AS smallint) AS sign_to_net_income,
                l1.v                                                            AS level_1,
                l2.v                                                            AS level_2,
                l3.v                                                            AS level_3,
                l4.v                                                            AS level_4,
                l5.v                                                            AS level_5,
                l6.v                                                            AS level_6,
                CAST(ROW_NUMBER() OVER (ORDER BY h.sort_path) AS int)           AS sort_order,
                CAST(CASE WHEN EXISTS (SELECT 1 FROM stg.awdw_dim_account k WHERE k.ParentAccountKey = a.AccountKey)
                          THEN 0 ELSE 1 END AS bit)                             AS is_leaf
        INTO #src
        FROM stg.awdw_dim_account a
        JOIN #hier h ON h.account_id = a.AccountKey
        CROSS APPLY (SELECT h.n0 AS v) l1
        CROSS APPLY (SELECT ISNULL(h.n1, l1.v) AS v) l2
        CROSS APPLY (SELECT ISNULL(h.n2, l2.v) AS v) l3
        CROSS APPLY (SELECT ISNULL(h.n3, l3.v) AS v) l4
        CROSS APPLY (SELECT ISNULL(h.n4, l4.v) AS v) l5
        CROSS APPLY (SELECT ISNULL(h.n5, l5.v) AS v) l6;
        SET @rows_read = @@ROWCOUNT;

        -- 1. Update rows whose values changed, or that came back to the source.
        UPDATE d
        SET row_type = s.row_type,
            account_code = s.account_code,
            account_name = s.account_name,
            account_type = s.account_type,
            [operator] = s.[operator],
            value_type = s.value_type,
            statement = s.statement,
            sign_to_net_income = s.sign_to_net_income,
            level_1 = s.level_1,
            level_2 = s.level_2,
            level_3 = s.level_3,
            level_4 = s.level_4,
            level_5 = s.level_5,
            level_6 = s.level_6,
            sort_order = s.sort_order,
            is_leaf = s.is_leaf,
            is_in_source = 1,
            updated_batch_id = @batch_id
        FROM dw.dim_account d
        JOIN #src s ON s.account_id = d.account_id
        WHERE NOT EXISTS (
            SELECT s.row_type, s.account_code, s.account_name, s.account_type, s.[operator], s.value_type,
                   s.statement, s.sign_to_net_income, s.level_1, s.level_2, s.level_3, s.level_4,
                   s.level_5, s.level_6, s.sort_order, s.is_leaf, CAST(1 AS bit)
            INTERSECT
            SELECT d.row_type, d.account_code, d.account_name, d.account_type, d.[operator], d.value_type,
                   d.statement, d.sign_to_net_income, d.level_1, d.level_2, d.level_3, d.level_4,
                   d.level_5, d.level_6, d.sort_order, d.is_leaf, d.is_in_source);
        SET @rows_updated = @@ROWCOUNT;

        -- 2. Insert new rows.
        INSERT INTO dw.dim_account (
            account_id, row_type, is_in_source, account_code, account_name, account_type, [operator],
            value_type, statement, sign_to_net_income, level_1, level_2, level_3, level_4, level_5,
            level_6, sort_order, is_leaf, inserted_batch_id, updated_batch_id)
        SELECT
            s.account_id, s.row_type, 1, s.account_code, s.account_name, s.account_type, s.[operator],
            s.value_type, s.statement, s.sign_to_net_income, s.level_1, s.level_2, s.level_3, s.level_4,
            s.level_5, s.level_6, s.sort_order, s.is_leaf, @batch_id, @batch_id
        FROM #src s
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_account d WHERE d.account_id = s.account_id);
        SET @rows_inserted = @@ROWCOUNT;

        -- 3. Soft delete: rows no longer in the source are kept but marked.
        UPDATE d
        SET is_in_source = 0,
            updated_batch_id = @batch_id
        FROM dw.dim_account d
        WHERE d.row_type IN ('Source', 'Derived')
          AND d.is_in_source = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.account_id = d.account_id);
        SET @rows_retired = @@ROWCOUNT;

        DECLARE @rows_written int = @rows_updated + @rows_inserted + @rows_retired;
        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        IF EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = OBJECT_ID('dw.dim_account'))
            SET IDENTITY_INSERT dw.dim_account OFF;
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
