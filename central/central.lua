local component = require("component")
local event = require("event")
local computer = require("computer")
local term = require("term")
local filesystem = require("filesystem")
local serialization = require("serialization")

local options = ...
if type(options) ~= "table" then options = {} end
local consolePrint = print
local commandOutput = nil
local commandFailed = false
local pendingOperator = nil
local function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    if commandOutput then table.insert(commandOutput, line)
    elseif options.log then options.log(line)
    else consolePrint(line) end
end

local VERSION = "3.2.0"
local PROTOCOL = 2
local CENTRAL_ID = "CENTRAL"
local DEFAULT_TTL = 6
local SEEN_TTL = 30
local PRUNE_INTERVAL = 10

local REPOSITORY_DIR = "/home/stratcom/repository"
local MANIFEST_PATH = REPOSITORY_DIR .. "/manifest.lua"
local PAYLOAD_DB_PATH = "/home/stratcom/payloads.db"
local LAUNCH_SITE_DB_PATH = "/home/stratcom/launchsites.db"

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
local DEFENSE_POST_LAUNCH_TIMEOUT = 20
local DEFENSE_REENGAGE_COOLDOWN = 10

local LAUNCH_SITE_MAX_ACQUIRE_Y = 160
local LAUNCH_SITE_MIN_CLIMB = 35
local LAUNCH_SITE_MIN_DEPARTURE = 40
local LAUNCH_SITE_CONFIRM_SAMPLES = 2
local LAUNCH_SITE_MERGE_DISTANCE = 100

local IFF_MATCH_WINDOW = 30
local IFF_HEADING_TOLERANCE = 30

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

local function readAll(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

if not filesystem.exists(REPOSITORY_DIR) then filesystem.makeDirectory(REPOSITORY_DIR) end

local modemAddress = component.list("modem")()
if not modemAddress then
    io.stderr:write("FATAL: No modem detected.\n")
    return
end

local modem = component.proxy(modemAddress)
local nodes = {}
local hologram, hologramAddress
local desiredRuntimes = {}
local payloadCatalog = {}
local radarTracks = {}
local engagementHistory = {}
local activeEngagements = {}
local pendingArm = nil
local launchSites = {}
local nodePreferences = {}
local pendingConfirmation = nil
local PREFERENCES_PATH = "/home/stratcom/preferences.db"
local nextLaunchSiteId = 1
local friendlyExpectations = {}
local nextFriendlyExpectationId = 1
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

local function savePreferences()
    local raw = serialization.serialize({nodes = nodePreferences, defense = defense, abmNode = ABM_NODE_ID, hologramAddress = hologramAddress})
    local path = PREFERENCES_PATH .. ".tmp"
    local f, err = io.open(path, "w")
    if not f then print("[CONFIG] Save failed: " .. tostring(err)); return false end
    local ok = f:write(raw)
    local flushed = f:flush()
    local closed, closeErr = f:close()
    if not ok or not flushed or closed == false or closeErr then print("[CONFIG] Write failed; previous settings retained"); return false end
    local backup = PREFERENCES_PATH .. ".bak"
    if filesystem.exists(backup) then filesystem.remove(backup) end
    if filesystem.exists(PREFERENCES_PATH) and not filesystem.rename(PREFERENCES_PATH, backup) then return false end
    if not filesystem.rename(path, PREFERENCES_PATH) then
        if filesystem.exists(backup) then filesystem.rename(backup, PREFERENCES_PATH) end
        print("[CONFIG] Save failed; previous settings retained")
        return false
    end
    return true
end

local function loadPreferences()
    local raw = readAll(PREFERENCES_PATH) or readAll(PREFERENCES_PATH .. ".bak")
    if not raw then return end
    local ok, saved = pcall(serialization.unserialize, raw)
    if not ok or type(saved) ~= "table" then return end
    if type(saved.nodes) == "table" then nodePreferences = saved.nodes end
    if type(saved.abmNode) == "string" then ABM_NODE_ID = saved.abmNode end
    if type(saved.hologramAddress) == "string" then hologramAddress = saved.hologramAddress end
    if type(saved.defense) == "table" then
        defense.protectX = tonumber(saved.defense.protectX)
        defense.protectZ = tonumber(saved.defense.protectZ)
        defense.radius = tonumber(saved.defense.radius)
        defense.auto = saved.defense.auto == true and defense.protectX ~= nil
            and defense.protectZ ~= nil and defense.radius ~= nil and defense.radius > 0
    end
end

local function desiredState(node)
    local preference = nodePreferences[node.id]
    return preference and preference.desiredState or node.desiredState or "running"
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
    local key = string.upper(id or "")
    if nodes[key] then return nodes[key] end
    for nodeId, preference in pairs(nodePreferences) do
        if string.upper(preference.alias or "") == key then return nodes[nodeId] end
    end
end

local function defenseZoneConfigured()
    return defense.protectX ~= nil and defense.protectZ ~= nil
        and defense.radius ~= nil and defense.radius > 0
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

local function saveLaunchSites()
    local ok, raw = pcall(serialization.serialize, {
        sites = launchSites,
        nextId = nextLaunchSiteId,
    })
    if not ok then return false end
    local file = io.open(LAUNCH_SITE_DB_PATH, "w")
    if not file then return false end
    file:write(raw)
    file:close()
    return true
end

local function loadLaunchSites()
    launchSites = {}
    nextLaunchSiteId = 1
    local raw = readAll(LAUNCH_SITE_DB_PATH)
    if not raw then return end
    local ok, data = pcall(serialization.unserialize, raw)
    if not ok or type(data) ~= "table" then return end
    if type(data.sites) == "table" then launchSites = data.sites end
    nextLaunchSiteId = tonumber(data.nextId) or 1
end

local function launchSiteConfidence(launches)
    launches = tonumber(launches) or 0
    if launches >= 3 then return "VERY_HIGH" end
    if launches >= 2 then return "HIGH" end
    return "MEDIUM"
end

local function horizontalDistance(x1, z1, x2, z2)
    local dx = (tonumber(x2) or 0) - (tonumber(x1) or 0)
    local dz = (tonumber(z2) or 0) - (tonumber(z1) or 0)
    return math.sqrt(dx * dx + dz * dz)
end

local function bearingFromDelta(dx, dz)
    if dx == 0 and dz == 0 then return 0 end
    local angle = math.deg((math.atan2 or math.atan)(dx, -dz))
    if angle < 0 then angle = angle + 360 end
    return angle
end

local function angleDifference(a, b)
    local diff = math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) % 360
    if diff > 180 then diff = 360 - diff end
    return diff
