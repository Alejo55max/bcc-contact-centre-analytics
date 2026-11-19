-- =====================================================================
-- 02_data_quality.sql — data quality rules + results (governance layer)
--
-- Each rule has an ID, a quality dimension, a threshold and a severity.
-- Running this script re-checks every rule and appends the outcome to
-- governance.dq_results, so quality is tracked over time, not asserted once.
-- Run after 01_clean_model.sql.
-- =====================================================================

-- Date the source extract was downloaded (used by the timeliness rule).
\set extract_date '2026-11-19'

-- Tables are created once and kept, so every run adds to the history.
-- (Rebuilding from scratch with 01_clean_model.sql resets the governance schema.)
CREATE TABLE IF NOT EXISTS governance.dq_rules (
    rule_id        TEXT PRIMARY KEY,
    dimension      TEXT NOT NULL CHECK (dimension IN
                   ('Completeness', 'Validity', 'Uniqueness', 'Consistency', 'Timeliness', 'Reconciliation')),
    target_table   TEXT NOT NULL,
    rule           TEXT NOT NULL,
    threshold_pct  NUMERIC NOT NULL,   -- max share of failing records allowed
    severity       TEXT NOT NULL CHECK (severity IN ('Critical', 'Warning')),
    action_on_fail TEXT NOT NULL
);

INSERT INTO governance.dq_rules VALUES
 ('DQ01', 'Completeness',   'staging.raw_enquiries',     'Every source row has a date',
   1.0, 'Warning',  'Quarantine undated rows; report volume excluded'),
 ('DQ02', 'Validity',       'staging.raw_enquiries',     'volume is a positive integer',
   0.0, 'Critical', 'Stop the load and investigate the extract'),
 ('DQ03', 'Validity',       'core.fact_daily_enquiries', 'Dates fall between 2014-01-01 and the extract date',
   0.0, 'Critical', 'Stop the load and investigate the extract'),
 ('DQ04', 'Validity',       'core.fact_daily_enquiries', 'work_site is Call Centre or Business Centre',
   0.0, 'Warning',  'Add the new site to the dictionary after confirming with the data owner'),
 ('DQ05', 'Uniqueness',     'core.fact_daily_enquiries', 'One row per date × channel × work_site × category × service',
   0.0, 'Critical', 'Collapse duplicates (step 4) before loading'),
 ('DQ06', 'Consistency',    'core.fact_daily_enquiries', 'Every channel exists in core.dim_channel',
   0.0, 'Critical', 'Map the new channel in dim_channel (step 5 fails loudly)'),
 ('DQ07', 'Completeness',   'core.dim_date',             'Every calendar day in the range has data',
   0.0, 'Warning',  'Flag gap days (has_data = FALSE); exclude them from trends and forecast training'),
 ('DQ08', 'Timeliness',     'core.fact_daily_enquiries', 'Latest date is no more than 60 days before the extract date',
   0.0, 'Warning',  'Check with the publisher whether the feed has stalled'),
 ('DQ09', 'Reconciliation', 'core.fact_daily_enquiries', 'Clean volume + quarantined volume = raw volume',
   0.0, 'Critical', 'Stop: contacts were lost or created during cleaning')
ON CONFLICT (rule_id) DO UPDATE                -- re-running updates a rule's definition in place
SET dimension = EXCLUDED.dimension, target_table = EXCLUDED.target_table, rule = EXCLUDED.rule,
    threshold_pct = EXCLUDED.threshold_pct, severity = EXCLUDED.severity, action_on_fail = EXCLUDED.action_on_fail;

CREATE TABLE IF NOT EXISTS governance.dq_results (
    run_at        TIMESTAMP DEFAULT now(),
    rule_id       TEXT REFERENCES governance.dq_rules (rule_id),
    records       BIGINT,
    failing       BIGINT,
    failing_pct   NUMERIC(7, 3),
    status        TEXT,
    detail        TEXT
);

-- One INSERT per rule: records checked, records failing, and a readable detail.
-- A single transaction gives every rule of this run the same run_at timestamp.
BEGIN;

INSERT INTO governance.dq_results (rule_id, records, failing, detail)
SELECT 'DQ01', COUNT(*), COUNT(*) FILTER (WHERE NULLIF(btrim(date), '') IS NULL),
       'Undated contacts: ' || SUM(volume::BIGINT) FILTER (WHERE NULLIF(btrim(date), '') IS NULL)
FROM staging.raw_enquiries;

