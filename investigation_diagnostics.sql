-- =====================================================================
-- Mismatch KPI drop: diagnostic queries for the `investigation` query
-- Run these against the same schema (RP7VFEPIDAT). Nothing here writes data.
-- Assumption: SERVICE_CLASS and OFFERS are columns of PFM_IN_STG (Charging).
-- =====================================================================


-- ---------------------------------------------------------------------
-- STEP 1. Find the break date and what disappeared (KPI output history)
-- Replace KPI_RESULT_TABLE with the table the KPI query's output is stored in.
-- Compare the weeks before and after the drop: the combination whose count
-- collapsed tells you which part of the query logic is responsible.
-- ---------------------------------------------------------------------
SELECT TRUNC(run_date) run_day, impact_type, billing_type,
       billing_status, charging_status, hlr_status, charging_type,
       COUNT(*) cnt
FROM   KPI_RESULT_TABLE
WHERE  run_date >= DATE '2026-09-01'          -- adjust: start a few weeks before the drop
GROUP  BY TRUNC(run_date), impact_type, billing_type,
          billing_status, charging_status, hlr_status, charging_type
ORDER  BY run_day, cnt DESC;

-- Split the output into branch 1 (BSCS row exists) and branch 2 (no billing type).
SELECT TRUNC(run_date) run_day,
       SUM(CASE WHEN billing_type IS NULL THEN 1 ELSE 0 END) branch2_no_billing_type,
       SUM(CASE WHEN billing_type IS NOT NULL THEN 1 ELSE 0 END) branch1_with_billing,
       SUM(CASE WHEN impact_type = 'Revenue Loss' THEN 1 ELSE 0 END) revenue_loss
FROM   KPI_RESULT_TABLE
GROUP  BY TRUNC(run_date)
ORDER  BY run_day;


-- ---------------------------------------------------------------------
-- STEP 2. Did the query or its tables change? (Oracle metadata)
-- ---------------------------------------------------------------------
-- DDL changes on the source tables, and on any view/package/procedure that holds the query.
SELECT owner, object_name, object_type, created, last_ddl_time
FROM   all_objects
WHERE  owner = 'RP7VFEPIDAT'
AND   (object_name IN ('PFM_BSCS_LOAD_ALL_STG','PFM_HLR_STG','PFM_IN_STG')
       OR object_type IN ('VIEW','PROCEDURE','PACKAGE BODY','MATERIALIZED VIEW'))
ORDER  BY last_ddl_time DESC;

-- Data types of the join and filter columns (MSISDN NUMBER vs VARCHAR2, SERVICE_CLASS type, etc.).
SELECT table_name, column_name, data_type, data_length, nullable
FROM   all_tab_columns
WHERE  owner = 'RP7VFEPIDAT'
AND    table_name IN ('PFM_BSCS_LOAD_ALL_STG','PFM_HLR_STG','PFM_IN_STG')
AND    column_name IN ('MSISDN','STATUS','TYPE','RUN_DATE','EXTRACT_DATE','SERVICE_CLASS','OFFERS')
ORDER  BY column_name, table_name;

-- Find where the query is stored (view or PL/SQL), so you can compare against older versions.
SELECT owner, name, type, line, text
FROM   all_source
WHERE  UPPER(text) LIKE '%PFM_IN_STG%';

-- If the Diagnostics Pack is licensed: did the SQL text / SQL_ID change around the break date?
SELECT s.snap_id, sn.begin_interval_time, s.sql_id, s.plan_hash_value,
       s.executions_delta, s.rows_processed_delta
FROM   dba_hist_sqlstat s
JOIN   dba_hist_snapshot sn ON sn.snap_id = s.snap_id AND sn.instance_number = s.instance_number
WHERE  s.sql_id IN (SELECT sql_id FROM dba_hist_sqltext
                    WHERE  UPPER(sql_text) LIKE '%PFM_BSCS_LOAD_ALL_STG%')
ORDER  BY sn.begin_interval_time;


-- ---------------------------------------------------------------------
-- STEP 3. Profile the inputs the KPI depends on (run per day / per snapshot)
-- "Data sources are fine" usually means row counts are fine. This query is
-- sensitive to VALUES, NULLS and MSISDN FORMAT, so check those.
-- ---------------------------------------------------------------------
-- How many days does each staging table hold? (the joins are on MSISDN only, not on date)
SELECT 'BSCS' src, TRUNC(extract_date) d, COUNT(*) n, COUNT(DISTINCT msisdn) n_msisdn
FROM   RP7VFEPIDAT.PFM_BSCS_LOAD_ALL_STG GROUP BY TRUNC(extract_date)
UNION ALL
SELECT 'HLR', TO_DATE(run_date,'yyyymmdd'), COUNT(*), COUNT(DISTINCT msisdn)
FROM   RP7VFEPIDAT.PFM_HLR_STG GROUP BY TO_DATE(run_date,'yyyymmdd')
UNION ALL
SELECT 'IN', TO_DATE(run_date,'yyyymmdd'), COUNT(*), COUNT(DISTINCT msisdn)
FROM   RP7VFEPIDAT.PFM_IN_STG GROUP BY TO_DATE(run_date,'yyyymmdd')
ORDER  BY 1, 2;

