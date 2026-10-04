-- Colonist exposure. Vanilla rain has no effect on people (no ChangeHealth/Sanity
-- with g_RainDisaster anywhere). A colonist is exposed when standing in the open:
-- outside any dome, or inside an opened dome (IsObjInOpenAir, Dome.lua:461), and
-- not inside a building, shuttle, train or passage (IsColonistExposedToDisaster,
-- Colonist.lua:1275). While the air is unbreathable the colonist wears a sealed
-- suit (Colonist:SetOutsideVisuals): toxic rain then only stresses them. Deep water
-- tires and frightens waders, and water over their head can drown them.
-- Exposure is sampled every tick and applied hourly with ChangeHealth/ChangeSanity
-- (const.Scale.Stat per point), with reasons shown via ColonistStatReasons.
local F = Flood
local P = {}
F.Colonists = P

local REASONS = {
    FloodToxicRain = "<red>Exposed to toxic rain<right><amount></red>",
    FloodToxicWater = "<red>Waded through toxic water<right><amount></red>",
    FloodWading = "<red>Waded through deep water<right><amount></red>",
    FloodFreshRain = "<green>Walked in the rain<right><amount></green>",
    FloodDrowning = "<red>Struggled in water over their head<right><amount></red>",
}
for id, text in pairs(REASONS) do ColonistStatReasons[id] = Untranslated(text) end
DeathReasons.FloodToxicRain = Untranslated("Toxic rain exposure")
DeathReasons.FloodToxicWater = Untranslated("Toxic water exposure")
DeathReasons.FloodDrowning = Untranslated("Drowned")

-- Exposure-hours per colonist since the last hourly pass; weak keys drop dead colonists.
local exposure = setmetatable({}, { __mode = "k" })

function P.Available()
    for _, name in ipairs({ "IsObjInOpenAir", "GetAtmosphereBreathable" }) do
        if type(rawget(_G, name)) ~= "function" then return false, name .. " unavailable" end
    end
    if type(const.Scale) ~= "table" or type(const.Scale.Stat) ~= "number" then return false, "const.Scale.Stat unavailable" end
    return true
end

local function active()
    return F.Config.ENABLE_COLONIST_EFFECTS == true and F.State.features.colonists == true
end

local function exposed(c)
    return IsValid(c) and not c:IsDying() and not IsValid(c.holder) and not IsValid(c.shuttle)
        and not IsValid(c.traversing_passage) and not IsValid(c.passage_hub) and c:IsValidPos()
        and IsObjInOpenAir(c)
end

function P.Tick()
    if not active() then return end
    local s = F.State
    local hours = F.Config.TICK_MS * 1.0 / const.HourDuration
    local raining = (s.last_nominal_rate or 0) > 0
    local city = s.map and s.map.City
    for _, c in ipairs(city and city.labels.Colonist or {}) do
        if exposed(c) then
            local depth, concentration = F.Water.DepthAt(c:GetPos():xy())
            if raining or depth >= F.Config.MIN_VISIBLE_DEPTH_MM then
                local e = exposure[c]
                if not e then e = { rain = 0, wade = 0, toxic_water = 0, deep = 0 }; exposure[c] = e end
                if raining then e.rain = e.rain + hours end
                if depth >= F.Config.WADING_DEPTH_MM then e.wade = e.wade + hours end
                if depth >= F.Config.DROWNING_DEPTH_MM then e.deep = e.deep + hours end
                if depth >= F.Config.MIN_VISIBLE_DEPTH_MM then e.toxic_water = e.toxic_water + hours * concentration end
            end
        end
    end
end

function P.Hourly(_, rain_mm_h, toxic)
    if not active() then for c in pairs(exposure) do exposure[c] = nil end; return end
    local cfg = F.Config
    local stat = const.Scale.Stat
    local breathable = GetAtmosphereBreathable(F.State.map)
    -- Rain effects scale with intensity relative to moderate rain.
    local intensity = rain_mm_h * 1.0 / cfg.RAIN_REFERENCE_MM_H
    local harmed, cheered, waded = 0, 0, 0
    for c, e in pairs(exposure) do
        if IsValid(c) and not c:IsDying() then
            if e.rain > 0 and toxic then
                c:ChangeSanity(-math.floor(cfg.TOXIC_RAIN_SANITY_PER_HOUR * e.rain * intensity * stat), "FloodToxicRain")
                if breathable then
                    c:ChangeHealth(-math.floor(cfg.TOXIC_RAIN_HEALTH_PER_HOUR * e.rain * intensity * stat), "FloodToxicRain")
                end
                harmed = harmed + 1
            elseif e.rain > 0 and breathable and rain_mm_h > 0 then
                c:ChangeSanity(math.floor(cfg.FRESH_RAIN_SANITY_PER_HOUR * e.rain * stat), "FloodFreshRain")
                cheered = cheered + 1
            end
            -- Skin contact needs breathable air; a suit seals the wearer otherwise.
            if e.toxic_water > 0 and breathable and IsValid(c) and not c:IsDying() then
                c:ChangeHealth(-math.floor(cfg.TOXIC_WATER_HEALTH_PER_HOUR * e.toxic_water * stat), "FloodToxicWater")
                harmed = harmed + 1
            end
            if e.wade > 0 and IsValid(c) and not c:IsDying() then
                c:ChangeSanity(-math.floor(cfg.WADING_SANITY_PER_HOUR * e.wade * stat), "FloodWading")
                waded = waded + 1
            end
            -- Over their head, suited or not, a colonist struggles to stay afloat.
            if e.deep > 0 and IsValid(c) and not c:IsDying() then
                c:ChangeHealth(-math.floor(cfg.DROWNING_HEALTH_PER_HOUR * e.deep * stat), "FloodDrowning")
                harmed = harmed + 1
            end
        end
        exposure[c] = nil
    end
    if cfg.DEBUG_EFFECTS == true then
        F.Log("Colonists", "exposure pass", { harmed = harmed, cheered = cheered, waded = waded,
            breathable = breathable, toxic = toxic, rain_mm_h = rain_mm_h })
    end
end

-- Stat changes are history, like vanilla disaster damage; only pending exposure is dropped.
function P.Restore()
    for c in pairs(exposure) do exposure[c] = nil end
end
