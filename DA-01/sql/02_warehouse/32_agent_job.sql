/*
  32_agent_job.sql
  SQL Server Agent job "EnterpriseBI_DW nightly load": one T-SQL step that runs
  etl.run_pipeline every night at 02:00 (D78). The brief allows scheduled SQL jobs when
  Azure Data Factory is not used (D09); the same procedure can be called by any scheduler.
  The step fails when the run fails (etl.run_pipeline ends with an error), so the job history
  shows every failed night; etl.load_batch, etl.load_log and etl.dq_result hold the details.
  Safe to re-run: an existing job with the same name is deleted and recreated.
*/

USE msdb;
GO

DECLARE @job_name sysname = N'EnterpriseBI_DW nightly load';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @job_name)
    EXEC msdb.dbo.sp_delete_job @job_name = @job_name, @delete_unused_schedule = 1;

EXEC msdb.dbo.sp_add_job
     @job_name    = @job_name,
     @enabled     = 1,
     @description = N'Loads staging, dimensions and facts of EnterpriseBI_DW in one transaction and runs the data quality checks (etl.run_pipeline). Rolled back on any Error check.';

EXEC msdb.dbo.sp_add_jobstep
     @job_name          = @job_name,
     @step_name         = N'Run etl.run_pipeline',
     @subsystem         = N'TSQL',
     @database_name     = N'EnterpriseBI_DW',
     @command           = N'EXEC etl.run_pipeline;',
     @on_success_action = 1,     -- quit reporting success
     @on_fail_action    = 2,     -- quit reporting failure
     @retry_attempts    = 0;

EXEC msdb.dbo.sp_add_schedule
     @schedule_name     = N'EnterpriseBI_DW daily 02:00',
     @freq_type         = 4,         -- daily
     @freq_interval     = 1,         -- every day
     @active_start_time = 020000;    -- 02:00:00

EXEC msdb.dbo.sp_attach_schedule
     @job_name      = @job_name,
     @schedule_name = N'EnterpriseBI_DW daily 02:00';

EXEC msdb.dbo.sp_add_jobserver
     @job_name    = @job_name,
     @server_name = N'(local)';
GO
