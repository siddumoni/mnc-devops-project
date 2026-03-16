-- ─────────────────────────────────────────────────────────────────────────────
-- Flyway Migration: V1__init_schema.sql
--
-- Flyway naming convention: V{version}__{description}.sql
-- This is the very first migration — creates all tables from scratch.
--
-- How Flyway works:
--   1. On app startup, Flyway checks the 'flyway_schema_history' table in the DB.
--   2. If V1__init_schema.sql has not been applied yet, it runs it.
--   3. It records the checksum in flyway_schema_history so it never runs twice.
--   4. Future changes go in V2__add_column.sql, V3__add_index.sql, etc.
--
-- To add new tables or columns in future sprints, create a new file:
--   app/database/migration/V2__your_description.sql
-- Never edit this file after it has been applied to any environment.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS products (
    id               BIGINT        NOT NULL AUTO_INCREMENT,
    name             VARCHAR(100)  NOT NULL,
    description      VARCHAR(500),
    price            DECIMAL(10,2) NOT NULL,
    stock_quantity   INT           NOT NULL DEFAULT 0,
    created_at       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    INDEX idx_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Seed data for dev and staging (not applied to prod — see Jenkinsfile profile logic)
-- Flyway runs this in all environments unless you use profiles to exclude it.
-- In prod the seed data rows already exist from the initial data load; INSERT IGNORE is safe.
INSERT IGNORE INTO products (name, description, price, stock_quantity) VALUES
    ('Laptop Pro 15',       'High-performance laptop for developers',  89999.00, 50),
    ('Wireless Mouse',      'Ergonomic wireless mouse',                 1299.00, 200),
    ('USB-C Hub',           '7-in-1 USB-C hub with 4K HDMI',           3499.00, 150),
    ('Mechanical Keyboard', 'Tenkeyless mechanical keyboard',           5999.00,  75),
    ('Monitor 27"',         '4K IPS display, 144Hz',                  32999.00,  30);
