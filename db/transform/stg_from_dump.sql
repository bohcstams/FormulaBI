-- Builds API-shaped staging rows for all Jolpica staging tables (1950-present) from the raw
-- Jolpica CSV dump tables (stg.dump_*, loaded by etl/job_load_dump.kjb).
-- Only seasons / rounds that are not yet in the target stg.jolpica_* table are inserted
-- (WHERE NOT EXISTS), so rounds already loaded from the API are kept as they are, and the
-- incremental API jobs will only fetch the newest rounds missing from the 14-day-delayed dump.
-- The payload has the same shape as the Jolpica Ergast REST API response, so the staging -> dwh
-- transforms (db/transform/dim_*.sql, fact_*.sql) do not need to know where a row came from.

-- 1. Race calendar & circuits per season (1950+): MRData.RaceTable.Races[]
WITH race_row AS (
    SELECT s.year::int   AS season,
           r.number::int AS round,
           jsonb_strip_nulls(jsonb_build_object(
               'season',   s.year,
               'round',    r.number,
               'url',      NULLIF(r.wikipedia, ''),
               'raceName', r.name,
               'Circuit',  jsonb_strip_nulls(jsonb_build_object(
                   'circuitId',   c.reference,
                   'url',         NULLIF(c.wikipedia, ''),
                   'circuitName', c.name,
                   'Location',    jsonb_strip_nulls(jsonb_build_object(
                       'lat',      NULLIF(c.latitude, ''),
                       'long',     NULLIF(c.longitude, ''),
                       'locality', NULLIF(c.locality, ''),
                       'country',  NULLIF(c.country, '')
                   ))
               )),
               'date',     r.date,
               'time',     CASE
                               WHEN ss.has_time_data = 't' AND NULLIF(ss.timestamp, '') IS NOT NULL
                               THEN to_char((ss.timestamp::timestamptz) AT TIME ZONE 'UTC', 'HH24:MI:SS"Z"')
                           END
           )) AS race_json
    FROM stg.dump_round r
    JOIN stg.dump_season s         ON s.id = r.season_id
    JOIN stg.dump_circuit c        ON c.id = r.circuit_id
    LEFT JOIN stg.dump_session ss  ON ss.round_id = r.id AND ss.type = 'R'
    WHERE NULLIF(r.number, '') IS NOT NULL
      AND r.is_cancelled = 'f'
)
INSERT INTO stg.jolpica_races (season, source_url, payload)
SELECT season,
       'https://api.jolpi.ca/data/dumps/download/delayed/?dump_type=csv',
       jsonb_build_object('MRData', jsonb_build_object(
           'series', 'f1',
           'limit',  count(*)::text,
           'offset', '0',
           'total',  count(*)::text,
           'RaceTable', jsonb_build_object(
               'season', season::text,
               'Races',  jsonb_agg(race_json ORDER BY round)
           )
       ))
FROM race_row
WHERE NOT EXISTS (
    SELECT 1 FROM stg.jolpica_races s
    WHERE s.season = race_row.season
)
GROUP BY season;

-- 2. Drivers per season (1950+): MRData.DriverTable.Drivers[]
WITH season_driver AS (
    SELECT DISTINCT
           s.year::int AS season,
           d.reference AS driver_id,
           jsonb_strip_nulls(jsonb_build_object(
               'driverId',        d.reference,
               'permanentNumber', NULLIF(d.permanent_car_number, ''),
               'code',            NULLIF(d.abbreviation, ''),
               'url',             NULLIF(d.wikipedia, ''),
               'givenName',       d.forename,
               'familyName',      d.surname,
               'dateOfBirth',     NULLIF(d.date_of_birth, ''),
               'nationality',     NULLIF(d.nationality, '')
           )) AS driver_json
    FROM stg.dump_teamdriver td
    JOIN stg.dump_season s ON s.id = td.season_id
    JOIN stg.dump_driver d ON d.id = td.driver_id
)
INSERT INTO stg.jolpica_drivers (season, source_url, payload)
SELECT season,
       'https://api.jolpi.ca/data/dumps/download/delayed/?dump_type=csv',
       jsonb_build_object('MRData', jsonb_build_object(
           'series', 'f1',
           'limit',  count(*)::text,
           'offset', '0',
           'total',  count(*)::text,
           'DriverTable', jsonb_build_object(
               'season',  season::text,
               'Drivers', jsonb_agg(driver_json ORDER BY driver_id)
           )
       ))
