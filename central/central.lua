local component = require("component")
local event = require("event")
local computer = require("computer")
local term = require("term")
local shell = require("shell")
local filesystem = require("filesystem")
local serialization = require("serialization")

local VERSION = "2.0.0"
local BASE_URL = "https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/main/"
local SCRIPT_PATH = "/home/stratcom/central.lua"
local TMP_VERSION = "/tmp/stratcom-central-version.txt"
local TMP_SCRIPT = "/tmp/stratcom-central.lua"

local REPOSITORY_DIR = "/home/stratcom/repository"
local MANIFEST_PATH = REPOSITORY_DIR .. "/manifest.lua"
local TMP_MANIFEST = "/tmp/stratcom-runtime-manifest.lua"

local MGMT_PORT = 4510
local OP_PORT = 4511
local OFFLINE_AFTER = 15
local RECONCILE_INTERVAL = 10
local CHUNK_SIZE = 2048

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

if not filesystem.exists(REPOSITORY_DIR) then
    filesystem.makeDirectory(REPOSITORY_DIR)
end

local modemAddress = component.list("modem")()
if not modemAddress then
    io.stderr:write("FATAL: No modem detected.\n")
    return
end

local modem = component.proxy(modemAddress)
local nodes = {}
local desiredRuntimes = {}
local running = true

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

local function nodeOnline(node)
    return node and node.lastSeen and now() - node.lastSeen <= OFFLINE_AFTER
end

local function getNode(id)
    return nodes[string.upper(id or "")]
end

