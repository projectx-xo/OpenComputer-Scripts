-- Production strike runtime; OC API doubles model partial transfers and fail closed.
local function serialize(v)
    if type(v) == "table" then local out={};for k,x in pairs(v) do out[#out+1]="["..serialize(k).."]="..serialize(x) end;return "{"..table.concat(out,",").."}" end
    return type(v)=="string" and string.format("%q",v) or tostring(v)
end
local function unserialize(s) return assert(load("return "..s,"data","t",{}))() end
local function fixture(custom)
    local f={time=0,sent={},pads={},transposers={},db={},config={launchers={}},fired=0,save=true}
    local function copy(v) return v and unserialize(serialize(v)) end
    local function matches(a,b) return a and b and a.name==b.name and a.damage==b.damage and a.tag==b.tag end
    local parts={database={get=function(slot)return f.db[slot]end,computeHash=function(slot) return f.db[slot] and serialize(f.db[slot]) end}}
    local fuelName,oxName="hbm_propellant_kerosene","hbm_propellant_peroxide"
    f.design={name="hbm:item.missile_custom",damage=0,tag="correct-design",size=1}
    for i=1,2 do
        local index=i
        local state={mode="off",fuel=0,oxidizer=0,solid=0,valid=true,power=true,blockedReturn=false,partial=700}
        f.pads[i]=state
        local t={slots={[1]={},[2]={[1]=copy(f.design)},[3]={}},fluids={
            [0]={name=fuelName,amount=10000,capacity=64000},[4]={name=oxName,amount=10000,capacity=64000}}}
        f.transposers[i]=t
        local pad={getEnergyInfo=function()return 100000,100000 end,getTier=function()return 1 end,
            getFluid=function()return state.fuel,24000,fuelName,state.oxidizer,24000,oxName end,
            canLaunch=function()return state.mode=="off" and t.slots[1][1]~=nil and state.fuel>=2000 and state.oxidizer>=2000 end,
            setServiceMode=function(mode)state.mode=mode;return true end,
            verifyTransposer=function(address,side)return not state.mismatch and address=="t"..index and side==1 end,
            verifyMEInterface=function(address,padSide,supplySide,me)return address=="t"..index and padSide==1 and supplySide==2 and me=="me"..index end,
            getLogisticsInfo=function()return {version=1,mode=state.mode,valid=state.valid and t.slots[1][1]~=nil,
                fuel=fuelName,oxidizer=oxName,fuelType=fuelName,oxidizerType=oxName,fuelStored=state.fuel,oxidizerStored=state.oxidizer,
                fuelRequired=2000,oxidizerRequired=2000,solid=state.solid,solidRequired=custom and 500 or 0,
                ready=t.slots[1][1]~=nil and state.power and state.fuel>=2000 and state.oxidizer>=2000 and (not custom or state.solid>=500)} end,
            launchPrepared=function()
                assert(state.mode=="hold");f.fired=f.fired+1;t.slots[1][1]=nil;state.fuel=state.fuel-2000;state.oxidizer=state.oxidizer-2000;return true
            end,
            launch=function()error("managed launch bypassed interlock")end}
        if custom then
            pad.getContents=pad.getFluid;pad.getLaunchInfo=function()return pad.canLaunch(),true,true,true end
            pad.recoverSolidFuel=function() if t.slots[1][5] then return 0 end;local count=math.min(64,math.floor(state.solid/250));
                if count>0 then t.slots[1][5]={name="hbm:item.rocket_fuel",size=count};state.solid=state.solid-count*250 end;return count end
        end
        parts["p"..i]=pad
        parts["me"..i]={setInterfaceConfiguration=function(slot,db,entry)
            assert(slot==1);t.stock=entry and copy(f.db[entry]) or nil;return true
        end}
        parts["t"..i]={getInventorySize=function(side)return t.slots[side] and 8 end,
            getStackInSlot=function(side,slot)return copy(t.slots[side] and t.slots[side][slot])end,
            compareStackToDatabase=function(side,slot,_,entry,nbt)assert(nbt==true,"NBT comparison disabled");return matches(t.slots[side] and t.slots[side][slot],f.db[entry]) end,
            store=function(side,slot,_,entry)f.db[entry]=copy(t.slots[side][slot]);return false end,
            transferItem=function(source,sink,count,slot,destination)
                local stack=t.slots[source][slot];if not stack then return 0 end
                if source==1 then assert(state.mode=="drain");if state.blockedReturn then return 0 end
                    if slot==1 then assert(state.fuel==0 and state.oxidizer==0,"missile removed before draining")end
                end
                if sink==1 then assert(state.mode=="fill");if not state.valid then return 0 end end
                destination=destination or 1
                if t.slots[sink][destination] then return 0 end
                local moved=math.min(count,stack.size);t.slots[sink][destination]=copy(stack);t.slots[sink][destination].size=moved
                stack.size=stack.size-moved;if stack.size==0 then t.slots[source][slot]=nil end
                return moved
            end,
            getFluidInTank=function(side,tank)
                if side==1 then return {name=tank==1 and fuelName or oxName,amount=tank==1 and state.fuel or state.oxidizer}end
                return copy(t.fluids[side])
            end,
            transferFluid=function(source,sink,count,tank)
                assert(tank==nil,"Do not pass inspection's one-based index to OC transferFluid")
                local fluid=source==1 and t.fluids[sink] or t.fluids[source]
                if not fluid then return false,0 end
                local key=fluid.name==fuelName and "fuel" or "oxidizer"
                local moved
                if source==1 then
                    assert(state.mode=="drain");moved=math.min(count,state[key],fluid.capacity-fluid.amount,state.partial)
                    state[key]=state[key]-moved;fluid.amount=fluid.amount+moved
                else
                    assert(state.mode=="fill");moved=math.min(count,fluid.amount,2000-state[key],state.partial)
                    state[key]=state[key]+moved;fluid.amount=fluid.amount-moved
                end
                return moved>0,moved
            end}
        f.config.launchers[i]={label="L"..i,padAddress="p"..i}
    end
    local component={list=function(kind)
        local list=kind==(custom and "ntm_custom_launch_pad" or "ntm_launch_pad") and {"p1","p2"}
            or kind=="transposer" and {"t1","t2"} or kind=="database" and {"database"} or {}
        local i=0;return function()i=i+1;return list[i]end
    end,proxy=function(address)return parts[address]end}
    local modules={component=component,serialization={serialize=serialize,unserialize=unserialize},computer={uptime=function()return f.time end}}
    f.runtime=assert(loadfile("runtime/strike.lua","t",setmetatable({require=function(n)return assert(modules[n])end},{__index=_G})))()
    f.context={config=f.config,saveConfig=function()return f.save,"disk full"end,send=function(_,...)f.sent[#f.sent+1]={...}end}
    f.runtime.start(f.context)
    function f.command(request,fail)
        f.runtime.onMessage("CENTRAL","LOGISTICS",serialize(request),"token")
        local reply=f.sent[#f.sent];assert(reply[3]=="token","lost request token")
        if not fail then assert(reply[1]=="LOGISTICS",reply[2])else assert(reply[1]=="ERROR",reply[2])end
        return reply[2]
    end
    function f.tick(n)
        for _=1,n or 1 do
            f.time=f.time+0.5
            for i,t in ipairs(f.transposers)do
                if t.stock and not t.slots[2][1] then t.slots[2][1]=copy(t.stock) end
                if custom and f.pads[i].mode=="fill" and t.slots[1][5] then
                    f.pads[i].solid=f.pads[i].solid+250;t.slots[1][5].size=t.slots[1][5].size-1
                    if t.slots[1][5].size==0 then t.slots[1][5]=nil end
                end
            end
            f.runtime.tick()
        end
    end
    function f.setup()
        for i=1,2 do f.command({action="map",launcher=i,transposerAddress="t"..i,padSide=1,supplySide=2,returnSide=3})end
        f.command({action="profile",name="atlas",launcher=1,sourceSlot=1,databaseAddress="database",databaseSlot=1})
    end
    return f
end
local function test(name,body) body();print("PASS logistics "..name) end
test("exact loadout, requested count, partial fills, explicit launch only",function()
    local f=fixture();f.setup();local t=f.transposers[1]
    t.slots[2][2]=t.slots[2][1];t.slots[2][1]={name=f.design.name,damage=0,tag="wrong-design",size=1}
    f.command({action="prepare",name="atlas",count=1});assert(f.runtime.busy());f.tick(40)
    assert(f.pads[1].fuel==2000 and f.pads[1].oxidizer==2000 and f.pads[2].fuel==0)
    assert(t.slots[2][1].tag=="wrong-design" and t.slots[1][1].tag=="correct-design")
    assert(f.runtime.status().readyCount==1 and f.fired==0 and f.pads[1].mode=="hold")
    f.runtime.onMessage("CENTRAL","ARM","1");f.runtime.onMessage("CENTRAL","LAUNCH_SILO","1",serialize({x=5,z=6}))
    assert(f.fired==1 and f.pads[1].mode=="hold")
end)
test("reclaim conserves fuel and returns missile",function()
    local f=fixture();f.setup();f.command({action="prepare",name="atlas",count=1});f.tick(30)
    f.command({action="reclaim",launcher=1});f.tick(30)
    assert(f.pads[1].fuel==0 and f.pads[1].oxidizer==0 and not f.transposers[1].slots[1][1])
    assert(f.transposers[1].fluids[0].amount==10000 and f.transposers[1].fluids[4].amount==10000)
    assert(f.transposers[1].slots[3][1].tag=="correct-design" and f.fired==0)
end)
test("full return tank retains missile and fuel, retry after space is available",function()
    local f=fixture();f.setup();f.command({action="prepare",name="atlas",count=1});f.tick(30)
    f.transposers[1].fluids[0].amount=64000
    f.command({action="reclaim",launcher=1});f.tick(10)
    assert(not f.runtime.busy() and f.pads[1].mode=="hold" and f.pads[1].fuel==2000 and f.transposers[1].slots[1][1])
    assert(f.command({action="status"}):find("FUEL_RETURN_FULL",1,true))
    f.transposers[1].fluids[0].amount=0;f.command({action="reclaim",launcher=1});f.tick(25)
    assert(f.pads[1].fuel==0 and not f.transposers[1].slots[1][1])
end)
test("missing supply, changed database, wrong mapping and failed saves",function()
    local f=fixture();f.setup();f.db[1].tag="changed"
    assert(f.command({action="prepare",name="atlas",count=1},true):find("DATABASE_CHANGED",1,true))
    f.db[1].tag="correct-design";f.pads[2].mismatch=true
    f.command({action="prepare",name="atlas",count=2},true);assert(f.pads[1].mode=="hold")
    f.pads[2].mismatch=false;f.save=false;f.command({action="prepare",name="atlas",count=1},true)
    assert(not f.config.launchers[1].assignedLoadout);f.save=true
    f.transposers[1].slots[2]={};f.command({action="prepare",name="atlas",count=1});f.tick(15)
    assert(f.command({action="status"}):find("MISSILE_MISSING",1,true));assert(f.fired==0)
end)
test("stop and restart hold hardware without replaying preparation",function()
    local f=fixture();f.setup();f.command({action="prepare",name="atlas",count=2});f.tick(5)
    f.runtime.onMessage("CENTRAL","ARM","all");assert(f.sent[#f.sent][1]=="ERROR")
    f.runtime.stop();local fuel=f.pads[1].fuel;f.runtime.start(f.context);f.tick(30)
    assert(not f.runtime.busy() and f.pads[1].fuel==fuel and f.pads[2].fuel==0 and f.pads[1].mode=="hold")
end)
test("ME interface requests exact stock and clears dedicated slot",function()
    local f=fixture();f.setup();f.command({action="me",launcher=1,meAddress="me1",meSlot=1})
    f.transposers[1].slots[2]={};f.command({action="prepare",name="atlas",count=1});f.tick(40)
    assert(f.runtime.status().readyCount==1 and not f.transposers[1].stock and f.fired==0)
end)
test("custom solid fueling and recovery",function()
    local f=fixture(true);f.setup();f.transposers[1].slots[2][2]={name="hbm:item.rocket_fuel",size=2}
    f.command({action="prepare",name="atlas",count=1});f.tick(35)
    assert(f.pads[1].solid==500 and f.runtime.status().readyCount==1)
    f.command({action="reclaim",launcher=1});f.tick(35)
    -- Return inventory has one occupied slot; retain the missile rather than dropping it.
    assert(f.pads[1].solid==0 and f.transposers[1].slots[3][1].name=="hbm:item.rocket_fuel")
    assert(f.pads[1].mode=="hold" and f.transposers[1].slots[1][1])
end)
test("payload changes during fueling never reach ready",function()
    local f=fixture();f.setup();f.command({action="prepare",name="atlas",count=1});f.tick(4)
    assert(f.transposers[1].slots[1][1]);f.transposers[1].slots[1][1].tag="tampered";f.tick(5)
    assert(f.command({action="status"}):find("DESIGN_CHANGED",1,true) and f.runtime.status().readyCount==0 and f.fired==0)
end)
