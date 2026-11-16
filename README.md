import os
import sys

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, PROJECT_ROOT)

from config.duckdb_connection import duckdb_connection

RUN_DATE = "20261004"
TOLERANCE_PCT = 8  # speeds within this % of each other (relative to the larger one) are treated as equal
MAI_KPI_PATH = "/project/PLATFORM_INTEGRITY/exports/sdsl_speed_kpi.csv"
NETWORK_PATH = f"/project/SDSL_OUT/SDSL_NETWORK_RESULT{RUN_DATE}.csv"
run_date_formatted = f"{RUN_DATE[:4]}-{RUN_DATE[4:6]}-{RUN_DATE[6:]}"
billing_path = f"/RAIDdata/PI/SDSL/BSCS_SDSL/raw/SDSL_BSCS_PROFILES_{RUN_DATE}.csv.gz"
sdsl_network_path = f"/RAIDdata/PI/SDSL/SDSL_Network/in/SDSL_{RUN_DATE}.csv"
bscs_sdsl_vs_network_path = "/project/PLATFORM_INTEGRITY/exports/BSCS_SDSL_VS_NETWORK_202611051550.csv"
output_path = f"/project/PLATFORM_INTEGRITY/exports/SDSL_SPEED_RESULT_{RUN_DATE}.csv"

con = duckdb_connection()

