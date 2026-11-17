-- FixTrace: repair history + resale value tracking for phones and laptops
-- Written for SQLite; for PostgreSQL swap INTEGER PRIMARY KEY AUTOINCREMENT -> SERIAL/GENERATED

PRAGMA foreign_keys = ON;

-- 1. DEVICES: one row per physical device
CREATE TABLE devices (
    device_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    device_type      TEXT NOT NULL CHECK (device_type IN ('phone','laptop','tablet','other')),
    brand            TEXT NOT NULL,
    model            TEXT NOT NULL,
    serial_or_imei   TEXT UNIQUE,
    storage_gb       INTEGER,
    ram_gb           INTEGER,
    color            TEXT,
    purchase_date    DATE,
    purchase_price   NUMERIC(10,2),          -- what you paid / acquired it for
    original_mrp     NUMERIC(10,2),          -- launch price, for depreciation
    warranty_start   DATE,                   -- defaults to purchase_date when NULL
    warranty_months  INTEGER NOT NULL DEFAULT 0,  -- device warranty period; 0 = none
    status           TEXT NOT NULL DEFAULT 'in_use'
                     CHECK (status IN ('in_use','in_repair','for_sale','sold')),
    notes            TEXT,
    created_at       DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- 2. REPAIRS: each repair job on a device
CREATE TABLE repairs (
    repair_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id        INTEGER NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    repair_date      DATE NOT NULL,
    issue_description TEXT NOT NULL,         -- e.g. "cracked screen", "battery swelling"
    diagnosis        TEXT,
    repair_shop      TEXT,
    technician       TEXT,
    labor_cost       NUMERIC(10,2) DEFAULT 0,
    warranty_days    INTEGER DEFAULT 0,      -- warranty on the repair itself
    outcome          TEXT DEFAULT 'completed'
                     CHECK (outcome IN ('completed','partial','failed','pending')),
    notes            TEXT
);

-- 3. PARTS: catalog of part types/sources
CREATE TABLE parts (
    part_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    part_name        TEXT NOT NULL,          -- "Display", "Battery", "Motherboard", "SSD"
    category         TEXT,                   -- screen / battery / board / storage / port / other
    compatible_model TEXT,
    UNIQUE (part_name, compatible_model)
);

-- 4. REPAIR_PARTS: which parts were replaced in which repair
CREATE TABLE repair_parts (
    repair_part_id   INTEGER PRIMARY KEY AUTOINCREMENT,
    repair_id        INTEGER NOT NULL REFERENCES repairs(repair_id) ON DELETE CASCADE,
    part_id          INTEGER NOT NULL REFERENCES parts(part_id),
    quantity         INTEGER NOT NULL DEFAULT 1,
    unit_cost        NUMERIC(10,2) NOT NULL DEFAULT 0,
    part_quality     TEXT NOT NULL DEFAULT 'unknown'
                     CHECK (part_quality IN ('OEM','original_refurb','aftermarket','unknown')),
    supplier         TEXT,
    serial_no        TEXT,                   -- serial printed on the replaced part (needed for claims)
    warranty_months  INTEGER NOT NULL DEFAULT 0   -- part warranty, counted from repair_date; 0 = none
);

-- 5. VALUATIONS: resale value snapshots over time
CREATE TABLE valuations (
    valuation_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id        INTEGER NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    valuation_date   DATE NOT NULL,
    condition_grade  TEXT CHECK (condition_grade IN ('A','B','C','D')),  -- A = like new
    battery_health_pct INTEGER,
    market_price_ref NUMERIC(10,2),          -- price of similar unrepaired device
    estimated_resale NUMERIC(10,2) NOT NULL,
    method           TEXT,                   -- "manual", "OLX comps", "formula"
    notes            TEXT
);

-- 6. SALES: final outcome (feeds back into better valuations)
CREATE TABLE sales (
    sale_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id        INTEGER NOT NULL UNIQUE REFERENCES devices(device_id),
    sale_date        DATE NOT NULL,
    sale_price       NUMERIC(10,2) NOT NULL,
    platform         TEXT,
    buyer_notes      TEXT
);

-- 7. WARRANTY_CLAIMS: claims filed against a replaced part's warranty
CREATE TABLE warranty_claims (
    claim_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    repair_part_id   INTEGER NOT NULL REFERENCES repair_parts(repair_part_id) ON DELETE CASCADE,
    claim_date       DATE NOT NULL,
    status           TEXT NOT NULL DEFAULT 'filed' CHECK (status IN ('filed','approved','rejected')),
    note             TEXT                    -- ticket number, shop reply, etc.
);

-- Indexes
CREATE INDEX idx_repairs_device ON repairs(device_id);
CREATE INDEX idx_repair_parts_repair ON repair_parts(repair_id);
CREATE INDEX idx_valuations_device_date ON valuations(device_id, valuation_date);
CREATE INDEX idx_claims_repair_part ON warranty_claims(repair_part_id);

-- ============ VIEWS ============

-- Total repair spend per repair
CREATE VIEW v_repair_costs AS
SELECT r.repair_id,
       r.device_id,
       r.repair_date,
       r.labor_cost,
       COALESCE(SUM(rp.quantity * rp.unit_cost), 0)             AS parts_cost,
       r.labor_cost + COALESCE(SUM(rp.quantity * rp.unit_cost), 0) AS total_cost
FROM repairs r
LEFT JOIN repair_parts rp ON rp.repair_id = r.repair_id
GROUP BY r.repair_id;

-- Complete overview per device: the main FixTrace dashboard
CREATE VIEW v_device_overview AS
SELECT d.device_id,
       d.brand || ' ' || d.model                                AS device,
       d.status,
       d.purchase_price,
       COUNT(DISTINCT c.repair_id)                              AS repair_count,
       COALESCE(SUM(c.total_cost), 0)                           AS total_repair_spend,
       d.purchase_price + COALESCE(SUM(c.total_cost), 0)        AS total_invested,
       (SELECT v.estimated_resale FROM valuations v
         WHERE v.device_id = d.device_id
         ORDER BY v.valuation_date DESC, v.valuation_id DESC LIMIT 1) AS latest_resale_estimate,
       (SELECT v.estimated_resale FROM valuations v
         WHERE v.device_id = d.device_id
         ORDER BY v.valuation_date DESC, v.valuation_id DESC LIMIT 1)
         - (d.purchase_price + COALESCE(SUM(c.total_cost), 0)) AS projected_profit_loss
FROM devices d
LEFT JOIN v_repair_costs c ON c.device_id = d.device_id
GROUP BY d.device_id;

-- Which parts were replaced, and with what quality (affects resale trust)
CREATE VIEW v_parts_history AS
SELECT d.device_id,
       d.brand || ' ' || d.model AS device,
       r.repair_date,
       p.part_name,
       rp.part_quality,
       rp.quantity,
       rp.unit_cost
FROM repair_parts rp
JOIN repairs r ON r.repair_id = rp.repair_id
JOIN devices d ON d.device_id = r.device_id
JOIN parts p   ON p.part_id = rp.part_id
ORDER BY d.device_id, r.repair_date;

-- Warranty status of every replaced part (and its latest claim, if any)
CREATE VIEW v_part_warranty AS
SELECT d.device_id,
       d.brand || ' ' || d.model AS device,
       p.part_name,
       rp.serial_no,
       r.repair_date,
       rp.warranty_months,
       CASE WHEN rp.warranty_months > 0
            THEN date(r.repair_date, '+' || rp.warranty_months || ' months') END AS warranty_expires,
       CASE WHEN rp.warranty_months = 0 THEN 'none'
            WHEN date(r.repair_date, '+' || rp.warranty_months || ' months') >= date('now') THEN 'active'
            ELSE 'expired' END AS warranty_status,
       (SELECT wc.status FROM warranty_claims wc
         WHERE wc.repair_part_id = rp.repair_part_id
         ORDER BY wc.claim_id DESC LIMIT 1) AS latest_claim_status
FROM repair_parts rp
JOIN repairs r ON r.repair_id = rp.repair_id
JOIN devices d ON d.device_id = r.device_id
JOIN parts p   ON p.part_id = rp.part_id;

-- ============ SAMPLE DATA ============
INSERT INTO devices (device_type, brand, model, serial_or_imei, storage_gb, purchase_date, purchase_price, original_mrp, warranty_months, status)
VALUES ('phone','Samsung','Galaxy S21','350000000000001',128,'2024-03-10',28000,69999,12,'for_sale');

INSERT INTO repairs (device_id, repair_date, issue_description, repair_shop, labor_cost, warranty_days)
VALUES (1,'2025-06-15','Cracked screen','City Mobile Care',500,90);

INSERT INTO parts (part_name, category, compatible_model) VALUES ('Display','screen','Galaxy S21');
INSERT INTO repair_parts (repair_id, part_id, quantity, unit_cost, part_quality, serial_no, warranty_months)
VALUES (1,1,1,6500,'OEM','DSP-21A-77302',3);

INSERT INTO warranty_claims (repair_part_id, claim_date, status, note)
VALUES (1,'2025-08-02','approved','Replacement display issued, ticket #4471');

INSERT INTO valuations (device_id, valuation_date, condition_grade, battery_health_pct, market_price_ref, estimated_resale, method)
VALUES (1,'2026-11-17','B',88,26000,24500,'manual');

-- Try it:
-- SELECT * FROM v_device_overview;
-- SELECT * FROM v_parts_history;
-- SELECT * FROM v_part_warranty;
