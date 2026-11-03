WITH latest_weather AS (
    SELECT DISTINCT ON (s.season, s.round)
           r.race_key,
           s.payload
    FROM stg.openf1_weather s
    JOIN dwh.dim_race r
      ON r.season_year = s.season
     AND r.round = s.round
    ORDER BY s.season, s.round, s.stg_id DESC
)
INSERT INTO dwh.dim_weather (race_key, avg_track_temp, avg_air_temp, avg_humidity, is_wet)
SELECT lw.race_key,
       ROUND(AVG((w->>'track_temperature')::numeric), 2) AS avg_track_temp,
       ROUND(AVG((w->>'air_temperature')::numeric), 2)   AS avg_air_temp,
       ROUND(AVG((w->>'humidity')::numeric), 2)          AS avg_humidity,
       BOOL_OR((w->>'rainfall')::numeric > 0)            AS is_wet
FROM latest_weather lw,
     jsonb_array_elements(lw.payload) AS w
GROUP BY lw.race_key
ON CONFLICT (race_key) DO UPDATE
   SET avg_track_temp = EXCLUDED.avg_track_temp,
       avg_air_temp   = EXCLUDED.avg_air_temp,
       avg_humidity   = EXCLUDED.avg_humidity,
       is_wet         = EXCLUDED.is_wet;