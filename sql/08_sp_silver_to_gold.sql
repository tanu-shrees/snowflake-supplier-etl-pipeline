USE ROLE SYSADMIN;
USE WAREHOUSE SUPPLIER_TRANSFORM_WH;
USE DATABASE SUPPLIER_DW;
USE SCHEMA GOLD;

-- ============================================================
-- FILE: 08_sp_silver_to_gold.sql
-- PURPOSE: Stored procedure — Silver → Gold transformation
--   1. Refreshes AGG_RISK_SPEND (materialized aggregate)
--   2. Refreshes KPI_SNAPSHOT (dashboard KPIs)
--   3. Logs execution to AUDIT.PIPELINE_RUN_LOG
-- Source: SILVER.SUPPLIERS_CLEAN + SILVER.DIM_SUPPLIERS
-- ============================================================

CREATE OR REPLACE PROCEDURE SUPPLIER_DW.GOLD.SP_SILVER_TO_GOLD()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_start_time      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_rows_agg        NUMBER DEFAULT 0;
    v_rows_kpi        NUMBER DEFAULT 0;
BEGIN

    -- --------------------------------------------------------
    -- STEP 1: Refresh AGG_RISK_SPEND table
    --         (truncate + reload pattern for aggregates)
    -- --------------------------------------------------------
    TRUNCATE TABLE IF EXISTS SUPPLIER_DW.GOLD.AGG_RISK_SPEND;

    INSERT INTO SUPPLIER_DW.GOLD.AGG_RISK_SPEND (
        REGION, CATEGORY, RISK_RATING,
        SUPPLIER_COUNT, TOTAL_CONTRACT_VALUE,
        AVG_QUALITY_SCORE, AVG_ON_TIME_PCT, AVG_LEAD_TIME_DAYS
    )
    SELECT
        REGION,
        CATEGORY,
        RISK_RATING,
        COUNT(*)                            AS SUPPLIER_COUNT,
        SUM(CONTRACT_VALUE_USD)             AS TOTAL_CONTRACT_VALUE,
        ROUND(AVG(QUALITY_SCORE), 2)        AS AVG_QUALITY_SCORE,
        ROUND(AVG(ON_TIME_DELIVERY_PCT), 2) AS AVG_ON_TIME_PCT,
        ROUND(AVG(LEAD_TIME_DAYS), 1)       AS AVG_LEAD_TIME_DAYS
    FROM SUPPLIER_DW.SILVER.SUPPLIERS_CLEAN
    GROUP BY REGION, CATEGORY, RISK_RATING;

    v_rows_agg := SQLROWCOUNT;

    -- --------------------------------------------------------
    -- STEP 2: Refresh KPI_SNAPSHOT table
    --         (single-row summary for Streamlit dashboard)
    -- --------------------------------------------------------
    TRUNCATE TABLE IF EXISTS SUPPLIER_DW.GOLD.KPI_SNAPSHOT;

    INSERT INTO SUPPLIER_DW.GOLD.KPI_SNAPSHOT (
        TOTAL_SUPPLIERS,
        ACTIVE_SUPPLIERS,
        TOTAL_CONTRACT_VALUE,
        AVG_QUALITY_SCORE,
        AVG_ON_TIME_PCT,
        HIGH_RISK_COUNT,
        CRITICAL_RISK_COUNT,
        AUDIT_OVERDUE_COUNT,
        DQ_PASS_RATE_PCT
    )
    SELECT
        COUNT(*)                                                     AS TOTAL_SUPPLIERS,
        SUM(CASE WHEN IS_ACTIVE = TRUE THEN 1 ELSE 0 END)          AS ACTIVE_SUPPLIERS,
        SUM(CONTRACT_VALUE_USD)                                      AS TOTAL_CONTRACT_VALUE,
        ROUND(AVG(QUALITY_SCORE), 2)                                 AS AVG_QUALITY_SCORE,
        ROUND(AVG(ON_TIME_DELIVERY_PCT), 2)                          AS AVG_ON_TIME_PCT,
        SUM(CASE WHEN RISK_RATING = 'HIGH' THEN 1 ELSE 0 END)       AS HIGH_RISK_COUNT,
        SUM(CASE WHEN RISK_RATING = 'HIGH' AND QUALITY_SCORE < 75
                 THEN 1 ELSE 0 END)                                  AS CRITICAL_RISK_COUNT,
        SUM(CASE WHEN DATEDIFF('day', LAST_AUDIT_DATE, CURRENT_DATE()) > 365
                 THEN 1 ELSE 0 END)                                  AS AUDIT_OVERDUE_COUNT,
        (SELECT ROUND(
            SUM(CASE WHEN DQ_PASSED = TRUE THEN 1 ELSE 0 END) * 100.0
            / NULLIF(COUNT(*), 0), 2)
         FROM SUPPLIER_DW.SILVER.DIM_SUPPLIERS
         WHERE IS_CURRENT = TRUE)                                    AS DQ_PASS_RATE_PCT
    FROM SUPPLIER_DW.SILVER.SUPPLIERS_CLEAN;

    v_rows_kpi := SQLROWCOUNT;

    -- --------------------------------------------------------
    -- STEP 3: Audit log
    -- --------------------------------------------------------
    INSERT INTO SUPPLIER_DW.AUDIT.PIPELINE_RUN_LOG (
        TASK_NAME,
        PROCEDURE_NAME,
        START_TIME,
        END_TIME,
        ROWS_PROCESSED,
        ROWS_INSERTED,
        ROWS_UPDATED,
        ROWS_REJECTED,
        STATUS,
        ERROR_MESSAGE
    )
    VALUES (
        'TASK_SILVER_TO_GOLD',
        'SP_SILVER_TO_GOLD',
        :v_start_time,
        CURRENT_TIMESTAMP(),
        :v_rows_agg + :v_rows_kpi,
        :v_rows_agg + :v_rows_kpi,
        0,
        0,
        'SUCCESS',
        NULL
    );

    RETURN 'SUCCESS: AGG_RISK_SPEND rows=' || :v_rows_agg
        || ' | KPI_SNAPSHOT rows=' || :v_rows_kpi;

EXCEPTION
    WHEN OTHER THEN
        INSERT INTO SUPPLIER_DW.AUDIT.PIPELINE_RUN_LOG (
            TASK_NAME,
            PROCEDURE_NAME,
            START_TIME,
            END_TIME,
            ROWS_PROCESSED,
            ROWS_INSERTED,
            ROWS_UPDATED,
            ROWS_REJECTED,
            STATUS,
            ERROR_MESSAGE
        )
        VALUES (
            'TASK_SILVER_TO_GOLD',
            'SP_SILVER_TO_GOLD',
            :v_start_time,
            CURRENT_TIMESTAMP(),
            0, 0, 0, 0,
            'FAILED',
            SQLERRM
        );

        RETURN 'FAILED: ' || SQLERRM;
END;
$$;

-- Quick test (uncomment to run manually)
-- CALL SUPPLIER_DW.GOLD.SP_SILVER_TO_GOLD();