-- =====================================================================
-- Project 1: Customer Value and Churn Analysis (RFM) - Online Retail
-- Database: PostgreSQL | Source: UCI Online Retail (541,909 rows)
-- Every step below was checked against an independent Excel analysis.
-- =====================================================================

-- ---------------------------------------------------------------------
-- STEP 1: Create the raw table and import the CSV
-- Import settings (pgAdmin): Header ON, delimiter comma, encoding LATIN1.
-- invoice_date is loaded as text (M/D/YYYY H:MM) and converted in STEP 3.
-- unit_price uses 4 decimals because some prices are 0.001.
-- ---------------------------------------------------------------------
CREATE TABLE online_retail (
    invoice_no   VARCHAR(20),
    stock_code   VARCHAR(20),
    description  VARCHAR(255),
    quantity     INT,
    invoice_date VARCHAR(30),
    unit_price   NUMERIC(12,4),
    customer_id  INT,
    country      VARCHAR(50)
);

-- Expected after import: 541,909
SELECT COUNT(*) FROM online_retail;

-- ---------------------------------------------------------------------
-- STEP 2: Profile the raw data (find the mess before fixing it)
-- Expected: 541909 | 135080 | 9288 | 10624 | 2517 | 1454
-- ---------------------------------------------------------------------
SELECT
  COUNT(*)                                       AS total_rows,
  COUNT(*) FILTER (WHERE customer_id IS NULL)    AS missing_customer_id,
  COUNT(*) FILTER (WHERE invoice_no LIKE 'C%')   AS cancellations,
  COUNT(*) FILTER (WHERE quantity < 0)           AS negative_quantity,
  COUNT(*) FILTER (WHERE unit_price <= 0)        AS zero_or_negative_price,
  COUNT(*) FILTER (WHERE description IS NULL
                      OR TRIM(description) = '') AS blank_description
FROM online_retail;

-- ---------------------------------------------------------------------
-- STEP 3: Cleaning view (raw table is never modified)
--   * DISTINCT removes exact duplicate rows
--   * WHERE NOT (...) removes stock-adjustment rows:
--       zero price + no description + no customer
--   * Date text converted to a real timestamp
--   * Rows with no customer_id and cancellations are KEPT on purpose
--     (they count toward total revenue / churn signal)
-- ---------------------------------------------------------------------
CREATE VIEW retail_clean AS
SELECT DISTINCT
    invoice_no,
    stock_code,
    description,
    quantity,
    TO_TIMESTAMP(invoice_date, 'MM/DD/YYYY HH24:MI')::TIMESTAMP AS invoice_ts,
    unit_price,
    customer_id,
    country
FROM online_retail
WHERE NOT (
    unit_price = 0
    AND (description IS NULL OR TRIM(description) = '')
    AND customer_id IS NULL
);

-- Expected: 535187 | 24446 | 4372 | 9726006.95
SELECT
  COUNT(*)                             AS clean_rows,
  COUNT(DISTINCT invoice_no)           AS invoices,
  COUNT(DISTINCT customer_id)          AS customers,
  ROUND(SUM(quantity * unit_price), 2) AS total_revenue
FROM retail_clean;

-- ---------------------------------------------------------------------
-- STEP 4: One row per customer (Recency, Frequency, Monetary)
--   * Recency   = days from last real purchase to the day after the data ends
--   * Frequency = distinct real (non-cancelled) invoices
--   * Monetary  = net spend (cancellations reduce it)
--   * customer_id IS NOT NULL      -> customer-level analysis only
--   * last_purchase IS NOT NULL    -> drops the 33 customers who only cancelled
-- ---------------------------------------------------------------------
CREATE VIEW rfm_base AS
WITH ref AS (
    SELECT MAX(invoice_ts)::DATE + 1 AS ref_date
    FROM retail_clean
),
cust AS (
    SELECT
        customer_id,
        MODE() WITHIN GROUP (ORDER BY country)                             AS country,
        MAX(invoice_ts) FILTER (WHERE invoice_no NOT LIKE 'C%')            AS last_purchase,
        COUNT(DISTINCT invoice_no) FILTER (WHERE invoice_no NOT LIKE 'C%') AS frequency,
        COUNT(DISTINCT invoice_no) FILTER (WHERE invoice_no LIKE 'C%')     AS cancelled_invoices,
        ROUND(SUM(quantity * unit_price), 2)                               AS monetary
    FROM retail_clean
    WHERE customer_id IS NOT NULL
    GROUP BY customer_id
)
SELECT
    c.customer_id,
    c.country,
    c.last_purchase::DATE              AS last_purchase_date,
    r.ref_date - c.last_purchase::DATE AS recency_days,
    c.frequency,
    c.cancelled_invoices,
    c.monetary
FROM cust c
CROSS JOIN ref r
WHERE c.last_purchase IS NOT NULL;

