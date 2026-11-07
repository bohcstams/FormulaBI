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

## 2026. november 3.

Befejeztem a még hiányzó staging táblák (`stg.jolpica_driver_standings`, `stg.jolpica_constructor_standings`) feltöltését. Mivel a Jolpica API végpontok neve (`driverstandings`, `constructorstandings`) nem tartalmaz aláhúzásjelet, a staging táblák neve viszont igen, a `tr_list_seasons` és a `tr_load_endpoint_season` transzformációkat kiegészítettem egy `TARGET_TABLE` paraméterrel, a `tr_list_seasons`-ben pedig egy `Select values` lépéssel `#` formátummaszkot állítottam be a `season` mezőre. A `job_load_season_dims` jobot kibővítettem a két új végponttal; a futtatás után mindkét táblába bekerült a 31-31 szezon (1996–2026) végeredménye.

Elkészítettem a még hiányzó dimenzió-transzformációkat és az összes dimenziót betöltő `etl/job_transform_dims.kjb` Pentaho jobot:
 - `db/transform/dim_weather.sql`: az `stg.openf1_weather` JSON mintáiból futamonkénti átlagos pálya- és levegőhőmérsékletet, páratartalmat, valamint esős futam (`is_wet`) jelzőt számol a `dwh.dim_weather` táblába.
 - `db/transform/dim_season.sql`: kiegészítettem a lezárt szezonok egyéni és konstruktőri világbajnokainak (`champion_driver_key`, `champion_constructor_key`) frissítésével a bajnoki állások staging tábláiból.
 - `db/transform/dim_franchise.sql`: feltölti a csapatok jogfolytonosságát összefogó `dwh.dim_franchise` táblát (pl. Alpine / Renault, Aston Martin, Mercedes, Red Bull Racing, Racing Bulls, Sauber / Audi), beállítja a `dwh.dim_constructor.franchise_key` kulcsokat, és sziget-algoritmussal (`ROW_NUMBER`) előállítja a `dwh.dim_constructor_alias` időszakait és a szponzorneveket.

Végül elkészítettem a négy ténytábla SQL transzformációit és az ezeket futtató `etl/job_transform_facts.kjb` jobot:
 - Az időtartamok (`SS.mmm`, `M:SS.mmm`, `H:MM:SS.mmm`) másodpercre váltásához létrehoztam az `etl.parse_duration_sec` függvényt (`db/init/02_dump_schema.sql`).
 - `db/transform/fact_qualifying.sql`: az időmérő edzések eredményeit és a Q1/Q2/Q3 időket tölti a `dwh.fact_qualifying` táblába.
 - `db/transform/fact_race_results.sql`: a futameredményeket tölti a `dwh.fact_race_results` táblába, összekapcsolva az esős futam jelzővel (`dim_weather`) és a Safety Car fázisok számával (`stg.openf1_race_control`), valamint kezeli az utólagos FIA-büntetések verziózását (`is_current`, `snapshot_date`).
 - `db/transform/fact_pit_stops.sql` és `db/transform/fact_lap_times.sql`: a bokszkiállásokat és a köridőket tölti be (`dwh.fact_pit_stops`, `dwh.fact_lap_times`), a lapozott API sorok deduplikálásával és a 2023 utáni Safety Car körök megjelölésével. A JSON tömbök kibontásánál a vesszős felsorolást `CROSS JOIN LATERAL`-ra kellett cserélni, hogy a megelőző tábla-aliasok láthatóak maradjanak a `LEFT JOIN` feltételekben. A javítás után a teljes `job_transform_facts` job hibamentesen lefutott, így a `dwh` séma minden dimenzió- és ténytáblája feltöltődött.

## 2026. november 4.

Kibővítettem a Jolpica CSV dump alapú betöltést (`db/init/02_dump_schema.sql`, `etl/tr_load_dump_csv.ktr`, `db/transform/stg_from_dump.sql`), hogy ne csak a köridőket és a bokszkiállásokat, hanem mind a 9 Jolpica staging táblát (`jolpica_races`, `jolpica_drivers`, `jolpica_constructors`, `jolpica_driver_standings`, `jolpica_constructor_standings`, `jolpica_results`, `jolpica_qualifying`, `jolpica_laps`, `jolpica_pitstops`) feltöltse **1950-től** kezdődően. Ehhez 4 új nyers dump táblát (`dump_circuit`, `dump_team`, `dump_driverchampionship`, `dump_teamchampionship`) vettem fel, a `dim_franchise.sql` scriptet pedig kiegészítettem az 1950 és 1995 közötti csapat-jogelődökkel és karosszéria-motor kombinációkkal (pl. Toleman, Team Lotus, Brabham, Cooper, McLaren, March).

