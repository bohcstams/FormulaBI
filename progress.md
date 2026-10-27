# Haladási dokumentáció

## 2026. október 8.

Első alkalommal egy docker compose fájlt készítettem, aminek a segítségével egy PostgreSQL adatbázist futtató konténert lehet indítani, hiszen ebben az adatbázisban fogom tárolni a különböző API-okról érkező adatokat, emellett pedig azokat a tény és dimenzió táblákat, amelyek alapján a kimutatásokat készítem.

Ennek érdekében létrehoztam egy .sql scriptet is, amelynek segítségével inicializálni lehet a táblákat. Ez már tartalmazza az API-okról érkező adatok átmeneti tároló tábláit (stg) emelett pedig a tény és dimenzió táblákat is.

## 2026. október 12.

A mai nap folyamán az első nagyon egyszerű ETL jobot készítettem el a Pentaho segítségével. Ebben két transform kapott helyet:
 - A szezonok listájának feltöltése (évszámokkal)
 - Az egyes szezonok során rendezett futamok adatainak feltöltése

A job során ezek az adatok az stg.jolpica_races táblába kerülnek be.

## 2026. október 13.

Elkészítettem a második ETL jobot (job_load_season_dims), amely a pilóták és a csapatok szezononkénti adatait tölti be. Az első jobhoz képest az a újdonság, hogy a végpont paraméterezett (ENDPOINT): a tr_list_seasons és az új tr_load_endpoint_season transform ugyanazt a logikát használja a drivers és a constructors végpontra, a Table Output pedig a céltáblát mezőből (target_table) veszi. A job lefutott, az stg.jolpica_drivers és az stg.jolpica_constructors tábla is 31-31 sort tartalmaz (1996-2026). A futamhétvégék adatai már az stg.jolpica_races táblában voltak, ezért ahhoz nem kellett új betöltés.

A staging táblákból feltöltöttem a dimenziókat SQL-lel (db/transform mappa): dim_season, dim_circuit, dim_race, dim_driver, dim_constructor. A scriptek idempotensek (ON CONFLICT), és a staging táblák append-only jellege miatt mindig a legfrissebb sort veszik figyelembe. A jsonb_array_elements függvénnyel bontottam szét a JSON tömböket sorokra. A tartalmukat ellenőriztem, hibamentesen lefutottak.

## 2026. október 14.

Elkészítettem a Jolpica fordulónkénti adatainak betöltését. Új a `tr_list_rounds` transform, amely a `dwh.dim_race` táblából listázza azokat a fordulókat, amelyek még nincsenek a megfelelő staging táblában, így a betöltés megszakítás után folytatható. A `tr_load_endpoint_round` az eddigi szezonális transform fordulós változata, ezt a `job_load_round_data` job hívja az eredményekre, az időmérőre és a bokszkiállásokra. Az indulás után több hibát kellett javítanom: elírt séma a listázó lekérdezésben, a `ROUND` és `DELAY_SECONDS` paraméterek hiánya a transzformációból, a `round` oszlop hiánya a Table Outputban, és a Download bejegyzéseknél a `SEASON`/`ROUND` paraméterek nem a result sorból érkeztek (a *Stream column name* oszlopot kellett kitölteni). Ezek miatt kezdetben az 1996-os első forduló töltődött be többször. Ezeket a hibás sorokat töröltem, és a javítás után a 2025–2026-os tesztbetöltés rendben lefutott.

Az API a kéréseket korlátozza (429, Cloudflare 1015). Az órás limit kb. 500 kérés, ezért a `DELAY_SECONDS` értékét 8 másodpercre állítottam (kb. 450 kérés/óra). Az 1996-tól induló teljes betöltés (eredmények, időmérő, 2011-től a bokszkiállások) jelenleg fut.

Ezzel párhuzamosan elkészítettem a köridők betöltését is (2023-tól): `tr_laps_total` (a forduló köridő-rekordjainak száma), `tr_load_laps_pages` (az oldalak letöltése `offset` szerint), `job_load_laps_round` (egy forduló, a félbemaradt betöltés törlésével) és `job_load_laps` (a hiányzó fordulók listája és a fordulónkénti futtatás). Ezek még nem futottak le, mert a rate limit miatt megvárom a többi betöltés végét.

