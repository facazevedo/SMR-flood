# Flood

Rain fills low ground on the surface of Surviving Mars Relaunched. A volume budget drives water height and expanding shorelines. Separate depressions fill independently, overflow at their saddles, then join into lakes. Open map edges drain water. Dry weather lowers the water through evaporation and infiltration. Standing water and rain then act on the colony: buildings, dust, groundwater, soil, rovers, drones, shuttles, trains, construction and colonists.

The temporary panel has exactly four buttons:

- **Light**, **Moderate**, **Heavy**: start that strength; click the active strength again to stop. Choosing another strength replaces the test storm.
- **Fresh / Toxic**: change the selected type, including during a test storm.

These controls invoke actual game storms and their ordinary soil, vegetation and toxic-pool effects. They do not cancel unrelated disasters. Disabling Flood stops only a storm it owns. Natural rain also feeds Flood automatically. Martian Waters' cosmetic-only rain is not precipitation; use gameplay rain or Flood's buttons. Below the buttons the panel shows rain, evaporation, pools, stored water, flooded buildings and slowed rovers.

Fresh water is blue; toxic water is yellow-green. Mixing dilutes the color continuously. Evaporation concentrates dissolved contamination; infiltration removes it with the water. Dry contaminant residue persists until subsequently washed out. Flood does not alter vanilla toxic-pool behavior.

## Gameplay effects

Vanilla rain only changes vegetation growth, global soil quality, toxic pools, Landscaping lakes and some terraforming buildings. Every effect below is added by Flood, and each has its own switch in `Code/fl_config.lua`. Rain-driven effects scale with the nominal storm rate relative to `RAIN_REFERENCE_MM_H` (15 mm/h). The test-storm 10x multiplier only speeds up filling; it never scales effects. Water effects use depth (mm) and toxic concentration sampled under the object.

| Switch | Effect | Game mechanism |
| --- | --- | --- |
| `ENABLE_CLIMATE_EVAPORATION` | Evaporation is up to 25x faster on barren Mars, falling to the base rate as `min(Atmosphere, Temperature)` terraforming reaches 100% | `GetTerraformParamPct` |
| `ENABLE_BUILDING_FLOODING` | Outdoor operating buildings under 300 mm of water stop (resume below 250 mm); shallower water adds wear | `SetSuspended(…, "Flooded")`, maintenance points |
| `ENABLE_CONSTRUCTION_RULES` | Placement on deep water is blocked; on shallow water it is warned | Construction statuses |
| `ENABLE_RAIN_DUST_WASHING` | Any rain washes accumulated dust off everything that collects it in the open: buildings, domes, cables, pipes, drones, rovers | Each object's own `AddDust` (negative), over the dust-storm object set |
| `ENABLE_TOXIC_CORROSION` | Toxic rain corrodes outdoor buildings, outpacing the washing | Maintenance points |
| `ENABLE_GROUNDWATER_RECHARGE` | Fresh water soaking in under a pool refills water deposits within 150 m | Deposit `amount`, capped at `max_amount` |
| `ENABLE_TOXIC_SOIL` | Toxic water and dried toxic residue lower soil quality locally | `SoilAdd` per hex |
| `ENABLE_FRESH_SOIL` | Fresh standing water raises soil quality locally, up to 60%; plants respond to soil | `SoilAdd` per hex |
| `ENABLE_ROVER_SLOWDOWN` | Rovers drive 40% slower in water deeper than 200 mm | `move_speed` modifier |
| `ENABLE_ROVER_BREAKDOWN` | Rovers driven past 700 mm risk an electrical breakdown each hour, more often in toxic water; drones repair it | Vanilla `Malfunction` |
| `ENABLE_DRONE_EFFECTS` | Drones fly slower in rain; hovering ground drones lose battery in water over 250 mm; toxic rain leaves grime that can break them down | `Drone` label modifier, `UseBattery`, `AddDust` |
| `ENABLE_SHUTTLE_EFFECTS` | Shuttles fly slower in rain; storms of 40 mm/h and above ground them until they ease | `CargoShuttle` label modifier, hub suspension like dust storms |
| `ENABLE_TRAIN_EFFECTS` | Trains run at 50% over rails under 100 mm of water and crawl at 15% above 400 mm; flooded stations stop new trips | Speed per track element |
| `ENABLE_COLONIST_EFFECTS` | Colonists in the open (outside domes, or in opened domes, not inside buildings) are affected. Toxic rain stresses them, and once the air is breathable it also harms them; suits protect them while it is not. Toxic water burns skin in breathable air. Deep water exhausts them, and water over their head (1.4 m) can drown them. Fresh rain under an open, breathable sky lifts their sanity. | `ChangeHealth`, `ChangeSanity`, with reasons in the colonist log |