# ---------------------------------------------------------------------------
# 1) sdsl_network
#    Unit base is 1000 everywhere (1 G = 1000 M = 1,000,000 K).
#    Speeds are rounded to 6 decimals to remove float noise (e.g. 2.3000000000000003),
#    and a numeric PE_Speed_Kbps column is produced so the comparison never has to
#    parse the display string again.
# ---------------------------------------------------------------------------
con.execute(f"""
    CREATE OR REPLACE TABLE sdsl_network AS
    WITH base AS (
        SELECT
            TRY_CAST("SID" AS VARCHAR) AS SID,
            TRY_CAST("PE Interface" AS VARCHAR) AS PE_Interface,
            TRY_CAST("WAN IP" AS VARCHAR) AS WAN_IP,
            TRY_CAST("MGT VRF" AS VARCHAR) AS MGT_VRF,
            TRY_CAST("VRF" AS VARCHAR) AS VRF,
            TRY_CAST("Actual Speed" AS VARCHAR) AS Actual_Speed,
            TRY_CAST("PE Describtion" AS VARCHAR) AS PE_Describtion,
            TRY_CAST("Comments" AS VARCHAR) AS Comments,
            TRY_CAST("PE Speed" AS VARCHAR) AS Original_PE_Speed,
            TRY_CAST("Service Type" AS VARCHAR) AS Service_Type,
            TRY_CAST("Branch Name" AS VARCHAR) AS Branch_Name,
            TRY_CAST("Entry Date" AS VARCHAR) AS Entry_Date,

            ROUND(
                TRY_CAST(
                    regexp_extract("PE Speed", '([0-9.]+)', 1)
                    AS DOUBLE
                )
                *
                CASE regexp_extract(upper("PE Speed"), '([KMG])', 1)
                    WHEN 'K' THEN 0.001
                    WHEN 'G' THEN 1000
                    ELSE 1
                END
            , 6) AS pe_speed_mbps

        FROM read_csv_auto('{sdsl_network_path}', ignore_errors=True, all_varchar=true, sample_size=-1)
    ),

    sid_rules AS (
        SELECT
            SID,

            COUNT(*) FILTER (WHERE MGT_VRF = 'l2') AS l2_count,
            COUNT(*) FILTER (WHERE MGT_VRF = 'l3') AS l3_count,
            SUM(pe_speed_mbps) FILTER (WHERE MGT_VRF = 'l3') AS l3_total_speed,
            MIN(pe_speed_mbps) FILTER (WHERE MGT_VRF = 'l3') AS l3_speed,
            MIN(pe_speed_mbps) FILTER (WHERE MGT_VRF = 'l2') AS l2_speed,

            CASE
                WHEN COUNT(DISTINCT pe_speed_mbps)
                     FILTER (WHERE MGT_VRF = 'l2') > 1
                THEN 'REJECTED: Multiple PE Speeds found in l2'

                WHEN COUNT(*) FILTER (WHERE MGT_VRF = 'l2') > 0
                     AND COUNT(*) FILTER (WHERE MGT_VRF = 'l3') > 0
                     AND COUNT(DISTINCT pe_speed_mbps)
                         FILTER (WHERE MGT_VRF = 'l3') > 1
                THEN 'REJECTED: Mixed l2/l3 SID with multiple l3 speeds'

                WHEN COUNT(*) FILTER (WHERE MGT_VRF = 'l2') > 0
                     AND COUNT(*) FILTER (WHERE MGT_VRF = 'l3') > 0
                THEN 'VALID: Mixed l2/l3 SID using l3 speed'

                WHEN COUNT(*) FILTER (WHERE MGT_VRF = 'l2') > 0
                     AND COUNT(*) FILTER (WHERE MGT_VRF = 'l3') = 0
                THEN 'VALID: l2 only SID'

                WHEN COUNT(*) FILTER (WHERE MGT_VRF = 'l3') > 0
                     AND COUNT(*) FILTER (WHERE MGT_VRF = 'l2') = 0
                THEN 'VALID: l3 only SID'

                ELSE 'VALID: No specific rule applied'
            END AS PE_Speed_Rule_Status

        FROM base
        GROUP BY SID
    ),

    resolved AS (
        SELECT
            b.*,
            r.PE_Speed_Rule_Status,

            ROUND(
                CASE
                    WHEN r.PE_Speed_Rule_Status LIKE 'REJECTED:%'
                    THEN NULL

                    WHEN r.l3_count > 0
                         AND r.l2_count = 0
                    THEN r.l3_total_speed

                    WHEN r.l2_count > 0
                         AND r.l3_count > 0
                    THEN r.l3_speed

                    WHEN r.l2_count > 0
                         AND r.l3_count = 0
                    THEN r.l2_speed

                    ELSE b.pe_speed_mbps
                END
            , 6) AS resolved_speed_mbps

        FROM base b
        LEFT JOIN sid_rules r
            ON b.SID = r.SID
    )

    SELECT
        SID,
        PE_Interface,
        WAN_IP,
        MGT_VRF,
        VRF,
        Actual_Speed,
        PE_Describtion,
        Comments,

        CASE
            WHEN resolved_speed_mbps IS NULL
            THEN Original_PE_Speed

            WHEN resolved_speed_mbps >= 1000
                 AND resolved_speed_mbps % 1000 = 0
            THEN
                CAST(
                    CAST(resolved_speed_mbps / 1000 AS BIGINT)
                    AS VARCHAR
                ) || 'G'

            WHEN resolved_speed_mbps =
                 CAST(resolved_speed_mbps AS BIGINT)
            THEN
                CAST(
                    CAST(resolved_speed_mbps AS BIGINT)
                    AS VARCHAR
                ) || 'M'

            ELSE
                CAST(resolved_speed_mbps AS VARCHAR) || 'M'
        END AS PE_Speed,

        -- numeric PE speed in Kbps (base 1000), used for the comparison
        ROUND(COALESCE(resolved_speed_mbps, pe_speed_mbps) * 1000, 3) AS PE_Speed_Kbps,

        PE_Speed_Rule_Status,
        Service_Type,
        Branch_Name,
        Entry_Date

    FROM resolved
""")

