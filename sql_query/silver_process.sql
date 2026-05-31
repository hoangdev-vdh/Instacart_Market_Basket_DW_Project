USE Instacart_DWH;
GO

-- 1. Create Schema for Silver Layer
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'silver')
BEGIN
    EXEC('CREATE SCHEMA silver');
END
GO

-- 2. Create the Stored Procedure
CREATE OR ALTER PROCEDURE sp_load_silver_layer
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        PRINT '--- STARTING SILVER LAYER ELT PROCESS ---';

        -- ==========================================
        -- DIMENSION TABLES: aisles, departments, products
        -- ==========================================
        PRINT 'Processing silver.aisles...';
        DROP TABLE IF EXISTS silver.aisles;
        SELECT 
            CAST(aisle_id AS INT) AS aisle_id,
            CAST(aisle AS VARCHAR(255)) AS aisle,
            CAST(_etl_load_datetime AS DATETIME2) AS _etl_load_datetime
        INTO silver.aisles
        FROM bronze.aisles;

        PRINT 'Processing silver.departments...';
        DROP TABLE IF EXISTS silver.departments;
        SELECT 
            CAST(department_id AS INT) AS department_id,
            CAST(department AS VARCHAR(255)) AS department,
            CAST(_etl_load_datetime AS DATETIME2) AS _etl_load_datetime
        INTO silver.departments
        FROM bronze.departments;

        PRINT 'Processing silver.products...';
        DROP TABLE IF EXISTS silver.products;
        SELECT 
            CAST(product_id AS INT) AS product_id,
            CAST(product_name AS VARCHAR(500)) AS product_name,
            CAST(aisle_id AS INT) AS aisle_id,
            CAST(department_id AS INT) AS department_id,
            CAST(_etl_load_datetime AS DATETIME2) AS _etl_load_datetime
        INTO silver.products
        FROM bronze.products;

        -- ==========================================
        -- FACT-RELATED TABLE: orders
        -- ==========================================
        PRINT 'Processing silver.orders...';
        DROP TABLE IF EXISTS silver.orders;
        SELECT 
            CAST(order_id AS INT) AS order_id,
            CAST(user_id AS INT) AS user_id,
            CAST(eval_set AS VARCHAR(50)) AS eval_set,
            CAST(order_number AS INT) AS order_number,
            CAST(order_dow AS TINYINT) AS order_dow, -- TINYINT (0-255) is perfect for Days of Week
            CAST(order_hour_of_day AS TINYINT) AS order_hour_of_day, -- TINYINT is perfect for Hours (0-23)
            -- Use TRY_CAST and NULLIF to handle empty strings or 'nan' strings
            TRY_CAST(NULLIF(days_since_prior_order, '') AS FLOAT) AS days_since_prior_order,
            CAST(_etl_load_datetime AS DATETIME2) AS _etl_load_datetime
        INTO silver.orders
        FROM bronze.orders;

        -- ==========================================
        -- MASSIVE CONSOLIDATION: order_products
        -- ==========================================
        PRINT 'Processing silver.order_products (UNION ALL 33.8M rows)...';
        DROP TABLE IF EXISTS silver.order_products;
        
        SELECT 
            CAST(order_id AS INT) AS order_id,
            CAST(product_id AS INT) AS product_id,
            CAST(add_to_cart_order AS INT) AS add_to_cart_order,
            CAST(reordered AS TINYINT) AS reordered, -- Boolean flag (0 or 1), TINYINT is best
            CAST(_source_file_name AS VARCHAR(255)) AS _source_file_name,
            CAST(_etl_load_datetime AS DATETIME2) AS _etl_load_datetime
        INTO silver.order_products
        FROM (
            -- UNION ALL is used instead of UNION to skip the expensive deduplication sort
            SELECT order_id, product_id, add_to_cart_order, reordered, _source_file_name, _etl_load_datetime 
            FROM bronze.order_products__prior
            
            UNION ALL
            
            SELECT order_id, product_id, add_to_cart_order, reordered, _source_file_name, _etl_load_datetime 
            FROM bronze.order_products__train
        ) AS combined_order_products;

        -- Create a Clustered Columnstore Index for massive performance gain in Gold Layer queries
        PRINT 'Creating Clustered Columnstore Index on silver.order_products...';
        CREATE CLUSTERED COLUMNSTORE INDEX CCI_silver_order_products 
        ON silver.order_products;

        PRINT '--- SILVER LAYER ELT PROCESS COMPLETED SUCCESSFULLY ---';

    END TRY
    BEGIN CATCH
        PRINT 'ERROR OCCURRED DURING SILVER LAYER PROCESSING!';
        PRINT 'Error Message: ' + ERROR_MESSAGE();
        PRINT 'Error Line: ' + CAST(ERROR_LINE() AS VARCHAR);
    END CATCH
END
GO

EXEC sp_load_silver_layer;