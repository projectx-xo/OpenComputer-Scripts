local component = require("component")
local event = require("event")
local computer = require("computer")
local serialization = require("serialization")

local context = nil
local radars = {}
local tracks = {}
local nextTrackId = 1
local scanTimer = nil
local lastHardwareCheck = 0

local POLL_INTERVAL = 0.25
local UPDATE_INTERVAL = 1.0
local MATCH_DISTANCE = 350
local LOST_TIMEOUT = 2.0
local RADAR_MERGE_DISTANCE = 10

local TYPE_NAMES = {
    [0] = "TIER0",
    [1] = "TIER1",
    [2] = "TIER2",
    [3] = "TIER3",
    [4] = "TIER4",
    [5] = "TIER10",
    [6] = "TIER10_15",
    [7] = "TIER15",
    [8] = "TIER15_20",
    [9] = "TIER20",
    [10] = "ANTI_BALLISTIC",
    [11] = "PLAYER",
    [12] = "ARTILLERY",
    [13] = "SPECIAL",
}

local function now()
    return computer.uptime()
end

local function typeName(typeId)
    return TYPE_NAMES[tonumber(typeId)] or ("UNKNOWN_" .. tostring(typeId))
end

local function safeCall(object, method, ...)
    if not object or object[method] == nil then
        return false, "METHOD_NOT_AVAILABLE"
    end

    local result = {pcall(object[method], ...)}
    if not result[1] then return false, result[2] end
    table.remove(result, 1)
    return true, table.unpack(result)
end

local function distance3d(x1, y1, z1, x2, y2, z2)
    local dx = x2 - x1
    local dy = y2 - y1
    local dz = z2 - z1
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function heading(dx, dz)
    if dx == 0 and dz == 0 then return 0 end
    local angle = math.deg((math.atan2 or math.atan)(dx, -dz))
    if angle < 0 then angle = angle + 360 end
    return angle
end

local function cardinal(angle)
    local directions = {"N", "NE", "E", "SE", "S", "SW", "W", "NW"}
    local index = math.floor((angle + 22.5) / 45) % 8 + 1
    return directions[index]
end

local function compatible(a, b)
    if a.typeId ~= b.typeId or a.isPlayer ~= b.isPlayer then return false end
    if a.isPlayer then
        return tostring(a.name or "") == tostring(b.name or "")
    end
    return true
end

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then return true end
    end
    return false
end

local function mergeObservation(observations, incoming)
    local best = nil
    local bestDistance = nil

    for _, existing in ipairs(observations) do
        if compatible(existing, incoming) then
            local d = distance3d(
                existing.x, existing.y, existing.z,
                incoming.x, incoming.y, incoming.z
            )
            if d <= RADAR_MERGE_DISTANCE and (not bestDistance or d < bestDistance) then
                best = existing
                bestDistance = d
            end
        end
    end

    if best then
        if not contains(best.radars, incoming.radar) then
            table.insert(best.radars, incoming.radar)
        end
        return
    end

    incoming.radars = {incoming.radar}
    incoming.radar = nil
    table.insert(observations, incoming)
end

local function radarSnapshot(entry)
    local r = entry.proxy
    local _, x, y, z = safeCall(r, "getPos")
    local _, range = safeCall(r, "getRange")
    local _, power, maxPower = safeCall(r, "getEnergyInfo")
    local _, jammed = safeCall(r, "isJammed")
    local _, missiles, shells, players, smart = safeCall(r, "getSettings")
    local _, amount = safeCall(r, "getAmount")

    return {
        address = entry.address,
        shortAddress = entry.short,
        x = tonumber(x),
        y = tonumber(y),
        z = tonumber(z),
        range = tonumber(range),
        power = tonumber(power),
        maxPower = tonumber(maxPower),
        jammed = jammed == true,
        scanMissiles = missiles == true,
        scanShells = shells == true,
        scanPlayers = players == true,
        smartMode = smart == true,
        contacts = tonumber(amount) or 0,
    }
