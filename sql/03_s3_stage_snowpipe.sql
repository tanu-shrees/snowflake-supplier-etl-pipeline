USE ROLE SYSADMIN;
USE DATABASE SUPPLIER_DW;
USE SCHEMA BRONZE;
USE WAREHOUSE SUPPLIER_INGEST_WH;

-- =====================================================
-- FILE 3: S3 STAGE + SNOWPIPE
-- Purpose:
-- 1) Create storage integration to access S3
-- 2) Create external stage for supplier batch CSV files
-- 3) Create Snowpipe for auto-ingest into BRONZE.RAW_SUPPLIERS
-- =====================================================

-- -----------------------------------------------------
-- 1) Storage integration (requires ACCOUNTADMIN)
-- -----------------------------------------------------
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE STORAGE INTEGRATION S3_SUPPLIER_INT
TYPE = EXTERNAL_STAGE
STORAGE_PROVIDER = S3
ENABLED = TRUE
STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:role/<YOUR_ROLE_NAME>'
STORAGE_ALLOWED_LOCATIONS = ('s3://<YOUR_BUCKET_NAME>/raw/');

-- Switch back to SYSADMIN
USE ROLE SYSADMIN;

-- -----------------------------------------------------
-- 2) Check Snowflake-generated IAM details
-- IMPORTANT:
-- Run this and copy the values of:
--   STORAGE_AWS_IAM_USER_ARN
--   STORAGE_AWS_EXTERNAL_ID
-- Then update the AWS IAM role trust policy accordingly
-- -----------------------------------------------------
DESC INTEGRATION S3_SUPPLIER_INT;

-- -----------------------------------------------------
-- 3) File format (must be created BEFORE the stage)
-- -----------------------------------------------------
CREATE OR REPLACE FILE FORMAT SUPPLIER_DW.BRONZE.FF_SUPPLIER_CSV
TYPE = CSV
FIELD_DELIMITER = ','
SKIP_HEADER = 1
FIELD_OPTIONALLY_ENCLOSED_BY = '"'
TRIM_SPACE = TRUE
EMPTY_FIELD_AS_NULL = TRUE
NULL_IF = ('NULL', 'null', '')
COMPRESSION = AUTO;

-- -----------------------------------------------------
-- 4) External stage
-- -----------------------------------------------------
CREATE OR REPLACE STAGE STG_SUPPLIER_RAW
STORAGE_INTEGRATION = S3_SUPPLIER_INT
URL = 's3://<YOUR_BUCKET_NAME>/raw/'
FILE_FORMAT = SUPPLIER_DW.BRONZE.FF_SUPPLIER_CSV;

-- Optional check: list files visible in the stage
LIST @STG_SUPPLIER_RAW;

-- -----------------------------------------------------
-- 4) Snowpipe
-- This maps the 12 CSV columns + staged file metadata
-- into BRONZE.RAW_SUPPLIERS
-- -----------------------------------------------------
CREATE OR REPLACE PIPE PIPE_RAW_SUPPLIERS
AUTO_INGEST = TRUE
AS
COPY INTO SUPPLIER_DW.BRONZE.RAW_SUPPLIERS (
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
    _BATCH_ID
)
FROM (
    SELECT
        $1,
        $2,
        $3,
        $4,
        $5,
        $6,
        $7,
        $8,
        $9,
        $10,
        $11,
        $12,
        METADATA$FILENAME,
        METADATA$FILE_ROW_NUMBER,
        SPLIT_PART(SPLIT_PART(METADATA$FILENAME, '/', -1), '.', 1)
    FROM @STG_SUPPLIER_RAW
)
ON_ERROR = 'CONTINUE';

-- -----------------------------------------------------
-- 5) Check pipe details
-- IMPORTANT:
-- Run this after pipe creation.
-- Copy the NOTIFICATION_CHANNEL value and use it
-- in AWS S3 event notification / SQS configuration.
-- -----------------------------------------------------
DESC PIPE PIPE_RAW_SUPPLIERS;

SHOW STAGES IN SCHEMA SUPPLIER_DW.BRONZE;
SHOW PIPES IN SCHEMA SUPPLIER_DW.BRONZE;