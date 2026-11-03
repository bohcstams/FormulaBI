WITH latest_results AS (
    SELECT DISTINCT ON (season, round)
           season, round, load_ts::date AS snapshot_date, payload
    FROM stg.jolpica_results
    WHERE season IS NOT NULL AND round IS NOT NULL
    ORDER BY season, round, stg_id DESC
),
latest_rc AS (
    SELECT DISTINCT ON (season, round)
           season, round, payload
    FROM stg.openf1_race_control
    WHERE season IS NOT NULL AND round IS NOT NULL
    ORDER BY season, round, stg_id DESC
),
sc_counts AS (
    SELECT lrc.season,
           lrc.round,
           COUNT(*) FILTER (
               WHERE rc->>'category' = 'SafetyCar'
                 AND rc->>'message' LIKE '%DEPLOYED%'
           )::int AS safety_car_cnt
    FROM latest_rc lrc,
         jsonb_array_elements(lrc.payload) AS rc
    GROUP BY lrc.season, lrc.round
),
staged AS (
    SELECT DISTINCT ON (dr.race_key, dd.driver_key)
           dr.race_key,
           dd.driver_key,
           dc.constructor_key,
           NULLIF(res->>'number', '')::int                              AS car_number,
           NULLIF(res->>'grid', '')::int                                AS grid_pos,
           NULLIF(res->>'position', '')::int                            AS finish_pos,
           res->>'positionText'                                         AS position_text,
           NULLIF(res->>'points', '')::numeric(5, 2)                    AS points,
           NULLIF(res->>'laps', '')::int                                AS laps_completed,
           res->>'status'                                               AS status,
           NOT (res->>'status' = 'Finished' OR res->>'status' LIKE '+%') AS is_dnf,
           NULLIF(res->'Time'->>'millis', '')::bigint                   AS race_time_ms,
           NULLIF(res->'FastestLap'->>'rank', '')::int                  AS fastest_lap_rank,
           NULLIF(res->'FastestLap'->>'lap', '')::int                   AS fastest_lap_number,
           etl.parse_duration_sec(res->'FastestLap'->'Time'->>'time')   AS fastest_lap_time_sec,
           dw.is_wet                                                    AS is_wet_race,
           sc.safety_car_cnt                                            AS safety_car_cnt,
           lr.snapshot_date                                             AS snapshot_date
    FROM latest_results lr
    JOIN dwh.dim_race dr
      ON dr.season_year = lr.season AND dr.round = lr.round
    LEFT JOIN dwh.dim_weather dw
      ON dw.race_key = dr.race_key
    LEFT JOIN sc_counts sc
      ON sc.season = lr.season AND sc.round = lr.round,
         jsonb_array_elements(lr.payload->'MRData'->'RaceTable'->'Races') AS r,
         jsonb_array_elements(r->'Results') AS res
    JOIN dwh.dim_driver dd
      ON dd.jolpica_driver_id = res->'Driver'->>'driverId'
    JOIN dwh.dim_constructor dc
      ON dc.jolpica_constructor_id = res->'Constructor'->>'constructorId'
    ORDER BY dr.race_key, dd.driver_key, NULLIF(res->>'position', '')::int NULLS LAST
),
-- 1. If a sporting result changed (e.g. post-race FIA penalty), expire the old version
expire_changed AS (
    UPDATE dwh.fact_race_results f
       SET is_current = FALSE
      FROM staged s
     WHERE f.race_key = s.race_key
       AND f.driver_key = s.driver_key
       AND f.is_current = TRUE
       AND (f.finish_pos     IS DISTINCT FROM s.finish_pos
         OR f.position_text  IS DISTINCT FROM s.position_text
         OR f.points         IS DISTINCT FROM s.points
         OR f.status         IS DISTINCT FROM s.status
         OR f.grid_pos       IS DISTINCT FROM s.grid_pos
         OR f.laps_completed IS DISTINCT FROM s.laps_completed)
    RETURNING f.race_key, f.driver_key
),
-- 2. Update non-versioned enrichment columns (weather / safety car count) in place if unchanged
update_enrichment AS (
    UPDATE dwh.fact_race_results f
       SET is_wet_race    = s.is_wet_race,
           safety_car_cnt = s.safety_car_cnt
      FROM staged s
     WHERE f.race_key = s.race_key
       AND f.driver_key = s.driver_key
       AND f.is_current = TRUE
       AND (f.is_wet_race    IS DISTINCT FROM s.is_wet_race
         OR f.safety_car_cnt IS DISTINCT FROM s.safety_car_cnt)
)
-- 3. Insert new rows (either first load or new version after expiring old row)
INSERT INTO dwh.fact_race_results (
    race_key, driver_key, constructor_key, car_number, grid_pos, finish_pos,
    position_text, points, laps_completed, status, is_dnf, race_time_ms,
    fastest_lap_rank, fastest_lap_number, fastest_lap_time_sec,
    is_wet_race, safety_car_cnt, is_current, snapshot_date
)
SELECT s.race_key, s.driver_key, s.constructor_key, s.car_number, s.grid_pos, s.finish_pos,
       s.position_text, s.points, s.laps_completed, s.status, s.is_dnf, s.race_time_ms,
       s.fastest_lap_rank, s.fastest_lap_number, s.fastest_lap_time_sec,
       s.is_wet_race, s.safety_car_cnt, TRUE, s.snapshot_date
FROM staged s
WHERE NOT EXISTS (
    SELECT 1 FROM dwh.fact_race_results f
    WHERE f.race_key = s.race_key
      AND f.driver_key = s.driver_key
      AND f.is_current = TRUE
)
   OR EXISTS (
    SELECT 1 FROM expire_changed e
    WHERE e.race_key = s.race_key
      AND e.driver_key = s.driver_key
);