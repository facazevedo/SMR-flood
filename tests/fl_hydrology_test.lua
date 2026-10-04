Flood = {}
dofile('Code/fl_hydrology.lua')
local H = Flood.Hydrology
local count = 0
local function near(a, b, message)
    assert(math.abs(a - b) < math.max(0.0001, math.abs(b) * 0.000001),
        (message or 'not equal') .. ': ' .. tostring(a) .. ' vs ' .. tostring(b))
    count = count + 1
end
local function bowl()
    return H.Build(5, 5, {1000,1000,1000,1000,1000,
        1000,200,200,200,1000, 1000,200,0,200,1000,
        1000,200,200,200,1000, 1000,1000,1000,1000,1000}, 1)
end
local m = bowl()
local sink = m.sinks[13]
H.Import(m, {{13, 100, 50}})
near(H.Total(m), 100, 'volume at floor')
near(H.Pools(m)[1].level, 100, 'depth scales with volume below shelves')
H.Step(m, 10, 0, false, 1, 0, 1)
local v, mass = H.Total(m)
near(v, 90, 'evaporation'); near(mass, 50, 'evaporation leaves dissolved tracer')
H.Step(m, 10, 0, false, 0, 1, 1)
v, mass = H.Total(m)
near(v, 80, 'infiltration'); near(mass, 50 * 80 / 90, 'infiltration removes tracer')
H.Import(m, {{13, 400, 0}})
near(H.Pools(m)[1].level, 200 + 280 / 9, 'shoreline expansion follows hypsometry')
local before, tracer = H.Total(m)
local restored = bowl()
H.Import(restored, H.Export(m))
near(H.Total(restored), before, 'save volume round trip')
local _, saved_mass = H.Total(restored)
near(saved_mass, tracer, 'save tracer round trip')
H.Step(m, 10000, 0, false, 1, 0, 1)
near(H.Total(m), 0, 'fully dry')
local _, residue = H.Total(m)
near(residue, tracer, 'dry residue persists')
restored = bowl(); H.Import(restored, H.Export(m))
local _, restored_residue = H.Total(restored)
near(restored_residue, residue, 'dry residue save')
H.Import(m, {{13, 100000, 0}})
near(H.Total(m), 7400, 'spill capacity')
assert(m.budget.outflow > 0, 'overflow leaves open edge')

local z = {1000,1000,1000,1000,1000,1000,1000,
    1000,0,0,200,100,100,1000,
    1000,1000,1000,1000,1000,1000,1000}
m = H.Build(7, 3, z, 1)
H.Import(m, {{9, 100, 100}})
near(H.Total(m), 100, 'independent basin')
assert(#H.Pools(m) == 1, 'does not fill disconnected neighbour')
H.Import(m, {{9, 350, 0}})
assert(#H.Pools(m) == 2, 'overflow enters neighbour before merging')
H.Import(m, {{9, 300, 0}})
assert(#H.Pools(m) == 1, 'full neighbours merge above saddle')
near(H.Pools(m)[1].level, 230, 'merged water surface')
local exported = H.Export(m)
restored = H.Build(7, 3, z, 1); H.Import(restored, exported)
near(H.Total(restored), H.Total(m), 'merged save volume')
H.Step(m, 35, 0, false, 1, 0, 1)
assert(#H.Pools(m) == 2, 'drying splits at saddle')
local _, after_split_mass = H.Total(m)
near(after_split_mass, 100, 'splitting conserves tracer')

-- Deterministic randomized terrain exercises nested saddles, flat ties,
-- open drainage, dry residues, saturation, and repeated save/load.
math.randomseed(41)
for case = 1, 100 do
    local heights = {}
    for i = 1, 81 do heights[i] = math.random(0, 8) * 100 end
    m = H.Build(9, 9, heights, 16)
    for tick = 1, 12 do
        local previous = H.Total(m)
        local b = m.budget
        local r, e, inf, out, ground = b.rain, b.evaporation, b.infiltration, b.outflow, b.ground
        H.Step(m, 0.5, tick % 3 == 0 and 0 or 200, tick % 2 == 0, 0.5, 1.5, 0.65)
        near(H.Total(m), previous + b.rain-r - (b.evaporation-e) - (b.infiltration-inf)
            - (b.outflow-out) - (b.ground-ground), 'conserved water budget')
        local seeped = 0
        for _, s in ipairs(m.seepage) do
            assert(s.mass >= 0 and s.mass <= s.volume + 0.0001, 'seepage tracer within volume')
            seeped = seeped + s.volume
        end
        near(seeped, b.infiltration - inf, 'seepage locations sum to infiltration')
        local wet, conc = H.WetCells(m)
        for i, depth in pairs(wet) do
            assert(depth > 0 and conc[i] >= 0 and conc[i] <= 1, 'wet cell concentration in range')
        end
    end
    local _, total_mass = H.Total(m)
    local pooled = 0
    for _, pool in ipairs(H.Pools(m)) do pooled = pooled + pool.mass end
    for _, r in ipairs(H.Residues(m)) do pooled = pooled + r.mass end
    near(pooled, total_mass, 'pools and residues account for all tracer')
    restored = H.Build(9, 9, heights, 16)
    H.Import(restored, H.Export(m))
    v, mass = H.Total(m)
    local rv, rm = H.Total(restored)
    near(rv, v, 'random terrain saved volume')
    near(rm, mass, 'random terrain saved mass')
end
-- WetCells must match the original per-cell ancestor walk exactly.
local function reference_wet(model)
    local wet, levels = {}, {}
    for _, pool in ipairs(H.Pools(model)) do
        local stack = { pool.node }
        while #stack > 0 do
            local n = model.nodes[table.remove(stack)]
            levels[n.id] = pool.level
            for _, id in ipairs(n.children) do stack[#stack + 1] = id end
        end
    end
    for i, sink in ipairs(model.sinks) do
        local id, level = sink, levels[sink]
        while id ~= 0 and level == nil do id = model.nodes[id].parent; level = levels[id] end
        if level and level > model.elevations[i] then wet[i] = level - model.elevations[i] end
    end
    return wet
end
math.randomseed(7)
for case = 1, 30 do
    local heights = {}
    for i = 1, 400 do heights[i] = math.random(0, 12) * 100 end
    m = H.Build(20, 20, heights, 16)
    H.Step(m, 1, case % 3 == 0 and 0 or 300, case % 2 == 0, 0.5, 1.5, 0.65)
    local expected, actual = reference_wet(m), H.WetCells(m)
    for i = 1, 400 do near(actual[i] or 0, expected[i] or 0, 'WetCells matches reference walk') end
end

-- Large dry map: the game's thread watchdog killed an O(cells x depth) walk on
-- a 384 x 384 grid (5 s). The memoized resolution must stay well under that.
do
    local w, heights = 384, {}
    for i = 1, w * w do heights[i] = math.random(0, 400) * 10 end
    local big = H.Build(w, w, heights, 256)
    local t0 = os.clock()
    H.WetCells(big)
    H.Step(big, 1 / 30, 0, false, 10, 1.5, 0.65)
    local seconds = os.clock() - t0
    assert(seconds < 1, 'dry WetCells + Step on 384x384 too slow: ' .. seconds .. ' s')
    count = count + 1
end
print('PASS: ' .. count .. ' hydrology assertions')
