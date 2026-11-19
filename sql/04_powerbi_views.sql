-- =====================================================================
-- 04_powerbi_views.sql — the semantic layer Power BI reads
--
-- Power BI imports ONLY from schema `bi`, so the dashboard uses the same
-- cleaned data, business rules and definitions as the SQL analysis.
-- Run order: 00 → 01 → 02 → 03 → notebook (writes core.forecast_monthly
-- and core.staffing_scenario) → 04.
-- =====================================================================

DROP SCHEMA IF EXISTS bi CASCADE;
CREATE SCHEMA bi;

-- Fact: one row per day × channel × site × category × service
CREATE VIEW bi.fact_enquiries AS
SELECT enquiry_date, channel, work_site, category, service, volume
FROM core.fact_daily_enquiries;

-- Channel dimension (business rule: 27 channels → 7 groups, inbound/outbound)
CREATE VIEW bi.dim_channel AS
SELECT channel, channel_group, direction
FROM core.dim_channel;

-- Date dimension with labels Power BI needs for sorting and filtering
CREATE VIEW bi.dim_date AS
SELECT calendar_date,
       year,
       month,
       to_char(calendar_date, 'Mon')                                  AS month_name,
       date_trunc('month', calendar_date)::DATE                       AS month_start,
       weekday,
       iso_weekday,
       is_weekend,
       financial_year,
       'FY' || right(financial_year::TEXT, 2)                         AS fy_label,
       (financial_year BETWEEN 2015 AND 2026 AND financial_year <> 2019) AS is_complete_fy,
       has_data
FROM core.dim_date;

-- Monthly actual calls + forecast with 80% range (written by the notebook)
CREATE VIEW bi.forecast_monthly AS
SELECT month_start::DATE AS month_start, actual_calls, forecast_calls, forecast_p10, forecast_p90
FROM core.forecast_monthly;

-- Erlang C staffing scenario (written by the notebook)
CREATE VIEW bi.staffing_scenario AS
SELECT * FROM core.staffing_scenario;

-- Surge days: calls relative to a normal day of the same FY and day type (same logic as Q8)
CREATE VIEW bi.surge_days AS
WITH daily AS (
    SELECT f.enquiry_date, d.financial_year, d.is_weekend,
           SUM(f.volume) AS calls,
           SUM(f.volume) FILTER (WHERE f.category ILIKE 'Emergency%') AS emergency_calls
    FROM core.fact_daily_enquiries f
    JOIN core.dim_date d ON d.calendar_date = f.enquiry_date
    WHERE f.channel = 'Voice In'
    GROUP BY 1, 2, 3
), typical AS (
    SELECT financial_year, is_weekend,
           (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY calls))::NUMERIC AS median_calls
    FROM daily GROUP BY 1, 2
)
SELECT d.enquiry_date,
       to_char(d.enquiry_date, 'Dy')      AS weekday,
       d.calls,
       ROUND(t.median_calls)              AS typical_calls,
       ROUND(d.calls / t.median_calls, 2) AS times_typical,
       COALESCE(d.emergency_calls, 0)     AS emergency_calls
FROM daily d
JOIN typical t USING (financial_year, is_weekend)
ORDER BY d.calls / t.median_calls DESC
LIMIT 20;

-- Governance: cleaning steps and latest data-quality results
CREATE VIEW bi.cleaning_log AS
SELECT step, step_name, rule, reason, rows_in, rows_out, volume_in, volume_out
FROM governance.cleaning_log;

CREATE VIEW bi.data_quality AS
SELECT q.rule_id, q.dimension, q.rule, q.severity, q.threshold_pct,
       r.records, r.failing, r.failing_pct, r.status, r.detail, r.run_at
FROM governance.dq_rules q
JOIN governance.dq_results r USING (rule_id)
WHERE r.run_at = (SELECT MAX(run_at) FROM governance.dq_results);

-- Row counts for a quick check after import
SELECT 'fact_enquiries' AS view, COUNT(*) FROM bi.fact_enquiries
UNION ALL SELECT 'dim_channel', COUNT(*) FROM bi.dim_channel
UNION ALL SELECT 'dim_date', COUNT(*) FROM bi.dim_date
UNION ALL SELECT 'forecast_monthly', COUNT(*) FROM bi.forecast_monthly
UNION ALL SELECT 'staffing_scenario', COUNT(*) FROM bi.staffing_scenario
UNION ALL SELECT 'surge_days', COUNT(*) FROM bi.surge_days
UNION ALL SELECT 'cleaning_log', COUNT(*) FROM bi.cleaning_log
UNION ALL SELECT 'data_quality', COUNT(*) FROM bi.data_quality;
