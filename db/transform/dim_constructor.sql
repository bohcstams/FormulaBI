INSERT INTO dwh.dim_constructor (jolpica_constructor_id, name, nationality)
SELECT DISTINCT ON (c->>'constructorId')
       c->>'constructorId', c->>'name', c->>'nationality'
FROM stg.jolpica_constructors s,
     jsonb_array_elements(s.payload->'MRData'->'ConstructorTable'->'Constructors') AS c
ORDER BY c->>'constructorId', s.season DESC, s.stg_id DESC
ON CONFLICT (jolpica_constructor_id) DO UPDATE
   SET name = EXCLUDED.name, nationality = EXCLUDED.nationality;