local failures = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    print((ok and 'PASS ' or 'FAIL ') .. name .. (ok and '' or ': ' .. tostring(err)))
    if not ok then failures = failures + 1 end
end
local function loadRuntime(path, devices)
    local t, timer, sent = 0, nil, {}
    local component = {list = function(kind)
        local addresses = {}; for address, entry in pairs(devices) do if entry.kind == kind then addresses[#addresses + 1] = address end end
        table.sort(addresses); local i = 0
        return function() i = i + 1; return addresses[i] end
    end, proxy = function(address) return assert(devices[address], 'missing device').proxy end}
    local modules = {component = component, serialization = {serialize = function(v) return v end, unserialize = function(v) return v end},
        computer = {uptime = function() return t end}, event = {timer = function(_, fn) timer = fn; return 1 end, cancel = function() timer = nil end}}
    local env = setmetatable({require = function(n) return assert(modules[n], n) end}, {__index = _G})
    local chunk = assert(loadfile(path, 't', env))
    local ctx = {id = 'NODE', role = 'strike', session = 'boot-A', config = {},
        log = function() end, send = function(...) sent[#sent + 1] = {...} end}
    ctx.saveConfig = function(config) ctx.config = config; return true end
    return chunk(), ctx, sent, function(time) t = time; if timer then timer() end end
end
local function pad()
    return {getEnergyInfo = function() return 10, 10 end, getFluid = function() return 0, 0, '', 0, 0, '' end,
        getTier = function() return 20 end, canLaunch = function() return true end, launch = function() return true end}
end

test('explicit launcher mapping wins over sorted component addresses', function()
    local devices = {a = {kind='ntm_launch_pad',proxy=pad()}, b={kind='ntm_launch_pad',proxy=pad()}}
    devices.i = {kind='inventory_controller',proxy={getInventorySize=function(side) return side == 2 and 10 or nil end,
        getStackInSlot=function(_, slot) if slot == 3 then return {name='hbm:item.missile_test',label='TEST',size=1} end end}}
    local r,ctx=loadRuntime('runtime/strike.lua',devices)
    ctx.config.launchers={{label='Bravo',padAddress='b',inventoryAddress='i',side=2,slot=3}}
    r.start(ctx)
    local status=r.status()
    assert(status.launchers[1].padAddress=='b','mapping reordered')
    assert(status.launchers[1].label=='Bravo','label missing')
    assert(status.launchers[1].missileName=='hbm:item.missile_test')
end)

test('cached inventory slot avoids scanning every side and slot', function()
    local reads=0
    local devices={a={kind='ntm_launch_pad',proxy=pad()},i={kind='inventory_controller',proxy={
        getInventorySize=function(side) return side==2 and 10 or nil end,
        getStackInSlot=function(_,slot) reads=reads+1; if slot==8 then return {name='hbm:item.missile_test',size=1} end end}}}
    local r,ctx=loadRuntime('runtime/strike.lua',devices); r.start(ctx); r.status(); reads=0; r.status()
    assert(reads==1,'repeat status scanned '..reads..' slots')
end)

test('ambiguous inventories are left unmapped', function()
    local devices={a={kind='ntm_launch_pad',proxy=pad()},b={kind='ntm_launch_pad',proxy=pad()},i={kind='inventory_controller',proxy={}}}
    local r,ctx=loadRuntime('runtime/strike.lua',devices);r.start(ctx)
    local status=r.status()
    assert(status.launchers[1].inventoryAddress==nil,'guessed an inventory assignment')
    assert(status.launchers[1].ready==false,'unmapped launcher was ready')
end)

test('defense inventory uses the cached missile slot', function()
    local reads=0
    local devices={a={kind='ntm_launch_pad',proxy=pad()},i={kind='inventory_controller',proxy={
        getInventorySize=function(side)return side==2 and 10 or nil end,
        getStackInSlot=function(_,slot)reads=reads+1;if slot==8 then return {name='hbm:item.missile_anti_ballistic',size=1}end end}}}
    local r,ctx=loadRuntime('runtime/launchpad.lua',devices);ctx.role='defense';r.start(ctx);r.status();reads=0;r.status()
    assert(reads==1,'defense status scanned '..reads..' slots')
end)

test('radar observations carry session and increasing sample sequence', function()
    local x=0
    local r,ctx,sent,tick=loadRuntime('runtime/radar.lua',{radar={kind='ntm_radar',proxy={
        getAmount=function()return 1 end,getEntityAtIndex=function()return false,x,100,0,9,'' end}}})
    r.start(ctx);tick(1);x=10;tick(2)
    local first,second=sent[1][3].track,sent[2][3].track
    assert(first.session=='boot-A','session absent')
    assert(first.sequence and second.sequence>first.sequence,'sample sequence absent')
    local summary=r.status('summary');assert(summary.tracks==nil,'summary duplicated tracks')
    assert(summary.activeTrackCount==1)
    assert(r.status('full').tracks[1].x==10)
    r.stop()
end)

test('intelligence commands reject other satellite types without starting', function()
    local starts=0
    local r,ctx,sent=loadRuntime('runtime/intel.lua',{sat={kind='ntm_satlink',proxy={
        isConnected=function()return true end,getType=function()return 'RADAR' end,intelStartScan=function()starts=starts+1 end}}})
    r.start(ctx);r.onMessage('CENTRAL','SCAN',508,1710,'token')
    assert(starts==0);assert(sent[#sent][2]=='ERROR');assert(sent[#sent][4]=='token')
end)

test('combined satellite scan and finding fields use real HBM callback positions', function()
    local target
    local r,ctx,sent=loadRuntime('runtime/intel.lua',{sat={kind='ntm_satlink',proxy={
        isConnected=function()return true end,getType=function()return 'COMBINED_INTEL' end,
        intelStatus=function()return 'COMPLETE',0,0,100 end,
        intelSetTarget=function(x,z)target={x,z};return true,'OK' end,
        intelStartScan=function()return true,'STARTED' end,
        intelSummary=function()return 'COMBINED;508;1710;100%' end,
        intelFindingCount=function()return 1 end,
        intelGetFinding=function()return true,'LAUNCH_SITE',.95,508,40,1710,512,45,1715,true,true,false,true,false,'MISSILE','hbm:test',2 end}}})
    r.start(ctx);r.onMessage('CENTRAL','SCAN',508,1710,'start')
    assert(target[1]==508 and target[2]==1710);assert(sent[#sent][4]=='start')
    r.onMessage('CENTRAL','SCAN_RESULTS',1,'results')
    local reply=sent[#sent];assert(reply[2]=='SCAN_RESULTS');assert(reply[4]=='results')
    assert(reply[3]:find('MISSILE',1,true) and reply[3]:find('hbm:test',1,true) and reply[3]:find('508',1,true))
end)
if failures>0 then error(failures..' runtime tests failed') end
