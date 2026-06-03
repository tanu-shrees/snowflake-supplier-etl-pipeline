USE ROLE SYSADMIN;
USE WAREHOUSE SUPPLIER_TRANSFORM_WH;
USE DATABASE SUPPLIER_DW;
USE SCHEMA SILVER;

-- ============================================================
-- FILE: 06_sp_bronze_to_silver.sql
-- PURPOSE: Stored procedure — Bronze → Silver transformation
--   1. Reads incrementally from Stream (CDC)
--   2. Validates data quality
--   3. Routes clean records → SUPPLIERS_CLEAN + DIM_SUPPLIERS (SCD2)
--   4. Routes failed records → REJECTED_SUPPLIERS
--   5. Logs execution to AUDIT.PIPELINE_RUN_LOG
-- ============================================================

CREATE OR REPLACE PROCEDURE SUPPLIER_DW.SILVER.SP_BRONZE_TO_SILVER()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_start_time      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_rows_clean      NUMBER DEFAULT 0;
    v_rows_rejected   NUMBER DEFAULT 0;
    v_rows_scd_expired NUMBER DEFAULT 0;
    v_rows_scd_inserted NUMBER DEFAULT 0;
    v_stream_has_data  BOOLEAN DEFAULT FALSE;
BEGIN

    -- --------------------------------------------------------
    -- STEP 0: Check if stream has data to process
    -- --------------------------------------------------------
    SELECT SYSTEM$STREAM_HAS_DATA('SUPPLIER_DW.BRONZE.STR_RAW_SUPPLIERS')
      INTO :v_stream_has_data;

    IF (NOT v_stream_has_data) THEN
        RETURN 'NO_DATA: Stream has no new records to process.';
    END IF;

    -- --------------------------------------------------------
    -- STEP 1: Stage stream data into a temp table
    --         (consuming the stream so it resets)
    -- --------------------------------------------------------
    CREATE OR REPLACE TEMPORARY TABLE SUPPLIER_DW.SILVER._STG_STREAM_DATA AS
    SELECT
        SUPPLIER_ID,
        SUPPLIER_NAME,
        COUNTRY_CODE,
        REGION,
        CATEGORY,
        CONTRACT_VALUE_USD,
        LEAD_TIME_DAYS,
        QUALITY_SCORE,
        ON_TIME_DELIVERY_PCT,
        RISK_RATING,
        LAST_AUDIT_DATE,
        IS_ACTIVE,
        _SOURCE_FILE_NAME,
        _SOURCE_ROW_NUMBER,
        _BATCH_ID,
        _LOAD_TS,
        CASE WHEN
            SUPPLIER_ID IS NULL
            OR SUPPLIER_NAME IS NULL OR TRIM(SUPPLIER_NAME) = ''
            OR REGION IS NULL OR TRIM(REGION) = ''
            OR COUNTRY_CODE IS NULL OR TRIM(COUNTRY_CODE) = ''
            OR QUALITY_SCORE IS NULL OR QUALITY_SCORE NOT BETWEEN 0 AND 100
            OR ON_TIME_DELIVERY_PCT IS NULL OR ON_TIME_DELIVERY_PCT NOT BETWEEN 0 AND 100
            OR CONTRACT_VALUE_USD IS NULL OR CONTRACT_VALUE_USD < 0
            OR LEAD_TIME_DAYS IS NULL OR LEAD_TIME_DAYS < 0
        THEN FALSE ELSE TRUE END AS _DQ_PASSED
    FROM SUPPLIER_DW.BRONZE.STR_RAW_SUPPLIERS
    WHERE METADATA$ACTION = 'INSERT';

    -- --------------------------------------------------------
    -- STEP 2: Insert REJECTED records (DQ failures)
    -- --------------------------------------------------------
    INSERT INTO SUPPLIER_DW.SILVER.REJECTED_SUPPLIERS (
        SUPPLIER_ID,
        SUPPLIER_NAME,
        COUNTRY_CODE,
        REGION,
        CATEGORY,
        CONTRACT_VALUE_USD,
        LEAD_TIME_DAYS,
        QUALITY_SCORE,
        ON_TIME_DELIVERY_PCT,
        RISK_RATING,
        LAST_AUDIT_DATE,
        IS_ACTIVE,
        REJECTION_REASON,
        SOURCE_FILE_NAME,
        SOURCE_ROW_NUMBER
    )
    SELECT
        SUPPLIER_ID,
        SUPPLIER_NAME,
        COUNTRY_CODE,
        REGION,
        CATEGORY,
        CONTRACT_VALUE_USD,
        LEAD_TIME_DAYS,
        QUALITY_SCORE,
        ON_TIME_DELIVERY_PCT,
        RISK_RATING,
        LAST_AUDIT_DATE,
        IS_ACTIVE,
        -- Build rejection reason string
        TRIM(
            CASE WHEN SUPPLIER_ID IS NULL THEN 'NULL_SUPPLIER_ID | ' ELSE '' END ||
            CASE WHEN SUPPLIER_NAME IS NULL OR TRIM(SUPPLIER_NAME) = '' THEN 'BLANK_SUPPLIER_NAME | ' ELSE '' END ||
            CASE WHEN REGION IS NULL OR TRIM(REGION) = '' THEN 'BLANK_REGION | ' ELSE '' END ||
            CASE WHEN COUNTRY_CODE IS NULL OR TRIM(COUNTRY_CODE) = '' THEN 'BLANK_COUNTRY_CODE | ' ELSE '' END ||
            CASE WHEN QUALITY_SCORE IS NULL THEN 'NULL_QUALITY_SCORE | ' ELSE '' END ||
            CASE WHEN QUALITY_SCORE NOT BETWEEN 0 AND 100 THEN 'QUALITY_SCORE_OUT_OF_RANGE | ' ELSE '' END ||
            CASE WHEN ON_TIME_DELIVERY_PCT IS NULL THEN 'NULL_ON_TIME_DELIVERY | ' ELSE '' END ||
            CASE WHEN ON_TIME_DELIVERY_PCT NOT BETWEEN 0 AND 100 THEN 'ON_TIME_DELIVERY_OUT_OF_RANGE | ' ELSE '' END ||
            CASE WHEN CONTRACT_VALUE_USD IS NULL THEN 'NULL_CONTRACT_VALUE | ' ELSE '' END ||
            CASE WHEN CONTRACT_VALUE_USD < 0 THEN 'NEGATIVE_CONTRACT_VALUE | ' ELSE '' END ||
            CASE WHEN LEAD_TIME_DAYS IS NULL THEN 'NULL_LEAD_TIME | ' ELSE '' END ||
            CASE WHEN LEAD_TIME_DAYS < 0 THEN 'NEGATIVE_LEAD_TIME | ' ELSE '' END
        , '| ')  AS REJECTION_REASON,
        _SOURCE_FILE_NAME,
        _SOURCE_ROW_NUMBER
    FROM SUPPLIER_DW.SILVER._STG_STREAM_DATA
    WHERE _DQ_PASSED = FALSE;

    v_rows_rejected := SQLROWCOUNT;

    -- --------------------------------------------------------
    -- STEP 3: Upsert clean records into SUPPLIERS_CLEAN
    --         (current-state table, one row per supplier)
    -- --------------------------------------------------------
    MERGE INTO SUPPLIER_DW.SILVER.SUPPLIERS_CLEAN AS tgt
    USING (
        SELECT
            SUPPLIER_ID,
            TRIM(UPPER(SUPPLIER_NAME))    AS SUPPLIER_NAME,
            TRIM(UPPER(COUNTRY_CODE))     AS COUNTRY_CODE,
            TRIM(UPPER(REGION))           AS REGION,
            TRIM(UPPER(CATEGORY))         AS CATEGORY,
            CONTRACT_VALUE_USD,
            LEAD_TIME_DAYS,
            QUALITY_SCORE,
            ON_TIME_DELIVERY_PCT,
            TRIM(UPPER(RISK_RATING))      AS RISK_RATING,
            LAST_AUDIT_DATE,
            IS_ACTIVE,
            _SOURCE_FILE_NAME             AS SOURCE_FILE_NAME,
            _SOURCE_ROW_NUMBER            AS SOURCE_ROW_NUMBER,
            MD5(
                COALESCE(TRIM(UPPER(SUPPLIER_NAME)), '') || '|' ||
                COALESCE(TRIM(UPPER(COUNTRY_CODE)), '')  || '|' ||
                COALESCE(TRIM(UPPER(REGION)), '')        || '|' ||
                COALESCE(TRIM(UPPER(CATEGORY)), '')      || '|' ||
                COALESCE(CONTRACT_VALUE_USD::VARCHAR, '') || '|' ||
                COALESCE(LEAD_TIME_DAYS::VARCHAR, '')    || '|' ||
                COALESCE(QUALITY_SCORE::VARCHAR, '')     || '|' ||
                COALESCE(ON_TIME_DELIVERY_PCT::VARCHAR, '') || '|' ||
                COALESCE(TRIM(UPPER(RISK_RATING)), '')   || '|' ||
                COALESCE(LAST_AUDIT_DATE::VARCHAR, '')   || '|' ||
                COALESCE(IS_ACTIVE::VARCHAR, '')
            ) AS RECORD_HASH
        FROM SUPPLIER_DW.SILVER._STG_STREAM_DATA
        WHERE _DQ_PASSED = TRUE
    ) AS src
    ON tgt.SUPPLIER_ID = src.SUPPLIER_ID
    WHEN MATCHED AND tgt.RECORD_HASH <> src.RECORD_HASH THEN
        UPDATE SET
            tgt.SUPPLIER_NAME        = src.SUPPLIER_NAME,
            tgt.COUNTRY_CODE         = src.COUNTRY_CODE,
            tgt.REGION               = src.REGION,
            tgt.CATEGORY             = src.CATEGORY,
            tgt.CONTRACT_VALUE_USD   = src.CONTRACT_VALUE_USD,
            tgt.LEAD_TIME_DAYS       = src.LEAD_TIME_DAYS,
            tgt.QUALITY_SCORE        = src.QUALITY_SCORE,
            tgt.ON_TIME_DELIVERY_PCT = src.ON_TIME_DELIVERY_PCT,
            tgt.RISK_RATING          = src.RISK_RATING,
            tgt.LAST_AUDIT_DATE      = src.LAST_AUDIT_DATE,
            tgt.IS_ACTIVE            = src.IS_ACTIVE,
            tgt.SOURCE_FILE_NAME     = src.SOURCE_FILE_NAME,
            tgt.SOURCE_ROW_NUMBER    = src.SOURCE_ROW_NUMBER,
            tgt.LOAD_TS              = CURRENT_TIMESTAMP(),
            tgt.RECORD_HASH          = src.RECORD_HASH
    WHEN NOT MATCHED THEN
        INSERT (
            SUPPLIER_ID, SUPPLIER_NAME, COUNTRY_CODE, REGION, CATEGORY,
            CONTRACT_VALUE_USD, LEAD_TIME_DAYS, QUALITY_SCORE, ON_TIME_DELIVERY_PCT,
            RISK_RATING, LAST_AUDIT_DATE, IS_ACTIVE,
            SOURCE_FILE_NAME, SOURCE_ROW_NUMBER, RECORD_HASH
        )
        VALUES (
            src.SUPPLIER_ID, src.SUPPLIER_NAME, src.COUNTRY_CODE, src.REGION, src.CATEGORY,
            src.CONTRACT_VALUE_USD, src.LEAD_TIME_DAYS, src.QUALITY_SCORE, src.ON_TIME_DELIVERY_PCT,
            src.RISK_RATING, src.LAST_AUDIT_DATE, src.IS_ACTIVE,
            src.SOURCE_FILE_NAME, src.SOURCE_ROW_NUMBER, src.RECORD_HASH
        );

    v_rows_clean := SQLROWCOUNT;

    -- --------------------------------------------------------
    -- STEP 4: SCD Type-2 — Expire changed current rows
    -- --------------------------------------------------------
    UPDATE SUPPLIER_DW.SILVER.DIM_SUPPLIERS tgt
    SET
        tgt.IS_CURRENT = FALSE,
        tgt.VALID_TO   = CURRENT_TIMESTAMP()
    WHERE tgt.IS_CURRENT = TRUE
      AND EXISTS (
          SELECT 1
          FROM SUPPLIER_DW.SILVER.SUPPLIERS_CLEAN src
          WHERE src.SUPPLIER_ID = tgt.SUPPLIER_ID
            AND src.RECORD_HASH <> tgt.RECORD_HASH
      );

    v_rows_scd_expired := SQLROWCOUNT;

    -- --------------------------------------------------------
    -- STEP 5: SCD Type-2 — Insert new version of changed +
    --         brand new records into DIM_SUPPLIERS
    -- --------------------------------------------------------
    INSERT INTO SUPPLIER_DW.SILVER.DIM_SUPPLIERS (
        SUPPLIER_ID, SUPPLIER_NAME, COUNTRY_CODE, REGION, CATEGORY,
        CONTRACT_VALUE_USD, LEAD_TIME_DAYS, QUALITY_SCORE, ON_TIME_DELIVERY_PCT,
        RISK_RATING, LAST_AUDIT_DATE, IS_ACTIVE,
        DQ_PASSED, DQ_FAIL_REASONS, RECORD_HASH,
        VALID_FROM, VALID_TO, IS_CURRENT,
        SOURCE_FILE_NAME, SOURCE_ROW_NUMBER
    )
    SELECT
        src.SUPPLIER_ID,
        src.SUPPLIER_NAME,
        src.COUNTRY_CODE,
        src.REGION,
        src.CATEGORY,
        src.CONTRACT_VALUE_USD,
        src.LEAD_TIME_DAYS,
        src.QUALITY_SCORE,
        src.ON_TIME_DELIVERY_PCT,
        src.RISK_RATING,
        src.LAST_AUDIT_DATE,
        src.IS_ACTIVE,
        TRUE                    AS DQ_PASSED,
        NULL                    AS DQ_FAIL_REASONS,
        src.RECORD_HASH,
        CURRENT_TIMESTAMP()     AS VALID_FROM,
        NULL                    AS VALID_TO,
        TRUE                    AS IS_CURRENT,
        src.SOURCE_FILE_NAME,
        src.SOURCE_ROW_NUMBER
    FROM SUPPLIER_DW.SILVER.SUPPLIERS_CLEAN src
    WHERE NOT EXISTS (
        SELECT 1
        FROM SUPPLIER_DW.SILVER.DIM_SUPPLIERS dim
        WHERE dim.SUPPLIER_ID = src.SUPPLIER_ID
          AND dim.IS_CURRENT  = TRUE
    );

    v_rows_scd_inserted := SQLROWCOUNT;

    -- --------------------------------------------------------
    -- STEP 6: Audit log
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
        'TASK_BRONZE_TO_SILVER',
        'SP_BRONZE_TO_SILVER',
        :v_start_time,
        CURRENT_TIMESTAMP(),
        :v_rows_clean + :v_rows_rejected,
        :v_rows_scd_inserted,
        :v_rows_scd_expired,
        :v_rows_rejected,
        'SUCCESS',
        NULL
    );

    -- Clean up temp table
    DROP TABLE IF EXISTS SUPPLIER_DW.SILVER._STG_STREAM_DATA;

    RETURN 'SUCCESS: clean_records=' || :v_rows_clean
        || ' | rejected=' || :v_rows_rejected
        || ' | scd_new_versions=' || :v_rows_scd_inserted
        || ' | scd_expired=' || :v_rows_scd_expired;

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
            'TASK_BRONZE_TO_SILVER',
            'SP_BRONZE_TO_SILVER',
            :v_start_time,
            CURRENT_TIMESTAMP(),
            0, 0, 0, 0,
            'FAILED',
            SQLERRM
        );

        DROP TABLE IF EXISTS SUPPLIER_DW.SILVER._STG_STREAM_DATA;

        RETURN 'FAILED: ' || SQLERRM;
END;
$$;

-- --------------------------------------------------------
-- Quick test (uncomment to run manually)
-- --------------------------------------------------------
-- CALL SUPPLIER_DW.SILVER.SP_BRONZE_TO_SILVER();

-- Verify results
-- SELECT IS_CURRENT, COUNT(*) FROM SUPPLIER_DW.SILVER.DIM_SUPPLIERS GROUP BY 1;
-- SELECT * FROM SUPPLIER_DW.SILVER.REJECTED_SUPPLIERS LIMIT 10;
-- SELECT * FROM SUPPLIER_DW.AUDIT.PIPELINE_RUN_LOG ORDER BY START_TIME DESC LIMIT 5;