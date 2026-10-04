-- Trains. Vanilla rain has no effect on them.
-- Trains slow down over flooded rails: water hides the track, washes ballast and
-- risks shorting signals, so trains crawl, much as vanilla slows them on frozen track.
-- Train speed is not a modifiable property; it is recomputed for every track element by
-- Train:GetNominalMoveSpeed(element) (Train.lua:535, 593-614), which this wraps.
-- Flooded stations are Buildings and are suspended by fl_buildings.lua, which stops
-- new trips there (TrainTransport.lua:446) without stranding trains.
local F = Flood
local TR = {}
F.Trains = TR

function TR.Available()
    if type(rawget(_G, "Train")) ~= "table" or type(Train.GetNominalMoveSpeed) ~= "function" then
        return false, "Train.GetNominalMoveSpeed unavailable"
    end
    return true
end

-- Speed factor at a track element (or the train itself), 1 when unaffected.
function TR.SpeedFactor(train, element)
    local s, cfg = F.State, F.Config
    if not s.enabled or cfg.ENABLE_TRAIN_EFFECTS ~= true or s.features.trains ~= true or not s.wet then return 1 end
    local at = IsValid(element) and element or train
    if not IsValid(at) or at:GetMap() ~= s.map then return 1 end
    local depth = F.Water.DepthAt(at:GetPos():xy())
    if depth >= cfg.TRAIN_DEEP_DEPTH_MM then return cfg.TRAIN_DEEP_SPEED_PERCENT * 1.0 / 100 end
    if depth >= cfg.TRAIN_WET_DEPTH_MM then return cfg.TRAIN_WET_SPEED_PERCENT * 1.0 / 100 end
    return 1
end

-- Installed once at load (subclasses copy methods when classes are built) and a
-- pass-through whenever Flood or this switch is off. The original is kept once so
-- reloading the mod never wraps the wrapper.
if TR.Available() then
    local vanilla_speed = rawget(Train, "FloodVanillaGetNominalMoveSpeed") or Train.GetNominalMoveSpeed
    Train.FloodVanillaGetNominalMoveSpeed = vanilla_speed
    function Train:GetNominalMoveSpeed(element, ...)
        local speed, turn_anim_speed = vanilla_speed(self, element, ...)
        local factor = TR.SpeedFactor(self, element)
        if factor < 1 then
            speed = math.max(1, math.floor(speed * factor + 0.5))
            if turn_anim_speed then turn_anim_speed = math.max(1, math.floor(turn_anim_speed * factor + 0.5)) end
        end
        return speed, turn_anim_speed
    end
end
