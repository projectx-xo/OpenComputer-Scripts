local component = require("component")
local serialization = require("serialization")
local computer = require("computer")

local context = nil
local launchers = {}
local armed = {}
local lastHardwareCheck = 0
local strikeQueue = nil

local MISSILE_PREFIX = "hbm:item.missile_"

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

local function scanInventory(entry, force)
    local controller = entry.inventory
    if not controller then return "", "UNMAPPED", 0, nil end
    local cache = entry.cache
    if cache and (force or computer.uptime() - cache.checked < 30) then
        local ok, stack = pcall(controller.getStackInSlot, cache.side, cache.slot)
        if ok and stack and startsWith(stack.name, MISSILE_PREFIX) then
            return stack.name, stack.label or stack.name, tonumber(stack.size) or 0, cache.side
        end
    end
    entry.cache = nil
    local first, last = entry.side or 0, entry.side or 5
    for side = first, last do
        local ok, size = pcall(controller.getInventorySize, side)
        if ok and type(size) == "number" then
            local startSlot, endSlot = entry.slot or 1, entry.slot or size
            for slot = startSlot, endSlot do
                local read, stack = pcall(controller.getStackInSlot, side, slot)
                if read and stack and startsWith(stack.name, MISSILE_PREFIX) then
                    entry.cache = {side = side, slot = slot, checked = computer.uptime()}
                    return stack.name, stack.label or stack.name, tonumber(stack.size) or 0, side
                end
            end
        end
    end
    return "", "UNLOADED", 0, entry.side
end

