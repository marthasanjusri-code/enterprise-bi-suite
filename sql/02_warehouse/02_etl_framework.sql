/*
  02_etl_framework.sql
  Load logging and data quality storage used by every load step.
    etl.load_batch  one row per pipeline run
    etl.load_log    one row per step within a run
    etl.dq_result   one row per data quality check within a run
  Procedures to open and close runs and steps.
  Safe to re-run: tables are created only if missing; procedures are replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('etl.load_batch') IS NULL
CREATE TABLE etl.load_batch (
    batch_id      int IDENTITY(1,1) NOT NULL CONSTRAINT pk_load_batch PRIMARY KEY,
    started_at    datetime2(0)      NOT NULL CONSTRAINT df_load_batch_started DEFAULT SYSDATETIME(),
    ended_at      datetime2(0)      NULL,
    status        varchar(10)       NOT NULL CONSTRAINT df_load_batch_status DEFAULT 'Running',
    triggered_by  nvarchar(128)     NOT NULL,
    CONSTRAINT ck_load_batch_status CHECK (status IN ('Running', 'Succeeded', 'Failed'))
);
GO

IF OBJECT_ID('etl.load_log') IS NULL
CREATE TABLE etl.load_log (
    log_id         int IDENTITY(1,1) NOT NULL CONSTRAINT pk_load_log PRIMARY KEY,
    batch_id       int               NOT NULL CONSTRAINT fk_load_log_batch REFERENCES etl.load_batch (batch_id),
    step_name      varchar(100)      NOT NULL,
    started_at     datetime2(0)      NOT NULL CONSTRAINT df_load_log_started DEFAULT SYSDATETIME(),
    ended_at       datetime2(0)      NULL,
    rows_read      int               NULL,
    rows_written   int               NULL,
    status         varchar(10)       NOT NULL CONSTRAINT df_load_log_status DEFAULT 'Running',
    error_message  nvarchar(4000)    NULL,
    CONSTRAINT ck_load_log_status CHECK (status IN ('Running', 'Succeeded', 'Failed'))
);
GO

IF OBJECT_ID('etl.dq_result') IS NULL
CREATE TABLE etl.dq_result (
    dq_id           int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dq_result PRIMARY KEY,
    batch_id        int               NOT NULL CONSTRAINT fk_dq_result_batch REFERENCES etl.load_batch (batch_id),
    check_name      varchar(200)      NOT NULL,
    severity        varchar(10)       NOT NULL,
    measured_value  decimal(18,4)     NULL,
    expected_value  varchar(100)      NULL,
    status          varchar(10)       NOT NULL,
    details         nvarchar(4000)    NULL,
    checked_at      datetime2(0)      NOT NULL CONSTRAINT df_dq_result_checked DEFAULT SYSDATETIME(),
    CONSTRAINT ck_dq_result_severity CHECK (severity IN ('Error', 'Warning')),
    CONSTRAINT ck_dq_result_status   CHECK (status   IN ('Pass', 'Fail', 'Warn'))
);
GO

-- Opens a run and returns its batch_id.
CREATE OR ALTER PROCEDURE etl.start_batch
    @batch_id int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO etl.load_batch (triggered_by) VALUES (SUSER_SNAME());
    SET @batch_id = SCOPE_IDENTITY();
END;
GO

-- Closes a run.
CREATE OR ALTER PROCEDURE etl.end_batch
    @batch_id int,
    @status   varchar(10)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE etl.load_batch
    SET ended_at = SYSDATETIME(),
        status   = @status
    WHERE batch_id = @batch_id;
END;
GO

-- Opens a step within a run and returns its log_id.
CREATE OR ALTER PROCEDURE etl.start_step
    @batch_id  int,
    @step_name varchar(100),
    @log_id    int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO etl.load_log (batch_id, step_name) VALUES (@batch_id, @step_name);
    SET @log_id = SCOPE_IDENTITY();
END;
GO

-- Closes a step with its row counts, status and any error message.
CREATE OR ALTER PROCEDURE etl.end_step
    @log_id        int,
    @status        varchar(10),
    @rows_read     int            = NULL,
    @rows_written  int            = NULL,
    @error_message nvarchar(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE etl.load_log
    SET ended_at      = SYSDATETIME(),
        status        = @status,
        rows_read     = @rows_read,
        rows_written  = @rows_written,
        error_message = @error_message
    WHERE log_id = @log_id;
END;
GO