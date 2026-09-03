local component = require("component")
local event = require("event")
local computer = require("computer")
local shell = require("shell")
local filesystem = require("filesystem")
local serialization = require("serialization")

local VERSION = "1.2.1"
local BASE_URL = "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/main/node/"
local SCRIPT_PATH = "/home/stratcom/node.lua"
local CONFIG_PATH = "/home/stratcom/config.lua"
local TMP_VERSION = "/tmp/stratcom-node-version.txt"
local TMP_SCRIPT = "/tmp/stratcom-node.lua"

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
        .. "-"
        .. tostring(math.random(100000, 999999))
    local separator = url:find("?", 1, true) and "&" or "?"
    return url .. separator .. "cb=" .. token
end

local function download(url, path)
    if filesystem.exists(path) then filesystem.remove(path) end
    local command = 'wget -f "' .. cacheBust(url) .. '" "' .. path .. '"'
    local ok = shell.execute(command)
    return ok and filesystem.exists(path)
end

local function readFirstLine(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local value = file:read("*l")
    file:close()
    return value
end

local function checkForUpdates()
    print("[UPDATE] Checking GitHub...")

    if not download(BASE_URL .. "version.txt", TMP_VERSION) then
        print("[UPDATE] GitHub unavailable; continuing with v" .. VERSION)
        return false
    end

    local remoteVersion = trim(readFirstLine(TMP_VERSION))
    if not isNewer(remoteVersion, VERSION) then
        print("[UPDATE] Current version: " .. VERSION)
        return false
    end

    print("[UPDATE] v" .. remoteVersion .. " available; downloading...")
    if not download(BASE_URL .. "node.lua", TMP_SCRIPT) then
        print("[UPDATE] Download failed; continuing with v" .. VERSION)
        return false
    end

    local backup = SCRIPT_PATH .. ".bak"
    if filesystem.exists(backup) then filesystem.remove(backup) end
    if filesystem.exists(SCRIPT_PATH) then filesystem.rename(SCRIPT_PATH, backup) end

    if not filesystem.rename(TMP_SCRIPT, SCRIPT_PATH) then
        if filesystem.exists(backup) then filesystem.rename(backup, SCRIPT_PATH) end
        print("[UPDATE] Install failed; restored previous version")
        return false
    end

    print("[UPDATE] Installed v" .. remoteVersion .. "; rebooting...")
    os.sleep(1)
    computer.shutdown(true)
    return true
end

checkForUpdates()

if not filesystem.exists(CONFIG_PATH) then
    io.stderr:write("FATAL: Missing " .. CONFIG_PATH .. "\n")
    return
end

local config = dofile(CONFIG_PATH)
local NODE_ID = assert(config.id, "config.id is required")
local NODE_ROLE = assert(config.role, "config.role is required")
local PORT = tonumber(config.port) or 4510
local HEARTBEAT_INTERVAL = 5

local function findComponent(componentType)
    local address = component.list(componentType)()
    if not address then return nil end
    return component.proxy(address)
end

local modem = findComponent("modem")
local launchPad = findComponent("ntm_launch_pad")
local inventory = findComponent("inventory_controller")

if not modem then io.stderr:write("FATAL: No modem detected.\n"); return end
if not launchPad then io.stderr:write("FATAL: No ntm_launch_pad detected.\n"); return end

local armed = false
local running = true
local lastHeartbeat = 0
local launcherInventorySide = nil

local function log(message)
    print(string.format("[%06.1f] %s", computer.uptime(), tostring(message)))
end

local function findLauncherInventorySide()
    if not inventory then return nil end

    for side = 0, 5 do
        local ok, size = pcall(inventory.getInventorySize, side)
        if ok and size == 7 then return side end
    end

    return nil
end

local function getMissileInfo()
    if not inventory then return "", "", 0 end

    if launcherInventorySide == nil then
        launcherInventorySide = findLauncherInventorySide()
    end

    if launcherInventorySide == nil then return "", "", 0 end

    local ok, stack = pcall(inventory.getStackInSlot, launcherInventorySide, 1)
    if not ok or not stack then return "", "", 0 end

    return tostring(stack.name or ""),
        tostring(stack.label or ""),
        tonumber(stack.size) or 0
end

local function getStatus()
    local energy, maxEnergy = launchPad.getEnergyInfo()
    local fuel, fuelMax, fuelType, oxidizer, oxidizerMax, oxidizerType =
        launchPad.getFluid()
    local missileName, missileLabel, missileCount = getMissileInfo()
    local tier = launchPad.getTier()
    if tier == nil then tier = -1 end

    return {
        armed = armed,
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
        missileName = missileName,
        missileLabel = missileLabel,
        missileCount = missileCount,
    }
end

local function send(remoteAddress, ...)
    modem.send(remoteAddress, PORT, ...)
end

local function broadcast(...)
    modem.broadcast(PORT, ...)
end

local function sendStatus(remoteAddress)
    send(
        remoteAddress,
        "STATUS",
        NODE_ID,
        NODE_ROLE,
        serialization.serialize(getStatus())
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

-- These packet types are emitted by nodes/central as responses or telemetry.
-- A field node must never answer them, or two nodes can create a feedback loop.
local IGNORE_PACKET = {
    HELLO = true,
    HEARTBEAT = true,
    PONG = true,
    IDENTIFY = true,
    ACK = true,
    ERROR = true,
    LAUNCH_RESULT = true,
}

local function handleCommand(remoteAddress, command, arg1, arg2)
    if IGNORE_PACKET[command] then
        return
    end

    if command == "PING" then
        log("PING <- " .. remoteAddress)
        send(remoteAddress, "PONG", NODE_ID, NODE_ROLE)
    elseif command == "DISCOVER" then
        send(remoteAddress, "IDENTIFY", NODE_ID, NODE_ROLE)
    elseif command == "STATUS" then
        log("STATUS requested")
        sendStatus(remoteAddress)
    elseif command == "ARM" then
        armed = true
        log("ARMED by " .. remoteAddress)
        send(remoteAddress, "ACK", NODE_ID, "ARM", true)
    elseif command == "DISARM" then
        armed = false
        log("DISARMED by " .. remoteAddress)
        send(remoteAddress, "ACK", NODE_ID, "DISARM", true)
    elseif command == "LAUNCH" then
        if not armed then
            send(remoteAddress, "ERROR", NODE_ID, "DISARMED")
            return
        end

        local targetX = tonumber(arg1)
        local targetZ = tonumber(arg2)
        if not targetX or not targetZ then
            send(remoteAddress, "ERROR", NODE_ID, "INVALID_COORDINATES")
            return
        end

        if not launchPad.canLaunch() then
            send(remoteAddress, "ERROR", NODE_ID, "NOT_READY")
            return
        end

        log("LAUNCH -> X=" .. targetX .. " Z=" .. targetZ)
        local success = launchPad.launch(targetX, targetZ)
        if success then armed = false end
        send(remoteAddress, "LAUNCH_RESULT", NODE_ID, success, targetX, targetZ)
    elseif command == "SHUTDOWN_NODE" then
        send(remoteAddress, "ACK", NODE_ID, "SHUTDOWN_NODE", true)
        running = false
    else
        -- Unknown network traffic is ignored rather than answered. This prevents
        -- malformed or third-party packets from creating an error-response loop.
        log("Ignored unknown packet: " .. tostring(command))
    end
end

modem.open(PORT)
launcherInventorySide = findLauncherInventorySide()
local initialStatus = getStatus()

print("")
print("================================")
print("       STRATCOM FIELD NODE")
print("================================")
print("Version:     " .. VERSION)
print("Node ID:     " .. NODE_ID)
print("Role:        " .. NODE_ROLE)
print("Port:        " .. PORT)
print("Launch Pad:  CONNECTED")
print(
    "Inventory:   "
        .. (
            launcherInventorySide ~= nil
                and ("CONNECTED (side " .. launcherInventorySide .. ")")
            or "UNAVAILABLE"
        )
)
print(
    "Missile:     "
        .. (
            initialStatus.missileLabel ~= ""
                and initialStatus.missileLabel
            or "UNKNOWN"
        )
)
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
