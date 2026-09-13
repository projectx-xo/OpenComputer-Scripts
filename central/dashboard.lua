local component = require("component")
local event = require("event")
local computer = require("computer")
local term = require("term")

local dashboard = {}

local COLORS = {
    bg = 0x11161C,
    panel = 0x18212A,
    panelAlt = 0x202C37,
    header = 0x0B1117,
    border = 0x344454,
    text = 0xD8E1EA,
    muted = 0x7E8B98,
    cyan = 0x42C7D9,
    green = 0x57C778,
    amber = 0xE5B84A,
    red = 0xE15A5A,
    blue = 0x659BE8,
    purple = 0xA477D4,
}

local PAGE_ORDER = {"cop", "tracks", "assets", "network"}
local PAGE_LABELS = {
    cop = "COP",
    tracks = "TRACKS",
    assets = "ASSETS",
    network = "NETWORK",
}

local dashboardLog = {}

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function round(value)
    return math.floor(value + 0.5)
end

local function appendLog(text)
    text = tostring(text or ""):gsub("\n", " ")
    if text == "" then return end
    table.insert(dashboardLog, text)
    while #dashboardLog > 8 do table.remove(dashboardLog, 1) end
end

local function joinPrintArgs(...)
    local values = {}
    for index = 1, select("#", ...) do
        values[index] = tostring(select(index, ...))
    end
    return table.concat(values, " ")
end

local function boundGpu()
    local address = component.list("gpu")()
    if not address then return nil, "No GPU detected." end
    local gpu = component.proxy(address)
    local ok, screen = pcall(gpu.getScreen)
    if not ok or not screen then return nil, "GPU is not bound to a screen." end
    return gpu
end

local function inspectDisplay(override)
    local gpu, reason = boundGpu()
    if not gpu then return nil, reason end

    local okSize, blocksWide, blocksHigh = pcall(gpu.getSize)
    if not okSize then
        blocksWide, blocksHigh = 1, 1
    end
    blocksWide = math.max(1, tonumber(blocksWide) or 1)
    blocksHigh = math.max(1, tonumber(blocksHigh) or 1)

    local maxWidth, maxHeight = gpu.maxResolution()
    local currentWidth, currentHeight = gpu.getResolution()
    local physicalAspect = blocksWide / blocksHigh

    -- Character cells are roughly twice as tall as they are wide. Matching the
    -- logical character aspect to the physical panel aspect keeps a square 3x3
    -- wall from rendering a 160x50 UI stretched across the glass.
    local targetHeight = maxHeight
    local targetWidth = round(targetHeight * 2 * physicalAspect)
    targetWidth = clamp(targetWidth, math.min(60, maxWidth), maxWidth)

    local requested = string.lower(tostring(override or "auto"))
    if requested == "wide" or requested == "workstation" then
        targetWidth, targetHeight = maxWidth, maxHeight
    elseif requested == "compact" then
        targetWidth = math.min(maxWidth, 80)
        targetHeight = math.min(maxHeight, 30)
    elseif requested ~= "auto" and requested ~= "wall" then
        requested = "auto"
    end

    local profile
    if requested == "wall" or (requested == "auto" and blocksWide >= 3 and blocksHigh >= 3) then
        profile = "command_wall"
    elseif requested == "compact" or targetWidth < 90 or targetHeight < 30 then
        profile = "compact"
    else
        profile = "workstation"
    end

    return {
        gpu = gpu,
        blocksWide = blocksWide,
        blocksHigh = blocksHigh,
        maxWidth = maxWidth,
        maxHeight = maxHeight,
        currentWidth = currentWidth,
        currentHeight = currentHeight,
        targetWidth = targetWidth,
        targetHeight = targetHeight,
        profile = profile,
        override = requested,
    }
end

dashboard.inspectDisplay = inspectDisplay

