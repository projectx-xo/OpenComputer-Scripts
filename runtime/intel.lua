local component = require("component")
local computer = require("computer")
local context
local runtime = {}
local PAGE_SIZE = 6
local scanFrame, frameSequence, nextPoll = nil, 0, 0

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

-- Frames identify the result being paged, including repeated scans of the same coordinates.
local function observeScan()
    local sat, address = satellite()
    local _, state = progress(sat)
    if state ~= "COMPLETE" then scanFrame = nil; return sat end
    local summary = tostring(sat.intelSummary())
    if not scanFrame or scanFrame.summary ~= summary or scanFrame.address ~= address then
        frameSequence = frameSequence + 1
        local session = tostring(context.session or context.id)
        scanFrame = {id=session .. ":" .. frameSequence, sequence=frameSequence, session=session,
            summary=summary, address=address}
        context.send(nil, "SCAN_COMPLETE", scanFrame)
    end
    return sat
end

local function modelPage(frame, page)
    local sat = observeScan()
    if not scanFrame or frame ~= scanFrame.id then error("Scan changed or is not complete; request the latest frame") end
    local kind, index = tostring(page):match("^(%a+):(%d+)$")
    index = integer(index, "Model page", 1)
    local rows = {}
    if kind == "structure" and index <= 128 then
        local ok, count, encoded = sat.intelStructuralPage(index)
        if not ok then
            if count == "OUT_OF_RANGE" then return "", true end
            error(tostring(count))
        end
        for row in tostring(encoded):gmatch("[^|]+") do
            local x,y,z,_,_,resistance = row:match("^([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),[^,]+$")
            if not x or not tonumber(resistance) then error("Malformed structural cell") end
            rows[#rows+1] = table.concat({integer(x,"X"),integer(y,"Y"),integer(z,"Z"),tonumber(resistance)>=40 and 2 or 1},",")
        end
        if #rows ~= count or count > 64 then error("Malformed structural page") end
        return table.concat(rows,"|"), count < 64 or index == 128
    elseif kind == "targets" and index <= 16 then
        local count = math.min(128, sat.intelFindingCount())
        for i=(index-1)*8+1, math.min(index*8,count) do
            local f={sat.intelGetFinding(i)}
            if not f[1] then error("Finding unavailable") end
            if (f[15] and f[15] ~= "") or f[11] or f[13] then
                local coordinates={}
                for axis=4,9 do coordinates[#coordinates+1]=integer(f[axis],"Target coordinate") end
                rows[#rows+1]=table.concat(coordinates,",")
            end
        end
        return table.concat(rows,"|"), index*8 >= count
    end
    error("Model page out of range")
end

function runtime.start(ctx) context = assert(ctx); scanFrame=nil; frameSequence=0; nextPoll=0 end
function runtime.stop() context = nil; scanFrame=nil end
function runtime.tick()
    if not context or computer.uptime() < nextPoll then return end
    nextPoll=computer.uptime()+1
    local ok=pcall(observeScan)
    if not ok then scanFrame=nil end
end
function runtime.busy() return runtime.status().busy == true end
function runtime.status()
    local ok, result = pcall(function()
        local sat, address = satellite()
        local text, state = progress(sat)
        return {intelligence = true, satelliteAddress = address, satelliteType = "COMBINED_INTEL", scanState = state,
            scanProgress = text, busy = state == "RUNNING" or state == "SCANNING", ready = true,
            scanFrame = state == "COMPLETE" and scanFrame or nil}
    end)
    return ok and result or {intelligence = true, ready = false, error = tostring(result)}
end

function runtime.onMessage(remote, command, arg1, arg2, arg3)
    if command == "SCAN_MODEL" then
        local ok, data, done = pcall(modelPage, arg1, arg2)
        if not ok then done=tostring(data); data=false end
        context.send(remote, command, arg1, arg2, arg3, data, done)
        return
    end
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
            scanFrame = nil
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