end

local function readObservations()
    local observations = {}

    for _, radar in ipairs(radars) do
        local okAmount, amount = safeCall(radar.proxy, "getAmount")
        if okAmount then
            amount = tonumber(amount) or 0
            for index = 1, amount do
                local ok, isPlayer, x, y, z, typeId, name =
                    safeCall(radar.proxy, "getEntityAtIndex", index)

                if ok and x ~= nil then
                    mergeObservation(observations, {
                        isPlayer = isPlayer == true,
                        x = tonumber(x) or 0,
                        y = tonumber(y) or 0,
                        z = tonumber(z) or 0,
                        typeId = tonumber(typeId) or -1,
                        typeName = typeName(typeId),
                        name = name,
                        radar = radar.short,
                    })
                end
            end
        end
    end

    return observations
end

local function publicTrack(track)
    return {
        id = track.id,
        session = context.session,
        sequence = track.sequence,
        typeId = track.typeId,
        typeName = track.typeName,
        isPlayer = track.isPlayer,
        name = track.name,
        x = track.x,
        y = track.y,
        z = track.z,
        vx = track.vx,
        vy = track.vy,
        vz = track.vz,
        horizontalSpeed = track.horizontalSpeed,
        totalSpeed = track.totalSpeed,
        heading = track.heading,
        headingName = cardinal(track.heading),
        radars = track.radars,
        firstSeen = track.firstSeen,
        lastSeen = track.lastSeen,
        age = math.max(0, now() - track.firstSeen),
    }
end

local function sendTrackEvent(eventType, track)
    if not context then return end
    context.send(
        nil,
        "RADAR_TRACK",
        serialization.serialize({
            event = eventType,
            track = publicTrack(track),
        })
    )
end

local function acquireTrack(observation, timestamp)
    local id = nextTrackId
    nextTrackId = nextTrackId + 1

    local track = {
        id = id,
        sequence = 1,
        typeId = observation.typeId,
        typeName = observation.typeName,
        isPlayer = observation.isPlayer,
        name = observation.name,
        x = observation.x,
        y = observation.y,
        z = observation.z,
        vx = 0,
        vy = 0,
        vz = 0,
        horizontalSpeed = 0,
        totalSpeed = 0,
        heading = 0,
        radars = observation.radars,
        firstSeen = timestamp,
        lastSeen = timestamp,
        lastBroadcast = timestamp,
        matched = true,
    }

    tracks[id] = track
    sendTrackEvent("ACQUIRED", track)
    return track
end

local function updateTrack(track, observation, timestamp)
    local dt = timestamp - track.lastSeen
    if dt <= 0 then dt = POLL_INTERVAL end

    local oldX, oldY, oldZ = track.x, track.y, track.z
    track.x = observation.x
    track.y = observation.y
    track.z = observation.z
    track.vx = (track.x - oldX) / dt
    track.vy = (track.y - oldY) / dt
    track.vz = (track.z - oldZ) / dt
    track.horizontalSpeed = math.sqrt(track.vx * track.vx + track.vz * track.vz)
    track.totalSpeed = math.sqrt(
        track.vx * track.vx + track.vy * track.vy + track.vz * track.vz
    )
    track.heading = heading(track.vx, track.vz)
    track.radars = observation.radars
    track.lastSeen = timestamp
    track.sequence = track.sequence + 1
    track.matched = true

    if timestamp - track.lastBroadcast >= UPDATE_INTERVAL then
        sendTrackEvent("UPDATE", track)
        track.lastBroadcast = timestamp
    end
end