function dashboard.printDisplayInfo()
    local display, reason = inspectDisplay("auto")
    if not display then
        print("[DISPLAY] " .. tostring(reason))
        return false
    end

    local depth = "?"
    if display.gpu.maxDepth then
        local ok, value = pcall(display.gpu.maxDepth)
        if ok then depth = tostring(value) end
    end

    print("")
    print("STRATCOM DISPLAY")
    print("============================================================")
    print("Physical panel: " .. display.blocksWide .. "x" .. display.blocksHigh .. " blocks")
    print("Current:        " .. display.currentWidth .. "x" .. display.currentHeight)
    print("Maximum:        " .. display.maxWidth .. "x" .. display.maxHeight)
    print("Color depth:    " .. depth .. " bit")
    print("Auto profile:   " .. display.profile)
    print("Auto resolution:" .. display.targetWidth .. "x" .. display.targetHeight)
    print("Dashboard:      dashboard [auto|wall|wide|compact]")
    print("")
    return true
end

local function configureDisplay(override)
    local display, reason = inspectDisplay(override)
    if not display then return nil, reason end

    if display.gpu.maxDepth then
        local ok, depth = pcall(display.gpu.maxDepth)
        if ok and tonumber(depth) and tonumber(depth) >= 8 then
            pcall(display.gpu.setDepth, 8)
        end
    end

    local width, height = display.gpu.getResolution()
    if width ~= display.targetWidth or height ~= display.targetHeight then
        local ok, changed = pcall(display.gpu.setResolution, display.targetWidth, display.targetHeight)
        if not ok or changed == false then
            return nil, "Unable to set dashboard resolution."
        end
    end

    display.width, display.height = display.gpu.getResolution()
    return display
end

local function setColors(gpu, foreground, background)
    gpu.setForeground(foreground)
    gpu.setBackground(background)
end

local function fill(gpu, width, height, x, y, w, h, background, character)
    if w <= 0 or h <= 0 then return end
    if x > width or y > height or x + w - 1 < 1 or y + h - 1 < 1 then return end
    local x1 = clamp(x, 1, width)
    local y1 = clamp(y, 1, height)
    local x2 = clamp(x + w - 1, 1, width)
    local y2 = clamp(y + h - 1, 1, height)
    if x2 < x1 or y2 < y1 then return end
    gpu.setBackground(background)
    gpu.fill(x1, y1, x2 - x1 + 1, y2 - y1 + 1, character or " ")
end

local function text(gpu, width, height, x, y, value, foreground, background, maxLength)
    if x < 1 or x > width or y < 1 or y > height then return end
    value = tostring(value or "")
    local available = width - x + 1
    if maxLength then available = math.min(available, maxLength) end
    if available <= 0 then return end
    if #value > available then
        if available <= 1 then value = value:sub(1, available)
        else value = value:sub(1, available - 1) .. "~" end
    end
    setColors(gpu, foreground or COLORS.text, background or COLORS.bg)
    gpu.set(x, y, value)
end

local function panel(gpu, width, height, x, y, w, h, title, alternate)
    local background = alternate and COLORS.panelAlt or COLORS.panel
    fill(gpu, width, height, x, y, w, h, background, " ")
    if w > 2 and h > 1 then
        fill(gpu, width, height, x, y, w, 1, COLORS.header, " ")
        if title then text(gpu, width, height, x + 1, y, title, COLORS.muted, COLORS.header, w - 2) end
    end
end

local function addHit(state, kind, value, x1, y1, x2, y2)
    table.insert(state.hits, {
        kind = kind,
        value = value,
        x1 = x1,
        y1 = y1,
        x2 = x2,
        y2 = y2,
    })
end

local function trackKey(track)
    if track.key then return tostring(track.key) end
    return tostring(track.station or "?") .. ":" .. tostring(track.id or "?")
end

