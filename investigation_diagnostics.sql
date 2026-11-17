SELECT run_day, cnt,
       LAG(cnt) OVER (ORDER BY run_day) - cnt AS left_since_previous_day
FROM (
  SELECT TRUNC(run_date) run_day, COUNT(DISTINCT msisdn) cnt
  FROM   KPI_RESULT_TABLE
  WHERE  billing_type = 'PRE' AND billing_status = 'DEACTIVE'
  AND    charging_status = 'ACTIVE' AND charging_type = 'PRE'
  AND    hlr_status IS NULL
  AND    run_date >= DATE '2026-09-01'
  GROUP  BY TRUNC(run_date)
)
ORDER  BY run_day;
