-- Temporary test control (the panel's Cold Wave button). On starts a vanilla
-- cold wave (StartColdWave(settings), ColdWave.lua:101-148, in a game-time
-- thread as CheatColdWave does, :319-334) with the map's cold-wave preset, and
-- starts the next one whenever it ends while the button stays on. Off ends it
-- with vanilla StopColdWave (:358). The waves are timed, not endless: if Flood
-- is removed while one runs, it ends on its own after its vanilla duration.
-- It is a real cold wave: buildings and colonists react as in vanilla, and the
-- heat grid cools gradually; Flood's ice follows the local heat (fl_ice.lua). A
-- natural cold wave is never replaced or stopped. Ownership lives in a map
-- variable, so Off still works after a save and load; disabling Flood stops
-- the cold wave it started.
local F = Flood
local CW = {}
F.ColdWave = CW

-- MapVar stores false for a false default, so test for registration with nil.
if MapVarValues.fl_test_cold_wave == nil then MapVar("fl_test_cold_wave", false) end

function CW.Available()
    for _, name in ipairs({ "StartColdWave", "StopColdWave" }) do
        if type(rawget(_G, name)) ~= "function" then return false, name .. " unavailable" end
    end
    if not Presets.MapSettings or not Presets.MapSettings.ColdWave then return false, "Cold wave presets unavailable" end
    return true
end

-- Follows ownership: a press while paused takes effect on unpause, and a wave
-- ended by something else (e.g. the ColdWaveStop terraforming threshold) is
-- cleared by the next press.
function CW.Active()
    local map = F.State.map
    return map ~= nil and map ~= false and map.fl_test_cold_wave == true
end

local function preset(map)
    local presets = Presets.MapSettings.ColdWave
    return presets[map.mapdata.MapSettings_ColdWave] or presets.ColdWave_VeryLow
end

-- Starts or stops the test cold wave. Returns true, or false and the reason.
function CW.Toggle()
    local s = F.State
    local ok, err = CW.Available()
    if not ok then return false, err end
    if not s.map then return false, "No map" end
    if CW.Active() then return CW.Stop() end
    if rawget(_G, "g_ColdWave") then return false, "A cold wave is already under way" end
    local settings = preset(s.map)
    if not settings then return false, "No cold wave preset for this map" end
    s.map.fl_test_cold_wave = true
    CW.thread = s.map:CreateGameTimeThread(StartColdWave, settings)
    F.Log("ColdWave", "test cold wave started", { preset = settings.id })
    return true
end

-- Every simulation tick: while the button is on and no cold wave runs (the last
-- one ran its course, or after a load), start the next one.
function CW.Keep()
    local s = F.State
    if not CW.Active() or not CW.Available() then return end
    if rawget(_G, "g_ColdWave") or (CW.thread and IsValidThread(CW.thread)) then return end
    local settings = preset(s.map)
    if not settings then return end
    CW.thread = s.map:CreateGameTimeThread(StartColdWave, settings)
    F.Log("ColdWave", "test cold wave renewed", { preset = settings.id })
end

-- Ends the cold wave this control started. Idempotent; never touches a
-- natural cold wave.
function CW.Stop()
    local map = F.State.map
    if not map or map.fl_test_cold_wave ~= true then return true end
    map.fl_test_cold_wave = false
    CW.thread = false
    if rawget(_G, "g_ColdWave") then StopColdWave() end
    F.Log("ColdWave", "test cold wave stopped", {})
    return true
end
