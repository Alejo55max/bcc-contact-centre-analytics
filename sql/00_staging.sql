-- =====================================================================
-- 00_staging.sql — Brisbane City Council Contact Centre analytics
-- Loads the raw open-data export exactly as published (all columns TEXT),
-- so nothing is lost or silently converted before the logged cleaning steps.
--
-- Source : Brisbane City Council, "Contact Centre – Customer enquiries"
--          https://data.brisbane.qld.gov.au/explore/dataset/contact-centre-customer-enquiries
-- Licence: CC BY 4.0
-- Extract: full CSV export downloaded 2026-11-19 (1,707,129 rows, 2014-01-01 → 2026-09-30)
--
-- Run (from the project folder):
--   createdb -U postgres bcc_contact_centre
--   psql -U postgres -d bcc_contact_centre -v csv="<path to CSV>" -f sql/00_staging.sql
-- =====================================================================

DROP SCHEMA IF EXISTS staging CASCADE;
CREATE SCHEMA staging;

CREATE TABLE staging.raw_enquiries (
    date      TEXT,
    channel   TEXT,
    work_site TEXT,
    category  TEXT,
    service   TEXT,
    volume    TEXT
);

-- The export is UTF-8 with a byte-order mark; HEADER skips the first line, BOM included.
\set copy_cmd '\\copy staging.raw_enquiries FROM ' :'csv' ' WITH (FORMAT csv, HEADER true, ENCODING ''UTF8'')'
:copy_cmd

SELECT COUNT(*) AS raw_rows, SUM(volume::INT) AS raw_volume FROM staging.raw_enquiries;
