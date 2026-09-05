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
local ready, closed, stopped, userStatusStarted = false, 0, false, nil
local nativeLoadfile = loadfile
local function packet(kind,payload)
    nextId=nextId+1
    queue[#queue+1]={at=clock,port=kind=='RUNTIME' and 4511 or 4510,envelope={protocol=2,id='rx'..nextId,
        source='N1',destination='CENTRAL',ttl=6,kind=kind,payload=payload}}
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
    elseif p[1]=='STOP' then stopped=true;packet('MGMT_ACK',{'STOP',true})
    elseif p[1]=='STATUS' then
        packet('RUNTIME',{'STATUS',serialize({ready=false,missileLabel='WRONG TOKEN'}),'unrelated'})
        packet('RUNTIME',{'STATUS',serialize({ready=true,armed=false,missileLabel='TEST PAYLOAD',missileName='hbm:item.missile_test'}),p[3]})
        queue[#queue].at=clock+2
    elseif p[1]=='SCAN_STATUS' then packet('RUNTIME',{'SCAN_STATUS','COMPLETE | coverage 100%',p[2]}) end
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
    if clock>60 then error('CENTRAL service failed to terminate') end
end
local modules={component={list=function()return function()return 'modem' end end,proxy=function()return modem end},
    event=event,computer={uptime=function()return clock end},term={clear=function()error('service cleared terminal')end},
    filesystem=fs,serialization={serialize=serialize,unserialize=unserialize}}
local env=setmetatable({require=function(name)return assert(modules[name],name)end,
    io={open=fileOpen,stderr=io.stderr,read=function()error('service attempted terminal input')end,write=function()error('service wrote over prompt')end}}, {__index=_G})
local commands={'status N1','stop N1','quit','scan N1 status','nodes'}
local index=0
local options={appDir='.',ready=function()ready=true end,log=function()end,
    stopping=function()return index>=#commands and clock>15 end,
    nextCommand=function()
        if clock<1 or (index>=#commands) then return end
        index=index+1
        if index==1 then userStatusStarted=clock end
        return {id=index,line=commands[index]}
    end,
    reply=function(id,ok,text)replies[id]={ok=ok,text=text,at=clock}end}
assert(nativeLoadfile('central/central.lua','t',env))(options)
assert(ready,'did not report ready')
assert(replies[1].ok and replies[1].text:find('TEST PAYLOAD',1,true),replies[1].text)
assert(replies[1].at-userStatusStarted>=2,'printed before correlated reply arrived')
assert(not replies[1].text:find('WRONG TOKEN',1,true),'accepted unrelated status')
assert(replies[3].text:find('service remains active',1,true),'quit stopped service')
assert(replies[4].text:find('COMPLETE',1,true),'scan reply not returned')
assert(replies[5],'commands after quit were not processed')
assert(stopped,'STOP not transmitted')
local prefs=unserialize(assert(files['/home/stratcom/preferences.db']))
assert(prefs.nodes.N1.desiredState=='stopped','operator intent not persisted')
for _,e in ipairs(traffic)do assert(e.payload[1]~='START','reconciliation undid STOP')end
assert(closed==2 and listener==nil and next(timers)==nil,'service resources leaked')
print('PASS full CENTRAL offline startup, correlated replies, persisted STOP, console detach, scan reply and cleanup')
