# Haladási dokumentáció

## 2026. október 8.

Első alkalommal egy docker compose fájlt készítettem, aminek a segítségével egy PostgreSQL adatbázist futtató konténert lehet indítani, hiszen ebben az adatbázisban fogom tárolni a különböző API-okról érkező adatokat, emellett pedig azokat a tény és dimenzió táblákat, amelyek alapján a kimutatásokat készítem.

Ennek érdekében létrehoztam egy .sql scriptet is, amelynek segítségével inicializálni lehet a táblákat. Ez már tartalmazza az API-okról érkező adatok átmeneti tároló tábláit (stg) emelett pedig a tény és dimenzió táblákat is.

## 2026. október 12.

A mai nap folyamán az első nagyon egyszerű ETL jobot készítettem el a Pentaho segítségével. Ebben két transform kapott helyet:
 - A szezonok listájának feltöltése (évszámokkal)
 - Az egyes szezonok során rendezett futamok adatainak feltöltése

A job során ezek az adatok az stg.jolpica_races táblába kerülnek be.