FROM season_driver
WHERE NOT EXISTS (
    SELECT 1 FROM stg.jolpica_drivers s
    WHERE s.season = season_driver.season
)
GROUP BY season;

-- 3. Constructors per season (1950+): MRData.ConstructorTable.Constructors[]
WITH season_constructor AS (
    SELECT DISTINCT
           s.year::int AS season,
           t.reference AS constructor_id,
           jsonb_strip_nulls(jsonb_build_object(
               'constructorId', t.reference,
               'url',           NULLIF(t.wikipedia, ''),
               'name',          t.name,
               'nationality',   NULLIF(t.nationality, '')
           )) AS constructor_json
    FROM stg.dump_teamdriver td
    JOIN stg.dump_season s ON s.id = td.season_id
    JOIN stg.dump_team t   ON t.id = td.team_id
)
INSERT INTO stg.jolpica_constructors (season, source_url, payload)
SELECT season,
       'https://api.jolpi.ca/data/dumps/download/delayed/?dump_type=csv',
       jsonb_build_object('MRData', jsonb_build_object(
           'series', 'f1',
           'limit',  count(*)::text,
           'offset', '0',
           'total',  count(*)::text,
           'ConstructorTable', jsonb_build_object(
               'season',       season::text,
               'Constructors', jsonb_agg(constructor_json ORDER BY constructor_id)
           )
       ))
FROM season_constructor
WHERE NOT EXISTS (
    SELECT 1 FROM stg.jolpica_constructors s
    WHERE s.season = season_constructor.season
)
GROUP BY season;

-- 4. Driver Championship Standings per season (1950+): MRData.StandingsTable.StandingsLists[0].DriverStandings[]
WITH driver_standing AS (
    SELECT dc.year::int                 AS season,
           NULLIF(dc.round_number, '')  AS round,
           NULLIF(dc.position, '')::int AS pos_num,
           jsonb_strip_nulls(jsonb_build_object(
               'position',     NULLIF(dc.position, ''),
               'positionText', CASE
                                   WHEN dc.adjustment_type IN ('101', '102') OR NULLIF(dc.position, '') IS NULL
                                   THEN '-'
                                   ELSE dc.position
                               END,
               'points',       trim_scale(NULLIF(dc.points, '')::numeric)::text,
               'wins',         dc.win_count,
               'Driver',       jsonb_strip_nulls(jsonb_build_object(
                   'driverId',        d.reference,
                   'permanentNumber', NULLIF(d.permanent_car_number, ''),
                   'code',            NULLIF(d.abbreviation, ''),
                   'url',             NULLIF(d.wikipedia, ''),
                   'givenName',       d.forename,
                   'familyName',      d.surname,
                   'dateOfBirth',     NULLIF(d.date_of_birth, ''),
                   'nationality',     NULLIF(d.nationality, '')
               ))
           )) AS standing_json
    FROM stg.dump_driverchampionship dc
    JOIN stg.dump_driver d ON d.id = dc.driver_id
    WHERE NULLIF(dc.season_id, '') IS NOT NULL
)
INSERT INTO stg.jolpica_driver_standings (season, source_url, payload)
SELECT season,
       'https://api.jolpi.ca/data/dumps/download/delayed/?dump_type=csv',
       jsonb_build_object('MRData', jsonb_build_object(
           'series', 'f1',
           'limit',  count(*)::text,
           'offset', '0',
           'total',  count(*)::text,
           'StandingsTable', jsonb_strip_nulls(jsonb_build_object(
               'season', season::text,
               'round',  max(round),
               'StandingsLists', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                   'season',          season::text,
                   'round',           max(round),
                   'DriverStandings', jsonb_agg(standing_json ORDER BY pos_num NULLS LAST)
               )))
           ))
       ))
FROM driver_standing
WHERE NOT EXISTS (
    SELECT 1 FROM stg.jolpica_driver_standings s
    WHERE s.season = driver_standing.season
)
GROUP BY season;

