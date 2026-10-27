-- Raw copies of the Jolpica CSV database dump (https://api.jolpi.ca/data/dumps/download/).
-- Only the files needed for the lap time and pit stop backfill are loaded. Every column is
-- TEXT, named after the CSV header; etl/tr_load_dump_csv.ktr truncates and reloads them.
-- The script is idempotent: etl/job_load_dump.kjb runs it before every load.
CREATE TABLE IF NOT EXISTS stg.dump_season (
    id TEXT,
    api_id TEXT,
    championship_system_id TEXT,
    wikipedia TEXT,
    year TEXT
);
CREATE TABLE IF NOT EXISTS stg.dump_round (
    id TEXT,
    api_id TEXT,
    circuit_id TEXT,
    date TEXT,
    is_cancelled TEXT,
    name TEXT,
    number TEXT,
    race_number TEXT,
    season_id TEXT,
    wikipedia TEXT
);
CREATE TABLE IF NOT EXISTS stg.dump_session (
    id TEXT,
    api_id TEXT,
    completed_distance TEXT,
    completed_laps TEXT,
    has_time_data TEXT,
    is_cancelled TEXT,
    number TEXT,
    point_system_id TEXT,
    round_id TEXT,
    scheduled_laps TEXT,
    timestamp TEXT,
    timezone TEXT,
    type TEXT
);
CREATE TABLE IF NOT EXISTS stg.dump_sessionentry (
    id TEXT,
    api_id TEXT,
    detail TEXT,
    driver_of_the_day_percentage TEXT,
    driver_of_the_day_winner TEXT,
    fastest_lap_rank TEXT,
    grid TEXT,
    is_classified TEXT,
    is_eligible_for_points TEXT,
    laps_completed TEXT,
    points TEXT,
    position TEXT,
    round_entry_id TEXT,
    session_id TEXT,
    status TEXT,
    time TEXT
);
CREATE TABLE IF NOT EXISTS stg.dump_roundentry (
    id TEXT,
    api_id TEXT,
    car_number TEXT,
    round_id TEXT,
    team_driver_id TEXT
);
CREATE TABLE IF NOT EXISTS stg.dump_teamdriver (
    id TEXT,
    api_id TEXT,
    driver_id TEXT,
    role TEXT,
    season_id TEXT,
    team_id TEXT
);
CREATE TABLE IF NOT EXISTS stg.dump_driver (
    id TEXT,
    abbreviation TEXT,
    api_id TEXT,
    country_code TEXT,
    date_of_birth TEXT,
    forename TEXT,
    nationality TEXT,
    permanent_car_number TEXT,
    reference TEXT,
    surname TEXT,
    wikipedia TEXT
);
CREATE TABLE IF NOT EXISTS stg.dump_lap (
    id TEXT,
    api_id TEXT,
    average_speed TEXT,
    is_deleted TEXT,
    is_entry_fastest_lap TEXT,
    number TEXT,
    position TEXT,
    session_entry_id TEXT,
    time TEXT
);
CREATE TABLE IF NOT EXISTS stg.dump_pitstop (
    id TEXT,
    api_id TEXT,
    duration TEXT,
    lap_id TEXT,
    local_timestamp TEXT,
    number TEXT,
    session_entry_id TEXT
);

-- Race (session type 'R') entries of the dump with season, round and the Ergast driverId.
CREATE OR REPLACE VIEW stg.v_dump_race_entry AS
SELECT se.id          AS session_entry_id,
       s.year::int    AS season,
       r.number::int  AS round,
       r.name         AS race_name,
       r.date         AS race_date,
       r.wikipedia    AS race_url,
       d.reference    AS driver_id
FROM stg.dump_sessionentry se
JOIN stg.dump_session    ss ON ss.id = se.session_id AND ss.type = 'R'
JOIN stg.dump_round      r  ON r.id  = ss.round_id
JOIN stg.dump_season     s  ON s.id  = r.season_id
JOIN stg.dump_roundentry re ON re.id = se.round_entry_id
JOIN stg.dump_teamdriver td ON td.id = re.team_driver_id
JOIN stg.dump_driver     d  ON d.id  = td.driver_id;

-- Formats a duration like the Jolpica API (format_timedelta in jolpica/formula_one/utils.py):
-- 00:01:16.29 -> '1:16.290', 00:00:24.036 -> '24.036', 01:02:03.4 -> '1:02:03.400'.
CREATE OR REPLACE FUNCTION etl.format_duration(d INTERVAL) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT regexp_replace(
               CASE WHEN h > 0 THEN lpad(h::text, 2, '0') || ':' ELSE '' END
            || CASE WHEN h > 0 OR m > 0 THEN lpad(m::text, 2, '0') || ':' ELSE '' END
            || to_char(s, 'FM00.000'),
           '^0', '')
    FROM (SELECT floor(e / 3600)::int       AS h,
                 floor(mod(e, 3600) / 60)::int AS m,
                 mod(e, 60)                 AS s
          FROM (SELECT extract(epoch FROM d) AS e) x) y
$$;
