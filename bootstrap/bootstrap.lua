local component = require("component")
local event = require("event")
local computer = require("computer")
local filesystem = require("filesystem")
local serialization = require("serialization")
local keyboard = require("keyboard")

local VERSION = "2.1.0"
local PROTOCOL = 2
local CENTRAL_ID = "CENTRAL"
local CONFIG_PATH = "/home/stratcom/config.lua"
local RUNTIME_DIR = "/home/stratcom/runtime"
local CURRENT_RUNTIME = RUNTIME_DIR .. "/current.lua"
local PREVIOUS_RUNTIME = RUNTIME_DIR .. "/previous.lua"
local TEMP_RUNTIME = RUNTIME_DIR .. "/incoming.lua"
local VERSION_PATH = RUNTIME_DIR .. "/version.txt"

if not filesystem.exists(CONFIG_PATH) then
    io.stderr:write("FATAL: Missing " .. CONFIG_PATH .. "\n")
    return
end

if not filesystem.exists(RUNTIME_DIR) then
    filesystem.makeDirectory(RUNTIME_DIR)
end

local config = dofile(CONFIG_PATH)
local NODE_ID = string.upper(assert(config.id, "config.id is required"))
local NODE_ROLE = assert(config.role, "config.role is required")
local MGMT_PORT = tonumber(config.managementPort or config.port) or 4510
local OP_PORT = tonumber(config.operationalPort) or 4511
local HEARTBEAT_INTERVAL = tonumber(config.heartbeatInterval) or 5
local DEFAULT_TTL = tonumber(config.meshTtl) or 6
local SEEN_TTL = 30
local PRUNE_INTERVAL = 10

local modemAddress = component.list("modem")()
if not modemAddress then
    io.stderr:write("FATAL: No modem detected.\n")
    return
end

local modem = component.proxy(modemAddress)
local controllerId = nil
local runtimeModule = nil
local runtimeRunning = false
local deployment = nil
local running = true
local lastHeartbeat = 0
local lastPrune = 0
local messageCounter = 0
local seenMessages = {}

local function now()
    return computer.uptime()
end

local function log(message)
    print(string.format("[%06.1f] %s", now(), tostring(message)))
end