INSERT INTO governance.dq_results (rule_id, records, failing, detail)
SELECT 'DQ02', COUNT(*), COUNT(*) FILTER (WHERE NOT (volume ~ '^[0-9]+$') OR volume::BIGINT <= 0),
       'Max daily volume: ' || MAX(volume::BIGINT) FILTER (WHERE volume ~ '^[0-9]+$')
FROM staging.raw_enquiries;

INSERT INTO governance.dq_results (rule_id, records, failing, detail)
SELECT 'DQ03', COUNT(*),
       COUNT(*) FILTER (WHERE enquiry_date < DATE '2014-01-01' OR enquiry_date > DATE :'extract_date'),
       'Range: ' || MIN(enquiry_date) || ' to ' || MAX(enquiry_date)
FROM core.fact_daily_enquiries;

INSERT INTO governance.dq_results (rule_id, records, failing, detail)
SELECT 'DQ04', COUNT(*), COUNT(*) FILTER (WHERE work_site NOT IN ('Call Centre', 'Business Centre')),
       'Sites found: ' || string_agg(DISTINCT work_site, ', ')
FROM core.fact_daily_enquiries;

INSERT INTO governance.dq_results (rule_id, records, failing, detail)
SELECT 'DQ05', (SELECT COUNT(*) FROM core.fact_daily_enquiries),
       (SELECT COUNT(*) FROM (SELECT 1 FROM core.fact_daily_enquiries
                              GROUP BY enquiry_date, channel, work_site, category, service
                              HAVING COUNT(*) > 1) d),
       'Enforced by primary key; 71 source duplicates were summed in cleaning step 4';

INSERT INTO governance.dq_results (rule_id, records, failing, detail)
SELECT 'DQ06', COUNT(*), COUNT(*) FILTER (WHERE c.channel IS NULL),
       COUNT(DISTINCT f.channel) || ' channels in data, ' || (SELECT COUNT(*) FROM core.dim_channel) || ' mapped'
FROM core.fact_daily_enquiries f LEFT JOIN core.dim_channel c USING (channel);

INSERT INTO governance.dq_results (rule_id, records, failing, detail)
SELECT 'DQ07', COUNT(*), COUNT(*) FILTER (WHERE NOT has_data),
       'Gap: ' || MIN(calendar_date) FILTER (WHERE NOT has_data) || ' to ' || MAX(calendar_date) FILTER (WHERE NOT has_data)
FROM core.dim_date;

INSERT INTO governance.dq_results (rule_id, records, failing, detail)
SELECT 'DQ08', 1, CASE WHEN DATE :'extract_date' - MAX(enquiry_date) > 60 THEN 1 ELSE 0 END,
       'Latest date ' || MAX(enquiry_date) || ', ' || (DATE :'extract_date' - MAX(enquiry_date)) || ' days before extract'
FROM core.fact_daily_enquiries;

INSERT INTO governance.dq_results (rule_id, records, failing, detail)
SELECT 'DQ09', 1,
       CASE WHEN r.v = f.v + q.v THEN 0 ELSE 1 END,
       'Raw ' || r.v || ' = clean ' || f.v || ' + quarantined ' || q.v
FROM (SELECT SUM(volume::BIGINT) v FROM staging.raw_enquiries) r,
     (SELECT SUM(volume)::BIGINT v FROM core.fact_daily_enquiries) f,
     (SELECT SUM(volume)::BIGINT v FROM governance.quarantine_missing_date) q;

-- Score each result against its rule's threshold.
UPDATE governance.dq_results r
SET failing_pct = ROUND(100.0 * r.failing / NULLIF(r.records, 0), 3),
    status = CASE
               WHEN r.failing = 0 THEN 'Pass'
               WHEN 100.0 * r.failing / NULLIF(r.records, 0) <= q.threshold_pct THEN 'Pass (within threshold)'
               WHEN q.severity = 'Critical' THEN 'Fail'
               ELSE 'Known issue'
             END
FROM governance.dq_rules q
WHERE q.rule_id = r.rule_id
  AND r.status IS NULL;                        -- score only this run's rows

COMMIT;

-- Latest run
SELECT q.rule_id, q.dimension, q.rule, r.records, r.failing, r.failing_pct, q.threshold_pct, r.status, r.detail
FROM governance.dq_rules q JOIN governance.dq_results r USING (rule_id)
WHERE r.run_at = (SELECT MAX(run_at) FROM governance.dq_results)
ORDER BY q.rule_id;
