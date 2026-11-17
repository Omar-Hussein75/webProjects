WITH lost AS (                -- had the combination before the drop, not in the output after it
  SELECT DISTINCT l.msisdn
  FROM   KPI_RESULT_TABLE l
  WHERE  TRUNC(l.run_date) = DATE '2026-10-01'        -- day BEFORE the drop
  AND    l.billing_type    = 'PRE'
  AND    l.billing_status  = 'DEACTIVE'
  AND    l.charging_status = 'ACTIVE'
  AND    l.charging_type   = 'PRE'
  AND    l.hlr_status IS NULL
  AND    NOT EXISTS (SELECT 1
                     FROM   KPI_RESULT_TABLE k
                     WHERE  k.msisdn = l.msisdn
                     AND    TRUNC(k.run_date) = DATE '2026-11-01')   -- day AFTER the drop
),
in_last9 AS (                 -- IN numbers keyed by last 9 digits, to catch format differences
  SELECT SUBSTR(msisdn, -9) k9, MIN(msisdn) any_msisdn
  FROM   RP7VFEPIDAT.PFM_IN_STG
  GROUP  BY SUBSTR(msisdn, -9)
),
traced AS (
  SELECT l.msisdn,
         CASE WHEN b.msisdn IS NULL THEN 'missing'
              ELSE b.type || '/' || NVL(b.status, 'NULL') END               bscs_state,
         CASE WHEN h.msisdn IS NULL THEN 'missing'
              ELSE NVL(h.status, 'NULL') END                                hlr_state,
         CASE WHEN c.msisdn IS NULL THEN 'missing'
              ELSE c.type || '/' || NVL(c.status, 'NULL') END               in_state,
         NVL(TO_CHAR(c.service_class), '-')                                 service_class,
         CASE WHEN c.msisdn IS NULL AND f.any_msisdn IS NOT NULL
              THEN 'IN has it as ' || f.any_msisdn ELSE '-' END             format_hint
  FROM   lost l
  LEFT   JOIN RP7VFEPIDAT.PFM_BSCS_LOAD_ALL_STG b ON b.msisdn = l.msisdn
  LEFT   JOIN RP7VFEPIDAT.PFM_HLR_STG           h ON h.msisdn = l.msisdn
  LEFT   JOIN RP7VFEPIDAT.PFM_IN_STG            c ON c.msisdn = l.msisdn
  LEFT   JOIN in_last9                          f ON f.k9     = SUBSTR(l.msisdn, -9)
)
SELECT bscs_state, hlr_state, in_state, service_class,
       CASE WHEN format_hint = '-' THEN '-' ELSE 'FORMAT DIFFERS' END format_check,
       COUNT(DISTINCT msisdn) n_msisdn,
       MIN(msisdn)            sample_msisdn,
       MIN(format_hint)       sample_format_hint
FROM   traced
GROUP  BY bscs_state, hlr_state, in_state, service_class,
          CASE WHEN format_hint = '-' THEN '-' ELSE 'FORMAT DIFFERS' END
ORDER  BY n_msisdn DESC;
