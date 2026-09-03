local component = require("component")
local event = require("event")
local computer = require("computer")
local filesystem = require("filesystem")
local serialization = require("serialization")
local keyboard = require("keyboard")

local VERSION = "2.0.0"
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
local NODE_ID = assert(config.id, "config.id is required")
local NODE_ROLE = assert(config.role, "config.role is required")
local MGMT_PORT = tonumber(config.managementPort or config.port) or 4510
local OP_PORT = tonumber(config.operationalPort) or 4511
local HEARTBEAT_INTERVAL = tonumber(config.heartbeatInterval) or 5

local modemAddress = component.list("modem")()
if not modemAddress then
    io.stderr:write("FATAL: No modem detected.\n")
    return
end

local modem = component.proxy(modemAddress)
local controllerAddress = nil
local runtimeModule = nil
local runtimeRunning = false
local deployment = nil
local running = true
local lastHeartbeat = 0

local function log(message)
    print(string.format("[%06.1f] %s", computer.uptime(), tostring(message)))
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

local function sendMgmt(remoteAddress, messageType, ...)
    modem.send(remoteAddress, MGMT_PORT, messageType, NODE_ID, ...)
end

local function broadcastHello()
    modem.broadcast(
        MGMT_PORT,
        "BOOT_HELLO",
        NODE_ID,
        NODE_ROLE,
        VERSION,
        installedRuntimeVersion(),
        runtimeState()
    )
end

local function broadcastHeartbeat()
    modem.broadcast(
        MGMT_PORT,
        "BOOT_HEARTBEAT",
        NODE_ID,
        NODE_ROLE,
        VERSION,
        installedRuntimeVersion(),
        runtimeState()
    )
    lastHeartbeat = computer.uptime()
end

