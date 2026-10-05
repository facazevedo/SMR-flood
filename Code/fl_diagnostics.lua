-- Frame-cost profiler: every piece of Flood's work runs through Measure, which
-- keeps the slowest step of the last PROFILE_WINDOW_MS of real time (shown in
-- the test panel) and the slowest per step name since the last report (logged
-- once per game hour when DEBUG_LOGS is true). A step here is one uninterrupted
-- run of Lua and engine calls: the longest one is how long Flood can stall the
-- game in one go.
local F = Flood
local D = {}
F.Diagnostics = D

local window = { worst_ms = 0, worst_name = "none", started = 0 }
local since_report = {}

-- Runs fn(...) and records its real-time cost under name. Returns fn's results.
function D.Measure(name, fn, ...)
    local t0 = GetPreciseTicks()
    local a, b, c = fn(...)
    local ms = GetPreciseTicks() - t0
    local now = RealTime()
    if now - window.started >= F.Config.PROFILE_WINDOW_MS then
        window.worst_ms, window.worst_name, window.started = 0, "none", now
    end
    if ms > window.worst_ms then window.worst_ms, window.worst_name = ms, name end
    if ms > (since_report[name] or 0) then since_report[name] = ms end
    return a, b, c
end

-- The slowest step of the current window, for the panel.
function D.Worst()
    return window.worst_ms, window.worst_name
end

-- Logs the slowest step per name since the last report, then starts afresh.
function D.Report()
    if next(since_report) then F.Log("Profile", "slowest steps (ms) since last report", since_report) end
    since_report = {}
end
