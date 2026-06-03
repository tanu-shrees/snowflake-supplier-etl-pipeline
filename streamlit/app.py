"""
Snowflake Supplier ETL Pipeline - Dashboard
Connects to SUPPLIER_DW.GOLD layer and displays KPIs, charts, and risk analysis.

Usage:
    pip install streamlit snowflake-connector-python pandas
    streamlit run streamlit/app.py
"""

import streamlit as st
import snowflake.connector
import pandas as pd

# -----------------------------------------------------------
# Page config
# -----------------------------------------------------------
st.set_page_config(
    page_title="Supplier Analytics Dashboard",
    page_icon="📊",
    layout="wide"
)

st.title("Supplier Analytics Dashboard")
st.caption("Real-time insights from the Gold layer | SUPPLIER_DW.GOLD")

# -----------------------------------------------------------
# Connection (uses Streamlit secrets or manual input)
# -----------------------------------------------------------
@st.cache_resource
def get_connection():
    """Create Snowflake connection using Streamlit secrets."""
    return snowflake.connector.connect(
        account=st.secrets["snowflake"]["account"],
        user=st.secrets["snowflake"]["user"],
        password=st.secrets["snowflake"]["password"],
        warehouse=st.secrets["snowflake"]["warehouse"],
        database=st.secrets["snowflake"]["database"],
        schema=st.secrets["snowflake"]["schema"],
        role=st.secrets["snowflake"]["role"]
    )

@st.cache_data(ttl=300)
def run_query(query):
    """Execute a query and return a DataFrame."""
    conn = get_connection()
    cur = conn.cursor()
    cur.execute(query)
    columns = [desc[0] for desc in cur.description]
    data = cur.fetchall()
    return pd.DataFrame(data, columns=columns)

# -----------------------------------------------------------
# Sidebar
# -----------------------------------------------------------
st.sidebar.header("Filters")
st.sidebar.info(
    "This dashboard reads from:\n"
    "- `GOLD.VW_REGIONAL_SUMMARY`\n"
    "- `GOLD.VW_CATEGORY_SUMMARY`\n"
    "- `GOLD.VW_RISK_SCORECARD`\n"
    "- `GOLD.VW_SUPPLIER_RANKINGS`\n"
    "- `AUDIT.PIPELINE_RUN_LOG`"
)

# -----------------------------------------------------------
# KPI Section
# -----------------------------------------------------------
st.header("Key Performance Indicators")

try:
    kpi_query = """
    SELECT
        COUNT(*) AS total_suppliers,
        SUM(CASE WHEN IS_ACTIVE = TRUE THEN 1 ELSE 0 END) AS active_suppliers,
        ROUND(SUM(CONTRACT_VALUE_USD), 0) AS total_contract_value,
        ROUND(AVG(QUALITY_SCORE), 1) AS avg_quality_score,
        ROUND(AVG(ON_TIME_DELIVERY_PCT), 1) AS avg_on_time_pct,
        SUM(CASE WHEN RISK_RATING = 'HIGH' THEN 1 ELSE 0 END) AS high_risk_count
    FROM SUPPLIER_DW.SILVER.SUPPLIERS_CLEAN
    """
    kpi = run_query(kpi_query)

    col1, col2, col3, col4, col5, col6 = st.columns(6)
    col1.metric("Total Suppliers", f"{kpi['TOTAL_SUPPLIERS'][0]:,}")
    col2.metric("Active", f"{kpi['ACTIVE_SUPPLIERS'][0]:,}")
    col3.metric("Total Contract Value", f"${kpi['TOTAL_CONTRACT_VALUE'][0]:,.0f}")
    col4.metric("Avg Quality Score", f"{kpi['AVG_QUALITY_SCORE'][0]}")
    col5.metric("Avg On-Time %", f"{kpi['AVG_ON_TIME_PCT'][0]}%")
    col6.metric("High Risk", f"{kpi['HIGH_RISK_COUNT'][0]}", delta_color="inverse")

except Exception as e:
    st.error(f"Connection error: {e}")
    st.info(
        "To connect, create `.streamlit/secrets.toml` with:\n"
        "```toml\n"
        "[snowflake]\n"
        'account = "your_account"\n'
        'user = "your_user"\n'
        'password = "your_password"\n'
        'warehouse = "SUPPLIER_ANALYTICS_WH"\n'
        'database = "SUPPLIER_DW"\n'
        'schema = "GOLD"\n'
        'role = "SUPPLIER_ANALYST_ROLE"\n'
        "```"
    )
    st.stop()

