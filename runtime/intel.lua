local component = require("component")
local context
local runtime = {}
local PAGE_SIZE = 6

local function satellite()
    local addresses = {}
    for address in component.list("ntm_satlink") do addresses[#addresses + 1] = address end
    local address = context.config and context.config.satelliteAddress
    if not address then
        if #addresses ~= 1 then error("Connect one ntm_satlink, or set config.satelliteAddress") end
        address = addresses[1]
    end
    local sat = component.proxy(address)
    if not sat.isConnected() then error("Satellite link disconnected; check power and frequency") end
    if sat.getType() ~= "COMBINED_INTEL" then error("This feature requires a COMBINED_INTEL satellite") end
    return sat, address
end

local function integer(value, name, minimum)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge or n % 1 ~= 0 or (minimum and n < minimum) then
        error(name .. " must be an integer" .. (minimum and (" >= " .. minimum) or ""))
    end
    return n
end

local function progress(sat)
    local state, done, total, coverage = sat.intelStatus()
    return tostring(state) .. " | work " .. tostring(done) .. "/" .. tostring(total)
        .. " | coverage " .. tostring(coverage) .. "%", state
end

local function results(sat, page)
    local _, state = progress(sat)
    if state ~= "COMPLETE" then error("Scan is " .. tostring(state) .. "; wait for COMPLETE before reading results") end
    local count = sat.intelFindingCount()
    local pages = math.max(1, math.ceil(count / PAGE_SIZE))
    if page > pages then error("Page out of range; " .. pages .. " page(s)") end
    local lines = {sat.intelSummary(), string.format("Findings %d | page %d/%d", count, page, pages)}
    for index = (page - 1) * PAGE_SIZE + 1, math.min(count, page * PAGE_SIZE) do
        local f = {sat.intelGetFinding(index)}
        if f[1] then
            lines[#lines + 1] = string.format("#%d %s | X=%s Y=%s Z=%s to %s,%s,%s | confidence=%s",
                index, tostring(f[2]), tostring(f[4]), tostring(f[5]), tostring(f[6]),
                tostring(f[7]), tostring(f[8]), tostring(f[9]), tostring(f[3]))
            if f[15] and f[15] ~= "" then
                lines[#lines + 1] = "  " .. tostring(f[15]) .. " | " .. tostring(f[16]) .. " | count=" .. tostring(f[17])
            end
        end
    end
    if count == 0 then lines[#lines + 1] = "No findings in this scan." end
    return table.concat(lines, "\n")
end

local function structure(sat, page)
    local _, state = progress(sat)
    if state ~= "COMPLETE" then error("Scan is " .. tostring(state) .. "; wait for COMPLETE") end
    -- HBM returns 64 cells per page. Display eight per console page to keep packets bounded.
    local sourcePage = math.floor((page - 1) / 8) + 1
    local offset = ((page - 1) % 8) * 8
    local ok, count, encoded = sat.intelStructuralPage(sourcePage)
    if not ok then error("Structural page unavailable: " .. tostring(count)) end
    local lines, cells = {"Structure page " .. page .. " | HBM blast resistance"}, {}
    for cell in tostring(encoded):gmatch("[^|]+") do cells[#cells + 1] = cell end
    if offset >= #cells then error("Structural page out of range") end
    for index = offset + 1, math.min(offset + 8, #cells) do
        local x, y, z, material, metadata, resistance, band = cells[index]:match("^([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)$")
        if x then lines[#lines + 1] = string.format("%s,%s,%s | %s:%s | %s (%s)", x, y, z, material, metadata, resistance, band) end
    end
    if page == 1 and sat.intelStructuralSummary then
        local s = {sat.intelStructuralSummary()}
        if s[1] then lines[#lines + 1] = string.format("Material=%s avg=%s max=%s wall=%s roof=%s floor=%s weak=%s",
            tostring(s[2]), tostring(s[3]), tostring(s[4]), tostring(s[5]), tostring(s[6]), tostring(s[7]), tostring(s[8])) end
    end
    return table.concat(lines, "\n")
end

function runtime.start(ctx) context = assert(ctx) end
function runtime.stop() context = nil end
function runtime.tick() end
function runtime.busy() return runtime.status().busy == true end
function runtime.status()
    local ok, result = pcall(function()
        local sat, address = satellite()
        local text, state = progress(sat)
        return {intelligence = true, satelliteAddress = address, satelliteType = "COMBINED_INTEL", scanState = state,
            scanProgress = text, busy = state == "RUNNING" or state == "SCANNING", ready = true}
    end)
    return ok and result or {intelligence = true, ready = false, error = tostring(result)}
end

function runtime.onMessage(remote, command, arg1, arg2, arg3)
    local token = command == "SCAN" and arg3 or (command == "SCAN_STATUS" and arg1 or arg2)
    local ok, text = pcall(function()
        local sat = satellite()
        if command == "SCAN" then
            local x, z = integer(arg1, "X"), integer(arg2, "Z")
            local _, state = progress(sat)
            if state == "RUNNING" or state == "SCANNING" then error("Scan already running") end
            local accepted, detail = sat.intelSetTarget(x, z)
            if not accepted then error(tostring(detail)) end
            accepted, detail = sat.intelStartScan()
            if not accepted then error(tostring(detail)) end
            return "Scan started at X=" .. x .. " Z=" .. z .. ". Use scan status, then scan results."
        elseif command == "SCAN_STATUS" then
            return progress(sat)
        elseif command == "SCAN_RESULTS" then
            return results(sat, integer(arg1 or 1, "Page", 1))
        elseif command == "SCAN_STRUCTURE" then
            return structure(sat, integer(arg1 or 1, "Page", 1))
        end
        error("Unsupported intelligence command: " .. tostring(command))
    end)
    context.send(remote, ok and command or "ERROR", tostring(text), token)
end
return runtime
