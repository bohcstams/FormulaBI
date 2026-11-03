INSERT INTO dwh.dim_season (season_year)
SELECT DISTINCT season
FROM stg.jolpica_races
ON CONFLICT (season_year) DO NOTHING;

-- Update World Drivers' Champion for completed seasons
WITH latest_ds AS (
    SELECT DISTINCT ON (season) season, payload
    FROM stg.jolpica_driver_standings
    WHERE season IS NOT NULL
    ORDER BY season, stg_id DESC
),
driver_champ AS (
    SELECT l.season AS season_year,
           d.driver_key
    FROM latest_ds l,
         jsonb_array_elements(l.payload->'MRData'->'StandingsTable'->'StandingsLists') AS sl,
         jsonb_array_elements(sl->'DriverStandings') AS ds
    JOIN dwh.dim_driver d ON d.jolpica_driver_id = ds->'Driver'->>'driverId'
    WHERE ds->>'position' = '1'
      AND NOT EXISTS (
          SELECT 1 FROM dwh.dim_race r
          WHERE r.season_year = l.season AND r.race_date >= CURRENT_DATE
      )
)
UPDATE dwh.dim_season s
   SET champion_driver_key = dc.driver_key
  FROM driver_champ dc
 WHERE s.season_year = dc.season_year
   AND s.champion_driver_key IS DISTINCT FROM dc.driver_key;

-- Update World Constructors' Champion for completed seasons
WITH latest_cs AS (
    SELECT DISTINCT ON (season) season, payload
    FROM stg.jolpica_constructor_standings
    WHERE season IS NOT NULL
    ORDER BY season, stg_id DESC
),
constructor_champ AS (
    SELECT l.season AS season_year,
           c.constructor_key
    FROM latest_cs l,
         jsonb_array_elements(l.payload->'MRData'->'StandingsTable'->'StandingsLists') AS sl,
         jsonb_array_elements(sl->'ConstructorStandings') AS cs
    JOIN dwh.dim_constructor c ON c.jolpica_constructor_id = cs->'Constructor'->>'constructorId'
    WHERE cs->>'position' = '1'
      AND NOT EXISTS (
          SELECT 1 FROM dwh.dim_race r
          WHERE r.season_year = l.season AND r.race_date >= CURRENT_DATE
      )
)
UPDATE dwh.dim_season s
   SET champion_constructor_key = cc.constructor_key
  FROM constructor_champ cc
 WHERE s.season_year = cc.season_year
   AND s.champion_constructor_key IS DISTINCT FROM cc.constructor_key;