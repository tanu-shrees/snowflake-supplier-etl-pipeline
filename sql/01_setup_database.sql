USE ROLE SYSADMIN;

CREATE OR REPLACE DATABASE SUPPLIER_DW
COMMENT = 'Supplier Data Warehouse - Bronze / Silver / Gold';

-- Optional only if you truly want a separate raw database.
-- If not, skip this because BRONZE already acts as the raw landing layer.
-- CREATE OR REPLACE DATABASE SUPPLIER_RAW
-- COMMENT = 'Raw data landing from Snowpipe ingestion';

USE DATABASE SUPPLIER_DW;

CREATE OR REPLACE SCHEMA BRONZE
COMMENT = 'Raw data ingested from S3';

CREATE OR REPLACE SCHEMA SILVER
COMMENT = 'Cleansed and validated data';

CREATE OR REPLACE SCHEMA GOLD
COMMENT = 'Aggregated analytics-ready data';

CREATE OR REPLACE SCHEMA STAGING
COMMENT = 'Temporary tables for transforms';

CREATE OR REPLACE SCHEMA AUDIT
COMMENT = 'Pipeline health and lineage tracking';

CREATE OR REPLACE WAREHOUSE SUPPLIER_INGEST_WH
WITH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Used by Snowpipe and ingestion-related processing';

CREATE OR REPLACE WAREHOUSE SUPPLIER_TRANSFORM_WH
WITH
    WAREHOUSE_SIZE = 'SMALL'
    AUTO_SUSPEND = 120
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Used by scheduled tasks and stored procedures';

CREATE OR REPLACE WAREHOUSE SUPPLIER_ANALYTICS_WH
WITH
    WAREHOUSE_SIZE = 'SMALL'
    AUTO_SUSPEND = 120
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Used by BI queries and Streamlit dashboard';

SHOW DATABASES LIKE 'SUPPLIER%';
SHOW WAREHOUSES LIKE 'SUPPLIER%';
SHOW SCHEMAS IN DATABASE SUPPLIER_DW;