A missing engine API turns off only the affected effect and is logged as `effect availability`.

## Configuration

Edit `Code/fl_config.lua`, redeploy, then restart the game. `metadata.lua` is the only mod-version source. `metadata.lua` and `items.lua` contain identical explicit script order. The entry point is `Code/Flood.lua`; supporting files use `fl_`.

| Setting | Default | Meaning |
| --- | ---: | --- |
| `ENABLE_MOD` | `true` | Master simulation switch |
| `ENABLE_TEST_UI` | `true` | Temporary four-button panel |
| `RAIN_MM_H` | 5 / 15 / 40 | Light / moderate / heavy rain, mm per game hour |
| `TEST_RAIN_MULTIPLIER` | 10 | Faster filling for test storms only; set to 1 for ordinary rates |
| `EVAPORATION_MM_H` | 0.4 | Standing-water evaporation on a fully terraformed planet |
| `INFILTRATION_MM_H` | 1.5 | Standing-water infiltration |
| `RUNOFF_COEFFICIENT` | 0.65 | Fraction of rain on dry ground reaching low ground |
| `CELL_SIZE_M` | 4 | Requested terrain sampling spacing |
| `MAX_GRID_CELLS` | 262144 | Larger maps explicitly use a coarser grid, shown in the panel/log |
| `SUBSAMPLE_M`, `MAX_SUBSAMPLES` | 4, 4 | Each cell takes the lowest of up to 4 x 4 height reads, so narrow notches in basin rims are not missed |
| `TICK_MS` | 3000 | Game time between simulation steps (1/10 game hour) |
| `EFFECT_INTERVAL_HOURS` | 1 | Cadence of building, dust, soil, groundwater, breakdown and colonist effects |
| `WET_SNAPSHOT_TICKS` | 3 | Ticks between per-cell depth snapshots (effects) and water redraws |
| `MAX_RENDERED_POOLS` | 400 | Largest pools drawn as native water; smaller ones still count in the model and effects |
| `RENDER_BUDGET_MS` | 60 | Real time per redraw spent rebuilding native water; the rest follows on later redraws |
| `MARKER_AREA_SLACK`, `MIN_MARKER_AREA_M2` | 3, 2000 | Bound on each drawn lake's area before the engine lowers it to stop a spill |
| `LARGE_LAKE_PLANES`, `LARGE_LAKE_STEP_MM` | 2000, 100 | Lakes with this many native water planes redraw every 100 mm of level change; small pools beside them defer their clean-up to the large lake's redraw |
| `DEBUG_LOGS` | `true` | Lifecycle, API failures, terrain, save and rain diagnostics |
| `DEBUG_HYDROLOGY` | `false` | Per-tick water-budget diagnostics; also requires `DEBUG_LOGS == true` |
| `DEBUG_EFFECTS` | `true` | Per-pass effect summaries; also requires `DEBUG_LOGS == true` |

Each effect's thresholds and rates sit next to its switch in `Code/fl_config.lua`.

`Flood.Lifecycle.Disable()` removes owned visuals, UI and test rain, lifts flood and storm suspensions, and removes speed modifiers, while retaining numeric water data for re-enabling. `Flood.Lifecycle.Enable()` restores it. Repeated calls are idempotent.

Flood touches vanilla code in these places:

- It wraps two methods at load: `ConstructionController:FinalizeStatusGathering` (construction statuses) and `Train:GetNominalMoveSpeed` (flooded rails). Classes copy methods when they are built, so the wrappers stay installed and pass through unchanged whenever Flood or the switch is off.
- It adds entries to four vanilla tables: `NotWorkingWarning`, `ConstructionStatus`, `ColonistStatReasons` and `DeathReasons`.
- It modifies no shared water presets.

## Saves and removal

The simulation thread is stopped before every save and restarted afterwards, so saves hold only the numerical water state (schema 1, on the surface map), never the thread or the in-memory model. Water markers and speed modifiers are removed before serialization and reapplied on the next tick. Flood and storm suspensions of buildings and shuttle hubs are kept in the save so they survive a reload. To remove Flood from a colony, call `Flood.Lifecycle.Disable()` in the console and save first. Otherwise buildings that were flooded at save time stay suspended without an explanation text.

## Physical scope