local function findBestTrack(observation, timestamp)
    local best = nil
    local bestDistance = nil

    for _, track in pairs(tracks) do
        if not track.matched and track.typeId == observation.typeId
            and track.isPlayer == observation.isPlayer
        then
            local nameCompatible = not track.isPlayer
                or tostring(track.name or "") == tostring(observation.name or "")

            if nameCompatible then
                local elapsed = math.max(timestamp - track.lastSeen, POLL_INTERVAL)
                local predictedX = track.x + track.vx * elapsed
                local predictedY = track.y + track.vy * elapsed
                local predictedZ = track.z + track.vz * elapsed
                local d = distance3d(
                    predictedX, predictedY, predictedZ,
                    observation.x, observation.y, observation.z
                )

                if d <= MATCH_DISTANCE and (not bestDistance or d < bestDistance) then
                    best = track
                    bestDistance = d
                end
            end
        end
    end

    return best
end

local function expireTracks(timestamp)
    local expired = {}
    for id, track in pairs(tracks) do
        if timestamp - track.lastSeen >= LOST_TIMEOUT then
            table.insert(expired, id)
        end
    end

    for _, id in ipairs(expired) do
        local track = tracks[id]
        sendTrackEvent("LOST", track)
        tracks[id] = nil
    end
end

local function scan()
    if not context then return end

    local timestamp = now()
    for _, track in pairs(tracks) do track.matched = false end

    local observations = readObservations()
    for _, observation in ipairs(observations) do
        local track = findBestTrack(observation, timestamp)
        if track then
            updateTrack(track, observation, timestamp)
        else
            acquireTrack(observation, timestamp)
        end
    end

    expireTracks(timestamp)
end

local function getStatus(detail)
    local result = {
        radarStation = true,
        radarCount = #radars,
        activeTrackCount = 0,
        radars = {},
        tracks = detail ~= "summary" and {} or nil,
    }

    for index, radar in ipairs(radars) do
        result.radars[index] = radarSnapshot(radar)
    end

    for id, track in pairs(tracks) do
        if result.tracks then result.tracks[id] = publicTrack(track) end
        result.activeTrackCount = result.activeTrackCount + 1
    end

    return result
end

local runtime = {}

function runtime.start(ctx)
    context = assert(ctx, "runtime context is required")
    radars = {}
    tracks = {}
    nextTrackId = 1
    context.session = context.session or (tostring(context.id) .. ":" .. tostring(now()) .. ":" .. tostring(math.random(100000,999999)))

    local addresses = {}
    for address in component.list("ntm_radar") do
        table.insert(addresses, address)
    end
    table.sort(addresses)

    if #addresses < 1 then
        error("No ntm_radar components detected")
    end

    for _, address in ipairs(addresses) do
        table.insert(radars, {
            address = address,
            short = address:sub(1, 8),
            proxy = component.proxy(address),
        })
    end

    if context.log then
        context.log(
            "Radar runtime started for " .. tostring(context.id)
                .. " with " .. tostring(#radars) .. " radar(s)"
        )
    end

    scanTimer = event.timer(POLL_INTERVAL, scan, math.huge)
end

function runtime.stop()
    if scanTimer then
        pcall(event.cancel, scanTimer)
        scanTimer = nil
    end
    tracks = {}
    if context and context.log then context.log("Radar runtime stopped") end
    context = nil
end

function runtime.busy()
    return false
end

function runtime.tick()
    if now() - lastHardwareCheck < 10 then return end
    local refreshed = {}
    for address in component.list("ntm_radar") do
        refreshed[#refreshed + 1] = {address=address,short=address:sub(1,8),proxy=component.proxy(address)}
    end
    radars = refreshed
    lastHardwareCheck = now()
end

function runtime.status(detail)
    return getStatus(detail)
end

function runtime.onMessage(remoteAddress, command)
    if command == "PING" then
        context.send(remoteAddress, "PONG", "radar")
        return
    end

    if command == "STATUS" then
        context.send(remoteAddress, "STATUS", serialization.serialize(getStatus()))
        return
    end

    context.send(remoteAddress, "ERROR", "UNKNOWN_COMMAND", tostring(command))
end

return runtime