-- 5. Constructor Championship Standings per season (1958+): MRData.StandingsTable.StandingsLists[0].ConstructorStandings[]
WITH constructor_standing AS (
    SELECT tc.year::int                 AS season,
           NULLIF(tc.round_number, '')  AS round,
           NULLIF(tc.position, '')::int AS pos_num,
           jsonb_strip_nulls(jsonb_build_object(
               'position',     NULLIF(tc.position, ''),
               'positionText', CASE
                                   WHEN tc.adjustment_type IN ('101', '102') OR NULLIF(tc.position, '') IS NULL
                                   THEN '-'
                                   ELSE tc.position
                               END,
               'points',       trim_scale(NULLIF(tc.points, '')::numeric)::text,
               'wins',         tc.win_count,
               'Constructor',  jsonb_strip_nulls(jsonb_build_object(
                   'constructorId', t.reference,
                   'url',           NULLIF(t.wikipedia, ''),
                   'name',          t.name,
                   'nationality',   NULLIF(t.nationality, '')
               ))
           )) AS standing_json
    FROM stg.dump_teamchampionship tc
    JOIN stg.dump_team t ON t.id = tc.team_id
    WHERE NULLIF(tc.season_id, '') IS NOT NULL
)
INSERT INTO stg.jolpica_constructor_standings (season, source_url, payload)
SELECT season,
       'https://api.jolpi.ca/data/dumps/download/delayed/?dump_type=csv',
       jsonb_build_object('MRData', jsonb_build_object(
           'series', 'f1',
           'limit',  count(*)::text,
           'offset', '0',
           'total',  count(*)::text,
           'StandingsTable', jsonb_strip_nulls(jsonb_build_object(
               'season', season::text,
               'round',  max(round),
               'StandingsLists', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                   'season',               season::text,
                   'round',                max(round),
                   'ConstructorStandings', jsonb_agg(standing_json ORDER BY pos_num NULLS LAST)
               )))
           ))
       ))
FROM constructor_standing
WHERE NOT EXISTS (
    SELECT 1 FROM stg.jolpica_constructor_standings s
    WHERE s.season = constructor_standing.season
)
GROUP BY season;

