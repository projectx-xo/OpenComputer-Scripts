-- Production CENTRAL and strike runtime connected through a simulated modem.
local function serialize(v)
    if type(v)=='table' then local out={};for k,x in pairs(v)do out[#out+1]='['..serialize(k)..']='..serialize(x)end;return '{'..table.concat(out,',')..'}'end
    return type(v)=='string' and string.format('%q',v) or tostring(v)
end
local function unserialize(s)return assert(load('return '..s,'data','t',{}))()end
local clock,id,listener=0,0,nil
local timers,queue,replies,fired,logs,files={},{},{},{},{},{}
files['/home/stratcom/launchsites.db']=serialize({sites={[7]={id=7,x=507.2,y=5,z=1709.2,confidence='MEDIUM'}},nextId=8})
files['/home/stratcom/payloads.db']=serialize({['hbm:item.missile_test']={class='nuclear'}})
files['/home/stratcom/preferences.db']=serialize({defense={protectX=0,protectZ=0,radius=100}})
local function packet(kind,payload,replyTo)
    id=id+1;queue[#queue+1]={protocol=2,id='node-'..id,source='SILO-S2',destination='CENTRAL',ttl=6,kind=kind,payload=payload,replyTo=replyTo}
end
local pads,loaded={},{}
for i=1,4 do
    local n=i;loaded[n]=true
    pads['p'..n]={getEnergyInfo=function()return 10,10 end,getFluid=function()return 0,0,'',0,0,'' end,
        getTier=function()return 20 end,canLaunch=function()return loaded[n]end,
        launch=function(x,z)fired[#fired+1]={index=n,at=clock,x=x,z=z};loaded[n]=false;return true end}
end
local inventory={getInventorySize=function()return 1 end,getStackInSlot=function(side)
    if loaded[side] then return {name='hbm:item.missile_test',size=1}end
end}
local nodeComponent={list=function(kind)local a=kind=='ntm_launch_pad' and {'p1','p2','p3','p4'} or kind=='inventory_controller' and {'i'} or {};local n=0;return function()n=n+1;return a[n]end end,
    proxy=function(a)return pads[a] or inventory end}
local modules={serialization={serialize=serialize,unserialize=unserialize},computer={uptime=function()return clock end}}
local runtime=assert(loadfile('runtime/strike.lua','t',setmetatable({require=function(n)return n=='component' and nodeComponent or assert(modules[n])end},{__index=_G})))()
local replyTo
local config={launchers={}}
for i=1,4 do config.launchers[i]={padAddress='p'..i,inventoryAddress='i',side=i}end
runtime.start({id='SILO-S2',role='strike',config=config,send=function(_,kind,...)packet('RUNTIME',{kind,...},replyTo)end})
local modem={open=function()end,close=function()end,broadcast=function(_,_,encoded)
    local e=unserialize(encoded);local p=e.payload
    if p[1]=='DISCOVER' then packet('BOOT_HELLO',{'SILO-S2','strike','3.0.0','3.1.0','running','running','boot-A'})
    elseif p[1]=='CLAIM' then packet('MGMT_ACK',{'CLAIM',true},e.id)
    elseif p[1]=='STATUS' then packet('RUNTIME',{'STATUS',serialize(runtime.status()),p[3]},e.id)
    elseif e.kind=='CMD' then replyTo=e.id;runtime.onMessage('CENTRAL',table.unpack(p));replyTo=nil end
    return true
end}
modules.component={list=function(kind)local first=true;return function()if first and kind=='modem' then first=false;return 'modem'end end end,proxy=function()return modem end}
modules.filesystem={exists=function(p)return files[p]~=nil end,makeDirectory=function()return true end,
    remove=function(p)files[p]=nil;return true end,rename=function(a,b)files[b]=files[a];files[a]=nil;return true end}
modules.term={clear=function()end}
modules.event={listen=function(_,fn)listener=fn end,ignore=function()listener=nil end,
    timer=function(interval,fn,times)id=id+1;timers[id]={at=clock+interval,interval=interval,fn=fn,left=times};return id end,
    cancel=function(n)timers[n]=nil end}
function modules.event.pull(timeout)
    clock=clock+(tonumber(timeout) or .1)
    runtime.tick()
    for n,t in pairs(timers)do if clock>=t.at then t.at=clock+t.interval;t.left=t.left-1;t.fn();if t.left<=0 then timers[n]=nil end end end
    local delivered=queue;queue={}
    for _,e in ipairs(delivered)do if listener then listener('modem_message',nil,nil,e.kind=='RUNTIME' and 4511 or 4510,nil,'STRATCOM_NET',serialize(e))end end
    assert(clock<100,'CENTRAL did not terminate')
end
local function fileOpen(p,mode)
    if mode=='r' and files[p]==nil then return nil end;if mode=='w' then files[p]=''end
    return {read=function()return files[p]end,write=function(_,s)files[p]=files[p]..s;return true end,flush=function()return true end,close=function()end}
end
local env=setmetatable({require=function(n)return assert(modules[n],n)end,io={open=fileOpen,stderr=io.stderr,write=function()end}},{__index=_G})
local commands={'counterstrike nuclear 4 7 SILO-S2 3','confirm STRIKE','status SILO-S2'}
local n=0
assert(loadfile('central/central.lua','t',env))({appDir='.',ready=function()end,
    stopping=function()return clock>22 end,log=function(s)logs[#logs+1]=s end,
    nextCommand=function()
        if clock<2 or n>=#commands then return end
        if n==1 then assert(#fired==0,'counterstrike fired before confirmation')end
        n=n+1;return {id=n,line=commands[n]}
    end,reply=function(i,ok,s)replies[i]={ok=ok,text=s,at=clock}end})
assert(replies[1].ok and replies[1].text:find('X=507 Z=1709',1,true) and replies[1].text:find('confirm STRIKE',1,true),replies[1].text)
assert(replies[2].ok and replies[2].text:find('Queued 4 launches',1,true),replies[2].text)
assert(replies[3].ok and replies[3].at<fired[4].at,'status waited for the whole salvo')
assert(#fired==4,'incorrect launch count')
for i,f in ipairs(fired)do
    assert(f.x==507 and f.z==1709,'launch lost the detected coordinates')
    if i>1 then assert(f.at-fired[i-1].at>=3,'salvo interval shortened')end
end
assert(table.concat(logs,'\n'):find('4/4',1,true),'completion progress missing')
assert(not runtime.busy() and next(timers)==nil,'queue or timers leaked')
print('PASS CENTRAL counterstrike -> explicit confirmation -> four paced runtime launches with responsive status')
