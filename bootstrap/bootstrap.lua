local options = ...
if type(options) ~= "table" then options = {} end
local component = require("component")
local event = require("event")
local computer = require("computer")
local filesystem = require("filesystem")
local serialization = require("serialization")
local keyboard = require("keyboard")

local VERSION = "3.0.0"
local PROTOCOL = 2
local CENTRAL_ID = "CENTRAL"
local CONFIG_PATH = "/home/stratcom/config.lua"
local RUNTIME_DIR = "/home/stratcom/runtime"
local CURRENT_RUNTIME = RUNTIME_DIR .. "/current.lua"
local PREVIOUS_RUNTIME = RUNTIME_DIR .. "/previous.lua"
local TEMP_RUNTIME = RUNTIME_DIR .. "/incoming.lua"
local VERSION_PATH = RUNTIME_DIR .. "/version.txt"
local PREVIOUS_VERSION = RUNTIME_DIR .. "/previous-version.txt"
local ACTIVATION_PATH = RUNTIME_DIR .. "/activation.txt"
local STATE_PATH = "/home/stratcom/node-state.txt"
local REJECTED_PATH = RUNTIME_DIR .. "/rejected-version.txt"
local DEPLOY_TIMEOUT = 60
local completed = {}
local localResponses = nil
local sessionCounter = 0
local runtimeSession = nil
local replyTo = nil

if not filesystem.exists(CONFIG_PATH) and filesystem.exists(CONFIG_PATH .. ".previous") then
    filesystem.rename(CONFIG_PATH .. ".previous", CONFIG_PATH)
end
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
local runtimeFailure = nil
local lastHeartbeat = 0
local lastPrune = 0
local messageCounter = 0
local seenMessages = {}

local function now()
    return computer.uptime()
end

local function log(message)
    (options.log or print)(string.format("[%06.1f] %s", now(), tostring(message)))
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
    local ok, writeErr = file:write(tostring(value) .. "\n")
    local closed, closeErr = file:close()
    if not ok then return false, writeErr end
    if closed == nil then return false, closeErr end
    return true
end

local function replaceText(path, value)
    local pending, previous = path .. ".pending", path .. ".previous"
    local ok, err = writeText(pending, value)
    if not ok then return false, err end
    if filesystem.exists(previous) then filesystem.remove(previous) end
    if filesystem.exists(path) and not filesystem.rename(path, previous) then return false, "BACKUP_FAILED" end
    if not filesystem.rename(pending, path) then
        if filesystem.exists(previous) then filesystem.rename(previous, path) end
        return false, "REPLACE_FAILED"
    end
    return true
end

if not filesystem.exists(STATE_PATH) and filesystem.exists(STATE_PATH .. ".previous") then
    filesystem.rename(STATE_PATH .. ".previous", STATE_PATH)
end
local desiredState = readFirstLine(STATE_PATH)
if not desiredState then
    desiredState = filesystem.exists(STATE_PATH) and "maintenance" or "running"
end
if desiredState ~= "running" and desiredState ~= "stopped" and desiredState ~= "maintenance" then desiredState = "maintenance" end
local function setDesired(state)
    local ok, err = replaceText(STATE_PATH, state)
    if not ok then return false, err end
    desiredState = state
    return true
end

local function copyRuntime(source, destination)
    local input, err = io.open(source, "r")
    if not input then return false, err end
    local data = input:read("*a"); input:close()
    if not data then return false, "READ_FAILED" end
    local output
    output, err = io.open(destination, "w")
    if not output then return false, err end
    local written, writeErr = output:write(data)
    local closed, closeErr = output:close()
    if not written or not closed then return false, writeErr or closeErr end
    return true
end

local function restorePrevious()
    if not filesystem.exists(PREVIOUS_RUNTIME) then return false, "NO_PREVIOUS_RUNTIME" end
    local ok, err = copyRuntime(PREVIOUS_RUNTIME, CURRENT_RUNTIME)
    if not ok then return false, err end
    return writeText(VERSION_PATH, readFirstLine(PREVIOUS_VERSION) or readFirstLine(VERSION_PATH) or "none")
end

local function installedRuntimeVersion()
    return readFirstLine(VERSION_PATH) or "none"
end

