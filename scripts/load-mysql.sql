-- Loads the lab data set into MySQL (database shop). The formulas are the
-- same as in load-mongo.js. @n is the number of orders (multiple of 10000).
--
-- The schema follows a common large-scale e-commerce layout: an order table
-- and an order item table, no foreign keys, the sharding key (customer_id)
-- on both, order fields copied onto items so item reports need no JOIN, and
-- snapshots of values that must not change after the order is placed.
CREATE DATABASE IF NOT EXISTS shop;
USE shop;
DROP TABLE IF EXISTS order_items, orders, customers, nums;

CREATE TABLE nums (n INT PRIMARY KEY);
INSERT INTO nums WITH RECURSIVE s(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM s WHERE n < 9999) SELECT n FROM s;

-- Customers: current profile. Orders keep their own snapshot of what they need.
CREATE TABLE customers (
  id      INT PRIMARY KEY,
  name    VARCHAR(32),
  tier    VARCHAR(8),             -- current membership tier
  country VARCHAR(4));
INSERT INTO customers
  SELECT n, CONCAT('customer-', n), ELT(n % 3 + 1, 'gold', 'silver', 'bronze'), ELT(n % 5 + 1, 'SG', 'CN', 'US', 'DE', 'JP')
  FROM (SELECT x.n * 10000 + y.n + 1 AS n FROM nums x JOIN nums y WHERE x.n < 5) t;

-- Orders (order header).
CREATE TABLE orders (
  id            BIGINT PRIMARY KEY,
  customer_id   INT NOT NULL,     -- sharding key; "my orders" queries filter on it
  status        VARCHAR(12),      -- paid, shipped, delivered, cancelled, refunded
  amount        DECIMAL(10,2),
  created_at    DATETIME,
  region        VARCHAR(8) NULL,  -- optional
  customer_tier VARCHAR(8),       -- snapshot: tier at the time of the order
  KEY idx_customer_created (customer_id, created_at));
INSERT INTO orders
  SELECT n,
         (n * 7919) % 50000 + 1,
         ELT(n % 5 + 1, 'paid', 'shipped', 'delivered', 'cancelled', 'refunded'),
         ((n * 37) % 100000) / 100,
         TIMESTAMPADD(SECOND, (n * 13) % 31536000, '2026-01-01 00:00:00'),
         CASE WHEN n % 7 IN (0, 1) THEN NULL ELSE ELT(n % 3 + 1, 'apac', 'emea', 'amer') END,
         ELT(((n * 7919) % 50000 + 1) % 3 + 1, 'gold', 'silver', 'bronze')
  FROM (SELECT x.n * 10000 + y.n + 1 AS n FROM nums x JOIN nums y WHERE x.n < @n / 10000) t;

-- Order items. No foreign key; order fields are copied here on purpose.
CREATE TABLE order_items (
  order_id    BIGINT,
  line        INT,
  customer_id INT NOT NULL,       -- copied from orders: sharding key, keeps items with their order
  status      VARCHAR(12),        -- copied from orders: item reports can filter on it without a JOIN
  created_at  DATETIME,           -- copied from orders: same reason
  sku         VARCHAR(12),
  sku_name    VARCHAR(64),        -- snapshot: product name when the order was placed
  qty         INT,
  price       DECIMAL(10,2),      -- snapshot: unit price when the order was placed
  PRIMARY KEY (order_id, line),
  KEY idx_created (created_at));
INSERT INTO order_items
  SELECT o.id, j.j, o.customer_id, o.status, o.created_at,
         CONCAT('sku-', (o.id * 31 + j.j * 17) % 500), CONCAT('Product ', (o.id * 31 + j.j * 17) % 500),
         (o.id + j.j) % 4 + 1, ((o.id * 7 + j.j * 11) % 5000) / 100
  FROM orders o JOIN (SELECT 0 AS j UNION ALL SELECT 1 UNION ALL SELECT 2) j ON j.j <= o.id % 3;

ANALYZE TABLE customers, orders, order_items;
SELECT CONCAT('mysql: ', (SELECT COUNT(*) FROM orders), ' orders, ', (SELECT COUNT(*) FROM customers), ' customers, ',
              (SELECT COUNT(*) FROM order_items), ' order items') AS loaded;
