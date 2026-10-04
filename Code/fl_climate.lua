-- Effect 1: evaporation follows the terraformed climate. Below the triple point
-- liquid water boils or sublimates, so thin, cold air empties puddles fast.
-- GetTerraformParamPct (Lua/Terraforming.lua:219) returns an integer 0..100.
local F = Flood
local C = {}
F.Climate = C

function C.Available()
    if type(GetTerraformParamPct) ~= "function" then return false, "GetTerraformParamPct unavailable" end
    return true
end

function C.Active()
    return F.Config.ENABLE_CLIMATE_EVAPORATION == true and F.State.features.climate == true
end

-- Habitability 0..1 is the scarcer of atmosphere and temperature.
function C.Habitability()
    local atmosphere = GetTerraformParamPct("Atmosphere")
    local temperature = GetTerraformParamPct("Temperature")
    return math.max(0, math.min(1, math.min(atmosphere, temperature) * 1.0 / 100)), atmosphere, temperature
end

function C.EvaporationRate()
    local cfg = F.Config
    if not C.Active() then return cfg.EVAPORATION_MM_H end
    local h = C.Habitability()
    local multiplier = 1 + (cfg.EVAPORATION_BARREN_MULTIPLIER - 1) * (1 - h) * (1 - h)
    return cfg.EVAPORATION_MM_H * multiplier
end
