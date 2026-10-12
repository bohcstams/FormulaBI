INSERT INTO dwh.dim_season (season_year)
SELECT DISTINCT season
FROM stg.jolpica_races
ON CONFLICT (season_year) DO NOTHING;