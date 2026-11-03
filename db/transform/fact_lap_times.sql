WITH latest_rc AS (
    SELECT DISTINCT ON (season, round)
           season, round, payload
    FROM stg.openf1_race_control
    WHERE season IS NOT NULL AND round IS NOT NULL
    ORDER BY season, round, stg_id DESC
),
sc_laps AS (
    SELECT DISTINCT
           lrc.season,
           lrc.round,
           (rc->>'lap_number')::int AS lap_number
    FROM latest_rc lrc
    CROSS JOIN LATERAL jsonb_array_elements(lrc.payload) AS rc
    WHERE rc->>'lap_number' IS NOT NULL
      AND (rc->>'category' = 'SafetyCar'
        OR (rc->>'scope' = 'Track' AND rc->>'flag' IN ('YELLOW', 'DOUBLE YELLOW')))
)
INSERT INTO dwh.fact_lap_times (
    race_key, driver_key, lap_number, position, lap_time_sec, is_safety_car, avg_track_temp
)
SELECT DISTINCT ON (dr.race_key, dd.driver_key, (l->>'number')::int)
       dr.race_key,
       dd.driver_key,
       (l->>'number')::int                      AS lap_number,
       NULLIF(t->>'position', '')::int          AS position,
       etl.parse_duration_sec(t->>'time')       AS lap_time_sec,
       CASE
           WHEN lrc.season IS NULL THEN NULL
           ELSE (scl.lap_number IS NOT NULL)
       END                                      AS is_safety_car,
       dw.avg_track_temp                        AS avg_track_temp
FROM stg.jolpica_laps s
JOIN dwh.dim_race dr
  ON dr.season_year = s.season AND dr.round = s.round
LEFT JOIN dwh.dim_weather dw
  ON dw.race_key = dr.race_key
LEFT JOIN latest_rc lrc
  ON lrc.season = s.season AND lrc.round = s.round
CROSS JOIN LATERAL jsonb_array_elements(s.payload->'MRData'->'RaceTable'->'Races') AS r
CROSS JOIN LATERAL jsonb_array_elements(r->'Laps') AS l
CROSS JOIN LATERAL jsonb_array_elements(l->'Timings') AS t
JOIN dwh.dim_driver dd
  ON dd.jolpica_driver_id = t->>'driverId'
LEFT JOIN sc_laps scl
  ON scl.season = s.season
 AND scl.round = s.round
 AND scl.lap_number = (l->>'number')::int
WHERE s.season IS NOT NULL AND s.round IS NOT NULL
ORDER BY dr.race_key, dd.driver_key, (l->>'number')::int, s.stg_id DESC
ON CONFLICT (race_key, driver_key, lap_number) DO UPDATE
   SET position       = EXCLUDED.position,
       lap_time_sec   = EXCLUDED.lap_time_sec,
       is_safety_car  = EXCLUDED.is_safety_car,
       avg_track_temp = EXCLUDED.avg_track_temp;