This is a catchment storage model for the game's terraforming setting, not an atmospheric Mars climate simulation. Its fill/spill/merge design follows the depression-hierarchy principle described by [Barnes, Callaghan and Wickert (2021)](https://esurf.copernicus.org/articles/9/105/2021/); the implementation here is original Lua. The game exposes storm strength, not measured precipitation, so configurable rates supply that missing physical quantity.

Catchment runoff routes within each simulation tick. Infiltration is a configurable effective rate. Evaporation scales with terraforming but is not a temperature- or pressure-resolved model. Holes smaller than the sampling grid may be missed; "every hole" cannot be guaranteed below that resolution. Surface shape is rendered by the native water grid and may differ near a shoreline from the sampled volume model. Terrain is never carved or modified by Flood. Landscaping triggers a rebuild, and periodic scans detect other terrain edits while redistributing saved volume. Simulation and drying pause with game time. Underground and asteroid maps do not receive rain.

### Rendering and performance

Each drawn pool is one native `TerrainWaterObject` that the engine flood-fills from the pool's lowest point. Native fills dominate the cost, so:

- **Drawn pools:** only the `MAX_RENDERED_POOLS` largest are drawn.
- **Redraw budget:** each redraw spends at most `RENDER_BUDGET_MS` on native work, largest level changes first.
- **Marker reuse:** markers move with their water when basins merge or split.
- **Rising water:** only fills; it never clears and refills.
- **Narrow rebuild:** a lowered or dried surface clears only its own box and refills the water objects touching it. It doesn't use `ApplyAllWaterObjects`, whose box grows over every intersecting object; that made one cleared lake refill nearly the whole map, taking 2.4 s.
- **Large lakes:** a lake of thousands of planes takes about 0.8 s to refill, so it redraws only every 100 mm, and small pools beside it leave their clean-up to its next redraw.
- **Spill bound:** each drawn lake's area is bounded, so a level that overshoots a rim notch narrower than the sampling is lowered by the engine instead of flooding the map.

All figures below were measured under the harness's debugger on a 6 km map with 147,456 cells. Retail runs without the debugger hook are faster.

- **Simulation step:** about 35 ms.
- **Snapshot:** about 130 ms.
- **Redraw:** about 70 ms on average and about 110 ms at worst on a map flooded by several metres of test rain.

The game has no local vegetation-growth control. Plants respond to the soil grid, which is how vanilla toxic pools and Landscaping lakes act locally, so Flood's vegetation effects go through soil quality. Effects are sampled at object centers and build footprints at hex resolution.

## Ownership and reference sources

Flood is standalone. It uses Martian Waters' native `TerrainWaterObject` approach as a reference, with a distinct `FloodWaterMarker` subclass. It does not copy its assets, import its state, call its broad cleanup routines, or edit its project. Existing water remains owned by its creator; overlapping native water surfaces need in-game compatibility checks.

Read-only local game references under `C:\Games\Surviving Mars Relaunched\ModTools\Src`:

- `CommonLua/Water.lua`: marker placement, water planes, shader properties and water-grid rebuilding.
- `Lua/TerraformingDisasters.lua` and `Data/MapSettings-RainsDisaster.lua`: rain types, strength presets, threads and stop behavior.
- `CommonLua/Core/lib.lua`: map variables and game-logic checks.
- `CommonLua/Savegame.lua`: pre-save and post-save lifecycle.
- `Lua/Landscape/LandscapeConstructionSiteBase.lua`: completed-landscaping event.
- `Lua/Terraforming.lua`: terraforming parameters and breathable atmosphere.
- `Lua/Buildings/BaseBuilding.lua`, `Lua/Buildings/Building.lua`, `Lua/RequiresMaintenance.lua`: suspension, warnings, maintenance and dust.
- `Lua/DustStorm.lua`, `Lua/SupplyGrid.lua`, `Lua/Buildings/TriboelectricScrubber.lua`: the dust object set and negative dust.
- `Lua/Buildings/SubsurfaceDeposit.lua`: deposit amounts.
- `Lua/Soil.lua`, `Lua/Vegetation.lua`, `Lua/Buildings/SensorTower.lua`, `Lua/ToxicPool.lua`: soil grid writes.
- `Lua/Modifiers.lua`, `Lua/LabelContainer.lua`, `Lua/Units/DroneBase.lua`, `Lua/Units/Drone.lua`, `Lua/Buildings/BaseRover.lua`, `Lua/DustDevils.lua`: speed modifiers, battery, breakdowns.
- `Lua/Buildings/ShuttleHub.lua`, `Lua/Flight.lua`: shuttle speed and hub grounding.
- `Lua/Units/Train.lua`, `Lua/TrainTransport.lua`: train speed and station selection.
- `Lua/Units/Colonist.lua`, `Lua/Buildings/Dome.lua`, `Lua/Interests.lua`: colonist stats, exposure and reasons.
- `Lua/Construction/Construction.lua`: construction statuses.

