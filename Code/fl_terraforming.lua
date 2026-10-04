-- Temporary test control (the panel's Terraformed button). On: every vanilla
-- terraforming parameter is set to 100 % through SetTerraformParamPct
-- (Terraforming.lua:182-212), which updates the boosts and fires the threshold
-- messages exactly as real progress does (liquid water, breathable air, rain
-- types, cold waves and dust storms stopping...). Off: each parameter goes back
-- to the raw value it had when the button was switched on, through the same
-- function, so the thresholds roll back too (with their vanilla hysteresis).
-- The saved values live in a map variable, so Off still works after a save and
-- load; disabling Flood rolls back as well (Flood owns the change).
local F = Flood
local TF = {}
F.Terraforming = TF

-- MapVar stores false for a false default, so test for registration with nil.
if MapVarValues.fl_test_terraform == nil then MapVar("fl_test_terraform", false) end

function TF.Available()
    if type(rawget(_G, "SetTerraformParam")) ~= "function" or type(rawget(_G, "SetTerraformParamPct")) ~= "function" then
        return false, "SetTerraformParam unavailable"
    end
    if type(rawget(_G, "Terraforming")) ~= "table" or type(rawget(_G, "TerraformingParamDefs")) ~= "table" then
        return false, "Terraforming parameters unavailable"
    end
    return true
end

local function saved_table()
    local map = F.State.map
    return map and map.fl_test_terraform or false
end

function TF.Active()
    return saved_table() ~= false
end

-- Switches between full terraforming and the conditions saved when it was
-- switched on. Returns true, or false and the reason.
function TF.Toggle()
    local s = F.State
    local ok, err = TF.Available()
    if not ok then return false, err end
    if IsGameRuleActive("NoTerraforming") then return false, "The No Terraforming game rule is active" end
    if not s.map then return false, "No map" end
    if TF.Active() then return TF.Restore() end
    local saved = {}
    for name in pairs(TerraformingParamDefs) do
        saved[name] = Terraforming[name] or 0
        SetTerraformParamPct(name, 100)
    end
    s.map.fl_test_terraform = saved
    F.Log("Terraforming", "test terraforming on", saved)
    return true
end

-- Rolls back to the saved conditions. Idempotent.
function TF.Restore()
    local s = F.State
    local saved = saved_table()
    if not saved then return true end
    if TF.Available() and not IsGameRuleActive("NoTerraforming") then
        for name, value in pairs(saved) do SetTerraformParam(name, value) end
    end
    s.map.fl_test_terraform = false
    F.Log("Terraforming", "test terraforming off: initial conditions restored", saved)
    return true
end