local function readFirstLine(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local value = file:read("*l")
    file:close()
    return value
end

local function writeText(path, value)
    local file, err = io.open(path, "w")
    if not file then return false, err end
    file:write(tostring(value))
    file:write("\n")
    file:close()
    return true
end

local function installedRuntimeVersion()
    return readFirstLine(VERSION_PATH) or "none"
end

local function runtimeState()
    if runtimeRunning then return "running" end
    if filesystem.exists(CURRENT_RUNTIME) then return "stopped" end
    return "missing"
end

local function nextMessageId()
    messageCounter = messageCounter + 1
    return table.concat({
        NODE_ID,
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
        source = NODE_ID,
        destination = string.upper(tostring(destination)),
        ttl = tonumber(ttl) or DEFAULT_TTL,
        kind = tostring(kind),
        payload = payload or {},
    }

    seenMessages[envelope.id] = now()
    return transmitEnvelope(port, envelope)
end

local function relayEnvelope(port, envelope)
    if envelope.ttl <= 0 then return end
    envelope.ttl = envelope.ttl - 1
    transmitEnvelope(port, envelope)
end

local function sendMgmt(messageType, ...)
    return originate(MGMT_PORT, CENTRAL_ID, messageType, {...})
end

local function broadcastHello()
    originate(
        MGMT_PORT,
        CENTRAL_ID,
        "BOOT_HELLO",
        {
            NODE_ID,
            NODE_ROLE,
            VERSION,
            installedRuntimeVersion(),
            runtimeState(),
        }
    )
end

local function broadcastHeartbeat()
    originate(
        MGMT_PORT,
        CENTRAL_ID,
        "BOOT_HEARTBEAT",
        {
            NODE_ID,
            NODE_ROLE,
            VERSION,
            installedRuntimeVersion(),
            runtimeState(),
        }
    )
    lastHeartbeat = now()
end

local function sendInfo()
    local info = {
        id = NODE_ID,
        role = NODE_ROLE,
        bootstrapVersion = VERSION,
        runtimeVersion = installedRuntimeVersion(),
        runtimeState = runtimeState(),
        managementPort = MGMT_PORT,
        operationalPort = OP_PORT,
        controller = controllerId,
        meshProtocol = PROTOCOL,
        meshTtl = DEFAULT_TTL,
    }

    sendMgmt("BOOT_INFO", serialization.serialize(info))
end

local function stopRuntime()
    if runtimeModule and type(runtimeModule.stop) == "function" then
        pcall(runtimeModule.stop)
    end

    runtimeModule = nil
    runtimeRunning = false
end

local function startRuntime()
    if runtimeRunning then return true end
    if not filesystem.exists(CURRENT_RUNTIME) then
        return false, "NO_RUNTIME"
    end

    local chunk, loadErr = loadfile(CURRENT_RUNTIME)
    if not chunk then return false, "LOAD_FAILED: " .. tostring(loadErr) end

    local ok, module = pcall(chunk)
    if not ok then return false, "INIT_FAILED: " .. tostring(module) end
    if type(module) ~= "table" or type(module.start) ~= "function" then
        return false, "INVALID_RUNTIME_INTERFACE"
    end

    local context = {
        id = NODE_ID,
        role = NODE_ROLE,
        managementPort = MGMT_PORT,
        operationalPort = OP_PORT,
        send = function(destination, responseType, ...)
            originate(
                OP_PORT,
                destination or CENTRAL_ID,
                "RUNTIME",
                {responseType, ...}
            )
        end,
        log = log,
    }

    local started, startErr = pcall(module.start, context)
    if not started then
        return false, "START_FAILED: " .. tostring(startErr)
    end

    runtimeModule = module
    runtimeRunning = true
    return true
end

local function abortDeployment()
    if deployment and deployment.file then
        pcall(function() deployment.file:close() end)
    end
    deployment = nil
    if filesystem.exists(TEMP_RUNTIME) then filesystem.remove(TEMP_RUNTIME) end
end

local function beginDeployment(version, totalChunks)
    stopRuntime()
    abortDeployment()

    local total = tonumber(totalChunks)
    if not total or total < 1 then
        sendMgmt("MGMT_ERROR", "DEPLOY_BEGIN", "INVALID_CHUNK_COUNT")
        return
    end

    local file, err = io.open(TEMP_RUNTIME, "w")
    if not file then
        sendMgmt("MGMT_ERROR", "DEPLOY_BEGIN", tostring(err))
        return
    end

    deployment = {
        version = tostring(version),
        total = total,
        next = 1,
        file = file,
    }

    sendMgmt("MGMT_ACK", "DEPLOY_BEGIN", deployment.version)
end

local function receiveChunk(index, data)
    if not deployment then
        sendMgmt("MGMT_ERROR", "DEPLOY_CHUNK", "NO_DEPLOYMENT")
        return
    end

    local chunkIndex = tonumber(index)
    if chunkIndex ~= deployment.next then
        sendMgmt(
            "MGMT_ERROR",
            "DEPLOY_CHUNK",
            "EXPECTED_" .. tostring(deployment.next)
        )
        abortDeployment()
        return
    end

    deployment.file:write(tostring(data or ""))
    deployment.next = deployment.next + 1
end

local function commitDeployment(version)
    if not deployment then
        sendMgmt("MGMT_ERROR", "DEPLOY_COMMIT", "NO_DEPLOYMENT")
        return
    end

    if tostring(version) ~= deployment.version then
        sendMgmt("MGMT_ERROR", "DEPLOY_COMMIT", "VERSION_MISMATCH")
        abortDeployment()
        return
    end

    if deployment.next ~= deployment.total + 1 then
        sendMgmt("MGMT_ERROR", "DEPLOY_COMMIT", "MISSING_CHUNKS")
        abortDeployment()
        return
    end

    deployment.file:close()
    deployment.file = nil

    local chunk, loadErr = loadfile(TEMP_RUNTIME)
    if not chunk then
        sendMgmt(
            "MGMT_DEPLOY_RESULT",
            false,
            deployment.version,
            "SYNTAX_ERROR: " .. tostring(loadErr)
        )
        abortDeployment()
        return
    end

    if filesystem.exists(PREVIOUS_RUNTIME) then filesystem.remove(PREVIOUS_RUNTIME) end
    if filesystem.exists(CURRENT_RUNTIME) then
        filesystem.rename(CURRENT_RUNTIME, PREVIOUS_RUNTIME)
    end

    if not filesystem.rename(TEMP_RUNTIME, CURRENT_RUNTIME) then
        if filesystem.exists(PREVIOUS_RUNTIME) then
            filesystem.rename(PREVIOUS_RUNTIME, CURRENT_RUNTIME)
        end
        sendMgmt(
            "MGMT_DEPLOY_RESULT",
            false,
            deployment.version,
            "INSTALL_FAILED"
        )
        deployment = nil
        return
    end

    local deployedVersion = deployment.version
    deployment = nil
    writeText(VERSION_PATH, deployedVersion)
    sendMgmt("MGMT_DEPLOY_RESULT", true, deployedVersion, "OK")
end

local function managementCommand(source, payload)
    local command = payload[1]
    local arg1 = payload[2]
    local arg2 = payload[3]

    if command == "DISCOVER" and source == CENTRAL_ID then
        broadcastHello()
        return
    end

    if command == "CLAIM" and source == CENTRAL_ID then
        if controllerId == nil or controllerId == CENTRAL_ID then
            controllerId = CENTRAL_ID
            sendMgmt("MGMT_ACK", "CLAIM", true)
            sendInfo()
            log("Claimed by central")
        else
            sendMgmt("MGMT_ERROR", "CLAIM", "ALREADY_CLAIMED")
        end
        return
    end

    if source ~= controllerId or source ~= CENTRAL_ID then return end

    if command == "INFO" then
        sendInfo()
    elseif command == "DEPLOY_BEGIN" then
        beginDeployment(arg1, arg2)
    elseif command == "DEPLOY_CHUNK" then
        receiveChunk(arg1, arg2)
    elseif command == "DEPLOY_COMMIT" then
        commitDeployment(arg1)
    elseif command == "START" then
        local ok, err = startRuntime()
        sendMgmt("MGMT_ACK", "START", ok, err or "OK")
    elseif command == "STOP" then
        stopRuntime()
        sendMgmt("MGMT_ACK", "STOP", true)
    elseif command == "RESTART" then
        stopRuntime()
        local ok, err = startRuntime()
        sendMgmt("MGMT_ACK", "RESTART", ok, err or "OK")
    end
end

local function runtimeCommand(source, payload)
    if source ~= controllerId or source ~= CENTRAL_ID then return end
    if not runtimeRunning or not runtimeModule then return end
    if type(runtimeModule.onMessage) ~= "function" then return end

    local ok, err = pcall(
        runtimeModule.onMessage,
        source,
        payload[1],
        payload[2],
        payload[3]
    )

    if not ok then
        originate(
            OP_PORT,
            CENTRAL_ID,
            "RUNTIME",
            {"ERROR", "RUNTIME_EXCEPTION", tostring(err)}
        )
    end
end

local function handleEnvelope(port, envelope)
    if not validEnvelope(envelope) then return end
    if seenMessages[envelope.id] then return end

    seenMessages[envelope.id] = now()

    local destination = string.upper(envelope.destination)
    local localDelivery = destination == NODE_ID or destination == "*"

    if localDelivery then
        if port == MGMT_PORT and envelope.kind == "MGMT" then
            managementCommand(string.upper(envelope.source), envelope.payload)
        elseif port == OP_PORT and envelope.kind == "CMD" then
            runtimeCommand(string.upper(envelope.source), envelope.payload)
        end
    end

    if destination ~= NODE_ID and envelope.ttl > 0 then
        relayEnvelope(port, envelope)
    end
end

local function handleModemMessage(port, marker, encoded)
    if (port ~= MGMT_PORT and port ~= OP_PORT) or marker ~= "STRATCOM_NET" then
        return
    end

    local ok, envelope = pcall(serialization.unserialize, encoded)
    if not ok then return end
    handleEnvelope(port, envelope)
end

modem.open(MGMT_PORT)
modem.open(OP_PORT)

print("")
print("================================")
print("     STRATCOM NODE BOOTSTRAP")
print("================================")
print("Bootstrap:   " .. VERSION)
print("Node ID:     " .. NODE_ID)
print("Role:        " .. NODE_ROLE)
print("Mgmt Port:   " .. MGMT_PORT)
print("Op Port:     " .. OP_PORT)
print("Mesh:        protocol " .. PROTOCOL .. " / TTL " .. DEFAULT_TTL)
print("Runtime:     " .. installedRuntimeVersion() .. " / " .. runtimeState())
print("")
print("Waiting for central command...")
print("Ctrl+C to stop bootstrap.")
print("")

broadcastHello()
broadcastHeartbeat()

while running do
    local eventName,
        a1,
        a2,
        a3,
        a4,
        a5,
        a6 = event.pull(1)

    if eventName == "key_down" then
        local keyCode = a3
        local ok, ctrlDown = pcall(keyboard.isControlDown)
        if keyCode == keyboard.keys.c and ok and ctrlDown then
            log("Local Ctrl+C shutdown requested")
            running = false
        end
    elseif eventName == "modem_message" then
        local port = a3
        local marker = a5
        local encoded = a6
        handleModemMessage(port, marker, encoded)
    end

    if runtimeRunning and runtimeModule and type(runtimeModule.tick) == "function" then
        local ok, err = pcall(runtimeModule.tick)
        if not ok then
            log("Runtime tick failed: " .. tostring(err))
            stopRuntime()
        end
    end

    if now() - lastHeartbeat >= HEARTBEAT_INTERVAL then
        broadcastHeartbeat()
    end

    if now() - lastPrune >= PRUNE_INTERVAL then
        pruneSeen()
    end
end

stopRuntime()
abortDeployment()
modem.close(OP_PORT)
modem.close(MGMT_PORT)
log("Bootstrap stopped.")
