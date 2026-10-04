-- Engine-independent, volume-conserving depression hierarchy.
-- Elevation: mm. Area: m^2. Water and dissolved tracer: litres (mm * m^2).
-- Ascending union-find records real saddles. Children fill independently,
-- spill into siblings, then merge; open map edges are outlets. No terrain edits.
-- Floating point operands are explicit: the game VM divides integer operands
-- differently from stock Lua. No external libraries are required.
local H = {}
Flood.Hydrology = H
local function div(a, b) return a * 1.0 / b end
local function clamp(v, lo, hi) return math.max(lo, math.min(v, hi)) end

local function neighbours(i, w, h, visit)
    local x = (i - 1) % w
    if x > 0 then visit(i - 1) end
    if x < w - 1 then visit(i + 1) end
    if i > w then visit(i - w) end
    if i <= w * (h - 1) then visit(i + w) end
end

function H.Build(width, height, elevations, cell_area, yield_fn)
    assert(width >= 3 and height >= 3 and #elevations == width * height, "invalid terrain grid")
    assert(cell_area > 0, "invalid cell area")
    local model = { width = width, height = height, elevations = elevations,
        area = cell_area, nodes = {}, sinks = {}, roots = {}, outlet_cells = 0, seepage = {},
        budget = { rain = 0, evaporation = 0, infiltration = 0, outflow = 0, ground = 0 } }
    local nodes, sinks = model.nodes, model.sinks
    local order, uf, component = {}, { [0] = 0 }, { [0] = 0 }
    for i = 1, #elevations do order[i] = i end
    table.sort(order, function(a, b)
        return elevations[a] < elevations[b] or (elevations[a] == elevations[b] and a < b)
    end)
    local function root(i)
        local r = i
        while uf[r] ~= r do r = uf[r] end
        while uf[i] ~= i do local p = uf[i]; uf[i] = r; i = p end
        return r
    end
    local function make_node(z, seed, children)
        local n = { id = #nodes + 1, base = z, seed = seed, children = children or {},
            heights = {}, prefix = {}, initial_count = 0, count = 0, sum = 0,
            water = 0, mass = 0, total = 0, total_mass = 0, catchment = 0 }
        for _, id in ipairs(n.children) do
            local c = nodes[id]
            c.parent = n.id
            n.count = n.count + c.count
            n.sum = n.sum + c.sum
            if elevations[c.seed] < elevations[n.seed] then n.seed = c.seed end
        end
        n.initial_count = n.count
        nodes[n.id] = n
        return n.id
    end
    local function close_node(id, spill)
        local n = nodes[id]
        n.spill = spill
        n.capacity = math.max(0, (spill * n.count - n.sum) * cell_area)
        local children_cap = 0
        for _, c in ipairs(n.children) do children_cap = children_cap + nodes[c].capacity end
        n.extra_capacity = math.max(0, n.capacity - children_cap)
    end
    for k, i in ipairs(order) do
        local z = elevations[i]
        local roots, seen, lowest = {}, {}, nil
        neighbours(i, width, height, function(j)
            if uf[j] ~= nil then
                local r = root(j)
                if not seen[r] then roots[#roots + 1] = r; seen[r] = true end
                if lowest == nil or elevations[j] < elevations[lowest]
                    or (elevations[j] == elevations[lowest] and j < lowest) then lowest = j end
            end
        end)
        local x = (i - 1) % width
        local edge = x == 0 or x == width - 1 or i <= width or i > width * (height - 1)
        if edge and not seen[0] then roots[#roots + 1] = 0; seen[0] = true end
        local id
        if #roots == 0 then
            id = make_node(z, i)
            sinks[i] = id
        else
            sinks[i] = edge and 0 or sinks[lowest]
            id = component[roots[1]]
            for r = 2, #roots do
                local other = component[roots[r]]
                if id ~= 0 and other ~= 0 then
                    close_node(id, z); close_node(other, z)
                    id = make_node(z, i, { id, other })
                else
                    local closed = id ~= 0 and id or other
                    if closed ~= 0 then
                        close_node(closed, z)
                        nodes[closed].parent = 0
                        model.roots[#model.roots + 1] = closed
                    end
                    id = 0
                end
            end
        end
        local leader = id == 0 and 0 or i
        uf[i] = leader
        for _, r in ipairs(roots) do uf[r] = leader end
        component[leader] = id
        if id ~= 0 then
            local n = nodes[id]
            n.count = n.count + 1; n.sum = n.sum + z
            n.heights[#n.heights + 1] = z
            n.prefix[#n.heights] = (n.prefix[#n.heights - 1] or 0) + z
        end
        if sinks[i] == 0 then model.outlet_cells = model.outlet_cells + 1
        else nodes[sinks[i]].catchment = nodes[sinks[i]].catchment + 1 end
        if yield_fn and k % 8192 == 0 then yield_fn() end
    end
    return model
end

local function below(n, level)
    local lo, hi = 0, #n.heights
    while lo < hi do
        local mid = math.floor(div(lo + hi + 1, 2))
        if n.heights[mid] < level then lo = mid else hi = mid - 1 end
    end
    return lo
end

local function extra_at(model, n, level)
    local count = below(n, level)
    return ((level - n.base) * n.initial_count + level * count - (n.prefix[count] or 0)) * model.area
end

function H.Level(model, n)
    if n.water <= 0 then return n.base end
    local lo, hi = n.base, n.spill
    for _ = 1, 32 do
        local mid = div(lo + hi, 2)
        if extra_at(model, n, mid) < n.water then lo = mid else hi = mid end
    end
    return div(lo + hi, 2)
end

local function totals(model, n)
    n.total, n.total_mass = n.water, n.mass
    for _, id in ipairs(n.children) do
        n.total = n.total + model.nodes[id].total
        n.total_mass = n.total_mass + model.nodes[id].total_mass
    end
end

local function distribute_mass(model, n, mass)
    if n.total > 0 then
        n.mass = mass * div(n.water, n.total)
        for _, id in ipairs(n.children) do
            local c = model.nodes[id]
            distribute_mass(model, c, mass * div(c.total, n.total))
        end
    else
        n.mass = #n.children == 0 and mass or 0
        for k, id in ipairs(n.children) do distribute_mass(model, model.nodes[id], k == 1 and mass or 0) end
    end
    n.total_mass = mass
end

-- Store water in a subtree without overflowing it. Return unconsumed input.
local function fill(model, n, water, mass)
    for _, id in ipairs(n.children) do
        if water <= 0 then break end
        local c = model.nodes[id]
        if c.total < c.capacity then water, mass = fill(model, c, water, mass) end
    end
    local added = math.min(water, math.max(0, n.extra_capacity - n.water))
    local tracer = water > 0 and mass * div(added, water) or 0
    n.water = n.water + added; n.mass = n.mass + tracer
    totals(model, n)
    return water - added, mass - tracer
end

function H.Balance(model)
    local outflow, tracer_out = 0, 0
    for _, n in ipairs(model.nodes) do
        for _, id in ipairs(n.children) do
            local child = model.nodes[id]
            if n.water > 0 and child.total < child.capacity then
                n.water, n.mass = fill(model, child, n.water, n.mass)
            end
        end
        totals(model, n)
        if n.water > 0 then distribute_mass(model, n, n.total_mass) end
        local excess = math.max(0, n.water - n.extra_capacity)
        if excess > 0 then
            local tracer = n.mass * div(excess, n.water)
            n.water = n.water - excess; n.mass = n.mass - tracer
            if n.parent == 0 then outflow = outflow + excess; tracer_out = tracer_out + tracer
            else
                local parent = model.nodes[n.parent]
                parent.water = parent.water + excess; parent.mass = parent.mass + tracer
            end
            totals(model, n)
        end
    end
    model.budget.outflow = model.budget.outflow + outflow
    return outflow, tracer_out
end

-- Drop a connected water surface by depth mm, splitting at saddles as needed.
local function lower(model, n, depth)
    local initial = n.total
    if n.water > 0 then
        local level = H.Level(model, n)
        local drop = math.min(depth, level - n.base)
        n.water = math.max(0, extra_at(model, n, level - drop))
        depth = math.max(0, depth - drop)
    end
    if depth > 0 then
        for _, id in ipairs(n.children) do lower(model, model.nodes[id], depth) end
    end
    totals(model, n)
    return math.max(0, initial - n.total)
end

local function drain(model, n, depth, infiltration_share)
    if n.water > 0 or #n.children == 0 then
        local volume, mass = n.total, n.total_mass
        local lost = lower(model, n, depth)
        local removed_mass = volume > 0 and mass * div(lost, volume) * infiltration_share or 0
        distribute_mass(model, n, math.max(0, mass - removed_mass))
        if lost > 0 and infiltration_share > 0 then
            -- Where water entered the ground this step; tracer is the toxic share.
            model.seepage[#model.seepage + 1] = { seed = n.seed,
                volume = lost * infiltration_share, mass = removed_mass }
        end
        return lost
    end
    local lost = 0
    for _, id in ipairs(n.children) do lost = lost + drain(model, model.nodes[id], depth, infiltration_share) end
    totals(model, n)
    return lost
end

function H.Step(model, hours, rain_mm_h, toxic, evaporation, infiltration, runoff)
    assert(hours >= 0 and rain_mm_h >= 0 and evaporation >= 0 and infiltration >= 0, "negative water rate")
    assert(runoff >= 0 and runoff <= 1, "invalid runoff coefficient")
    -- Rain falling on standing water is captured fully. Dry land sheds only the
    -- configured runoff fraction; the rest immediately enters the ground.
    local wet = H.WetCells(model)
    local per_cell = hours * rain_mm_h * model.area
    local input, ground, outlet = 0, 0, 0
    if per_cell > 0 then
        for i, sink in ipairs(model.sinks) do
            local amount = per_cell * (wet[i] and 1 or runoff)
            input = input + per_cell; ground = ground + per_cell - amount
            if sink == 0 then outlet = outlet + amount
            else
                local n = model.nodes[sink]
                n.water = n.water + amount
                if toxic == true then n.mass = n.mass + amount end
            end
        end
    end
    model.budget.rain = model.budget.rain + input
    model.budget.ground = model.budget.ground + ground
    model.budget.outflow = model.budget.outflow + outlet
    H.Balance(model)
    model.seepage = {}
    local rate, lost = evaporation + infiltration, 0
    if rate > 0 then
        for _, id in ipairs(model.roots) do
            lost = lost + drain(model, model.nodes[id], hours * rate, div(infiltration, rate))
        end
        model.budget.infiltration = model.budget.infiltration + lost * div(infiltration, rate)
        model.budget.evaporation = model.budget.evaporation + lost * div(evaporation, rate)
    end
    return H.Total(model)
end

function H.Total(model)
    local water, mass = 0, 0
    for _, id in ipairs(model.roots) do
        water = water + model.nodes[id].total; mass = mass + model.nodes[id].total_mass
    end
    return water, mass
end

function H.Pools(model)
    local pools, stack = {}, {}
    for _, id in ipairs(model.roots) do stack[#stack + 1] = id end
    while #stack > 0 do
        local n = model.nodes[table.remove(stack)]
        if n.water > 0 then
            pools[#pools + 1] = { node = n.id, seed = n.seed, level = H.Level(model, n),
                volume = n.total, mass = n.total_mass,
                concentration = n.total > 0 and clamp(div(n.total_mass, n.total), 0, 1) or 0 }
        else for _, id in ipairs(n.children) do stack[#stack + 1] = id end end
    end
    return pools
end

-- Returns depth (mm) and dissolved tracer concentration (0..1) per wet cell.
function H.WetCells(model)
    local wet, concentration, levels, pool_of = {}, {}, {}, {}
    for _, pool in ipairs(H.Pools(model)) do
        local stack = { pool.node }
        while #stack > 0 do
            local n = model.nodes[table.remove(stack)]
            levels[n.id] = pool.level; pool_of[n.id] = pool
            for _, id in ipairs(n.children) do stack[#stack + 1] = id end
        end
    end
    -- A cell's own terrain component (rather than its runoff sink) determines
    -- whether a rising parent lake covers it. Sink ancestors carry that level.
    for i, sink in ipairs(model.sinks) do
        local id, level = sink, levels[sink]
        while id ~= 0 and level == nil do id = model.nodes[id].parent; level = levels[id] end
        if level and level > model.elevations[i] then
            wet[i] = level - model.elevations[i]
            concentration[i] = pool_of[id].concentration
        end
    end
    return wet, concentration
end

-- Dissolved tracer left behind by basins that dried completely.
function H.Residues(model)
    local residues = {}
    for _, n in ipairs(model.nodes) do
        if n.water == 0 and n.mass > 0 then
            residues[#residues + 1] = { seed = n.seed, mass = n.mass, cells = n.count }
        end
    end
    return residues
end

-- Plain numeric records keyed by cell preserve volume and residue across
-- saves and terrain rebuilds. No engine objects, UI or threads are serialized.
function H.Export(model)
    local records, wet = {}, H.WetCells(model)
    local concentration = {}
    for _, pool in ipairs(H.Pools(model)) do
        local stack = { pool.node }
        while #stack > 0 do
            local n = model.nodes[table.remove(stack)]
            concentration[n.id] = div(pool.mass, pool.volume)
            for _, id in ipairs(n.children) do stack[#stack + 1] = id end
        end
    end
    for i, depth in pairs(wet) do
        local id = model.sinks[i]
        while id ~= 0 and concentration[id] == nil do id = model.nodes[id].parent end
        local volume = depth * model.area
        records[#records + 1] = { i, volume, volume * (concentration[id] or 0) }
    end
    for _, n in ipairs(model.nodes) do
        if n.water == 0 and n.mass > 0 then records[#records + 1] = { n.seed, 0, n.mass } end
    end
    return records
end

function H.Import(model, records)
    for _, rec in ipairs(records) do
        local sink = model.sinks[rec[1]]
        assert(sink ~= nil and rec[2] >= 0 and rec[3] >= 0, "invalid saved water cell")
        if sink == 0 then model.budget.outflow = model.budget.outflow + rec[2]
        else
            local n = model.nodes[sink]
            n.water = n.water + rec[2]; n.mass = n.mass + rec[3]
        end
    end
    H.Balance(model)
end
