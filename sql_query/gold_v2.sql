-- ============================================================================
-- DỰ ÁN: INSTACART MARKET BASKET ANALYSIS
-- TẦNG DỮ LIỆU: GOLD LAYER (STAR SCHEMA)
-- KIẾN TRÚC: DUAL-FACT TABLES (HEADER/LINE GRAIN)
-- ============================================================================

IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'gold')
BEGIN
    EXEC('CREATE SCHEMA gold');
END
GO

CREATE OR ALTER PROCEDURE sp_load_gold_layer
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        PRINT '===================================================';
        PRINT 'BẮT ĐẦU CHẠY PIPELINE GOLD LAYER';
        PRINT '===================================================';

        -- ---------------------------------------------------------
        -- 1. DIM_PRODUCTS (Hạt độ: 1 dòng = 1 Sản phẩm)
        -- ---------------------------------------------------------
        PRINT '>> Building [gold].[dim_products]...';
        DROP TABLE IF EXISTS gold.dim_products;
        
        SELECT 
            p.product_id,
            p.product_name,
            CAST(ISNULL(d.department, 'Unknown') AS VARCHAR(100)) AS department,
            CAST(ISNULL(a.aisle, 'Unknown') AS VARCHAR(100)) AS aisle
        INTO gold.dim_products
        FROM silver.products p
        LEFT JOIN silver.departments d ON p.department_id = d.department_id
        LEFT JOIN silver.aisles a      ON p.aisle_id      = a.aisle_id;

        -- Ép NOT NULL trước khi tạo PK
        ALTER TABLE gold.dim_products ALTER COLUMN product_id INT NOT NULL;
        ALTER TABLE gold.dim_products ADD CONSTRAINT PK_dim_products PRIMARY KEY CLUSTERED (product_id);

        -- ---------------------------------------------------------
        -- 2. DIM_TIME_SLOT (Hạt độ: 1 dòng = 1 Khung giờ trong tuần)
        -- ---------------------------------------------------------
        PRINT '>> Building [gold].[dim_time_slot]...';
        DROP TABLE IF EXISTS gold.dim_time_slot;
        
        WITH DistinctTimes AS (
            SELECT DISTINCT order_dow, order_hour_of_day FROM silver.orders
        )
        SELECT 
            CAST((order_dow * 100) + order_hour_of_day AS SMALLINT) AS time_slot_id,
            CAST(order_dow AS TINYINT) AS order_dow,
            CAST(order_hour_of_day AS TINYINT) AS order_hour_of_day,
            CAST(CASE WHEN order_dow IN (0, 6) THEN 'Weekend' ELSE 'Weekday' END AS VARCHAR(20)) AS day_type,
            CAST(
                CASE 
                    WHEN order_hour_of_day BETWEEN 6  AND 11 THEN 'Morning'
                    WHEN order_hour_of_day BETWEEN 12 AND 17 THEN 'Afternoon'
                    WHEN order_hour_of_day BETWEEN 18 AND 22 THEN 'Evening'
                    ELSE 'Night'
                END AS VARCHAR(20)
            ) AS time_of_day_name
        INTO gold.dim_time_slot
        FROM DistinctTimes;

        ALTER TABLE gold.dim_time_slot ALTER COLUMN time_slot_id SMALLINT NOT NULL;
        ALTER TABLE gold.dim_time_slot ADD CONSTRAINT PK_dim_time_slot PRIMARY KEY CLUSTERED (time_slot_id);

        -- ---------------------------------------------------------
        -- 3. DIM_USERS (Hạt độ: 1 dòng = 1 Người dùng - Behavioral Dimension)
        -- ---------------------------------------------------------
        PRINT '>> Building [gold].[dim_users]...';
        DROP TABLE IF EXISTS gold.dim_users;
        
        SELECT 
            user_id,
            COUNT(DISTINCT order_id) AS total_lifetime_orders,
            MAX(order_number) AS max_order_sequence,
            CAST(AVG(CAST(days_since_prior_order AS FLOAT)) AS FLOAT) AS avg_days_between_orders,
            CAST(MIN(CAST(days_since_prior_order AS FLOAT)) AS FLOAT) AS min_days_between_orders,
            CAST(MAX(CAST(days_since_prior_order AS FLOAT)) AS FLOAT) AS max_days_between_orders,
            COUNT(days_since_prior_order) AS orders_with_gap_data,
            CAST(
                CASE 
                    WHEN COUNT(DISTINCT order_id) >= 10 THEN 'High Frequency'
                    WHEN COUNT(DISTINCT order_id) >= 5  THEN 'Medium Frequency'
                    ELSE 'Low Frequency'
                END AS VARCHAR(30)
            ) AS user_segment
        INTO gold.dim_users
        FROM silver.orders
        GROUP BY user_id;

        ALTER TABLE gold.dim_users ALTER COLUMN user_id INT NOT NULL;
        ALTER TABLE gold.dim_users ADD CONSTRAINT PK_dim_users PRIMARY KEY CLUSTERED (user_id);

        -- ---------------------------------------------------------
        -- 4. DIM_ORDER_CATEGORY (Bảng tra cứu - Lookup Table)
        -- ---------------------------------------------------------
        PRINT '>> Building [gold].[dim_order_category]...';
        DROP TABLE IF EXISTS gold.dim_order_category;
        
        CREATE TABLE gold.dim_order_category (
            order_category_id   TINYINT     NOT NULL PRIMARY KEY,
            order_category_name VARCHAR(50) NOT NULL
        );
        INSERT INTO gold.dim_order_category VALUES
            (1, 'Historical Order (Prior)'),
            (2, 'Latest Order (Train)'),
            (3, 'Prediction Target (Test)'),
            (0, 'Unknown');

        -- ---------------------------------------------------------
        -- 5. FACT_ORDERS (Hạt độ: 1 dòng = 1 Đơn hàng | ~3.4M rows)
        -- Giải quyết The SUM Trap cho Measure "days_since_prior_order"
        -- ---------------------------------------------------------
        PRINT '>> Building [gold].[fact_orders] (Header Grain)...';
        DROP TABLE IF EXISTS gold.fact_orders;

        SELECT
            o.order_id,
            o.user_id,
            CAST((o.order_dow * 100) + o.order_hour_of_day AS SMALLINT) AS time_slot_id,
            CAST(
                CASE o.eval_set
                    WHEN 'prior' THEN 1
                    WHEN 'train' THEN 2
                    WHEN 'test'  THEN 3
                    ELSE 0
                END AS TINYINT
            ) AS order_category_id,
            o.order_number,
            -- Đây là Measure cấp độ Order
            CAST(o.days_since_prior_order AS FLOAT) AS days_since_prior_order
        INTO gold.fact_orders
        FROM silver.orders o;

        -- FIX LỖI: Ép NOT NULL
        ALTER TABLE gold.fact_orders ALTER COLUMN order_id INT NOT NULL;
        ALTER TABLE gold.fact_orders ADD CONSTRAINT PK_fact_orders PRIMARY KEY CLUSTERED (order_id);

        -- ---------------------------------------------------------
        -- 6. FACT_ORDER_ITEMS (Hạt độ: 1 dòng = 1 Món hàng | ~33.8M rows)
        -- Áp dụng "Inherited Dimensional Keys" để Power BI Join 1-hop
        -- ---------------------------------------------------------
        PRINT '>> Building [gold].[fact_order_items] (Line Item Grain)...';
        DROP TABLE IF EXISTS gold.fact_order_items;

        SELECT
            op.order_id,                -- Nối vào fact_orders
            o.user_id,                  -- Kế thừa (Denormalized) để nối thẳng dim_users
            CAST((o.order_dow * 100) + o.order_hour_of_day AS SMALLINT) AS time_slot_id, -- Nối thẳng dim_time_slot
            op.product_id,              -- Nối thẳng dim_products
            op.add_to_cart_order,       -- Measure: Thứ tự bỏ vào giỏ
            CAST(op.reordered AS TINYINT) AS reordered -- Measure: Tái đăng ký (0/1)
        INTO gold.fact_order_items
        FROM silver.order_products op
        INNER JOIN silver.orders o ON op.order_id = o.order_id;

        -- Dùng Clustered Columnstore Index (CCI) tối ưu nén và OLAP Scan
        PRINT '>> Creating Columnstore Index for 33.8M rows (Please wait)...';
        CREATE CLUSTERED COLUMNSTORE INDEX CCI_fact_order_items
            ON gold.fact_order_items;

        PRINT '===================================================';
        PRINT 'HOÀN THÀNH PIPELINE GOLD LAYER!';
        PRINT '===================================================';

    END TRY
    BEGIN CATCH
        PRINT 'LỖI NGHIÊM TRỌNG TRONG QUÁ TRÌNH CHẠY GOLD LAYER:';
        PRINT 'Error Message: ' + ERROR_MESSAGE();
        PRINT 'Error Line: ' + CAST(ERROR_LINE() AS VARCHAR);
    END CATCH
END
GO

EXEC sp_load_gold_layer;