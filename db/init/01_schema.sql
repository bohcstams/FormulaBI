-- FormulaBI schema: ETL control, staging (raw JSON) and the DWH (galaxy schema)
-- Runs automatically only when the database volume is empty (first start).

CREATE SCHEMA IF NOT EXISTS etl;
CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS dwh;

-- ---------------------------------------------------------------------------
-- ETL control
-- ---------------------------------------------------------------------------
CREATE TABLE etl.run_log (
    run_id        SERIAL PRIMARY KEY,
    job_name      TEXT        NOT NULL,           -- e.g. 'job_a_season', 'job_b_race'
    endpoint      TEXT,                           -- e.g. 'jolpica/results'
    season        INT,
    round         INT,
    status        TEXT        NOT NULL DEFAULT 'running'
                  CHECK (status IN ('running', 'success', 'failed')),
    rows_loaded   INT,
    message       TEXT,
    started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at   TIMESTAMPTZ
);
CREATE INDEX ix_run_log_lookup ON etl.run_log (job_name, endpoint, season, round, status);

-- First season for which each kind of data exists (verified with the APIs).
-- Reports use this to tell the user where the data starts.
CREATE TABLE etl.data_coverage (
    data_name     TEXT PRIMARY KEY,
    first_season  INT  NOT NULL,
    source        TEXT NOT NULL,
    note          TEXT
);
INSERT INTO etl.data_coverage (data_name, first_season, source, note) VALUES
    ('results',        1950, 'jolpica', 'Results, calendar, drivers, constructors, circuits, standings. Backfill starts at 1996.'),
    ('qualifying',     1995, 'jolpica', NULL),
    ('lap_times',      1996, 'jolpica', NULL),
    ('pit_stops',      2011, 'jolpica', NULL),
    ('weather',        2023, 'openf1',  'is_wet_race, avg_track_temp are NULL before this season'),
    ('safety_car',     2023, 'openf1',  'safety_car_cnt, is_safety_car are NULL before this season'),
    ('stints',         2023, 'openf1',  NULL);

-- ---------------------------------------------------------------------------
-- Staging: one table per endpoint, raw JSON, append-only
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'jolpica_seasons', 'jolpica_races', 'jolpica_circuits',
        'jolpica_drivers', 'jolpica_constructors',
        'jolpica_results', 'jolpica_qualifying', 'jolpica_laps', 'jolpica_pitstops',
        'jolpica_driver_standings', 'jolpica_constructor_standings',
        'openf1_sessions', 'openf1_drivers', 'openf1_weather',
        'openf1_race_control', 'openf1_stints'
    ]
    LOOP
        EXECUTE format($f$
            CREATE TABLE stg.%I (
                stg_id       BIGSERIAL PRIMARY KEY,
                season       INT,
                round        INT,
                session_key  INT,              -- OpenF1 tables only
                source_url   TEXT,
                payload      JSONB       NOT NULL,
                run_id       INT REFERENCES etl.run_log (run_id),
                load_ts      TIMESTAMPTZ NOT NULL DEFAULT now()
            )$f$, t);
        EXECUTE format('CREATE INDEX %I ON stg.%I (season, round)', 'ix_' || t || '_sr', t);
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- DWH dimensions
-- ---------------------------------------------------------------------------
CREATE TABLE dwh.dim_driver (
    driver_key            SERIAL PRIMARY KEY,
    jolpica_driver_id     TEXT NOT NULL UNIQUE,   -- e.g. 'max_verstappen'
    code                  TEXT,                   -- 3-letter code, joins to OpenF1 name_acronym
    given_name            TEXT NOT NULL,
    family_name           TEXT NOT NULL,
    date_of_birth         DATE,
    nationality           TEXT,
    permanent_number      INT                     -- not reliable for joins, informational only
);

-- Franchise lineage: groups constructor entries that are the same team
-- (e.g. cosmetic renames). Ownership changes are linked case by case.
CREATE TABLE dwh.dim_franchise (
    franchise_key   SERIAL PRIMARY KEY,
    franchise_name  TEXT NOT NULL UNIQUE
);

CREATE TABLE dwh.dim_constructor (
    constructor_key         SERIAL PRIMARY KEY,
    jolpica_constructor_id  TEXT NOT NULL UNIQUE, -- e.g. 'red_bull'
    name                    TEXT NOT NULL,
    nationality             TEXT,
    franchise_key           INT REFERENCES dwh.dim_franchise (franchise_key)
);

-- Name a constructor used in specific seasons (sponsor names etc.)
CREATE TABLE dwh.dim_constructor_alias (
    alias_key          SERIAL PRIMARY KEY,
    constructor_key    INT  NOT NULL REFERENCES dwh.dim_constructor (constructor_key),
    alias_name         TEXT NOT NULL,
    valid_from_season  INT  NOT NULL,
    valid_to_season    INT,                       -- NULL = still in use
    CHECK (valid_to_season IS NULL OR valid_to_season >= valid_from_season)
);

CREATE TABLE dwh.dim_circuit (
    circuit_key           SERIAL PRIMARY KEY,
    jolpica_circuit_id    TEXT NOT NULL UNIQUE,   -- e.g. 'bahrain'
    openf1_circuit_key    INT,                    -- filled from the matched OpenF1 session
    name                  TEXT NOT NULL,
    locality              TEXT,
    country               TEXT,
    latitude              NUMERIC(9, 6),
    longitude             NUMERIC(9, 6)
);