end

local function countFriendlyExpectations()
    local count = 0
    for _, expectation in pairs(friendlyExpectations) do
        if expectation.remaining and expectation.remaining > 0 and expectation.deadline >= now() then
            count = count + 1
        end
    end
    return count
end

local function pruneFriendlyExpectations()
    local timestamp = now()
    for id, expectation in pairs(friendlyExpectations) do
        if expectation.remaining <= 0 or timestamp > expectation.deadline then
            friendlyExpectations[id] = nil
        end
    end
end

local function registerFriendlyExpectation(node, count, targetX, targetZ, mode)
    if not node or tostring(node.role) ~= "strike" then return nil end
    if not defenseZoneConfigured() then
        print("[IFF] No protected region configured; friendly launch cannot be correlated.")
        return nil
    end

    count = tonumber(count) or 0
    if count < 1 then return nil end
    targetX = tonumber(targetX)
    targetZ = tonumber(targetZ)
    if not targetX or not targetZ then return nil end

    local id = nextFriendlyExpectationId
    nextFriendlyExpectationId = nextFriendlyExpectationId + 1
    local created = now()
    local expectation = {
        id = id,
        source = node.id,
        mode = tostring(mode or "launch"),
        createdAt = created,
        deadline = created + IFF_MATCH_WINDOW,
        targetX = targetX,
        targetZ = targetZ,
        targetBearing = bearingFromDelta(targetX - defense.protectX, targetZ - defense.protectZ),
        expected = count,
        remaining = count,
    }
    friendlyExpectations[id] = expectation
    print("[IFF] Registered friendly " .. expectation.mode .. " from " .. node.id
        .. " count=" .. tostring(count)
        .. " target=" .. tostring(targetX) .. "," .. tostring(targetZ)
        .. " window=" .. tostring(IFF_MATCH_WINDOW) .. "s")
    return expectation
end

local function trackOriginInsideProtectedRegion(track)
    if not defenseZoneConfigured() or not track then return false end
    if track.firstX == nil or track.firstZ == nil then return false end
    return horizontalDistance(defense.protectX, defense.protectZ, track.firstX, track.firstZ) <= defense.radius
end

local function trackMovingOutward(track)
    if not defenseZoneConfigured() or not track then return false end
    local x = tonumber(track.x)
    local z = tonumber(track.z)
    local vx = tonumber(track.vx) or 0
    local vz = tonumber(track.vz) or 0
    if not x or not z then return false end
    local rx = x - defense.protectX
    local rz = z - defense.protectZ
    return (rx * vx + rz * vz) > 0
end

local function tryMatchFriendlyTrack(track)
    if not track or track.friendly == true then return track and true or false end
    local typeId = tonumber(track.typeId)
    if typeId == nil or typeId < 0 or typeId > 9 then return false end
    if not trackOriginInsideProtectedRegion(track) then return false end
    if not trackMovingOutward(track) then return false end

    pruneFriendlyExpectations()
    local timestamp = now()
    local trackHeading = tonumber(track.heading) or bearingFromDelta(track.vx or 0, track.vz or 0)
    local best = nil
    local bestAngle = nil

    for _, expectation in pairs(friendlyExpectations) do
        if expectation.remaining > 0
            and timestamp >= expectation.createdAt
            and timestamp <= expectation.deadline
        then
            local diff = angleDifference(trackHeading, expectation.targetBearing)
            if diff <= IFF_HEADING_TOLERANCE and (not bestAngle or diff < bestAngle) then
                best = expectation
                bestAngle = diff
            end
        end
    end

    if not best then return false end

    best.remaining = best.remaining - 1
    track.friendly = true
    track.iffState = "FRIENDLY_OUTBOUND"
    track.friendlySource = best.source
    track.friendlyTargetX = best.targetX
    track.friendlyTargetZ = best.targetZ
    track.friendlyExpectationId = best.id
    track.friendlyMatchedAt = timestamp
    track.threatSamples = 0
    track.launchSiteSamples = 0

    print("[IFF] " .. track.key .. " FRIENDLY_OUTBOUND"
        .. " source=" .. tostring(best.source)
        .. " target=" .. tostring(best.targetX) .. "," .. tostring(best.targetZ)
        .. " headingError=" .. string.format("%.1f", bestAngle))

    if best.remaining <= 0 then friendlyExpectations[best.id] = nil end
    return true
end

local function recordLaunchSite(track)
    if not track or track.firstX == nil or track.firstZ == nil then return nil end

    local best = nil
    local bestDistance = nil
    for _, site in pairs(launchSites) do
        local distance = horizontalDistance(site.x, site.z, track.firstX, track.firstZ)
        if distance <= LAUNCH_SITE_MERGE_DISTANCE
            and (not bestDistance or distance < bestDistance)
        then
            best = site
            bestDistance = distance
        end
    end

    if not best then
        best = {
            id = nextLaunchSiteId,
            x = track.firstX,
            y = track.firstY,
            z = track.firstZ,
            launches = 0,
            firstDetected = now(),
        }
        launchSites[best.id] = best
        nextLaunchSiteId = nextLaunchSiteId + 1
    end

    local oldCount = tonumber(best.launches) or 0
    local newCount = oldCount + 1
    if oldCount > 0 then
        best.x = ((best.x or 0) * oldCount + track.firstX) / newCount
        best.z = ((best.z or 0) * oldCount + track.firstZ) / newCount
        best.y = ((best.y or 0) * oldCount + (track.firstY or 0)) / newCount
    end
    best.launches = newCount
    best.lastDetected = now()
    best.station = track.station
    best.lastTrackId = track.id
    best.lastTypeId = track.typeId
    best.lastTypeName = track.typeName
    best.confidence = launchSiteConfidence(best.launches)
    saveLaunchSites()

    print("[RADAR] POSSIBLE LAUNCH SITE #" .. tostring(best.id)
        .. " @ X=" .. tostring(math.floor(best.x + 0.5))
        .. " Z=" .. tostring(math.floor(best.z + 0.5))
        .. " confidence=" .. tostring(best.confidence)
        .. " launches=" .. tostring(best.launches))
    return best
end