# ---------------------------------------------------------------------------
# 2) bscs_sdsl
# ---------------------------------------------------------------------------
con.execute(f"""
    CREATE OR REPLACE TABLE bscs_sdsl AS
    SELECT
        TRY_CAST(SID AS VARCHAR) AS SID,
        TRY_CAST(BILLCYCLE AS VARCHAR) AS BILLCYCLE,
        TRY_CAST(RATEPLAN_FLAG AS VARCHAR) AS RATEPLAN_FLAG,
        TRY_CAST(CH_STATUS AS VARCHAR) AS CH_STATUS,
        TRY_CAST(CCNAME AS VARCHAR) AS CCNAME,
        TRY_CAST(CUSTCODE AS VARCHAR) AS CUSTCODE,
        TRY_CAST(SERVICE_CODE AS VARCHAR) AS SERVICE_CODE,
        TRY_CAST(SERVICE_STATUS AS VARCHAR) AS SERVICE_STATUS,
        TRY_CAST(PARAMETER_DATE AS VARCHAR) AS PARAMETER_DATE,
        TRY_CAST("INTERVAL" AS VARCHAR) AS "INTERVAL",
        TRY_CAST(PARAMETER_NAME AS VARCHAR) AS PARAMETER_NAME,
        TRY_CAST(DESCRIPTION AS VARCHAR) AS DESCRIPTION,
        TRY_CAST(VALUE AS VARCHAR) AS VALUE,
        TRY_CAST(SERVICE_NAME AS VARCHAR) AS SERVICE_NAME,
        TRY_CAST(PRICE AS VARCHAR) AS PRICE,
        TRY_CAST('{run_date_formatted}' AS DATE) AS RUN_DATE
    FROM read_csv_auto('{billing_path}', ignore_errors=True, delim='|', all_varchar=true, sample_size=-1)
""")

