-- Engine-independent, volume-conserving depression hierarchy.
-- Elevation: mm. Area: m^2. Water and dissolved tracer: litres (mm * m^2).
-- Ascending union-find records real saddles. Children fill independently,
-- spill into siblings, then merge; open map edges are outlets. No terrain edits.
-- Floating point operands are explicit: the game VM divides integer operands
-- differently from stock Lua. No external libraries are required.
local H = {}
Flood.Hydrology = H
-- Hot-path globals as locals: inside a mod every global read goes through the
-- mod environment's __index metamethod.
local min, max, floor = math.min, math.max, math.floor
local ipairs, pairs, remove = ipairs, pairs, table.remove
local function div(a, b) return a * 1.0 / b end
local function clamp(v, lo, hi) return max(lo, min(v, hi)) end

local function neighbours(i, w, h, visit)
    local x = (i - 1) % w
    if x > 0 then visit(i - 1) end
    if x < w - 1 then visit(i + 1) end
    if i > w then visit(i - w) end
    if i <= w * (h - 1) then visit(i + w) end
end

-- Sorts list in place with less(a, b), calling yield_fn (when given) every few
-- thousand steps: table.sort cannot pause, and sorting a 6 km map's 147,456 cells
-- in one go stalls the game for most of a second. Bottom-up merge sort; with a
-- strict total order the result equals table.sort's.
local function sort_yielding(list, less, yield_fn)
    local n = #list
    if not yield_fn then table.sort(list, less); return end
    local src, dst = list, {}
    local width, steps = 1, 0
    while width < n do
        for lo = 1, n, 2 * width do
            local mid, hi = math.min(lo + width, n + 1), math.min(lo + 2 * width, n + 1)
            local i, j, k = lo, mid, lo
            -- Yield inside the merge: the last passes merge up to the whole list
            -- in one block.
            while i < mid and j < hi do
                if less(src[j], src[i]) then dst[k] = src[j]; j = j + 1 else dst[k] = src[i]; i = i + 1 end
                k = k + 1
                steps = steps + 1
                if steps >= 256 then steps = 0; yield_fn() end
            end
            while i < mid do dst[k] = src[i]; i = i + 1; k = k + 1 end
            while j < hi do dst[k] = src[j]; j = j + 1; k = k + 1 end
            steps = steps + 1
            if steps >= 256 then steps = 0; yield_fn() end
        end
        src, dst = dst, src
        width = width * 2
    end
    if src ~= list then
        for i = 1, n do
            list[i] = src[i]
            if i % 4096 == 0 then yield_fn() end
        end
    end
end

