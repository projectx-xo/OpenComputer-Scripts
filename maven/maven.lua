local component = require("component")
local event = require("event")
local computer = require("computer")
local serialization = require("serialization")
local filesystem = require("filesystem")

local VERSION = "1.0.0"
local PROTOCOL = 2
local MGMT_PORT = 4510
local OP_PORT = 4511
local MARKER = "STRATCOM_NET"
local OFFLINE_AFTER = 15
local TRACK_STALE_AFTER = 10
local SEEN_TTL = 30

local args = {...}
local requestedMode = string.lower(tostring(args[1] or "auto"))

local function now()
    return computer.uptime()
end

local function loadDashboard()
    local candidates = {
        "/home/maven/dashboard.lua",
        "/home/stratcom/dashboard.lua",
        "central/dashboard.lua",
        "dashboard.lua",
    }

    for _, path in ipairs(candidates) do
        if filesystem.exists(path) then
            local ok, module = pcall(dofile, path)
            if ok and type(module) == "table" and type(module.run) == "function" then
                return module, path
            end
        end
    end

    return nil, "dashboard.lua not found"
end

local dashboard, dashboardPath = loadDashboard()
if not dashboard then
    io.stderr:write("MAVEN: " .. tostring(dashboardPath) .. ".\n")
    io.stderr:write("Place central/dashboard.lua at /home/maven/dashboard.lua and retry.\n")
    return
end

local modemAddress = component.list("modem")()
if not modemAddress then
    io.stderr:write("MAVEN: no modem detected.\n")
    return
end

local modem = component.proxy(modemAddress)
local nodes = {}
local tracks = {}
local seenMessages = {}

local function nodeOnline(node)
    return node and node.lastSeen and now() - node.lastSeen <= OFFLINE_AFTER
end

local function trackKey(station, id)
    return string.upper(tostring(station or "?")) .. ":" .. tostring(id or "?")
end

local function trackState(track)
    local node = nodes[string.upper(tostring(track.station or ""))]
    if node and not nodeOnline(node) then return "STALE" end
    if now() - (tonumber(track.lastUpdate) or 0) > TRACK_STALE_AFTER then return "STALE" end
    return "ACTIVE"
end

local function nodeAssetSummary(node)
    if node.radarStation then
        return tostring(node.activeTrackCount or 0) .. " TRACKS"
    end
    return tostring(node.runtimeState or "---")
end

local function registerNode(id, role, bootstrapVersion, runtimeVersion, runtimeState)
    if not id then return nil end
    id = string.upper(tostring(id))
    if id == "CENTRAL" then return nil end

    local node = nodes[id]
    if not node then
        node = {id = id}
        nodes[id] = node
        print("[MAVEN] Node observed: " .. id)
    end

    if role ~= nil then node.role = tostring(role) end
    if bootstrapVersion ~= nil then node.bootstrapVersion = tostring(bootstrapVersion) end
    if runtimeVersion ~= nil then node.runtimeVersion = tostring(runtimeVersion) end
    if runtimeState ~= nil then node.runtimeState = tostring(runtimeState) end
    node.lastSeen = now()
    return node
end

local function applyTrack(station, incoming)
    if type(incoming) ~= "table" or incoming.id == nil then return nil end
    local key = trackKey(station, incoming.id)
    local saved = tracks[key] or {}

    saved.key = key
    saved.station = string.upper(tostring(station))
    saved.id = incoming.id
    saved.typeId = tonumber(incoming.typeId)
    saved.typeName = incoming.typeName
    saved.isPlayer = incoming.isPlayer == true
    saved.name = incoming.name
    saved.x = tonumber(incoming.x)
    saved.y = tonumber(incoming.y)
    saved.z = tonumber(incoming.z)
    saved.vx = tonumber(incoming.vx) or 0
    saved.vy = tonumber(incoming.vy) or 0
    saved.vz = tonumber(incoming.vz) or 0
    saved.totalSpeed = tonumber(incoming.totalSpeed) or 0
    saved.heading = tonumber(incoming.heading) or 0
    saved.headingName = incoming.headingName
    saved.radars = incoming.radars or {}
    saved.lastUpdate = now()

    tracks[key] = saved
    return saved
end

