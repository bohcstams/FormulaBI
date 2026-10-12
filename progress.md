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

