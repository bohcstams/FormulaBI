INSERT INTO dwh.dim_driver (jolpica_driver_id, code, given_name, family_name,
                            date_of_birth, nationality, permanent_number)
SELECT DISTINCT ON (d->>'driverId')
       d->>'driverId', d->>'code', d->>'givenName', d->>'familyName',
       NULLIF(d->>'dateOfBirth','')::date, d->>'nationality',
       NULLIF(d->>'permanentNumber','')::int
FROM stg.jolpica_drivers s,
     jsonb_array_elements(s.payload->'MRData'->'DriverTable'->'Drivers') AS d
ORDER BY d->>'driverId', s.season DESC, s.stg_id DESC
ON CONFLICT (jolpica_driver_id) DO UPDATE
   SET code = EXCLUDED.code, given_name = EXCLUDED.given_name,
       family_name = EXCLUDED.family_name, date_of_birth = EXCLUDED.date_of_birth,
       nationality = EXCLUDED.nationality, permanent_number = EXCLUDED.permanent_number;