-- 6. Race Results per round (1950+): MRData.RaceTable.Races[0].Results[]
WITH fastest_lap AS (
    SELECT DISTINCT ON (l.session_entry_id)
           l.session_entry_id,
           NULLIF(l.number, '')        AS lap_number,
           NULLIF(l.time, '')          AS lap_time,
           NULLIF(l.average_speed, '') AS avg_speed
    FROM stg.dump_lap l
    WHERE l.is_entry_fastest_lap = 't'
    ORDER BY l.session_entry_id, l.id::int
),
result_row AS (
    SELECT s.year::int                  AS season,
           r.number::int                AS round,
           r.name                       AS race_name,
           r.date                       AS race_date,
           r.wikipedia                  AS race_url,
           NULLIF(se.position, '')::int AS pos_num,
           se.id::int                   AS se_id,
           jsonb_strip_nulls(jsonb_build_object(
               'number',       NULLIF(re.car_number, ''),
               'position',     NULLIF(se.position, ''),
               'positionText', CASE
                                   WHEN se.is_classified = 't'    THEN se.position
                                   WHEN se.status = '1'           THEN 'N'
                                   WHEN se.status IN ('10', '11') THEN 'R'
                                   WHEN se.status = '20'          THEN 'D'
                                   WHEN se.status = '30'          THEN 'W'
                                   WHEN se.status IN ('40', '41') THEN 'F'
                                   ELSE COALESCE(NULLIF(se.position, ''), 'R')
                               END,
               'points',       trim_scale(NULLIF(se.points, '')::numeric)::text,
               'Driver',       jsonb_strip_nulls(jsonb_build_object(
                   'driverId',        d.reference,
                   'permanentNumber', NULLIF(d.permanent_car_number, ''),
                   'code',            NULLIF(d.abbreviation, ''),
                   'url',             NULLIF(d.wikipedia, ''),
                   'givenName',       d.forename,
                   'familyName',      d.surname,
                   'dateOfBirth',     NULLIF(d.date_of_birth, ''),
                   'nationality',     NULLIF(d.nationality, '')
               )),
               'Constructor',  jsonb_strip_nulls(jsonb_build_object(
                   'constructorId', t.reference,
                   'url',           NULLIF(t.wikipedia, ''),
                   'name',          t.name,
                   'nationality',   NULLIF(t.nationality, '')
               )),
               'grid',         NULLIF(se.grid, ''),
               'laps',         NULLIF(se.laps_completed, ''),
               'status',       NULLIF(se.detail, ''),
               'Time',         CASE
                                   WHEN NULLIF(se.time, '') IS NOT NULL THEN jsonb_build_object(
                                       'millis', round(extract(epoch FROM (se.time::interval)) * 1000)::bigint::text,
                                       'time',   etl.format_duration(se.time::interval)
                                   )
                               END,
               'FastestLap',   CASE
                                   WHEN fl.session_entry_id IS NOT NULL OR NULLIF(se.fastest_lap_rank, '') IS NOT NULL
                                   THEN jsonb_strip_nulls(jsonb_build_object(
                                       'rank', NULLIF(se.fastest_lap_rank, ''),
                                       'lap',  fl.lap_number,
                                       'Time', CASE
                                                   WHEN fl.lap_time IS NOT NULL
                                                   THEN jsonb_build_object('time', etl.format_duration(fl.lap_time::interval))
                                               END
                                   ))
                               END
           )) AS res_json
    FROM stg.dump_sessionentry se
    JOIN stg.dump_session ss    ON ss.id = se.session_id AND ss.type = 'R'
    JOIN stg.dump_round r       ON r.id  = ss.round_id
    JOIN stg.dump_season s      ON s.id  = r.season_id
    JOIN stg.dump_roundentry re ON re.id = se.round_entry_id
    JOIN stg.dump_teamdriver td ON td.id = re.team_driver_id
    JOIN stg.dump_driver d      ON d.id  = td.driver_id
    JOIN stg.dump_team t        ON t.id  = td.team_id
    LEFT JOIN fastest_lap fl    ON fl.session_entry_id = se.id
    WHERE NULLIF(r.number, '') IS NOT NULL
)
INSERT INTO stg.jolpica_results (season, round, source_url, payload)
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
                   'Results',  jsonb_agg(res_json ORDER BY pos_num NULLS LAST, se_id)
               ))
           )
       ))
FROM result_row
WHERE NOT EXISTS (
    SELECT 1 FROM stg.jolpica_results s
    WHERE s.season = result_row.season AND s.round = result_row.round
)
GROUP BY season, round, race_name, race_date, race_url;

