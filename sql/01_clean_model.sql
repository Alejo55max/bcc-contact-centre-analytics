-- =====================================================================
-- 01_clean_model.sql — cleaning (every step logged) + analytical model
--
-- Output schemas
--   governance.cleaning_log      one row per cleaning step: rule, reason, rows/volume in → out
--   governance.quarantine_*      rows removed from analysis, kept for audit (never deleted)
--   core.dim_channel             channel → channel group + direction (documented mapping)
--   core.dim_date                calendar with data-coverage flag
--   core.fact_daily_enquiries    clean daily grain: date × channel × work_site × category × service
-- =====================================================================

DROP SCHEMA IF EXISTS governance CASCADE;
DROP SCHEMA IF EXISTS core CASCADE;
CREATE SCHEMA governance;
CREATE SCHEMA core;

CREATE TABLE governance.cleaning_log (
    step        INT PRIMARY KEY,
    step_name   TEXT NOT NULL,
    rule        TEXT NOT NULL,
    reason      TEXT NOT NULL,
    rows_in     BIGINT,
    rows_out    BIGINT,
    volume_in   BIGINT,
    volume_out  BIGINT,
    logged_at   TIMESTAMP DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Step 1 — Raw load (baseline)
-- ---------------------------------------------------------------------
INSERT INTO governance.cleaning_log (step, step_name, rule, reason, rows_in, rows_out, volume_in, volume_out)
SELECT 1, 'Raw load',
       'Load the published CSV unchanged, every column as TEXT',
       'Baseline for reconciliation: must equal the open-data API total_count',
       COUNT(*), COUNT(*), SUM(volume::BIGINT), SUM(volume::BIGINT)
FROM staging.raw_enquiries;

-- ---------------------------------------------------------------------
-- Step 2 — Type casting and validity checks
-- Text fields were profiled first: no leading/trailing spaces, no case variants,
-- no non-numeric or non-positive volumes. Casting therefore loses nothing,
-- but the checks stay in the script so a future extract is re-validated.
-- ---------------------------------------------------------------------
CREATE TABLE staging.typed AS
SELECT NULLIF(btrim(date), '')::DATE AS enquiry_date,
       btrim(channel)                AS channel,
       btrim(work_site)              AS work_site,
       btrim(category)               AS category,
       btrim(service)                AS service,
       volume::INT                   AS volume
FROM staging.raw_enquiries
WHERE volume ~ '^[0-9]+$' AND volume::INT > 0;

INSERT INTO governance.cleaning_log (step, step_name, rule, reason, rows_in, rows_out, volume_in, volume_out)
SELECT 2, 'Cast types + validate volume',
       'date → DATE, volume → INT; keep only volume that is a positive integer; trim text',
       'Analysis needs real dates and numbers; invalid volumes would distort totals',
       (SELECT rows_out FROM governance.cleaning_log WHERE step = 1), COUNT(*),
       (SELECT volume_out FROM governance.cleaning_log WHERE step = 1), SUM(volume)
FROM staging.typed;

-- ---------------------------------------------------------------------
-- Step 3 — Quarantine rows without a date
-- ---------------------------------------------------------------------
CREATE TABLE governance.quarantine_missing_date AS
SELECT * FROM staging.typed WHERE enquiry_date IS NULL;

CREATE TABLE staging.dated AS
SELECT * FROM staging.typed WHERE enquiry_date IS NOT NULL;

INSERT INTO governance.cleaning_log (step, step_name, rule, reason, rows_in, rows_out, volume_in, volume_out)
SELECT 3, 'Quarantine missing dates',
       'Move rows with an empty date to governance.quarantine_missing_date',
       'A contact without a date cannot be placed in a time series; kept for audit, excluded from trends and forecasts',
       (SELECT rows_out FROM governance.cleaning_log WHERE step = 2), COUNT(*),
       (SELECT volume_out FROM governance.cleaning_log WHERE step = 2), SUM(volume)
FROM staging.dated;

-- ---------------------------------------------------------------------
-- Step 4 — Collapse duplicate keys
-- Some date × channel × work_site × category × service combinations appear
-- more than once with different volumes (partial records of the same day).
-- They are summed so the table has one row per key. Volume is unchanged.
-- ---------------------------------------------------------------------
CREATE TABLE governance.duplicate_keys AS
SELECT enquiry_date, channel, work_site, category, service,
       COUNT(*) AS records, SUM(volume) AS volume
FROM staging.dated
GROUP BY 1, 2, 3, 4, 5
HAVING COUNT(*) > 1;

CREATE TABLE staging.deduped AS
SELECT enquiry_date, channel, work_site, category, service, SUM(volume)::INT AS volume
FROM staging.dated
GROUP BY 1, 2, 3, 4, 5;

INSERT INTO governance.cleaning_log (step, step_name, rule, reason, rows_in, rows_out, volume_in, volume_out)
SELECT 4, 'Collapse duplicate keys',
       'GROUP BY date, channel, work_site, category, service and SUM(volume)',
       'Repeated keys with different volumes are partial records; summing gives one row per key without losing contacts',
       (SELECT rows_out FROM governance.cleaning_log WHERE step = 3), COUNT(*),
       (SELECT volume_out FROM governance.cleaning_log WHERE step = 3), SUM(volume)
FROM staging.deduped;

-- ---------------------------------------------------------------------
-- Step 5 — Channel mapping (documented business rule)
-- 27 raw channel labels → 7 channel groups + direction.
-- Outbound = contacts the Council initiates (not customer demand).
-- ---------------------------------------------------------------------
CREATE TABLE core.dim_channel (
    channel        TEXT PRIMARY KEY,
    channel_group  TEXT NOT NULL,
    direction      TEXT NOT NULL CHECK (direction IN ('Inbound', 'Outbound')),
    note           TEXT
);

INSERT INTO core.dim_channel VALUES
 ('Voice In',                               'Phone',               'Inbound',  NULL),
 ('Voice Out',                              'Phone',               'Outbound', NULL),
 ('WEB',                                    'Web & online forms',  'Inbound',  'Online requests via the Council website'),
 ('Online - Report it',                     'Web & online forms',  'Inbound',  NULL),
 ('Online - Report it - Failed case',       'Web & online forms',  'Inbound',  'Submission that failed to create a case'),
 ('Online - Report it - Failed attachment', 'Web & online forms',  'Inbound',  'Submission whose attachment failed'),
 ('Brisbane App',                           'Web & online forms',  'Inbound',  NULL),
 ('Online - Facebook',                      'Social media',        'Inbound',  NULL),
 ('Online - Twitter',                       'Social media',        'Inbound',  NULL),
 ('Online - Instagram',                     'Social media',        'Inbound',  NULL),
 ('Online - Linkedin',                      'Social media',        'Inbound',  NULL),
 ('Email - Mobile app',                     'Email',               'Inbound',  NULL),
 ('Email - Other',                          'Email',               'Inbound',  NULL),
 ('Email - Ward Office',                    'Email',               'Inbound',  NULL),
 ('Email Council Online',                   'Email',               'Inbound',  NULL),
 ('Email - Write it',                       'Email',               'Inbound',  NULL),
 ('Email - Pix-o-gram',                     'Email',               'Inbound',  NULL),
 ('Email - Business Hotline',               'Email',               'Inbound',  NULL),
 ('Email - Eyes on the Street',             'Email',               'Inbound',  NULL),
 ('Email - SES app',                        'Email',               'Inbound',  NULL),
 ('e-mail Out',                             'Email',               'Outbound', NULL),
 ('Face2Face',                              'Face-to-face',        'Inbound',  'Business Centre counters'),
 ('Mail In',                                'Mail & fax',          'Inbound',  NULL),
 ('Mail Out',                               'Mail & fax',          'Outbound', NULL),
 ('Fax In',                                 'Mail & fax',          'Inbound',  NULL),
 ('SMS In',                                 'SMS',                 'Inbound',  NULL),
 ('SMS Out',                                'SMS',                 'Outbound', NULL);

-- Every raw channel must be mapped (a new label in a future extract fails here loudly).
DO $$
DECLARE unmapped TEXT;
BEGIN
  SELECT string_agg(DISTINCT d.channel, ', ') INTO unmapped
  FROM staging.deduped d LEFT JOIN core.dim_channel c USING (channel)
  WHERE c.channel IS NULL;
  IF unmapped IS NOT NULL THEN
    RAISE EXCEPTION 'Unmapped channel(s): %', unmapped;
  END IF;
END $$;

INSERT INTO governance.cleaning_log (step, step_name, rule, reason, rows_in, rows_out, volume_in, volume_out)
SELECT 5, 'Map channels',
       'Join to core.dim_channel (27 labels → 7 groups, Inbound/Outbound); fail if any label is unmapped',
       'Raw labels are too granular and mix customer demand (inbound) with Council-initiated contacts (outbound)',
       (SELECT rows_out FROM governance.cleaning_log WHERE step = 4), COUNT(*),
       (SELECT volume_out FROM governance.cleaning_log WHERE step = 4), SUM(volume)
FROM staging.deduped d JOIN core.dim_channel c USING (channel);

-- ---------------------------------------------------------------------
-- Step 6 — Fact table + calendar with coverage flag
-- Jan–Jun 2019 has no records at all (a publishing gap, not zero demand).
-- The gap is flagged, not filled, so totals stay honest.
-- ---------------------------------------------------------------------
CREATE TABLE core.fact_daily_enquiries AS
SELECT enquiry_date, channel, work_site, category, service, volume
FROM staging.deduped;

ALTER TABLE core.fact_daily_enquiries
    ADD PRIMARY KEY (enquiry_date, channel, work_site, category, service),
    ADD FOREIGN KEY (channel) REFERENCES core.dim_channel (channel);

CREATE TABLE core.dim_date AS
SELECT d::DATE                                   AS calendar_date,
       EXTRACT(YEAR FROM d)::INT                 AS year,
       EXTRACT(MONTH FROM d)::INT                AS month,
       to_char(d, 'Dy')                          AS weekday,
       EXTRACT(ISODOW FROM d)::INT               AS iso_weekday,
       (EXTRACT(ISODOW FROM d) >= 6)             AS is_weekend,
       CASE WHEN EXTRACT(MONTH FROM d) >= 7
            THEN EXTRACT(YEAR FROM d)::INT + 1
            ELSE EXTRACT(YEAR FROM d)::INT END   AS financial_year,   -- AU FY ends 30 June
       EXISTS (SELECT 1 FROM core.fact_daily_enquiries f
               WHERE f.enquiry_date = d::DATE)   AS has_data
FROM generate_series((SELECT MIN(enquiry_date) FROM core.fact_daily_enquiries),
                     (SELECT MAX(enquiry_date) FROM core.fact_daily_enquiries),
                     INTERVAL '1 day') AS d;

ALTER TABLE core.dim_date ADD PRIMARY KEY (calendar_date);

INSERT INTO governance.cleaning_log (step, step_name, rule, reason, rows_in, rows_out, volume_in, volume_out)
SELECT 6, 'Build fact + calendar, flag coverage gaps',
       'Primary key on the daily grain; dim_date.has_data = FALSE for days with no records (incl. 2019-01-01 → 2019-06-30)',
       'A missing half-year is a publishing gap, not zero demand; flagged so trends and forecasts can exclude it',
       (SELECT rows_out FROM governance.cleaning_log WHERE step = 5), COUNT(*),
       (SELECT volume_out FROM governance.cleaning_log WHERE step = 5), SUM(volume)
FROM core.fact_daily_enquiries;

-- Staging intermediates are no longer needed (raw table stays for reconciliation).
DROP TABLE staging.typed, staging.dated, staging.deduped;

-- Results
SELECT step, step_name, rows_in, rows_out, rows_in - rows_out AS rows_removed,
       volume_in, volume_out, volume_in - volume_out AS volume_removed
FROM governance.cleaning_log ORDER BY step;

SELECT COUNT(*) AS days_without_data,
       MIN(calendar_date) AS first_gap_day, MAX(calendar_date) AS last_gap_day
FROM core.dim_date WHERE NOT has_data;
