-- Execute the entire CENTRAL service against a simulated OpenOS event/modem boundary.
local function serialize(value)
    if type(value)=='table' then
        local out={};for k,v in pairs(value) do out[#out+1]='['..serialize(k)..']='..serialize(v) end
        return '{'..table.concat(out,',')..'}'
    elseif type(value)=='string' then return string.format('%q',value)
    else return tostring(value) end
end
local function unserialize(value) return assert(load('return '..value,'data','t',{}))() end
local clock, listener, nextId, timers = 0, nil, 0, {}
local files, queue, replies, traffic = {}, {}, {}, {}
files["/home/stratcom/preferences.db"] = serialize({defense={protectX=0,protectZ=0,radius=100}})
local ready, closed, stopped, userStatusStarted = false, 0, false, nil
local nativeLoadfile = loadfile
local intelMode = 0
local function packet(kind,payload,replyTo,delay)
    nextId=nextId+1
    queue[#queue+1]={at=clock+(delay or 0),port=kind=='RUNTIME' and 4511 or 4510,envelope={protocol=2,id='rx'..nextId,
        replyTo=replyTo,source='N1',destination='CENTRAL',ttl=6,kind=kind,payload=payload}}
end
local fs={exists=function(path)return files[path]~=nil end,makeDirectory=function()return true end,
    remove=function(path)files[path]=nil;return true end,
    rename=function(a,b)if not files[a] then return nil,'missing' end;files[b]=files[a];files[a]=nil;return true end}
local function fileOpen(path,mode)
    if mode=='r' and files[path]==nil then return nil end
    if mode=='w' then files[path]='' end
    return {read=function()return files[path]end,write=function(_,value)files[path]=files[path]..value;return true end,flush=function()return true end,close=function()end}