local function evaluateLaunchSiteCandidate(track)
    if not track or track.launchSitePromoted or track.friendly == true then return end
    local typeId = tonumber(track.typeId)
    if typeId == nil or typeId < 0 or typeId > 9 then return end
    if track.firstY == nil or track.firstY > LAUNCH_SITE_MAX_ACQUIRE_Y then return end

    local climb = (tonumber(track.y) or 0) - (tonumber(track.firstY) or 0)
    local departure = horizontalDistance(track.firstX, track.firstZ, track.x, track.z)
    if climb >= LAUNCH_SITE_MIN_CLIMB
        and departure >= LAUNCH_SITE_MIN_DEPARTURE
        and (tonumber(track.vy) or 0) > 0
    then
        track.launchSiteSamples = (track.launchSiteSamples or 0) + 1
        if track.launchSiteSamples >= LAUNCH_SITE_CONFIRM_SAMPLES then
            track.launchSitePromoted = true
            recordLaunchSite(track)
        end
    end
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
    local sent = modem.broadcast(port, "STRATCOM_NET", encoded)
    return sent ~= false
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
    if pendingOperator and not pendingOperator.id then pendingOperator.id = envelope.id end
    return transmitEnvelope(port, envelope), envelope.id
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
    -- The installer/updater stages a complete bundle. Boot never needs HTTP.
    local manifestPath = options.appDir and (options.appDir .. "/runtime/manifest.lua") or MANIFEST_PATH
    local chunk, err = loadfile(manifestPath)
    if not chunk then print("[REPO] No valid installed manifest: " .. tostring(err)); return false end
    local ok, manifest = pcall(chunk)
    if not ok or type(manifest) ~= "table" or type(manifest.roles) ~= "table" then
        print("[REPO] Invalid installed manifest; current runtime cache retained")
        return false
    end
    local staged = {}
    for role, entry in pairs(manifest.roles) do
        local path = options.appDir and (options.appDir .. "/" .. tostring(entry.path))
            or (REPOSITORY_DIR .. "/" .. tostring(role) .. ".lua")
        if not entry.version or not loadfile(path) then
            print("[REPO] Incomplete bundle; current runtime cache retained: " .. tostring(role))
            return false
        end
        staged[role] = {version = tostring(entry.version), path = path}
    end
    desiredRuntimes = staged
    return true
end

local function requestRuntimeStatus(node, force, detail)
    if not node or not nodeOnline(node) or not node.claimed then return false end
    if node.runtimeState ~= "running" then return false end
    if not force and node.lastStatusRequest and now() - node.lastStatusRequest < STATUS_INTERVAL then return false end
    local token = nextMessageId()
    node.lastStatusRequest = now()
    node.pendingStatus = token
    node.statusComplete = nil
    node.nextStatus = now() + STATUS_INTERVAL
    if not sendOperational(node, "STATUS", detail or "summary", token) then node.pendingStatus = nil; return false end
    return token
end

local function pollRuntimeStatus()
    -- Send one due poll per tick, rather than a burst to every node.
    local selected = nil
    for _, node in pairs(nodes) do
        if nodeOnline(node) and node.claimed and node.runtimeState == "running" and not node.deploying
            and (not node.nextStatus or now() >= node.nextStatus)
            and (not selected or (node.nextStatus or 0) < (selected.nextStatus or 0)) then selected = node end
    end
    if selected then requestRuntimeStatus(selected) end
end

local function registerNode(id, role, bootstrapVersion, runtimeVersion, runtimeState, intent, session)
    if not id then return nil end
    id = string.upper(tostring(id))
    local node = nodes[id]
    local discovered = false

    if not node then
        node = {id = id, firstSeen = now(), claimed = false, deploying = false}
        nodes[id] = node
        discovered = true
    end

    if session and node.retiredSessions and node.retiredSessions[session] then return nil end
    node.role = tostring(role or node.role or "unknown")
    node.bootstrapVersion = tostring(bootstrapVersion or node.bootstrapVersion or "unknown")
    node.runtimeVersion = tostring(runtimeVersion or node.runtimeVersion or "none")
    node.runtimeState = tostring(runtimeState or node.runtimeState or "unknown")
    node.lastSeen = now()
    node.desiredState = intent or node.desiredState
    if session and node.session ~= session then
        node.retiredSessions = node.retiredSessions or {}
        if node.session then node.retiredSessions[node.session] = now() end
        for retired, timestamp in pairs(node.retiredSessions) do
            if now() - timestamp > 600 then node.retiredSessions[retired] = nil end
        end
        for key, track in pairs(radarTracks) do
            if track.station == id then radarTracks[key] = nil end
        end
        node.ready = false
        node.armed = false
        node.lastStatus = nil
        node.session = session
    end

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
    local transaction = node.deployment and node.deployment.id
    node.rejectedVersion = node.deployment and node.deployment.version
    node.deploying = false
    node.deployment = nil
    sendMgmt(node, "DEPLOY_ABORT", transaction)
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
        sendMgmt(node, "DEPLOY_BEGIN", deployment.version, deployment.totalChunks, deployment.id, deployment.checksum)
    elseif deployment.phase == "chunk" then
        local index = deployment.nextChunk
        sendMgmt(node, "DEPLOY_CHUNK", index, deploymentChunk(deployment, index), deployment.id)
    elseif deployment.phase == "commit" then
        sendMgmt(node, "DEPLOY_COMMIT", deployment.version, deployment.id)
    else
        failDeployment(node, "INVALID_PHASE")
        return false
    end

    deployment.lastSent = now()
    return true
end

