WITH lost AS (
  SELECT l.msisdn,
         MAX(l.billing_type)    b_type0,
         MAX(l.billing_status)  b_stat0,
         MAX(l.hlr_status)      h_stat0,
         MAX(l.charging_status) c_stat0,
         MAX(l.charging_type)   c_type0
  FROM   KPI_RESULT_TABLE l
  WHERE  TRUNC(l.run_date) = DATE '2026-10-01'                 -- day BEFORE the drop
  AND    l.billing_type = 'PRE' AND l.billing_status = 'DEACTIVE'
  AND    l.charging_status = 'ACTIVE' AND l.charging_type = 'PRE'
  AND    l.hlr_status IS NULL
  AND    NOT EXISTS (SELECT 1 FROM KPI_RESULT_TABLE k
                     WHERE  k.msisdn = l.msisdn
                     AND    TRUNC(k.run_date) = DATE '2026-11-01')   -- day AFTER the drop
  GROUP  BY l.msisdn
),
cur AS (
  SELECT l.*,
         b.type   b_type1, b.status b_stat1, b.extract_date b_date,
         h.status h_stat1, h.run_date h_date,
         c.status c_stat1, c.type c_type1, c.service_class sc1, c.run_date c_date
  FROM   lost l
  LEFT   JOIN RP7VFEPIDAT.PFM_BSCS_LOAD_ALL_STG b ON b.msisdn = l.msisdn
  LEFT   JOIN RP7VFEPIDAT.PFM_HLR_STG           h ON h.msisdn = l.msisdn
  LEFT   JOIN RP7VFEPIDAT.PFM_IN_STG            c ON c.msisdn = l.msisdn
),
scen AS (
  SELECT 0 sid FROM dual UNION ALL SELECT 1 FROM dual UNION ALL
  SELECT 2     FROM dual UNION ALL SELECT 3 FROM dual UNION ALL SELECT 4 FROM dual
),
ev AS (            -- 0 before, 1 only BSCS new, 2 only HLR new, 3 only IN new, 4 all new
  SELECT c.msisdn, s.sid,
         CASE WHEN s.sid IN (1,4) THEN c.b_type1 ELSE c.b_type0 END bt,
         CASE WHEN s.sid IN (1,4) THEN c.b_stat1 ELSE c.b_stat0 END bs,
         CASE WHEN s.sid IN (2,4) THEN c.h_stat1 ELSE c.h_stat0 END hs,
         CASE WHEN s.sid IN (3,4) THEN c.c_stat1 ELSE c.c_stat0 END cs,
         CASE WHEN s.sid IN (3,4) THEN c.c_type1 ELSE c.c_type0 END ct,
         CASE WHEN s.sid IN (3,4) THEN TO_CHAR(c.sc1)          END sc
  FROM   cur c CROSS JOIN scen s
),
judged AS (        -- same WHERE logic as the KPI query, including its NULL behaviour
  SELECT ev.msisdn, ev.sid,
    CASE
      WHEN sc = '510' THEN 'REMOVED: SERVICE CLASS 510'
      WHEN (    NOT (bt='CTRL' AND bs='SUSPENDED' AND cs='ACTIVE' AND hs='SUSPENDED' AND ct IN ('CTRL','PRE'))
            AND NOT (bs='ACTIVE'    AND cs='ACTIVE'    AND hs='ACTIVE')
            AND NOT (bs='SUSPENDED' AND cs='SUSPENDED' AND hs='SUSPENDED')
            AND NOT (bs='SUSPENDED' AND cs='ACTIVE'    AND hs='SUSPENDED')
            AND NOT (bs='ACTIVE'    AND cs='SUSPENDED' AND hs='ACTIVE' AND bt='POST')
            AND NOT (bs='DEACTIVE'  AND hs IS NULL     AND cs IS NULL))
           OR bt IS NULL                                                         THEN 'KEPT'
      WHEN bt='CTRL' AND bs='SUSPENDED' AND cs='ACTIVE' AND hs='SUSPENDED'
           AND ct IN ('CTRL','PRE')                                              THEN 'REMOVED: RULE1 CTRL S/A/S'
      WHEN bs='ACTIVE'    AND cs='ACTIVE'    AND hs='ACTIVE'                     THEN 'REMOVED: RULE2 ALL ACTIVE'
      WHEN bs='SUSPENDED' AND cs='SUSPENDED' AND hs='SUSPENDED'                  THEN 'REMOVED: RULE3 ALL SUSPENDED'
      WHEN bs='SUSPENDED' AND cs='ACTIVE'    AND hs='SUSPENDED'                  THEN 'REMOVED: RULE4 S/A/S'
      WHEN bs='ACTIVE'    AND cs='SUSPENDED' AND hs='ACTIVE' AND bt='POST'       THEN 'REMOVED: RULE5 POST A/S/A'
      WHEN bs='DEACTIVE'  AND hs IS NULL     AND cs IS NULL                      THEN 'REMOVED: RULE6 DEACTIVE ONLY'
      ELSE                                                                            'REMOVED: NULL LOGIC'
    END outcome
  FROM ev
),
outc AS (
  SELECT msisdn,
         MAX(CASE WHEN sid = 0 THEN outcome END) o_before,
         MAX(CASE WHEN sid = 1 THEN outcome END) o_only_bscs,
         MAX(CASE WHEN sid = 2 THEN outcome END) o_only_hlr,
         MAX(CASE WHEN sid = 3 THEN outcome END) o_only_in,
         MAX(CASE WHEN sid = 4 THEN outcome END) o_today
  FROM   judged GROUP BY msisdn
),
final AS (
  SELECT c.msisdn,
         NVL(c.b_stat0,'NULL') || ' -> ' || NVL(c.b_stat1,'NULL') bscs_change,
         NVL(c.h_stat0,'NULL') || ' -> ' || NVL(c.h_stat1,'NULL') hlr_change,
         NVL(c.c_stat0,'NULL') || ' -> ' || NVL(c.c_stat1,'NULL') in_change,
         o.o_before, o.o_only_bscs, o.o_only_hlr, o.o_only_in, o.o_today,
         CASE
           WHEN o.o_before <> 'KEPT' THEN 'CHECK: before-state not kept'
           WHEN o.o_today   = 'KEPT' THEN 'STILL KEPT TODAY'
           WHEN o.o_only_bscs <> 'KEPT' OR o.o_only_hlr <> 'KEPT' OR o.o_only_in <> 'KEPT' THEN
                RTRIM(  CASE WHEN o.o_only_bscs <> 'KEPT' THEN 'BSCS ' END
                     || CASE WHEN o.o_only_hlr  <> 'KEPT' THEN 'HLR '  END
                     || CASE WHEN o.o_only_in   <> 'KEPT' THEN 'IN '   END) || ' change alone removes it'
           ELSE 'Only the combined changes remove it'
         END decisive_status,
         c.b_date, c.h_date, c.c_date, c.sc1
  FROM   cur c JOIN outc o ON o.msisdn = c.msisdn
)
SELECT decisive_status, bscs_change, hlr_change, in_change,
       o_only_bscs, o_only_hlr, o_only_in, o_today,
       COUNT(DISTINCT msisdn) n_msisdn,
       LISTAGG(CASE WHEN rn <= 5 THEN TO_CHAR(msisdn) END, ', ')
         WITHIN GROUP (ORDER BY msisdn) sample_msisdns
FROM (
  SELECT f.*,
         ROW_NUMBER() OVER (PARTITION BY decisive_status, bscs_change, hlr_change, in_change
                            ORDER BY msisdn) rn
  FROM   final f
)
GROUP  BY decisive_status, bscs_change, hlr_change, in_change,
          o_only_bscs, o_only_hlr, o_only_in, o_today
ORDER  BY n_msisdn DESC;
