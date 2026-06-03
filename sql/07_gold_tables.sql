USE ROLE SYSADMIN;
USE WAREHOUSE SUPPLIER_TRANSFORM_WH;
USE DATABASE SUPPLIER_DW;

CREATE SCHEMA IF NOT EXISTS GOLD;
USE SCHEMA GOLD;

-- ============================================================
-- FILE: 07_gold_tables.sql
-- PURPOSE: Gold layer — analytics-ready aggregations
--   1. Regional summary
--   2. Category summary
--   3. Risk scorecard
--   4. Monthly trends
--   5. Supplier rankings
-- Source: SILVER.SUPPLIERS_CLEAN (current-state clean data)
-- ============================================================

-- =============================================================
-- 1) REGIONAL SUMMARY
--    Aggregate metrics by region (APAC, AMER, EMEA, LATAM)
-- =============================================================
CREATE OR REPLACE VIEW SUPPLIER_DW.GOLD.VW_REGIONAL_SUMMARY AS
SELECT
    REGION,
    COUNT(*)                                    AS SUPPLIER_COUNT,
    SUM(CONTRACT_VALUE_USD)                     AS TOTAL_CONTRACT_VALUE,
    ROUND(AVG(CONTRACT_VALUE_USD), 2)           AS AVG_CONTRACT_VALUE,
    ROUND(AVG(QUALITY_SCORE), 2)                AS AVG_QUALITY_SCORE,
    ROUND(AVG(ON_TIME_DELIVERY_PCT), 2)         AS AVG_ON_TIME_DELIVERY_PCT,
    ROUND(AVG(LEAD_TIME_DAYS), 1)               AS AVG_LEAD_TIME_DAYS,
    SUM(CASE WHEN RISK_RATING = 'HIGH' THEN 1 ELSE 0 END)   AS HIGH_RISK_COUNT,
    SUM(CASE WHEN RISK_RATING = 'MEDIUM' THEN 1 ELSE 0 END) AS MEDIUM_RISK_COUNT,
    SUM(CASE WHEN RISK_RATING = 'LOW' THEN 1 ELSE 0 END)    AS LOW_RISK_COUNT,
    SUM(CASE WHEN IS_ACTIVE = TRUE THEN 1 ELSE 0 END)       AS ACTIVE_SUPPLIERS
FROM SUPPLIER_DW.SILVER.SUPPLIERS_CLEAN
GROUP BY REGION;

-- =============================================================
-- 2) CATEGORY SUMMARY
--    Aggregate metrics by category
-- =============================================================
CREATE OR REPLACE VIEW SUPPLIER_DW.GOLD.VW_CATEGORY_SUMMARY AS
SELECT
    CATEGORY,
    COUNT(*)                                    AS SUPPLIER_COUNT,
    SUM(CONTRACT_VALUE_USD)                     AS TOTAL_CONTRACT_VALUE,
    ROUND(AVG(CONTRACT_VALUE_USD), 2)           AS AVG_CONTRACT_VALUE,
    ROUND(AVG(QUALITY_SCORE), 2)                AS AVG_QUALITY_SCORE,
    ROUND(AVG(ON_TIME_DELIVERY_PCT), 2)         AS AVG_ON_TIME_DELIVERY_PCT,
    ROUND(AVG(LEAD_TIME_DAYS), 1)               AS AVG_LEAD_TIME_DAYS,
    SUM(CASE WHEN RISK_RATING = 'HIGH' THEN 1 ELSE 0 END) AS HIGH_RISK_COUNT
FROM SUPPLIER_DW.SILVER.SUPPLIERS_CLEAN
GROUP BY CATEGORY;

-- =============================================================
-- 3) RISK SCORECARD
--    Suppliers flagged as high risk or underperforming
-- =============================================================
CREATE OR REPLACE VIEW SUPPLIER_DW.GOLD.VW_RISK_SCORECARD AS
SELECT
    SUPPLIER_ID,
    SUPPLIER_NAME,
    REGION,
    CATEGORY,
    COUNTRY_CODE,
    CONTRACT_VALUE_USD,
    QUALITY_SCORE,
    ON_TIME_DELIVERY_PCT,
    LEAD_TIME_DAYS,
    RISK_RATING,
    LAST_AUDIT_DATE,
    -- Composite risk flags
    CASE
        WHEN RISK_RATING = 'HIGH' AND QUALITY_SCORE < 75 THEN 'CRITICAL'
        WHEN RISK_RATING = 'HIGH' THEN 'HIGH'
        WHEN QUALITY_SCORE < 70 OR ON_TIME_DELIVERY_PCT < 60 THEN 'WATCH'
        ELSE 'OK'
    END AS RISK_LEVEL,
    -- Days since last audit
    DATEDIFF('day', LAST_AUDIT_DATE, CURRENT_DATE()) AS DAYS_SINCE_AUDIT,
    CASE
        WHEN DATEDIFF('day', LAST_AUDIT_DATE, CURRENT_DATE()) > 365 THEN TRUE
        ELSE FALSE
    END AS AUDIT_OVERDUE
FROM SUPPLIER_DW.SILVER.SUPPLIERS_CLEAN
WHERE RISK_RATING = 'HIGH'
   OR QUALITY_SCORE < 75
   OR ON_TIME_DELIVERY_PCT < 60;

