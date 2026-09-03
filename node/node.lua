local component = require("component")
local event = require("event")
local computer = require("computer")

local NODE_ID = "ABM-A1"
local NODE_ROLE = "defense"

local PORT = 4510
local HEARTBEAT_INTERVAL = 5

local function findComponent(componentType)
    local address = component.list(componentType)()

    if not address then
        return nil
    end

    return component.proxy(address)
end

local modem = findComponent("modem")
local launchPad = findComponent("ntm_launch_pad")

if not modem then
    io.stderr:write("FATAL: No modem detected.\n")
    return
end

if not launchPad then
    io.stderr:write("FATAL: No ntm_launch_pad detected.\n")
    return
end

local armed = false
local running = true
local lastHeartbeat = 0

local function log(message)
    print(string.format("[%06.1f] %s", computer.uptime(), tostring(message)))
end

local function getStatus()
    local energy, maxEnergy = launchPad.getEnergyInfo()
    local fuel, fuelMax, fuelType, oxidizer, oxidizerMax, oxidizerType =
        launchPad.getFluid()

    local tier = launchPad.getTier()

    if tier == nil then
        tier = -1
    end

    return {
        ready = launchPad.canLaunch(),
        tier = tier,
        energy = energy or 0,
        maxEnergy = maxEnergy or 0,
        fuel = fuel or 0,
        fuelMax = fuelMax or 0,
        fuelType = tostring(fuelType),
        oxidizer = oxidizer or 0,
        oxidizerMax = oxidizerMax or 0,
        oxidizerType = tostring(oxidizerType),
        armed = armed,
    }
end

local function send(remoteAddress, ...)
    modem.send(remoteAddress, PORT, ...)
end

local function broadcast(...)
    modem.broadcast(PORT, ...)
end

local function sendStatus(remoteAddress)
    local status = getStatus()

    send(
        remoteAddress,
        "STATUS",
        NODE_ID,
        NODE_ROLE,
        status.armed,
        status.ready,
        status.tier,
        status.energy,
        status.maxEnergy,
        status.fuel,
        status.fuelMax,
        status.fuelType,
        status.oxidizer,
        status.oxidizerMax,
        status.oxidizerType
    )
end

local function sendHeartbeat()
    local status = getStatus()

    broadcast(
        "HEARTBEAT",
        NODE_ID,
        NODE_ROLE,
        status.armed,
        status.ready,
        status.tier,
        status.energy,
        status.maxEnergy
    )

    lastHeartbeat = computer.uptime()
end

local function handlePing(remoteAddress)
    log("PING <- " .. remoteAddress)
    send(remoteAddress, "PONG", NODE_ID, NODE_ROLE)
end

local function handleStatus(remoteAddress)
    log("STATUS requested")
    sendStatus(remoteAddress)
end

local function handleArm(remoteAddress)
    armed = true
    log("ARMED by " .. remoteAddress)
    send(remoteAddress, "ACK", NODE_ID, "ARM", true)
end

local function handleDisarm(remoteAddress)
    armed = false
    log("DISARMED by " .. remoteAddress)
    send(remoteAddress, "ACK", NODE_ID, "DISARM", true)
end

local function handleLaunch(remoteAddress, targetX, targetZ)
    if not armed then
        log("LAUNCH REJECTED: node disarmed")
        send(remoteAddress, "ERROR", NODE_ID, "DISARMED")
        return
    end

    targetX = tonumber(targetX)
    targetZ = tonumber(targetZ)

    if not targetX or not targetZ then
        send(remoteAddress, "ERROR", NODE_ID, "INVALID_COORDINATES")
        return
    end

    if not launchPad.canLaunch() then
        log("LAUNCH REJECTED: launcher not ready")
        send(remoteAddress, "ERROR", NODE_ID, "NOT_READY")
        return
    end

    log("LAUNCH -> X=" .. targetX .. " Z=" .. targetZ)

    local success = launchPad.launch(targetX, targetZ)

    if success then
        armed = false
        log("MISSILE LAUNCHED")
        send(remoteAddress, "LAUNCH_RESULT", NODE_ID, true, targetX, targetZ)
    else
        log("LAUNCH FAILED")
        send(remoteAddress, "LAUNCH_RESULT", NODE_ID, false, targetX, targetZ)
    end
end

local function handleCommand(remoteAddress, command, arg1, arg2)
    if command == "PING" then
        handlePing(remoteAddress)
    elseif command == "STATUS" then
        handleStatus(remoteAddress)
    elseif command == "ARM" then
        handleArm(remoteAddress)
    elseif command == "DISARM" then
        handleDisarm(remoteAddress)
    elseif command == "LAUNCH" then
        handleLaunch(remoteAddress, arg1, arg2)
    elseif command == "IDENTIFY" then
        send(remoteAddress, "IDENTIFY", NODE_ID, NODE_ROLE)
    elseif command == "SHUTDOWN_NODE" then
        log("Remote node shutdown requested")
        send(remoteAddress, "ACK", NODE_ID, "SHUTDOWN_NODE", true)
        running = false
    else
        log("Unknown command: " .. tostring(command))
        send(
            remoteAddress,
            "ERROR",
            NODE_ID,
            "UNKNOWN_COMMAND",
            tostring(command)
        )
    end
end

modem.open(PORT)

local initialStatus = getStatus()

print("")
print("================================")
print("       STRATCOM FIELD NODE")
print("================================")
print("")
print("Node ID:     " .. NODE_ID)
print("Role:        " .. NODE_ROLE)
print("Port:        " .. PORT)
print("")
print("Launch Pad:  CONNECTED")
print("Armed:       " .. tostring(initialStatus.armed))
print("Ready:       " .. tostring(initialStatus.ready))
print("Tier:        " .. tostring(initialStatus.tier))
print("Power:       " .. initialStatus.energy .. "/" .. initialStatus.maxEnergy)
print("")
print("Waiting for STRATCOM commands...")
print("Ctrl+C to stop.")
print("")

broadcast("HELLO", NODE_ID, NODE_ROLE)
sendHeartbeat()

while running do
    local eventName, _, remoteAddress, port, _, command, arg1, arg2 =
        event.pull(1, "modem_message")

    if eventName == "modem_message" and port == PORT then
        handleCommand(remoteAddress, command, arg1, arg2)
    end

    if computer.uptime() - lastHeartbeat >= HEARTBEAT_INTERVAL then
        sendHeartbeat()
    end
end

modem.close(PORT)
log("STRATCOM node stopped.")
