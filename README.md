# Snowflake Supplier ETL Pipeline

End-to-end data engineering pipeline built on Snowflake, implementing the **Medallion Architecture** (Bronze/Silver/Gold) with automated ingestion, data quality validation, SCD Type-2 tracking, and analytics-ready views.

## Architecture

```
  AWS S3 (CSV batches)
        |
        v
  [Snowpipe - Auto Ingest]
        |
        v
+-------+--------+-------+--------+-------+
|  BRONZE        |  SILVER        |  GOLD          |
|  (Raw Landing) |  (Cleansed)    |  (Analytics)   |
|                |                |                |
|  RAW_SUPPLIERS |  SUPPLIERS_    |  VW_REGIONAL_  |
|                |    CLEAN       |    SUMMARY     |
|  Stream (CDC)  |  DIM_SUPPLIERS |  VW_CATEGORY_  |
|                |    (SCD2)      |    SUMMARY     |
|                |  REJECTED_     |  VW_RISK_      |
|                |    SUPPLIERS   |    SCORECARD   |
|                |                |  VW_SUPPLIER_  |
|                |                |    RANKINGS    |
+----------------+----------------+----------------+
        |                |                |
        v                v                v
  [TASK: Bronze→Silver]  [TASK: Silver→Gold]
        |                        |
        v                        v
  [AUDIT.PIPELINE_RUN_LOG]  [Streamlit Dashboard]
```

## Pipeline Flow

1. **Ingestion**: CSV files land in S3 → Snowpipe auto-ingests into Bronze
2. **Bronze → Silver** (every 5 min, stream-driven):
   - Data quality validation (NULL checks, range checks)
   - Clean records → `SUPPLIERS_CLEAN` (MERGE with hash-based change detection)
   - Failed records → `REJECTED_SUPPLIERS` (with rejection reasons)
   - SCD Type-2 history → `DIM_SUPPLIERS` (expire old, insert new version)
3. **Silver → Gold** (triggered after Bronze→Silver succeeds):
   - Regional/Category aggregations
   - Risk scorecard with composite scoring
   - Supplier performance rankings with tier classification
   - KPI snapshot for dashboards
4. **Monitoring**: Every run logged to `AUDIT.PIPELINE_RUN_LOG`

## Features

| Feature | Implementation |
|---------|---------------|
| Auto-ingestion | Snowpipe with S3 event notifications |
| Change Data Capture | Streams on Bronze table |
| Data Quality | Multi-rule validation with rejection routing |
| Change Detection | MD5 hash comparison on MERGE |
| SCD Type-2 | Full history with VALID_FROM/VALID_TO/IS_CURRENT |
| Task Orchestration | Parent→Child DAG with stream-based trigger |
| Audit Logging | Every run tracked (rows processed, rejected, timing) |
| Error Handling | TRY/CATCH with failure logging |
| RBAC | 4 roles with least-privilege (Ingest, Transform, Analyst, Streamlit) |
| Analytics | Composite scoring, risk tiers, trend analysis |

## Tech Stack

- **Snowflake**: Warehouses, Snowpipe, Streams, Tasks, Stored Procedures
- **AWS S3**: External stage for raw CSV files
- **Streamlit**: Dashboard for KPI visualization
- **SQL**: Snowflake SQL with Scripting (procedures)

## Project Structure

```
snowflake-supplier-etl-pipeline/
├── sql/
│   ├── 01_setup_database.sql        # Database, schemas, warehouses
│   ├── 02_bronze_tables.sql         # Raw landing tables + stream
│   ├── 03_s3_stage_snowpipe.sql     # S3 integration, stage, Snowpipe
│   ├── 04_silver_tables.sql         # Clean tables + DIM (SCD2)
│   ├── 05_sp_bronze_to_silver.sql   # Stored procedure: Bronze→Silver
│   ├── 06_audit_tables.sql          # Pipeline run log + DQ metrics
│   ├── 07_gold_tables.sql           # Analytics views + materialized tables
│   ├── 08_sp_silver_to_gold.sql     # Stored procedure: Silver→Gold
│   ├── 09_tasks.sql                 # Scheduled task DAG
│   └── 10_rbac_setup.sql           # Role-based access control
├── data/
│   ├── suppliers_batch_001.csv      # Sample batch files (6 batches)
│   ├── suppliers_batch_002.csv
│   ├── suppliers_batch_003.csv
│   ├── suppliers_batch_004.csv
│   ├── suppliers_batch_005.csv
│   ├── suppliers_batch_006.csv
│   └── suppliers_updates_batch.csv  # Update batch (triggers SCD2)
├── streamlit/
│   └── app.py                       # Dashboard connecting to Gold layer
└── README.md
```

## Setup Instructions

### Prerequisites
- Snowflake account (Enterprise edition recommended)
- AWS account with S3 bucket
- Python 3.8+ (for Streamlit dashboard)

### Step 1: Run SQL scripts in order
```sql
-- Execute in Snowflake worksheet, in order:
-- 01_setup_database.sql
-- 02_bronze_tables.sql
-- 03_s3_stage_snowpipe.sql  (update ARN with your IAM role)
-- 04_silver_tables.sql
-- 05_sp_bronze_to_silver.sql
-- 06_audit_tables.sql
-- 07_gold_tables.sql
-- 08_sp_silver_to_gold.sql
-- 09_tasks.sql
-- 10_rbac_setup.sql
```

### Step 2: Configure AWS
1. Create S3 bucket and upload CSV files from `data/`
2. Update IAM role trust policy with Snowflake's external ID (from `DESC INTEGRATION`)
3. Configure S3 event notification → SQS (from `DESC PIPE`)

### Step 3: Run Streamlit dashboard
```bash
pip install streamlit snowflake-connector-python
streamlit run streamlit/app.py
```

## Sample Data

The `data/` folder contains 7 CSV files (195 records total):
- 6 initial batch files (25 suppliers each across APAC, AMER, EMEA, LATAM)
- 1 updates batch (45 records that trigger SCD2 changes)

Columns: supplier_id, supplier_name, country_code, region, category, contract_value_usd, lead_time_days, quality_score, on_time_delivery_pct, risk_rating, last_audit_date, is_active

## Key Design Decisions

1. **Stream-driven tasks** over scheduled polling — only runs when new data exists (cost-efficient)
2. **Hash-based change detection** — avoids updating unchanged records
3. **Separate rejection table** — enables DQ monitoring without losing bad data
4. **CTAS for temp staging** — consumes stream atomically, prevents partial processing
5. **Role hierarchy** — Analyst inherits Streamlit access, all roll up to SYSADMIN
