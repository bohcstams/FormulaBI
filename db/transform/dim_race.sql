INSERT INTO dwh.dim_race (season_year, round, race_name, race_date, race_time, circuit_key)
SELECT DISTINCT ON ((r->>'season')::int, (r->>'round')::int)
       (r->>'season')::int,
       (r->>'round')::int,
       r->>'raceName',
       (r->>'date')::date,
       NULLIF(replace(r->>'time', 'Z', ''), '')::time,
       c.circuit_key
FROM stg.jolpica_races s,
     jsonb_array_elements(s.payload->'MRData'->'RaceTable'->'Races') AS r
JOIN dwh.dim_circuit c ON c.jolpica_circuit_id = r->'Circuit'->>'circuitId'
ORDER BY (r->>'season')::int, (r->>'round')::int, s.stg_id DESC
ON CONFLICT (season_year, round) DO UPDATE
   SET race_name = EXCLUDED.race_name, race_date = EXCLUDED.race_date,
       race_time = EXCLUDED.race_time, circuit_key = EXCLUDED.circuit_key;