-- Value domains: new spellings ('Active', 'ACTIVE ', 'SUSP'), new types, more NULLs.
SELECT 'BSCS' src, type, status, COUNT(*) n FROM RP7VFEPIDAT.PFM_BSCS_LOAD_ALL_STG GROUP BY type, status
UNION ALL
SELECT 'HLR',  type, status, COUNT(*)   FROM RP7VFEPIDAT.PFM_HLR_STG          GROUP BY type, status
UNION ALL
SELECT 'IN',   type, status, COUNT(*)   FROM RP7VFEPIDAT.PFM_IN_STG           GROUP BY type, status
ORDER  BY 1, 4 DESC;

-- MSISDN format per source (country code, leading zero, length): a change breaks the joins.
SELECT 'BSCS' src, LENGTH(msisdn) len, SUBSTR(msisdn,1,3) prefix, COUNT(*) n
FROM   RP7VFEPIDAT.PFM_BSCS_LOAD_ALL_STG GROUP BY LENGTH(msisdn), SUBSTR(msisdn,1,3)
UNION ALL
SELECT 'HLR', LENGTH(msisdn), SUBSTR(msisdn,1,3), COUNT(*)
FROM   RP7VFEPIDAT.PFM_HLR_STG GROUP BY LENGTH(msisdn), SUBSTR(msisdn,1,3)
UNION ALL
SELECT 'IN', LENGTH(msisdn), SUBSTR(msisdn,1,3), COUNT(*)
FROM   RP7VFEPIDAT.PFM_IN_STG GROUP BY LENGTH(msisdn), SUBSTR(msisdn,1,3)
ORDER  BY 1, 4 DESC;

-- Query-specific filters: service class 510 exclusion and the '%3000%' offer override.
SELECT service_class, type,
       SUM(CASE WHEN offers LIKE '%3000%' THEN 1 ELSE 0 END) with_3000_offer,
       COUNT(*) n
FROM   RP7VFEPIDAT.PFM_IN_STG
GROUP  BY service_class, type
ORDER  BY n DESC;

-- Which offer values actually match '%3000%'? (substring match also hits 13000, 30001, ...)
SELECT offers, COUNT(*) n
FROM   RP7VFEPIDAT.PFM_IN_STG
WHERE  offers LIKE '%3000%'
GROUP  BY offers
ORDER  BY n DESC;