## 2026. október 27.

A köridők és a bokszkiállások történeti feltöltésének felgyorsítására (az API rate limit megkerülésére) elkészült a Jolpica adatbázis-dump (CSV export) alapú betöltés:
 - `db/init/02_dump_schema.sql`: létrehozza a CSV fájloknak megfelelő nyers `stg.dump_*` táblákat, a futambejegyzéseket összekapcsoló `stg.v_dump_race_entry` nézetet, valamint az időtartamokat az API formátumára alakító `etl.format_duration` függvényt.
 - `etl/tr_load_dump_csv.ktr` és `etl/job_load_dump.kjb`: letölti és kicsomagolja a CSV dumpot a `data/jolpica_dump` mappába, majd betölti a szükséges 9 CSV fájlt az `stg.dump_*` táblákba, végül lefuttatja az SQL transzformációt.
 - `db/transform/stg_from_dump.sql`: a dump táblákból az API válaszaival megegyező JSONB szerkezetű sorokat állít elő az `stg.jolpica_laps` és az `stg.jolpica_pitstops` táblákba (1996-tól), kihagyva a már betöltött fordulókat.

A `db/transform/stg_from_dump.sql` scriptben egy felesleges záró zárójel javítása után a dump alapú betöltés sikeresen lefutott: az `stg.jolpica_laps` táblába 585 forduló (1996–2026), az `stg.jolpica_pitstops` táblába pedig a korábban API-ról betöltött 98 forduló mellé további 228 forduló került be.

Ezután lefuttattam a `job_load_round_data` és a `job_load_laps` jobokat, hogy a 14 napos késleltetésű dumpból még hiányzó legfrissebb fordulók is bekerüljenek az API-ról. A `tr_laps_total` transzformációban az egész szám típusú mezők (`season`, `round`, `total`) formátumát `#`-re kellett állítani, mert üres formátummaszk mellett a Pentaho szóközzel és vezető nullákkal adta át a paramétereket az URL-be. A javítás után a `job_load_laps` is hibamentesen lefutott, és 12 lapozott sorban letöltötte a hiányzó 2026-os 18. forduló köridőit. Ezzel mind a négy Jolpica staging tábla (`jolpica_results`: 586 sor, `jolpica_qualifying`: 586 sor, `jolpica_pitstops`: 328 sor, `jolpica_laps`: 597 sor / 586 forduló) teljes.

Elkészült és lefutott az OpenF1 adatok betöltése is (`etl/job_load_openf1.kjb`, 2023-tól, `DELAY_SECONDS = 3` másodperces késleltetéssel):
 - `etl/tr_list_openf1_seasons.ktr` és `etl/tr_load_openf1_sessions.ktr`: szezononként letölti a futamok (`session_name=Race`) session adatait az `stg.openf1_sessions` táblába (4 sor: 2023–2026).
 - `db/transform/dim_openf1_session.sql`: összekapcsolja az OpenF1 futamokat a `dwh.dim_race` táblával (`openf1_session_key`, legfeljebb 1 napos UTC vs. helyi dátumeltérés megengedésével a szombat esti Las Vegas-i futamok miatt, így mind a 93 futam összekapcsolódott 2023–2026 között), valamint feltölti a `dwh.dim_circuit.openf1_circuit_key` oszlopot (26 pálya).
 - `etl/tr_list_openf1_sessions.ktr` és `etl/tr_load_openf1_endpoint.ktr`: a már lezajlott futamokra (`race_date < current_date` és `openf1_session_key IS NOT NULL`) végpontonként (`weather`, `race_control`, `stints`, `drivers`) letölti a még hiányzó session-ök adatait az `stg.openf1_*` táblákba. Mind a négy táblába 88–88 nem üres JSONB sor került be (2023: 22, 2024: 24, 2025: 24, 2026: 18 futam).

