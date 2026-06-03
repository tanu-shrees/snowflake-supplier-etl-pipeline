USE ROLE SYSADMIN;
USE DATABASE SUPPLIER_DW;
USE SCHEMA BRONZE;
USE WAREHOUSE SUPPLIER_INGEST_WH;

-- =====================================================
-- FILE 2: BRONZE TABLES
-- Purpose:
-- Create raw landing table for supplier batch CSV files
-- =====================================================

CREATE OR REPLACE TABLE SUPPLIER_DW.BRONZE.RAW_SUPPLIERS (
    -- Business columns from CSV
    SUPPLIER_ID             VARCHAR(50),
    SUPPLIER_NAME           VARCHAR(255),
    COUNTRY_CODE            VARCHAR(10),
    REGION                  VARCHAR(100),
    CATEGORY                VARCHAR(100),
    CONTRACT_VALUE_USD      NUMBER(18,2),
    LEAD_TIME_DAYS          INTEGER,
    QUALITY_SCORE           NUMBER(5,2),
    ON_TIME_DELIVERY_PCT    NUMBER(5,2),
    RISK_RATING             VARCHAR(50),
    LAST_AUDIT_DATE         DATE,
    IS_ACTIVE               BOOLEAN,

    -- Bronze metadata columns
    _SOURCE_FILE_NAME       VARCHAR(500),
    _SOURCE_ROW_NUMBER      NUMBER,
    _LOAD_TS                TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _BATCH_ID               VARCHAR(100),
    _INGESTION_STATUS       VARCHAR(30) DEFAULT 'LOADED'
);

-- Optional helper view for quick inspection
CREATE OR REPLACE VIEW SUPPLIER_DW.BRONZE.VW_RAW_SUPPLIERS_LATEST AS
SELECT *
FROM SUPPLIER_DW.BRONZE.RAW_SUPPLIERS
ORDER BY _LOAD_TS DESC, _SOURCE_FILE_NAME, _SOURCE_ROW_NUMBER;

-- Verification
DESC TABLE SUPPLIER_DW.BRONZE.RAW_SUPPLIERS;
SHOW TABLES IN SCHEMA SUPPLIER_DW.BRONZE;