-- ---------------------------------------------------------------------
-- STEP 4. Reason-code decomposition of the KPI query
-- Same joins and logic as `investigation`, but instead of filtering it labels
-- every row with WHY it is kept or dropped. Run it for a good snapshot and a
-- bad snapshot (or compare per run_date if the STG tables keep history):
-- the reason whose count moved is your root cause.
-- ---------------------------------------------------------------------
WITH bscs_hlr AS (
  SELECT NVL(b.extract_date, TO_DATE(h.run_date,'yyyymmdd')) run_date,
         NVL(b.msisdn, h.msisdn)                            msisdn,
         b.type billing_type, b.status billing_status,
         h.status hlr_status, h.type hlr_type,
         CASE WHEN b.msisdn IS NOT NULL THEN 1 ELSE 0 END   in_bscs,
         CASE WHEN h.msisdn IS NOT NULL THEN 1 ELSE 0 END   in_hlr
  FROM   RP7VFEPIDAT.PFM_BSCS_LOAD_ALL_STG b
  FULL   OUTER JOIN RP7VFEPIDAT.PFM_HLR_STG h ON b.msisdn = h.msisdn
),
base AS (
  SELECT NVL(x.run_date, TO_DATE(c.run_date,'yyyymmdd')) run_date,
         NVL(x.msisdn, c.msisdn)                           msisdn,
         x.billing_type, x.billing_status, x.hlr_status, x.hlr_type,
         c.status                                          raw_charging_status,
         CASE WHEN c.offers LIKE '%3000%' AND x.billing_type = 'CONV'
              THEN 'SUSPENDED' ELSE c.status END           charging_status,
         CASE WHEN c.offers LIKE '%3000%' AND x.billing_type = 'CONV'
              THEN 1 ELSE 0 END                            offer3000_override,
         c.type charging_type, c.service_class,
         NVL(x.in_bscs,0) in_bscs, NVL(x.in_hlr,0) in_hlr,
         CASE WHEN c.msisdn IS NOT NULL THEN 1 ELSE 0 END  in_in
  FROM   bscs_hlr x
  FULL   OUTER JOIN RP7VFEPIDAT.PFM_IN_STG c ON x.msisdn = c.msisdn
),
-- Tri-state of each exclusion condition: T = row is excluded by it,
-- F = condition does not apply, U = NULL made it UNKNOWN (row silently lost).
tri AS (
  SELECT b.*,
    CASE WHEN     (billing_type='CTRL' AND billing_status='SUSPENDED' AND charging_status='ACTIVE' AND hlr_status='SUSPENDED' AND charging_type IN ('CTRL','PRE')) THEN 'T'
         WHEN NOT (billing_type='CTRL' AND billing_status='SUSPENDED' AND charging_status='ACTIVE' AND hlr_status='SUSPENDED' AND charging_type IN ('CTRL','PRE')) THEN 'F' ELSE 'U' END e1,
    CASE WHEN     (billing_status='ACTIVE' AND charging_status='ACTIVE' AND hlr_status='ACTIVE') THEN 'T'
         WHEN NOT (billing_status='ACTIVE' AND charging_status='ACTIVE' AND hlr_status='ACTIVE') THEN 'F' ELSE 'U' END e2,
    CASE WHEN     (billing_status='SUSPENDED' AND charging_status='SUSPENDED' AND hlr_status='SUSPENDED') THEN 'T'
         WHEN NOT (billing_status='SUSPENDED' AND charging_status='SUSPENDED' AND hlr_status='SUSPENDED') THEN 'F' ELSE 'U' END e3,
    CASE WHEN     (billing_status='SUSPENDED' AND charging_status='ACTIVE' AND hlr_status='SUSPENDED') THEN 'T'
         WHEN NOT (billing_status='SUSPENDED' AND charging_status='ACTIVE' AND hlr_status='SUSPENDED') THEN 'F' ELSE 'U' END e4,
    CASE WHEN     (billing_status='ACTIVE' AND charging_status='SUSPENDED' AND hlr_status='ACTIVE' AND billing_type='POST') THEN 'T'
         WHEN NOT (billing_status='ACTIVE' AND charging_status='SUSPENDED' AND hlr_status='ACTIVE' AND billing_type='POST') THEN 'F' ELSE 'U' END e5,
    CASE WHEN     (billing_status='DEACTIVE' AND hlr_status IS NULL AND charging_status IS NULL) THEN 'T'
         WHEN NOT (billing_status='DEACTIVE' AND hlr_status IS NULL AND charging_status IS NULL) THEN 'F' ELSE 'U' END e6
  FROM base b
),
labelled AS (
  SELECT t.*,
    CASE
      WHEN service_class = '510'                                   THEN 'DROP_SERVICE_CLASS_510'
      WHEN e1||e2||e3||e4||e5||e6 = 'FFFFFF'                       THEN 'KEEP_BRANCH1_MISMATCH'
      WHEN billing_type IS NULL AND msisdn IS NOT NULL             THEN 'KEEP_BRANCH2_NO_BILLING_TYPE'
      WHEN e1 = 'T' THEN 'DROP_E1_CTRL_S/A/S'
      WHEN e2 = 'T' THEN 'DROP_E2_ALL_ACTIVE'
      WHEN e3 = 'T' THEN 'DROP_E3_ALL_SUSPENDED'
      WHEN e4 = 'T' THEN 'DROP_E4_S/A/S'
      WHEN e5 = 'T' THEN 'DROP_E5_POST_A/S/A'
      WHEN e6 = 'T' THEN 'DROP_E6_DEACTIVE_ONLY_BSCS'
      ELSE               'DROP_NULL_UNKNOWN'     -- lost only because of NULL three-valued logic
    END reason
  FROM tri t
)
SELECT TRUNC(run_date) run_day, reason,
       in_bscs||in_hlr||in_in presence_bscs_hlr_in,   -- e.g. 101 = in BSCS and IN, missing in HLR
       billing_type, billing_status, charging_status, hlr_status,
       SUM(offer3000_override) offer3000_overrides,
       COUNT(*) n
FROM   labelled
GROUP  BY TRUNC(run_date), reason, in_bscs||in_hlr||in_in,
          billing_type, billing_status, charging_status, hlr_status
ORDER  BY run_day, reason, n DESC;
