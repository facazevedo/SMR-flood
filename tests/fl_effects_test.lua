-- Offline checks for Flood effect modules and the lifecycle tick against minimal
-- engine stubs. The stubs reproduce only the documented contracts the modules rely
-- on (cited in each module); they are not the game. In-game behavior still needs
-- manual verification.
local count = 0
local function check(cond, message) assert(cond, message); count = count + 1 end
local function near(a, b, message)
    check(math.abs(a - b) < 0.0001 + math.abs(b) * 0.000001, (message or "") .. ": " .. tostring(a) .. " vs " .. tostring(b))
end

-- Engine stubs ---------------------------------------------------------------
guim = 1000
const = { HourDuration = 30000, HeightTileSize = 1000, ResourceScale = 1000, SoilGridScale = 100,
    GridSpacing = 10000, MaxMaintenance = 100000, Scale = { Stat = 1000 } }
g_Classes = { SubsurfaceDepositWater = {}, CargoShuttle = {}, ShuttleHubBase = {}, FloodWaterMarker = {} }
MapVarValues = {}
function MapVar(name, value) assert(MapVarValues[name] == nil, "map var registered twice"); MapVarValues[name] = value or false end
function Untranslated(s) return { s } end
NotWorkingWarning, ConstructionStatus, ColonistStatReasons, DeathReasons = {}, {}, {}, {}
local finalized = 0
ConstructionController = { FinalizeStatusGathering = function(self, old_t) finalized = finalized + 1 end }
Train = { GetNominalMoveSpeed = function(self, element) return 1000, 3000 end }
DefineClass = setmetatable({}, { __newindex = function(_, name, def) rawset(_G, name, def) end })
TerrainWaterObject = {}
BaseRover = { SetModifier = function() end }
Drone = { UseBattery = function() end }
Modifier = { new = function(self, t) return t end }
local rolls = 0
SessionRandom = { Random = function(self, n) return rolls end }
local breathable = false
function GetAtmosphereBreathable() return breathable end
function IsObjInOpenAir(obj) return not obj.parent_dome end

local Point = {}
Point.__index = Point
function Point:x() return self[1] end
function Point:y() return self[2] end
function Point:xy() return self[1], self[2] end
function point(x, y) return setmetatable({ x, y }, Point) end

function IsValid(o) return type(o) == "table" and o.valid ~= false end
function IsKindOf(o, class) return type(o) == "table" and o.classes ~= nil and o.classes[class] == true end
function IsKindOfClasses(o, ...)
    for _, class in ipairs({ ... }) do if IsKindOf(o, class) then return true end end
    return false
end
function HexAngleToDirection() return 0 end
function HexRotate(x, y) return x, y end
function WorldToHex(x, y)
    if type(x) == "table" then x, y = x:xy() end
    return math.floor(x / 10000), math.floor(y / 10000)
end
function HexToWorld(q, r) return q * 10000 + 5000, r * 10000 + 5000 end
function ForEachHexInCircle(pos, rad, cb)
    local q, r = WorldToHex(pos)
    local h = rad // 10000 + 1
    for dq = -h, h do for dr = -h, h do cb(q + dq, r + dr) end end
end
local soil, soil_changed = {}, 0
SoilGrid = {}
function GetSoilQuality(q, r) return math.floor(soil[q .. ":" .. r] or 50) end
function SoilAdd(q, r, delta) local k = q .. ":" .. r; soil[k] = (soil[k] or 50) + delta / const.SoilGridScale end
function OnSoilGridChanged() soil_changed = soil_changed + 1 end
local terraform = { Atmosphere = 0, Temperature = 0 }
function GetTerraformParamPct(name) return terraform[name] end
function Sleep() end
function GetPreciseTicks() return 0 end
function RGB() return 0 end
function RGBA() return 0 end
local real_print = print
print = function() end -- silence debug logs

local function object(x, y, classes, extra)
    local o = { pos = point(x, y), classes = classes or {} }
    function o:GetPos() return self.pos end
    function o:GetAngle() return 0 end
    function o:GetMap() return MainMap end
    function o:IsValidPos() return true end
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

