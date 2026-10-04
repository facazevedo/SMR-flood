-- Effect 3: fresh water soaking in under a pool recharges nearby water deposits.
-- SubsurfaceDeposit keeps a plain 'amount' capped by 'max_amount' (SubsurfaceDeposit.lua:196-225);
-- the vanilla refill (CheatRefill, :252) writes amount directly. A depleted deposit is
-- destroyed by the game, so only deposits that still exist can be recharged.
local F = Flood
local G = {}
F.Groundwater = G

function G.Available()
    if not g_Classes.SubsurfaceDepositWater then return false, "SubsurfaceDepositWater class unavailable" end
    if type(const.ResourceScale) ~= "number" then return false, "const.ResourceScale unavailable" end
    return true
end

local function active()
    return F.Config.ENABLE_GROUNDWATER_RECHARGE == true and F.State.features.groundwater == true
end

-- Called after every hydrology step: model.seepage only holds that step.
-- Toxic tracer is the contaminated share and does not recharge.
function G.Collect(seepage)
    if not active() then return end
    local pending = F.State.recharge
    for _, s in ipairs(seepage) do
        local fresh = s.volume - s.mass
        if fresh > 0 then pending[s.seed] = (pending[s.seed] or 0) + fresh end
    end
end

function G.Hourly()
    local s = F.State
    if not active() or not s.grid or not s.map then s.recharge = {}; return end
    local cfg = F.Config
    local radius = cfg.RECHARGE_RADIUS_M * guim
    local per_litre = const.ResourceScale * 1.0 / cfg.RECHARGE_LITRES_PER_UNIT
    local applied, recharged, lost, carried = 0, 0, 0, 0
    local remaining = {}
    for seed, litres in pairs(s.recharge) do
        local x, y = F.Terrain.Position(s.grid, seed)
        local deposits = s.map:MapGet(point(x, y), radius, "SubsurfaceDepositWater") or {}
        if #deposits == 0 then
            lost = lost + litres -- no aquifer within reach; the water stays in the ground
        else
            local share = math.floor(litres * per_litre / #deposits)
            if share > 0 then
                for _, deposit in ipairs(deposits) do
                    local before = deposit.amount
                    deposit.amount = math.min(deposit.max_amount, before + share)
                    if deposit.amount > before then recharged = recharged + 1 end
                end
                applied = applied + litres
            else
                remaining[seed] = litres -- under one resource step; carry to the next pass
                carried = carried + 1
            end
        end
    end
    s.recharge = remaining
    if cfg.DEBUG_EFFECTS == true then
        F.Log("Groundwater", "recharge pass", { litres_applied = applied, litres_without_deposit = lost,
            deposits_raised = recharged, seeds_carried = carried })
    end
end
