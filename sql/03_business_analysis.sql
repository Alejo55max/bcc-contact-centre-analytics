-- =====================================================================
-- 03_business_analysis.sql — nine business questions, answered in SQL
--
-- Conventions
--   * Demand = INBOUND contacts only (customer-initiated). See core.dim_channel.
--   * Years are Australian financial years (FY2026 = Jul 2025 – Jun 2026).
--   * Complete years = FY2015–FY2026, except FY2019 (Jan–Jun 2019 not published).
--     FY2014 (starts Jan 2014) and FY2027 (to Sep 2026) are partial and excluded
--     from year-on-year comparisons.
--   * "Calls" = channel 'Voice In'.
-- Run after 01_clean_model.sql.
-- =====================================================================

-- Reusable view: every clean row with its channel and calendar attributes.
CREATE OR REPLACE VIEW core.v_enquiries AS
SELECT f.enquiry_date, d.financial_year, d.year, d.month, d.iso_weekday, d.weekday, d.is_weekend,
       f.channel, c.channel_group, c.direction, f.work_site, f.category, f.service, f.volume,
       (d.financial_year BETWEEN 2015 AND 2026 AND d.financial_year <> 2019) AS is_complete_fy
FROM core.fact_daily_enquiries f
JOIN core.dim_channel c USING (channel)
JOIN core.dim_date    d ON d.calendar_date = f.enquiry_date;


-- ---------------------------------------------------------------------
-- Q1. Is customer demand growing?
--     Inbound contacts per complete financial year, with change vs prior year.
-- ---------------------------------------------------------------------
WITH fy AS (
    SELECT financial_year, SUM(volume) AS inbound
    FROM core.v_enquiries
    WHERE direction = 'Inbound' AND is_complete_fy
    GROUP BY financial_year
)
SELECT financial_year,
       inbound,
       ROUND(100.0 * (inbound - LAG(inbound) OVER (ORDER BY financial_year))
             / LAG(inbound) OVER (ORDER BY financial_year), 1) AS change_vs_prior_pct
FROM fy
ORDER BY financial_year;


-- ---------------------------------------------------------------------
-- Q2. How has the channel mix shifted?
--     Share of inbound demand by channel group, per complete financial year.
-- ---------------------------------------------------------------------
SELECT financial_year,
       channel_group,
       SUM(volume) AS inbound,
       ROUND(100.0 * SUM(volume) / SUM(SUM(volume)) OVER (PARTITION BY financial_year), 1) AS share_pct
FROM core.v_enquiries
WHERE direction = 'Inbound' AND is_complete_fy
GROUP BY financial_year, channel_group
ORDER BY financial_year, inbound DESC;


-- ---------------------------------------------------------------------
-- Q3. How much phone work has channel shift removed?
--     Calls per year, calls per weekday, and the change FY2015 → FY2026.
-- ---------------------------------------------------------------------
WITH calls AS (
    SELECT financial_year,
           SUM(volume) AS calls,
           SUM(volume) FILTER (WHERE NOT is_weekend) AS weekday_calls,
           COUNT(DISTINCT enquiry_date) FILTER (WHERE NOT is_weekend) AS weekdays
    FROM core.v_enquiries
    WHERE channel = 'Voice In' AND is_complete_fy
    GROUP BY financial_year
)
SELECT financial_year,
       calls,
       ROUND(1.0 * weekday_calls / weekdays) AS avg_calls_per_weekday,
       ROUND(100.0 * (calls - FIRST_VALUE(calls) OVER (ORDER BY financial_year))
             / FIRST_VALUE(calls) OVER (ORDER BY financial_year), 1) AS change_vs_fy2015_pct
FROM calls
ORDER BY financial_year;


-- ---------------------------------------------------------------------
-- Q4. Which services drive demand, and which are growing fastest?
--     Top 10 services by FY2026 inbound volume, with growth since FY2016.
--     (A service is identified by category + service.)
-- ---------------------------------------------------------------------
WITH s AS (
    SELECT category, service, financial_year,
           SUM(volume) AS inbound,
           SUM(volume) FILTER (WHERE channel = 'Voice In') AS calls
    FROM core.v_enquiries
    WHERE direction = 'Inbound' AND financial_year IN (2016, 2026)
    GROUP BY category, service, financial_year
)
SELECT now_.category,
       now_.service,
       now_.inbound                                                   AS fy2026_inbound,
       ROUND(100.0 * now_.inbound / SUM(now_.inbound) OVER (), 1)     AS share_of_fy2026_pct,
       ROUND(100.0 * now_.calls / now_.inbound)                       AS phone_share_pct,
       before.inbound                                                 AS fy2016_inbound,
       ROUND(100.0 * (now_.inbound - before.inbound) / before.inbound) AS growth_since_fy2016_pct
FROM s now_
LEFT JOIN s before
       ON before.category = now_.category AND before.service = now_.service AND before.financial_year = 2016
WHERE now_.financial_year = 2026
ORDER BY now_.inbound DESC
LIMIT 10;


-- ---------------------------------------------------------------------
-- Q5. How concentrated is phone demand?
--     Cumulative share of FY2026 calls by service (Pareto).
-- ---------------------------------------------------------------------
WITH s AS (
    SELECT category, service, SUM(volume) AS calls
    FROM core.v_enquiries
    WHERE channel = 'Voice In' AND financial_year = 2026
    GROUP BY category, service
), ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (ORDER BY calls DESC)                     AS rank,
           SUM(calls) OVER (ORDER BY calls DESC) / SUM(calls) OVER ()  AS cumulative_share
    FROM s
)
SELECT COUNT(*)                                            AS services_with_calls,
       MIN(rank) FILTER (WHERE cumulative_share >= 0.5)    AS services_for_50pct_of_calls,
       MIN(rank) FILTER (WHERE cumulative_share >= 0.8)    AS services_for_80pct_of_calls