-- Building stub implementing the SetSuspended reason-slot and maintenance contracts.
local function building(x, y, classes)
    local b = object(x, y, classes or { ElectricityConsumer = true }, { suspended = false, parent_dome = false,
        destroyed = false, accumulate_maintenance_points = true, maintenance_threshold_current = 100000,
        accumulated_maintenance_points = 0 })
    function b:GetBuildShape() return { point(0, 0) } end
    function b:DoesRequireMaintenance() return true end
    function b:AccumulateMaintenancePoints(p)
        self.accumulated_maintenance_points = math.max(0, math.min(self.maintenance_threshold_current,
            self.accumulated_maintenance_points + p))
    end
    function b:AddDust(amount) self:AccumulateMaintenancePoints(amount) end
    function b:SetSuspended(on, reason)
        if on then self.suspended = reason elseif self.suspended == reason then self.suspended = false end
    end
    return b
end

local function modifiable(o)
    o.mods = {}
    function o:SetModifier(prop, id, amount, percent)
        self.mods[id] = (amount ~= 0 or percent ~= 0) and percent or nil
    end
    return o
end

local function dusty(o, max)
    o.dust, o.dust_max = 0, max
    function o:GetDustMax() return self.dust_max end
    function o:AddDust(d) self.dust = math.max(0, math.min(self.dust_max, self.dust + d)) end
    function o:IsDead() return false end
    return o
end

-- Load the payload in metadata order; the entry file only registers OnMsg handlers.
OnMsg = {}
local metadata = io.open("metadata.lua"):read("a")
for path in metadata:gmatch('"(Code/[^"]+%.lua)"') do
    if not path:find("Flood.lua") then dofile(path) end
end
local F = Flood

