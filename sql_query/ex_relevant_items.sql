-- Tìm top 10 sản phẩm hay mua kèm với "Bag of Organic Bananas" nhất
SELECT TOP 10
    p.product_name AS San_Pham_Mua_Kem,
    f.items_bought_together AS So_Lan_Mua_Chung
FROM gold.fact_market_basket f
INNER JOIN gold.dim_products p 
    ON f.product_id_B = p.product_id
WHERE f.product_id_A = (
    SELECT product_id 
    FROM gold.dim_products 
    WHERE product_name = 'Bag of Organic Bananas'
)
ORDER BY f.items_bought_together DESC;