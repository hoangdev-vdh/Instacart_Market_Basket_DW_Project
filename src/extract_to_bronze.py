import os
import shutil
import pandas as pd
from sqlalchemy import create_engine, text
from datetime import datetime

# 1. PATH CONFIGURATION & DATABASE CONNECTION
# Anchor path to the script's location
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BASE_DIR = os.path.join(SCRIPT_DIR, '..', 'data')
INBOUND_DIR = os.path.join(BASE_DIR, '1_Inbound_Data')
PROCESSING_DIR = os.path.join(BASE_DIR, '2_Processing_Data')
ARCHIVE_DIR = os.path.join(BASE_DIR, '3_Archive_Data')
ERROR_DIR = os.path.join(BASE_DIR, '4_Error_Data')

# Create directories if they don't exist
for directory in (INBOUND_DIR, PROCESSING_DIR, ARCHIVE_DIR, ERROR_DIR):
    os.makedirs(directory, exist_ok=True)

# Database credentials
SERVER_NAME = r'host.docker.internal,1433'  # Use host.docker.internal and port 1433 to connect to SQL Express
DATABASE_NAME = 'Instacart_DWH'
DB_USER = 'your_username'  # Replace with your SQL Server username
DB_PASSWORD = 'your_password'  # Replace with your SQL Server password

# Create SQL Server connection with SQL Server Authentication
conn_str = f"mssql+pyodbc://{DB_USER}:{DB_PASSWORD}@{SERVER_NAME}/{DATABASE_NAME}?driver=ODBC+Driver+17+for+SQL+Server"
engine = create_engine(conn_str, fast_executemany=True)

# Define Chunk Size for massive files (Instacart order_products__prior has 32.4M rows)
CHUNK_SIZE = 150000 

# 2. PIPELINE FUNCTION
def run_bronze_pipeline():
    # Ensure bronze schema exists
    with engine.begin() as conn:
        conn.execute(text("IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'bronze') BEGIN EXEC('CREATE SCHEMA [bronze]'); END"))

    # Scan for CSV files in the Inbound directory
    files_to_process = [f for f in os.listdir(INBOUND_DIR) if f.endswith('.csv')]
    
    if not files_to_process:
        print("No new files found in Inbound directory.")
        return

    for file_name in files_to_process:
        source_path = os.path.join(INBOUND_DIR, file_name)
        processing_path = os.path.join(PROCESSING_DIR, file_name)
        
        # Clean table name (e.g., 'order_products__prior.csv' -> 'order_products__prior')
        table_name = file_name.replace('.csv', '')

        try:
            print(f"\nProcessing file: {file_name} -> Table: bronze.{table_name}")
            
            # STEP A: Move file to Processing (Isolation to prevent locking issues)
            shutil.move(source_path, processing_path)
            
            # Define audit metrics
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            archive_name = f"{table_name}_{timestamp}.csv"
            etl_load_datetime = datetime.now()
            
            # STEP B & C: Read CSV in CHUNKS and push to SQL Server
            # dtype=str is kept to prevent Pandas from guessing types and crashing midway
            print(f"Reading and loading data in chunks of {CHUNK_SIZE} rows...")
            with pd.read_csv(processing_path, dtype=str, chunksize=CHUNK_SIZE) as chunk_iterator:
                for i, chunk in enumerate(chunk_iterator):
                    # Add Audit Columns to the current chunk
                    chunk['_source_file_name'] = archive_name
                    chunk['_etl_load_datetime'] = etl_load_datetime
                    
                    # Push chunk to Bronze layer
                    chunk.to_sql(
                        name=table_name, 
                        con=engine, 
                        schema='bronze', 
                        if_exists='append', 
                        index=False
                    )
                    
                    # Progress logging
                    rows_processed = (i + 1) * len(chunk)
                    print(f"  -> [{table_name}] Inserted chunk {i + 1} (~{rows_processed:,} rows)...")

            # STEP D: Success -> Move file to Archive
            archive_path = os.path.join(ARCHIVE_DIR, archive_name)
            shutil.move(processing_path, archive_path)
            print(f"SUCCESS! File archived to: {archive_path}")
            
        except Exception as e:
            # STEP E: Failure -> Move file to Error for debugging
            error_path = os.path.join(ERROR_DIR, file_name)
            shutil.move(processing_path, error_path)
            print(f"ERROR processing {file_name}. Moved to Error_Data. Details: {e}")

if __name__ == "__main__":
    print("STARTING BRONZE PIPELINE...")
    run_bronze_pipeline()
    print("PIPELINE COMPLETED!")