function H.Build(width, height, elevations, cell_area, yield_fn)
    assert(width >= 3 and height >= 3 and #elevations == width * height, "invalid terrain grid")
    assert(cell_area > 0, "invalid cell area")
    local model = { width = width, height = height, elevations = elevations,
        area = cell_area, nodes = {}, sinks = {}, roots = {}, outlet_cells = 0, seepage = {},
        budget = { rain = 0, evaporation = 0, infiltration = 0, outflow = 0, ground = 0 } }
    local nodes, sinks = model.nodes, model.sinks
    local order, uf, component = {}, { [0] = 0 }, { [0] = 0 }
    for i = 1, #elevations do
        order[i] = i
        if yield_fn and i % 4096 == 0 then yield_fn() end
    end
    sort_yielding(order, function(a, b)
        return elevations[a] < elevations[b] or (elevations[a] == elevations[b] and a < b)
    end, yield_fn)
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
        n.capacity = max(0, (spill * n.count - n.sum) * cell_area)
        local children_cap = 0
        for _, c in ipairs(n.children) do children_cap = children_cap + nodes[c].capacity end
        n.extra_capacity = max(0, n.capacity - children_cap)
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
        if yield_fn and k % 256 == 0 then yield_fn() end
    end
    -- Cells whose runoff sink is each node: lets wet-cell queries visit only the
    -- cells under wet basins instead of the whole grid.
    local cells_of = {}
    for i, sink in ipairs(sinks) do
        if sink ~= 0 then
            local list = cells_of[sink]
            if not list then list = {}; cells_of[sink] = list end
            list[#list + 1] = i
        end
        if yield_fn and i % 1024 == 0 then yield_fn() end
    end
    model.cells_of = cells_of
    return model
end

local function below(n, level)
    local lo, hi = 0, #n.heights
    while lo < hi do
        local mid = floor(div(lo + hi + 1, 2))
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

-- The hierarchy can be over a thousand levels deep on large maps, and the game
-- engine logs a stack dump for every call past its depth warning. Every subtree
-- walk below therefore uses an explicit stack, visiting nodes and summing in the
-- same order as the equivalent recursion.

-- yield_fn, when given (restores in a terrain job), is called every 256 nodes:
-- a large lake's subtree has thousands of them.
local YIELD_NODES = 256

-- Split a subtree's tracer among its nodes in proportion to their water.
local function distribute_mass(model, n, mass, yield_fn)
    local nodes = model.nodes
    local stack_n, stack_m = { n }, { mass }
    local visited = 0
    while #stack_n > 0 do
        if yield_fn then
            visited = visited + 1
            if visited % YIELD_NODES == 0 then yield_fn() end
        end
        local node, m = stack_n[#stack_n], stack_m[#stack_m]
        stack_n[#stack_n], stack_m[#stack_m] = nil, nil
        local children = node.children
        if node.total > 0 then
            node.mass = m * div(node.water, node.total)
            for _, id in ipairs(children) do
                local c = nodes[id]
                stack_n[#stack_n + 1], stack_m[#stack_m + 1] = c, m * div(c.total, node.total)
            end
        else
            node.mass = #children == 0 and m or 0
            for k, id in ipairs(children) do
                stack_n[#stack_n + 1], stack_m[#stack_m + 1] = nodes[id], k == 1 and m or 0
            end
        end
        node.total_mass = m
    end
end

-- Store water in a subtree without overflowing it. Return unconsumed input.
-- Children fill first, in order, while input remains; then the node itself.
local function fill(model, n, water, mass, yield_fn)
    local nodes = model.nodes
    local stack = { { n, 1 } }
    local visited = 0
    while #stack > 0 do
        if yield_fn then
            visited = visited + 1
            if visited % YIELD_NODES == 0 then yield_fn() end
        end
        local frame = stack[#stack]
        local node, k = frame[1], frame[2]
        local children = node.children
        local pushed = false
        while k <= #children and water > 0 do
            local c = nodes[children[k]]
            k = k + 1
            if c.total < c.capacity then
                frame[2] = k
                stack[#stack + 1] = { c, 1 }
                pushed = true
                break
            end
        end
        if not pushed then
            local added = min(water, max(0, node.extra_capacity - node.water))
            local tracer = water > 0 and mass * div(added, water) or 0
            node.water = node.water + added; node.mass = node.mass + tracer
            totals(model, node)
            water, mass = water - added, mass - tracer
            stack[#stack] = nil
        end
    end
    return water, mass
end

-- yield_fn, when given, is called every 512 nodes: restoring a large saved water
-- state balances the whole hierarchy at once (in-game: >30M Lua lines, killed by
-- the engine's thread watchdog). Yielding never changes the result.
function H.Balance(model, yield_fn)
    local outflow, tracer_out = 0, 0
    for k, n in ipairs(model.nodes) do
        if yield_fn and k % 64 == 0 then yield_fn() end
        for _, id in ipairs(n.children) do
            local child = model.nodes[id]
            if n.water > 0 and child.total < child.capacity then
                n.water, n.mass = fill(model, child, n.water, n.mass, yield_fn)
            end
        end
        totals(model, n)
        if n.water > 0 then distribute_mass(model, n, n.total_mass, yield_fn) end
        local excess = max(0, n.water - n.extra_capacity)
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
-- Each node lowers its own surface on entry; whatever depth remains passes to
-- its children; totals are refreshed on exit.
local function lower(model, n, depth)
    local nodes = model.nodes
    local function enter(node, d)
        local initial = node.total
        if node.water > 0 then
            local level = H.Level(model, node)
            local drop = min(d, level - node.base)
            node.water = max(0, extra_at(model, node, level - drop))
            d = max(0, d - drop)
        end
        return { node, d, 1, initial }
    end
    local stack = { enter(n, depth) }
    local initial = stack[1][4]
    while #stack > 0 do
        local frame = stack[#stack]
        local node, d, k = frame[1], frame[2], frame[3]
        if d > 0 and k <= #node.children then
            frame[3] = k + 1
            stack[#stack + 1] = enter(nodes[node.children[k]], d)
        else
            totals(model, node)
            stack[#stack] = nil
        end
    end
    return max(0, initial - n.total)
end

-- A wet node or a leaf: lower it and remove infiltrated tracer.
local function drain_surface(model, n, depth, infiltration_share)
    local volume, mass = n.total, n.total_mass
    local lost = lower(model, n, depth)
    local removed_mass = volume > 0 and mass * div(lost, volume) * infiltration_share or 0
    distribute_mass(model, n, max(0, mass - removed_mass))
    if lost > 0 and infiltration_share > 0 then
        -- Where water entered the ground this step; tracer is the toxic share.
        model.seepage[#model.seepage + 1] = { seed = n.seed,
            volume = lost * infiltration_share, mass = removed_mass }
    end
    return lost
end

-- Dry interior nodes pass the drain to their children, summing losses in order.
-- A subtree with no water and no tracer has nothing to drain (Balance has just
-- refreshed totals), so it is skipped.
local function drain(model, n, depth, infiltration_share)
    if n.water > 0 or #n.children == 0 then return drain_surface(model, n, depth, infiltration_share) end
    local nodes = model.nodes
    local stack = { { n, 1, 0 } }
    while true do
        local frame = stack[#stack]
        local node, k = frame[1], frame[2]
        local children = node.children
        local pushed = false
        while k <= #children do
            local c = nodes[children[k]]
            k = k + 1
            if c.total > 0 or c.total_mass > 0 then
                if c.water > 0 or #c.children == 0 then
                    frame[3] = frame[3] + drain_surface(model, c, depth, infiltration_share)
                else
                    frame[2] = k
                    stack[#stack + 1] = { c, 1, 0 }
                    pushed = true
                    break
                end
            end
        end
        if not pushed then
            totals(model, node)
            stack[#stack] = nil
            if #stack == 0 then return frame[3] end
            local parent = stack[#stack]
            parent[3] = parent[3] + frame[3]
        end
    end
end

function H.Step(model, hours, rain_mm_h, toxic, evaporation, infiltration, runoff)
    assert(hours >= 0 and rain_mm_h >= 0 and evaporation >= 0 and infiltration >= 0, "negative water rate")
    assert(runoff >= 0 and runoff <= 1, "invalid runoff coefficient")
    -- Rain falling on standing water is captured fully. Dry land sheds only the
    -- configured runoff fraction; the rest immediately enters the ground.
    local per_cell = hours * rain_mm_h * model.area
    local input, ground, outlet = 0, 0, 0
    if per_cell > 0 then
        local wet = H.WetCells(model)
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
            local root = model.nodes[id]
            if root.total > 0 or root.total_mass > 0 then
                lost = lost + drain(model, root, hours * rate, div(infiltration, rate))
            end
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

function H.Pools(model, yield_fn)
    local pools, stack = {}, {}
    for _, id in ipairs(model.roots) do stack[#stack + 1] = id end
    local visited = 0
    while #stack > 0 do
        if yield_fn then
            visited = visited + 1
            if visited % YIELD_NODES == 0 then yield_fn() end
        end
        local n = model.nodes[remove(stack)]
        if n.water > 0 then
            pools[#pools + 1] = { node = n.id, seed = n.seed, level = H.Level(model, n),
                volume = n.total, mass = n.total_mass,
                concentration = n.total > 0 and clamp(div(n.total_mass, n.total), 0, 1) or 0 }
        else for _, id in ipairs(n.children) do stack[#stack + 1] = id end end
    end
    return pools
end

-- Returns depth (mm) and dissolved tracer concentration (0..1) per wet cell, and
-- the number of wet cells per pool (keyed by the pool's node id).
-- Also returns the pools list it was computed from.
-- A cell is covered by a pool when its runoff sink lies in the pool's subtree (a
-- rising parent lake covers its children's cells) and the level is above it.
-- Ancestors of a node outside every pool subtree cannot be pool members, so only
-- the cells under wet subtrees are visited (not the whole grid).
local no_cells = {}
-- yield_fn, when given (the handover of a terrain job), is called every 256 nodes.
function H.WetCells(model, yield_fn)
    local wet, concentration, pool_cells = {}, {}, {}
    local pools = H.Pools(model, yield_fn)
    local nodes, cells_of, elevations = model.nodes, model.cells_of, model.elevations
    local visited = 0
    for _, pool in ipairs(pools) do
        local level, c, count = pool.level, pool.concentration, 0
        local stack = { pool.node }
        while #stack > 0 do
            if yield_fn then
                visited = visited + 1
                if visited % YIELD_NODES == 0 then yield_fn() end
            end
            local n = nodes[remove(stack)]
            for _, i in ipairs(cells_of[n.id] or no_cells) do
                local z = elevations[i]
                if level > z then wet[i] = level - z; concentration[i] = c; count = count + 1 end
            end
            for _, id in ipairs(n.children) do stack[#stack + 1] = id end
        end
        if count > 0 then pool_cells[pool.node] = count end
    end
    return wet, concentration, pool_cells, pools
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
function H.Export(model, yield_fn)
    local records, wet = {}, H.WetCells(model, yield_fn)
    local concentration = {}
    local visited = 0
    for _, pool in ipairs(H.Pools(model, yield_fn)) do
        local stack = { pool.node }
        while #stack > 0 do
            if yield_fn then
                visited = visited + 1
                if visited % YIELD_NODES == 0 then yield_fn() end
            end
            local n = model.nodes[remove(stack)]
            concentration[n.id] = div(pool.mass, pool.volume)
            for _, id in ipairs(n.children) do stack[#stack + 1] = id end
        end
    end
    local k = 0
    for i, depth in pairs(wet) do
        k = k + 1
        if yield_fn and k % 512 == 0 then yield_fn() end
        local id = model.sinks[i]
        while id ~= 0 and concentration[id] == nil do id = model.nodes[id].parent end
        local volume = depth * model.area
        records[#records + 1] = { i, volume, volume * (concentration[id] or 0) }
    end
    for j, n in ipairs(model.nodes) do
        if yield_fn and j % 1024 == 0 then yield_fn() end
        if n.water == 0 and n.mass > 0 then records[#records + 1] = { n.seed, 0, n.mass } end
    end
    return records
end

function H.Import(model, records, yield_fn)
    for k, rec in ipairs(records) do
        if yield_fn and k % 1024 == 0 then yield_fn() end
        local sink = model.sinks[rec[1]]
        assert(sink ~= nil and rec[2] >= 0 and rec[3] >= 0, "invalid saved water cell")
        if sink == 0 then model.budget.outflow = model.budget.outflow + rec[2]
        else
            local n = model.nodes[sink]
            n.water = n.water + rec[2]; n.mass = n.mass + rec[3]
        end
    end
    H.Balance(model, yield_fn)
end
