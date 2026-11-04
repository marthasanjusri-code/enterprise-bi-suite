/*
  05_etl_settings.sql
  One place for the constants that several load procedures use, so no
  number is typed twice:
    hr_date_shift_days       +4,017 days for HR dates            (D21)
    dw_date_shift_days       +4,170 days for DW (finance) dates  (D20)
    fiscal_year_start_month  7 = fiscal year starts 1 July       (D23)
  Safe to re-run: the table is created once; values are set to the ones below.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('etl.setting') IS NULL
CREATE TABLE etl.setting (
    setting_name   varchar(100)   NOT NULL CONSTRAINT pk_setting PRIMARY KEY,
    setting_value  varchar(100)   NOT NULL,
    description    nvarchar(400)  NOT NULL
);
GO

WITH v (setting_name, setting_value, description) AS (
    SELECT * FROM (VALUES
        ('hr_date_shift_days',      '4017', N'Days added to HR dates to align them with the sales timeline (D21).'),
        ('dw_date_shift_days',      '4170', N'Days added to AdventureWorksDW dates to align them with the sales timeline (D20).'),
        ('fiscal_year_start_month', '7',    N'First month of the fiscal year; the fiscal year is named by the year it ends (D23).')
    ) x (setting_name, setting_value, description)
)
UPDATE s
SET setting_value = v.setting_value,
    description   = v.description
FROM etl.setting s
JOIN v ON v.setting_name = s.setting_name
WHERE s.setting_value <> v.setting_value
   OR s.description   <> v.description;

WITH v (setting_name, setting_value, description) AS (
    SELECT * FROM (VALUES
        ('hr_date_shift_days',      '4017', N'Days added to HR dates to align them with the sales timeline (D21).'),
        ('dw_date_shift_days',      '4170', N'Days added to AdventureWorksDW dates to align them with the sales timeline (D20).'),
        ('fiscal_year_start_month', '7',    N'First month of the fiscal year; the fiscal year is named by the year it ends (D23).')
    ) x (setting_name, setting_value, description)
)
INSERT INTO etl.setting (setting_name, setting_value, description)
SELECT v.setting_name, v.setting_value, v.description
FROM v
WHERE NOT EXISTS (SELECT 1 FROM etl.setting s WHERE s.setting_name = v.setting_name);
GO

-- Returns a whole-number setting, or raises an error if it is missing,
-- so a load can never run with an undefined constant.
CREATE OR ALTER PROCEDURE etl.get_setting_int
    @setting_name varchar(100),
    @value        int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @value = TRY_CAST(setting_value AS int)
    FROM etl.setting
    WHERE setting_name = @setting_name;

    IF @value IS NULL
    BEGIN
        DECLARE @msg nvarchar(400) = N'Setting "' + @setting_name + N'" is missing or not a whole number in etl.setting.';
        THROW 50001, @msg, 1;
    END;
END;
GO
