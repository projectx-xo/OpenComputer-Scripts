local function read(path) local f=assert(io.open(path));local s=f:read('*a');f:close();return s end
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local source=read('central/central.lua')
local prefix=source:sub(1,assert(source:find('local VERSION =',1,true))-1)
local makePrint=assert(load(prefix..'\nreturn function(o,out) options=o;commandOutput=out;return print end','central output','t',
    setmetatable({require=function()return {}end},{__index=_G})))()
local alerts,logs,out={},{},{}
local output=makePrint({alert=function(s)alerts[#alerts+1]=s end,log=function(s)logs[#logs+1]=s end},out)
output('[DEFENSE] ABM-A1 engaging RADAR-1:7 target X=50 Z=100')
eq(#alerts,1);eq(#logs,1);eq(#out,1)
output('[RADAR] RADAR-1 TRACK #7 ACQUIRED TIER3 @ 50,100,50')
output('[RADAR] POSSIBLE LAUNCH SITE #2 @ X=50 Z=100 confidence=HIGH launches=2')
output('[DEFENSE] ABM fired for RADAR-1:7')
output('[DEFENSE] UNCONFIRMED RADAR-1:7 CONTACT_LOST_AFTER_ENGAGEMENT')
eq(#alerts,5)
output('[MGMT] Node online');output('[RADAR] RADAR-1 TRACK #8 ACQUIRED PLAYER @ 1,2,3')
eq(#alerts,5)
local fallback={}
local failingOutput=makePrint({alert=function()error('display unavailable')end,log=function(s)fallback[#fallback+1]=s end},nil)
failingOutput('[DEFENSE] ABM fired');eq(#fallback,1)
print('PASS operational alerts bypass pending command output; routine messages stay quiet; display failure cannot abort defense')

-- Exercise the actual console with OpenOS-compatible editable cursor methods.
local pending,serial,results={},0,{}
local submitted,printed,echoed,beeps={}, {}, {},0
local function publish(s) serial=serial+1;pending[#pending+1]={id=serial,text=s} end
local svc={start=function()return true end,status=function()return {state='running'}end,
    alerts=function(after)local batch={};for _,a in ipairs(pending)do if a.id>(after or 0) then batch[#batch+1]=a end end;return batch,serial,0 end,
    command=function()return nil,nil end,submit=function(line)submitted[#submitted+1]=line;return #submitted end,
    result=function(id)return results[id]end}
local clock=0
local computer={uptime=function()return clock end,beep=function()beeps=beeps+1 end}
local event={pull=function()clock=clock+.1;publish('[DEFENSE] ABM fired');results[1]={ok=true,text='status complete'};return 'stratcom_alert'end}
local nativeCursor
if os.getenv('OPENOS_LIB') then
    local modules={unicode={len=string.len,wlen=string.len,sub=string.sub},
        keyboard={keys={},isControlDown=function()return false end},tty={window={}},text={},computer={},package={delay=function()end}}
    nativeCursor=assert(loadfile(os.getenv('OPENOS_LIB')..'/core/cursor.lua','t',
        setmetatable({require=function(n)return assert(modules[n],n)end},{__index=_G})))()
end
local reads=0
local term={read=function(history)
    reads=reads+1
    if reads==2 then return 'quit\n' end
    assert(type(history.handle)=='function','console has no live input alert handler')
    local cursor=nativeCursor and nativeCursor.new(history) or history
    cursor.data='status RADAR-1';cursor.len=#cursor.data;cursor.index=6;cursor.hindex=2;cursor.cache={hint='keep'};cursor.clear='<clear>'
    if not nativeCursor then cursor.move=function(self,n)self.index=math.max(0,math.min(self.len,self.index+n))end end
    cursor.echo=function(_,s)echoed[#echoed+1]=s end
    if not nativeCursor then cursor.update=function(self,s,back)
        if not s then self.data='';self.len=0;self.index=0;self.hindex=0;return end
        self.data=self.data..s;self.len=#self.data;self.index=self.len+(back or 0)
    end
    cursor.super={handle=function(_,name)return name~='interrupted'end}
    end
    publish('[RADAR] MISSILE DETECTED')
    assert(cursor:handle('stratcom_alert'))
    eq(cursor.data,'status RADAR-1');eq(cursor.index,6);eq(cursor.hindex,2);eq(cursor.cache.hint,'keep')
    local before=#echoed;assert(cursor:handle('stratcom_alert'));eq(#echoed,before)
    assert(not cursor:handle('interrupted'),'Ctrl+C was swallowed')
    return cursor.data..'\n'
end}
local mods={['stratcom.service']=svc,event=event,computer=computer,term=term}
local env=setmetatable({require=function(n)return assert(mods[n],n)end,
    print=function(s)printed[#printed+1]=s end,io={write=function()end}},{__index=_G})
assert(load(read('service/console.lua'),'console','t',env))()
eq(submitted[1],'status RADAR-1');eq(#submitted,1)
assert(table.concat(echoed):find('MISSILE DETECTED',1,true),'alert not rendered during typing')
assert(table.concat(printed,'\n'):find('ABM fired',1,true),'alert not rendered during command wait')
eq(beeps,2)
print('PASS alerts preserve input, edit position and history; command waits display alerts without replay')
