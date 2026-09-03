local component = require("component")
local event = require("event")
local computer = require("computer")
local term = require("term")
local shell = require("shell")
local filesystem = require("filesystem")
local serialization = require("serialization")

local VERSION = "2.4.1"
local PROTOCOL = 2
local CENTRAL_ID = "CENTRAL"
local DEFAULT_TTL = 6
local SEEN_TTL = 30
local PRUNE_INTERVAL = 10

local BASE_URL = "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/main/"
local SCRIPT_PATH = "/home/stratcom/central.lua"
local TMP_VERSION = "/tmp/stratcom-central-version.txt"
local TMP_SCRIPT = "/tmp/stratcom-central.lua"
local REPOSITORY_DIR = "/home/stratcom/repository"
local MANIFEST_PATH = REPOSITORY_DIR .. "/manifest.lua"
local TMP_MANIFEST = "/tmp/stratcom-runtime-manifest.lua"
local PAYLOAD_DB_PATH = "/home/stratcom/payloads.db"

local MGMT_PORT = 4510
local OP_PORT = 4511
local OFFLINE_AFTER = 15
local RECONCILE_INTERVAL = 10
local STATUS_INTERVAL = 5
local CHUNK_SIZE = 2048
local DEPLOY_TIMEOUT = 3
local DEPLOY_MAX_RETRIES = 4
local RADAR_TRACK_STALE_AFTER = 10

local ABM_NODE_ID = "ABM-A1"
local ABM_MISSILE_ID = "hbm:item.missile_anti-ballistic"
local DEFENSE_CONFIRM_SAMPLES = 3
local DEFENSE_MAX_TCA = 120
local DEFENSE_LEAD_SECONDS = 2
local DEFENSE_POST_LAUNCH_TIMEOUT = 8
local DEFENSE_REENGAGE_COOLDOWN = 10

local VALID_CLASSES = {
    nuclear = true,
    conventional = true,
    bunker = true,
    special = true,
    unknown = true,
}