end
local modem={open=function()end,close=function()closed=closed+1 end,broadcast=function(port,marker,encoded)
    local e=unserialize(encoded);local p=e.payload;traffic[#traffic+1]=e
    if p[1]=='DISCOVER' then packet('BOOT_HELLO',{'N1','strike','3.0.0','3.0.0','running','running','session-A'})
    elseif p[1]=='CLAIM' then packet('MGMT_ACK',{'CLAIM',true})
    elseif p[1]=='START' then
        packet('MGMT_ACK',{'START',true,'WRONG REQUEST'},'unrelated',.1)
        packet('RUNTIME',{'ACK','ARM',true},e.id,.2)
        packet('MGMT_ACK',{'START',true,'STARTED'},e.id,2)
    elseif p[1]=='ARM' then packet('RUNTIME',{'ACK','ARM',false,'NO_PAYLOAD'},e.id,1)
    elseif p[1]=='PING' then packet('RUNTIME',{'PONG','strike'},nil,.5)
    elseif p[1]=='STOP' then stopped=true
    elseif p[1]=='DISARM' then packet('RUNTIME',{'ACK','DISARM',true},e.id,1)
    elseif p[1]=='MAINTENANCE' then packet('MGMT_ACK',{'MAINTENANCE',true},e.id,1)
    elseif p[1]=='RESTART' then packet('MGMT_ACK',{'RESTART',true},e.id,1)
    elseif p[1]=='INFO' then packet('BOOT_INFO',{serialize({id='N1',role='strike',runtimeState='running',runtimeVersion='3.0.0'})},e.id,1)
    elseif p[1]=='LAUNCH' then
        packet('RUNTIME',{'PONG','INCIDENTAL'},e.id,.1)
        packet('RUNTIME',{'LAUNCH_RESULT',true,'LAUNCHED'},e.id,2)
    elseif p[1]=='STATUS' then
        local status = intelMode==0 and {ready=true,armed=true,missileLabel='TEST PAYLOAD',missileName='hbm:item.missile_test'}
            or intelMode==1 and {intelligence=true,satelliteType='COMBINED_INTEL',scanState='RUNNING',scanProgress='50% coverage'}
            or {intelligence=true,ready=false,error='Satellite link disconnected'}
        packet('RUNTIME',{'STATUS',serialize(status),p[3]})
    end
    return true
end}
local event={listen=function(_,fn)listener=fn end,ignore=function()listener=nil end,
    timer=function(interval,fn,times)nextId=nextId+1;timers[nextId]={at=clock+interval,interval=interval,fn=fn,left=times};return nextId end,
    cancel=function(id)timers[id]=nil end}
function event.pull(timeout)
    clock=clock+(tonumber(timeout) or .1)
    for id,timer in pairs(timers)do if clock>=timer.at then
        timer.at=clock+timer.interval;timer.left=timer.left-1;timer.fn();if timer.left<=0 then timers[id]=nil end
    end end
    for i=#queue,1,-1 do
        local item=queue[i]
        if item.at<=clock and listener then table.remove(queue,i);listener('modem_message',nil,nil,item.port,nil,'STRATCOM_NET',serialize(item.envelope)) end
    end
    if clock>300 then error('CENTRAL service failed to terminate') end
end
local modules={component={list=function()return function()return 'modem' end end,proxy=function()return modem end},
    event=event,computer={uptime=function()return clock end},term={clear=function()error('service cleared terminal')end},
    filesystem=fs,serialization={serialize=serialize,unserialize=unserialize}}
local env=setmetatable({require=function(name)return assert(modules[name],name)end,
    io={open=fileOpen,stderr=io.stderr,read=function()error('service attempted terminal input')end,write=function()error('service wrote over prompt')end}}, {__index=_G})
local commands={'start N1','arm N1','ping N1','stop N1','quit','disarm N1','maintenance N1 on','info N1','restart N1','status N1','launch N1 10 20','confirm LAUNCH','nodes','status N1','status N1'}
local index=0
local options={appDir='.',ready=function()ready=true end,log=function()end,
    stopping=function()return index>=#commands and clock>30 end,
    nextCommand=function()
        if clock<1 or (index>=#commands) then return end
        index=index+1
        if index==1 then userStatusStarted=clock end
        if index>=14 then intelMode=index-13 end
        return {id=index,line=commands[index]}
    end,
    reply=function(id,ok,text)replies[id]={ok=ok,text=text,at=clock}end}
assert(nativeLoadfile('central/central.lua','t',env))(options)
assert(ready,'did not report ready')
assert(replies[1].ok and replies[1].text:find('CONFIRMED',1,true),replies[1].text)
assert(replies[1].at-userStatusStarted>=2,'accepted wrong replyTo or incidental telemetry')
assert(not replies[1].text:find('WRONG REQUEST',1,true),'captured unrelated ACK')
assert(not replies[2].ok and replies[2].text:find('REJECTED',1,true),replies[2].text)
assert(not replies[3].ok and replies[3].text:find('UNCONFIRMED',1,true) and replies[3].text:find('upgrade',1,true),replies[3].text)
assert(not replies[4].ok and replies[4].text:find('TIMEOUT',1,true),replies[4].text)
assert(replies[5].text:find('service remains active',1,true),'quit stopped service')
for _,id in ipairs({6,7,8,9,12}) do assert(replies[id].ok and replies[id].text:find('CONFIRMED',1,true),replies[id].text) end
assert(replies[8].text:find('runtimeVersion',1,true),'INFO missing readable content')
assert(replies[13],'commands after quit were not processed')
local iffAt = assert(replies[12].text:find('[IFF] Registered friendly',1,true),replies[12].text)
assert(iffAt < assert(replies[12].text:find('CONFIRMED',1,true)),'IFF registered after launch completion')
assert(replies[14].text:find('COMBINED_INTEL',1,true) and replies[14].text:find('50% coverage',1,true),replies[14].text)
assert(replies[15].text:find('Satellite link disconnected',1,true) and not replies[15].text:find('Missile:',1,true),replies[15].text)
local launched=0
for _,e in ipairs(traffic) do if e.payload[1]=='LAUNCH' then launched=launched+1 end end
assert(launched==1,'launch replayed')
assert(closed==2 and listener==nil and next(timers)==nil,'service resources leaked')
print('PASS command correlation, incidental filtering, rejection, legacy unconfirmed, timeout, detach and launch result')

-- Run the real bootstrap too: replies are scoped to a command, never its next tick.
local function runNode(crash)
    files={['/home/stratcom/config.lua']='return {id="N1",role="strike"}',
        ['/home/stratcom/runtime/version.txt']='3.0.0',
        ['/home/stratcom/runtime/current.lua']=[[
local ctx
return {start=function(context) ctx=context end,
onMessage=function(remote,command) ctx.send(remote,"ACK",command,false,"NO_PAYLOAD") end,
tick=function() if crash then error("LATE_TICK_FAILURE") end ctx.send("CENTRAL","RADAR_TRACK","periodic") end,
stop=function() stoppedRuntime=true end}
]]}
    local nodeTraffic, pulls, portsClosed, uptime = {}, 0, 0, 0
    local nodeModules={filesystem=fs,serialization={serialize=serialize,unserialize=unserialize},
        computer={uptime=function() return uptime end},keyboard={keys={c=46},isControlDown=function()return false end}}
    local nodeModem={open=function()end,close=function()portsClosed=portsClosed+1 end,
        broadcast=function(_,_,encoded)nodeTraffic[#nodeTraffic+1]=unserialize(encoded);return true end}
    nodeModules.component={list=function()return function()return 'modem' end end,proxy=function()return nodeModem end}
    nodeModules.event={pull=function()
        pulls=pulls+1;uptime=uptime+3
        if pulls>2 then return end
        local command=pulls==1 and 'CLAIM' or 'ARM'
        local message={protocol=2,id='request-'..pulls,source='CENTRAL',destination='N1',ttl=6,
            kind=pulls==1 and 'MGMT' or 'CMD',payload={command}}
        return 'modem_message',nil,nil,pulls==1 and 4510 or 4511,nil,'STRATCOM_NET',serialize(message)
    end}
    local nodeEnv=setmetatable({crash=crash,require=function(name)return assert(nodeModules[name],name)end,
        io={open=fileOpen,stderr=io.stderr},print=function()error('bootstrap wrote over prompt')end}, {__index=_G})
    nodeEnv.loadfile=function(path)return load(assert(files[path],path),path,'t',nodeEnv)end
    nodeEnv.dofile=function(path)return assert(nodeEnv.loadfile(path))()end
    local ok,err=pcall(assert(nativeLoadfile('bootstrap/bootstrap.lua','t',nodeEnv)),
        {log=function()end,stopping=function()return pulls>=4 end})
    assert(portsClosed==2 and nodeEnv.stoppedRuntime,'node resources leaked')
    if crash then
        assert(not ok and tostring(err):find('LATE_TICK_FAILURE',1,true),'tick failure did not reach supervisor')
    else
        assert(ok,err)
        local ack,periodic,heartbeat=false,false,false
        for _,e in ipairs(nodeTraffic)do
            if e.kind=='MGMT_ACK' then assert(e.replyTo=='request-1') end
            if e.kind=='RUNTIME' and e.payload[1]=='ACK' then assert(e.replyTo=='request-2');ack=true end
            if e.kind=='RUNTIME' and e.payload[1]=='RADAR_TRACK' then assert(e.replyTo==nil);periodic=true end
            if e.kind=='BOOT_HEARTBEAT' then assert(e.replyTo==nil);heartbeat=true end
        end
        assert(ack and periodic and heartbeat,'missing expected node events')
    end
end
runNode(false)
runNode(true)
print('PASS bootstrap reply ID scoping, periodic telemetry isolation and crash cleanup')