local function deployNode(node)
    if not node or node.deploying or not node.claimed or not nodeOnline(node) then return false end
    if desiredState(node) ~= "running" then return false end
    local busy = next(activeEngagements) ~= nil or node.armed == true or (node.armedCount or 0) > 0
    for _, other in pairs(nodes) do if other.deploying then busy = true end end
    if busy then
        if not node.deployQueued then print("[DEPLOY] " .. node.id .. " queued until idle") end
        node.deployQueued = true
        return false
    end
    node.deployQueued = false
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
    local a, b = 1, 0
    for i = 1, #data do a = (a + data:byte(i)) % 65521; b = (b + a) % 65521 end
    node.deployment = {
        id = nextMessageId(),
        checksum = string.format("%08x", b * 65536 + a),
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
        if node.deployQueued then deployNode(node) end
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
    local intent = desiredState(node)
    if intent ~= "running" then
        if intent == "maintenance" and node.runtimeState ~= "maintenance" then sendMgmt(node, "MAINTENANCE")
        elseif node.runtimeState == "running" and intent == "stopped" then sendMgmt(node, "STOP") end
        return
    end
    local desired = desiredRuntimes[node.role]
    if not desired then return end

    if tostring(node.runtimeVersion) ~= tostring(desired.version) then
        if node.rejectedVersion ~= desired.version then deployNode(node) end
    elseif node.runtimeState ~= "running" then
        print("[MGMT] Starting runtime on " .. node.id)
        sendMgmt(node, "START")
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
    if node.session and track.session and node.session ~= track.session then return nil end
    local key = radarTrackKey(node.id, track.id)
    local previous = radarTracks[key]
    if previous and previous.session ~= track.session then previous = nil end
    if previous and track.sequence and previous.sequence and track.sequence <= previous.sequence then return nil end
    radarTracks[key] = {
        session = track.session,
        sequence = track.sequence,
        evaluatedSequence = previous and previous.evaluatedSequence,
        evaluatedUpdate = previous and previous.evaluatedUpdate,
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
        firstX = previous and previous.firstX or tonumber(track.x),
        firstY = previous and previous.firstY or tonumber(track.y),
        firstZ = previous and previous.firstZ or tonumber(track.z),
        launchSiteSamples = previous and previous.launchSiteSamples or 0,
        launchSitePromoted = previous and previous.launchSitePromoted or false,
        friendly = previous and previous.friendly or false,
        iffState = previous and previous.iffState or nil,
        friendlySource = previous and previous.friendlySource or nil,
        friendlyTargetX = previous and previous.friendlyTargetX or nil,
        friendlyTargetZ = previous and previous.friendlyTargetZ or nil,
        friendlyExpectationId = previous and previous.friendlyExpectationId or nil,
        friendlyMatchedAt = previous and previous.friendlyMatchedAt or nil,
    }
    return radarTracks[key]
end

local function applyRadarStatus(node, status)
    node.radarStation = true
    node.radarCount = tonumber(status.radarCount) or 0
    node.activeTrackCount = tonumber(status.activeTrackCount) or 0
    node.radars = status.radars or {}

    if type(status.tracks) ~= "table" then return end
    local seen = {}
    if type(status.tracks) == "table" then
        for _, track in pairs(status.tracks) do
            local saved = applyRadarTrack(node, track)
            seen[radarTrackKey(node.id, track.id)] = true
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

    node.status = status
    if hologram and node.role == "intel" and status.satelliteType == "COMBINED_INTEL"
        and status.scanState == "COMPLETE" and type(status.scanFrame) == "table"
        and status.scanFrame.session == node.session then
        hologram.offer(node.id, status.scanFrame)
    end
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
    if not node.lastStatus or now() - node.lastStatus > RADAR_TRACK_STALE_AFTER then return false, "ABM_STATUS_STALE" end
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
    if not track then return end
    local station = getNode(track.station)
    if not station or not nodeOnline(station) or station.runtimeState ~= "running"
        or not track.lastUpdate or now() - track.lastUpdate > RADAR_TRACK_STALE_AFTER then
        track.threatSamples = 0
        return
    end
    if track.sequence then
        if track.evaluatedSequence == track.sequence then return end
        track.evaluatedSequence = track.sequence
    else
        if track.evaluatedUpdate == track.lastUpdate then return end
        track.evaluatedUpdate = track.lastUpdate
    end
    if track.friendly == true then
        track.threatSamples = 0
        return
    end
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
    pruneFriendlyExpectations()
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
                finishEngagement(engagement, "MISS", "HOSTILE_TRACK_STILL_ACTIVE_AFTER_OBSERVATION_WINDOW")
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
        finishEngagement(engagement, "UNCONFIRMED", "CONTACT_LOST_AFTER_ENGAGEMENT")
    elseif engagement.state == "ARMING" then
        finishEngagement(engagement, "ABORTED", "TRACK_LOST_BEFORE_LAUNCH")
    end
end

local function handleMgmtEnvelope(envelope)
    local source = string.upper(envelope.source)
    local payload = envelope.payload

    if envelope.kind == "BOOT_HELLO" or envelope.kind == "BOOT_HEARTBEAT" then
        local node = registerNode(source, payload[2], payload[3], payload[4], payload[5], payload[6], payload[7])
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
        if command:sub(1, 7) == "DEPLOY_" and node.deployment
            and payload[4] and payload[4] ~= node.deployment.id then return end

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
                if acknowledged >= d.totalChunks then d.phase = "commit" else d.nextChunk = acknowledged + 1 end
                sendDeploymentStep(node, false)
            end
        elseif command == "START" then
            if success then
                node.runtimeState = "running"
                event.timer(0.5, function() requestRuntimeStatus(node) end, 1)
            end
            print("[MGMT] " .. node.id .. " START -> " .. tostring(success) .. " " .. tostring(detail or ""))
        elseif command == "MAINTENANCE" then
            if success then node.runtimeState = "maintenance" end
            print("[MGMT] " .. node.id .. " MAINTENANCE -> " .. tostring(success))
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
        if not node.deployment or (payload[4] and payload[4] ~= node.deployment.id) then return end
        local success = payload[1]
        local version = tostring(payload[2] or "unknown")
        local detail = payload[3]
        node.deploying = false
        node.deployment = nil

        if success then
            node.runtimeVersion = version
            node.runtimeState = payload[5] or "stopped"
            node.rejectedVersion = nil
            print("[DEPLOY] " .. node.id .. " healthy " .. version)
            if node.runtimeState ~= "running" and desiredState(node) == "running" then sendMgmt(node, "START") end
        else
            node.rejectedVersion = version
            print("[DEPLOY] " .. node.id .. " FAILED: " .. tostring(detail))
            sendMgmt(node, "INFO")
        end
    elseif envelope.kind == "MGMT_ERROR" then
        if node.deployment and tostring(payload[1]):sub(1, 7) == "DEPLOY_"
            and (not payload[4] or payload[4] == node.deployment.id) then
            failDeployment(node, tostring(payload[1]) .. ": " .. tostring(payload[2]))
        end
    elseif envelope.kind == "BOOT_INFO" then
        local ok, info = pcall(serialization.unserialize, payload[1])
        if ok and type(info) == "table" then
            node.bootstrapVersion = info.bootstrapVersion or node.bootstrapVersion
            node.runtimeVersion = info.runtimeVersion or node.runtimeVersion
            node.runtimeState = info.runtimeState or node.runtimeState
            node.desiredState = info.desiredState or node.desiredState
            node.rejectedVersion = info.rejectedVersion or node.rejectedVersion
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
        local existing = radarTracks[key]
        if existing and track.session and existing.session ~= track.session then return end
        if existing and track.sequence and existing.sequence and track.sequence < existing.sequence then return end
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
        if saved then
            tryMatchFriendlyTrack(saved)
            evaluateLaunchSiteCandidate(saved)
            evaluateTrackForDefense(saved)
        end
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
        if ok and type(status) == "table" then
            if payload[3] and payload[3] ~= node.pendingStatus then return end
            applyRuntimeStatus(node, status)
            node.statusComplete = payload[3] or node.pendingStatus
            node.pendingStatus = nil
        end
    elseif responseType == "SCAN_COMPLETE" then
        local frame = payload[2]
        if hologram and node.role == "intel" and type(frame) == "table" and frame.session == node.session then
            hologram.offer(node.id, frame)
        end
    elseif responseType == "SCAN_MODEL" then
        local frame = payload[2]
        if hologram and node.role == "intel" and node.session and type(frame) == "string"
            and frame:sub(1, #node.session + 1) == node.session .. ":" then
            hologram.receive(node.id, table.unpack(payload, 2, 7))
        end
    elseif responseType == "SCAN" or responseType == "SCAN_STATUS" or responseType == "SCAN_RESULTS"
        or responseType == "SCAN_STRUCTURE" or responseType == "HARDWARE" then
        node.lastReply = {kind = responseType, text = tostring(payload[2]), at = now(), token = payload[3]}
        print("[" .. node.id .. "] " .. tostring(payload[2]))
    elseif responseType == "RADAR_TRACK" then
        handleRadarTrackEvent(node, payload[2])
    elseif responseType == "ACK" then
        local command = tostring(payload[2] or "")
        local success = payload[3]
        print("[ACK] " .. node.id .. " " .. command .. " -> " .. tostring(success))

        if success == true and (command == "ARM" or command == "DISARM") then
            local value = command == "ARM"
            if node.multiLauncher then
                local selector = payload[4]
                for _, launcher in ipairs(node.launchers or {}) do
                    if selector == "all" or tonumber(selector) == launcher.index then launcher.armed = value end
                end
                local count = 0
                for _, launcher in ipairs(node.launchers or {}) do if launcher.armed then count = count + 1 end end
                node.armedCount = count
                node.armed = count > 0
            else node.armed = value end
        end

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
        node.lastReply = {kind = "ERROR", text = code, token = payload[3], at = now()}
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

-- A command can emit incidental telemetry before its actual result.
local function collectOperatorReply(port, envelope)
    local request = pendingOperator
    if not request or envelope.source ~= request.node.id or port ~= request.port then return end
    local p, command = envelope.payload, request.command
    local matches, success, detail = false, false, nil
    if port == MGMT_PORT then
        if envelope.kind == "MGMT_ACK" and p[1] == command then
            matches, success, detail = true, p[2] == true, p[3]
        elseif envelope.kind == "MGMT_ERROR" and p[1] == command then
            matches, detail = true, p[2]
        elseif command == "INFO" and envelope.kind == "BOOT_INFO" then
            local ok, info = pcall(serialization.unserialize, p[1])
            if ok and type(info) == "table" then matches, success, detail = true, true, p[1] end
        end
    elseif envelope.kind == "RUNTIME" then
        if p[1] == "ERROR" then matches, detail = true, p[2]
        elseif (command == "ARM" or command == "DISARM") and p[1] == "ACK" and p[2] == command then
            matches, success, detail = true, p[3] == true, p[4]
        elseif command == "PING" and p[1] == "PONG" then
            matches, success, detail = true, true, p[2]
        elseif (command == "LAUNCH" or command == "LAUNCH_SILO") and p[1] == "LAUNCH_RESULT" then
            matches, success, detail = true, p[2] == true, serialization.serialize(p)
        elseif command == "STRIKE" and p[1] == "STRIKE_RESULT" then
            local ok, results = pcall(serialization.unserialize, p[2])
            if ok and type(results) == "table" and #results > 0 then
                matches, success, detail = true, true, p[2]
                for _, result in ipairs(results) do
                    if type(result) ~= "table" or result.success ~= true then success = false end
                end
            end
        end
    end
    if not matches then return end
    if envelope.replyTo == request.id then request.result = {ok = success, detail = detail}
    elseif envelope.replyTo == nil then request.legacy = true end
end

local function handleEnvelope(port, envelope)
    if not validEnvelope(envelope) or seenMessages[envelope.id] then return end
    seenMessages[envelope.id] = now()
    if string.upper(envelope.destination) ~= CENTRAL_ID and envelope.destination ~= "*" then return end

    collectOperatorReply(port, envelope)
    local output = commandOutput
    if pendingOperator then commandOutput = nil end
    if port == MGMT_PORT then
        handleMgmtEnvelope(envelope)
    elseif port == OP_PORT and envelope.kind == "RUNTIME" then
        handleRuntimeEnvelope(envelope)
    end
    commandOutput = output
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
    if not options.log then term.clear() end
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
    print("IFF:          friendly outbound")
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
            clip(launcher.label or ("L" .. tostring(launcher.index)), 9),
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
                track.friendly and "FRIENDLY" or trackState(track)
            ))
            if track.friendly then
                print("           IFF: FRIENDLY_OUTBOUND source=" .. tostring(track.friendlySource)
                    .. " target=" .. tostring(track.friendlyTargetX) .. "," .. tostring(track.friendlyTargetZ))
            else
                local approach = closestApproach(track)
                if approach and approach.inbound then
                    print("           THREAT closest=" .. string.format("%.1f", approach.closest)
                        .. " tca=" .. string.format("%.1fs", approach.t))
                end
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

    if node.status and node.status.intelligence then
        print("Satellite:   " .. tostring(node.status.satelliteType or "unavailable"))
        print("Link address:" .. tostring(node.status.satelliteAddress or "---"))
        print("Scan:        " .. tostring(node.status.scanState or "---"))
        if node.status.scanProgress then print("Progress:    " .. tostring(node.status.scanProgress)) end
        if node.status.error then print("Error:       " .. tostring(node.status.error)) end
    elseif node.multiLauncher then
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
    print("IFF pending:   " .. tostring(countFriendlyExpectations()))
    print("IFF window:    " .. tostring(IFF_MATCH_WINDOW) .. "s / " .. tostring(IFF_HEADING_TOLERANCE) .. "deg")
    print("Confirm:       " .. DEFENSE_CONFIRM_SAMPLES .. " distinct observations")
    print("============================================================")
    print("")