local function sendInfo(remoteAddress)
    local info = {
        id = NODE_ID,
        role = NODE_ROLE,
        bootstrapVersion = VERSION,
        runtimeVersion = installedRuntimeVersion(),
        runtimeState = runtimeState(),
        managementPort = MGMT_PORT,
        operationalPort = OP_PORT,
        controller = controllerAddress,
    }

    sendMgmt(remoteAddress, "BOOT_INFO", serialization.serialize(info))
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
        send = function(remoteAddress, responseType, ...)
            modem.send(
                remoteAddress,
                OP_PORT,
                "RUNTIME",
                NODE_ID,
                responseType,
                ...
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

local function beginDeployment(remoteAddress, version, totalChunks)
    stopRuntime()
    abortDeployment()

    local total = tonumber(totalChunks)
    if not total or total < 1 then
        sendMgmt(remoteAddress, "MGMT_ERROR", "DEPLOY_BEGIN", "INVALID_CHUNK_COUNT")
        return
    end

    local file, err = io.open(TEMP_RUNTIME, "w")
    if not file then
        sendMgmt(remoteAddress, "MGMT_ERROR", "DEPLOY_BEGIN", tostring(err))
        return
    end

    deployment = {
        version = tostring(version),
        total = total,
        next = 1,
        file = file,
    }

    sendMgmt(remoteAddress, "MGMT_ACK", "DEPLOY_BEGIN", deployment.version)
end

local function receiveChunk(remoteAddress, index, data)
    if not deployment then
        sendMgmt(remoteAddress, "MGMT_ERROR", "DEPLOY_CHUNK", "NO_DEPLOYMENT")
        return
    end

    local chunkIndex = tonumber(index)
    if chunkIndex ~= deployment.next then
        sendMgmt(
            remoteAddress,
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

local function commitDeployment(remoteAddress, version)
    if not deployment then
        sendMgmt(remoteAddress, "MGMT_ERROR", "DEPLOY_COMMIT", "NO_DEPLOYMENT")
        return
    end

    if tostring(version) ~= deployment.version then
        sendMgmt(remoteAddress, "MGMT_ERROR", "DEPLOY_COMMIT", "VERSION_MISMATCH")
        abortDeployment()
        return
    end

    if deployment.next ~= deployment.total + 1 then
        sendMgmt(remoteAddress, "MGMT_ERROR", "DEPLOY_COMMIT", "MISSING_CHUNKS")
        abortDeployment()
        return
    end

    deployment.file:close()
    deployment.file = nil

    local chunk, loadErr = loadfile(TEMP_RUNTIME)
    if not chunk then
        sendMgmt(
            remoteAddress,
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
            remoteAddress,
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
    sendMgmt(remoteAddress, "MGMT_DEPLOY_RESULT", true, deployedVersion, "OK")
end

local function managementCommand(remoteAddress, command, arg1, arg2, arg3)
    if command == "DISCOVER" then
        broadcastHello()
        return
    end

    if command == "CLAIM" then
        if controllerAddress == nil or controllerAddress == remoteAddress then
            controllerAddress = remoteAddress
            sendMgmt(remoteAddress, "MGMT_ACK", "CLAIM", true)
            sendInfo(remoteAddress)
            log("Claimed by central " .. remoteAddress)
        else
            sendMgmt(remoteAddress, "MGMT_ERROR", "CLAIM", "ALREADY_CLAIMED")
        end
        return
    end

    if remoteAddress ~= controllerAddress then
        return
    end

    if command == "INFO" then
        sendInfo(remoteAddress)
    elseif command == "DEPLOY_BEGIN" then
        beginDeployment(remoteAddress, arg1, arg2)
    elseif command == "DEPLOY_CHUNK" then
        receiveChunk(remoteAddress, arg1, arg2)
    elseif command == "DEPLOY_COMMIT" then
        commitDeployment(remoteAddress, arg1)
    elseif command == "START" then
        local ok, err = startRuntime()
        sendMgmt(remoteAddress, "MGMT_ACK", "START", ok, err or "OK")
    elseif command == "STOP" then
        stopRuntime()
        sendMgmt(remoteAddress, "MGMT_ACK", "STOP", true)
    elseif command == "RESTART" then
        stopRuntime()
        local ok, err = startRuntime()
        sendMgmt(remoteAddress, "MGMT_ACK", "RESTART", ok, err or "OK")
    end
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
        a6,
        a7,
        a8,
        a9 = event.pull(1)

    if eventName == "key_down" then
        local keyCode = a3
        local ok, ctrlDown = pcall(keyboard.isControlDown)
        if keyCode == keyboard.keys.c and ok and ctrlDown then
            log("Local Ctrl+C shutdown requested")
            running = false
        end
    elseif eventName == "modem_message" then
        local remoteAddress = a2
        local port = a3
        local messageType = a5

        if port == MGMT_PORT and messageType == "MGMT" then
            managementCommand(remoteAddress, a6, a7, a8, a9)
        elseif
            port == OP_PORT
            and messageType == "CMD"
            and remoteAddress == controllerAddress
            and runtimeRunning
            and runtimeModule
            and type(runtimeModule.onMessage) == "function"
        then
            local ok, err = pcall(runtimeModule.onMessage, remoteAddress, a6, a7, a8)
            if not ok then
                modem.send(
                    remoteAddress,
                    OP_PORT,
                    "RUNTIME",
                    NODE_ID,
                    "ERROR",
                    "RUNTIME_EXCEPTION",
                    tostring(err)
                )
            end
        end
    end

    if runtimeRunning and runtimeModule and type(runtimeModule.tick) == "function" then
        local ok, err = pcall(runtimeModule.tick)
        if not ok then
            log("Runtime tick failed: " .. tostring(err))
            stopRuntime()
        end
    end

    if computer.uptime() - lastHeartbeat >= HEARTBEAT_INTERVAL then
        broadcastHeartbeat()
    end
end

stopRuntime()
abortDeployment()
modem.close(OP_PORT)
modem.close(MGMT_PORT)
log("Bootstrap stopped.")
