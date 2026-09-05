-- Execute CENTRAL itself: completion arrives over the modem, never through a local relay.
local function serialize(v)
    if type(v)=='table' then local out={};for k,item in pairs(v)do out[#out+1]='['..serialize(k)..']='..serialize(item)end;return '{'..table.concat(out,',')..'}' end
    return type(v)=='string' and string.format('%q',v) or tostring(v)
end
local function unserialize(s)return assert(load('return '..s,'data','t',{}))()end
local clock, timers, queue, files, replies, id = 0, {}, {}, {}, {}, 0
local listener, cleared, drawn, queried = nil, 0, 0, 0
local function packet(kind,payload,replyTo)
    id=id+1;queue[#queue+1]={protocol=2,id='intel-'..id,source='INTEL-1',destination='CENTRAL',ttl=6,
        kind=kind,payload=payload,replyTo=replyTo}
end
local modem={open=function()end,close=function()end,broadcast=function(port,marker,encoded)
    local e=unserialize(encoded);local p=e.payload
    if p[1]=='DISCOVER' then packet('BOOT_HELLO',{'INTEL-1','intel','3.0.0','1.2.0','running','running','boot-A'})
    elseif p[1]=='CLAIM' then packet('MGMT_ACK',{'CLAIM',true},e.id)
    elseif p[1]=='STATUS' then
        packet('RUNTIME',{'STATUS',serialize({intelligence=true,ready=true,satelliteType='COMBINED_INTEL',scanState='COMPLETE',
            scanFrame={id='boot-A:1',session='boot-A',sequence=1,modelVersion=2,summary='COMBINED;10;20;100%'}}),p[3]})
    elseif p[1]=='SCAN_MODEL' then
        queried=queried+1
        local pages={['structure:1']='10,40,20,1|12,42,22,2',
            ['findings:1']='10,40,20,10,40,20,1,MISSILE,100,1|10,40,20,10,40,20,2,LAUNCH_INFRASTRUCTURE,100,1'}
        packet('RUNTIME',{'SCAN_MODEL',p[2],p[3],p[4],assert(pages[p[3]],'wrong model section'),true})
    end
    return true
end}
local holo={maxDepth=function()return 2 end,setPaletteColor=function()end,
    clear=function()cleared=cleared+1 end,set=function()drawn=drawn+1 end}
local component={list=function(kind)local first=true;return function()
    if not first then return end;first=false
    if kind=='modem' then return 'modem' elseif kind=='hologram' then return 'projector' end
end end,proxy=function(address)return address=='modem' and modem or assert(address=='projector') and holo end}
local fs={exists=function(path)return files[path]~=nil end,makeDirectory=function()return true end,
    remove=function(path)files[path]=nil;return true end,rename=function(a,b)files[b]=files[a];files[a]=nil;return true end}
local function fileOpen(path,mode)
    if mode=='r' and files[path]==nil then return nil end;if mode=='w' then files[path]='' end
    return {read=function()return files[path]end,write=function(_,s)files[path]=files[path]..s;return true end,flush=function()return true end,close=function()end}
end
local event={listen=function(_,fn)listener=fn end,ignore=function()listener=nil end,
    timer=function(interval,fn,times)id=id+1;timers[id]={at=clock+interval,interval=interval,fn=fn,left=times};return id end,
    cancel=function(timer)timers[timer]=nil end}
function event.pull(timeout)
    clock=clock+(tonumber(timeout) or .1)
    for key,t in pairs(timers)do if clock>=t.at then t.at=clock+t.interval;t.left=t.left-1;t.fn();if t.left<=0 then timers[key]=nil end end end
    local delivered=queue;queue={}
    for _,e in ipairs(delivered)do if listener then listener('modem_message',nil,nil,e.kind=='RUNTIME' and 4511 or 4510,nil,'STRATCOM_NET',serialize(e)) end end
    if clock>100 then error('CENTRAL failed to stop')end
end
local modules={component=component,event=event,computer={uptime=function()return clock end},filesystem=fs,
    term={clear=function()end},serialization={serialize=serialize,unserialize=unserialize}}
local env=setmetatable({require=function(name)return assert(modules[name],name)end,
    io={open=fileOpen,stderr=io.stderr,read=function()error('foreground input')end,write=function()end}},{__index=_G})
local commands={'hologram status','hologram list','hologram select 2','hologram status','hologram clear'}
local commandIndex=0
assert(loadfile('central/central.lua','t',env))({appDir='.',ready=function()end,log=function()end,
    stopping=function()return clock>24 end,
    nextCommand=function()
        if clock<12+commandIndex*2 or commandIndex>=#commands then return end
        commandIndex=commandIndex+1;return {id=commandIndex,line=commands[commandIndex]}
    end,reply=function(i,ok,text)replies[i]={ok,text}end})
assert(queried==2,'CENTRAL did not request both model sections over the mesh')
assert(drawn>2,'CENTRAL did not render finding symbols')
assert(replies[1][2]:find('DISPLAYED',1,true) and replies[1][2]:find('2 findings',1,true),replies[1][2])
assert(replies[2][2]:find('#1 MISSILE',1,true) and replies[2][2]:find('#2 LAUNCH_INFRASTRUCTURE',1,true),replies[2][2])
assert(replies[3][1] and replies[3][2]:find('10,40,20',1,true),replies[3][2])
assert(replies[4][2]:find('Selected #2 LAUNCH_INFRASTRUCTURE',1,true),replies[4][2])
assert(replies[5][2]:find('CLEARED',1,true) and cleared==3,'hologram clear command was not routed')
assert(next(timers)==nil,'CENTRAL leaked a timer on shutdown')
print('PASS CENTRAL modem scan completion -> typed findings -> projector -> console selection and clear')
