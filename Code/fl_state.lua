-- Persistent data belongs to the surface map. Everything else is transient.
local F = Flood
-- MapVar stores false for a false default, so test for registration with nil;
-- a second MapVar call on mod reload would assert "already registered".
if MapVarValues.fl_saved == nil then MapVar("fl_saved", false) end
F.State = { enabled = false, thread = false, map = false, model = false,
    markers = {}, retiring = {}, ui = false, building = false, saving = false, dirty = true,
    status = "Waiting for surface map", rain_type = "normal", rain_strength = 0,
    rain_thread = false, fast_preview = true, error = false,
    -- Effect state, rebuilt from the model and game objects; never saved.
    wet = false, wet_concentration = false, ticks = 0, last_effects = false,
    recharge = {}, features = {}, evaporation_mm_h = 0, flooded_buildings = 0 }

function F.SetError(scope, message)
    F.State.error = tostring(message)
    F.State.status = tostring(message)
    F.Log(scope, "operation failed", { error = message })
end