CREATE TABLE dwh.dim_season (
    season_year                INT PRIMARY KEY,
    champion_driver_key        INT REFERENCES dwh.dim_driver (driver_key),
    champion_constructor_key   INT REFERENCES dwh.dim_constructor (constructor_key)
);

-- One row per Grand Prix; also carries the link to the OpenF1 session.
CREATE TABLE dwh.dim_race (
    race_key            SERIAL PRIMARY KEY,
    season_year         INT  NOT NULL REFERENCES dwh.dim_season (season_year),
    round               INT  NOT NULL,
    race_name           TEXT NOT NULL,
    race_date           DATE NOT NULL,
    race_time           TIME,
    circuit_key         INT  NOT NULL REFERENCES dwh.dim_circuit (circuit_key),
    openf1_session_key  INT,                      -- NULL before 2023 or until matched
    UNIQUE (season_year, round)
);

-- Per-race weather summary (OpenF1, 2023 onward)
CREATE TABLE dwh.dim_weather (
    weather_key       SERIAL PRIMARY KEY,
    race_key          INT NOT NULL UNIQUE REFERENCES dwh.dim_race (race_key),
    avg_track_temp    NUMERIC(5, 2),
    avg_air_temp      NUMERIC(5, 2),
    avg_humidity      NUMERIC(5, 2),
    is_wet            BOOLEAN                     -- any rainfall during the race
);

-- ---------------------------------------------------------------------------
-- DWH facts
-- ---------------------------------------------------------------------------
-- Versioned: a changed result (e.g. later FIA penalty) inserts a new row and
-- flips the old one to is_current = FALSE.
CREATE TABLE dwh.fact_race_results (
    result_key             BIGSERIAL PRIMARY KEY,
    race_key               INT NOT NULL REFERENCES dwh.dim_race (race_key),
    driver_key             INT NOT NULL REFERENCES dwh.dim_driver (driver_key),
    constructor_key        INT NOT NULL REFERENCES dwh.dim_constructor (constructor_key),
    car_number             INT,
    grid_pos               INT,                   -- 0 = pit lane start in the API
    finish_pos             INT,
    position_text          TEXT,                  -- 'R' = retired, 'D', 'W', ...
    points                 NUMERIC(5, 2),
    laps_completed         INT,
    status                 TEXT,
    is_dnf                 BOOLEAN,
    race_time_ms           BIGINT,
    fastest_lap_rank       INT,
    fastest_lap_number     INT,
    fastest_lap_time_sec   NUMERIC(8, 3),
    is_wet_race            BOOLEAN,               -- NULL before 2023
    safety_car_cnt         INT,                   -- NULL before 2023
    is_current             BOOLEAN NOT NULL DEFAULT TRUE,
    snapshot_date          DATE    NOT NULL DEFAULT CURRENT_DATE
);
CREATE UNIQUE INDEX ux_fact_results_current
    ON dwh.fact_race_results (race_key, driver_key) WHERE is_current;

CREATE TABLE dwh.fact_qualifying (
    qualifying_key   BIGSERIAL PRIMARY KEY,
    race_key         INT NOT NULL REFERENCES dwh.dim_race (race_key),
    driver_key       INT NOT NULL REFERENCES dwh.dim_driver (driver_key),
    constructor_key  INT NOT NULL REFERENCES dwh.dim_constructor (constructor_key),
    position         INT,
    q1_sec           NUMERIC(8, 3),
    q2_sec           NUMERIC(8, 3),
    q3_sec           NUMERIC(8, 3),
    UNIQUE (race_key, driver_key)
);

CREATE TABLE dwh.fact_lap_times (
    lap_key          BIGSERIAL PRIMARY KEY,
    race_key         INT NOT NULL REFERENCES dwh.dim_race (race_key),
    driver_key       INT NOT NULL REFERENCES dwh.dim_driver (driver_key),
    lap_number       INT NOT NULL,
    position         INT,
    lap_time_sec     NUMERIC(8, 3),
    is_safety_car    BOOLEAN,                     -- NULL before 2023
    avg_track_temp   NUMERIC(5, 2),               -- NULL before 2023
    UNIQUE (race_key, driver_key, lap_number)
);

CREATE TABLE dwh.fact_pit_stops (
    pit_stop_key     BIGSERIAL PRIMARY KEY,
    race_key         INT NOT NULL REFERENCES dwh.dim_race (race_key),
    driver_key       INT NOT NULL REFERENCES dwh.dim_driver (driver_key),
    constructor_key  INT REFERENCES dwh.dim_constructor (constructor_key),
    stop_number      INT NOT NULL,
    in_lap           INT,
    duration_sec     NUMERIC(8, 3),
    local_time       TIME,
    UNIQUE (race_key, driver_key, stop_number)
);

CREATE INDEX ix_fact_laps_race       ON dwh.fact_lap_times (race_key);
CREATE INDEX ix_fact_pits_race       ON dwh.fact_pit_stops (race_key);
CREATE INDEX ix_fact_results_driver  ON dwh.fact_race_results (driver_key);
