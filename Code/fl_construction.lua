-- Effect 6: building on flooded ground. Deep water blocks placement (it would be
-- suspended on completion); shallow water is a warning.
-- ConstructionStatus is a plain table that vanilla files extend
-- (LandscapeConstructionController.lua:296). Types are only error/problem/info
-- (Construction.lua:84-88); an "error" first in the sorted list blocks Place().
local F = Flood
local C = {}
F.Construction = C

ConstructionStatus.FloodSubmerged = { type = "error", priority = 90,
    text = Untranslated("The site is under deep water. The building would stop working."),
    short = Untranslated("Flooded site") }
ConstructionStatus.FloodWet = { type = "problem", priority = 40,
    text = Untranslated("Standing water here wears the building and can flood it in heavy rain."),
    short = Untranslated("Wet ground") }

function C.Available()
    if type(ConstructionController) ~= "table" or type(ConstructionController.FinalizeStatusGathering) ~= "function" then
        return false, "ConstructionController.FinalizeStatusGathering unavailable"
    end
    return true
end

local function site_status(controller)
    local s, cfg = F.State, F.Config
    if not s.enabled or cfg.ENABLE_CONSTRUCTION_RULES ~= true or s.features.construction ~= true then return end
    if not s.wet or controller:GetMap() ~= s.map then return end
    if IsKindOf(controller, "LandscapeConstructionController") then return end
    local template, cursor = controller.template_obj, controller.cursor_obj
    if not template or not IsValid(cursor) or IsKindOfClasses(template, "Dome", "LandscapeLake") then return end
    local depth = F.Water.FootprintDepth(cursor:GetPos(), cursor:GetAngle(), controller.template_obj_points)
    if depth >= cfg.FLOOD_SUSPEND_DEPTH_MM then return ConstructionStatus.FloodSubmerged end
    if depth >= cfg.MIN_VISIBLE_DEPTH_MM and template.accumulate_maintenance_points then
        return ConstructionStatus.FloodWet
    end
end

-- FinalizeStatusGathering runs at the end of every normal status update (also for
-- Tunnel and other controllers that call the base) and never on vanilla's early
-- tutorial returns, so wrapping it leaves those paths untouched. Subclasses copy
-- methods when classes are built, so this is installed once at load and is a
-- pass-through whenever Flood is disabled or the switch is off.
-- The original is kept once so reloading the mod never wraps the wrapper.
if C.Available() then
    local vanilla_finalize = rawget(ConstructionController, "FloodVanillaFinalizeStatusGathering")
        or ConstructionController.FinalizeStatusGathering
    ConstructionController.FloodVanillaFinalizeStatusGathering = vanilla_finalize
    function ConstructionController:FinalizeStatusGathering(old_t, ...)
        local status = site_status(self)
        if status then self.construction_statuses[#self.construction_statuses + 1] = status end
        return vanilla_finalize(self, old_t, ...)
    end
end