local function collectNodes(ctx)
    local result = {}
    for id, node in pairs(ctx.nodes or {}) do
        table.insert(result, {id = id, node = node})
    end
    table.sort(result, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return result
end

local function trackPriority(ctx, track)
    if track.friendly then return 0 end
    local state = ctx.trackState and ctx.trackState(track) or "ACTIVE"
    if state == "STALE" then return 1 end
    if ctx.closestApproach then
        local ok, approach = pcall(ctx.closestApproach, track)
        if ok and approach and approach.inbound then return 4 end
    end
    return 2
end

local function collectTracks(ctx)
    local result = {}
    for _, track in pairs(ctx.radarTracks or {}) do table.insert(result, track) end
    table.sort(result, function(a, b)
        local pa, pb = trackPriority(ctx, a), trackPriority(ctx, b)
        if pa ~= pb then return pa > pb end
        if tostring(a.station or "") ~= tostring(b.station or "") then
            return tostring(a.station or "") < tostring(b.station or "")
        end
        return tonumber(a.id or 0) < tonumber(b.id or 0)
    end)
    return result
end

local function findTrack(ctx, key)
    if not key then return nil end
    for _, track in pairs(ctx.radarTracks or {}) do
        if trackKey(track) == key then return track end
    end
    return nil
end

local function chooseSelectedTrack(ctx, state)
    local selected = findTrack(ctx, state.selectedTrack)
    if selected then return selected end
    local tracks = collectTracks(ctx)
    if #tracks > 0 then
        state.selectedTrack = trackKey(tracks[1])
        return tracks[1]
    end
    state.selectedTrack = nil
    return nil
end

local function onlineCount(ctx)
    local online, total = 0, 0
    for _, node in pairs(ctx.nodes or {}) do
        total = total + 1
        if ctx.nodeOnline and ctx.nodeOnline(node) then online = online + 1 end
    end
    return online, total
end

local function activeTrackCount(ctx)
    local active, hostile = 0, 0
    for _, track in pairs(ctx.radarTracks or {}) do
        local state = ctx.trackState and ctx.trackState(track) or "ACTIVE"
        if state ~= "STALE" then
            active = active + 1
            if not track.friendly then hostile = hostile + 1 end
        end
    end
    return active, hostile
end

local function drawHeader(ctx, state)
    local display = state.display
    local gpu, width, height = display.gpu, display.width, display.height
    fill(gpu, width, height, 1, 1, width, 4, COLORS.header, " ")

    local title = "STRATCOM // " .. PAGE_LABELS[state.page]
    text(gpu, width, height, 2, 1, title, COLORS.text, COLORS.header)

    local physical = display.blocksWide .. "x" .. display.blocksHigh
        .. "  " .. width .. "x" .. height
        .. "  " .. string.upper(display.profile)
    text(gpu, width, height, math.max(2, width - #physical), 1, physical, COLORS.muted, COLORS.header)

    local x = 2
    for index, page in ipairs(PAGE_ORDER) do
        local label = " " .. tostring(index) .. " " .. PAGE_LABELS[page] .. " "
        local bg = state.page == page and COLORS.blue or COLORS.panelAlt
        local fg = state.page == page and 0xFFFFFF or COLORS.muted
        fill(gpu, width, height, x, 2, #label, 1, bg, " ")
        text(gpu, width, height, x, 2, label, fg, bg)
        addHit(state, "page", page, x, 2, x + #label - 1, 2)
        x = x + #label + 1
    end

    local online, total = onlineCount(ctx)
    local active, hostile = activeTrackCount(ctx)
    local defenseState = ctx.defense and ctx.defense.auto and "AUTO" or "MANUAL"
    local status = string.format("NODES %d/%d   TRACKS %d   HOSTILE %d   DEFENSE %s", online, total, active, hostile, defenseState)
    text(gpu, width, height, 2, 4, status, hostile > 0 and COLORS.amber or COLORS.green, COLORS.header, width - 2)
end

local function drawFooter(state)
    local display = state.display
    local gpu, width, height = display.gpu, display.width, display.height
    local footerHeight = math.min(6, math.max(4, math.floor(height * 0.14)))
    local y = height - footerHeight + 1
    panel(gpu, width, height, 1, y, width, footerHeight, "EVENTS / CONTROLS", true)

    local available = footerHeight - 2
    local start = math.max(1, #dashboardLog - available + 1)
    local row = y + 1
    for index = start, #dashboardLog do
        text(gpu, width, height, 2, row, dashboardLog[index], COLORS.muted, COLORS.panelAlt, width - 3)
        row = row + 1
        if row >= height then break end
    end
    text(gpu, width, height, 2, height, "1-4 pages   touch enabled   Q return to STRATCOM CLI", COLORS.cyan, COLORS.header, width - 2)
    return footerHeight
end

local function threatColor(ctx, track)
    if track.friendly then return COLORS.green end
    local state = ctx.trackState and ctx.trackState(track) or "ACTIVE"
    if state == "STALE" then return COLORS.muted end
    if ctx.closestApproach then
        local ok, approach = pcall(ctx.closestApproach, track)
        if ok and approach and approach.inbound then return COLORS.red end
    end
    return COLORS.amber
end

local function drawAssetList(ctx, state, x, y, w, h)
    local gpu, width, height = state.display.gpu, state.display.width, state.display.height
    panel(gpu, width, height, x, y, w, h, "SENSORS / ASSETS")
    local nodes = collectNodes(ctx)
    local row = y + 1
    for _, entry in ipairs(nodes) do
        if row >= y + h then break end
        local node = entry.node
        local online = ctx.nodeOnline and ctx.nodeOnline(node)
        local marker = online and "+" or "-"
        local role = string.upper(tostring(node.role or "?"))
        local asset = ctx.nodeAssetSummary and ctx.nodeAssetSummary(node) or tostring(node.runtimeState or "---")
        text(gpu, width, height, x + 1, row, marker, online and COLORS.green or COLORS.red, COLORS.panel)
        text(gpu, width, height, x + 3, row, tostring(entry.id), COLORS.text, COLORS.panel, math.max(1, w - 4))
        row = row + 1
        if row >= y + h then break end
        text(gpu, width, height, x + 3, row, role .. "  " .. asset, COLORS.muted, COLORS.panel, math.max(1, w - 4))
        row = row + 1
    end
    if #nodes == 0 then text(gpu, width, height, x + 1, y + 2, "NO NODES", COLORS.muted, COLORS.panel) end
end

local function mapCenter(ctx, tracks)
    if ctx.defense and ctx.defense.protectX ~= nil and ctx.defense.protectZ ~= nil then
        return tonumber(ctx.defense.protectX) or 0, tonumber(ctx.defense.protectZ) or 0
    end
    if #tracks == 0 then return 0, 0 end
    local sx, sz, count = 0, 0, 0
    for _, track in ipairs(tracks) do
        if tonumber(track.x) and tonumber(track.z) then
            sx = sx + tonumber(track.x)
            sz = sz + tonumber(track.z)
            count = count + 1
        end
    end
    if count == 0 then return 0, 0 end
    return sx / count, sz / count
end

local function drawMap(ctx, state, x, y, w, h)
    local gpu, width, height = state.display.gpu, state.display.width, state.display.height
    panel(gpu, width, height, x, y, w, h, "TACTICAL PICTURE", true)
    if w < 8 or h < 5 then return end

    local tracks = collectTracks(ctx)
    local centerX, centerZ = mapCenter(ctx, tracks)
    local range = 256
    if ctx.defense and tonumber(ctx.defense.radius) then range = math.max(range, tonumber(ctx.defense.radius) * 1.25) end
    for _, track in ipairs(tracks) do
        local tx, tz = tonumber(track.x), tonumber(track.z)
        if tx and tz then
            local dx, dz = tx - centerX, tz - centerZ
            range = math.max(range, math.sqrt(dx * dx + dz * dz) * 1.15)
        end
    end

    local left, top = x + 1, y + 1
    local mapWidth, mapHeight = w - 2, h - 2
    local cx = left + math.floor(mapWidth / 2)
    local cy = top + math.floor(mapHeight / 2)
    text(gpu, width, height, cx, cy, "+", COLORS.blue, COLORS.panelAlt)
    if mapWidth >= 24 then text(gpu, width, height, cx + 2, cy, "PROTECTED", COLORS.muted, COLORS.panelAlt, mapWidth - math.floor(mapWidth / 2) - 2) end

    for _, track in ipairs(tracks) do
        local tx, tz = tonumber(track.x), tonumber(track.z)
        if tx and tz then
            local dx, dz = tx - centerX, tz - centerZ
            local px = cx + round((dx / range) * math.max(1, mapWidth / 2 - 2))
            local py = cy + round((dz / range) * math.max(1, mapHeight / 2 - 2))
            px = clamp(px, left, left + mapWidth - 1)
            py = clamp(py, top, top + mapHeight - 1)
            local key = trackKey(track)
            local selected = key == state.selectedTrack
            local symbol
            if selected then symbol = "@"
            elseif track.friendly then symbol = "o"
            elseif (ctx.trackState and ctx.trackState(track) == "STALE") then symbol = "."
            else symbol = "*" end
            text(gpu, width, height, px, py, symbol, selected and COLORS.cyan or threatColor(ctx, track), COLORS.panelAlt)
            addHit(state, "track", key, math.max(left, px - 1), math.max(top, py - 1), math.min(left + mapWidth - 1, px + 1), math.min(top + mapHeight - 1, py + 1))
            if mapWidth >= 34 and px + 2 <= left + mapWidth - 1 then
                text(gpu, width, height, px + 2, py, "#" .. tostring(track.id or "?"), COLORS.muted, COLORS.panelAlt, 6)
            end
        end
    end

    local scaleText = "CENTER " .. tostring(round(centerX)) .. "," .. tostring(round(centerZ)) .. "  RANGE " .. tostring(round(range))
    text(gpu, width, height, left, y + h - 1, scaleText, COLORS.muted, COLORS.panelAlt, mapWidth)
end

local function drawTrackInspector(ctx, state, x, y, w, h)
    local gpu, width, height = state.display.gpu, state.display.width, state.display.height
    panel(gpu, width, height, x, y, w, h, "SELECTED TRACK")
    local track = chooseSelectedTrack(ctx, state)
    if not track then
        text(gpu, width, height, x + 1, y + 2, "NO TRACK SELECTED", COLORS.muted, COLORS.panel, w - 2)
        return
    end

    local row = y + 1
    local function field(label, value, color)
        if row >= y + h then return end
        text(gpu, width, height, x + 1, row, label, COLORS.muted, COLORS.panel, math.max(1, w - 2))
        if row + 1 < y + h then
            text(gpu, width, height, x + 1, row + 1, tostring(value or "---"), color or COLORS.text, COLORS.panel, math.max(1, w - 2))
        end
        row = row + 2
    end

    field("TRACK", tostring(track.station or "?") .. " / #" .. tostring(track.id or "?"), COLORS.cyan)
    field("TYPE", tostring(track.typeName or track.typeId or "UNKNOWN"), threatColor(ctx, track))
    field("POSITION", string.format("%d / %d / %d", tonumber(track.x) or 0, tonumber(track.y) or 0, tonumber(track.z) or 0))
    field("SPEED", string.format("%.1f", tonumber(track.totalSpeed) or 0))
    field("HEADING", string.format("%.0f %s", tonumber(track.heading) or 0, tostring(track.headingName or "")))
    field("IFF / STATE", track.friendly and "FRIENDLY" or (ctx.trackState and ctx.trackState(track) or "ACTIVE"), track.friendly and COLORS.green or threatColor(ctx, track))

    if ctx.closestApproach and not track.friendly and row + 2 < y + h then
        local ok, approach = pcall(ctx.closestApproach, track)
        if ok and approach then
            field("CLOSEST / TCA", string.format("%.1f / %.1fs", tonumber(approach.closest) or 0, tonumber(approach.t) or 0), approach.inbound and COLORS.red or COLORS.amber)
        end
    end
end

local function drawCOP(ctx, state, bodyY, bodyHeight)
    local width = state.display.width
    if width < 90 then
        drawMap(ctx, state, 1, bodyY, width, bodyHeight)
        return
    end

    local leftWidth = math.max(20, math.floor(width * 0.22))
    local rightWidth = math.max(22, math.floor(width * 0.24))
    local centerWidth = width - leftWidth - rightWidth
    drawAssetList(ctx, state, 1, bodyY, leftWidth, bodyHeight)
    drawMap(ctx, state, leftWidth + 1, bodyY, centerWidth, bodyHeight)
    drawTrackInspector(ctx, state, leftWidth + centerWidth + 1, bodyY, rightWidth, bodyHeight)
end

local function drawTracks(ctx, state, bodyY, bodyHeight)
    local gpu, width, height = state.display.gpu, state.display.width, state.display.height
    panel(gpu, width, height, 1, bodyY, width, bodyHeight, "RADAR TRACK DATABASE")
    local row = bodyY + 1
    local header = string.format("%-8s %-10s %-14s %-17s %-7s %-7s %s", "TRACK", "STATION", "TYPE", "POSITION", "SPEED", "HDG", "STATE")
    text(gpu, width, height, 2, row, header, COLORS.muted, COLORS.panel, width - 2)
    row = row + 1

    for _, track in ipairs(collectTracks(ctx)) do
        if row >= bodyY + bodyHeight then break end
        local position = string.format("%d,%d,%d", tonumber(track.x) or 0, tonumber(track.y) or 0, tonumber(track.z) or 0)
        local stateText = track.friendly and "FRIENDLY" or (ctx.trackState and ctx.trackState(track) or "ACTIVE")
        local line = string.format(
            "#%-7s %-10s %-14s %-17s %-7.1f %-7.0f %s",
            tostring(track.id or "?"),
            tostring(track.station or "?"),
            tostring(track.typeName or track.typeId or "UNKNOWN"),
            position,
            tonumber(track.totalSpeed) or 0,
            tonumber(track.heading) or 0,
            stateText
        )
        local selected = trackKey(track) == state.selectedTrack
        local background = selected and 0x203E4A or COLORS.panel
        fill(gpu, width, height, 1, row, width, 1, background, " ")
        text(gpu, width, height, 2, row, line, selected and COLORS.cyan or threatColor(ctx, track), background, width - 2)
        addHit(state, "track", trackKey(track), 1, row, width, row)
        row = row + 1
    end
end

local function drawAssets(ctx, state, bodyY, bodyHeight)
    local gpu, width, height = state.display.gpu, state.display.width, state.display.height
    panel(gpu, width, height, 1, bodyY, width, bodyHeight, "DEFENSE / STRIKE ASSETS")
    local row = bodyY + 1
    local header = string.format("%-14s %-12s %-10s %-12s %-24s %s", "NODE", "ROLE", "RUNTIME", "STATE", "ASSET", "LINK")
    text(gpu, width, height, 2, row, header, COLORS.muted, COLORS.panel, width - 2)
    row = row + 1

    for _, entry in ipairs(collectNodes(ctx)) do
        if row >= bodyY + bodyHeight then break end
        local node = entry.node
        local online = ctx.nodeOnline and ctx.nodeOnline(node)
        local asset = ctx.nodeAssetSummary and ctx.nodeAssetSummary(node) or "---"
        local line = string.format(
            "%-14s %-12s %-10s %-12s %-24s %s",
            tostring(entry.id),
            string.upper(tostring(node.role or "?")),
            tostring(node.runtimeVersion or "---"),
            tostring(node.runtimeState or "---"),
            tostring(asset),
            online and "ONLINE" or "OFFLINE"
        )
        text(gpu, width, height, 2, row, line, online and COLORS.green or COLORS.red, COLORS.panel, width - 2)
        row = row + 1
    end
end

local function drawNetwork(ctx, state, bodyY, bodyHeight)
    local gpu, width, height = state.display.gpu, state.display.width, state.display.height
    panel(gpu, width, height, 1, bodyY, width, bodyHeight, "MESH / DISPLAY STATUS")
    local display = state.display
    local online, total = onlineCount(ctx)
    local rows = {
        "CENTRAL ID       " .. tostring(ctx.centralId or "CENTRAL"),
        "MANAGEMENT PORT  " .. tostring(ctx.mgmtPort or "---"),
        "OPERATION PORT   " .. tostring(ctx.opPort or "---"),
        "MODEM            " .. tostring(ctx.modemAddress or "---"),
        "NODES            " .. tostring(online) .. "/" .. tostring(total) .. " online",
        "PANEL            " .. display.blocksWide .. "x" .. display.blocksHigh .. " blocks",
        "RESOLUTION       " .. display.width .. "x" .. display.height,
        "PROFILE          " .. display.profile,
        "LAYOUT           responsive / physical-aspect aware",
    }
    local row = bodyY + 2
    for _, line in ipairs(rows) do
        if row >= bodyY + bodyHeight then break end
        text(gpu, width, height, 3, row, line, COLORS.text, COLORS.panel, width - 5)
        row = row + 2
    end
end

local function drawDashboard(ctx, state)
    local display = state.display
    local gpu, width, height = display.gpu, display.width, display.height
    state.hits = {}
    fill(gpu, width, height, 1, 1, width, height, COLORS.bg, " ")
    drawHeader(ctx, state)
    local footerHeight = math.min(6, math.max(4, math.floor(height * 0.14)))
    local bodyY = 5
    local bodyHeight = height - 4 - footerHeight
    if bodyHeight < 3 then bodyHeight = 3 end

    if state.page == "tracks" then
        drawTracks(ctx, state, bodyY, bodyHeight)
    elseif state.page == "assets" then
        drawAssets(ctx, state, bodyY, bodyHeight)
    elseif state.page == "network" then
        drawNetwork(ctx, state, bodyY, bodyHeight)
    else
        drawCOP(ctx, state, bodyY, bodyHeight)
    end
    drawFooter(state)
end

local function handleTouch(state, x, y)
    for index = #state.hits, 1, -1 do
        local hit = state.hits[index]
        if x >= hit.x1 and x <= hit.x2 and y >= hit.y1 and y <= hit.y2 then
            if hit.kind == "page" then state.page = hit.value
            elseif hit.kind == "track" then state.selectedTrack = hit.value end
            return true
        end
    end
    return false
end

local function restoreDisplay(display, oldWidth, oldHeight, oldForeground, oldBackground)
    if display and display.gpu then
        pcall(display.gpu.setResolution, oldWidth, oldHeight)
        pcall(display.gpu.setForeground, oldForeground)
        pcall(display.gpu.setBackground, oldBackground)
    end
    pcall(term.clear)
end

function dashboard.run(ctx, override)
    assert(type(ctx) == "table", "dashboard context is required")
    local display, reason = configureDisplay(override)
    if not display then return false, reason end

    local gpu = display.gpu
    local oldWidth, oldHeight = display.currentWidth, display.currentHeight
    local oldForeground = select(1, gpu.getForeground())
    local oldBackground = select(1, gpu.getBackground())
    local oldPrint = _G.print

    local state = {
        display = display,
        page = "cop",
        selectedTrack = nil,
        hits = {},
    }

    appendLog("Dashboard active: " .. display.blocksWide .. "x" .. display.blocksHigh
        .. " blocks / " .. display.width .. "x" .. display.height .. " / " .. display.profile)

    _G.print = function(...)
        appendLog(joinPrintArgs(...))
    end

    local ok, errorMessage = xpcall(function()
        local lastDraw = -1
        local redraw = true
        while true do
            local timestamp = computer.uptime()
            if redraw or timestamp - lastDraw >= 0.5 then
                drawDashboard(ctx, state)
                lastDraw = timestamp
                redraw = false
            end

            local signal = {event.pull(0.20)}
            local name = signal[1]
            if name == "key_down" then
                local character = tonumber(signal[3]) or 0
                if character == string.byte("q") or character == string.byte("Q") then
                    break
                elseif character >= string.byte("1") and character <= string.byte("4") then
                    state.page = PAGE_ORDER[character - string.byte("0")]
                    redraw = true
                end
            elseif name == "touch" then
                local x, y = tonumber(signal[3]), tonumber(signal[4])
                if x and y and handleTouch(state, x, y) then redraw = true end
            elseif name == "screen_resized" then
                local resized, resizeReason = configureDisplay(override)
                if resized then
                    state.display = resized
                    redraw = true
                else
                    appendLog("DISPLAY FAULT: " .. tostring(resizeReason))
                end
            elseif name == "interrupted" then
                break
            elseif name ~= nil then
                -- Network listeners/timers run through the event dispatcher. A
                -- periodic redraw keeps their live state visible without a
                -- dedicated render timer or per-frame GPU work.
                redraw = true
            end
        end
    end, debug.traceback)

    _G.print = oldPrint
    restoreDisplay(state.display or display, oldWidth, oldHeight, oldForeground, oldBackground)

    if not ok then return false, errorMessage end
    return true
end

return dashboard