`AGENTS.md` and `CLAUDE.md` remain unchanged. The game installation and all sibling mod projects are read-only references. No vendored code or generated assets are included.

## Validation and deployment

Run `python -B tools/fl_validate.py` for syntax, manifest order and the offline tests:

- `tests/fl_hydrology_test.lua`: volume, tracer and save conservation.
- `tests/fl_effects_test.lua`: every effect module and a lifecycle tick, run against minimal engine stubs.

Run `python -B tools/fl_deploy.py` to validate and copy only `metadata.lua`, `items.lua` and `Code/*.lua` to `%APPDATA%\Surviving Mars Relaunched\Mods\flood`. The destination must identify itself as Flood; extra files stop deployment. Copy hashes are checked and nothing is deleted.

The source folder is this project root. Lua 5.4 `lua` and `luac` are used for local checks. The stub tests catch logic and wiring errors but are not the game.

### In-game tests

`scenarios/flood_ingame.lua` runs inside a live hidden game through `D:\PROJS\SMR\smr-harness` (`smr.cmd`):

- `flood_00_new_game`: starts a fresh colony map and checks the scan and that every effect is available.
- `flood_20_effects`: floods a basin and checks every building, vehicle, colonist, dust and shuttle effect, then disable/enable.
- `flood_10_rain`: runs real Heavy fresh and toxic storms and checks storage, spill bounds, contamination, the panel and that the redraw catches up.
- `flood_30_save_load`: saves the flooded colony (the simulation stops and restarts around the save), loads it, checks the water volume is restored, then deletes the test save.

Last full run (2026-10-04, game revision 405907, 6 km random map): all 78 checks passed.

| Scenario | Checks |
|---|---|
| `flood_00_new_game` | 18/18 |
| `flood_20_effects` | 32/32 |
| `flood_10_rain` | 16/16 |
| `flood_30_save_load` | 12/12 |

The save/load run restored 100,187,559 m³ of 100,190,287 m³.

Run them after `smr daemon start --hidden`. Enable Flood for the session (`TurnModOn("Flood")`, then `smr reload --full`), then run `smr test <scenario> --project <this folder> --screenshot`. Reports and screenshots go to `.harness/`.

Game logs are in `%APPDATA%\Surviving Mars Relaunched\logs`. Search for `[Flood:` and Lua errors. Logs are retained; no automatic deletion workflow is configured.

## In-game acceptance checks

1. Enable Flood in the mod manager and restart. Load a surface colony or start a map with visible depressions; wait for terrain scanning to finish. The log lists `effect availability` with `available=true` for every effect.
2. Start Light, Moderate and Heavy separately. Verify exactly one selected strength, faster filling at higher strengths, and rain stopping when that strength is clicked again.
3. Toggle Fresh/Toxic while rain runs. Verify the weather switches and incoming water changes lake color gradually. Real toxic storms can spawn vanilla toxic pools.
4. Stop rain and watch water recede through evaporation/infiltration. Test a shallow puddle, two basins separated by a low ridge, a deep crater and an edge-draining valley. Evaporation is much faster on an unterraformed map.
5. Effects:
   1. Flood an outdoor building: it shows "Flooded" and stops, then resumes as the water drops.
   2. Place a building on a flooded site: it is blocked or warned.
   3. Drive a rover into a lake: it slows, and past fording depth it may break down.
   4. Run a Heavy storm: shuttle hubs ground, then resume when it ends.
   5. Flood a rail: trains slow over it.
   6. During toxic rain, check a colonist outside a dome: their log shows the Flood reasons.
6. Save/reload with wet basins, after drying, during a test storm, and with flooded buildings. The water budget, residue and flood suspensions should survive. The transient test multiplier resets on reload, while a saved game storm follows vanilla behavior.
7. Call Disable twice, then Enable twice. Confirm owned markers, buttons, suspensions and speed modifiers disappear/reappear without duplicates and other mods' water remains unchanged.
8. Complete landscaping and revisit the basin. Verify no water appears from nothing, except new rain; spill leaving the map is recorded as outflow.
9. Test both feature flags and the debug flags. Review fresh game logs for errors.
