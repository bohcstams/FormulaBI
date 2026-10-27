-- Links dwh.dim_race and dwh.dim_circuit to OpenF1 identifiers using stg.openf1_sessions.
-- Matches Race sessions by season_year and race_date (allowing a 1-day UTC vs. local date
-- offset, e.g. Las Vegas GP where local Saturday night is Sunday morning in UTC).

WITH openf1_race AS (
    SELECT DISTINCT ON ((js->>'session_key')::int)
           (js->>'session_key')::int               AS session_key,
           (js->>'year')::int                      AS season_year,
           left(js->>'date_start', 10)::date       AS session_date,
           (js->>'circuit_key')::int               AS openf1_circuit_key
    FROM stg.openf1_sessions s,
         jsonb_array_elements(s.payload) AS js
    WHERE js->>'session_name' = 'Race'
    ORDER BY (js->>'session_key')::int, s.stg_id DESC
),
matched_race AS (
    SELECT DISTINCT ON (r.race_key)
           r.race_key,
           r.circuit_key,
           o.session_key,
           o.openf1_circuit_key
    FROM dwh.dim_race r
    JOIN openf1_race o
      ON o.season_year = r.season_year
     AND abs(r.race_date - o.session_date) <= 1
    ORDER BY r.race_key, abs(r.race_date - o.session_date)
),
upd_race AS (
    UPDATE dwh.dim_race r
       SET openf1_session_key = m.session_key
      FROM matched_race m
     WHERE r.race_key = m.race_key
       AND r.openf1_session_key IS DISTINCT FROM m.session_key
)
UPDATE dwh.dim_circuit c
   SET openf1_circuit_key = sub.openf1_circuit_key
  FROM (
      SELECT DISTINCT ON (circuit_key)
             circuit_key,
             openf1_circuit_key
      FROM matched_race
      WHERE openf1_circuit_key IS NOT NULL
      ORDER BY circuit_key, race_key DESC
  ) sub
 WHERE c.circuit_key = sub.circuit_key
   AND c.openf1_circuit_key IS DISTINCT FROM sub.openf1_circuit_key;