# ---------------------------------------------------------------------------
# 3) sdsl_speed
#    - both speeds are converted to Kbps (base 1000) before comparing
#    - speeds within TOLERANCE_PCT of each other are treated as equal and the
#      billing value is normalised to the PE value
#    - both speeds are displayed in one common unit (G, M or K), picked from
#      the larger of the two values
# ---------------------------------------------------------------------------
con.execute(f"""
    CREATE OR REPLACE TABLE sdsl_speed AS
    WITH joined AS (
        SELECT
            bn.sid,
            bn.network_status,
            bn.billing_status,
            n.MGT_VRF,
            n.PE_Speed,
            n.PE_Speed_Kbps,
            n.PE_Speed_Rule_Status,
            n.Entry_Date,
            b.value AS billing_value
        FROM read_csv_auto('{bscs_sdsl_vs_network_path}', ignore_errors=True) bn
        LEFT JOIN bscs_sdsl b
            ON trim(bn.sid) = trim(b.sid)
           AND b.run_date = TRY_CAST('{run_date_formatted}' AS DATE)
           AND upper(b.parameter_name) = 'SPEED'
        LEFT JOIN sdsl_network n
            ON trim(bn.sid) = trim(n.sid)
        WHERE bn.network_status = 'ACTIVE'
          AND bn.billing_status = 'A'
          AND CAST(bn.run_date AS DATE) = TRY_CAST('{run_date_formatted}' AS DATE)
    ),
    ranked AS (
        SELECT
            sid, network_status, billing_status, MGT_VRF, PE_Speed, PE_Speed_Kbps, PE_Speed_Rule_Status,
            row_number() OVER (
                PARTITION BY sid
                ORDER BY
                    (PE_Speed IS NOT NULL) DESC,
                    try_strptime(Entry_Date, '%d/%m/%Y') DESC NULLS LAST
            ) AS r,
            CASE
                WHEN upper(billing_value) LIKE '%MBPS%' THEN replace(replace(upper(billing_value), 'MBPS', 'M'), ' ', '')
                WHEN upper(billing_value) LIKE '%KBPS%' THEN replace(replace(upper(billing_value), 'KBPS', 'K'), ' ', '')
                WHEN upper(billing_value) LIKE '%GBPS%' THEN replace(replace(upper(billing_value), 'GBPS', 'G'), ' ', '')
                ELSE billing_value
            END AS billing_speed
        FROM joined
    ),
    dedup AS (
        SELECT sid, network_status, billing_status, MGT_VRF, PE_Speed, PE_Speed_Kbps, PE_Speed_Rule_Status,
               billing_speed
        FROM ranked
        WHERE r = 1
    ),
    converted AS (
        SELECT
            sid, network_status, billing_status, MGT_VRF, PE_Speed, PE_Speed_Rule_Status,
            billing_speed,
            PE_Speed_Kbps AS pe_kbps,
            -- billing speed -> Kbps (base 1000)
            ROUND(
                CASE
                    WHEN trim(billing_speed) = '0' THEN 0
                    ELSE TRY_CAST(regexp_extract(billing_speed, '([0-9]*[.]?[0-9]+)', 1) AS DOUBLE)
                         * CASE regexp_extract(upper(billing_speed), '([KMG])', 1)
                               WHEN 'K' THEN 1
                               WHEN 'M' THEN 1000
                               WHEN 'G' THEN 1000000
                           END
                END
            , 3) AS billing_kbps
        FROM dedup
    ),
    toleranced AS (
        SELECT
            *,
            (pe_kbps IS NOT NULL
             AND billing_kbps IS NOT NULL
             AND abs(billing_kbps - pe_kbps) * 100 <= {TOLERANCE_PCT} * greatest(pe_kbps, billing_kbps)
            ) AS within_tolerance
        FROM converted
    ),
    scaled AS (
        SELECT
            *,
            -- one common unit for both values, based on the larger of the two
            CASE
                WHEN greatest(coalesce(pe_kbps, 0), coalesce(billing_kbps, 0)) >= 1000000 THEN 'G'
                WHEN greatest(coalesce(pe_kbps, 0), coalesce(billing_kbps, 0)) >= 1000    THEN 'M'
                ELSE 'K'
            END AS common_unit,
            CASE
                WHEN greatest(coalesce(pe_kbps, 0), coalesce(billing_kbps, 0)) >= 1000000 THEN 1000000
                WHEN greatest(coalesce(pe_kbps, 0), coalesce(billing_kbps, 0)) >= 1000    THEN 1000
                ELSE 1
            END AS divisor
        FROM toleranced
    )
    SELECT
        sid                  AS "Sid",
        network_status       AS "Network_status",
        billing_status       AS "Billing_status",
        MGT_VRF              AS "MGT_VRF",
        PE_Speed             AS "PE_Speed",
        PE_Speed_Rule_Status AS "PE_Speed_Rule_Status",
        billing_speed        AS "Billing_Speed",
        common_unit          AS "Common_Unit",
        CASE
            WHEN pe_kbps IS NULL THEN NULL
            ELSE rtrim(rtrim(printf('%.3f', pe_kbps / divisor), '0'), '.') || common_unit
        END AS "PE_Speed_Common",
        -- within tolerance: billing is normalised to the PE value
        CASE
            WHEN billing_kbps IS NULL THEN NULL
            WHEN within_tolerance
                THEN rtrim(rtrim(printf('%.3f', pe_kbps / divisor), '0'), '.') || common_unit
            ELSE rtrim(rtrim(printf('%.3f', billing_kbps / divisor), '0'), '.') || common_unit
        END AS "Billing_Speed_Common",
        CASE
            WHEN pe_kbps IS NOT NULL
             AND billing_kbps IS NOT NULL
             AND greatest(pe_kbps, billing_kbps) > 0
            THEN round(abs(billing_kbps - pe_kbps) * 100.0 / greatest(pe_kbps, billing_kbps), 2)
        END AS "Diff_Pct",
        CASE
            WHEN pe_kbps IS NULL OR billing_kbps IS NULL THEN 'CANNOT IDENTIFY'
            WHEN within_tolerance THEN 'MATCHING'
            WHEN billing_kbps > pe_kbps THEN 'BILLING HIGHER'
            ELSE 'PE HIGHER'
        END AS "Billing_Vs_PE",
        TRY_CAST('{run_date_formatted}' AS DATE) AS "RUN_DATE"
    FROM scaled
""")

print(con.sql("SELECT * FROM sdsl_speed LIMIT 20"))
print(con.sql("""
    SELECT count(*) AS total,
           count(MGT_VRF) AS has_mgt_vrf,
           count(PE_Speed) AS has_pe_speed,
           count(Billing_Speed) AS has_billing_speed
    FROM sdsl_speed
"""))
print(con.sql("""
    SELECT Billing_Vs_PE, count(*) AS n
    FROM sdsl_speed
    GROUP BY 1 ORDER BY n DESC
"""))

# ---------------------------------------------------------------------------
# 4) Export results to CSV
# ---------------------------------------------------------------------------
con.execute(f"""
    COPY (SELECT * FROM sdsl_speed ORDER BY "Sid")
    TO '{output_path}'
    (FORMAT CSV, HEADER, DELIMITER ',')
""")
print(f"Exported {con.sql('SELECT count(*) FROM sdsl_speed').fetchone()[0]} rows to {output_path}")