Végül elkészítettem a két fő vezérlő (orchestrator) Pentaho jobot:
 - `etl/job_weekly_update.kjb`: a rendszeres heti (keddenkénti) frissítő job, amely frissíti az aktuális szezon naptárát, pilótáit, csapatait és bajnoki állásait (`tr_list_seasons.ktr`), letölti az új fordulók adatait és 21 napos csúszóablakban újratölti a legutóbbi futameredményeket az utólagos FIA-büntetések követéséhez (`tr_list_rounds.ktr`), letölti az OpenF1 adatokat, majd lefuttatja a dimenzió- és ténytábla-transzformációkat.
 - `etl/job_init_all.kjb`: egy üres adatbázis teljes inicializáló jobja, amely először lefuttatja a `job_load_dump` jobot (1950-től betöltve a teljes történeti állományt a CSV dumpból), majd meghívja a `job_weekly_update` jobot az elmúlt 14 nap API-adatainak és az OpenF1 adatoknak a pótlására, valamint a teljes `dwh` csillagséma felépítésére.

A heti frissítő job parancssori indításához elkészült az `etl/run_weekly_update.bat` script (amely elindítja a PostgreSQL konténert, meghívja a Pentaho `Kitchen.bat`-ot, és az `etl/logs/` mappába naplóz), az automatikus heti futtatást pedig a Windows Task Schedulerben ütemeztem és teszteltem.


Elkezdtem a Power BI riport (`FormulaBI.pbix`, a repository gyökerében) elkészítését. A Power BI Desktopban a PostgreSQL adatbázishoz (`localhost:5432`, `formulabi`) **Import** móddal csatlakoztam, és betöltöttem a `dwh` séma összes dimenzió- és ténytábláját, valamint az `etl.data_coverage` táblát. A Power Query-ben a táblanevekből eltávolítottam a séma előtagot, a `dim_driver` táblában pedig létrehoztam a `driver_name` oszlopot (`given_name` + `family_name`). A modellnézetben a `dim_season` és a `dim_driver`, illetve `dim_constructor` közötti bajnoki kulcs kapcsolatokat (`champion_driver_key`, `champion_constructor_key`) törölni kellett: ezek miatt a `dim_season → dim_race → fact_*` útvonal inaktív lett, és az évenkénti bontásban minden évre ugyanaz az érték (26 202 eredménysor) jelent meg. A kapcsolatok `1 → *` irányúak, egy irányú szűréssel, a `fact_race_results[is_current] = True` szűrő pedig az összes oldalra érvényes, hogy alapból a hivatalos eredmények látszódjanak. A földrajzi adatoknál az adatkategóriát (szélesség, hosszúság) beállítottam a térképhez.

A DAX mérőszámokat egy külön `_Measures` táblában gyűjtöm (a mérőszámok mindig az `is_current = TRUE` verziót használják):
  - Alap mutatók: `Total Points`, `Race Wins`, `Podiums`, `Races Entered`.
  - Időmérő determináltsága: `Pole Positions`, `Pole to Win %`, `Avg Grid Position`, `Avg Finish Position`, `Avg Positions Gained` (a kiesők és a boxutcából indulók nélkül).
  - Időjárás és Safety Car: `DNF Count`, `DNF Rate %`, `Avg Lap Time (s)`, `Clean Race Pace (s)` (Safety Car körök nélkül), `Safety Car Pace Delta (s)`.
  - Bokszkiállások: `Avg Pit Stop (s)`, `Pit Stop StdDev (s)` és `Slow Pit Stop Rate %` (a 60 másodpercnél hosszabb kiállásokat kihagyják).

A riport 5 oldalból áll: **1. Data Coverage & Overview**, **2. Franchise & Championship History**, **3. Track Affinity & Qualifying**, **4. Race Pace & Pit Stop Strategy**, **5. Weather, Safety Car & Steward Audit**. Ezek közül az 1–3. oldalt kezdtem el.
  - **1. oldal:** négy KPI kártya (futamok, pilóták, köridő rekordok, bokszkiállás rekordok; a futamok kártyán a *Display units* értéke *None*), az `etl.data_coverage` táblából készült adatlefedettségi tábla és oszlopdiagram, valamint az évenkénti rekordszámokat mutató vegyes diagram, amelyen látszik az eredmények 1950-es, az időmérő 1994-es, a köridők 1996-os és a bokszkiállások 2011-es kezdete. A Power Query-ben az `etl.data_coverage` táblában az alulvonásokat szóközre cseréltem, és nagy kezdőbetűs formára alakítottam az adatnevet és a forrást. A mezőket átneveztem (pl. `Count of driver_key` → `Total Drivers`).
  - **Téma:** a riport egységes sötét témát kapott (*View → Themes*, az oldal- és vizuál-háttér egyedi sötét színnel), mert az alkalmazás sötét módja csak a menüket érinti.
  - **2. oldal:** a franchise-ok dominanciája időben (halmozott terület diagram), a franchise → konstruktőr hierarchiát tartalmazó mátrix (a részösszegek kikapcsolva, mert a végösszeg értelmetlen), valamint az örökranglista legjobb 15 pilótával (*Top N* szűrő). A `Total Points` mérőszám dinamikus formátuma (`IF(MOD(SELECTEDMEASURE(), 1) = 0, "#,0", "#,0.##")`) csak a tizedesjegyeket mutatja, ha van. A szezon és franchise szeletelők szinkronizáltak, a franchise szeletelő pedig a `[Races Entered] > 0` vizuál szintű szűrő miatt csak a kiválasztott időszakban versenyző csapatokat listázza.
  - **3. oldal:** `Pole to Win %` pályánként, a rajt és a befutó összevetése pilótánként (pontdiagram), a pilóta és pálya mátrix (`Avg Positions Gained`, feltételes háttérszínezéssel), valamint a pályák térképe. A pálya és pilóta szeletelők ugyanazzal a `[Races Entered] > 0` szűrővel csak a kiválasztott időszak elemeit mutatják.

