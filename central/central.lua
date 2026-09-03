local component = require("component")
local event = require("event")
local computer = require("computer")
local term = require("term")
local shell = require("shell")
local filesystem = require("filesystem")
local serialization = require("serialization")

local VERSION = "1.1.1"
local BASE_URL = "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/main/central/"
local SCRIPT_PATH = "/home/stratcom/central.lua"
local TMP_VERSION = "/tmp/stratcom-central-version.txt"
local TMP_SCRIPT = "/tmp/stratcom-central.lua"

local PORT = 4510
local OFFLINE_AFTER = 15

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

local function download(url, path)
    if filesystem.exists(path) then filesystem.remove(path) end
    local ok = shell.execute("wget -f " .. url .. " " .. path)
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
    if not download(BASE_URL .. "central.lua", TMP_SCRIPT) then
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

local modem = component.modem
local nodes = {}
local running = true

modem.open(PORT)

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

local function nodeOnline(node)
    return node and node.lastSeen and now() - node.lastSeen <= OFFLINE_AFTER
end

local function getNode(id)
    return nodes[string.upper(id or "")]
end

local function requestStatus(node)
    if node and node.address then
        modem.send(node.address, PORT, "STATUS")
    end
end

local function registerNode(address, id, role)
    if not id then return nil end

    id = string.upper(id)
    local node = nodes[id]
    local discovered = false

    if not node then
        node = {
            id = id,
            address = address,
            role = role or "unknown",
            firstSeen = now(),
        }
        nodes[id] = node
        discovered = true

        print("")
        print("[NET] Node discovered: " .. id .. " (" .. tostring(role) .. ")")
        io.write("STRATCOM> ")
    end

    node.address = address
    node.role = role or node.role
    node.lastSeen = now()

    if discovered then requestStatus(node) end
    return node
end

local function applyStatus(node, status)
    if not node or type(status) ~= "table" then return end

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
    node.lastStatus = now()
end

local function onModemMessage(_, _, remoteAddress, port, _, messageType, ...)
    if port ~= PORT then return end
    local args = {...}

    if messageType == "HELLO" then
        registerNode(remoteAddress, args[1], args[2])
    elseif messageType == "HEARTBEAT" then
        local node = registerNode(remoteAddress, args[1], args[2])
        if node then
            node.armed = args[3]
            node.ready = args[4]
            node.tier = args[5]
            node.energy = args[6]
            node.maxEnergy = args[7]
        end
    elseif messageType == "PONG" then
        local node = registerNode(remoteAddress, args[1], args[2])
        if node then node.lastPing = now() end
        print("")
        print("[NET] PONG <- " .. tostring(args[1]))
        io.write("STRATCOM> ")
    elseif messageType == "STATUS" then
        local node = registerNode(remoteAddress, args[1], args[2])
        if node then
            local ok, status = pcall(serialization.unserialize, args[3])
            if ok and type(status) == "table" then
                applyStatus(node, status)
            else
                print("")
                print("[ERROR] Invalid STATUS payload from " .. tostring(args[1]))
                io.write("STRATCOM> ")
            end
        end
    elseif messageType == "ACK" then
        print("")
        print("[ACK] " .. tostring(args[1]) .. " " .. tostring(args[2]) .. " -> " .. tostring(args[3]))
        io.write("STRATCOM> ")
    elseif messageType == "ERROR" then
        print("")
        print("[ERROR] " .. tostring(args[1]) .. ": " .. tostring(args[2]))
        io.write("STRATCOM> ")
    elseif messageType == "LAUNCH_RESULT" then
        print("")
        if args[2] then
            print("[LAUNCH] " .. tostring(args[1]) .. " launched toward X=" .. tostring(args[3]) .. " Z=" .. tostring(args[4]))
        else
            print("[LAUNCH] " .. tostring(args[1]) .. " launch FAILED")
        end
        io.write("STRATCOM> ")
    elseif messageType == "IDENTIFY" then
        registerNode(remoteAddress, args[1], args[2])
    end
end

event.listen("modem_message", onModemMessage)

local function sendNode(node, command, ...)
    if not node then print("Node not found."); return false end
    if not nodeOnline(node) then
        print("WARNING: " .. node.id .. " is currently offline.")
        return false
    end
    modem.send(node.address, PORT, command, ...)
    return true
end

local function discover()
    print("Broadcasting discovery request...")
    modem.broadcast(PORT, "IDENTIFY")
    modem.broadcast(PORT, "PING")
end

local function printHeader()
    term.clear()
    print("========================================")
    print("          STRATCOM CENTRAL")
    print("========================================")
    print("")
    print("Version:      " .. VERSION)
    print("Network port: " .. PORT)
    print("")
end