FROM ranked;


-- ---------------------------------------------------------------------
-- Q6. Which large services have NOT shifted to digital?
--     Services with ≥ 10,000 inbound contacts in FY2026 that still arrive
--     ≥ 70% by phone, and the calls avoided if each fell to the contact
--     centre's overall FY2026 phone share (a scenario, not a forecast).
-- ---------------------------------------------------------------------
WITH s AS (
    SELECT category, service, financial_year,
           SUM(volume) AS inbound,
           SUM(volume) FILTER (WHERE channel = 'Voice In') AS calls
    FROM core.v_enquiries
    WHERE direction = 'Inbound' AND financial_year IN (2016, 2026)
    GROUP BY category, service, financial_year
), overall AS (
    SELECT SUM(volume) FILTER (WHERE channel = 'Voice In')::NUMERIC / SUM(volume) AS phone_share
    FROM core.v_enquiries
    WHERE direction = 'Inbound' AND financial_year = 2026
), laggards AS (
    SELECT now_.category, now_.service, now_.inbound, now_.calls,
           ROUND(100.0 * now_.calls / now_.inbound)                       AS phone_share_fy2026_pct,
           ROUND(100.0 * before.calls / NULLIF(before.inbound, 0))        AS phone_share_fy2016_pct,
           ROUND(now_.calls - now_.inbound * o.phone_share)               AS calls_avoided_at_average
    FROM s now_
    CROSS JOIN overall o
    LEFT JOIN s before
           ON before.category = now_.category AND before.service = now_.service AND before.financial_year = 2016
    WHERE now_.financial_year = 2026
      AND now_.inbound >= 10000
      AND now_.calls >= 0.7 * now_.inbound
)
SELECT category, service, inbound AS fy2026_inbound, calls AS fy2026_calls,
       phone_share_fy2016_pct, phone_share_fy2026_pct, calls_avoided_at_average,
       SUM(calls) OVER ()                    AS laggard_calls_total,
       SUM(calls_avoided_at_average) OVER () AS calls_avoided_total
FROM laggards
ORDER BY calls DESC;


-- ---------------------------------------------------------------------
-- Q7. When does phone demand arrive?
--     (a) average calls by weekday, FY2026 (days with no calls count as 0)
--     (b) monthly seasonality index, FY2021–FY2026 (100 = average month)
-- ---------------------------------------------------------------------
WITH daily AS (
    SELECT d.calendar_date, d.iso_weekday, d.weekday, COALESCE(SUM(f.volume), 0) AS calls
    FROM core.dim_date d
    LEFT JOIN core.fact_daily_enquiries f
           ON f.enquiry_date = d.calendar_date AND f.channel = 'Voice In'
    WHERE d.financial_year = 2026
    GROUP BY d.calendar_date, d.iso_weekday, d.weekday
)
SELECT iso_weekday, weekday, ROUND(AVG(calls)) AS avg_calls, COUNT(*) AS days
FROM daily
GROUP BY iso_weekday, weekday
ORDER BY iso_weekday;

WITH monthly AS (
    SELECT year, month, SUM(volume) AS calls
    FROM core.v_enquiries
    WHERE channel = 'Voice In' AND financial_year BETWEEN 2021 AND 2026
    GROUP BY year, month
)
SELECT month,
       ROUND(AVG(calls))                                   AS avg_calls,
       ROUND(100 * AVG(calls) / AVG(AVG(calls)) OVER ())   AS seasonality_index
FROM monthly
GROUP BY month
ORDER BY month;


-- ---------------------------------------------------------------------
-- Q8. What do demand surges look like?
--     Days with the most calls RELATIVE to a normal day of the same year and
--     day type (weekday vs weekend), plus emergency-related calls that day.
--     Relative ranking stops early high-volume years from dominating.
-- ---------------------------------------------------------------------
WITH daily AS (
    SELECT enquiry_date, financial_year, is_weekend,
           SUM(volume) AS calls,
           SUM(volume) FILTER (WHERE category ILIKE 'Emergency%') AS emergency_calls
    FROM core.v_enquiries
    WHERE channel = 'Voice In'
    GROUP BY enquiry_date, financial_year, is_weekend
), typical AS (
    SELECT financial_year, is_weekend,
           (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY calls))::NUMERIC AS median_calls
    FROM daily
    GROUP BY financial_year, is_weekend
)
SELECT d.enquiry_date,
       to_char(d.enquiry_date, 'Dy')            AS weekday,
       d.calls,
       ROUND(t.median_calls)                    AS typical_calls,
       ROUND(d.calls / t.median_calls, 2)       AS times_typical,
       COALESCE(d.emergency_calls, 0)           AS emergency_calls
FROM daily d
JOIN typical t USING (financial_year, is_weekend)
ORDER BY d.calls / t.median_calls DESC
LIMIT 10;


-- ---------------------------------------------------------------------
-- Q9. How much is the Council contacting customers proactively?
--     Outbound contacts (Council-initiated) per complete financial year.
-- ---------------------------------------------------------------------
SELECT financial_year,
       SUM(volume)                                              AS outbound,
       SUM(volume) FILTER (WHERE channel = 'SMS Out')           AS sms_out,
       SUM(volume) FILTER (WHERE channel = 'e-mail Out')        AS email_out,
       SUM(volume) FILTER (WHERE channel IN ('Mail Out', 'Voice Out')) AS mail_and_calls_out
FROM core.v_enquiries
WHERE direction = 'Outbound' AND is_complete_fy
GROUP BY financial_year
ORDER BY financial_year;
