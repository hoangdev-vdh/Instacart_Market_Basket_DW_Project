USE Instacart_DWH;
GO

PRINT '>> Building [gold].[fact_market_basket]...';
DROP TABLE IF EXISTS gold.fact_market_basket;

SELECT 
    op1.product_id AS product_id_A,
    op2.product_id AS product_id_B,
    COUNT(DISTINCT op1.order_id) AS items_bought_together
INTO gold.fact_market_basket
FROM silver.order_products op1
INNER JOIN silver.order_products op2 
    ON op1.order_id = op2.order_id 
    AND op1.product_id <> op2.product_id -- ĐÃ SỬA THÀNH DẤU KHÁC (<>)
GROUP BY 
    op1.product_id, 
    op2.product_id
HAVING 
    COUNT(DISTINCT op1.order_id) > 10;

CREATE CLUSTERED INDEX CIX_fact_market_basket ON gold.fact_market_basket(product_id_A, product_id_B);