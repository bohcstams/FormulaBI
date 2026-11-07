-- Rebuilds dwh.fact_result_changes: drivers whose classification differs from the order at the chequered flag.
-- Must run after fact_race_results and fact_lap_times.
-- Source 1 ('versioned'): races where fact_race_results holds several versions (first vs. current version).
-- Source 2 ('lap_data'):  history reconstructed from lap data (1996+): the on-track order is the order by
--                         laps completed and the position on the last lap; it is compared to the official result.
--                         Races with versioned results are skipped here. Races where any driver lacks lap data are skipped.
DELETE FROM dwh.fact_result_changes;

INSERT INTO dwh.fact_result_changes (
    race_key, driver_key, constructor_key, on_track_pos, official_pos, position_change,
    original_points, official_points, official_status, change_source
)
WITH first_ver AS (
    SELECT DISTINCT ON (race_key, driver_key)
           race_key, driver_key, finish_pos, points
    FROM dwh.fact_race_results
    ORDER BY race_key, driver_key, result_key
)
SELECT cur.race_key, cur.driver_key, cur.constructor_key,
       fv.finish_pos, cur.finish_pos,
       fv.finish_pos - cur.finish_pos,
       fv.points, cur.points, cur.status, 'versioned'
FROM dwh.fact_race_results cur
JOIN first_ver fv ON fv.race_key = cur.race_key AND fv.driver_key = cur.driver_key
WHERE cur.is_current
  AND (fv.finish_pos IS DISTINCT FROM cur.finish_pos
    OR fv.points     IS DISTINCT FROM cur.points);

INSERT INTO dwh.fact_result_changes (
    race_key, driver_key, constructor_key, on_track_pos, official_pos, position_change,
    official_points, official_status, change_source
)
WITH last_lap AS (
    SELECT DISTINCT ON (race_key, driver_key)
           race_key, driver_key, lap_number, position
    FROM dwh.fact_lap_times
    ORDER BY race_key, driver_key, lap_number DESC
),
pool AS (
    SELECT r.race_key, r.driver_key, r.constructor_key, r.finish_pos, r.points, r.status,
           l.lap_number, l.position AS last_lap_pos
    FROM dwh.fact_race_results r
    LEFT JOIN last_lap l ON l.race_key = r.race_key AND l.driver_key = r.driver_key
    WHERE r.is_current
      AND r.finish_pos IS NOT NULL
      AND COALESCE(r.laps_completed, 0) > 0
),
complete_races AS (
    SELECT race_key
    FROM pool
    GROUP BY race_key
    HAVING COUNT(*) = COUNT(lap_number) AND COUNT(*) = COUNT(last_lap_pos)
),
ranked AS (
    SELECT p.*,
           ROW_NUMBER() OVER (
               PARTITION BY p.race_key
               ORDER BY p.lap_number DESC, p.last_lap_pos ASC
           )::int AS on_track_pos
    FROM pool p
    JOIN complete_races cr ON cr.race_key = p.race_key
)
SELECT rk.race_key, rk.driver_key, rk.constructor_key, rk.on_track_pos, rk.finish_pos,
       rk.on_track_pos - rk.finish_pos, rk.points, rk.status, 'lap_data'
FROM ranked rk
WHERE rk.on_track_pos <> rk.finish_pos
  AND NOT EXISTS (
      SELECT 1 FROM dwh.fact_result_changes c WHERE c.race_key = rk.race_key
  )
  AND NOT EXISTS (
      SELECT 1 FROM dwh.fact_race_results v
      WHERE v.race_key = rk.race_key AND NOT v.is_current
  );

-- Steward messages from OpenF1 race control (2023+): penalties and disqualifications per driver code.
WITH latest_rc AS (
    SELECT DISTINCT ON (season, round)
           season, round, payload
    FROM stg.openf1_race_control
    WHERE season IS NOT NULL AND round IS NOT NULL
    ORDER BY season, round, stg_id DESC
),
notes AS (
    SELECT dr.race_key,
           m[2] AS code,
           STRING_AGG(DISTINCT regexp_replace(rc->>'message', '^FIA STEWARDS: ', ''), '; ') AS notes
    FROM latest_rc lrc
    JOIN dwh.dim_race dr ON dr.season_year = lrc.season AND dr.round = lrc.round
    CROSS JOIN LATERAL jsonb_array_elements(lrc.payload) AS rc
    CROSS JOIN LATERAL regexp_match(rc->>'message', 'CAR (\d+) \((\w+)\)') AS m
    WHERE rc->>'message' ~ '(TIME PENALTY|DRIVE THROUGH|STOP/GO|DISQUALIFIED|EXCLUDED|GRID POSITION PENALTY)'
      AND rc->>'message' !~ '(SERVED|NO FURTHER|NOTED|UNDER INVESTIGATION|REVIEW)'
    GROUP BY dr.race_key, m[2]
)
UPDATE dwh.fact_result_changes c
   SET penalty_notes = n.notes
  FROM notes n
  JOIN dwh.dim_driver dd ON dd.code = n.code
 WHERE c.race_key = n.race_key
   AND c.driver_key = dd.driver_key;
