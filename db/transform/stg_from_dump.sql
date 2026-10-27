-- Builds API-shaped staging rows for lap times and pit stops from the raw Jolpica dump
-- tables (stg.dump_*, loaded by etl/job_load_dump.kjb).
-- One row per race round, only for the rounds that are not yet in stg.jolpica_laps /
-- stg.jolpica_pitstops, so the rounds already loaded from the API are kept as they are, and
-- tr_list_rounds will only list the rounds that are missing from the dump (the newest ones).
-- The payload has the same shape as the API response (MRData.RaceTable.Races[0].Laps / PitStops),
-- so the staging -> dwh transform does not need to know where a row came from. Differences:
-- one row contains every lap of the round (limit = offset + total), and Races[0] has no Circuit.

-- Lap times: Races[0].Laps[] = {number, Timings[] = {driverId, position, time}}.
WITH timing AS (
    SELECT e.season, e.round, e.race_name, e.race_date, e.race_url,
           l.number::int                    AS lap,
           NULLIF(l.position, '')::int      AS position,
           jsonb_strip_nulls(jsonb_build_object(
               'driverId', e.driver_id,
               'position', NULLIF(l.position, ''),
               'time',     etl.format_duration(NULLIF(l.time, '')::interval))) AS timing
    FROM stg.dump_lap l
    JOIN stg.v_dump_race_entry e ON e.session_entry_id = l.session_entry_id
    WHERE NULLIF(l.number, '') IS NOT NULL      -- rows without a number are the fastest-lap entries of the results
      AND e.season >= 1996
),
lap AS (
    SELECT season, round, race_name, race_date, race_url, lap,
           count(*) AS timings,
           jsonb_build_object(
               'number',  lap::text,
               'Timings', jsonb_agg(timing ORDER BY position NULLS LAST)) AS lap_json
    FROM timing
    GROUP BY season, round, race_name, race_date, race_url, lap
)
INSERT INTO stg.jolpica_laps (season, round, source_url, payload)
SELECT season, round,
       'https://api.jolpi.ca/data/dumps/download/delayed/?dump_type=csv',
       jsonb_build_object('MRData', jsonb_build_object(
           'series', 'f1',
           'limit',  sum(timings)::text,
           'offset', '0',
           'total',  sum(timings)::text,
           'RaceTable', jsonb_build_object(
               'season', season::text,
               'round',  round::text,
               'Races',  jsonb_build_array(jsonb_build_object(
                   'season',   season::text,
                   'round',    round::text,
                   'url',      race_url,
                   'raceName', race_name,
                   'date',     race_date,
                   'Laps',     jsonb_agg(lap_json ORDER BY lap))))))
FROM lap
WHERE NOT EXISTS (
    SELECT 1 FROM stg.jolpica_laps s
    WHERE s.season = lap.season AND s.round = lap.round)
GROUP BY season, round, race_name, race_date, race_url;

-- Pit stops: Races[0].PitStops[] = {driverId, lap, stop, time, duration}.
WITH stop AS (
    SELECT e.season, e.round, e.race_name, e.race_date, e.race_url,
           NULLIF(l.number, '')::int       AS lap,
           p.number::int                   AS stop,
           jsonb_strip_nulls(jsonb_build_object(
               'driverId', e.driver_id,
               'lap',      NULLIF(l.number, ''),
               'stop',     p.number,
               'time',     NULLIF(p.local_timestamp, ''),
               'duration', etl.format_duration(NULLIF(p.duration, '')::interval))) AS stop_json
    FROM stg.dump_pitstop p
    JOIN stg.v_dump_race_entry e ON e.session_entry_id = p.session_entry_id
    LEFT JOIN stg.dump_lap l ON l.id = p.lap_id
    WHERE e.season >= 1996
)
INSERT INTO stg.jolpica_pitstops (season, round, source_url, payload)
SELECT season, round,
       'https://api.jolpi.ca/data/dumps/download/delayed/?dump_type=csv',
       jsonb_build_object('MRData', jsonb_build_object(
           'series', 'f1',
           'limit',  count(*)::text,
           'offset', '0',
           'total',  count(*)::text,
           'RaceTable', jsonb_build_object(
               'season', season::text,
               'round',  round::text,
               'Races',  jsonb_build_array(jsonb_build_object(
                   'season',   season::text,
                   'round',    round::text,
                   'url',      race_url,
                   'raceName', race_name,
                   'date',     race_date,
                   'PitStops', jsonb_agg(stop_json ORDER BY lap NULLS LAST, stop))))))
FROM stop
WHERE NOT EXISTS (
    SELECT 1 FROM stg.jolpica_pitstops s
    WHERE s.season = stop.season AND s.round = stop.round)
GROUP BY season, round, race_name, race_date, race_url;
