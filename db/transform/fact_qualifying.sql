WITH latest_qual AS (
    SELECT DISTINCT ON (season, round)
           season, round, payload
    FROM stg.jolpica_qualifying
    WHERE season IS NOT NULL AND round IS NOT NULL
    ORDER BY season, round, stg_id DESC
)
INSERT INTO dwh.fact_qualifying (
    race_key, driver_key, constructor_key, position, q1_sec, q2_sec, q3_sec
)
SELECT DISTINCT ON (dr.race_key, dd.driver_key)
       dr.race_key,
       dd.driver_key,
       dc.constructor_key,
       NULLIF(q->>'position', '')::int       AS position,
       etl.parse_duration_sec(q->>'Q1')      AS q1_sec,
       etl.parse_duration_sec(q->>'Q2')      AS q2_sec,
       etl.parse_duration_sec(q->>'Q3')      AS q3_sec
FROM latest_qual lq
JOIN dwh.dim_race dr
  ON dr.season_year = lq.season AND dr.round = lq.round,
     jsonb_array_elements(lq.payload->'MRData'->'RaceTable'->'Races') AS r,
     jsonb_array_elements(r->'QualifyingResults') AS q
JOIN dwh.dim_driver dd
  ON dd.jolpica_driver_id = q->'Driver'->>'driverId'
JOIN dwh.dim_constructor dc
  ON dc.jolpica_constructor_id = q->'Constructor'->>'constructorId'
ORDER BY dr.race_key, dd.driver_key, NULLIF(q->>'position', '')::int NULLS LAST
ON CONFLICT (race_key, driver_key) DO UPDATE
   SET constructor_key = EXCLUDED.constructor_key,
       position        = EXCLUDED.position,
       q1_sec          = EXCLUDED.q1_sec,
       q2_sec          = EXCLUDED.q2_sec,
       q3_sec          = EXCLUDED.q3_sec;