## 2026. november 6.

A 3. oldal finomítása:
  - A `Pole to Win %` diagramon a pilótánkénti 100%-os értékek (pl. Alonso) valójában kis mintából adódtak (egy pole pozíció egy győzelemmel), nem hibás a mérőszám. A diagramon ezért a `[Pole Positions]` mérőszám alapján szűrök (legalább 2–3 pole), a `[Pole Positions]` pedig tooltip-ként is megjelenik. A tengely tartományát 0–1 (0–100%) értékre rögzítettem, hogy az oszlopok mérete ne legyen félrevezető.
  - A slicereken bekapcsoltam a keresőmezőt (*Slicer settings → Search*). A pályák több elemének kijelölése Ctrl + kattintással működik.
  - A pontdiagramban a `dim_driver[Driver Label]` számított oszlop (`COALESCE(code, UPPER(LEFT(family_name, 3)))`) a buborékok felirata, a színeket a családnév adja (*Legend*).
  - A pálya és pilóta mátrixban a pilóták szerinti rendezést a Power BI oszlopoknál nem teszi lehetővé mérőszám alapján. Ezt a pilóták sorba, a pályák oszlopba helyezésével és az összesen oszlop szerinti rendezéssel oldom meg.

## 2026. november 7.

A Power BI riport 5. oldalához (FIA steward audit) elkészült a `dwh.fact_result_changes` tábla (`db/init/01_schema.sql`, `db/transform/fact_result_changes.sql`), amely azokat a pilótákat listázza, akiknek a besorolása a leintés után megváltozott. Mivel a `fact_race_results` verziózása (`is_current`) csak az első betöltés utáni módosításokat látja, és a betöltött adatok már a végleges eredményeket tartalmazták, két forrás van (`change_source`):
  - `versioned`: a jövőbeli módosítások: a `fact_race_results` első és aktuális verziójának eltérése (pozíció vagy pontszám).
  - `lap_data`: a múltbeli futamok rekonstrukciója (1996-tól): a pályán mért sorrend (lefutott körök és az utolsó kör pozíciója, `fact_lap_times`) összevetve a hivatalos eredménnyel. Azokat a futamokat kihagyja, ahol valamelyik pilótához nincs köridő-adat, illetve ahol már van verziózott módosítás.
A 2023 utáni futamoknál a `penalty_notes` oszlop az OpenF1 `race_control` üzeneteiből (`stg.openf1_race_control`) tölti a büntetések szövegét. A script a `job_transform_facts.kjb` utolsó lépéseként fut (teljes újraépítés, idempotens). Első futtatás: 754 sor, 143 futam (1996–2026).

5. oldal: az időjárás hatását a pilóták esős és száraz futamokon elért átlagos pozíciónyereségének összevetése mutatja (pontdiagram: [Avg Positions Gained (Dry)] az X, [Avg Positions Gained (Wet)] az Y tengelyen, a méret a [Wet Races], és kiegészítő sávdiagram a [Wet Advantage] értékkel, legalább 2–3 esős futamot megkövetelve), mert a pályahőmérséklet inkább a pályát és a szezont jellemzi, mint a pilótát. Az időjárás-adatok 2023-tól érhetők el, ezért az esős futam jelzők korábban NULL értékűek.

A steward audit tábla elkészítésekor kiderült, hogy a fact_race_results verziózása (is_current) nem tartalmaz módosítást, mivel a Jolpica dump és az API betöltések már a végleges eredményeket hozták (26 202 sor, mind is_current = TRUE, nincs olyan futam-pilóta pár, amelynek több verziója lenne). A Power BI-ban ezért a verziókat összehasonlító mérőszámok helyett a dwh.fact_result_changes táblát használom: a 5. oldalon mátrix jeleníti meg a változásokat szezon, futam (Race Label = forduló és futamnév) és pilóta szerinti, lenyitható csoportosításban. A mátrix mérőszámai (Drivers Affected, On-track Pos, Official Pos, Position Shift, Official Status, Steward Notes) az ISINSCOPE függvénnyel csak a pilóta szintjén mutatnak értéket. Az original_points oszlop a rekonstruált (lap_data) sorokban üres, mert a pontszámok eredeti értéke nem állapítható meg, ezért a pontváltozás nem számolható. A Power BI Desktop nem frissül magától, a heti futás után a *Home → Refresh* gombbal kell betölteni az új sorokat.
