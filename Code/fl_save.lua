local F = Flood
F.Save = {}

function F.Save.Capture()
    local s = F.State
    if not s.model or not s.grid or not s.map then return false end
    local saved = { schema = 1, width = s.grid.width, height = s.grid.height,
        sx = s.grid.sx, sy = s.grid.sy, cells = F.Hydrology.Export(s.model) }
    s.map.fl_saved = saved
    F.Log("Save", "captured water and dissolved residue", { cells = #saved.cells })
    return saved
end

function F.Save.Import(model, grid, saved)
    assert(type(saved) == "table" and saved.schema == 1, "unsupported Flood save schema")
    assert(saved.sx == grid.sx and saved.sy == grid.sy, "Flood saved map dimensions do not match")
    assert(type(saved.cells) == "table" and saved.width >= 3 and saved.height >= 3, "invalid Flood saved grid")
    local records = {}
    for _, record in ipairs(saved.cells) do
        local i = record[1]
        assert(type(i) == "number" and i >= 1 and i <= saved.width * saved.height, "invalid Flood saved cell")
        local x = (i - 1) % saved.width
        local y = math.floor((i - 1) * 1.0 / saved.width)
        local nx = math.min(grid.width - 1, math.floor((x + 0.5) * grid.width / (saved.width * 1.0)))
        local ny = math.min(grid.height - 1, math.floor((y + 0.5) * grid.height / (saved.height * 1.0)))
        records[#records + 1] = { ny * grid.width + nx + 1, record[2], record[3] }
    end
    F.Hydrology.Import(model, records)
    F.Log("Save", "restored water and dissolved residue", { cells = #records })
end