local function printNodes()
    print("")
    print("NODE       ROLE       LINK      ARMED   READY   POWER")
    print("-------------------------------------------------------")

    local found = false
    for id, node in pairs(nodes) do
        found = true
        local link = nodeOnline(node) and "ONLINE" or "OFFLINE"
        local p = percent(node.energy, node.maxEnergy)
        local power = p and (tostring(p) .. "%") or "---"

        print(string.format(
            "%-10s %-10s %-9s %-7s %-7s %s",
            id,
            string.upper(tostring(node.role)),
            link,
            stateText(node.armed),
            stateText(node.ready),
            power
        ))
    end

    if not found then print("No nodes discovered.") end
    print("")
end

local function printStatus(node)
    if not node then print("Node not found."); return end

    print("")
    print("----------------------------------------")
    print("NODE STATUS")
    print("----------------------------------------")
    print("Node:       " .. node.id)
    print("Role:       " .. string.upper(tostring(node.role)))
    print("Link:       " .. (nodeOnline(node) and "ONLINE" or "OFFLINE"))
    print("Address:    " .. tostring(node.address))
    print("Armed:      " .. stateText(node.armed))
    print("Ready:      " .. stateText(node.ready))
    print("Tier:       " .. tostring(node.tier or "---"))

    local p = percent(node.energy, node.maxEnergy)
    if p then
        print("Power:      " .. node.energy .. "/" .. node.maxEnergy .. " (" .. p .. "%)")
    else
        print("Power:      ---")
    end

    if node.fuel ~= nil then
        print("Fuel:       " .. tostring(node.fuel) .. "/" .. tostring(node.fuelMax) .. " " .. tostring(node.fuelType))
    else
        print("Fuel:       ---")
    end

    if node.oxidizer ~= nil then
        print("Oxidizer:   " .. tostring(node.oxidizer) .. "/" .. tostring(node.oxidizerMax) .. " " .. tostring(node.oxidizerType))
    else
        print("Oxidizer:   ---")
    end

    if node.lastSeen then
        print("Last seen:   " .. string.format("%.1fs ago", now() - node.lastSeen))
    end

    print("----------------------------------------")
    print("")
end

local function printHelp()
    print("")
    print("Available commands:")
    print("  help")
    print("  discover")
    print("  nodes")
    print("  status <node>")
    print("  ping <node>")
    print("  arm <node>")
    print("  disarm <node>")
    print("  launch <node> <x> <z>")
    print("  clear")
    print("  quit")
    print("")
end

local function splitWords(line)
    local words = {}
    for word in string.gmatch(line or "", "%S+") do table.insert(words, word) end
    return words
end

local function execute(line)
    local args = splitWords(line)
    local command = string.lower(args[1] or "")

    if command == "" then return
    elseif command == "help" then printHelp()
    elseif command == "discover" then discover()
    elseif command == "nodes" then printNodes()
    elseif command == "status" then
        local node = getNode(args[2])
        if not node then print("Usage: status <node>"); return end
        sendNode(node, "STATUS")
        os.sleep(0.5)
        printStatus(node)
    elseif command == "ping" then
        local node = getNode(args[2])
        if not node then print("Usage: ping <node>"); return end
        sendNode(node, "PING")
    elseif command == "arm" then
        local node = getNode(args[2])
        if not node then print("Usage: arm <node>"); return end
        print("Sending ARM -> " .. node.id)
        sendNode(node, "ARM")
    elseif command == "disarm" then
        local node = getNode(args[2])
        if not node then print("Usage: disarm <node>"); return end
        print("Sending DISARM -> " .. node.id)
        sendNode(node, "DISARM")
    elseif command == "launch" then
        local node = getNode(args[2])
        local x = tonumber(args[3])
        local z = tonumber(args[4])
        if not node or not x or not z then print("Usage: launch <node> <x> <z>"); return end

        print("")
        print("*** LAUNCH REQUEST ***")
        print("Node:   " .. node.id)
        print("Target: X=" .. x .. " Z=" .. z)
        if node.armed ~= true then print("REJECTED: node is not armed."); return end

        io.write("Type LAUNCH to confirm: ")
        if io.read() ~= "LAUNCH" then print("Launch cancelled."); return end
        sendNode(node, "LAUNCH", x, z)
    elseif command == "clear" then printHeader()
    elseif command == "quit" then running = false
    else print("Unknown command. Type 'help'.") end
end

printHeader()
print("Opening STRATCOM network...")
print("Listening on port " .. PORT)
print("")

discover()
os.sleep(1)
printNodes()
print("Type 'help' for commands.")
print("")

while running do
    io.write("STRATCOM> ")
    local line = io.read()
    if line then execute(line) end
end

event.ignore("modem_message", onModemMessage)
modem.close(PORT)
print("")
print("STRATCOM central stopped.")