local RADAR_TYPE_NAMES = {
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

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parseVersion(value)
    local a, b, c = trim(value):match("^(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return tonumber(a), tonumber(b), tonumber(c)
end

local function isNewer(remote, localVersion)
    local ra, rb, rc = parseVersion(remote)
    local la, lb, lc = parseVersion(localVersion)
    if not ra or not la then return false end
    if ra ~= la then return ra > la end
    if rb ~= lb then return rb > lb end
    return rc > lc
end

local function cacheBust(url)
    local token = tostring(math.floor(computer.uptime() * 1000))
        .. "-" .. tostring(math.random(100000, 999999))
    local separator = url:find("?", 1, true) and "&" or "?"
    return url .. separator .. "cb=" .. token
end

local function download(url, path)
    if filesystem.exists(path) then filesystem.remove(path) end
    local ok = shell.execute('wget -f "' .. cacheBust(url) .. '" "' .. path .. '"')
    return ok and filesystem.exists(path)
end

local function readFirstLine(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local value = file:read("*l")
    file:close()
    return value
end

local function readAll(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function checkForUpdates()
    print("[UPDATE] Checking central software...")
    if not download(BASE_URL .. "central/version.txt", TMP_VERSION) then
        print("[UPDATE] GitHub unavailable; continuing with v" .. VERSION)
        return false
    end

    local remoteVersion = trim(readFirstLine(TMP_VERSION))
    if not isNewer(remoteVersion, VERSION) then
        print("[UPDATE] Central version: " .. VERSION)
        return false
    end

    print("[UPDATE] Central v" .. remoteVersion .. " available; downloading...")
    if not download(BASE_URL .. "central/central.lua", TMP_SCRIPT) then
        print("[UPDATE] Download failed; continuing with v" .. VERSION)
        return false
    end

    local backup = SCRIPT_PATH .. ".bak"
    if filesystem.exists(backup) then filesystem.remove(backup) end
    if filesystem.exists(SCRIPT_PATH) then filesystem.rename(SCRIPT_PATH, backup) end

    if not filesystem.rename(TMP_SCRIPT, SCRIPT_PATH) then
        if filesystem.exists(backup) then filesystem.rename(backup, SCRIPT_PATH) end
        print("[UPDATE] Install failed; restored previous central version")
        return false
    end

    print("[UPDATE] Installed central v" .. remoteVersion .. "; rebooting...")
    os.sleep(1)
    computer.shutdown(true)
    return true
end

checkForUpdates()

if not filesystem.exists(REPOSITORY_DIR) then filesystem.makeDirectory(REPOSITORY_DIR) end

local modemAddress = component.list("modem")()
if not modemAddress then
    io.stderr:write("FATAL: No modem detected.\n")
    return
end

local modem = component.proxy(modemAddress)
local nodes = {}
local desiredRuntimes = {}
local payloadCatalog = {}
local radarTracks = {}
local engagementHistory = {}
local activeEngagements = {}
local pendingArm = nil
local running = true
local messageCounter = 0
local seenMessages = {}
local lastPrune = 0

local defense = {
    auto = false,
    protectX = nil,
    protectZ = nil,
    radius = nil,
}

local function now()
    return computer.uptime()
end

local function stateText(value)
    if value == nil then return "---" end
    return value and "YES" or "NO"
end

local function percent(current, maximum)
    if not current or not maximum or maximum <= 0 then return nil end
    return math.floor((current / maximum) * 100)
end

local function clip(value, maxLength)
    value = tostring(value or "")
    if value == "" or value == "nil" then return "---" end
    if #value <= maxLength then return value end
    return value:sub(1, maxLength - 1) .. "~"
end

local function radarTypeName(typeId)
    return RADAR_TYPE_NAMES[tonumber(typeId)] or ("UNKNOWN_" .. tostring(typeId))
end

local function nodeOnline(node)
    return node and node.lastSeen and now() - node.lastSeen <= OFFLINE_AFTER
end

local function getNode(id)
    return nodes[string.upper(id or "")]
end

local function loadPayloadCatalog()
    payloadCatalog = {
        ["hbm:item.missile_drill"] = {class = "bunker", name = "Bunker Buster"},
    }

    local raw = readAll(PAYLOAD_DB_PATH)
    if raw then
        local ok, saved = pcall(serialization.unserialize, raw)
        if ok and type(saved) == "table" then
            for itemId, entry in pairs(saved) do
                if type(entry) == "table" and VALID_CLASSES[tostring(entry.class)] then
                    payloadCatalog[itemId] = entry
                end
            end
        end
    end
end

local function savePayloadCatalog()
    local ok, raw = pcall(serialization.serialize, payloadCatalog)
    if not ok then return false end
    local file = io.open(PAYLOAD_DB_PATH, "w")
    if not file then return false end
    file:write(raw)
    file:close()
    return true
end

local function payloadClass(itemId)
    local entry = payloadCatalog[tostring(itemId or "")]
    return entry and tostring(entry.class) or "unknown"
end

local function nextMessageId()
    messageCounter = messageCounter + 1
    return table.concat({
        CENTRAL_ID,
        tostring(math.floor(now() * 1000)),
        tostring(messageCounter),
        tostring(math.random(100000, 999999)),
    }, "-")
end

local function pruneSeen()
    local cutoff = now() - SEEN_TTL
    for id, timestamp in pairs(seenMessages) do
        if timestamp < cutoff then seenMessages[id] = nil end
    end
    lastPrune = now()
end

local function validEnvelope(envelope)
    return type(envelope) == "table"
        and envelope.protocol == PROTOCOL
        and type(envelope.id) == "string"
        and type(envelope.source) == "string"
        and type(envelope.destination) == "string"
        and type(envelope.kind) == "string"
        and type(envelope.ttl) == "number"
        and type(envelope.payload) == "table"
end

local function transmitEnvelope(port, envelope)
    local ok, encoded = pcall(serialization.serialize, envelope)
    if not ok then return false end
    modem.broadcast(port, "STRATCOM_NET", encoded)
    return true
end

local function originate(port, destination, kind, payload, ttl)
    local envelope = {
        protocol = PROTOCOL,
        id = nextMessageId(),
        source = CENTRAL_ID,
        destination = string.upper(tostring(destination)),
        ttl = tonumber(ttl) or DEFAULT_TTL,
        kind = tostring(kind),
        payload = payload or {},
    }
    seenMessages[envelope.id] = now()
    return transmitEnvelope(port, envelope)
end

local function sendMgmt(node, command, ...)
    if not node then return false end
    return originate(MGMT_PORT, node.id, "MGMT", {command, ...})
end

local function sendOperational(node, command, ...)
    if not node or not nodeOnline(node) then return false end
    return originate(OP_PORT, node.id, "CMD", {command, ...})
end

local function syncRepository()
    print("[REPO] Syncing runtime repository from GitHub...")
    if download(BASE_URL .. "runtime/manifest.lua", TMP_MANIFEST) then
        local chunk, err = loadfile(TMP_MANIFEST)
        if not chunk then
            print("[REPO] Invalid remote manifest: " .. tostring(err))
            filesystem.remove(TMP_MANIFEST)
        else
            if filesystem.exists(MANIFEST_PATH) then filesystem.remove(MANIFEST_PATH) end
            filesystem.rename(TMP_MANIFEST, MANIFEST_PATH)
        end
    elseif not filesystem.exists(MANIFEST_PATH) then
        print("[REPO] No remote or cached manifest available.")
        return false
    else
        print("[REPO] GitHub unavailable; using cached manifest.")
    end

    local ok, manifest = pcall(dofile, MANIFEST_PATH)
    if not ok or type(manifest) ~= "table" or type(manifest.roles) ~= "table" then
        print("[REPO] Failed to load runtime manifest.")
        return false
    end

    desiredRuntimes = {}
    local loaded = {}
    for role, entry in pairs(manifest.roles) do
        if type(entry) == "table" and entry.version and entry.path then
            local localPath = REPOSITORY_DIR .. "/" .. tostring(role) .. ".lua"
            if not loaded[entry.path] then
                if not download(BASE_URL .. entry.path, localPath) then
                    if not filesystem.exists(localPath) then
                        print("[REPO] Missing runtime for role " .. tostring(role))
                        localPath = nil
                    else
                        print("[REPO] Using cached runtime for " .. tostring(role))
                    end
                end
                loaded[entry.path] = localPath
            else
                local source = loaded[entry.path]
                if source and source ~= localPath then
                    local data = readAll(source)
                    if data then
                        local f = io.open(localPath, "w")
                        if f then f:write(data); f:close() end
                    end
                end
            end

            if localPath and filesystem.exists(localPath) then
                desiredRuntimes[role] = {version = tostring(entry.version), path = localPath}
                print("[REPO] " .. tostring(role) .. " -> " .. tostring(entry.version))
            end
        end
    end
    return true
end

local function requestRuntimeStatus(node)
    if not node or not nodeOnline(node) or not node.claimed then return false end
    if node.runtimeState ~= "running" or node.deploying then return false end
    node.lastStatusRequest = now()
    return sendOperational(node, "STATUS")
end

local function pollRuntimeStatus()
    for _, node in pairs(nodes) do
        if nodeOnline(node) and node.claimed and node.runtimeState == "running" and not node.deploying then
            requestRuntimeStatus(node)
        end
    end
end

local function registerNode(id, role, bootstrapVersion, runtimeVersion, runtimeState)
    if not id then return nil end
    id = string.upper(tostring(id))
    local node = nodes[id]
    local discovered = false

    if not node then
        node = {id = id, firstSeen = now(), claimed = false, deploying = false}
        nodes[id] = node
        discovered = true
    end

    node.role = tostring(role or node.role or "unknown")
    node.bootstrapVersion = tostring(bootstrapVersion or node.bootstrapVersion or "unknown")
    node.runtimeVersion = tostring(runtimeVersion or node.runtimeVersion or "none")
    node.runtimeState = tostring(runtimeState or node.runtimeState or "unknown")
    node.lastSeen = now()

    if discovered then
        print("")
        print("[NET] Bootstrap discovered: " .. id .. " (" .. node.role .. ")")
    end
    if not node.claimed then sendMgmt(node, "CLAIM") end
    return node
end

local function deploymentChunk(deployment, index)
    local startIndex = ((index - 1) * CHUNK_SIZE) + 1
    return deployment.data:sub(startIndex, startIndex + CHUNK_SIZE - 1)
end

local function failDeployment(node, reason)
    if not node or not node.deploying then return end
    print("[DEPLOY] " .. node.id .. " FAILED: " .. tostring(reason))
    node.deploying = false
    node.deployment = nil
    sendMgmt(node, "DEPLOY_ABORT")
    sendMgmt(node, "START")
end

local function sendDeploymentStep(node, retrying)
    local deployment = node and node.deployment
    if not deployment then return false end

    if retrying then
        deployment.retries = deployment.retries + 1
        if deployment.retries > DEPLOY_MAX_RETRIES then
            failDeployment(node, "TIMEOUT_" .. tostring(deployment.phase))
            return false
        end
        print("[DEPLOY] " .. node.id .. " retry " .. deployment.retries
            .. "/" .. DEPLOY_MAX_RETRIES .. " (" .. deployment.phase .. ")")
    else
        deployment.retries = 0
    end

    if deployment.phase == "begin" then
        sendMgmt(node, "DEPLOY_BEGIN", deployment.version, deployment.totalChunks)
    elseif deployment.phase == "chunk" then
        local index = deployment.nextChunk
        sendMgmt(node, "DEPLOY_CHUNK", index, deploymentChunk(deployment, index))
    elseif deployment.phase == "commit" then
        sendMgmt(node, "DEPLOY_COMMIT", deployment.version)
    else
        failDeployment(node, "INVALID_PHASE")
        return false
    end

    deployment.lastSent = now()
    return true
end

local function deployNode(node)
    if not node or node.deploying or not node.claimed then return false end
    local desired = desiredRuntimes[node.role]
    if not desired then
        print("[DEPLOY] No runtime configured for role " .. tostring(node.role))
        return false
    end

    local data = readAll(desired.path)
    if not data then
        print("[DEPLOY] Cannot read runtime file for " .. node.id)
        return false
    end

    local totalChunks = math.max(1, math.ceil(#data / CHUNK_SIZE))
    node.deploying = true
    node.deployment = {
        version = desired.version,
        data = data,
        totalChunks = totalChunks,
        nextChunk = 1,
        phase = "begin",
        retries = 0,
        lastSent = 0,
    }

    print("[DEPLOY] " .. node.id .. " <- " .. desired.version
        .. " (" .. totalChunks .. " chunks, ACK mode)")
    return sendDeploymentStep(node, false)
end

local function checkDeploymentTimeouts()
    for _, node in pairs(nodes) do
        local deployment = node.deployment
        if node.deploying and deployment and deployment.lastSent > 0
            and now() - deployment.lastSent >= DEPLOY_TIMEOUT
        then
            sendDeploymentStep(node, true)
        end
    end
end

local function reconcileNode(node, force)
    if not node or not node.claimed or not nodeOnline(node) or node.deploying then return end
    if not force and node.lastReconcile and now() - node.lastReconcile < RECONCILE_INTERVAL then return end

    node.lastReconcile = now()
    local desired = desiredRuntimes[node.role]
    if not desired then return end

    if tostring(node.runtimeVersion) ~= tostring(desired.version) then
        deployNode(node)
    elseif node.runtimeState ~= "running" then
        print("[MGMT] Starting runtime on " .. node.id)
        sendMgmt(node, "START")
    else
        requestRuntimeStatus(node)
    end
end

local function reconcileAll(force)
    for _, node in pairs(nodes) do reconcileNode(node, force) end
end

local function radarTrackKey(nodeId, trackId)
    return string.upper(tostring(nodeId)) .. ":" .. tostring(trackId)
end

local function applyRadarTrack(node, track)
    if not node or type(track) ~= "table" or track.id == nil then return nil end
    local key = radarTrackKey(node.id, track.id)
    local previous = radarTracks[key]
    radarTracks[key] = {
        key = key,
        station = node.id,
        id = track.id,
        typeId = tonumber(track.typeId),
        typeName = track.typeName or radarTypeName(track.typeId),
        isPlayer = track.isPlayer == true,
        name = track.name,
        x = tonumber(track.x),
        y = tonumber(track.y),
        z = tonumber(track.z),
        vx = tonumber(track.vx) or 0,
        vy = tonumber(track.vy) or 0,
        vz = tonumber(track.vz) or 0,
        horizontalSpeed = tonumber(track.horizontalSpeed) or 0,
        totalSpeed = tonumber(track.totalSpeed) or 0,
        heading = tonumber(track.heading) or 0,
        headingName = track.headingName,
        radars = track.radars or {},
        age = tonumber(track.age) or 0,
        lastUpdate = now(),
        threatSamples = previous and previous.threatSamples or 0,
        lastEngaged = previous and previous.lastEngaged or nil,
    }
    return radarTracks[key]
end

local function applyRadarStatus(node, status)
    node.radarStation = true
    node.radarCount = tonumber(status.radarCount) or 0
    node.activeTrackCount = tonumber(status.activeTrackCount) or 0
    node.radars = status.radars or {}

    local seen = {}
    if type(status.tracks) == "table" then
        for _, track in pairs(status.tracks) do
            local saved = applyRadarTrack(node, track)
            if saved then seen[saved.key] = true end
        end
    end

    for key, track in pairs(radarTracks) do
        if track.station == node.id and not seen[key] then
            radarTracks[key] = nil
        end
    end
end

local function applyRuntimeStatus(node, status)
    if not node or type(status) ~= "table" then return end

    if status.radarStation == true then
        applyRadarStatus(node, status)
        node.lastStatus = now()
        return
    end

    node.multiLauncher = status.multiLauncher == true
    node.launcherCount = status.launcherCount
    node.launchers = status.launchers
    node.readyCount = status.readyCount
    node.armedCount = status.armedCount
    node.armed = status.armed
    node.ready = status.ready
    node.tier = status.tier
    node.energy = status.energy
    node.maxEnergy = status.maxEnergy
    node.fuel = status.fuel
    node.fuelMax = status.fuelMax
    node.fuelType = status.fuelType
    node.oxidizer = status.oxidizer
    node.oxidizerMax = status.oxidizerMax
    node.oxidizerType = status.oxidizerType
    node.missileName = status.missileName
    node.missileLabel = status.missileLabel
    node.missileCount = status.missileCount
    node.inventorySide = status.inventorySide
    node.lastStatus = now()
end

local function defenseZoneConfigured()
    return defense.protectX ~= nil and defense.protectZ ~= nil
        and defense.radius ~= nil and defense.radius > 0
end

local function automaticThreatType(track)
    local typeId = tonumber(track and track.typeId)
    return typeId ~= nil and typeId >= 0 and typeId <= 9
end

local function closestApproach(track)
    if not defenseZoneConfigured() then return nil end
    local x = tonumber(track.x)
    local z = tonumber(track.z)
    local vx = tonumber(track.vx) or 0
    local vz = tonumber(track.vz) or 0
    if not x or not z then return nil end

    local speed2 = vx * vx + vz * vz
    if speed2 < 1 then return nil end

    local rx = x - defense.protectX
    local rz = z - defense.protectZ
    local t = -((rx * vx) + (rz * vz)) / speed2
    if t <= 0 or t > DEFENSE_MAX_TCA then return nil end

    local cx = x + vx * t
    local cz = z + vz * t
    local dx = cx - defense.protectX
    local dz = cz - defense.protectZ
    local closest = math.sqrt(dx * dx + dz * dz)

    return {
        t = t,
        closest = closest,
        projectedX = cx,
        projectedZ = cz,
        inbound = closest <= defense.radius,
    }
end

local function abmReady()
    local node = getNode(ABM_NODE_ID)
    if not node then return false, "ABM_NODE_NOT_DISCOVERED" end
    if not nodeOnline(node) then return false, "ABM_OFFLINE" end
    if node.runtimeState ~= "running" then return false, "ABM_RUNTIME_NOT_RUNNING" end
    if node.ready ~= true then return false, "ABM_NOT_READY" end
    if tostring(node.missileName or "") ~= ABM_MISSILE_ID then
        return false, "WRONG_ABM_PAYLOAD"
    end
    return true, node
end

local function historyPush(entry)
    table.insert(engagementHistory, entry)
    while #engagementHistory > 30 do table.remove(engagementHistory, 1) end
end

local function finishEngagement(engagement, state, detail)
    if not engagement then return end
    engagement.state = state
    engagement.detail = detail
    engagement.finishedAt = now()
    activeEngagements[engagement.trackKey] = nil
    if pendingArm == engagement then pendingArm = nil end
    historyPush(engagement)
    print("[DEFENSE] " .. state .. " " .. engagement.trackKey
        .. (detail and (" - " .. tostring(detail)) or ""))
end

local function launchPendingEngagement()
    local engagement = pendingArm
    if not engagement or engagement.state ~= "ARMING" then return end

    local node = getNode(ABM_NODE_ID)
    if not nodeOnline(node) then
        finishEngagement(engagement, "ABORTED", "ABM_OFFLINE_AFTER_ARM")
        return
    end

    engagement.state = "LAUNCHING"
    engagement.launchSentAt = now()
    print("[DEFENSE] " .. ABM_NODE_ID .. " engaging " .. engagement.trackKey
        .. " target X=" .. math.floor(engagement.targetX + 0.5)
        .. " Z=" .. math.floor(engagement.targetZ + 0.5))
    sendOperational(node, "LAUNCH", engagement.targetX, engagement.targetZ)
end

local function createEngagement(track, approach)
    local ok, nodeOrReason = abmReady()
    if not ok then
        track.lastDefenseHoldReason = nodeOrReason
        return false
    end
    if pendingArm then
        track.lastDefenseHoldReason = "ABM_BUSY"
        return false
    end

    local targetX = track.x + (track.vx or 0) * DEFENSE_LEAD_SECONDS
    local targetZ = track.z + (track.vz or 0) * DEFENSE_LEAD_SECONDS
    local engagement = {
        trackKey = track.key,
        station = track.station,
        trackId = track.id,
        typeId = track.typeId,
        typeName = track.typeName,
        state = "ARMING",
        createdAt = now(),
        targetX = targetX,
        targetZ = targetZ,
        closestApproach = approach.closest,
        timeToClosest = approach.t,
        abmNode = ABM_NODE_ID,
    }

    activeEngagements[track.key] = engagement
    pendingArm = engagement
    track.lastEngaged = now()
    print("[DEFENSE] Threat confirmed " .. track.key
        .. " " .. tostring(track.typeName)
        .. " closest=" .. string.format("%.1f", approach.closest)
        .. " tca=" .. string.format("%.1fs", approach.t))
    sendOperational(nodeOrReason, "ARM")
    return true
end

local function evaluateTrackForDefense(track)
    if not defense.auto or not defenseZoneConfigured() then
        track.threatSamples = 0
        return
    end

    if not automaticThreatType(track) then
        track.threatSamples = 0
        return
    end

    local approach = closestApproach(track)
    if not approach or not approach.inbound then
        track.threatSamples = 0
        return
    end

    track.threatSamples = (track.threatSamples or 0) + 1
    if track.threatSamples < DEFENSE_CONFIRM_SAMPLES then return end

    if activeEngagements[track.key] then return end
    if track.lastEngaged and now() - track.lastEngaged < DEFENSE_REENGAGE_COOLDOWN then return end

    createEngagement(track, approach)
end

local function defenseTick()
    if defense.auto then
        for _, track in pairs(radarTracks) do
            evaluateTrackForDefense(track)
        end
    end

    for key, engagement in pairs(activeEngagements) do
        if engagement.state == "FIRED"
            and engagement.firedAt
            and now() - engagement.firedAt >= DEFENSE_POST_LAUNCH_TIMEOUT
        then
            local track = radarTracks[key]
            if track then
                finishEngagement(engagement, "MISS", "TRACK_STILL_ACTIVE")
                track.lastEngaged = now()
            end
        elseif engagement.state == "ARMING" and now() - engagement.createdAt > 5 then
            finishEngagement(engagement, "ABORTED", "ARM_TIMEOUT")
        elseif engagement.state == "LAUNCHING"
            and engagement.launchSentAt
            and now() - engagement.launchSentAt > 5
        then
            finishEngagement(engagement, "ABORTED", "LAUNCH_TIMEOUT")
        end
    end
end

local function handleTrackLostForDefense(key)
    local engagement = activeEngagements[key]
    if not engagement then return end

    if engagement.state == "FIRED" or engagement.state == "LAUNCHING" then
        finishEngagement(engagement, "TRACK_LOST", "POSSIBLE_INTERCEPT")
    elseif engagement.state == "ARMING" then
        finishEngagement(engagement, "ABORTED", "TRACK_LOST_BEFORE_LAUNCH")
    end
end

local function handleMgmtEnvelope(envelope)
    local source = string.upper(envelope.source)
    local payload = envelope.payload

    if envelope.kind == "BOOT_HELLO" or envelope.kind == "BOOT_HEARTBEAT" then
        local node = registerNode(source, payload[2], payload[3], payload[4], payload[5])
        if node and node.claimed then reconcileNode(node, false) end
        return
    end

    local node = getNode(source)
    if not node then return end
    node.lastSeen = now()

    if envelope.kind == "MGMT_ACK" then
        local command = tostring(payload[1])
        local success = payload[2]
        local detail = payload[3]

        if command == "CLAIM" and success then
            node.claimed = true
            print("[MGMT] Claimed " .. node.id)
            reconcileNode(node, true)
        elseif command == "DEPLOY_BEGIN" and success then
            local d = node.deployment
            if node.deploying and d and d.phase == "begin" then
                print("[DEPLOY] " .. node.id .. " begin ACK")
                d.phase = "chunk"
                d.nextChunk = 1
                sendDeploymentStep(node, false)
            end
        elseif command == "DEPLOY_CHUNK" and success then
            local d = node.deployment
            local acknowledged = tonumber(detail)
            if node.deploying and d and d.phase == "chunk" and acknowledged == d.nextChunk then
                print("[DEPLOY] " .. node.id .. " chunk " .. acknowledged .. "/" .. d.totalChunks .. " ACK")
                if acknowledged >= d.totalChunks then d.phase = "commit" else d.nextChunk = acknowledged + 1 end
                sendDeploymentStep(node, false)
            end
        elseif command == "START" then
            if success then
                node.runtimeState = "running"
                event.timer(0.5, function() requestRuntimeStatus(node) end, 1)
            end
            print("[MGMT] " .. node.id .. " START -> " .. tostring(success) .. " " .. tostring(detail or ""))
        elseif command == "STOP" then
            if success then node.runtimeState = "stopped" end
            print("[MGMT] " .. node.id .. " STOP -> " .. tostring(success))
        elseif command == "RESTART" then
            if success then
                node.runtimeState = "running"
                event.timer(0.5, function() requestRuntimeStatus(node) end, 1)
            end
            print("[MGMT] " .. node.id .. " RESTART -> " .. tostring(success) .. " " .. tostring(detail or ""))
        end
    elseif envelope.kind == "MGMT_DEPLOY_RESULT" then
        local success = payload[1]
        local version = tostring(payload[2] or "unknown")
        local detail = payload[3]
        node.deploying = false
        node.deployment = nil

        if success then
            node.runtimeVersion = version
            node.runtimeState = "stopped"
            print("[DEPLOY] " .. node.id .. " installed " .. version)
            sendMgmt(node, "START")
        else
            print("[DEPLOY] " .. node.id .. " FAILED: " .. tostring(detail))
            sendMgmt(node, "START")
        end
    elseif envelope.kind == "MGMT_ERROR" then
        failDeployment(node, tostring(payload[1]) .. ": " .. tostring(payload[2]))
    elseif envelope.kind == "BOOT_INFO" then
        local ok, info = pcall(serialization.unserialize, payload[1])
        if ok and type(info) == "table" then
            node.bootstrapVersion = info.bootstrapVersion or node.bootstrapVersion
            node.runtimeVersion = info.runtimeVersion or node.runtimeVersion
            node.runtimeState = info.runtimeState or node.runtimeState
        end
    end
end

local function handleRadarTrackEvent(node, encoded)
    local ok, message = pcall(serialization.unserialize, encoded)
    if not ok or type(message) ~= "table" or type(message.track) ~= "table" then
        print("[RADAR ERROR] Invalid track event from " .. node.id)
        return
    end

    local eventType = string.upper(tostring(message.event or ""))
    local track = message.track
    local key = radarTrackKey(node.id, track.id)

    if eventType == "LOST" then
        local existing = radarTracks[key] or applyRadarTrack(node, track)
        if existing then
            print("[RADAR] " .. node.id .. " TRACK #" .. tostring(track.id)
                .. " LOST " .. tostring(existing.typeName)
                .. " @ " .. tostring(existing.x) .. "," .. tostring(existing.y) .. "," .. tostring(existing.z))
        end
        handleTrackLostForDefense(key)
        radarTracks[key] = nil
    elseif eventType == "ACQUIRED" or eventType == "UPDATE" then
        local saved = applyRadarTrack(node, track)
        if eventType == "ACQUIRED" and saved then
            print("[RADAR] " .. node.id .. " TRACK #" .. tostring(track.id)
                .. " ACQUIRED " .. tostring(saved.typeName)
                .. " @ " .. tostring(saved.x) .. "," .. tostring(saved.y) .. "," .. tostring(saved.z))
        end
        if saved then evaluateTrackForDefense(saved) end
    end

    local count = 0
    for _, active in pairs(radarTracks) do
        if active.station == node.id then count = count + 1 end
    end
    node.activeTrackCount = count
end

local function handleRuntimeEnvelope(envelope)
    local node = getNode(envelope.source)
    if not node then return end

    local payload = envelope.payload
    local responseType = tostring(payload[1] or "")
    node.lastSeen = now()

    if responseType == "STATUS" then
        local ok, status = pcall(serialization.unserialize, payload[2])
        if ok and type(status) == "table" then applyRuntimeStatus(node, status) end
    elseif responseType == "RADAR_TRACK" then
        handleRadarTrackEvent(node, payload[2])
    elseif responseType == "ACK" then
        local command = tostring(payload[2] or "")
        local success = payload[3]
        print("[ACK] " .. node.id .. " " .. command .. " -> " .. tostring(success))

        if node.id == ABM_NODE_ID and command == "ARM" and pendingArm then
            if success == true then
                launchPendingEngagement()
            else
                finishEngagement(pendingArm, "ABORTED", "ARM_REJECTED")
            end
        end
        requestRuntimeStatus(node)
    elseif responseType == "ERROR" then
        local code = tostring(payload[2])
        print("[ERROR] " .. node.id .. ": " .. code)
        if node.id == ABM_NODE_ID and pendingArm then
            finishEngagement(pendingArm, "ABORTED", code)
        end
    elseif responseType == "LAUNCH_RESULT" then
        if node.id == ABM_NODE_ID and pendingArm then
            local success = payload[2] == true
            local engagement = pendingArm
            pendingArm = nil
            if success then
                engagement.state = "FIRED"
                engagement.firedAt = now()
                engagement.launchResult = "SUCCESS"
                print("[DEFENSE] ABM fired for " .. engagement.trackKey)
            else
                finishEngagement(engagement, "FAILED", "ABM_LAUNCH_FAILED")
            end
        else
            print("[LAUNCH] " .. node.id .. " success=" .. tostring(payload[2])
                .. " a=" .. tostring(payload[3]) .. " b=" .. tostring(payload[4])
                .. " c=" .. tostring(payload[5]))
        end
        event.timer(1, function() requestRuntimeStatus(node) end, 1)
    elseif responseType == "STRIKE_RESULT" then
        local ok, results = pcall(serialization.unserialize, payload[2])
        print("[STRIKE] " .. node.id .. " results:")
        if ok and type(results) == "table" then
            for _, result in ipairs(results) do
                print("  L" .. tostring(result.launcher) .. " -> "
                    .. (result.success and "SUCCESS" or "FAILED")
                    .. " " .. tostring(result.detail or ""))
            end
        end
        event.timer(1, function() requestRuntimeStatus(node) end, 1)
    elseif responseType == "PONG" then
        print("[NET] PONG <- " .. node.id)
    end
end

local function handleEnvelope(port, envelope)
    if not validEnvelope(envelope) or seenMessages[envelope.id] then return end
    seenMessages[envelope.id] = now()
    if string.upper(envelope.destination) ~= CENTRAL_ID and envelope.destination ~= "*" then return end

    if port == MGMT_PORT then
        handleMgmtEnvelope(envelope)
    elseif port == OP_PORT and envelope.kind == "RUNTIME" then
        handleRuntimeEnvelope(envelope)
    end
end

local function onModemMessage(_, _, _, port, _, marker, encoded)
    if (port ~= MGMT_PORT and port ~= OP_PORT) or marker ~= "STRATCOM_NET" then return end
    local ok, envelope = pcall(serialization.unserialize, encoded)
    if ok then handleEnvelope(port, envelope) end
end

local function discover()
    print("[NET] Broadcasting mesh discovery...")
    originate(MGMT_PORT, "*", "MGMT", {"DISCOVER"})
end

local function printHeader()
    term.clear()
    print("========================================")
    print("          STRATCOM CENTRAL")
    print("========================================")
    print("Version:      " .. VERSION)
    print("Mgmt port:    " .. MGMT_PORT)
    print("Op port:      " .. OP_PORT)
    print("Mesh:         protocol " .. PROTOCOL .. " / TTL " .. DEFAULT_TTL)
    print("Deploy:       ACK/retry")
    print("Status poll:  " .. STATUS_INTERVAL .. "s")
    print("Strike:       payload-aware")
    print("Radar:        network tracks")
    print("Defense:      " .. (defense.auto and "AUTO" or "MANUAL"))
    print("")
end

local function nodeAssetSummary(node)
    if node.radarStation or tostring(node.role) == "radar" then
        return tostring(node.activeTrackCount or 0) .. " TRACKS"
    end
    if node.multiLauncher then
        return tostring(node.readyCount or 0) .. "/" .. tostring(node.launcherCount or 0) .. " READY"
    end
    return clip(node.missileLabel, 20)
end

local function printNodes()
    print("")
    print("NODE       ROLE       RUNTIME   STATE     ASSET                LINK")
    print("---------------------------------------------------------------------")
    local found = false
    for id, node in pairs(nodes) do
        found = true
        print(string.format(
            "%-10s %-10s %-9s %-9s %-20s %s",
            id,
            string.upper(tostring(node.role)),
            clip(node.runtimeVersion, 9),
            clip(node.runtimeState, 9),
            nodeAssetSummary(node),
            nodeOnline(node) and "ONLINE" or "OFFLINE"
        ))
    end
    if not found then print("No mesh bootstrap nodes discovered.") end
    print("")
end

local function printLauncherTable(node)
    print("Launcher  Payload       Ready Armed Missile")
    print("------------------------------------------------------------")
    for _, launcher in ipairs(node.launchers or {}) do
        print(string.format(
            "%-9s %-13s %-5s %-5s %s",
            "L" .. tostring(launcher.index),
            string.upper(payloadClass(launcher.missileName)),
            launcher.ready and "YES" or "NO",
            launcher.armed and "YES" or "NO",
            clip(launcher.missileLabel, 27)
        ))
        if launcher.missileName and launcher.missileName ~= "" then
            print("          ID: " .. tostring(launcher.missileName))
        end
    end
end

local function printRadarNode(node)
    if not node then print("Node not found."); return end
    if tostring(node.role) ~= "radar" and not node.radarStation then
        print("Node is not a radar station.")
        return
    end

    print("")
    print("RADAR STATION - " .. node.id)
    print("============================================================")
    print("Link:          " .. (nodeOnline(node) and "ONLINE" or "OFFLINE"))
    print("Runtime:       " .. tostring(node.runtimeVersion or "---"))
    print("State:         " .. tostring(node.runtimeState or "---"))
    print("Physical radar: " .. tostring(node.radarCount or 0))
    print("Active tracks: " .. tostring(node.activeTrackCount or 0))
    print("")

    for index, radar in ipairs(node.radars or {}) do
        local powerText = tostring(radar.power or "---") .. "/" .. tostring(radar.maxPower or "---")
        print("R" .. tostring(index) .. " " .. tostring(radar.shortAddress or radar.address or "---"))
        print("  Pos:      X=" .. tostring(radar.x or "---")
            .. " Y=" .. tostring(radar.y or "---") .. " Z=" .. tostring(radar.z or "---"))
        print("  Range:    " .. tostring(radar.range or "---"))
        print("  Power:    " .. powerText)
        print("  Jammed:   " .. tostring(radar.jammed == true))
        print("  Contacts: " .. tostring(radar.contacts or 0))
        print("  Scan:     missiles=" .. tostring(radar.scanMissiles == true)
            .. " shells=" .. tostring(radar.scanShells == true)
            .. " players=" .. tostring(radar.scanPlayers == true)
            .. " smart=" .. tostring(radar.smartMode == true))
    end
    print("")
end

local function trackState(track)
    local node = getNode(track.station)
    if not nodeOnline(node) then return "STALE" end
    if now() - (track.lastUpdate or 0) > RADAR_TRACK_STALE_AFTER then return "STALE" end
    return "ACTIVE"
end

local function printTracks(filterNode)
    local filter = filterNode and string.upper(tostring(filterNode)) or nil
    print("")
    print("RADAR TRACKS" .. (filter and (" - " .. filter) or ""))
    print("================================================================================")
    print("STATION    TRACK TYPE             POSITION              SPEED    HDG      STATE")
    print("--------------------------------------------------------------------------------")

    local list = {}
    for _, track in pairs(radarTracks) do
        if not filter or track.station == filter then table.insert(list, track) end
    end
    table.sort(list, function(a, b)
        if a.station == b.station then return tonumber(a.id) < tonumber(b.id) end
        return a.station < b.station
    end)

    if #list == 0 then
        print("No active radar tracks.")
    else
        for _, track in ipairs(list) do
            local pos = string.format("%d,%d,%d", track.x or 0, track.y or 0, track.z or 0)
            local hdg = string.format("%.0f %s", track.heading or 0, tostring(track.headingName or ""))
            print(string.format(
                "%-10s #%-4s %-16s %-21s %-8.1f %-8s %s",
                track.station,
                tostring(track.id),
                clip(track.typeName or radarTypeName(track.typeId), 16),
                pos,
                track.totalSpeed or 0,
                hdg,
                trackState(track)
            ))
            local approach = closestApproach(track)
            if approach and approach.inbound then
                print("           THREAT closest=" .. string.format("%.1f", approach.closest)
                    .. " tca=" .. string.format("%.1fs", approach.t))
            end
            if track.isPlayer and track.name then print("           Player: " .. tostring(track.name)) end
            print("           Velocity X=" .. string.format("%+.1f", track.vx or 0)
                .. " Y=" .. string.format("%+.1f", track.vy or 0)
                .. " Z=" .. string.format("%+.1f", track.vz or 0)
                .. " seenBy=" .. table.concat(track.radars or {}, ","))
        end
    end
    print("")
end

local function printStatus(node)
    if not node then print("Node not found."); return end
    if tostring(node.role) == "radar" or node.radarStation then
        printRadarNode(node)
        return
    end

    print("")
    print("----------------------------------------")
    print("NODE STATUS")
    print("----------------------------------------")
    print("Node:        " .. node.id)
    print("Role:        " .. string.upper(tostring(node.role)))
    print("Link:        " .. (nodeOnline(node) and "ONLINE" or "OFFLINE"))
    print("Claimed:     " .. tostring(node.claimed))
    print("Bootstrap:   " .. tostring(node.bootstrapVersion or "---"))
    print("Runtime:     " .. tostring(node.runtimeVersion or "---"))
    print("State:       " .. tostring(node.runtimeState or "---"))

    if node.multiLauncher then
        print("Launchers:   " .. tostring(node.launcherCount or 0))
        print("Ready:       " .. tostring(node.readyCount or 0))
        print("Armed:       " .. tostring(node.armedCount or 0))
        print("")
        printLauncherTable(node)
    else
        print("Missile:     " .. clip(node.missileLabel, 30))
        print("Item:        " .. clip(node.missileName, 30))
        print("Count:       " .. tostring(node.missileCount or 0))
        print("Armed:       " .. stateText(node.armed))
        print("Ready:       " .. stateText(node.ready))
        print("Tier:        " .. tostring(node.tier or "---"))
        local p = percent(node.energy, node.maxEnergy)
        if p then print("Power:       " .. node.energy .. "/" .. node.maxEnergy .. " (" .. p .. "%)")
        else print("Power:       ---") end
    end

    if node.lastSeen then print("Last seen:   " .. string.format("%.1fs ago", now() - node.lastSeen)) end
    if node.lastStatus then print("Status age:  " .. string.format("%.1fs", now() - node.lastStatus)) end
    print("----------------------------------------")
    print("")
end

local function printRadars()
    print("")
    print("RADAR STATIONS")
    print("============================================================")
    print("NODE       RADARS TRACKS RUNTIME   STATE     LINK")
    print("------------------------------------------------------------")
    local found = false
    for _, node in pairs(nodes) do
        if tostring(node.role) == "radar" or node.radarStation then
            found = true
            print(string.format(
                "%-10s %-6s %-6s %-9s %-9s %s",
                node.id,
                tostring(node.radarCount or 0),
                tostring(node.activeTrackCount or 0),
                clip(node.runtimeVersion, 9),
                clip(node.runtimeState, 9),
                nodeOnline(node) and "ONLINE" or "OFFLINE"
            ))
        end
    end
    if not found then print("No radar stations discovered.") end
    print("")
end

local function printPayloads(node)
    if not node then print("Node not found."); return end
    if not node.multiLauncher then
        print("Node is not a multi-launcher strike site.")
        return
    end

    print("")
    print("PAYLOAD INVENTORY - " .. node.id)
    print("============================================================")
    printLauncherTable(node)
    print("")

    local counts = {nuclear = 0, conventional = 0, bunker = 0, special = 0, unknown = 0}
    for _, launcher in ipairs(node.launchers or {}) do
        if launcher.ready and launcher.missileName and launcher.missileName ~= "" then
            local class = payloadClass(launcher.missileName)
            counts[class] = (counts[class] or 0) + 1
        end
    end
    print("Ready payload counts:")
    print("  NUCLEAR:      " .. counts.nuclear)
    print("  CONVENTIONAL: " .. counts.conventional)
    print("  BUNKER:       " .. counts.bunker)
    print("  SPECIAL:      " .. counts.special)
    print("  UNKNOWN:      " .. counts.unknown)
    print("")
end

local function printDefenseStatus()
    local abm = getNode(ABM_NODE_ID)
    local ready, reason = abmReady()
    print("")
    print("AUTOMATIC DEFENSE")
    print("============================================================")
    print("Mode:          " .. (defense.auto and "AUTO" or "OFF"))
    if defenseZoneConfigured() then
        print("Protected:     X=" .. defense.protectX .. " Z=" .. defense.protectZ
            .. " radius=" .. defense.radius)
    else
        print("Protected:     NOT CONFIGURED")
    end
    print("Interceptor:   " .. ABM_NODE_ID)
    print("ABM online:    " .. tostring(nodeOnline(abm)))
    print("ABM runtime:   " .. tostring(abm and abm.runtimeState or "---"))
    print("ABM ready:     " .. tostring(ready) .. (ready and "" or (" (" .. tostring(reason) .. ")")))
    print("ABM missile:   " .. tostring(abm and abm.missileName or "---"))
    print("Active engage: " .. tostring(pendingArm and pendingArm.trackKey or "none"))
    print("Confirm:       " .. DEFENSE_CONFIRM_SAMPLES .. " qualification passes")
    print("============================================================")
    print("")
end

local function printEngagements()
    print("")
    print("ENGAGEMENT HISTORY")
    print("================================================================================")
    if #engagementHistory == 0 then
        print("No completed engagements.")
    else
        for i = #engagementHistory, 1, -1 do
            local e = engagementHistory[i]
            print(string.format(
                "%-18s %-10s %-12s target=%d,%d %s",
                tostring(e.trackKey),
                tostring(e.typeName),
                tostring(e.state),
                tonumber(e.targetX) or 0,
                tonumber(e.targetZ) or 0,
                tostring(e.detail or "")
            ))
        end
    end
    print("")
end

local function splitWords(line)
    local words = {}
    for word in string.gmatch(line or "", "%S+") do table.insert(words, word) end
    return words
end

local function selectPayloadLaunchers(node, class, count)
    local selected = {}
    for _, launcher in ipairs(node.launchers or {}) do
        if launcher.ready and launcher.missileName and launcher.missileName ~= ""
            and payloadClass(launcher.missileName) == class
        then
            table.insert(selected, launcher)
            if #selected >= count then break end
        end
    end
    return selected
end

local function executeStrike(node, class, count, x, z)
    if not node.multiLauncher then
        print("REJECTED: node is not a multi-launcher strike site.")
        return
    end
    if not VALID_CLASSES[class] or class == "unknown" then
        print("REJECTED: invalid payload class. Use nuclear, conventional, bunker, or special.")
        return
    end

    local selected = selectPayloadLaunchers(node, class, count)
    if #selected < count then
        print("REJECTED: requested " .. count .. " " .. string.upper(class)
            .. " payloads, only " .. #selected .. " ready.")
        return
    end

    print("")
    print("*** STRIKE PLAN ***")
    print("Site:       " .. node.id)
    print("Payload:    " .. string.upper(class))
    print("Quantity:   " .. count)
    print("Target:     X=" .. x .. " Z=" .. z)
    print("")
    print("Selected launchers:")
    local plan = {}
    for _, launcher in ipairs(selected) do
        table.insert(plan, launcher.index)
        print("  L" .. launcher.index .. "  " .. tostring(launcher.missileLabel)
            .. "  [" .. tostring(launcher.missileName) .. "]")
    end
    print("")
    io.write("Type STRIKE to confirm: ")
    if io.read() ~= "STRIKE" then
        print("Strike cancelled.")
        return
    end

    sendOperational(node, "STRIKE", serialization.serialize(plan), serialization.serialize({x = x, z = z}))
end

local function printHelp()
    print("")
    print("Management:")
    print("  discover | nodes | info <node> | sync")
    print("  deploy <node|all> | start <node> | stop <node> | restart <node>")
    print("")
    print("Radar:")
    print("  radars")
    print("  radar <node>")
    print("  tracks [node]")
    print("")
    print("Defense:")
    print("  defense protect <x> <z> <radius>")
    print("  defense auto on|off")
    print("  defense status")
    print("  engagements")
    print("")
    print("Operations:")
    print("  status <node> | ping <node>")
    print("  arm <node> [launcher|all]")
    print("  disarm <node> [launcher|all]")
    print("  launch <node> <launcher> <x> <z>       (multi-launcher)")
    print("  launch <node> <x> <z>                  (single-launcher)")
    print("")
    print("Payload planning:")
    print("  payloads <node>")
    print("  classify <item-id> <nuclear|conventional|bunker|special>")
    print("  unclassify <item-id>")
    print("  strike <node> <class> <count> <x> <z>")
    print("")
    print("Other: clear, help, quit")
    print("")
end

local function execute(line)
    local args = splitWords(line)
    local command = string.lower(args[1] or "")

    if command == "" then return
    elseif command == "help" then printHelp()
    elseif command == "discover" then discover()
    elseif command == "nodes" then printNodes()
    elseif command == "radars" then printRadars()
    elseif command == "radar" then
        local node = getNode(args[2]); if not node then print("Usage: radar <node>"); return end
        requestRuntimeStatus(node)
        os.sleep(0.5)
        printRadarNode(node)
    elseif command == "tracks" then
        if args[2] and not getNode(args[2]) then print("Node not found."); return end
        printTracks(args[2])
    elseif command == "defense" then
        local sub = string.lower(args[2] or "")
        if sub == "protect" then
            local x = tonumber(args[3])
            local z = tonumber(args[4])
            local radius = tonumber(args[5])
            if not x or not z or not radius or radius <= 0 then
                print("Usage: defense protect <x> <z> <radius>")
                return
            end
            defense.protectX = x
            defense.protectZ = z
            defense.radius = radius
            print("[DEFENSE] Protected zone X=" .. x .. " Z=" .. z .. " radius=" .. radius)
        elseif sub == "auto" then
            local value = string.lower(args[3] or "")
            if value == "on" then
                if not defenseZoneConfigured() then
                    print("REJECTED: configure protection zone first with defense protect <x> <z> <radius>.")
                    return
                end
                defense.auto = true
                print("[DEFENSE] Automatic engagement ENABLED")
            elseif value == "off" then
                defense.auto = false
                print("[DEFENSE] Automatic engagement DISABLED")
            else
                print("Usage: defense auto on|off")
            end
        elseif sub == "status" then
            printDefenseStatus()
        else
            print("Usage: defense protect <x> <z> <radius> | defense auto on|off | defense status")
        end
    elseif command == "engagements" then
        printEngagements()
    elseif command == "sync" then
        if syncRepository() then reconcileAll(true) end
    elseif command == "info" then
        local node = getNode(args[2]); if not node then print("Usage: info <node>"); return end
        sendMgmt(node, "INFO")
    elseif command == "deploy" then
        if string.lower(args[2] or "") == "all" then
            for _, node in pairs(nodes) do if node.claimed and nodeOnline(node) then deployNode(node) end end
        else
            local node = getNode(args[2]); if not node then print("Usage: deploy <node|all>"); return end
            deployNode(node)
        end
    elseif command == "start" or command == "stop" or command == "restart" then
        local node = getNode(args[2]); if not node then print("Usage: " .. command .. " <node>"); return end
        sendMgmt(node, string.upper(command))
    elseif command == "status" then
        local node = getNode(args[2]); if not node then print("Usage: status <node>"); return end
        if not requestRuntimeStatus(node) then print("Runtime unavailable or node offline."); return end
        os.sleep(0.5)
        printStatus(node)
    elseif command == "payloads" then
        local node = getNode(args[2]); if not node then print("Usage: payloads <node>"); return end
        requestRuntimeStatus(node)
        os.sleep(0.5)
        printPayloads(node)
    elseif command == "classify" then
        local itemId = args[2]
        local class = string.lower(args[3] or "")
        if not itemId or not VALID_CLASSES[class] or class == "unknown" then
            print("Usage: classify <item-id> <nuclear|conventional|bunker|special>")
            return
        end
        payloadCatalog[itemId] = {class = class}
        if savePayloadCatalog() then print("[PAYLOAD] " .. itemId .. " -> " .. string.upper(class))
        else print("[PAYLOAD] Failed to save classification.") end
    elseif command == "unclassify" then
        local itemId = args[2]
        if not itemId then print("Usage: unclassify <item-id>"); return end
        payloadCatalog[itemId] = nil
        savePayloadCatalog()
        print("[PAYLOAD] Removed classification for " .. itemId)
    elseif command == "ping" then
        local node = getNode(args[2]); if not node then print("Usage: ping <node>"); return end
        sendOperational(node, "PING")
    elseif command == "arm" or command == "disarm" then
        local node = getNode(args[2]); if not node then print("Usage: " .. command .. " <node> [launcher|all]"); return end
        if tostring(node.role) == "radar" then
            print("Radar nodes do not support arm/disarm.")
            return
        end
        if node.multiLauncher then
            local selector = args[3]
            if not selector then print("Usage: " .. command .. " <node> <launcher|all>"); return end
            sendOperational(node, string.upper(command), selector)
        else
            sendOperational(node, string.upper(command))
        end
    elseif command == "launch" then
        local node = getNode(args[2]); if not node then print("Node not found."); return end
        if node.multiLauncher then
            local launcher = tonumber(args[3])
            local x = tonumber(args[4])
            local z = tonumber(args[5])
            if not launcher or not x or not z then print("Usage: launch <node> <launcher> <x> <z>"); return end
            local launcherStatus = node.launchers and node.launchers[launcher]
            if not launcherStatus or launcherStatus.armed ~= true then
                print("REJECTED: launcher is not armed.")
                return
            end
            print("Launcher: L" .. launcher .. "  " .. tostring(launcherStatus.missileLabel))
            print("Target: X=" .. x .. " Z=" .. z)
            io.write("Type LAUNCH to confirm: ")
            if io.read() ~= "LAUNCH" then print("Launch cancelled."); return end
            sendOperational(node, "LAUNCH_SILO", launcher, serialization.serialize({x = x, z = z}))
        else
            local x = tonumber(args[3]); local z = tonumber(args[4])
            if not x or not z then print("Usage: launch <node> <x> <z>"); return end
            if node.armed ~= true then print("REJECTED: node is not armed."); return end
            print("Missile: " .. clip(node.missileLabel, 30))
            print("Target: X=" .. x .. " Z=" .. z)
            io.write("Type LAUNCH to confirm: ")
            if io.read() ~= "LAUNCH" then print("Launch cancelled."); return end
            sendOperational(node, "LAUNCH", x, z)
        end
    elseif command == "strike" then
        local node = getNode(args[2])
        local class = string.lower(args[3] or "")
        local count = tonumber(args[4])
        local x = tonumber(args[5])
        local z = tonumber(args[6])
        if not node or not count or count < 1 or count % 1 ~= 0 or not x or not z then
            print("Usage: strike <node> <class> <count> <x> <z>")
            return
        end
        executeStrike(node, class, count, x, z)
    elseif command == "clear" then printHeader()
    elseif command == "quit" then running = false
    else print("Unknown command. Type 'help'.") end
end

modem.open(MGMT_PORT)
modem.open(OP_PORT)
event.listen("modem_message", onModemMessage)
local deploymentTimer = event.timer(1, checkDeploymentTimeouts, math.huge)
local statusTimer = event.timer(STATUS_INTERVAL, pollRuntimeStatus, math.huge)
local defenseTimer = event.timer(1, defenseTick, math.huge)

loadPayloadCatalog()
printHeader()
syncRepository()
discover()
print("Type 'help' for commands.")
print("")

while running do
    io.write("STRATCOM> ")
    local line = io.read()
    if line then execute(line) end
    if now() - lastPrune >= PRUNE_INTERVAL then pruneSeen() end
end

defense.auto = false
event.cancel(defenseTimer)
event.cancel(statusTimer)
event.cancel(deploymentTimer)
event.ignore("modem_message", onModemMessage)
modem.close(OP_PORT)
modem.close(MGMT_PORT)
print("STRATCOM central stopped.")
