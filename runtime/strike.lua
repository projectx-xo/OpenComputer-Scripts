local component = require("component")
local serialization = require("serialization")
local computer = require("computer")

local context = nil
local launchers = {}
local armed = {}
local lastHardwareCheck = 0
local strikeQueue = nil
local logistics

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
    for _, address in ipairs(sortedAddresses("transposer")) do availableInventories[address] = true end
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
        local inventoryAddress = mapping.logistics and mapping.logistics.transposerAddress or mapping.inventoryAddress
        local inventory = inventoryAddress and availableInventories[inventoryAddress] and component.proxy(inventoryAddress) or nil
        launchers[index] = {label = mapping.label or ("L" .. index), padAddress = mapping.padAddress,
            custom = customPads[mapping.padAddress] == true,
            pad = availablePads[mapping.padAddress] and component.proxy(mapping.padAddress) or nil,
            inventoryAddress = inventoryAddress, inventory = inventory,
            logistics = mapping.logistics, assignedLoadout = mapping.assignedLoadout,
            side = mapping.logistics and mapping.logistics.padSide or mapping.side, slot = mapping.logistics and 1 or mapping.slot,
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
    local serviceInfo
    if entry.logistics then
        local ok, info = pcall(function()
            logistics.hardware(index)
            local value = pad.getLogisticsInfo()
            if entry.assignedLoadout then
                local profile = logistics.profile(entry.assignedLoadout)
                value.ready = value.ready and logistics.matches(entry.inventory, entry.side, 1, profile)
                value.loadoutHash = profile.hash
            else value.ready = false end
            return value
        end)
        serviceInfo = ok and info or nil
        ready = serviceInfo and serviceInfo.mode == "hold" and serviceInfo.ready == true
            and (not logistics.job) or false
    end
    local missileName, missileLabel, missileCount, inventorySide = scanInventory(entry, force)
    if tier == nil then tier = -1 end

    return {
        index = index,
        label = entry.label,
        mappingReady = entry.inventory ~= nil,
        logistics = entry.logistics ~= nil,
        loadout = entry.assignedLoadout,
        serviceMode = serviceInfo and serviceInfo.mode,
        loadoutHash = serviceInfo and serviceInfo.loadoutHash,
        logisticsState = logistics and logistics.results[index],
        padAddress = entry.padAddress,
        inventoryAddress = entry.inventoryAddress,
        armed = armed[index] == true,
        ready = entry.inventory ~= nil and ready == true and (not entry.logistics or missileCount == 1),
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
        siloLogistics = true,
        logisticsBusy = logistics.job ~= nil,
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

-- Local material movement only: ME stocks supplySide; fuelSides lead to the group's tanks.
logistics = {job = nil, results = {}}
local function integer(value, minimum, maximum)
    return type(value) == "number" and value == value and value % 1 == 0 and value >= minimum and value <= maximum
end
local function requireValue(value, reason)
    if not value then error(reason, 0) end
    return value
end
function logistics.hardware(index)
    local entry = requireValue(launchers[index], "INVALID_LAUNCHER")
    local mapping = requireValue(entry.logistics, "LOGISTICS_UNMAPPED")
    local pad = requireValue(entry.pad, "PAD_MISSING")
    requireValue(type(pad.getLogisticsInfo) == "function" and type(pad.verifyTransposer) == "function"
        and type(pad.setServiceMode) == "function" and type(pad.launchPrepared) == "function", "UPDATE_HBM_FOR_LOGISTICS")
    local transposer = requireValue(component.proxy(mapping.transposerAddress), "TRANSPOSER_MISSING")
    requireValue(pad.verifyTransposer(mapping.transposerAddress, mapping.padSide) == true, "TRANSPOSER_PAD_MISMATCH")
    if mapping.meAddress then
        requireValue(type(pad.verifyMEInterface) == "function" and pad.verifyMEInterface(mapping.transposerAddress,
            mapping.padSide, mapping.supplySide, mapping.meAddress) == true, "ME_INTERFACE_SUPPLY_MISMATCH")
    end
    return entry, mapping, pad, transposer
end
function logistics.profile(name)
    local profile = requireValue((context.config.logisticsProfiles or {})[name], "UNKNOWN_LOADOUT")
    local database = requireValue(component.proxy(profile.databaseAddress), "DATABASE_MISSING")
    requireValue(database.computeHash(profile.databaseSlot) == profile.hash, "LOADOUT_DATABASE_CHANGED")
    return profile
end
function logistics.matches(transposer, side, slot, profile)
    return transposer.compareStackToDatabase(side, slot, profile.databaseAddress, profile.databaseSlot, true) == true
end
function logistics.stock(mapping, profile)
    if not mapping.meAddress then return end
    local me = requireValue(component.proxy(mapping.meAddress), "ME_INTERFACE_MISSING")
    if profile then
        requireValue(me.setInterfaceConfiguration(mapping.meSlot, profile.databaseAddress, profile.databaseSlot, 1) == true,
            "ME_STOCK_REQUEST_FAILED")
    else requireValue(me.setInterfaceConfiguration(mapping.meSlot) == true, "ME_STOCK_CLEAR_FAILED") end
end
function logistics.hold(index)
    local entry = launchers[index]
    if entry and entry.pad and entry.logistics then return pcall(entry.pad.setServiceMode, "hold") end
    return false
end
function logistics.cancel(reason)
    local job = logistics.job
    if not job then return end
    for _, index in ipairs(job.indices) do
        local held = logistics.hold(index)
        local entry = launchers[index]
        if entry and entry.logistics then
            local clean = pcall(function() logistics.hardware(index); logistics.stock(entry.logistics) end)
            if not clean then reason = reason .. "; ME request could not be cleared" end
        end
        if not held then reason = reason .. "; hardware unavailable (persistent interlock retained)" end
    end
    logistics.results[job.indices[job.next]] = reason
    logistics.job = nil
    if context.log then context.log("Logistics: " .. reason) end
end
function logistics.returnItem(transposer, mapping, slot)
    local stack = transposer.getStackInSlot(mapping.padSide, slot)
    if not stack then return false end
    local before = tonumber(stack.size) or 0
    local moved = transposer.transferItem(mapping.padSide, mapping.returnSide, math.min(64, before), slot)
    requireValue(type(moved) == "number" and moved > 0, "RETURN_INVENTORY_FULL_OR_BLOCKED")
    local after = transposer.getStackInSlot(mapping.padSide, slot)
    requireValue(before - (after and after.size or 0) == moved, "ITEM_TRANSFER_CHANGED_UNEXPECTEDLY")
    return true
end
function logistics.fluid(transposer, mapping, tankIndex, fluidName, amount, drain)
    requireValue(fluidName ~= "", "UNSUPPORTED_STORED_FLUID")
    for _, side in ipairs(mapping.fuelSides) do
        local contents = transposer.getFluidInTank(side, 1)
        if contents and contents.name == fluidName then
            local before = transposer.getFluidInTank(mapping.padSide, tankIndex)
            local success, moved
            -- OC 1.8.7 transferFluid uses a raw zero-based sourceTank, unlike tank inspection.
            -- Omit it: pads drain fuel before oxidizer; each supply face is a single-fluid tank.
            if drain then success, moved = transposer.transferFluid(mapping.padSide, side, math.min(16000, amount))
            else success, moved = transposer.transferFluid(side, mapping.padSide, math.min(16000, amount)) end
            if success and type(moved) == "number" and moved > 0 then
                local after = transposer.getFluidInTank(mapping.padSide, tankIndex)
                local delta = (after and after.amount or 0) - (before and before.amount or 0)
                requireValue(delta == (drain and -moved or moved), "FLUID_TRANSFER_CHANGED_UNEXPECTEDLY")
                return
            end
        end
    end
    error((drain and "FUEL_RETURN_FULL_OR_BLOCKED: " or "FUEL_MISSING_OR_BLOCKED: ") .. fluidName, 0)
end
function logistics.step()
    local job = logistics.job
    if not job or computer.uptime() < job.at then return end
    job.at = computer.uptime() + 0.25
    local index = job.indices[job.next]
    local ok, reason = pcall(function()
        local entry, mapping, pad, transposer = logistics.hardware(index)
        local profile = job.profile and logistics.profile(job.profile)
        requireValue(not armed[index], "DISARM_BEFORE_SERVICING")
        local info = pad.getLogisticsInfo()
        requireValue(type(info) == "table" and info.version == 1, "UNSUPPORTED_LOGISTICS_API")
        requireValue(computer.uptime() < job.deadline, "PREPARATION_TIMEOUT")
        logistics.results[index] = job.phase
        if job.phase == "inspect" then
            pad.setServiceMode("hold")
            logistics.stock(mapping)
            local stack = transposer.getStackInSlot(mapping.padSide, 1)
            if not job.reclaim and stack and stack.size == 1
                and (info.fuelStored == 0 or info.fuelType == info.fuel)
                and (info.oxidizerStored == 0 or info.oxidizerType == info.oxidizer)
                and logistics.matches(transposer, mapping.padSide, 1, profile) then
                job.phase = "fuel"
            else job.phase = "drain" end
        elseif job.phase == "drain" then
            pad.setServiceMode("drain")
            if info.fuelStored > 0 then logistics.fluid(transposer, mapping, 1, info.fuelType, info.fuelStored, true); return end
            if info.oxidizerStored > 0 then logistics.fluid(transposer, mapping, 2, info.oxidizerType, info.oxidizerStored, true); return end
            if entry.custom then
                if logistics.returnItem(transposer, mapping, 5) then return end
                if info.solid >= 250 then
                    requireValue(pad.recoverSolidFuel() > 0, "SOLID_RETURN_BLOCKED"); return
                end
            end
            if logistics.returnItem(transposer, mapping, 1) then return end
            job.phase = job.reclaim and "complete" or "load"
        elseif job.phase == "load" then
            pad.setServiceMode("fill")
            logistics.stock(mapping, profile)
            requireValue(not transposer.getStackInSlot(mapping.padSide, 1), "LAUNCHER_INVENTORY_CHANGED")
            local size = transposer.getInventorySize(mapping.supplySide)
            requireValue(integer(size, 1, 256), "SUPPLY_INVENTORY_MISSING_OR_TOO_LARGE")
            -- At most 16 slots inspected per tick, even for large ME export inventories.
            local first = job.sourceSlot or 1
            for slot = first, math.min(size, first + 15) do
                if logistics.matches(transposer, mapping.supplySide, slot, profile) then
                    local moved = transposer.transferItem(mapping.supplySide, mapping.padSide, 1, slot, 1)
                    requireValue(moved == 1, "MISSILE_INSERT_BLOCKED_OR_INCOMPATIBLE_PAD")
                    requireValue(logistics.matches(transposer, mapping.padSide, 1, profile), "LOADED_DESIGN_MISMATCH")
                    logistics.stock(mapping)
                    job.sourceSlot = nil; job.phase = "fuel"; return
                end
            end
            job.sourceSlot = first + 16
            if job.sourceSlot > size then
                if mapping.meAddress then job.sourceSlot = nil; logistics.results[index] = "WAITING_FOR_ME_STOCK"
                else error("MISSILE_MISSING_FROM_ME_SUPPLY", 0) end
            end
        elseif job.phase == "fuel" then
            requireValue(logistics.matches(transposer, mapping.padSide, 1, profile), "LOADED_DESIGN_CHANGED")
            requireValue(info.valid == true, "MISSILE_INCOMPATIBLE_WITH_PAD")
            pad.setServiceMode("fill")
            if info.fuelStored < info.fuelRequired then
                logistics.fluid(transposer, mapping, 1, info.fuel, info.fuelRequired - info.fuelStored, false); return
            end
            if info.oxidizerStored < info.oxidizerRequired then
                logistics.fluid(transposer, mapping, 2, info.oxidizer, info.oxidizerRequired - info.oxidizerStored, false); return
            end
            if info.solid < info.solidRequired then
                local size = transposer.getInventorySize(mapping.supplySide)
                requireValue(integer(size, 1, 256), "SUPPLY_INVENTORY_MISSING_OR_TOO_LARGE")
                local pending = transposer.getStackInSlot(mapping.padSide, 5)
                if pending then return end -- The machine consumes one item per game tick.
                for slot = job.sourceSlot or 1, math.min(size, (job.sourceSlot or 1) + 15) do
                    local stack = transposer.getStackInSlot(mapping.supplySide, slot)
                    if stack and stack.name == "hbm:item.rocket_fuel" then
                        requireValue(transposer.transferItem(mapping.supplySide, mapping.padSide,
                            math.min(64, math.ceil((info.solidRequired-info.solid)/250)), slot, 5) > 0, "SOLID_INSERT_BLOCKED")
                        job.sourceSlot = nil; return
                    end
                end
                job.sourceSlot = (job.sourceSlot or 1) + 16
                requireValue(job.sourceSlot <= size, "SOLID_FUEL_MISSING_FROM_ME_SUPPLY")
                return
            end
            pad.setServiceMode("hold")
            if info.ready then job.phase = "complete" else logistics.results[index] = "WAITING_FOR_POWER_DESIGNATOR_OR_ERECTOR" end
        elseif job.phase == "complete" then
            if not job.reclaim then
                requireValue(info.ready and logistics.matches(transposer, mapping.padSide, 1, profile), "PREPARED_PAYLOAD_CHANGED")
            end
            requireValue(pad.setServiceMode("hold") == true, "COULD_NOT_HOLD_LAUNCHER")
            logistics.results[index] = job.reclaim and "RECLAIMED" or ("PREPARED: " .. job.profile)
            job.next = job.next + 1
            if job.next > #job.indices then
                logistics.job = nil
                if context.log then context.log("Logistics completed for " .. #job.indices .. " launcher(s)") end
            else job.phase = "inspect"; job.deadline = computer.uptime() + 180; job.sourceSlot = nil end
        end
    end)
    if not ok then logistics.cancel("BLOCKED: " .. tostring(reason)) end
end
function logistics.command(request)
    local action = request.action
    if action == "status" then
        local lines = {logistics.job and ("Running " .. logistics.job.phase) or "Idle (no automatic restart/retry)"}
        for i, entry in ipairs(launchers) do
            lines[#lines+1] = "L" .. i .. " " .. entry.label .. " loadout=" .. tostring(entry.assignedLoadout or "none")
                .. " " .. tostring(logistics.results[i] or (entry.logistics and "MAPPED" or "UNMAPPED"))
        end
        return table.concat(lines, "\n")
    end
    if action == "cancel" then logistics.cancel("CANCELLED"); return "Cancelled; launchers remain interlocked" end
    requireValue(not logistics.job and not strikeQueue, "LOGISTICS_OR_STRIKE_BUSY")
    for _, value in pairs(armed) do requireValue(not value, "DISARM_BEFORE_SERVICING") end
    if action == "map" then
        requireValue(integer(request.launcher, 1, #launchers), "INVALID_LAUNCHER")
        requireValue(type(request.transposerAddress) == "string", "INVALID_TRANSPOSER")
        requireValue(integer(request.padSide, 0, 5) and integer(request.supplySide, 0, 5)
            and integer(request.returnSide, 0, 5), "INVALID_SIDE")
        requireValue(request.padSide ~= request.supplySide and request.padSide ~= request.returnSide, "PAD_SIDE_OVERLAPS_SUPPLY")
        local fuelSides = {}
        for side = 0, 5 do
            if side ~= request.padSide and side ~= request.supplySide and side ~= request.returnSide then fuelSides[#fuelSides+1] = side end
        end
        for i, entry in ipairs(launchers) do
            requireValue(i == request.launcher or not entry.logistics or entry.logistics.transposerAddress ~= request.transposerAddress,
                "TRANSPOSER_ALREADY_ASSIGNED")
        end
        local entry = launchers[request.launcher]
        requireValue(entry.pad and type(entry.pad.verifyTransposer) == "function", "UPDATE_HBM_FOR_LOGISTICS")
        requireValue(entry.pad.verifyTransposer(request.transposerAddress, request.padSide), "TRANSPOSER_PAD_MISMATCH")
        local mapping = {transposerAddress=request.transposerAddress, padSide=request.padSide,
            supplySide=request.supplySide, returnSide=request.returnSide, fuelSides=fuelSides}
        local saved = context.config.launchers[request.launcher]
        local old = saved.logistics; saved.logistics = mapping
        local ok, err = context.saveConfig(context.config)
        if not ok then saved.logistics = old; error("Could not save mapping: " .. tostring(err), 0) end
        refreshHardware()
        requireValue(logistics.hold(request.launcher), "MAPPING_SAVED_BUT_INTERLOCK_FAILED")
        return "Mapped L" .. request.launcher .. "; remaining transposer sides are local fuel tanks"
    elseif action == "me" then
        local entry, mapping, pad = logistics.hardware(request.launcher)
        requireValue(type(request.meAddress) == "string" and integer(request.meSlot, 1, 9), "INVALID_ME_ADDRESS_OR_SLOT")
        requireValue(type(pad.verifyMEInterface) == "function" and pad.verifyMEInterface(mapping.transposerAddress,
            mapping.padSide, mapping.supplySide, request.meAddress), "ME_INTERFACE_SUPPLY_MISMATCH")
        for i, other in ipairs(launchers) do
            requireValue(i == request.launcher or not other.logistics or other.logistics.meAddress ~= request.meAddress,
                "ME_INTERFACE_ALREADY_ASSIGNED")
        end
        local oldAddress, oldSlot = mapping.meAddress, mapping.meSlot
        mapping.meAddress, mapping.meSlot = request.meAddress, request.meSlot
        local ok, err = context.saveConfig(context.config)
        if not ok then mapping.meAddress, mapping.meSlot = oldAddress, oldSlot; error("Could not save ME binding: " .. tostring(err), 0) end
        return "Bound dedicated ME interface slot; STRATCOM will request and clear missile stock here"
    elseif action == "profile" then
        requireValue(type(request.name) == "string" and #request.name <= 32 and request.name:match("^[%w_-]+$"), "INVALID_LOADOUT_NAME")
        requireValue(integer(request.sourceSlot, 1, 256) and integer(request.databaseSlot, 1, 81)
            and type(request.databaseAddress) == "string", "INVALID_DATABASE_OR_SLOT")
        local _, mapping, _, transposer = logistics.hardware(request.launcher)
        local stack = transposer.getStackInSlot(mapping.supplySide, request.sourceSlot)
        requireValue(stack and startsWith(stack.name, MISSILE_PREFIX), "PUT_EXAMPLE_MISSILE_IN_ME_SUPPLY_SLOT")
        local database = requireValue(component.proxy(request.databaseAddress), "DATABASE_MISSING")
        context.config.logisticsProfiles = context.config.logisticsProfiles or {}
        for name, profile in pairs(context.config.logisticsProfiles) do
            requireValue(name == request.name or profile.databaseAddress ~= request.databaseAddress
                or profile.databaseSlot ~= request.databaseSlot, "DATABASE_SLOT_USED_BY_ANOTHER_LOADOUT")
        end
        -- OC store returns whether it replaced an entry, not whether storage succeeded.
        requireValue(not database.get(request.databaseSlot) or logistics.matches(transposer, mapping.supplySide, request.sourceSlot,
            {databaseAddress=request.databaseAddress,databaseSlot=request.databaseSlot}), "DATABASE_SLOT_NOT_EMPTY: choose an unused slot")
        if not database.get(request.databaseSlot) then
            transposer.store(mapping.supplySide, request.sourceSlot, request.databaseAddress, request.databaseSlot)
        end
        local profile = {databaseAddress=request.databaseAddress,databaseSlot=request.databaseSlot,
            hash=requireValue(database.computeHash(request.databaseSlot), "DATABASE_STORE_FAILED"), label=stack.label or stack.name}
        requireValue(logistics.matches(transposer, mapping.supplySide, request.sourceSlot, profile), "DATABASE_STORE_MISMATCH")
        local old = context.config.logisticsProfiles[request.name]
        context.config.logisticsProfiles[request.name] = profile
        local ok, err = context.saveConfig(context.config)
        if not ok then context.config.logisticsProfiles[request.name] = old; error("Could not save loadout: " .. tostring(err), 0) end
        return "Saved exact loadout " .. request.name .. " (item, damage and NBT)"
    elseif action == "prepare" or action == "reclaim" then
        local indices = {}
        if action == "prepare" then
            logistics.profile(request.name)
            requireValue(integer(request.count, 1, #launchers), "INVALID_LAUNCHER_COUNT")
            for i, entry in ipairs(launchers) do
                if entry.logistics and entry.pad and not armed[i] and #indices < request.count then indices[#indices+1] = i end
            end
            requireValue(#indices == request.count, "NOT_ENOUGH_MAPPED_LAUNCHERS")
        else
            local selector = parseSelector(request.launcher, true)
            requireValue(selector, "INVALID_LAUNCHER")
            if selector == "all" then
                for i, entry in ipairs(launchers) do if entry.logistics then indices[#indices+1] = i end end
            else indices[1] = selector end
            requireValue(#indices > 0, "NO_MAPPED_LAUNCHERS")
        end
        -- Validate the whole group before locking or moving any inventory.
        for _, index in ipairs(indices) do logistics.hardware(index) end
        local old = {}
        for _, index in ipairs(indices) do
            old[index] = context.config.launchers[index].assignedLoadout
            if action == "prepare" then context.config.launchers[index].assignedLoadout = request.name end
        end
        local saved, err = context.saveConfig(context.config)
        if not saved then
            for _, index in ipairs(indices) do context.config.launchers[index].assignedLoadout = old[index] end
            error("Could not save assignments: " .. tostring(err), 0)
        end
        refreshHardware()
        for _, index in ipairs(indices) do
            requireValue(logistics.hold(index), "COULD_NOT_HOLD_LAUNCHER")
            logistics.results[index] = "QUEUED"
        end
        logistics.job = {indices=indices,next=1,phase="inspect",profile=action == "prepare" and request.name or nil,
            reclaim=action == "reclaim",at=computer.uptime(),deadline=computer.uptime()+180}
        return "Queued " .. action .. " for " .. #indices .. " launcher(s); use logistics status"
    end
    error("UNKNOWN_LOGISTICS_ACTION", 0)
end

local function launchOne(index, targetX, targetZ, requireArmed)
    local entry = launchers[index]
    if not entry then return false, "INVALID_LAUNCHER" end
    if requireArmed and not armed[index] then return false, "DISARMED" end
    local status = launcherStatus(index, true)
    if not status.ready or status.missileCount < 1 then return false, "NOT_READY_OR_UNMAPPED" end

    local ok, success = pcall(function()
        if entry.logistics then
            local _, mapping, pad, transposer = logistics.hardware(index)
            local profile = logistics.profile(entry.assignedLoadout)
            requireValue(logistics.matches(transposer, mapping.padSide, 1, profile), "LOADED_DESIGN_CHANGED")
            return pad.launchPrepared(targetX, targetZ)
        end
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
    logistics.job = nil
    logistics.results = {}

    refreshHardware()
    for index, entry in ipairs(launchers) do
        if entry.logistics then
            logistics.hold(index)
            local ok = pcall(function() logistics.hardware(index); logistics.stock(entry.logistics) end)
            logistics.results[index] = ok and "HELD_AFTER_START" or "HARDWARE_CHECK_REQUIRED"
        end
    end
    if #launchers < 1 then error("No ntm_launch_pad or ntm_custom_launch_pad detected; connect to the pad core") end
    if context.log then context.log("Strike runtime started; " .. #launchers .. " saved launcher(s)") end
end

function runtime.stop()
    logistics.cancel("CANCELLED: runtime stopped")
    for index, entry in ipairs(launchers) do if entry.logistics then logistics.hold(index) end end
    finishStrike("CANCELLED: runtime stopped")
    for index = 1, #launchers do armed[index] = false end
    if context and context.log then context.log("Strike runtime stopped") end
end

function runtime.busy()
    if strikeQueue or logistics.job then return true end
    for _, value in pairs(armed) do if value then return true end end
    return false
end

function runtime.tick()
    logistics.step()
    if computer.uptime() - lastHardwareCheck >= 10 then refreshHardware() end
    local q=strikeQueue
    if not q or computer.uptime()<q.at then return end
    local index=q.plan[q.next]
    local status=launcherStatus(index,true)
    local success,detail=false,"PAYLOAD_CHANGED"
    if status and status.padAddress==q.expected[index].padAddress and status.missileName==q.expected[index].missileName
        and status.loadoutHash==q.expected[index].loadoutHash then
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
    if command == "LOGISTICS" then
        local ok, result = pcall(function()
            local request = serialization.unserialize(arg1)
            requireValue(type(request) == "table", "INVALID_LOGISTICS_REQUEST")
            return logistics.command(request)
        end)
        context.send(remoteAddress, ok and "LOGISTICS" or "ERROR", tostring(result), arg2)
        return
    end
    if (strikeQueue or logistics.job) and (command=="STRIKE" or command=="LAUNCH_SILO" or command=="ARM" or command=="MAP") then
        context.send(remoteAddress,"ERROR","STRIKE_OR_LOGISTICS_BUSY");return
    end
    if command == "HARDWARE" then
        local lines = {"Saved launcher assignments:"}
        for index, entry in ipairs(launchers) do
            lines[#lines + 1] = "L" .. index .. " " .. entry.label .. " pad=" .. entry.padAddress
                .. " inventory=" .. tostring(entry.inventoryAddress or "UNMAPPED") .. " side=" .. tostring(entry.side or "auto")
        end
        lines[#lines + 1] = "Transposers: " .. table.concat(sortedAddresses("transposer"), ", ")
        lines[#lines + 1] = "ME interfaces: " .. table.concat(sortedAddresses("me_interface"), ", ")
        lines[#lines + 1] = "Databases: " .. table.concat(sortedAddresses("database"), ", ")
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
        mapping.logistics = old.logistics
        mapping.assignedLoadout = old.assignedLoadout
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
        if not value then
            finishStrike("CANCELLED: disarmed")
            logistics.cancel("CANCELLED: disarmed")
        end
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
            expected[index]={padAddress=status.padAddress,missileName=status.missileName,loadoutHash=status.loadoutHash}
        end
        strikeQueue={remote=remoteAddress,plan=plan,expected=expected,x=targetX,z=targetZ,interval=interval,next=1,at=computer.uptime(),results={}}
        context.send(remoteAddress,"STRIKE_ACCEPTED",#plan,interval,targetX,targetZ)
        return
    end

    context.send(remoteAddress, "ERROR", "UNKNOWN_COMMAND", tostring(command))
end

return runtime
