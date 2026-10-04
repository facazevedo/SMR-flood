-- Real storms, without CheatRainsDisaster's unrelated CheatStopDisaster call.
local F = Flood
local R = {}
F.Rain = R
local preset_suffix = { "VeryLow", "Low", "High" }

-- Returns the hydrology rain rate (mm/h, including the test-storm preview
-- multiplier), whether it is toxic, and the nominal storm rate. Gameplay effects
-- use the nominal rate so the preview only speeds up filling.
function R.Read()
    local kind = rawget(_G, "g_RainDisaster")
    if kind ~= "normal" and kind ~= "toxic" then return 0, false, 0 end
    local data = RainsDisasterThreads[kind]
    local own = data and F.State.rain_thread and data.main_thread == F.State.rain_thread
    local settings = data and Presets.MapSettings.RainsDisaster[data.id]
    local strength = own and F.State.rain_strength or settings and settings.strength
    if type(strength) ~= "number" or not F.Config.RAIN_MM_H[strength] then
        error("active " .. kind .. " rain has no supported strength (RainsDisasterThreads.id)")
    end
    local nominal = F.Config.RAIN_MM_H[strength]
    local rate = nominal
    if own and F.State.fast_preview then rate = rate * F.Config.TEST_RAIN_MULTIPLIER end
    return rate, kind == "toxic", nominal
end

function R.Owned()
    local s = F.State
    local data = RainsDisasterThreads and RainsDisasterThreads[s.rain_type]
    return data and s.rain_thread and data.main_thread == s.rain_thread
end

-- A test storm ends on its own after its rolled duration; forget the dead thread.
function R.Sync()
    local s = F.State
    if s.rain_thread and not IsValidThread(s.rain_thread) then
        s.rain_thread, s.rain_strength = false, 0
        F.Log("Rain", "test rain ended by itself", {})
    end
end

function R.StopOwned()
    local s = F.State
    if R.Owned() then StopRainsDisaster(s.rain_type)
    elseif s.rain_thread and IsValidThread(s.rain_thread) then
        -- A pending start has not called RainProcedure yet.
        DeleteThread(s.rain_thread)
    end
    s.rain_thread, s.rain_strength = false, 0
    F.Log("Rain", "test rain stopped", {})
end

function R.Start(strength)
    local s = F.State
    if not s.enabled or F.Config.ENABLE_TEST_UI ~= true then return false, "Flood test controls disabled" end
    if CurrentMap ~= MainMap or not s.model then return false, "Wait for surface terrain scan" end
    if not preset_suffix[strength] then return false, "Unsupported storm strength" end
    R.StopOwned()
    if IsDisasterActive() then return false, "Another disaster is active; wait until it ends" end
    local id = (s.rain_type == "toxic" and "Toxic_" or "Normal_") .. preset_suffix[strength]
    local preset = Presets.MapSettings.RainsDisaster[id]
    if not preset then return false, "Missing rain preset: " .. id end
    if not RainsDisasterThreads[s.rain_type] then return false, "Rain system is unavailable on this map" end
    s.rain_strength = strength
    s.rain_thread = CreateGameTimeThread(RainProcedure, preset, "from cheat")
    F.Log("Rain", "test rain started", { preset = id, strength = strength,
        mm_h = F.Config.RAIN_MM_H[strength], preview_multiplier = s.fast_preview and F.Config.TEST_RAIN_MULTIPLIER or 1 })
    return true
end

function R.Toggle(strength)
    if F.State.rain_strength == strength and F.State.rain_thread then R.StopOwned(); return true end
    return R.Start(strength)
end

function R.ToggleType()
    local s = F.State
    local strength = s.rain_strength
    R.StopOwned()
    s.rain_type = s.rain_type == "normal" and "toxic" or "normal"
    if strength > 0 then return R.Start(strength) end
    return true
end