# -----------------------------------------------------------
# Regional Summary
# -----------------------------------------------------------
st.header("Regional Summary")

regional = run_query("SELECT * FROM SUPPLIER_DW.GOLD.VW_REGIONAL_SUMMARY")

col1, col2 = st.columns(2)

with col1:
    st.subheader("Suppliers by Region")
    chart_data = regional[["REGION", "SUPPLIER_COUNT"]].set_index("REGION")
    st.bar_chart(chart_data)

with col2:
    st.subheader("Avg Quality Score by Region")
    chart_data = regional[["REGION", "AVG_QUALITY_SCORE"]].set_index("REGION")
    st.bar_chart(chart_data)

st.dataframe(regional, use_container_width=True, hide_index=True)

# -----------------------------------------------------------
# Category Summary
# -----------------------------------------------------------
st.header("Category Summary")

category = run_query("SELECT * FROM SUPPLIER_DW.GOLD.VW_CATEGORY_SUMMARY")

col1, col2 = st.columns(2)

with col1:
    st.subheader("Contract Value by Category")
    chart_data = category[["CATEGORY", "TOTAL_CONTRACT_VALUE"]].set_index("CATEGORY")
    st.bar_chart(chart_data)

with col2:
    st.subheader("On-Time Delivery % by Category")
    chart_data = category[["CATEGORY", "AVG_ON_TIME_DELIVERY_PCT"]].set_index("CATEGORY")
    st.bar_chart(chart_data)

# -----------------------------------------------------------
# Risk Scorecard
# -----------------------------------------------------------
st.header("Risk Scorecard")
st.caption("Suppliers flagged as HIGH risk or underperforming")

risk = run_query("""
    SELECT SUPPLIER_ID, SUPPLIER_NAME, REGION, CATEGORY,
           QUALITY_SCORE, ON_TIME_DELIVERY_PCT, RISK_RATING,
           RISK_LEVEL, DAYS_SINCE_AUDIT, AUDIT_OVERDUE
    FROM SUPPLIER_DW.GOLD.VW_RISK_SCORECARD
    ORDER BY RISK_LEVEL DESC, QUALITY_SCORE ASC
""")

# Color-code risk levels
risk_filter = st.multiselect(
    "Filter by Risk Level",
    options=risk["RISK_LEVEL"].unique().tolist(),
    default=risk["RISK_LEVEL"].unique().tolist()
)
filtered_risk = risk[risk["RISK_LEVEL"].isin(risk_filter)]
st.dataframe(filtered_risk, use_container_width=True, hide_index=True)

# -----------------------------------------------------------
# Supplier Rankings
# -----------------------------------------------------------
st.header("Supplier Rankings")

rankings = run_query("""
    SELECT SUPPLIER_NAME, REGION, CATEGORY, PERFORMANCE_SCORE,
           OVERALL_RANK, RANK_IN_REGION, PERFORMANCE_TIER
    FROM SUPPLIER_DW.GOLD.VW_SUPPLIER_RANKINGS
    ORDER BY OVERALL_RANK
    LIMIT 20
""")

col1, col2 = st.columns(2)
with col1:
    st.subheader("Top 20 Suppliers")
    st.dataframe(rankings, use_container_width=True, hide_index=True)

with col2:
    st.subheader("Performance Distribution")
    tier_counts = rankings["PERFORMANCE_TIER"].value_counts()
    st.bar_chart(tier_counts)

# -----------------------------------------------------------
# Pipeline Health (Audit Log)
# -----------------------------------------------------------
st.header("Pipeline Health")

audit = run_query("""
    SELECT TASK_NAME, PROCEDURE_NAME, START_TIME, END_TIME,
           ROWS_PROCESSED, ROWS_INSERTED, ROWS_REJECTED, STATUS
    FROM SUPPLIER_DW.AUDIT.PIPELINE_RUN_LOG
    ORDER BY START_TIME DESC
    LIMIT 10
""")
st.dataframe(audit, use_container_width=True, hide_index=True)

# -----------------------------------------------------------
# Footer
# -----------------------------------------------------------
st.divider()
st.caption("Data refreshes every 5 minutes via Snowflake Tasks | Source: SUPPLIER_DW.GOLD")
