-- 1. Map each Jolpica constructorId to its parent franchise name
WITH lineage (jolpica_constructor_id, franchise_name) AS (
    VALUES
        -- Enstone lineage
        ('benetton',      'Alpine / Renault (Enstone)'),
        ('renault',       'Alpine / Renault (Enstone)'),
        ('lotus_f1',      'Alpine / Renault (Enstone)'),
        ('alpine',        'Alpine / Renault (Enstone)'),
        -- Silverstone lineage
        ('jordan',        'Aston Martin (Silverstone)'),
        ('mf1',           'Aston Martin (Silverstone)'),
        ('spyker_mf1',    'Aston Martin (Silverstone)'),
        ('spyker',        'Aston Martin (Silverstone)'),
        ('force_india',   'Aston Martin (Silverstone)'),
        ('racing_point',  'Aston Martin (Silverstone)'),
        ('aston_martin',  'Aston Martin (Silverstone)'),
        -- Brackley lineage
        ('tyrrell',       'Mercedes (Brackley)'),
        ('bar',           'Mercedes (Brackley)'),
        ('honda',         'Mercedes (Brackley)'),
        ('brawn',         'Mercedes (Brackley)'),
        ('mercedes',      'Mercedes (Brackley)'),
        -- Milton Keynes lineage
        ('stewart',       'Red Bull Racing'),
        ('jaguar',        'Red Bull Racing'),
        ('red_bull',      'Red Bull Racing'),
        -- Faenza lineage
        ('minardi',       'Racing Bulls (Faenza)'),
        ('toro_rosso',    'Racing Bulls (Faenza)'),
        ('alphatauri',    'Racing Bulls (Faenza)'),
        ('rb',            'Racing Bulls (Faenza)'),
        -- Hinwil lineage
        ('sauber',        'Sauber / Audi (Hinwil)'),
        ('bmw_sauber',    'Sauber / Audi (Hinwil)'),
        ('alfa',          'Sauber / Audi (Hinwil)'),
        ('audi',          'Sauber / Audi (Hinwil)'),
        -- Other multi-name teams (1996+)
        ('footwork',      'Arrows'),
        ('arrows',        'Arrows'),
        ('ligier',        'Prost / Ligier'),
        ('prost',         'Prost / Ligier'),
        ('lotus_racing',  'Caterham'),
        ('caterham',      'Caterham'),
        ('virgin',        'Manor / Marussia'),
        ('marussia',      'Manor / Marussia'),
        ('manor',         'Manor / Marussia')
),
resolved_franchise AS (
    SELECT c.constructor_key,
           c.jolpica_constructor_id,
           COALESCE(l.franchise_name, c.name) AS franchise_name
    FROM dwh.dim_constructor c
    LEFT JOIN lineage l
      ON l.jolpica_constructor_id = c.jolpica_constructor_id
),
ins_franchise AS (
    INSERT INTO dwh.dim_franchise (franchise_name)
    SELECT DISTINCT franchise_name
    FROM resolved_franchise
    ON CONFLICT (franchise_name) DO NOTHING
    RETURNING franchise_key, franchise_name
)
UPDATE dwh.dim_constructor c
   SET franchise_key = f.franchise_key
  FROM resolved_franchise rf
  JOIN dwh.dim_franchise f
    ON f.franchise_name = rf.franchise_name
 WHERE c.constructor_key = rf.constructor_key
   AND c.franchise_key IS DISTINCT FROM f.franchise_key;

-- 2. Rebuild dwh.dim_constructor_alias with contiguous active season ranges + sponsor aliases
TRUNCATE TABLE dwh.dim_constructor_alias RESTART IDENTITY;

WITH constructor_seasons AS (
    SELECT DISTINCT
           dc.constructor_key,
           dc.jolpica_constructor_id,
           c->>'name' AS alias_name,
           s.season
    FROM stg.jolpica_constructors s
    CROSS JOIN LATERAL jsonb_array_elements(
        s.payload->'MRData'->'ConstructorTable'->'Constructors'
    ) AS c
    JOIN dwh.dim_constructor dc
      ON dc.jolpica_constructor_id = c->>'constructorId'
    WHERE s.season IS NOT NULL
),
islands AS (
    SELECT constructor_key,
           alias_name,
           season,
           season - ROW_NUMBER() OVER (
               PARTITION BY constructor_key, alias_name ORDER BY season
           )::int AS grp
    FROM constructor_seasons
)
INSERT INTO dwh.dim_constructor_alias (
    constructor_key, alias_name, valid_from_season, valid_to_season
)
SELECT constructor_key,
       alias_name,
       MIN(season) AS valid_from_season,
       MAX(season) AS valid_to_season
FROM islands
GROUP BY constructor_key, alias_name, grp
UNION ALL
-- Commercial / title-sponsor names used under the same constructorId
SELECT dc.constructor_key, v.alias_name, v.valid_from_season, v.valid_to_season
FROM (
    VALUES
        ('sauber', 'Stake F1 Team Kick Sauber', 2024, 2025),
        ('rb',     'Visa Cash App RB',          2024, 2024),
        ('rb',     'Racing Bulls',              2025, 2026)
) AS v (jolpica_constructor_id, alias_name, valid_from_season, valid_to_season)
JOIN dwh.dim_constructor dc
  ON dc.jolpica_constructor_id = v.jolpica_constructor_id
ORDER BY valid_from_season, constructor_key;