-- =============================================================
-- 4) MONTHLY TRENDS
--    Performance metrics aggregated by audit month
-- =============================================================
CREATE OR REPLACE VIEW SUPPLIER_DW.GOLD.VW_MONTHLY_TRENDS AS
SELECT
    DATE_TRUNC('MONTH', LAST_AUDIT_DATE)        AS AUDIT_MONTH,
    REGION,
    COUNT(*)                                    AS SUPPLIER_COUNT,
    SUM(CONTRACT_VALUE_USD)                     AS TOTAL_CONTRACT_VALUE,
    ROUND(AVG(QUALITY_SCORE), 2)                AS AVG_QUALITY_SCORE,
    ROUND(AVG(ON_TIME_DELIVERY_PCT), 2)         AS AVG_ON_TIME_DELIVERY_PCT,
    ROUND(AVG(LEAD_TIME_DAYS), 1)               AS AVG_LEAD_TIME_DAYS,
    SUM(CASE WHEN RISK_RATING = 'HIGH' THEN 1 ELSE 0 END) AS HIGH_RISK_COUNT
FROM SUPPLIER_DW.SILVER.SUPPLIERS_CLEAN
GROUP BY DATE_TRUNC('MONTH', LAST_AUDIT_DATE), REGION
ORDER BY AUDIT_MONTH, REGION;

-- =============================================================
-- 5) SUPPLIER RANKINGS
--    Top/Bottom suppliers by composite performance score
--    Score = 40% quality + 40% on-time delivery + 20% inverse lead time
-- =============================================================
CREATE OR REPLACE VIEW SUPPLIER_DW.GOLD.VW_SUPPLIER_RANKINGS AS
SELECT
    SUPPLIER_ID,
    SUPPLIER_NAME,
    REGION,
    CATEGORY,
    COUNTRY_CODE,
    CONTRACT_VALUE_USD,
    QUALITY_SCORE,
    ON_TIME_DELIVERY_PCT,
    LEAD_TIME_DAYS,
    RISK_RATING,
    -- Composite score (0-100 scale)
    ROUND(
        (QUALITY_SCORE * 0.4) +
        (ON_TIME_DELIVERY_PCT * 0.4) +
        ((1 - (LEAD_TIME_DAYS / 30.0)) * 100 * 0.2)
    , 2) AS PERFORMANCE_SCORE,
    -- Rank within region
    RANK() OVER (PARTITION BY REGION ORDER BY
        (QUALITY_SCORE * 0.4) +
        (ON_TIME_DELIVERY_PCT * 0.4) +
        ((1 - (LEAD_TIME_DAYS / 30.0)) * 100 * 0.2)
    DESC) AS RANK_IN_REGION,
    -- Overall rank
    RANK() OVER (ORDER BY
        (QUALITY_SCORE * 0.4) +
        (ON_TIME_DELIVERY_PCT * 0.4) +
        ((1 - (LEAD_TIME_DAYS / 30.0)) * 100 * 0.2)
    DESC) AS OVERALL_RANK,
    -- Tier classification
    CASE
        WHEN RANK() OVER (ORDER BY
            (QUALITY_SCORE * 0.4) +
            (ON_TIME_DELIVERY_PCT * 0.4) +
            ((1 - (LEAD_TIME_DAYS / 30.0)) * 100 * 0.2)
        DESC) <= CEIL(COUNT(*) OVER () * 0.2) THEN 'TIER_1_TOP'
        WHEN RANK() OVER (ORDER BY
            (QUALITY_SCORE * 0.4) +
            (ON_TIME_DELIVERY_PCT * 0.4) +
            ((1 - (LEAD_TIME_DAYS / 30.0)) * 100 * 0.2)
        DESC) >= CEIL(COUNT(*) OVER () * 0.8) THEN 'TIER_3_BOTTOM'
        ELSE 'TIER_2_MID'
    END AS PERFORMANCE_TIER
FROM SUPPLIER_DW.SILVER.SUPPLIERS_CLEAN;

-- =============================================================
-- 6) MATERIALIZED TABLE: Aggregated risk + spend summary
--    (Refreshed by the Silver-to-Gold task/procedure)
-- =============================================================
CREATE OR REPLACE TABLE SUPPLIER_DW.GOLD.AGG_RISK_SPEND (
    REGION              VARCHAR(100),
    CATEGORY            VARCHAR(100),
    RISK_RATING         VARCHAR(50),
    SUPPLIER_COUNT      NUMBER,
    TOTAL_CONTRACT_VALUE NUMBER(18,2),
    AVG_QUALITY_SCORE   NUMBER(5,2),
    AVG_ON_TIME_PCT     NUMBER(5,2),
    AVG_LEAD_TIME_DAYS  NUMBER(5,1),
    LAST_REFRESHED_TS   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =============================================================
-- 7) MATERIALIZED TABLE: KPI snapshot for Streamlit dashboard
-- =============================================================
CREATE OR REPLACE TABLE SUPPLIER_DW.GOLD.KPI_SNAPSHOT (
    SNAPSHOT_TS             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    TOTAL_SUPPLIERS         NUMBER,
    ACTIVE_SUPPLIERS        NUMBER,
    TOTAL_CONTRACT_VALUE    NUMBER(18,2),
    AVG_QUALITY_SCORE       NUMBER(5,2),
    AVG_ON_TIME_PCT         NUMBER(5,2),
    HIGH_RISK_COUNT         NUMBER,
    CRITICAL_RISK_COUNT     NUMBER,
    AUDIT_OVERDUE_COUNT     NUMBER,
    DQ_PASS_RATE_PCT        NUMBER(5,2)
);

-- Verification
SHOW VIEWS IN SCHEMA SUPPLIER_DW.GOLD;
SHOW TABLES IN SCHEMA SUPPLIER_DW.GOLD;