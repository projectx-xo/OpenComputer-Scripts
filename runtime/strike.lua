local component = require("component")
local serialization = require("serialization")

local context = nil
local launchers = {}
local armed = {}

local MISSILE_PREFIX = "hbm:item.missile_"
local BATTERY_PREFIX = "hbm:item.battery_"

local function startsWith(value, prefix)
    value = tostring(value or "")
    return value:sub(1, #prefix) == prefix
end

local function sortedAddresses(componentType)
    local addresses = {}
    for address in component.list(componentType) do
        table.insert(addresses, address)
    end
    table.sort(addresses)
    return addresses
end

local function scanInventory(controller)
    if not controller then return "", "", 0, nil end

    local batterySide = nil
    for side = 0, 5 do
        local okSize, size = pcall(controller.getInventorySize, side)
        if okSize and type(size) == "number" and size > 0 then
            for slot = 1, size do
                local okStack, stack = pcall(controller.getStackInSlot, side, slot)
                if okStack and stack then
                    local name = tostring(stack.name or "")
                    if startsWith(name, MISSILE_PREFIX) then
                        return name,
                            tostring(stack.label or name),
                            tonumber(stack.size) or 0,
                            side
                    end
                    if batterySide == nil and startsWith(name, BATTERY_PREFIX) then
                        batterySide = side
                    end
                end
            end
        end
    end

    if batterySide ~= nil then
        return "", "UNLOADED", 0, batterySide
    end
    return "", "", 0, nil
end

local function launcherStatus(index)
    local entry = launchers[index]
    if not entry then return nil end

    local pad = entry.pad
    local energy, maxEnergy = pad.getEnergyInfo()
    local fuel, fuelMax, fuelType, oxidizer, oxidizerMax, oxidizerType = pad.getFluid()
    local missileName, missileLabel, missileCount, inventorySide = scanInventory(entry.inventory)
    local tier = pad.getTier()
    if tier == nil then tier = -1 end

    return {
        index = index,
        padAddress = entry.padAddress,
        inventoryAddress = entry.inventoryAddress,
        armed = armed[index] == true,
        ready = pad.canLaunch(),
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
        inventorySide = inventorySide,
    }
end

local function getStatus()
    local result = {
        multiLauncher = true,
        launcherCount = #launchers,
        launchers = {},
        armed = false,
        ready = false,
        missileLabel = tostring(#launchers) .. " LAUNCHERS",
        missileName = "",
        missileCount = 0,
    }

    local readyCount = 0
    local armedCount = 0
    for index = 1, #launchers do
        local status = launcherStatus(index)
        result.launchers[index] = status
        if status.ready then readyCount = readyCount + 1 end
        if status.armed then armedCount = armedCount + 1 end
    end

    result.readyCount = readyCount
    result.armedCount = armedCount
    result.ready = readyCount > 0
    result.armed = armedCount > 0
    result.missileLabel = tostring(readyCount) .. "/" .. tostring(#launchers) .. " READY"
    return result
end

local function parseSelector(value, allowAll)
    local raw = tostring(value or "")
    if allowAll and string.lower(raw) == "all" then return "all" end
    local index = tonumber(raw)
    if not index or index % 1 ~= 0 or index < 1 or index > #launchers then
        return nil
    end
    return index
end

local function launchOne(index, targetX, targetZ, requireArmed)
    local entry = launchers[index]
    if not entry then return false, "INVALID_LAUNCHER" end
    if requireArmed and not armed[index] then return false, "DISARMED" end
    if not entry.pad.canLaunch() then return false, "NOT_READY" end

    local ok, success = pcall(entry.pad.launch, targetX, targetZ)
    if not ok then return false, "LAUNCH_EXCEPTION: " .. tostring(success) end
    if success then armed[index] = false end
    return success == true, success == true and "OK" or "LAUNCH_FAILED"
end

local runtime = {}

function runtime.start(ctx)
    context = assert(ctx, "runtime context is required")
    launchers = {}
    armed = {}

    local padAddresses = sortedAddresses("ntm_launch_pad")
    local inventoryAddresses = sortedAddresses("inventory_controller")

    if #padAddresses < 1 then
        error("No ntm_launch_pad detected")
    end

    for index, padAddress in ipairs(padAddresses) do
        local inventoryAddress = inventoryAddresses[index]
        launchers[index] = {
            padAddress = padAddress,
            pad = component.proxy(padAddress),
            inventoryAddress = inventoryAddress,
            inventory = inventoryAddress and component.proxy(inventoryAddress) or nil,
        }
        armed[index] = false
    end

    if context.log then
        context.log(
            "Strike runtime started for " .. tostring(context.id)
                .. " with " .. tostring(#launchers) .. " launcher(s)"
        )
        if #inventoryAddresses ~= #padAddresses then
            context.log(
                "WARNING: launcher/inventory count mismatch: "
                    .. tostring(#padAddresses) .. "/" .. tostring(#inventoryAddresses)
            )
        end
    end
end

function runtime.stop()
    for index = 1, #launchers do armed[index] = false end
    if context and context.log then context.log("Strike runtime stopped") end
end

function runtime.tick()
end

function runtime.status()
    return getStatus()
end

function runtime.onMessage(remoteAddress, command, arg1, arg2)
    if command == "PING" then
        context.send(remoteAddress, "PONG", context.role)
        return
    end

    if command == "STATUS" then
        context.send(remoteAddress, "STATUS", serialization.serialize(getStatus()))
        return
    end

    if command == "ARM" or command == "DISARM" then
        local selector = parseSelector(arg1, true)
        if selector == nil then
            context.send(remoteAddress, "ERROR", "INVALID_LAUNCHER", tostring(arg1))
            return
        end

        local value = command == "ARM"
        if selector == "all" then
            for index = 1, #launchers do armed[index] = value end
        else
            armed[selector] = value
        end

        context.send(remoteAddress, "ACK", command, true, tostring(selector))
        return
    end

    if command == "LAUNCH_SILO" then
        local launcherIndex = parseSelector(arg1, false)
        local okCoords, coords = pcall(serialization.unserialize, tostring(arg2 or ""))
        if launcherIndex == nil then
            context.send(remoteAddress, "ERROR", "INVALID_LAUNCHER", tostring(arg1))
            return
        end
        if not okCoords or type(coords) ~= "table" then
            context.send(remoteAddress, "ERROR", "INVALID_COORDINATES")
            return
        end

        local targetX = tonumber(coords.x)
        local targetZ = tonumber(coords.z)
        if not targetX or not targetZ then
            context.send(remoteAddress, "ERROR", "INVALID_COORDINATES")
            return
        end

        local success, detail = launchOne(launcherIndex, targetX, targetZ, true)
        context.send(remoteAddress, "LAUNCH_RESULT", success, launcherIndex, targetX, targetZ, detail)
        return
    end

    if command == "STRIKE" then
        local okPlan, plan = pcall(serialization.unserialize, tostring(arg1 or ""))
        local okCoords, coords = pcall(serialization.unserialize, tostring(arg2 or ""))
        if not okPlan or type(plan) ~= "table" or not okCoords or type(coords) ~= "table" then
            context.send(remoteAddress, "ERROR", "INVALID_STRIKE_PLAN")
            return
        end

        local targetX = tonumber(coords.x)
        local targetZ = tonumber(coords.z)
        if not targetX or not targetZ then
            context.send(remoteAddress, "ERROR", "INVALID_COORDINATES")
            return
        end

        local results = {}
        local used = {}
        for _, rawIndex in ipairs(plan) do
            local index = parseSelector(rawIndex, false)
            if index and not used[index] then
                used[index] = true
                local success, detail = launchOne(index, targetX, targetZ, false)
                table.insert(results, {
                    launcher = index,
                    success = success,
                    detail = detail,
                })
            end
        end

        context.send(remoteAddress, "STRIKE_RESULT", serialization.serialize(results), targetX, targetZ)
        return
    end

    context.send(remoteAddress, "ERROR", "UNKNOWN_COMMAND", tostring(command))
end

return runtime
