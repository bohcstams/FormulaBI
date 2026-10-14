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
