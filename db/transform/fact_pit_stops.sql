WITH latest_pits AS (
    SELECT DISTINCT ON (season, round)
           season, round, payload
    FROM stg.jolpica_pitstops
    WHERE season IS NOT NULL AND round IS NOT NULL
    ORDER BY season, round, stg_id DESC
)
INSERT INTO dwh.fact_pit_stops (
    race_key, driver_key, constructor_key, stop_number, in_lap, duration_sec, local_time
)
SELECT DISTINCT ON (dr.race_key, dd.driver_key, (p->>'stop')::int)
       dr.race_key,
       dd.driver_key,
       fr.constructor_key,
       (p->>'stop')::int                        AS stop_number,
       NULLIF(p->>'lap', '')::int               AS in_lap,
       etl.parse_duration_sec(p->>'duration')   AS duration_sec,
       CASE WHEN p->>'time' ~ '^[0-9]{2}:[0-9]{2}:[0-9]{2}'
            THEN (p->>'time')::time
       END                                      AS local_time
FROM latest_pits lp
JOIN dwh.dim_race dr
  ON dr.season_year = lp.season AND dr.round = lp.round
CROSS JOIN LATERAL jsonb_array_elements(lp.payload->'MRData'->'RaceTable'->'Races') AS r
CROSS JOIN LATERAL jsonb_array_elements(r->'PitStops') AS p
JOIN dwh.dim_driver dd
  ON dd.jolpica_driver_id = p->>'driverId'
LEFT JOIN dwh.fact_race_results fr
  ON fr.race_key = dr.race_key
 AND fr.driver_key = dd.driver_key
 AND fr.is_current = TRUE
WHERE NULLIF(p->>'stop', '') IS NOT NULL
ORDER BY dr.race_key, dd.driver_key, (p->>'stop')::int
ON CONFLICT (race_key, driver_key, stop_number) DO UPDATE
   SET constructor_key = EXCLUDED.constructor_key,
       in_lap          = EXCLUDED.in_lap,
       duration_sec    = EXCLUDED.duration_sec,
       local_time      = EXCLUDED.local_time;