local component = require("component")
local serialization = require("serialization")

local context = nil
local launchPad = nil
local launchPadAddress = nil
local inventory = nil
local armed = false
local inventoryCache = nil
local skyguard = false
local skyguardTracks = {}
local skyguardSequence = 0
local skyguardIds = {}
local skyguardNextId = 1
local nextSkyguardScan = 0
local computer = require("computer")

local function skyguardSnapshot()
    local ok, state, energy, maximum, ammo, ready, x, y, z, dimension, contacts, autoFire = pcall(function()
        local state = launchPad.getState()
        local energy, maximum = launchPad.getEnergyInfo()
        local x, y, z = launchPad.getPos()
        local _, dimension = launchPad.getTargetingInfo()
        return state, energy, maximum, launchPad.getAmmoCount(), launchPad.canLaunch(), x, y, z, dimension,
            launchPad.getTracks(), launchPad.getAutoFire()
    end)
    local result = {skyguard=true, radarStation=true, radarCount=1, tracks={}, activeTrackCount=0,
        armed=armed, ready=false, missileName="hbm:item.missile_skyguard", rawMissileName="hbm:item.missile_skyguard",
        missileLabel="MIM-240 Skyguard Interceptor", missileCount=0, entityTargeting=true,
        range=768, state=ok and state or "UNAVAILABLE", energy=0, maxEnergy=2000000, radars={}}
    if not ok then return result end
    result.energy, result.maxEnergy, result.missileCount = energy, maximum, ammo
    result.ready, result.dimension, result.autoFire = ready == true and autoFire == false, dimension, autoFire
    result.position = {x=x,y=y,z=z}
    result.radars = {{address=launchPadAddress,shortAddress=launchPadAddress:sub(1,8),x=x,y=y,z=z,
        range=768,power=energy,maxPower=maximum,contacts=0,scanMissiles=true}}
    if type(contacts) ~= "table" then result.ready=false; return result end
    local currentIds={}
    for i=1,math.min(16,#contacts) do
        local t=contacts[i]
        if type(t)=="table" and type(t.entityId)=="number" and type(t.entityUuid)=="string" and #t.entityUuid==36
            and type(t.dimension)=="number" and type(t.x)=="number" and type(t.y)=="number" and type(t.z)=="number" then
            if not skyguardIds[t.entityUuid] then skyguardIds[t.entityUuid]=skyguardNextId; skyguardNextId=skyguardNextId+1 end
            t.id=skyguardIds[t.entityUuid]; currentIds[t.entityUuid]=t.id
            t.session=context.session; t.sequence=skyguardSequence
            t.vx=tonumber(t.vx) or 0; t.vy=tonumber(t.vy) or 0; t.vz=tonumber(t.vz) or 0
            t.horizontalSpeed=math.sqrt(t.vx*t.vx+t.vz*t.vz)
            t.totalSpeed=math.sqrt(t.horizontalSpeed*t.horizontalSpeed+t.vy*t.vy)
            t.radars={launchPadAddress:sub(1,8)}; t.isPlayer=false
            result.tracks[#result.tracks+1]=t
        end
    end
    skyguardIds=currentIds
    result.activeTrackCount=#result.tracks; result.radars[1].contacts=#result.tracks
    return result
end

local MISSILE_PREFIX = "hbm:item.missile_"
local BATTERY_PREFIX = "hbm:item.battery_"
local ABM_RAW_ID = "hbm:item.missile_anti_ballistic"
local ABM_CENTRAL_ID = "hbm:item.missile_anti-ballistic"

local function findComponent(componentType)
    local address = component.list(componentType)()
    if not address then return nil end
    return component.proxy(address), address
end

local function startsWith(value, prefix)
    value = tostring(value or "")
    return value:sub(1, #prefix) == prefix
end

local function getMissileInfo()
    if not inventory then return "", "", 0, nil end
    if inventoryCache then
        local ok, stack = pcall(inventory.getStackInSlot, inventoryCache.side, inventoryCache.slot)
        if ok and stack and startsWith(stack.name, MISSILE_PREFIX) then
            return stack.name, stack.label or stack.name, tonumber(stack.size) or 0, inventoryCache.side
        end
        inventoryCache = nil
    end

    local batterySide = nil

    for side = 0, 5 do
        local okSize, size = pcall(inventory.getInventorySize, side)
        if okSize and type(size) == "number" and size > 0 then
            for slot = 1, size do
                local okStack, stack = pcall(inventory.getStackInSlot, side, slot)
                if okStack and stack then
                    local name = tostring(stack.name or "")

                    if startsWith(name, MISSILE_PREFIX) then
                        inventoryCache = {side=side,slot=slot}
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

local function getStatus(detail)
    if skyguard then
        local snapshot=skyguardSnapshot()
        if detail=="summary" then snapshot.tracks=nil end
        return snapshot
    end
    local energy, maxEnergy = launchPad.getEnergyInfo()
    local fuel, fuelMax, fuelType, oxidizer, oxidizerMax, oxidizerType =
        launchPad.getFluid()
    local rawMissileName, missileLabel, missileCount, inventorySide = getMissileInfo()
    local missileName = rawMissileName
    local tier = launchPad.getTier()

    if context and context.role == "defense" and rawMissileName == ABM_RAW_ID then
        missileName = ABM_CENTRAL_ID
    end

    if tier == nil then tier = -1 end

    local position
    -- A cached proxy can omit getPos even while the component accepts it.
    local ok, x, y, z = pcall(component.invoke, launchPadAddress, "getPos")
    if ok then position = {x=x, y=y, z=z} end

    local targetingOk, targeting, dimension = pcall(component.invoke, launchPadAddress, "getTargetingInfo")
    return {
        entityTargeting = targetingOk and targeting == true,
        dimension = targetingOk and dimension or nil,
        position = position,
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
        rawMissileName = rawMissileName,
        missileLabel = missileLabel,
        missileCount = missileCount,
        inventorySide = inventorySide,
    }
end

local runtime = {}

function runtime.start(ctx)
    context = assert(ctx, "runtime context is required")
    skyguard = false; skyguardTracks = {}; skyguardSequence = 0; skyguardIds = {}; skyguardNextId = 1; nextSkyguardScan = 0
    local links = {}; for address in component.list("ntm_skyguard") do links[#links+1]=address end
    table.sort(links)
    launchPad, launchPadAddress = findComponent("ntm_launch_pad")
    if #links > 0 then
        assert(not launchPad, "AMBIGUOUS_DEFENSE_HARDWARE: separate Skyguard and ABM computers")
        local address=context.config.skyguardAddress
        if not address then assert(#links==1,"AMBIGUOUS_SKYGUARD: configure skyguardAddress"); address=links[1] end
        local found=false; for _, candidate in ipairs(links) do if candidate==address then found=true end end
        assert(found,"CONFIGURED_SKYGUARD_MISSING")
        launchPadAddress=address; launchPad=component.proxy(address); skyguard=true
        if context.config.skyguardAddress~=address then
            context.config.skyguardAddress=address
            assert(context.saveConfig(context.config),"SKYGUARD_MAPPING_SAVE_FAILED")
        end
        pcall(launchPad.setAutoFire,false)
    elseif context.config.skyguardAddress then
        error("CONFIGURED_SKYGUARD_MISSING")
    end
    inventory = findComponent("inventory_controller")
    inventoryCache = nil
    armed = false

    if not launchPad then
        error("No ntm_launch_pad or ntm_skyguard detected")
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
    if skyguard and launchPad then pcall(launchPad.setAutoFire,false) end
    skyguardTracks = {}

    if context and context.log then
        context.log("Launchpad runtime stopped")
    end
end

function runtime.busy()
    return armed
end

function runtime.tick()
    if not skyguard or computer.uptime()<nextSkyguardScan then return end
    nextSkyguardScan=computer.uptime()+1
    -- STRATCOM owns launch authorization while its defense runtime is running.
    pcall(launchPad.setAutoFire,false)
    skyguardSequence=skyguardSequence+1
    local snapshot=skyguardSnapshot(); local current={}
    for _, track in ipairs(snapshot.tracks) do
        current[track.id]=track
        context.send(nil,"RADAR_TRACK",serialization.serialize({event=skyguardTracks[track.id] and "UPDATE" or "ACQUIRED",track=track}))
    end
    for id, track in pairs(skyguardTracks) do
        if not current[id] then
            track.sequence=skyguardSequence
            context.send(nil,"RADAR_TRACK",serialization.serialize({event="LOST",track=track}))
        end
    end
    skyguardTracks=current
end

function runtime.status(detail)
    return getStatus(detail)
end

function runtime.onMessage(remoteAddress, command, arg1, arg2)
    if command == "SKYGUARD_CONTROL" then
        local ok, result = pcall(function()
            assert(skyguard,"NOT_SKYGUARD")
            local q=serialization.unserialize(arg1 or "")
            assert(type(q)=="table","INVALID_CONTROL")
            if q.action=="deploy" then return launchPad.deploy() end
            if q.action=="stow" then armed=false; return launchPad.stow() end
            if q.action=="filter" then
                assert((q.category=="BALLISTIC" or q.category=="MISSILES") and type(q.enabled)=="boolean","INVALID_FILTER")
                return launchPad.setTargetCategory(q.category,q.enabled)
            end
            error("INVALID_CONTROL")
        end)
        context.send(remoteAddress,"ACK","SKYGUARD_CONTROL",ok and result==true,arg2)
        return
    end
    if command == "INTERCEPT_STATUS" then
        local ok, outcome = pcall(function()
            local q=serialization.unserialize(arg1)
            assert(type(q)=='table' and type(q.interceptor)=='string' and type(q.entityUuid)=='string'
                and type(q.entityId)=='number' and type(q.dimension)=='number','INVALID_TARGET')
            return component.invoke(launchPadAddress,'getInterceptorStatus',q.interceptor,q.entityId,q.entityUuid,q.dimension)
        end)
        context.send(remoteAddress,'INTERCEPT_STATUS',ok and outcome or 'UNKNOWN',arg2)
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

    if command == "LAUNCH_ENTITY" then
        if not armed then context.send(remoteAddress, "ERROR", "DISARMED"); return end
        local ok, target = pcall(serialization.unserialize, arg1 or "")
        if not ok or type(target) ~= "table" or type(target.entityId) ~= "number"
            or target.entityId % 1 ~= 0 or type(target.entityUuid) ~= "string" or #target.entityUuid ~= 36
            or type(target.dimension) ~= "number" or target.dimension % 1 ~= 0 then
            armed = false
            context.send(remoteAddress, "ERROR", "INVALID_TARGET"); return
        end
        local invoked, success, reason, interceptor = pcall(component.invoke, launchPadAddress, "launchTracked",
            target.entityId, target.entityUuid, target.dimension)
        armed = false
        context.send(remoteAddress, "LAUNCH_RESULT", invoked and success == true, target.entityId,
            invoked and reason or "TARGET_CALLBACK_FAILED", invoked and interceptor or nil)
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
