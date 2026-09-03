local component = require("component")
local serialization = require("serialization")

local context = nil
local launchPad = nil
local inventory = nil
local launcherInventorySide = nil
local armed = false

local function findComponent(componentType)
    local address = component.list(componentType)()
    if not address then return nil end
    return component.proxy(address)
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
        inventorySide = launcherInventorySide,
    }
end

local runtime = {}

function runtime.start(ctx)
    context = assert(ctx, "runtime context is required")
    launchPad = findComponent("ntm_launch_pad")
    inventory = findComponent("inventory_controller")
    launcherInventorySide = findLauncherInventorySide()
    armed = false

    if not launchPad then
        error("No ntm_launch_pad detected")
    end

    if context.log then
        context.log(
            "Launchpad runtime started for "
                .. tostring(context.id)
                .. " ("
                .. tostring(context.role)
                .. ")"
        )
    end
end

function runtime.stop()
    armed = false

    if context and context.log then
        context.log("Launchpad runtime stopped")
    end
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

    if command == "ARM" then
        armed = true
        context.send(remoteAddress, "ACK", "ARM", true)
        return
    end

    if command == "DISARM" then
        armed = false
        context.send(remoteAddress, "ACK", "DISARM", true)
        return
    end

    if command == "LAUNCH" then
        if not armed then
            context.send(remoteAddress, "ERROR", "DISARMED")
            return
        end

        local targetX = tonumber(arg1)
        local targetZ = tonumber(arg2)

        if not targetX or not targetZ then
            context.send(remoteAddress, "ERROR", "INVALID_COORDINATES")
            return
        end

        if not launchPad.canLaunch() then
            context.send(remoteAddress, "ERROR", "NOT_READY")
            return
        end

        local success = launchPad.launch(targetX, targetZ)
        if success then armed = false end

        context.send(
            remoteAddress,
            "LAUNCH_RESULT",
            success,
            targetX,
            targetZ
        )
        return
    end

    context.send(remoteAddress, "ERROR", "UNKNOWN_COMMAND", tostring(command))
end

return runtime
