local F = Flood
function F.Log(scope, operation, data)
    if F.Config.DEBUG_LOGS ~= true then return end
    local fields = {}
    for key, value in pairs(data or {}) do
        fields[#fields + 1] = tostring(key) .. "=" .. tostring(value)
    end
    table.sort(fields)
    print("[Flood:" .. scope .. "] " .. operation .. " " .. table.concat(fields, " "))
end

