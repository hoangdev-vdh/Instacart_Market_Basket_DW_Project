import sys
from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator as MsSqlOperator
from airflow.operators.empty import EmptyOperator

# Chèn đường dẫn thư mục src vào sys.path để import hàm Python
sys.path.insert(0, '/opt/airflow/src')
from extract_to_bronze import run_bronze_pipeline

default_args = {
    'owner': 'vdh.hoangdev', 
    'depends_on_past': False,
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=3),
}

with DAG(
    dag_id='instacart_end_to_end_pipeline',
    default_args=default_args,
    start_date=datetime(2026, 5, 30),
    schedule='@daily',
    catchup=False,
    tags=['instacart', 'etl', 'medallion', 'dwh']
) as dag:

    start_pipeline = EmptyOperator(task_id='start_pipeline')

    # ==========================================
    # TASK 1: BRONZE LAYER (Data Ingestion bằng Python)
    # ==========================================
    extract_bronze = PythonOperator(
        task_id='extract_raw_to_bronze',
        python_callable=run_bronze_pipeline
    )

    # ==========================================
    # TASK 2: SILVER LAYER (Data Cleaning & Columnstore Index)
    # ==========================================
    load_silver = MsSqlOperator(
        task_id='load_silver_layer',
        sql='EXEC sp_load_silver_layer;',
        conn_id='sql_server_connection',
        database='Instacart_DWH' 
    )

    # ==========================================
    # TASK 3: GOLD LAYER (Star Schema & MBA Pre-aggregation)
    # ==========================================
    load_gold = MsSqlOperator(
        task_id='load_gold_layer',
        sql='EXEC sp_load_gold_layer;',
        conn_id='sql_server_connection',
        database='Instacart_DWH'
    )

    end_pipeline = EmptyOperator(task_id='end_pipeline')

    # ==========================================
    # LUỒNG CHẠY PIPELINE (DAG DEPENDENCIES)
    # ==========================================
    start_pipeline >> extract_bronze >> load_silver >> load_gold >> end_pipeline