-- 7. Qualifying Results per round (1994+): MRData.RaceTable.Races[0].QualifyingResults[]
WITH qual_sessions AS (
    SELECT ss.id          AS session_id,
           ss.round_id,
           DENSE_RANK() OVER (
               PARTITION BY ss.round_id
               ORDER BY CASE ss.type
                            WHEN 'Q1' THEN 1
                            WHEN 'Q2' THEN 2
                            WHEN 'Q3' THEN 3
                            ELSE NULLIF(ss.number, '')::int
                        END,
                        ss.id::int
           )              AS q_stage
    FROM stg.dump_session ss
    WHERE ss.type IN ('QB', 'QO', 'QA', 'Q1', 'Q2', 'Q3')
      AND EXISTS (SELECT 1 FROM stg.dump_sessionentry se WHERE se.session_id = ss.id)
),
qual_best_lap AS (
    SELECT DISTINCT ON (l.session_entry_id)
           l.session_entry_id,
           etl.format_duration(NULLIF(l.time, '')::interval) AS q_time
    FROM stg.dump_lap l
    WHERE l.is_entry_fastest_lap = 't'
      AND NULLIF(l.time, '') IS NOT NULL
    ORDER BY l.session_entry_id, l.id::int
),
qual_driver AS (
    SELECT s.year::int   AS season,
           r.number::int AS round,
           r.name        AS race_name,
           r.date        AS race_date,
           r.wikipedia   AS race_url,
           re.id         AS round_entry_id,
           re.car_number,
           d.reference   AS driver_id,
           d.permanent_car_number,
           d.abbreviation,
           d.wikipedia   AS driver_url,
           d.forename,
           d.surname,
           d.date_of_birth,
           d.nationality AS driver_nationality,
           t.reference   AS constructor_id,
           t.wikipedia   AS constructor_url,
           t.name        AS constructor_name,
           t.nationality AS constructor_nationality,
           (array_agg(NULLIF(se.position, '')::int ORDER BY qs.q_stage DESC)
               FILTER (WHERE NULLIF(se.position, '') IS NOT NULL))[1] AS position,
           MAX(qbl.q_time) FILTER (WHERE qs.q_stage = 1)              AS q1,
           MAX(qbl.q_time) FILTER (WHERE qs.q_stage = 2)              AS q2,
           MAX(qbl.q_time) FILTER (WHERE qs.q_stage = 3)              AS q3
    FROM qual_sessions qs
    JOIN stg.dump_sessionentry se ON se.session_id = qs.session_id
    JOIN stg.dump_round r         ON r.id  = qs.round_id
    JOIN stg.dump_season s        ON s.id  = r.season_id
    JOIN stg.dump_roundentry re   ON re.id = se.round_entry_id
    JOIN stg.dump_teamdriver td   ON td.id = re.team_driver_id
    JOIN stg.dump_driver d        ON d.id  = td.driver_id
    JOIN stg.dump_team t          ON t.id  = td.team_id
    LEFT JOIN qual_best_lap qbl   ON qbl.session_entry_id = se.id
    WHERE NULLIF(r.number, '') IS NOT NULL
    GROUP BY s.year, r.number, r.name, r.date, r.wikipedia,
             re.id, re.car_number,
             d.reference, d.permanent_car_number, d.abbreviation, d.wikipedia,
             d.forename, d.surname, d.date_of_birth, d.nationality,
             t.reference, t.wikipedia, t.name, t.nationality
),
qual_row AS (
    SELECT season, round, race_name, race_date, race_url, position, round_entry_id::int AS re_id,
           jsonb_strip_nulls(jsonb_build_object(
               'number',      NULLIF(car_number, ''),
               'position',    position::text,
               'Driver',      jsonb_strip_nulls(jsonb_build_object(
                   'driverId',        driver_id,
                   'permanentNumber', NULLIF(permanent_car_number, ''),
                   'code',            NULLIF(abbreviation, ''),
                   'url',             NULLIF(driver_url, ''),
                   'givenName',       forename,
                   'familyName',      surname,
                   'dateOfBirth',     NULLIF(date_of_birth, ''),
                   'nationality',     NULLIF(driver_nationality, '')
               )),
               'Constructor', jsonb_strip_nulls(jsonb_build_object(
                   'constructorId', constructor_id,
                   'url',           NULLIF(constructor_url, ''),
                   'name',          constructor_name,
                   'nationality',   NULLIF(constructor_nationality, '')
               )),
               'Q1',          q1,
               'Q2',          q2,
               'Q3',          q3
           )) AS qual_json
    FROM qual_driver
)
INSERT INTO stg.jolpica_qualifying (season, round, source_url, payload)
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
                   'season',            season::text,
                   'round',             round::text,
                   'url',               race_url,
                   'raceName',          race_name,
                   'date',              race_date,
                   'QualifyingResults', jsonb_agg(qual_json ORDER BY position NULLS LAST, re_id)
               ))
           )
       ))
FROM qual_row
WHERE NOT EXISTS (
    SELECT 1 FROM stg.jolpica_qualifying s
    WHERE s.season = qual_row.season AND s.round = qual_row.round
)
GROUP BY season, round, race_name, race_date, race_url;

-- 8. Lap times per round (1996+): MRData.RaceTable.Races[0].Laps[] = {number, Timings[] = {driverId, position, time}}
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

-- 9. Pit stops per round (2011+): MRData.RaceTable.Races[0].PitStops[] = {driverId, lap, stop, time, duration}
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

-- 10. Update data_coverage metadata to reflect full 1950+ Jolpica backfill
UPDATE etl.data_coverage
   SET note = 'Results, calendar, drivers, constructors, circuits, standings (1950+; constructor standings from 1958).'
 WHERE data_name = 'results';

UPDATE etl.data_coverage
   SET first_season = 1994
 WHERE data_name = 'qualifying' AND first_season <> 1994;
