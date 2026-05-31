-- 1. Create Schema for Gold Layer
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'gold')
BEGIN
    EXEC('CREATE SCHEMA gold');
END
GO

-- 2. Create the Stored Procedure
CREATE OR ALTER PROCEDURE sp_load_gold_layer
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        PRINT '--- STARTING GOLD LAYER (STAR SCHEMA) PROCESS ---';

        -- ==========================================
        -- DIM_PRODUCTS (Denormalizing Snowflake into Star)
        -- ==========================================
        PRINT 'Building gold.dim_products...';
        DROP TABLE IF EXISTS gold.dim_products;
        
        SELECT 
            p.product_id,
            p.product_name,
            d.department,
            a.aisle
        INTO gold.dim_products
        FROM silver.products p
        LEFT JOIN silver.departments d ON p.department_id = d.department_id
        LEFT JOIN silver.aisles a ON p.aisle_id = a.aisle_id;

        -- Add Primary Key
        ALTER TABLE gold.dim_products ADD CONSTRAINT PK_dim_products PRIMARY KEY CLUSTERED (product_id);

        -- ==========================================
        -- DIM_USERS (Dynamic Generation from Orders)
        -- ==========================================
        PRINT 'Building gold.dim_users...';
        DROP TABLE IF EXISTS gold.dim_users;
        
        -- Generating user dimension with some derived attributes for analytical power
        SELECT 
            user_id,
            COUNT(DISTINCT order_id) AS total_lifetime_orders,
            MAX(order_number) AS max_order_sequence
        INTO gold.dim_users
        FROM silver.orders
        GROUP BY user_id;

        -- Add Primary Key
        ALTER TABLE gold.dim_users ADD CONSTRAINT PK_dim_users PRIMARY KEY CLUSTERED (user_id);

        -- ==========================================
        -- DIM_TIME_SLOT (Handling Day of Week & Hour)
        -- ==========================================
        PRINT 'Building gold.dim_time_slot...';
        DROP TABLE IF EXISTS gold.dim_time_slot;
        
        -- Generate distinct combinations directly from the orders table
        WITH DistinctTimes AS (
            SELECT DISTINCT order_dow, order_hour_of_day
            FROM silver.orders
        )
        SELECT 
            CAST((order_dow * 100) + order_hour_of_day AS SMALLINT) AS time_slot_id,
            order_dow,
            order_hour_of_day,
            CASE 
                WHEN order_dow IN (0, 1) THEN 'Weekend' -- Assuming 0=Sat, 1=Sun (or adjust based on business logic)
                ELSE 'Weekday' 
            END AS day_type,
            CASE 
                WHEN order_hour_of_day BETWEEN 6 AND 11 THEN 'Morning'
                WHEN order_hour_of_day BETWEEN 12 AND 17 THEN 'Afternoon'
                WHEN order_hour_of_day BETWEEN 18 AND 22 THEN 'Evening'
                ELSE 'Night'
            END AS time_of_day_name
        INTO gold.dim_time_slot
        FROM DistinctTimes;

        -- Add Primary Key
        ALTER TABLE gold.dim_time_slot ADD CONSTRAINT PK_dim_time_slot PRIMARY KEY CLUSTERED (time_slot_id);

        -- ==========================================
        -- FACT_ORDER_ITEMS (Massive Fact Table: ~33.8M rows)
        -- ==========================================
        PRINT 'Building gold.fact_order_items (Resolving grain to 1 row per product per order)...';
        DROP TABLE IF EXISTS gold.fact_order_items;
        
        SELECT 
            o.order_id,
            o.user_id,
            op.product_id,
            CAST((o.order_dow * 100) + o.order_hour_of_day AS SMALLINT) AS time_slot_id,
            o.eval_set,                     -- Keep to distinguish 'prior' vs 'train' in Power BI
            o.order_number,                 -- Sequence of order for this user
            o.days_since_prior_order,
            op.add_to_cart_order,
            op.reordered
        INTO gold.fact_order_items
        FROM silver.orders o
        INNER JOIN silver.order_products op 
            ON o.order_id = op.order_id;

        -- Create Clustered Columnstore Index for OLAP Performance
        PRINT 'Creating Clustered Columnstore Index on gold.fact_order_items... (This might take a few minutes)';
        CREATE CLUSTERED COLUMNSTORE INDEX CCI_gold_fact_order_items 
        ON gold.fact_order_items;

        -- Optional: Non-Clustered Indexes on Foreign Keys can be added here if needed, 
        -- but CCI usually handles analytical queries well enough on its own.

        PRINT '--- GOLD LAYER PROCESS COMPLETED SUCCESSFULLY ---';

    END TRY
    BEGIN CATCH
        PRINT 'ERROR OCCURRED DURING GOLD LAYER PROCESSING!';
        PRINT 'Error Message: ' + ERROR_MESSAGE();
        PRINT 'Error Line: ' + CAST(ERROR_LINE() AS VARCHAR);
    END CATCH
END
GO