local function refreshHardware()
    local pads, inventories = sortedAddresses("ntm_launch_pad"), sortedAddresses("inventory_controller")
    local customPads = {}
    for _,address in ipairs(sortedAddresses("ntm_custom_launch_pad")) do pads[#pads+1]=address;customPads[address]=true end
    table.sort(pads)
    local availablePads, availableInventories = {}, {}
    for _, address in ipairs(pads) do availablePads[address] = true end
    for _, address in ipairs(inventories) do availableInventories[address] = true end
    context.config = context.config or {}
    local saved = context.config.launchers or {}
    local found, changed = {}, context.config.launchers == nil
    for _, mapping in ipairs(saved) do found[mapping.padAddress] = true end
    for _, address in ipairs(pads) do
        if not found[address] then
            saved[#saved + 1] = {label = "L" .. (#saved + 1), padAddress = address,
                inventoryAddress = #pads == 1 and #inventories == 1 and inventories[1] or nil}
            changed = true
        end
    end
    context.config.launchers = saved
    if changed and context.saveConfig then
        local ok, err = context.saveConfig(context.config)
        if not ok then error("Cannot save launcher assignments: " .. tostring(err)) end
    end
    for index, mapping in ipairs(saved) do
        local old = launchers[index]
        local inventory = mapping.inventoryAddress and availableInventories[mapping.inventoryAddress]
            and component.proxy(mapping.inventoryAddress) or nil
        launchers[index] = {label = mapping.label or ("L" .. index), padAddress = mapping.padAddress,
            custom = customPads[mapping.padAddress] == true,
            pad = availablePads[mapping.padAddress] and component.proxy(mapping.padAddress) or nil,
            inventoryAddress = mapping.inventoryAddress, inventory = inventory, side = mapping.side, slot = mapping.slot,
            cache = old and old.inventoryAddress == mapping.inventoryAddress and old.side == mapping.side
                and old.slot == mapping.slot and inventory and old.cache or nil}
    end
    lastHardwareCheck = computer.uptime()
end

local function launcherStatus(index, force)
    local entry = launchers[index]
    if not entry then return nil end

    local pad = entry.pad
    if not pad then return {index=index,label=entry.label,padAddress=entry.padAddress,inventoryAddress=entry.inventoryAddress,
        ready=false,armed=false,missileName="",missileLabel="HARDWARE MISSING",missileCount=0} end
    local energy, maxEnergy = pad.getEnergyInfo()
    local fuel, fuelMax, fuelType, oxidizer, oxidizerMax, oxidizerType, solid, solidMax
    local tier, ready
    if entry.custom then
        fuel,fuelMax,fuelType,oxidizer,oxidizerMax,oxidizerType,solid,solidMax=pad.getContents()
        ready=pad.getLaunchInfo()
    else
        fuel,fuelMax,fuelType,oxidizer,oxidizerMax,oxidizerType=pad.getFluid()
        tier=pad.getTier();ready=pad.canLaunch()
    end
    local missileName, missileLabel, missileCount, inventorySide = scanInventory(entry, force)
    if tier == nil then tier = -1 end

    return {
        index = index,
        label = entry.label,
        mappingReady = entry.inventory ~= nil,
        padAddress = entry.padAddress,
        inventoryAddress = entry.inventoryAddress,
        armed = armed[index] == true,
        ready = entry.inventory ~= nil and ready == true,
        custom = entry.custom,
        solid = solid,
        solidMax = solidMax,
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
        strikeScheduling = true,
        strikeRemaining = strikeQueue and (#strikeQueue.plan-strikeQueue.next+1) or 0,
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
    local status = launcherStatus(index, true)
    if not status.ready or status.missileCount < 1 then return false, "NOT_READY_OR_UNMAPPED" end

    local ok, success = pcall(function()
        if entry.custom then
            local set, reason=entry.pad.setCoords(targetX,targetZ)
            if not set then error(reason or "Designator not found") end
            return entry.pad.launch()
        end
        return entry.pad.launch(targetX,targetZ)
    end)
    if not ok then return false, "LAUNCH_EXCEPTION: " .. tostring(success) end
    if success then armed[index] = false end
    return success == true, success == true and "OK" or "LAUNCH_FAILED"
end

local runtime = {}

local function finishStrike(reason)
    local q=strikeQueue;if not q then return end
    if reason then
        for n=q.next,#q.plan do q.results[#q.results+1]={launcher=q.plan[n],success=false,detail=reason} end
    end
    strikeQueue=nil
    context.send(q.remote,"STRIKE_RESULT",serialization.serialize(q.results),q.x,q.z)
end

function runtime.start(ctx)
    context = assert(ctx, "runtime context is required")
    launchers = {}
    armed = {}
    strikeQueue = nil

    refreshHardware()
    if #launchers < 1 then error("No ntm_launch_pad or ntm_custom_launch_pad detected; connect to the pad core") end
    if context.log then context.log("Strike runtime started; " .. #launchers .. " saved launcher(s)") end
end

function runtime.stop()
    finishStrike("CANCELLED: runtime stopped")
    for index = 1, #launchers do armed[index] = false end
    if context and context.log then context.log("Strike runtime stopped") end
end

function runtime.busy()
    if strikeQueue then return true end
    for _, value in pairs(armed) do if value then return true end end
    return false
end

function runtime.tick()
    if computer.uptime() - lastHardwareCheck >= 10 then refreshHardware() end
    local q=strikeQueue
    if not q or computer.uptime()<q.at then return end
    local index=q.plan[q.next]
    local status=launcherStatus(index,true)
    local success,detail=false,"PAYLOAD_CHANGED"
    if status and status.padAddress==q.expected[index].padAddress and status.missileName==q.expected[index].missileName then
        success,detail=launchOne(index,q.x,q.z,false)
    end
    q.results[#q.results+1]={launcher=index,success=success,detail=detail}
    q.next=q.next+1
    context.send(q.remote,"STRIKE_PROGRESS",index,success,q.next-1,#q.plan,q.x,q.z)
    if not success then finishStrike("CANCELLED_AFTER_FAILURE")
    elseif q.next>#q.plan then finishStrike()
    else q.at=computer.uptime()+q.interval end
end

function runtime.status()
    return getStatus()
end

function runtime.onMessage(remoteAddress, command, arg1, arg2)
    if strikeQueue and (command=="STRIKE" or command=="LAUNCH_SILO" or command=="ARM" or command=="MAP") then
        context.send(remoteAddress,"ERROR","STRIKE_BUSY");return
    end
    if command == "HARDWARE" then
        local lines = {"Saved launcher assignments:"}
        for index, entry in ipairs(launchers) do
            lines[#lines + 1] = "L" .. index .. " " .. entry.label .. " pad=" .. entry.padAddress
                .. " inventory=" .. tostring(entry.inventoryAddress or "UNMAPPED") .. " side=" .. tostring(entry.side or "auto")
        end
        lines[#lines + 1] = "Inventory controllers: " .. table.concat(sortedAddresses("inventory_controller"), ", ")
        context.send(remoteAddress, "HARDWARE", table.concat(lines, "\n"), arg1)
        return
    elseif command == "MAP" then
        local ok, mapping = pcall(serialization.unserialize, arg1)
        if not ok or type(mapping) ~= "table" or type(mapping.label) ~= "string"
            or not tonumber(mapping.side) or mapping.side % 1 ~= 0 or mapping.side < 0 or mapping.side > 5
            or (mapping.slot and (type(mapping.slot) ~= "number" or mapping.slot < 1 or mapping.slot % 1 ~= 0)) then
            context.send(remoteAddress, "ERROR", "Invalid mapping", arg2); return
        end
        for _, value in pairs(armed) do if value then context.send(remoteAddress,"ERROR","Disarm before mapping",arg2); return end end
        local available = {}
        for address in component.list("inventory_controller") do available[address] = true end
        if not available[mapping.inventoryAddress] then context.send(remoteAddress,"ERROR","Inventory controller not found",arg2); return end
        local index
        for i, entry in ipairs(launchers) do if entry.padAddress == mapping.padAddress then index = i end end
        if not index then context.send(remoteAddress,"ERROR","Pad not found",arg2); return end
        for i, entry in ipairs(context.config.launchers) do
            if i ~= index and (entry.label == mapping.label or (entry.inventoryAddress == mapping.inventoryAddress
                and entry.side == mapping.side)) then context.send(remoteAddress,"ERROR","Label or inventory side already assigned",arg2); return end
        end
        local old = context.config.launchers[index]
        context.config.launchers[index] = mapping
        local saved, err = context.saveConfig(context.config)
        if not saved then
            context.config.launchers[index] = old
            context.send(remoteAddress,"ERROR","Could not save mapping: " .. tostring(err),arg2); return
        end
        refreshHardware()
        context.send(remoteAddress, "HARDWARE", "Saved " .. mapping.label .. " as L" .. index, arg2)
        return
    end
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
        if not value then finishStrike("CANCELLED: disarmed") end
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
        local interval=tonumber(coords.interval or 1)
        if not interval or interval~=interval or interval<1 or interval>60 or #plan<1 or #plan>#launchers then
            context.send(remoteAddress,"ERROR","INVALID_STRIKE_PLAN");return
        end
        local expected={}
        local used = {}
        for _, rawIndex in ipairs(plan) do
            local index = parseSelector(rawIndex, false)
            if not index or used[index] then context.send(remoteAddress,"ERROR","INVALID_STRIKE_PLAN");return end
            used[index]=true
            local status=launcherStatus(index,true)
            if not status.ready or status.missileCount<1 then context.send(remoteAddress,"ERROR","NOT_READY_OR_UNMAPPED");return end
            expected[index]={padAddress=status.padAddress,missileName=status.missileName}
        end
        strikeQueue={remote=remoteAddress,plan=plan,expected=expected,x=targetX,z=targetZ,interval=interval,next=1,at=computer.uptime(),results={}}
        context.send(remoteAddress,"STRIKE_ACCEPTED",#plan,interval,targetX,targetZ)
        return
    end

    context.send(remoteAddress, "ERROR", "UNKNOWN_COMMAND", tostring(command))
end

return runtime
