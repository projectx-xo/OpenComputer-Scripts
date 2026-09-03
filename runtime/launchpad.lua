local component = require("component")
local serialization = require("serialization")

local context = nil
local launchPad = nil
local inventory = nil
local armed = false

local MISSILE_PREFIX = "hbm:item.missile_"
local BATTERY_PREFIX = "hbm:item.battery_"

local function findComponent(componentType)
    local address = component.list(componentType)()
    if not address then return nil end
    return component.proxy(address)
end

local function startsWith(value, prefix)
    value = tostring(value or "")
    return value:sub(1, #prefix) == prefix
end

local function getMissileInfo()
    if not inventory then return "", "", 0, nil end

    local batterySide = nil

    for side = 0, 5 do
        local okSize, size = pcall(inventory.getInventorySize, side)
        if okSize and type(size) == "number" and size > 0 then
            for slot = 1, size do
                local okStack, stack = pcall(inventory.getStackInSlot, side, slot)
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

local function getStatus()
    local energy, maxEnergy = launchPad.getEnergyInfo()
    local fuel, fuelMax, fuelType, oxidizer, oxidizerMax, oxidizerType =
        launchPad.getFluid()
    local missileName, missileLabel, missileCount, inventorySide = getMissileInfo()
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
        inventorySide = inventorySide,
    }
end

local runtime = {}

function runtime.start(ctx)
    context = assert(ctx, "runtime context is required")
    launchPad = findComponent("ntm_launch_pad")
    inventory = findComponent("inventory_controller")
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