-- Terrain: a 10 x 10 bowl of 4 m cells (40 m square), deepest in the middle.
local W, Hgt = 10, 10
local z = {}
for y = 1, Hgt do for x = 1, W do
    local dx, dy = x - 5.5, y - 5.5
    z[#z + 1] = math.floor((dx * dx + dy * dy) * 100)
end end
local cell = 4 * guim
local grid = { width = W, height = Hgt, sx = W * cell, sy = Hgt * cell, dx = cell, dy = cell, elevations = z, area = 16 }
local model = F.Hydrology.Build(W, Hgt, z, 16)
F.Hydrology.Import(model, { { 45, 4000000, 0 } })

local deposits = { { amount = 1000, max_amount = 500000 } }
local bld_deep = building(18000, 18000)                 -- centre of the bowl
local bld_dry = building(1000, 1000)                    -- dry corner
local dome = building(18000, 18000, { Dome = true, ElectricityConsumer = true })
local track = building(18000, 18000, { TrackBase = true, ElectricityConsumer = true })
local hub = building(1000, 1000, { ElectricityConsumer = true })
local rover = modifiable(dusty(object(18000, 18000, { BaseRover = true, DroneBase = true }, { command = "Idle" }), 1000))
function rover:SetCommand(c) self.command = c end
local drone = dusty(object(18000, 18000, { Drone = true, DroneBase = true }, { battery = 100000, battery_max = 100000 }), 1000)
function drone:UseBattery(a) self.battery = self.battery - a end
function drone:GetParent() return nil end
local cable = dusty(object(1000, 1000, { DustGridElement = true }), 100000)
local labels_mods = {}
local colonists = {}
MainMap = { City = { labels = { Building = { bld_deep, bld_dry, dome, track, hub }, Rover = { rover },
    Drone = { drone }, Dome = { dome }, ShuttleHub = { hub }, Colonist = colonists },
    electricity = { { elements = { { building = cable } } } }, water = {} } }
function MainMap.City:SetLabelModifier(label, id, mod) labels_mods[label .. id] = mod end
function MainMap:MapGet(pt, radius, class) return class == "SubsurfaceDepositWater" and deposits or {} end
function MainMap:IsValid() return true end
local s = F.State
s.map, s.grid, s.model, s.enabled = MainMap, grid, model, true
local MODULES = { climate = "Climate", buildings = "Buildings", dust = "Dust", vehicles = "Vehicles",
    shuttles = "Shuttles", trains = "Trains", colonists = "Colonists", groundwater = "Groundwater",
    soil = "Soil", construction = "Construction" }
for key, module in pairs(MODULES) do
    local ok, reason = F[module].Available()
    check(ok == true, key .. " available with stubs: " .. tostring(reason))
    s.features[key] = true
end
F.Water.Snapshot()
local depth = F.Water.DepthAt(18000, 18000)
check(depth > 1400, "bowl centre is over a colonist's head: " .. depth)
check(F.Water.DepthAt(1000, 1000) == 0, "corner is dry")
check(F.Water.DepthAt(-1, 5) == 0 and F.Water.DepthAt(1e9, 5) == 0, "outside the grid is dry")

-- 1. Climate
near(F.Climate.EvaporationRate(), F.Config.EVAPORATION_MM_H * F.Config.EVAPORATION_BARREN_MULTIPLIER, "barren evaporation")
terraform.Atmosphere, terraform.Temperature = 100, 100
near(F.Climate.EvaporationRate(), F.Config.EVAPORATION_MM_H, "terraformed evaporation")
terraform.Atmosphere = 50
near(F.Climate.EvaporationRate(), F.Config.EVAPORATION_MM_H * (1 + 24 * 0.25), "scarcer parameter governs")
F.Config.ENABLE_CLIMATE_EVAPORATION = false
near(F.Climate.EvaporationRate(), F.Config.EVAPORATION_MM_H, "switch off restores base rate")
F.Config.ENABLE_CLIMATE_EVAPORATION = true

-- 2. Flooding
F.Buildings.Hourly(1, 0, false)
check(bld_deep.suspended == "Flooded", "deep building suspended")
check(bld_dry.suspended == false, "dry building untouched")
check(dome.suspended == false, "domes are sealed")
check(track.suspended == false, "tracks are never suspended")
check(NotWorkingWarning.Flooded and NotWorkingWarning.Flooded.short, "warning text registered")
bld_dry.suspended = "SuspendedDustStorm"
F.Buildings.Restore()
check(bld_deep.suspended == false, "restore lifts flood suspension")
check(bld_dry.suspended == "SuspendedDustStorm", "restore keeps other reasons")
bld_deep.suspended = "SuspendedDustStorm"
F.Buildings.Hourly(1, 0, false)
check(bld_deep.suspended == "SuspendedDustStorm", "flooding never overrides another reason")
bld_deep.suspended, bld_dry.suspended = false, false
F.Config.ENABLE_BUILDING_FLOODING = false
F.Buildings.Hourly(1, 0, false)
check(bld_deep.suspended == false, "switch off: no suspension")
F.Config.ENABLE_BUILDING_FLOODING = true

-- 5a. Dust washing reaches every dust-collecting object in the open.
bld_dry.accumulated_maintenance_points, drone.dust, rover.dust, cable.dust = 50000, 500, 500, 50000
local wash = const.MaxMaintenance * F.Config.RAIN_DUST_WASH_PER_HOUR
F.Dust.Hourly(1, 15)
near(bld_dry.accumulated_maintenance_points, 50000 - wash, "rain washes buildings")
check(drone.dust == 0 and rover.dust == 0, "rain washes drones and rovers")
near(cable.dust, 50000 - wash, "rain washes cables")
dome.parent_dome = false
local inside = building(1000, 1000); inside.parent_dome = dome; inside.accumulated_maintenance_points = 100
MainMap.City.labels.Building[#MainMap.City.labels.Building + 1] = inside
F.Dust.Hourly(1, 15)
check(inside.accumulated_maintenance_points == 100, "rain does not reach inside closed domes")
table.remove(MainMap.City.labels.Building)
-- 5b. Toxic corrosion
bld_dry.accumulated_maintenance_points = 0
F.Buildings.UpdateCorrosion(1, 15, true)
near(bld_dry.accumulated_maintenance_points, 100000 * F.Config.RAIN_CORROSION_PER_HOUR, "toxic rain corrodes")
F.Buildings.UpdateCorrosion(1, 15, false)
near(bld_dry.accumulated_maintenance_points, 100000 * F.Config.RAIN_CORROSION_PER_HOUR, "fresh rain does not corrode")

-- 3. Groundwater
F.Groundwater.Collect({ { seed = 45, volume = 5000, mass = 1000 }, { seed = 45, volume = 1000, mass = 0 } })
near(s.recharge[45], 5000, "only fresh seepage recharges")
F.Groundwater.Hourly()
check(deposits[1].amount == 1000 + 5000, "deposit raised by litres / unit * scale")
check(next(s.recharge) == nil, "pending recharge consumed")
deposits[1].amount = 499000
F.Groundwater.Collect({ { seed = 45, volume = 5000000, mass = 0 } })
F.Groundwater.Hourly()
check(deposits[1].amount == 500000, "recharge capped at max_amount")

-- 6. Rovers, drones
s.last_nominal_rate = 15
F.Vehicles.Tick()
check(rover.mods.FloodDeepWater == -F.Config.ROVER_SLOW_PERCENT, "rover slowed in deep water")
check(labels_mods.DroneFloodRainDrones and labels_mods.DroneFloodRainDrones.percent == -F.Config.DRONE_RAIN_SLOW_PERCENT,
    "drones slowed by rain")
check(drone.battery < 100000, "drone battery drains in deep water")
rolls = 0
F.Vehicles.Hourly(1, 15, true)
check(rover.command == "Malfunction", "submerged rover breaks down")
check(drone.dust > 0, "toxic rain leaves grime on drones")
F.Vehicles.Restore()
check(rover.mods.FloodDeepWater == nil and labels_mods.DroneFloodRainDrones == nil, "vehicle restore removes modifiers")
rover.command = "Idle"
rolls = 99
F.Vehicles.Tick(); F.Vehicles.Hourly(1, 0, false)
check(rover.command == "Idle", "failed roll leaves rover running")

-- Shuttles
s.last_nominal_rate = 40
F.Shuttles.Tick()
check(labels_mods.CargoShuttleFloodRainShuttles ~= nil, "shuttles slowed by rain")
check(hub.suspended == "FloodStormGrounded", "heavy storm grounds shuttle hubs")
s.last_nominal_rate = 5
F.Shuttles.Tick()
check(hub.suspended == false, "light rain clears hubs")
F.Shuttles.Restore()
check(labels_mods.CargoShuttleFloodRainShuttles == nil, "shuttle restore removes slowdown")

-- Trains
local train = object(1000, 1000, {})
local wet_rail, dry_rail = object(18000, 18000, {}), object(1000, 1000, {})
check(select(1, Train.GetNominalMoveSpeed(train, dry_rail)) == 1000, "dry rail: vanilla speed")
local slow, turn = Train.GetNominalMoveSpeed(train, wet_rail)
check(slow == 1000 * F.Config.TRAIN_DEEP_SPEED_PERCENT / 100 and turn == 3000 * F.Config.TRAIN_DEEP_SPEED_PERCENT / 100,
    "deep rail: crawl speed")
s.enabled = false
check(Train.GetNominalMoveSpeed(train, wet_rail) == 1000, "disabled: vanilla pass-through")
s.enabled = true

-- Colonists
local function colonist(x, y)
    local c = object(x, y, { Colonist = true }, { health = 100000, sanity = 100000 })
    function c:IsDying() return false end
    function c:ChangeHealth(a, reason) self.health = self.health + a; self.health_reason = reason end
    function c:ChangeSanity(a, reason) self.sanity = self.sanity + a; self.sanity_reason = reason end
    return c
end
local wader, walker, indoor = colonist(18000, 18000), colonist(1000, 1000), colonist(1000, 1000)
indoor.holder = bld_dry
colonists[1], colonists[2], colonists[3] = wader, walker, indoor
s.last_nominal_rate, breathable = 15, false
for _ = 1, 30 do F.Colonists.Tick() end
F.Colonists.Hourly(1, 15, true)
check(walker.sanity < 100000 and walker.health == 100000, "suited colonist: toxic rain stresses only")
check(wader.health < 100000 and wader.health_reason == "FloodDrowning", "water over the head harms")
check(indoor.sanity == 100000 and indoor.health == 100000, "indoors: no exposure")
walker.health, walker.sanity = 100000, 100000
breathable = true
for _ = 1, 30 do F.Colonists.Tick() end
F.Colonists.Hourly(1, 15, true)
check(walker.health < 100000, "breathable air: toxic rain harms skin")
walker.sanity = 100000
for _ = 1, 30 do F.Colonists.Tick() end
F.Colonists.Hourly(1, 15, false)
check(walker.sanity > 100000 and walker.sanity_reason == "FloodFreshRain", "fresh rain under open sky cheers")
check(ColonistStatReasons.FloodDrowning and DeathReasons.FloodDrowning, "stat and death reasons registered")
colonists[1], colonists[2], colonists[3] = nil, nil, nil

-- 4 and 7. Soil
F.Soil.Hourly(1)
check(soil_changed > 0 and soil["1:1"] and soil["1:1"] > 50, "fresh water improves soil: " .. tostring(soil["1:1"]))
soil = {}
F.Hydrology.Import(model, { { 45, 0, 4000000 } }) -- make the lake fully toxic tracer-wise
F.Water.Snapshot()
F.Soil.Hourly(1)
check(soil["1:1"] < 50, "toxic water degrades soil: " .. tostring(soil["1:1"]))
soil = { ["1:1"] = 0.2 }
F.Soil.Hourly(10)
check(soil["1:1"] >= 0, "soil never below 0")
F.Config.ENABLE_FRESH_SOIL, F.Config.ENABLE_TOXIC_SOIL = false, false
soil, soil_changed = {}, 0
F.Soil.Hourly(1)
check(soil_changed == 0, "both soil switches off: no writes")
F.Config.ENABLE_FRESH_SOIL, F.Config.ENABLE_TOXIC_SOIL = true, true

-- Dry residue degrades soil after the lake evaporates.
F.Hydrology.Step(model, 100000, 0, false, 10, 0, 1)
check(F.Hydrology.Total(model) == 0, "lake dried")
check(#F.Hydrology.Residues(model) > 0, "residue left")
F.Water.Snapshot()
soil = {}
F.Soil.Hourly(1)
check(soil["1:1"] and soil["1:1"] < 50, "residue degrades soil")

-- 6. Construction
local controller = { template_obj = { accumulate_maintenance_points = true }, construction_statuses = {},
    template_obj_points = { point(0, 0) }, cursor_obj = object(18000, 18000, {}) }
function controller:GetMap() return MainMap end
F.Hydrology.Import(model, { { 45, 4000000, 0 } })
F.Water.Snapshot()
ConstructionController.FinalizeStatusGathering(controller, {})
check(controller.construction_statuses[1] == ConstructionStatus.FloodSubmerged, "deep site blocked")
check(ConstructionStatus.FloodSubmerged.type == "error" and ConstructionStatus.FloodWet.type == "problem", "status types")
check(finalized == 1, "vanilla finalize still runs")
controller.construction_statuses = {}
s.enabled = false
ConstructionController.FinalizeStatusGathering(controller, {})
check(#controller.construction_statuses == 0, "disabled: vanilla pass-through")

-- Lifecycle smoke test: a real tick cycle over the effect hooks with stubbed rendering.
local game_time = 0
function GameTime() return game_time end
function IsValidThread() return false end
function CurrentThread() return nil end
function DeleteThread() end
g_RainDisaster = false
terrain = { GetMapSize = function() return grid.sx, grid.sy end,
    GetHeight = function(_, pt) local x, y = pt:xy(); return z[F.Terrain.Cell(grid, x, y)] * guim / 1000 end }
function RGB() return 0 end
function AddRects(a) return a end
function ApplyAllWaterObjects() end
function DoneObject(o) o.valid = false end
function PlaceObject()
    local o = { invalidation_box = {} }
    for _, m in ipairs({ "ClearEnumFlags", "SetPos", "UpdateGridAndVisuals", "Setwaterpreset",
        "SetColorModifier", "SetProperty", "WaterPropChanged" }) do o[m] = function() end end
    return o
end
function MainMap:MapGet() return {} end
const.efVisible = 1
F.Config.ENABLE_TEST_UI = false
s.enabled, s.model, s.grid, s.dirty, s.features = true, false, false, true, {}
for key, module in pairs(MODULES) do s.features[key] = F[module].Available() == true end
for _ = 1, 40 do
    F.Lifecycle.Tick()
    game_time = game_time + F.Config.TICK_MS
end
check(s.model and s.last_effects and s.ticks == 40, "lifecycle ticks with all effects")
F.Lifecycle.SaveStart()
check(s.saving and labels_mods.DroneFloodRainDrones == nil, "save drops transient modifiers")
F.Lifecycle.SaveDone()
F.Lifecycle.Disable()
check(not s.enabled and bld_deep.suspended == false, "disable restores object state")

print = real_print
print("PASS: " .. count .. " effect assertions")