local function removeStationTracks(station, keep)
    for key, track in pairs(tracks) do
        if track.station == station and not keep[key] then tracks[key] = nil end
    end
end

local function applyStatus(node, status)
    if not node or type(status) ~= "table" then return end

    node.lastSeen = now()
    node.radarStation = status.radarStation == true
    node.radarCount = tonumber(status.radarCount) or node.radarCount
    node.activeTrackCount = tonumber(status.activeTrackCount) or node.activeTrackCount

    if node.radarStation and type(status.tracks) == "table" then
        local keep = {}
        for _, incoming in pairs(status.tracks) do
            local saved = applyTrack(node.id, incoming)
            if saved then keep[saved.key] = true end
        end
        removeStationTracks(node.id, keep)
    end
end

local function handleTrackMessage(node, encoded)
    local ok, message = pcall(serialization.unserialize, encoded)
    if not ok or type(message) ~= "table" or type(message.track) ~= "table" then return end

    local eventType = string.upper(tostring(message.event or ""))
    local key = trackKey(node.id, message.track.id)
    if eventType == "LOST" then
        tracks[key] = nil
        print("[MAVEN] Track lost: " .. key)
    elseif eventType == "ACQUIRED" or eventType == "UPDATE" then
        local track = applyTrack(node.id, message.track)
        if eventType == "ACQUIRED" and track then
            print("[MAVEN] Track acquired: " .. key .. " " .. tostring(track.typeName or "UNKNOWN"))
        end
    end
end

local function pruneSeen()
    local cutoff = now() - SEEN_TTL
    for id, timestamp in pairs(seenMessages) do
        if timestamp < cutoff then seenMessages[id] = nil end
    end
end

local function validEnvelope(envelope)
    return type(envelope) == "table"
        and envelope.protocol == PROTOCOL
        and type(envelope.id) == "string"
        and type(envelope.source) == "string"
        and type(envelope.kind) == "string"
        and type(envelope.payload) == "table"
end

local function observeEnvelope(envelope)
    if not validEnvelope(envelope) then return end
    if seenMessages[envelope.id] then return end
    seenMessages[envelope.id] = now()

    local source = string.upper(tostring(envelope.source))
    local payload = envelope.payload

    if envelope.kind == "BOOT_HELLO" or envelope.kind == "BOOT_HEARTBEAT" then
        registerNode(source, payload[2], payload[3], payload[4], payload[5])
        return
    end

    local node = nodes[source]
    if source ~= "CENTRAL" and not node then node = registerNode(source, "unknown") end
    if node then node.lastSeen = now() end

    if envelope.kind == "RUNTIME" and node then
        local responseType = tostring(payload[1] or "")
        if responseType == "STATUS" then
            local ok, status = pcall(serialization.unserialize, payload[2])
            if ok and type(status) == "table" then applyStatus(node, status) end
        elseif responseType == "RADAR_TRACK" then
            handleTrackMessage(node, payload[2])
        end
    end
end

local function onModemMessage(_, _, _, port, _, marker, encoded)
    if (port ~= MGMT_PORT and port ~= OP_PORT) or marker ~= MARKER then return end
    local ok, envelope = pcall(serialization.unserialize, encoded)
    if ok then observeEnvelope(envelope) end
    pruneSeen()
end

modem.open(MGMT_PORT)
modem.open(OP_PORT)
event.listen("modem_message", onModemMessage)

print("MAVEN v" .. VERSION .. " // responsive STRATCOM telemetry")
print("Renderer: " .. dashboardPath)

local context = {
    applicationName = "MAVEN",
    version = VERSION,
    centralId = "STRATCOM",
    nodes = nodes,
    radarTracks = tracks,
    defense = {},
    nodeOnline = nodeOnline,
    trackState = trackState,
    nodeAssetSummary = nodeAssetSummary,
    modemAddress = modemAddress,
    mgmtPort = MGMT_PORT,
    opPort = OP_PORT,
}

local success, reason = dashboard.run(context, requestedMode)

event.ignore("modem_message", onModemMessage)
modem.close(OP_PORT)
modem.close(MGMT_PORT)

if not success then
    io.stderr:write("MAVEN dashboard failed: " .. tostring(reason) .. "\n")
end