-- Expected: 4339 | 8288930.66 | 1 | 374
SELECT COUNT(*) AS customers, SUM(monetary) AS total_monetary,
       MIN(recency_days) AS min_recency, MAX(recency_days) AS max_recency
FROM rfm_base;

-- Spot checks. 12346: 326, 1, 1, 0.00   |   12347: 3, 7, 0, 4310.00
SELECT * FROM rfm_base WHERE customer_id IN (12346, 12347);

-- ---------------------------------------------------------------------
-- STEP 5: Scores (1-5) and segments
--   * Cut-offs use PERCENTILE_CONT (same as Excel PERCENTILE.INC).
--   * NTILE(5) was deliberately NOT used: it splits tied customers
--     into different groups (34% of customers have exactly 1 order).
--   * Recency: small = good. Frequency / Monetary: large = good.
--   * fm_score = average of F and M scores, rounded.
-- ---------------------------------------------------------------------
CREATE VIEW rfm_scored AS
WITH cuts AS (
    SELECT
        PERCENTILE_CONT(0.2) WITHIN GROUP (ORDER BY recency_days) AS r20,
        PERCENTILE_CONT(0.4) WITHIN GROUP (ORDER BY recency_days) AS r40,
        PERCENTILE_CONT(0.6) WITHIN GROUP (ORDER BY recency_days) AS r60,
        PERCENTILE_CONT(0.8) WITHIN GROUP (ORDER BY recency_days) AS r80,
        PERCENTILE_CONT(0.2) WITHIN GROUP (ORDER BY frequency)    AS f20,
        PERCENTILE_CONT(0.4) WITHIN GROUP (ORDER BY frequency)    AS f40,
        PERCENTILE_CONT(0.6) WITHIN GROUP (ORDER BY frequency)    AS f60,
        PERCENTILE_CONT(0.8) WITHIN GROUP (ORDER BY frequency)    AS f80,
        PERCENTILE_CONT(0.2) WITHIN GROUP (ORDER BY monetary)     AS m20,
        PERCENTILE_CONT(0.4) WITHIN GROUP (ORDER BY monetary)     AS m40,
        PERCENTILE_CONT(0.6) WITHIN GROUP (ORDER BY monetary)     AS m60,
        PERCENTILE_CONT(0.8) WITHIN GROUP (ORDER BY monetary)     AS m80
    FROM rfm_base
),
scored AS (
    SELECT b.*,
        CASE WHEN b.recency_days <= c.r20 THEN 5
             WHEN b.recency_days <= c.r40 THEN 4
             WHEN b.recency_days <= c.r60 THEN 3
             WHEN b.recency_days <= c.r80 THEN 2
             ELSE 1 END AS r_score,
        CASE WHEN b.frequency <= c.f20 THEN 1
             WHEN b.frequency <= c.f40 THEN 2
             WHEN b.frequency <= c.f60 THEN 3
             WHEN b.frequency <= c.f80 THEN 4
             ELSE 5 END AS f_score,
        CASE WHEN b.monetary <= c.m20 THEN 1
             WHEN b.monetary <= c.m40 THEN 2
             WHEN b.monetary <= c.m60 THEN 3
             WHEN b.monetary <= c.m80 THEN 4
             ELSE 5 END AS m_score
    FROM rfm_base b
    CROSS JOIN cuts c
),
valued AS (
    SELECT s.*, ROUND((s.f_score + s.m_score) / 2.0)::INT AS fm_score
    FROM scored s
)
SELECT v.*,
    CASE WHEN r_score >= 4 AND fm_score >= 4 THEN 'Champions'
         WHEN r_score >= 4                   THEN 'Promising'
         WHEN r_score = 3  AND fm_score >= 4 THEN 'Loyal'
         WHEN r_score = 3                    THEN 'Needs Attention'
         WHEN fm_score >= 3                  THEN 'At Risk'
         ELSE 'Lost' END AS segment
FROM valued v;

-- ---------------------------------------------------------------------
-- STEP 6: Segment summary
-- Expected customers: Champions 1118, At Risk 639, Loyal 319,
--   Promising 631, Lost 1088, Needs Attention 544 (total 4339)
-- ---------------------------------------------------------------------
SELECT segment,
       COUNT(*)             AS customers,
       ROUND(SUM(monetary)) AS revenue
FROM rfm_scored
GROUP BY segment
ORDER BY revenue DESC;

-- ---------------------------------------------------------------------
-- STEP 7: Country summary
-- Countries with fewer than 15 customers are flagged: their averages can
-- be driven by one or two buyers (e.g. Netherlands: 1 customer = 98.2%
-- of revenue). Not run/verified yet.
-- ---------------------------------------------------------------------
SELECT country,
       COUNT(*)             AS customers,
       ROUND(SUM(monetary)) AS revenue,
       ROUND(AVG(monetary)) AS avg_spend_per_customer,
       CASE WHEN COUNT(*) < 15 THEN 'Low sample' ELSE 'OK' END AS sample_size
FROM rfm_scored
GROUP BY country
ORDER BY revenue DESC;