local function readAll(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
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
                desiredRuntimes[role] = {
                    version = tostring(entry.version),
                    path = localPath,
                }
                print(
                    "[REPO] "
                        .. tostring(role)
                        .. " -> "
                        .. tostring(entry.version)
                )
            end
        end
    end

    return true
end

local function sendMgmt(node, command, ...)
    if not node or not node.address then return false end
    modem.send(node.address, MGMT_PORT, "MGMT", command, ...)
    return true
end

local function sendOperational(node, command, ...)
    if not node or not node.address or not nodeOnline(node) then return false end
    modem.send(node.address, OP_PORT, "CMD", command, ...)
    return true
end

local function registerNode(
    address,
    id,
    role,
    bootstrapVersion,
    runtimeVersion,
    runtimeState
)
    if not id then return nil end

    id = string.upper(tostring(id))
    local node = nodes[id]
    local discovered = false

    if not node then
        node = {
            id = id,
            firstSeen = now(),
            claimed = false,
            deploying = false,
        }
        nodes[id] = node
        discovered = true
    end

    node.address = address
    node.role = tostring(role or node.role or "unknown")
    node.bootstrapVersion = tostring(bootstrapVersion or node.bootstrapVersion or "unknown")
    node.runtimeVersion = tostring(runtimeVersion or node.runtimeVersion or "none")
    node.runtimeState = tostring(runtimeState or node.runtimeState or "unknown")
    node.lastSeen = now()

    if discovered then
        print("")
        print(
            "[NET] Bootstrap discovered: "
                .. id
                .. " ("
                .. node.role
                .. ")"
        )
    end

    if not node.claimed then
        sendMgmt(node, "CLAIM")
    end

    return node
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

    print(
        "[DEPLOY] "
            .. node.id
            .. " <- "
            .. desired.version
            .. " ("
            .. totalChunks
            .. " chunks)"
    )

    sendMgmt(node, "DEPLOY_BEGIN", desired.version, totalChunks)

    for index = 1, totalChunks do
        local startIndex = ((index - 1) * CHUNK_SIZE) + 1
        local chunk = data:sub(startIndex, startIndex + CHUNK_SIZE - 1)
        sendMgmt(node, "DEPLOY_CHUNK", index, chunk)
    end

    sendMgmt(node, "DEPLOY_COMMIT", desired.version)
    return true
end

local function reconcileNode(node, force)
    if not node or not node.claimed or not nodeOnline(node) or node.deploying then
        return
    end

    if not force and node.lastReconcile and now() - node.lastReconcile < RECONCILE_INTERVAL then
        return
    end

    node.lastReconcile = now()
    local desired = desiredRuntimes[node.role]

    if not desired then return end

    if tostring(node.runtimeVersion) ~= tostring(desired.version) then
        deployNode(node)
    elseif node.runtimeState ~= "running" then
        print("[MGMT] Starting runtime on " .. node.id)
        sendMgmt(node, "START")
    end
end

local function reconcileAll(force)
    for _, node in pairs(nodes) do
        reconcileNode(node, force)
    end
end

local function applyRuntimeStatus(node, status)
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
    node.missileName = status.missileName
    node.missileLabel = status.missileLabel
    node.missileCount = status.missileCount
    node.inventorySide = status.inventorySide
    node.lastStatus = now()
end

local function handleMgmtMessage(remoteAddress, messageType, ...)
    local args = {...}

    if messageType == "BOOT_HELLO" or messageType == "BOOT_HEARTBEAT" then
        local node = registerNode(
            remoteAddress,
            args[1],
            args[2],
            args[3],
            args[4],
            args[5]
        )

        if node and node.claimed then reconcileNode(node, false) end
        return
    end

    local node = getNode(args[1])
    if not node then return end
    node.address = remoteAddress
    node.lastSeen = now()

    if messageType == "MGMT_ACK" then
        local command = tostring(args[2])
        local success = args[3]
        local detail = args[4]

        if command == "CLAIM" and success then
            node.claimed = true
            print("[MGMT] Claimed " .. node.id)
            reconcileNode(node, true)
        elseif command == "START" then
            if success then node.runtimeState = "running" end
            print("[MGMT] " .. node.id .. " START -> " .. tostring(success) .. " " .. tostring(detail or ""))
        elseif command == "STOP" then
            if success then node.runtimeState = "stopped" end
            print("[MGMT] " .. node.id .. " STOP -> " .. tostring(success))
        elseif command == "RESTART" then
            if success then node.runtimeState = "running" end
            print("[MGMT] " .. node.id .. " RESTART -> " .. tostring(success) .. " " .. tostring(detail or ""))
        end
    elseif messageType == "MGMT_DEPLOY_RESULT" then
        local success = args[2]
        local version = tostring(args[3] or "unknown")
        local detail = args[4]
        node.deploying = false

        if success then
            node.runtimeVersion = version
            node.runtimeState = "stopped"
            print("[DEPLOY] " .. node.id .. " installed " .. version)
            sendMgmt(node, "START")
        else
            print("[DEPLOY] " .. node.id .. " FAILED: " .. tostring(detail))
        end
    elseif messageType == "MGMT_ERROR" then
        node.deploying = false
        print(
            "[MGMT ERROR] "
                .. node.id
                .. " "
                .. tostring(args[2])
                .. ": "
                .. tostring(args[3])
        )
    elseif messageType == "BOOT_INFO" then
        local ok, info = pcall(serialization.unserialize, args[2])
        if ok and type(info) == "table" then
            node.bootstrapVersion = info.bootstrapVersion or node.bootstrapVersion
            node.runtimeVersion = info.runtimeVersion or node.runtimeVersion
            node.runtimeState = info.runtimeState or node.runtimeState
        end
    end
end

local function handleRuntimeMessage(remoteAddress, ...)
    local args = {...}
    local node = getNode(args[1])
    if not node or remoteAddress ~= node.address then return end

    local responseType = tostring(args[2] or "")
    node.lastSeen = now()

    if responseType == "STATUS" then
        local ok, status = pcall(serialization.unserialize, args[3])
        if ok and type(status) == "table" then
            applyRuntimeStatus(node, status)
        else
            print("[RUNTIME ERROR] Invalid status from " .. node.id)
        end
    elseif responseType == "ACK" then
        print(
            "[ACK] "
                .. node.id
                .. " "
                .. tostring(args[3])
                .. " -> "
                .. tostring(args[4])
        )
    elseif responseType == "ERROR" then
        print("[ERROR] " .. node.id .. ": " .. tostring(args[3]))
    elseif responseType == "LAUNCH_RESULT" then
        print(
            "[LAUNCH] "
                .. node.id
                .. " success="
                .. tostring(args[3])
                .. " X="
                .. tostring(args[4])
                .. " Z="
                .. tostring(args[5])
        )
    elseif responseType == "PONG" then
        print("[NET] PONG <- " .. node.id)
    end
end

local function onModemMessage(_, _, remoteAddress, port, _, messageType, ...)
    if port == MGMT_PORT then
        handleMgmtMessage(remoteAddress, messageType, ...)
    elseif port == OP_PORT and messageType == "RUNTIME" then
        handleRuntimeMessage(remoteAddress, ...)
    end
end

local function discover()
    print("[NET] Broadcasting bootstrap discovery...")
    modem.broadcast(MGMT_PORT, "MGMT", "DISCOVER")
end

local function printHeader()
    term.clear()
    print("========================================")
    print("          STRATCOM CENTRAL")
    print("========================================")
    print("Version:      " .. VERSION)
    print("Mgmt port:    " .. MGMT_PORT)
    print("Op port:      " .. OP_PORT)
    print("")
end

local function printNodes()
    print("")
    print("NODE       ROLE       RUNTIME   STATE     MISSILE              LINK")
    print("---------------------------------------------------------------------")

    local found = false
    for id, node in pairs(nodes) do
        found = true
        print(
            string.format(
                "%-10s %-10s %-9s %-9s %-20s %s",
                id,
                string.upper(tostring(node.role)),
                clip(node.runtimeVersion, 9),
                clip(node.runtimeState, 9),
                clip(node.missileLabel, 20),
                nodeOnline(node) and "ONLINE" or "OFFLINE"
            )
        )
    end

    if not found then print("No bootstrap nodes discovered.") end
    print("")
end

local function printStatus(node)
    if not node then print("Node not found."); return end

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
    print("Missile:     " .. clip(node.missileLabel, 30))
    print("Item:        " .. clip(node.missileName, 30))
    print("Count:       " .. tostring(node.missileCount or 0))
    print("Armed:       " .. stateText(node.armed))
    print("Ready:       " .. stateText(node.ready))
    print("Tier:        " .. tostring(node.tier or "---"))

    local p = percent(node.energy, node.maxEnergy)
    if p then
        print("Power:       " .. node.energy .. "/" .. node.maxEnergy .. " (" .. p .. "%)")
    else
        print("Power:       ---")
    end

    if node.lastSeen then
        print("Last seen:    " .. string.format("%.1fs ago", now() - node.lastSeen))
    end

    print("----------------------------------------")
    print("")
end

local function splitWords(line)
    local words = {}
    for word in string.gmatch(line or "", "%S+") do table.insert(words, word) end
    return words
end

local function printHelp()
    print("")
    print("Management:")
    print("  discover")
    print("  nodes")
    print("  info <node>")
    print("  deploy <node|all>")
    print("  start <node>")
    print("  stop <node>")
    print("  restart <node>")
    print("  sync")
    print("")
    print("Operations:")
    print("  status <node>")
    print("  ping <node>")
    print("  arm <node>")
    print("  disarm <node>")
    print("  launch <node> <x> <z>")
    print("")
    print("Other: clear, help, quit")
    print("")
end

local function execute(line)
    local args = splitWords(line)
    local command = string.lower(args[1] or "")

    if command == "" then return
    elseif command == "help" then
        printHelp()
    elseif command == "discover" then
        discover()
    elseif command == "nodes" then
        printNodes()
    elseif command == "sync" then
        if syncRepository() then reconcileAll(true) end
    elseif command == "info" then
        local node = getNode(args[2])
        if not node then print("Usage: info <node>"); return end
        sendMgmt(node, "INFO")
    elseif command == "deploy" then
        if string.lower(args[2] or "") == "all" then
            for _, node in pairs(nodes) do
                if node.claimed and nodeOnline(node) then deployNode(node) end
            end
        else
            local node = getNode(args[2])
            if not node then print("Usage: deploy <node|all>"); return end
            deployNode(node)
        end
    elseif command == "start" or command == "stop" or command == "restart" then
        local node = getNode(args[2])
        if not node then print("Usage: " .. command .. " <node>"); return end
        sendMgmt(node, string.upper(command))
    elseif command == "status" then
        local node = getNode(args[2])
        if not node then print("Usage: status <node>"); return end
        if not sendOperational(node, "STATUS") then
            print("Runtime unavailable or node offline.")
            return
        end
        os.sleep(0.5)
        printStatus(node)
    elseif command == "ping" then
        local node = getNode(args[2])
        if not node then print("Usage: ping <node>"); return end
        sendOperational(node, "PING")
    elseif command == "arm" then
        local node = getNode(args[2])
        if not node then print("Usage: arm <node>"); return end
        sendOperational(node, "ARM")
    elseif command == "disarm" then
        local node = getNode(args[2])
        if not node then print("Usage: disarm <node>"); return end
        sendOperational(node, "DISARM")
    elseif command == "launch" then
        local node = getNode(args[2])
        local x = tonumber(args[3])
        local z = tonumber(args[4])
        if not node or not x or not z then
            print("Usage: launch <node> <x> <z>")
            return
        end

        if node.armed ~= true then
            print("REJECTED: node is not armed.")
            return
        end

        print("")
        print("*** LAUNCH REQUEST ***")
        print("Node:    " .. node.id)
        print("Missile: " .. clip(node.missileLabel, 30))
        print("Target:  X=" .. x .. " Z=" .. z)
        io.write("Type LAUNCH to confirm: ")

        if io.read() ~= "LAUNCH" then
            print("Launch cancelled.")
            return
        end

        sendOperational(node, "LAUNCH", x, z)
    elseif command == "clear" then
        printHeader()
    elseif command == "quit" then
        running = false
    else
        print("Unknown command. Type 'help'.")
    end
end

modem.open(MGMT_PORT)
modem.open(OP_PORT)
event.listen("modem_message", onModemMessage)

printHeader()
syncRepository()
discover()
print("Type 'help' for commands.")
print("")

while running do
    io.write("STRATCOM> ")
    local line = io.read()
    if line then execute(line) end
end

event.ignore("modem_message", onModemMessage)
modem.close(OP_PORT)
modem.close(MGMT_PORT)
print("STRATCOM central stopped.")
