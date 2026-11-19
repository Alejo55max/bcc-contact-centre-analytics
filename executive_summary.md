# Executive Summary — Brisbane City Council Contact Centre: Demand, Channel Shift & 2027 Forecast

*SQL: [`sql/00_staging.sql`](sql/00_staging.sql) – [`sql/04_powerbi_views.sql`](sql/04_powerbi_views.sql). Charts, forecast and staffing model: [`bcc_contact_centre_analysis.ipynb`](bcc_contact_centre_analysis.ipynb). Governance: [`data_governance.md`](data_governance.md).*

## Business Problem

Brisbane City Council's Contact Centre handles residents' requests across phone, web, email, counters, mail and social media. Workforce planners need to know how demand is shifting between channels, which services keep generating calls, and how many staff to roster. This analysis answers: **how has demand changed between 2014 and 2026, and how many calls — and phone agents — should the Council plan for in 2027?**

## Data

**Source:** [Brisbane City Council — Contact Centre – Customer enquiries](https://data.brisbane.qld.gov.au/explore/dataset/contact-centre-customer-enquiries), CC BY 4.0. Daily contact volume by channel, work site, category and service, 1 January 2014 – 30 September 2026. Extract downloaded 19 November 2026.

| Layer | Rows | Contacts | Content |
|---|---:|---:|---|
| `staging.raw_enquiries` | 1,707,129 | 19,893,926 | Raw CSV, every column as text; reconciles to the open-data API total |
| `core.fact_daily_enquiries` | 1,696,778 | 19,583,461 | Clean daily grain: date × channel × site × category × service |
| `governance.quarantine_missing_date` | 10,280 | 310,465 | Undated rows, kept for audit |

**Data-quality decisions made before analysis:**
- **Undated rows quarantined, not deleted:** 10,280 rows (0.6% of rows, 1.6% of contacts) have no date and cannot be placed in a time series.
- **71 duplicate keys summed:** the same day × channel × site × service appeared twice with different volumes (partial records); summing kept every contact.
- **Publishing gap flagged, not filled:** 1 January – 30 June 2019 has no records at all (181 days). It is treated as unknown, never as zero, so FY2019 is excluded from year-on-year comparisons.
- **Channel rule:** 27 raw channel labels mapped to 7 groups and to *Inbound* (customer-initiated demand) or *Outbound* (Council-initiated, e.g. SMS notifications). Demand analysis uses Inbound only. The load fails if a new, unmapped channel appears.
- **Nine quality rules** re-run on every load; eight pass and one is a documented known issue (the 2019 gap). The reconciliation rule confirms clean + quarantined contacts = raw contacts exactly.

## Methodology

1. **PostgreSQL pipeline** (`sql/00`–`02`): raw staging → six logged cleaning steps → star schema (fact table, channel and date dimensions) → data-quality rules with run history.
2. **Nine business questions in SQL** (`sql/03`), using CTEs, `LAG`, `FIRST_VALUE`, cumulative `SUM() OVER`, `PERCENTILE_CONT` and a reusable view. Complete financial years are FY2015–FY2026 excluding FY2019 (Australian FY: July–June).
3. **Forecast** (notebook): daily calls from 1 July 2019, modelled on the log scale as a regression with ARIMA(1,1,1) errors. Regressors: day of week, Queensland public holidays, the 24 Dec – 2 Jan shutdown and three annual Fourier pairs. Trained to 30 September 2025 and tested on the next 12 months against a seasonal-naive baseline. The point forecast is the bias-corrected mean of the log model; uncertainty comes from 1,000 simulated paths.
4. **Staffing scenario:** Erlang C on the forecast, with stated assumptions.
5. **Power BI:** a `bi` semantic layer (`sql/04`); every DAX measure was reconciled to the SQL results before the pages were built.

## Results

**1. Demand is roughly flat to slightly up.** Inbound contacts: 1,431,004 (FY2015) → 1,545,953 (FY2026), **+8.0%**. The peak was FY2025 (1,589,762); the low was FY2023 (1,324,051).

**2. A third of demand moved online.**

| Channel | FY2015 | FY2026 |
|---|---:|---:|
| Phone | 83.6% | **56.9%** |
| Web & online forms | 6.6% | **33.4%** |
| Email | 2.6% | 6.7% |
| Face-to-face | 6.0% | 2.7% |

**3. Phone work fell by a quarter.** Calls: 1,196,669 → 879,503, **−26.5% (317,166 fewer a year)**. An average weekday fell from 4,188 to 3,059 calls. The lowest point was FY2023 (829,748).

**4. Top services, FY2026 (inbound contacts, growth since FY2016).** Property Searches 111,265 (+140%, 36% by phone) · Waste Collection Service Management 107,850 (+150%) · Parking Control Enforcement 107,106 (+54%, 73% by phone) · Waste Asset Provision 92,080 (+6%) · Rates Maintenance 86,516 (+28%).

**5. Calls are concentrated.** In FY2026, 10 of 321 services generated 50% of calls, and 37 generated 80%.

**6. Eleven large services have not shifted.** Services with 10,000+ inbound contacts still arriving 70%+ by phone: Parking Control Enforcement (77,735 calls), Lost Property Management (39,747), Plumbing Regulation (37,835, 94% by phone), Waste Treatment and Disposal (20,387, 95%), Switchboard Services (18,411, 97%), Domestic Animal Control, Rates Entitlements, Revenue Collection, Environment Health Protection, Rates Payment Collection and Library Facilities Use (96%). Together: **268,594 calls (31% of FY2026)**. Scenario: at the centre's average phone share (56.9%), **83,242 calls a year (9.5%)** would be avoided.

**7. When calls arrive (FY2026).** Mon 3,150 · Tue 3,176 · Wed 3,116 · Thu 2,992 · Fri 2,861 · **Sat 874 · Sun 683** calls per day. Monthly seasonality (FY2021–FY2026, 100 = average month): March 109 and February 108 are the peaks; December 86 is the trough.

**8. Surges come on weekends.** Ranking days by calls relative to a normal day of the same type and year: **Sun 27 Feb 2022 — 3,260 calls, 4.19× a normal Sunday** (Brisbane floods; 1,782 emergency-related calls), **Sun 9 Mar 2025 — 2,855 calls, 3.63×** (ex-Tropical Cyclone Alfred), and Sat 26 Feb 2022 (2.99×). Of the 71 weekdays since July 2019 with unusually low call volume, 70 are Queensland public holidays; the other is Fri 7 Mar 2025, as Cyclone Alfred approached.

**9. Proactive contact grew from almost nothing.** Outbound contacts: 1,202 (FY2015) → 380,557 (FY2026), of which 248,233 were SMS (started FY2021) and 126,460 email.

**10. Forecast validation (Oct 2025 – Sep 2026, unseen by the model).**

| Model | WAPE | Weekday MAPE | Error on yearly total |
|---|---:|---:|---:|
| Seasonal naive | 10.6% | 9.4% | +5.2% |
| **Regression + ARIMA** | **8.8%** | **8.5%** | **+0.8%** |

The model cuts daily error by 17% against the baseline. Using the bias-corrected mean instead of the median moved the yearly-total error from −2.0% to +0.8%, at the cost of slightly higher daily error (8.4% → 8.8%); for capacity planning the total matters more.

**11. 2027 forecast.** **823,520 calls** (80% range 639,356 – 1,052,836), 5% below the last 12 months (866,661). Average regular weekday ≈ 2,938 calls; busiest month March (≈ 76,300).

**12. Staffing scenario (Erlang C).** Assumptions: 12% of daily calls in the peak hour, AHT 6 minutes (sensitivity 5–7), 80% answered within 60 seconds, 35% shrinkage.

| Scenario | Daily calls | Peak-hour calls | Agents on phones | Rostered staff (AHT 5 / 6 / 7 min) |
|---|---:|---:|---:|---|
| Regular Monday 2027 | 3,148 | 378 | 42 | 56 / **65** / 76 |
| Regular Sunday 2027 | 641 | 77 | 11 | 14 / **17** / 19 |
| Sunday surge (4.2×) | 2,686 | 322 | 37 | 48 / **57** / 67 |

## Interpretation

Channel shift is real and has done its job: web forms absorbed all the growth in demand, and the centre answers a quarter fewer calls than in 2015. What remains on the phone is concentrated — a handful of services that never got a usable digital path, plus the switchboard. The forecast says the steady state will keep easing slowly. The operational risk is not the average day but the weekend weather surge, which lands when the roster is smallest.

## Business Recommendations

1. **Redesign the digital path for the 11 phone-dependent services**, starting with switchboard, library bookings, rates and plumbing enquiries — up to ~83,000 calls a year at the centre's average phone share.
2. **Create a weekend surge plan** triggered by severe-weather warnings: an on-call pool to bridge a ~17-person Sunday roster to the ~57 a surge requires.
3. **Budget 2027 on ~824,000 calls with March headroom**, use the 80% range for contingency, and refresh the forecast quarterly.
4. **Measure whether proactive SMS and email notifications prevent follow-up calls** — 380,000 contacts a year are currently unmeasured for impact.

## Limitations

- Volumes only: no handle times, wait times or intraday data, so staffing is a scenario. Peak-hour share and AHT should be replaced with the Council's telephony data.
- The 2019 publishing gap removes FY2019 from comparisons and limits the forecast's training window to July 2019 onwards, which includes the COVID period.
- The forecast does not anticipate future severe-weather events or service changes; its 80% range widens over the 15-month horizon.
- Weather events are matched to surge days by date; the data does not record why residents called.
- The "calls avoided" figure is a what-if, not a prediction of redesign outcomes.
