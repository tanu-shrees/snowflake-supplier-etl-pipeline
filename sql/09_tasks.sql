USE ROLE SYSADMIN;
USE WAREHOUSE SUPPLIER_TRANSFORM_WH;
USE DATABASE SUPPLIER_DW;

-- ============================================================
-- FILE: 09_tasks.sql
-- PURPOSE: Scheduled Tasks to automate the full pipeline
--
-- Task chain:
--   TASK_BRONZE_TO_SILVER (root, every 5 min, stream-driven)
--       └── TASK_SILVER_TO_GOLD (child, runs after parent succeeds)
--
-- Prerequisites:
--   - 06_sp_bronze_to_silver.sql (SP_BRONZE_TO_SILVER)
--   - 08_sp_silver_to_gold.sql (SP_SILVER_TO_GOLD)
--   - Stream: BRONZE.STR_RAW_SUPPLIERS
-- ============================================================

-- Ensure SYSADMIN can execute tasks
USE ROLE ACCOUNTADMIN;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE SYSADMIN;
GRANT EXECUTE MANAGED TASK ON ACCOUNT TO ROLE SYSADMIN;
USE ROLE SYSADMIN;

-- --------------------------------------------------------
-- Root task: Bronze → Silver
-- Runs every 5 minutes, but ONLY when stream has new data
-- --------------------------------------------------------
CREATE OR REPLACE TASK SUPPLIER_DW.SILVER.TASK_BRONZE_TO_SILVER
    WAREHOUSE = SUPPLIER_TRANSFORM_WH
    SCHEDULE  = '5 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('SUPPLIER_DW.BRONZE.STR_RAW_SUPPLIERS')
AS
    CALL SUPPLIER_DW.SILVER.SP_BRONZE_TO_SILVER();

-- --------------------------------------------------------
-- Child task: Silver → Gold
-- Automatically runs after Bronze-to-Silver succeeds
-- --------------------------------------------------------
CREATE OR REPLACE TASK SUPPLIER_DW.GOLD.TASK_SILVER_TO_GOLD
    WAREHOUSE = SUPPLIER_TRANSFORM_WH
    AFTER SUPPLIER_DW.SILVER.TASK_BRONZE_TO_SILVER
AS
    CALL SUPPLIER_DW.GOLD.SP_SILVER_TO_GOLD();

-- --------------------------------------------------------
-- Resume tasks (created in SUSPENDED state by default)
-- IMPORTANT: Resume child FIRST, then parent
-- --------------------------------------------------------
ALTER TASK SUPPLIER_DW.GOLD.TASK_SILVER_TO_GOLD RESUME;
ALTER TASK SUPPLIER_DW.SILVER.TASK_BRONZE_TO_SILVER RESUME;

-- --------------------------------------------------------
-- Verification
-- --------------------------------------------------------
SHOW TASKS IN DATABASE SUPPLIER_DW;

-- --------------------------------------------------------
-- Useful monitoring queries (uncomment as needed)
-- --------------------------------------------------------

-- Check task run history (last hour):
-- SELECT *
-- FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
--     SCHEDULED_TIME_RANGE_START => DATEADD('hour', -1, CURRENT_TIMESTAMP()),
--     RESULT_LIMIT => 20
-- ))
-- ORDER BY SCHEDULED_TIME DESC;

-- Suspend tasks (for maintenance):
-- ALTER TASK SUPPLIER_DW.SILVER.TASK_BRONZE_TO_SILVER SUSPEND;
-- ALTER TASK SUPPLIER_DW.GOLD.TASK_SILVER_TO_GOLD SUSPEND;