end

local function printLaunchSites()
    print("")
    print("POSSIBLE LAUNCH SITES")
    print("================================================================================")
    print("ID   POSITION             LAUNCHES CONFIDENCE LAST SOURCE")
    print("--------------------------------------------------------------------------------")
    local list = {}
    for _, site in pairs(launchSites) do table.insert(list, site) end
    table.sort(list, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
    if #list == 0 then
        print("No possible launch sites recorded.")
    else
        for _, site in ipairs(list) do
            local pos = string.format("%d,%d,%d", site.x or 0, site.y or 0, site.z or 0)
            print(string.format(
                "#%-3s %-20s %-8s %-10s %s:%s",
                tostring(site.id),
                pos,
                tostring(site.launches or 0),
                tostring(site.confidence or launchSiteConfidence(site.launches)),
                tostring(site.station or "---"),
                tostring(site.lastTrackId or "---")
            ))
        end
    end
    print("")
end

local function printLaunchSite(id)
    local site = launchSites[tonumber(id)]
    if not site then print("Launch site not found."); return end
    print("")
    print("POSSIBLE LAUNCH SITE #" .. tostring(site.id))
    print("============================================================")
    print("Position:     X=" .. tostring(math.floor((site.x or 0) + 0.5))
        .. " Y=" .. tostring(math.floor((site.y or 0) + 0.5))
        .. " Z=" .. tostring(math.floor((site.z or 0) + 0.5)))
    print("Launches:     " .. tostring(site.launches or 0))
    print("Confidence:   " .. tostring(site.confidence or launchSiteConfidence(site.launches)))
    print("Last station: " .. tostring(site.station or "---"))
    print("Last track:   " .. tostring(site.lastTrackId or "---"))
    print("Last type:    " .. tostring(site.lastTypeName or "---"))
    print("Strike hint:  strike SILO-S2 <class> <count> "
        .. tostring(math.floor((site.x or 0) + 0.5)) .. " "
        .. tostring(math.floor((site.z or 0) + 0.5)))
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

local function awaitStatus(node, detail)
    if node.lastStatus then print("Last known status: " .. string.format("%.1fs", now() - node.lastStatus) .. " old; refreshing...") end
    local token = requestRuntimeStatus(node, true, detail)
    if not token then print("Runtime unavailable or node offline."); return false end
    local deadline = now() + 5
    while node.statusComplete ~= token and now() < deadline do event.pull(0.1) end
    if node.statusComplete ~= token then
        print("TIMEOUT: no fresh status from " .. node.id .. "; cached information was not confirmed.")
        return false
    end
    return true
end

local function awaitControl(node, port, command, afterSend, ...)
    local request = {node = node, port = port, command = command}
    pendingOperator = request
    local send = port == MGMT_PORT and sendMgmt or sendOperational
    local sent = send(node, command, ...)
    if not sent then
        pendingOperator = nil
        commandFailed = true
        print("SEND FAILED: " .. command .. " on " .. node.id)
        return false
    end
    -- Register IFF intent before processing delayed results or radar events.
    if afterSend then afterSend() end
    local deadline = now() + 8
    while not request.result and now() < deadline do
        if options.stopping and options.stopping() then break end
        event.pull(0.1)
    end
    pendingOperator = nil
    if request.result then
        commandFailed = commandFailed or not request.result.ok
        print((request.result.ok and "CONFIRMED: " or "REJECTED: ") .. command .. " on " .. node.id
            .. (request.result.detail ~= nil and (" | " .. tostring(request.result.detail)) or ""))
        return request.result.ok
    end
    commandFailed = true
    if request.legacy then
        print("SENT / UNCONFIRMED: " .. command .. " on " .. node.id .. "; reply has no request ID; upgrade the node bootstrap for confirmed commands.")
    else
        print("TIMEOUT / UNCONFIRMED: " .. command .. " on " .. node.id .. "; no matching reply. Command was not replayed; check node status before retrying.")
    end
    return false
end

local function confirmAction(token, action)
    if options.nextCommand then
        pendingConfirmation = {token = token, action = action, expires = now() + 30}
        print("Type confirm " .. token .. " within 30 seconds, or cancel.")
        return
    end
    io.write("Type " .. token .. " to confirm: ")
    if io.read() == token then action() else print("Cancelled.") end
end

local function awaitRuntimeReply(node, command, arg1, arg2)
    local token = nextMessageId()
    local sent
    if command == "SCAN" then sent = sendOperational(node, command, arg1, arg2, token)
    elseif command == "SCAN_STATUS" or command == "HARDWARE" then sent = sendOperational(node, command, token)
    else sent = sendOperational(node, command, arg1, token) end
    if not sent then print("Node offline or send failed."); return false end
    local deadline = now() + 8
    while now() < deadline do
        if node.lastReply and node.lastReply.token == token then return node.lastReply.kind ~= "ERROR" end
        event.pull(0.1)
    end
    print("TIMEOUT: " .. command .. " on " .. node.id)
    return false
end

local function scanCommand(args)
    local node = getNode(args[2])
    local offset = node and 3 or 2
    local sub = string.lower(args[offset] or "status")
    local commands = {status = "SCAN_STATUS", results = "SCAN_RESULTS", structure = "SCAN_STRUCTURE"}
    local command = commands[sub] or "SCAN"
    local first = commands[sub] and args[offset + 1] or args[offset]
    local second = commands[sub] and nil or args[offset + 1]
    if node then return awaitRuntimeReply(node, command, first, second) end
    if not commands[sub] and not tonumber(args[2]) then print("Node not found, or invalid coordinates. Use scan [node] <x> <z>."); return end
    local path = options.appDir and options.appDir .. "/runtime/intel.lua"
    local chunk, err = path and loadfile(path)
    if not chunk then print("Local scan module unavailable: " .. tostring(err or "use the installer")); return end
    local runtime = chunk()
    local ok, message = pcall(function()
        runtime.start({id = CENTRAL_ID, role = "intel", config = {}, log = print,
            send = function(_, _, text) print(text) end})
        runtime.onMessage(CENTRAL_ID, command, first, second)
    end)
    if runtime.stop then pcall(runtime.stop) end
    if not ok then print("SCAN ERROR: " .. tostring(message)) end
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
    local expected = {}
    for _, launcher in ipairs(selected) do expected[launcher.index] = launcher.missileName end
    confirmAction("STRIKE", function()
        if not awaitStatus(node) then return end
        for index, item in pairs(expected) do
            local current = node.launchers and node.launchers[index]
            if not current or not current.ready or current.missileName ~= item then
                print("REJECTED: launcher inventory changed; create a new strike plan.")
                return
            end
        end
        awaitControl(node, OP_PORT, "STRIKE", function() registerFriendlyExpectation(node, #selected, x, z, "strike") end,
            serialization.serialize(plan), serialization.serialize({x = x, z = z}))
    end)
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
    print("  launchsites")
    print("  launchsite <id>")
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
    print("Satellite: scan [node] <x> <z> | scan [node] status|results [page]|structure [page]")
    print("Hologram:  hologram status | list | select <number|all> | view cutaway|structure|findings")
    print("           hologram show <node> | clear | bind <projector-address>")
    print("Setup: doctor [node] | hardware <node> | map <node> <label> <pad> <inventory> <side> [slot]")
    print("  alias <node> <name> | maintenance <node> on|off | defense node <node>")
    print("  confirm LAUNCH|STRIKE | cancel")
    print("Console: clear, help, quit (detach when installed as a service)")
    print("Service console: logs [count] | update check|status|apply|rollback")
    print("")
end

local function execute(line)
    local args = splitWords(line)
    local command = string.lower(args[1] or "")

    if command == "" then return
    elseif command == "help" then printHelp()
    elseif command == "cancel" then pendingConfirmation = nil; print("Cancelled.")
    elseif command == "confirm" then
        local pending = pendingConfirmation
        pendingConfirmation = nil
        if not pending or pending.token ~= args[2] or now() > pending.expires then
            print("No matching unexpired confirmation.")
        else pending.action() end
    elseif command == "scan" then scanCommand(args)
    elseif command == "hologram" then
        if not hologram then print("Hologram viewer unavailable; update CENTRAL using the installer."); return end
        local value = args[3]
        if args[2] == "show" then local node = getNode(value); value = node and node.id or value end
        local ok, text = hologram.command(args[2], value)
        if ok and args[2] == "bind" then
            hologramAddress = value
            if not savePreferences() then print("Projector selected for this session; saving the binding failed.") end
        end
        if not ok then commandFailed = true end
        print(text)
    elseif command == "doctor" then
        local node = getNode(args[2])
        if args[2] and not node then print("Node not found."); return end
        if node then
            print(node.id .. ": " .. (nodeOnline(node) and "online" or "offline")
                .. " bootstrap=" .. node.bootstrapVersion .. " runtime=" .. node.runtimeVersion
                .. " intent=" .. desiredState(node) .. " state=" .. node.runtimeState)
            if node.rejectedVersion then print("Rejected update: " .. node.rejectedVersion .. "; explicit deploy retries it.") end
            if awaitStatus(node) and node.status then print(serialization.serialize(node.status)) end
        else
            print("CENTRAL " .. VERSION .. " modem=" .. modemAddress .. " ports=" .. MGMT_PORT .. "/" .. OP_PORT)
            print("Startup mode: " .. (options.nextCommand and "background service" or "manual; run installer to enable boot startup"))
            print("Runtime bundle: " .. tostring(options.appDir or REPOSITORY_DIR))
            for _, known in pairs(nodes) do
                print(known.id .. " " .. known.role .. " " .. known.runtimeState .. " intent=" .. desiredState(known))
            end
        end
    elseif command == "hardware" or command == "map" then
        local node = getNode(args[2]); if not node then print("Node not found."); return end
        if command == "hardware" then awaitRuntimeReply(node, "HARDWARE")
        else
            local side, slot = tonumber(args[6]), tonumber(args[7])
            if not args[5] or not side or side % 1 ~= 0 or side < 0 or side > 5
                or (args[7] and (not slot or slot < 1 or slot % 1 ~= 0)) then
                print("Usage: map <node> <label> <pad-address> <inventory-address> <side> [slot]"); return
            end
            awaitRuntimeReply(node, "MAP", serialization.serialize({label=args[3], padAddress=args[4], inventoryAddress=args[5], side=side, slot=slot}))
        end
    elseif command == "alias" then
        local node = getNode(args[2]); if not node or not args[3] then print("Usage: alias <node> <name>"); return end
        local existing = getNode(args[3])
        if existing and existing.id ~= node.id then print("Alias already used."); return end
        nodePreferences[node.id] = nodePreferences[node.id] or {}
        nodePreferences[node.id].alias = args[3]
        if savePreferences() then print(args[3] .. " -> " .. node.id) end
    elseif command == "maintenance" then
        local node = getNode(args[2]); local value = args[3]
        if not node or (value ~= "on" and value ~= "off") then print("Usage: maintenance <node> on|off"); return end
        nodePreferences[node.id] = nodePreferences[node.id] or {}
        nodePreferences[node.id].desiredState = value == "on" and "maintenance" or "running"
        if savePreferences() then awaitControl(node, MGMT_PORT, value == "on" and "MAINTENANCE" or "START") end
    elseif command == "discover" then discover()
    elseif command == "nodes" then printNodes()
    elseif command == "radars" then printRadars()
    elseif command == "radar" then
        local node = getNode(args[2]); if not node then print("Usage: radar <node>"); return end
        if awaitStatus(node, "full") then printRadarNode(node) end
    elseif command == "tracks" then
        if args[2] and not getNode(args[2]) then print("Node not found."); return end
        printTracks(args[2])
    elseif command == "launchsites" then
        printLaunchSites()
    elseif command == "launchsite" then
        if not tonumber(args[2]) then print("Usage: launchsite <id>"); return end
        printLaunchSite(args[2])
    elseif command == "defense" then
        local sub = string.lower(args[2] or "")
        if sub == "node" then
            if not args[3] then print("Usage: defense node <node>"); return end
            ABM_NODE_ID = string.upper(args[3])
            if savePreferences() then print("Defense node: " .. ABM_NODE_ID) end
        elseif sub == "protect" then
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
            savePreferences()
            print("[DEFENSE] Protected zone X=" .. x .. " Z=" .. z .. " radius=" .. radius)
        elseif sub == "auto" then
            local value = string.lower(args[3] or "")
            if value == "on" then
                if not defenseZoneConfigured() then
                    print("REJECTED: configure protection zone first with defense protect <x> <z> <radius>.")
                    return
                end
                defense.auto = true
                savePreferences()
                print("[DEFENSE] Automatic engagement ENABLED")
            elseif value == "off" then
                defense.auto = false
                savePreferences()
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
        awaitControl(node, MGMT_PORT, "INFO")
    elseif command == "deploy" then
        if string.lower(args[2] or "") == "all" then
            for _, node in pairs(nodes) do if node.claimed and nodeOnline(node) then node.rejectedVersion = nil; deployNode(node) end end
        else
            local node = getNode(args[2]); if not node then print("Usage: deploy <node|all>"); return end
            node.rejectedVersion = nil
            deployNode(node)
        end
    elseif command == "start" or command == "stop" or command == "restart" then
        local node = getNode(args[2]); if not node then print("Usage: " .. command .. " <node>"); return end
        nodePreferences[node.id] = nodePreferences[node.id] or {}
        nodePreferences[node.id].desiredState = command == "stop" and "stopped" or "running"
        if savePreferences() then
            if command == "stop" and node.deployment then failDeployment(node, "OPERATOR_STOP") end
            node.deployQueued = nil
            awaitControl(node, MGMT_PORT, string.upper(command))
        end
    elseif command == "status" then
        local node = getNode(args[2]); if not node then print("Usage: status <node>"); return end
        if awaitStatus(node) then printStatus(node) end
    elseif command == "payloads" then
        local node = getNode(args[2]); if not node then print("Usage: payloads <node>"); return end
        if awaitStatus(node) then printPayloads(node) end
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
        awaitControl(node, OP_PORT, "PING")
    elseif command == "arm" or command == "disarm" then
        local node = getNode(args[2]); if not node then print("Usage: " .. command .. " <node> [launcher|all]"); return end
        if tostring(node.role) == "radar" then
            print("Radar nodes do not support arm/disarm.")
            return
        end
        if node.multiLauncher then
            local selector = args[3]
            if not selector then print("Usage: " .. command .. " <node> <launcher|all>"); return end
            awaitControl(node, OP_PORT, string.upper(command), nil, selector)
        else
            awaitControl(node, OP_PORT, string.upper(command))
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
            local expected = launcherStatus.missileName
            confirmAction("LAUNCH", function()
                if not awaitStatus(node) then return end
                local current = node.launchers and node.launchers[launcher]
                if not current or not current.armed or not current.ready or current.missileName ~= expected then
                    print("REJECTED: launcher readiness or payload changed."); return
                end
                awaitControl(node, OP_PORT, "LAUNCH_SILO", function() registerFriendlyExpectation(node, 1, x, z, "launch") end,
                    launcher, serialization.serialize({x = x, z = z}))
            end)
        else
            local x = tonumber(args[3]); local z = tonumber(args[4])
            if not x or not z then print("Usage: launch <node> <x> <z>"); return end
            if node.armed ~= true then print("REJECTED: node is not armed."); return end
            print("Missile: " .. clip(node.missileLabel, 30))
            print("Target: X=" .. x .. " Z=" .. z)
            local expected = node.missileName
            confirmAction("LAUNCH", function()
                if not awaitStatus(node) then return end
                if not node.armed or not node.ready or node.missileName ~= expected then
                    print("REJECTED: readiness or payload changed."); return
                end
                awaitControl(node, OP_PORT, "LAUNCH", function() registerFriendlyExpectation(node, 1, x, z, "launch") end, x, z)
            end)
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
    elseif command == "quit" then
        if options.nextCommand then print("Console detached; service remains active.") else running = false end
    else print("Unknown command. Type 'help'.") end
end

modem.open(MGMT_PORT)
modem.open(OP_PORT)
event.listen("modem_message", onModemMessage)
local deploymentTimer = event.timer(1, checkDeploymentTimeouts, math.huge)
local statusTimer = event.timer(0.25, pollRuntimeStatus, math.huge)
local pruneTimer = event.timer(PRUNE_INTERVAL, pruneSeen, math.huge)
local defenseTimer = event.timer(1, defenseTick, math.huge)

loadPreferences()
local hologramTimer
if options.appDir then
    local chunk, err = loadfile(options.appDir .. "/central/hologram.lua")
    if chunk then
        hologram = chunk()({component=component, now=now, log=print, address=hologramAddress,
            send=function(id, ...) local node=getNode(id); return node and sendOperational(node, ...) end})
        hologramTimer = event.timer(0.25, hologram.tick, math.huge)
    else print("[HOLOGRAM] Viewer unavailable: " .. tostring(err)) end
end
loadPayloadCatalog()
loadLaunchSites()
printHeader()
syncRepository()
discover()
if options.ready then options.ready() end
print("Type 'help' for commands.")
print("")

while running do
    if options.stopping and options.stopping() then break end
    if pendingConfirmation and now() > pendingConfirmation.expires then pendingConfirmation = nil end
    if options.setBusy then
        local busy = next(activeEngagements) ~= nil or pendingConfirmation ~= nil or (hologram and hologram.busy())
        for _, node in pairs(nodes) do
            if node.deploying or (nodeOnline(node) and (node.armed or (node.armedCount or 0) > 0)) then busy = true end
        end
        options.setBusy(busy)
    end
    if options.nextCommand then
        local request = options.nextCommand()
        if request then
            commandOutput = {}
            commandFailed = false
            local ok, err = pcall(execute, request.line)
            pendingOperator = nil
            local text = table.concat(commandOutput, "\n")
            commandOutput = nil
            if not ok then text = text .. "\nERROR: " .. tostring(err) end
            if options.reply then options.reply(request.id, ok and not commandFailed, text) end
        end
        event.pull(0.1)
    else
        io.write("STRATCOM> ")
        local line = io.read()
        if not line then break end
        execute(line)
    end
end

defense.auto = false
event.cancel(pruneTimer)
if hologramTimer then event.cancel(hologramTimer) end
event.cancel(defenseTimer)
event.cancel(statusTimer)
event.cancel(deploymentTimer)
event.ignore("modem_message", onModemMessage)
modem.close(OP_PORT)
modem.close(MGMT_PORT)
print("STRATCOM central stopped.")
