local failures = 0
local function serialize(v)
    if type(v)=='table' then local out={};for k,x in pairs(v)do out[#out+1]='['..serialize(k)..']='..serialize(x)end;return '{'..table.concat(out,',')..'}'end
    return type(v)=='string' and string.format('%q',v) or tostring(v)
end
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
    local modules = {component = component, serialization = {serialize = serialize, unserialize = function(v)return assert(load('return '..v,'data','t',{}))()end},
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

test('custom Large Launch Pads use their designator and custom callbacks',function()
    local coords, launched
    local custom={getEnergyInfo=function()return 10,10 end,getContents=function()return 0,0,'',0,0,'',50,50 end,
        getLaunchInfo=function()return true,true,true,true end,
        setCoords=function(x,z)coords={x,z};return true end,launch=function(...)assert(select('#',...)==0);launched=true;return true end}
    local devices={large={kind='ntm_custom_launch_pad',proxy=custom},i={kind='inventory_controller',proxy={
        getInventorySize=function(side)return side==0 and 2 end,
        getStackInSlot=function()return {name='hbm:item.missile_custom',size=1}end}}}
    local r,ctx=loadRuntime('runtime/strike.lua',devices);r.start(ctx)
    assert(r.status().launchers[1].ready,'custom pad not ready')
    r.onMessage('CENTRAL','ARM','1')
    r.onMessage('CENTRAL','LAUNCH_SILO','1',serialize({x=507,z=1709}))
    assert(launched and coords[1]==507 and coords[2]==1709,'custom pad did not launch at the requested coordinates')
end)

test('four-shot strikes are spaced without blocking commands or catching up in bursts',function()
    local times,clock={},0
    local devices={i={kind='inventory_controller',proxy={getInventorySize=function()return 1 end,
        getStackInSlot=function()return {name='hbm:item.missile_test',size=1}end}}}
    for i=1,4 do local p=pad();p.launch=function()times[#times+1]=clock;return true end;devices['p'..i]={kind='ntm_launch_pad',proxy=p}end
    local r,ctx,sent,advance=loadRuntime('runtime/strike.lua',devices)
    ctx.config.launchers={};for i=1,4 do ctx.config.launchers[i]={padAddress='p'..i,inventoryAddress='i',side=i}end
    r.start(ctx);r.onMessage('CENTRAL','STRIKE',serialize({1,2,3,4}),serialize({x=507,z=1709,interval=3}))
    assert(#times==0 and sent[#sent][2]=='STRIKE_ACCEPTED','strike fired synchronously instead of acknowledging its queue')
    assert(r.busy(),'queued strike was idle')
    local function tick(t)clock=t;advance(t);r.tick()end
    tick(0);tick(1);tick(2);assert(#times==1)
    r.onMessage('CENTRAL','PING');assert(sent[#sent][2]=='PONG','queue blocked commands')
    tick(3);tick(8);assert(#times==3,'delayed tick fired a burst')
    tick(9);tick(10);assert(#times==3,'interval measured from stale schedule')
    tick(11);assert(#times==4 and times[1]==0 and times[2]==3 and times[3]==8 and times[4]==11)
    assert(not r.busy() and sent[#sent][2]=='STRIKE_RESULT','queue never completed')
end)

test('disarming, stopping or changing a payload prevents remaining queued launches',function()
    for _,action in ipairs({'disarm','stop','swap'})do
        local fired,missile=0,'hbm:item.missile_test'
        local devices={i={kind='inventory_controller',proxy={getInventorySize=function()return 1 end,
            getStackInSlot=function()return {name=missile,size=1}end}}}
        for i=1,2 do local p=pad();p.launch=function()fired=fired+1;return true end;devices['p'..i]={kind='ntm_launch_pad',proxy=p}end
        local r,ctx,sent,advance=loadRuntime('runtime/strike.lua',devices)
        ctx.config.launchers={{padAddress='p1',inventoryAddress='i',side=1},{padAddress='p2',inventoryAddress='i',side=2}}
        r.start(ctx);r.onMessage('CENTRAL','STRIKE',serialize({1,2}),serialize({x=507,z=1709,interval=3}));r.tick()
        assert(fired==1)
        if action=='disarm' then r.onMessage('CENTRAL','DISARM','all')
        elseif action=='stop' then r.stop()
        else missile='hbm:item.missile_different' end
        advance(10);r.tick()
        assert(fired==1 and not r.busy(),action..' failed to cancel queued fire')
        local result
        for _,m in ipairs(sent)do if m[2]=='STRIKE_RESULT' then result=assert(load('return '..m[3]))()end end
        assert(result and #result==2 and result[1].success and not result[2].success,'partial result was lost')
    end
end)

test('invalid or duplicate strike plans cannot partially fire',function()
    local fired=0;local p=pad();p.launch=function()fired=fired+1;return true end
    local r,ctx,sent=loadRuntime('runtime/strike.lua',{p={kind='ntm_launch_pad',proxy=p},i={kind='inventory_controller',proxy={
        getInventorySize=function()return 1 end,getStackInSlot=function()return {name='hbm:item.missile_test',size=1}end}}})
    r.start(ctx)
    for _,plan in ipairs({{1,1},{2},{}})do
        r.onMessage('CENTRAL','STRIKE',serialize(plan),serialize({x=507,z=1709,interval=3}));r.tick()
        assert(sent[#sent][2]=='ERROR' and not r.busy() and fired==0,'invalid plan fired')
    end
end)

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
    local first,second=assert(load('return '..sent[1][3]))().track,assert(load('return '..sent[2][3]))().track
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