local function runtimeState()
    if desiredState == "maintenance" then return "maintenance" end
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
        replyTo = replyTo,
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
            desiredState,
            runtimeSession,
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
            desiredState,
            runtimeSession,
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
        desiredState = desiredState,
        previousVersion = readFirstLine(PREVIOUS_VERSION),
        rejectedVersion = readFirstLine(REJECTED_PATH),
    }

    sendMgmt("BOOT_INFO", serialization.serialize(info))
end

local function stopRuntime()
    if runtimeModule and type(runtimeModule.stop) == "function" then
        pcall(runtimeModule.stop)
    end

    runtimeModule = nil
    runtimeRunning = false
    runtimeSession = nil
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

    sessionCounter = sessionCounter + 1
    local session = nextMessageId() .. "-" .. tostring(sessionCounter)
    local context = {
        config = config,
        saveConfig = function(value)
            local updated = value or config
            local pending, backup = CONFIG_PATH .. ".pending", CONFIG_PATH .. ".previous"
            local ok, err = writeText(pending, "return " .. serialization.serialize(updated))
            if not ok then filesystem.remove(pending); return false, err end
            if filesystem.exists(backup) then filesystem.remove(backup) end
            ok, err = filesystem.rename(CONFIG_PATH, backup)
            if not ok then filesystem.remove(pending); return false, err end
            ok, err = filesystem.rename(pending, CONFIG_PATH)
            if not ok then
                local restored = filesystem.rename(backup, CONFIG_PATH)
                filesystem.remove(pending)
                return false, tostring(err) .. (restored and "" or "; CONFIG_RESTORE_FAILED")
            end
            config = updated
            return true
        end,
        session = session,
        id = NODE_ID,
        role = NODE_ROLE,
        managementPort = MGMT_PORT,
        operationalPort = OP_PORT,
        send = function(destination, responseType, ...)
            if localResponses or destination == NODE_ID then
                local values = {...}
                local out = {tostring(responseType)}
                for _, value in ipairs(values) do out[#out + 1] = type(value) == "table" and serialization.serialize(value) or tostring(value) end
                if localResponses then
                    localResponses[#localResponses + 1] = table.concat(out, " ")
                else
                    log(table.concat(out, " "))
                end
                return true
            end
            originate(
                OP_PORT,
                destination or CENTRAL_ID,
                "RUNTIME",
                {responseType, ...}
            )
        end,
        log = log,
    }

    local started, startErr, detail = pcall(module.start, context)
    if not started or startErr == false then
        if type(module.stop) == "function" then pcall(module.stop) end
        return false, "START_FAILED: " .. tostring(started and detail or startErr)
    end

    runtimeModule = module
    runtimeRunning = true
    runtimeSession = session
    return true
end

local function abortDeployment()
    if deployment and deployment.file then
        pcall(function() deployment.file:close() end)
    end
    deployment = nil
    if filesystem.exists(TEMP_RUNTIME) then filesystem.remove(TEMP_RUNTIME) end
end

local function deployError(command, message, transaction)
    sendMgmt("MGMT_ERROR", command, message, nil, transaction)
end

local function beginDeployment(version, totalChunks, transaction, checksum)
    if deployment and transaction and deployment.transaction == transaction then
        if deployment.version == tostring(version) and deployment.total == tonumber(totalChunks) and deployment.checksum == checksum then
            deployment.touched = now()
            sendMgmt("MGMT_ACK", "DEPLOY_BEGIN", true, deployment.version, transaction)
        else
            deployError("DEPLOY_BEGIN", "TRANSACTION_MISMATCH", transaction)
        end
        return
    end
    if deployment then deployError("DEPLOY_BEGIN", "BUSY", transaction); return end
    local total = tonumber(totalChunks)
    if type(version) ~= "string" or version == "" or not total or total < 1 or total > 16384 or total % 1 ~= 0
        or (transaction ~= nil and type(transaction) ~= "string")
        or (checksum ~= nil and (type(checksum) ~= "string" or not checksum:match("^%x%x%x%x%x%x%x%x$"))) then
        deployError("DEPLOY_BEGIN", "INVALID_METADATA", transaction)
        return
    end
    if transaction and completed[transaction] then
        deployError("DEPLOY_BEGIN", "TRANSACTION_COMPLETE", transaction); return
    end
    local file, err = io.open(TEMP_RUNTIME, "w")
    if not file then deployError("DEPLOY_BEGIN", tostring(err), transaction); return end
    deployment = {version=version, total=total, next=1, file=file, transaction=transaction,
        checksum=checksum, a=1, b=0, touched=now(), bytes=0}
    sendMgmt("MGMT_ACK", "DEPLOY_BEGIN", true, version, transaction)
end

local function receiveChunk(index, data, transaction)
    if not deployment or transaction ~= deployment.transaction then
        deployError("DEPLOY_CHUNK", "NO_DEPLOYMENT", transaction); return
    end
    local d = deployment
    local chunkIndex = tonumber(index)
    if chunkIndex == d.next - 1 and data == d.lastData then
        d.touched = now()
        sendMgmt("MGMT_ACK", "DEPLOY_CHUNK", true, chunkIndex, transaction); return
    end
    if chunkIndex ~= d.next or chunkIndex > d.total or type(data) ~= "string" or #data > 65536 or d.bytes + #data > 8 * 1024 * 1024 then
        abortDeployment()
        deployError("DEPLOY_CHUNK", "INVALID_CHUNK", transaction); return
    end
    local ok, err = d.file:write(data)
    if not ok then abortDeployment(); deployError("DEPLOY_CHUNK", tostring(err), transaction); return end
    for i=1,#data do d.a=(d.a+data:byte(i))%65521; d.b=(d.b+d.a)%65521 end
    d.bytes = d.bytes + #data
    d.lastData = data
    d.touched = now()
    d.next = d.next + 1
    sendMgmt("MGMT_ACK", "DEPLOY_CHUNK", true, chunkIndex, transaction)
end

local function commitDeployment(version, transaction)
    if transaction and completed[transaction] then
        local result = completed[transaction]
        if result.version ~= version then deployError("DEPLOY_COMMIT", "VERSION_MISMATCH", transaction); return end
        sendMgmt("MGMT_DEPLOY_RESULT", result.ok, result.version, result.message, transaction, result.state)
        return
    end
    if not deployment or transaction ~= deployment.transaction then
        deployError("DEPLOY_COMMIT", "NO_DEPLOYMENT", transaction); return
    end
    local d = deployment
    local function finish(ok, message)
        local result = {ok=ok,version=d.version,message=message,state=runtimeState(),time=now()}
        if transaction then completed[transaction] = result end
        if not ok then writeText(REJECTED_PATH, d.version) else filesystem.remove(REJECTED_PATH) end
        sendMgmt("MGMT_DEPLOY_RESULT", ok, d.version, message, transaction, result.state)
        abortDeployment()
    end
    if version ~= d.version or d.next ~= d.total + 1 then finish(false, "INCOMPLETE_OR_VERSION_MISMATCH"); return end
    local closed, closeErr = d.file:close(); d.file = nil
    if not closed then finish(false, "CLOSE_FAILED: " .. tostring(closeErr)); return end
    if d.checksum and string.lower(d.checksum) ~= string.format("%08x", d.b*65536+d.a) then finish(false, "CHECKSUM_MISMATCH"); return end
    local chunk, loadErr = loadfile(TEMP_RUNTIME)
    if not chunk then finish(false, "SYNTAX_ERROR: " .. tostring(loadErr)); return end
    local oldVersion, wasRunning = installedRuntimeVersion(), runtimeRunning
    local hadRuntime = filesystem.exists(CURRENT_RUNTIME)
    if hadRuntime then
        local copied, copyErr = copyRuntime(CURRENT_RUNTIME, PREVIOUS_RUNTIME)
        if not copied then finish(false, "BACKUP_FAILED: " .. tostring(copyErr)); return end
    else
        filesystem.remove(PREVIOUS_RUNTIME)
    end
    local saved, saveErr = writeText(PREVIOUS_VERSION, oldVersion)
    if saved then saved, saveErr = writeText(ACTIVATION_PATH, d.version) end
    if not saved then finish(false, "JOURNAL_FAILED: " .. tostring(saveErr)); return end
    stopRuntime()
    filesystem.remove(CURRENT_RUNTIME)
    local ok, err = filesystem.rename(TEMP_RUNTIME, CURRENT_RUNTIME)
    if ok then ok, err = startRuntime() end
    -- Include the first operational tick/status in health confirmation.
    if ok and type(runtimeModule.tick) == "function" then ok, err = pcall(runtimeModule.tick) end
    if ok and type(runtimeModule.status) == "function" then ok, err = pcall(runtimeModule.status, "summary") end
    if ok then ok, err = writeText(VERSION_PATH, d.version) end
    if not ok then
        stopRuntime()
        local restored, restoreErr
        if hadRuntime then restored, restoreErr = restorePrevious()
        else filesystem.remove(CURRENT_RUNTIME); restored = writeText(VERSION_PATH, "none") end
        if restored then filesystem.remove(ACTIVATION_PATH) end
        if restored and wasRunning then
            local restarted, restartErr = startRuntime()
            if not restarted then err = tostring(err) .. "; ROLLBACK_START_FAILED: " .. tostring(restartErr) end
        end
        if not restored then err = tostring(err) .. "; ROLLBACK_FILE_FAILED: " .. tostring(restoreErr) end
        finish(false, tostring(err)); return
    end
    filesystem.remove(ACTIVATION_PATH)
    if desiredState ~= "running" then stopRuntime() end
    finish(true, "OK")
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
        beginDeployment(arg1, arg2, payload[4], payload[5])
    elseif command == "DEPLOY_CHUNK" then
        receiveChunk(arg1, arg2, payload[4])
    elseif command == "DEPLOY_COMMIT" then
        commitDeployment(arg1, arg2)
    elseif command == "DEPLOY_ABORT" then
        if deployment and deployment.transaction == arg1 then abortDeployment() end
        sendMgmt("MGMT_ACK", "DEPLOY_ABORT", true, "OK", arg1)
    elseif command == "START" then
        local ok, err = setDesired("running")
        if ok then ok, err = startRuntime() end
        sendMgmt("MGMT_ACK", "START", ok, err or "OK")
    elseif command == "STOP" then
        local ok, err = setDesired("stopped")
        if ok then stopRuntime() end
        sendMgmt("MGMT_ACK", "STOP", ok, err or "OK")
    elseif command == "MAINTENANCE" then
        local ok, err = setDesired("maintenance")
        if ok then stopRuntime() end
        sendMgmt("MGMT_ACK", "MAINTENANCE", ok, err or "OK")
    elseif command == "RESTART" then
        local ok, err = setDesired("running")
        if ok then stopRuntime(); ok, err = startRuntime() end
        sendMgmt("MGMT_ACK", "RESTART", ok, err or "OK")
    end
end

local function runtimeCommand(source, payload)
    if source ~= controllerId or source ~= CENTRAL_ID then return end
    if not runtimeRunning or not runtimeModule then return end
    if payload[1] == "STATUS" and type(runtimeModule.status) == "function" then
        local ok, status = pcall(runtimeModule.status, payload[2])
        originate(OP_PORT, source, "RUNTIME", {ok and "STATUS" or "ERROR", ok and serialization.serialize(status) or tostring(status), payload[3]})
        return
    end
    if type(runtimeModule.onMessage) ~= "function" then return end

    local ok, err = pcall(
        runtimeModule.onMessage,
        source,
        payload[1],
        table.unpack(payload, 2, 6)
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
        local handler
        if port == MGMT_PORT and envelope.kind == "MGMT" then handler = managementCommand
        elseif port == OP_PORT and envelope.kind == "CMD" then handler = runtimeCommand end
        if handler then
            local previousReplyTo = replyTo
            replyTo = envelope.id
            local ok, err = pcall(handler, string.upper(envelope.source), envelope.payload)
            if not ok then
                if port == MGMT_PORT then sendMgmt("MGMT_ERROR", envelope.payload[1], tostring(err))
                else originate(OP_PORT, CENTRAL_ID, "RUNTIME", {"ERROR", tostring(err)}) end
            end
            replyTo = previousReplyTo
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

if filesystem.exists(ACTIVATION_PATH) then
    local rejected = readFirstLine(ACTIVATION_PATH)
    local ok, err = restorePrevious()
    if not ok and not filesystem.exists(PREVIOUS_RUNTIME) then
        filesystem.remove(CURRENT_RUNTIME)
        ok, err = writeText(VERSION_PATH, "none")
    end
    if not ok then error("Interrupted deployment recovery failed: " .. tostring(err)) end
    if rejected then writeText(REJECTED_PATH, rejected) end
    filesystem.remove(ACTIVATION_PATH)
elseif not filesystem.exists(CURRENT_RUNTIME) and filesystem.exists(PREVIOUS_RUNTIME) then
    local ok, err = restorePrevious()
    if not ok then error("Missing runtime recovery failed: " .. tostring(err)) end
end

log("STRATCOM node " .. NODE_ID .. " / " .. NODE_ROLE .. " / bootstrap " .. VERSION)
if desiredState == "running" and filesystem.exists(CURRENT_RUNTIME) then
    local ok, err = startRuntime()
    if not ok then error("Runtime startup failed: " .. tostring(err)) end
end
abortDeployment()
if options.ready then options.ready() end

local function localCommand(line)
    local words = {}
    for word in tostring(line):gmatch("%S+") do words[#words+1] = word end
    local cmd = string.lower(words[1] or "status")
    if cmd == "start" or cmd == "stop" or cmd == "maintenance" then
        local state = cmd == "start" and "running" or cmd == "stop" and "stopped" or "maintenance"
        local ok, err = setDesired(state)
        if ok then
            if state == "running" then ok, err = startRuntime() else stopRuntime() end
        end
        return ok, err or runtimeState()
    elseif cmd == "status" or cmd == "doctor" then
        local result = {"node=" .. NODE_ID, "runtime=" .. installedRuntimeVersion(), "state=" .. runtimeState(), "intent=" .. desiredState}
        if runtimeModule and type(runtimeModule.status) == "function" then
            local ok, status = pcall(runtimeModule.status, words[2])
            result[#result+1] = ok and serialization.serialize(status) or tostring(status)
        end
        return true, table.concat(result, " ")
    elseif cmd == "scan" or cmd == "hardware" or cmd == "map" then
        if not runtimeRunning or not runtimeModule or type(runtimeModule.onMessage) ~= "function" then return false, "Runtime unavailable" end
        local names = {status="SCAN_STATUS", results="SCAN_RESULTS", structure="SCAN_STRUCTURE"}
        local sub = string.lower(words[2] or "")
        localResponses = {}
        local command = cmd == "scan" and (names[sub] or "SCAN") or string.upper(cmd)
        local offset = cmd == "scan" and names[sub] and 3 or 2
        local ok, err
        if cmd == "map" then
            local mapping = {label=words[2],padAddress=words[3],inventoryAddress=words[4],side=tonumber(words[5]),slot=tonumber(words[6])}
            ok, err = pcall(runtimeModule.onMessage, NODE_ID, "MAP", serialization.serialize(mapping))
        else ok, err = pcall(runtimeModule.onMessage, NODE_ID, command, table.unpack(words, offset, offset + 4)) end
        local output = table.concat(localResponses, "\n")
        localResponses = nil
        return ok, ok and (output ~= "" and output or "Scan command accepted") or tostring(err)
    end
    return false, "Commands: status, doctor, start, stop, maintenance, scan, hardware, map"
end

broadcastHello()
broadcastHeartbeat()

while running do
    if options.stopping and options.stopping() then break end
    if options.setBusy then
        local busy = deployment ~= nil
        if runtimeRunning and runtimeModule and type(runtimeModule.busy) == "function" then
            local ok, value = pcall(runtimeModule.busy)
            busy = busy or not ok or value == true
        end
        options.setBusy(busy)
    end
    if options.nextCommand then
        local request = options.nextCommand()
        if request then
            local ok, text = localCommand(request.line)
            if options.reply then options.reply(request.id, ok, text) end
        end
    end
    if deployment and now() - deployment.touched >= DEPLOY_TIMEOUT then
        deployError("DEPLOY_ABORT", "TIMEOUT", deployment.transaction)
        abortDeployment()
    end
    for transaction, result in pairs(completed) do
        if now() - result.time > 600 then completed[transaction] = nil end
    end
    local eventName,
        a1,
        a2,
        a3,
        a4,
        a5,
        a6 = event.pull(1)

    if eventName == "interrupted" and not options.stopping then
        running = false
    elseif eventName == "key_down" and not options.stopping then
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
            runtimeFailure = "Runtime tick failed: " .. tostring(err)
            log(runtimeFailure)
            stopRuntime()
            running = false
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
if runtimeFailure then error(runtimeFailure) end
