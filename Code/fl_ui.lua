-- Temporary test panel: Light / Moderate / Heavy storm toggles, Fresh / Toxic, Cold
-- Wave and Terraformed.
-- Pattern follows Martian Waters' HUD panel (XDialog parented to GetHUD()).
local F = Flood
local UI = {}
F.UI = UI

local TEXT_STYLE = "InfopanelTextR"
local BUTTON_BG = RGBA(32, 46, 56, 235)
local BUTTON_ACTIVE = RGBA(40, 130, 110, 245)
local BUTTON_TOXIC = RGBA(120, 132, 40, 245)
local BUTTON_HOVER = RGBA(48, 74, 90, 245)
local BUTTON_COLD = RGBA(70, 118, 168, 245)
local BUTTON_TERRAFORMED = RGBA(64, 140, 72, 245)
local STRENGTH_NAMES = { "Light", "Moderate", "Heavy" }

local function alive(win)
    return win and win.window_state ~= "destroying" and win.window_state ~= "destroyed"
end

local function host()
    local hud = GetHUD()
    if alive(hud) then return hud end
    return terminal.desktop and alive(terminal.desktop) and terminal.desktop or nil
end

local function button(panel, id, on_press)
    local btn = XTextButton:new({ Id = id, Text = "", Translate = false, TextStyle = TEXT_STYLE,
        TextColor = RGB(232, 240, 245), RolloverTextColor = RGB(255, 255, 255),
        HAlign = "stretch", MinHeight = 26, MaxHeight = 26, Padding = box(6, 3, 6, 3),
        Background = BUTTON_BG, FocusedBackground = BUTTON_BG,
        RolloverBackground = BUTTON_HOVER, PressedBackground = BUTTON_HOVER }, panel)
    btn.OnPress = function()
        local ok, err = on_press()
        if ok == false then
            F.State.status = tostring(err)
            F.Log("UI", "control refused", { control = id, reason = err })
        end
        UI.Refresh()
    end
    return btn
end

local function set_button(btn, text, background)
    if not alive(btn) then return end
    btn:SetText(text)
    btn:SetBackground(background); btn:SetFocusedBackground(background)
end

local function show()
    local parent = host()
    if not parent then return false end
    local panel = XDialog:new({ Id = "idFloodTestPanel", ZOrder = 9800, IdNode = true,
        HAlign = "left", VAlign = "top", Margins = box(F.Config.UI_LEFT, F.Config.UI_TOP, 0, 0),
        Padding = box(10, 8, 10, 8), MinWidth = 280, MaxWidth = 280,
        LayoutMethod = "VList", LayoutVSpacing = 4, Background = RGBA(10, 20, 28, 200),
        HandleMouse = true, ChildrenHandleMouse = true }, parent)
    XText:new({ Id = "idTitle", TextStyle = TEXT_STYLE, Translate = false, Text = "Flood test storms" }, panel)
    for strength = 1, 3 do
        button(panel, "idRain" .. strength, function() return F.Rain.Toggle(strength) end)
    end
    button(panel, "idType", function() return F.Rain.ToggleType() end)
    button(panel, "idColdWave", function() return F.ColdWave.Toggle() end)
    button(panel, "idTerraform", function() return F.Terraforming.Toggle() end)
    XText:new({ Id = "idStatus", TextStyle = TEXT_STYLE, Translate = false, Text = "" }, panel)
    if panel.window_state == "new" then panel:Open() end
    F.State.ui = panel
    F.Log("UI", "panel shown", { left = F.Config.UI_LEFT, top = F.Config.UI_TOP })
    return true
end

local function status_lines(s)
    local lines = { s.status }
    if s.model then
        lines[#lines + 1] = string.format("Rain %.1f mm/h%s, evaporation %.1f mm/h",
            s.last_rate or 0, s.last_toxic and " toxic" or "", s.evaporation_mm_h or 0)
        lines[#lines + 1] = string.format("Pools %d (%d drawn), water %.0f m3",
            s.wet_pools or 0, s.visible_pools or 0, F.Hydrology.Total(s.model) / 1000)
        lines[#lines + 1] = string.format("Flooded buildings %d, slowed rovers %d",
            s.flooded_buildings or 0, s.slowed_rovers or 0)
        local worst_ms, worst_name = F.Diagnostics.Worst()
        lines[#lines + 1] = string.format("Slowest Flood step (10 s): %d ms, %s", worst_ms, worst_name)
        if (s.frozen_pools or 0) > 0 then
            lines[#lines + 1] = string.format("Frozen pools %d, ice plates %d", s.frozen_pools, s.ice_plates or 0)
        end
    end
    return table.concat(lines, "\n")
end

-- Creates the panel when needed, then mirrors the current state. Idempotent.
function UI.Refresh()
    local s = F.State
    if F.Config.ENABLE_TEST_UI ~= true or not s.map then UI.Hide(); return end
    if not alive(s.ui) and not show() then return end
    local panel = s.ui
    for strength = 1, 3 do
        local on = s.rain_strength == strength and s.rain_thread ~= false
        set_button(panel["idRain" .. strength], string.format("%s %s (%d mm/h)", on and "Stop" or "Start",
            STRENGTH_NAMES[strength], F.Config.RAIN_MM_H[strength]), on and BUTTON_ACTIVE or BUTTON_BG)
    end
    set_button(panel.idType, s.rain_type == "toxic" and "Rain type: Toxic" or "Rain type: Fresh",
        s.rain_type == "toxic" and BUTTON_TOXIC or BUTTON_BG)
    local cold = F.ColdWave.Active()
    set_button(panel.idColdWave, cold and "Cold wave: On (click: Off)" or "Cold wave: Off (click: On)",
        cold and BUTTON_COLD or BUTTON_BG)
    local terraformed = F.Terraforming.Active()
    set_button(panel.idTerraform, terraformed and "Terraformed: On (click: Off)" or "Terraformed: Off (click: On)",
        terraformed and BUTTON_TERRAFORMED or BUTTON_BG)
    if alive(panel.idStatus) then panel.idStatus:SetText(status_lines(s)) end
end

function UI.Hide()
    local s = F.State
    if alive(s.ui) then
        s.ui:delete()
        F.Log("UI", "panel hidden", {})
    end
    s.ui = false
end
