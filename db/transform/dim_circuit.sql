INSERT INTO dwh.dim_circuit (jolpica_circuit_id, name, locality, country, latitude, longitude)
SELECT DISTINCT ON (r->'Circuit'->>'circuitId')
       r->'Circuit'->>'circuitId',
       r->'Circuit'->>'circuitName',
       r->'Circuit'->'Location'->>'locality',
       r->'Circuit'->'Location'->>'country',
       (r->'Circuit'->'Location'->>'lat')::numeric,
       (r->'Circuit'->'Location'->>'long')::numeric
FROM stg.jolpica_races s,
     jsonb_array_elements(s.payload->'MRData'->'RaceTable'->'Races') AS r
ORDER BY r->'Circuit'->>'circuitId', s.season DESC, s.stg_id DESC
ON CONFLICT (jolpica_circuit_id) DO UPDATE
   SET name = EXCLUDED.name, locality = EXCLUDED.locality, country = EXCLUDED.country,
       latitude = EXCLUDED.latitude, longitude = EXCLUDED.longitude;