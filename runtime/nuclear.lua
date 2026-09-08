local component=require('component')
local event=require('event')
local serialization=require('serialization')
local runtime={}
local context,timer,pending,station,lastError
local function number(value)
    local n=tonumber(value)
    assert(n and n==n and math.abs(n)<1e15,'INVALID_NUMBER')
    return n
end
local function poll()
    if pending then context.send('CENTRAL','NUCLEAR_EVENTS',pending.data,pending.token);return end
    local addresses={};for a in component.list('ntm_satlink')do addresses[#addresses+1]=a end;table.sort(addresses)
    station=nil
    for _,a in ipairs(addresses)do
        local ok,t=pcall(component.invoke,a,'getType')
        if ok and t=='NUCLEAR_DETECTION' then station=a;break end
    end
    if not station then lastError='NUCLEAR_SATELLITE_REQUIRED';return end
    local saved=context.config.nuclearCursor or {}
    local ok,epoch,cursor,rows,lost=component.invoke(station,'nuclearEvents',saved.epoch or '',saved.cursor or 0)
    assert(ok,tostring(epoch));assert(type(epoch)=='string' and #epoch<=64,'INVALID_EPOCH')
    cursor=number(cursor);assert(cursor>=0 and cursor%1==0,'INVALID_CURSOR')
    assert(type(rows)=='string' and #rows<=4096,'INVALID_EVENTS')
    local events={}
    for row in rows:gmatch('[^|]+')do
        local f={};for v in row:gmatch('[^,]+')do f[#f+1]=v end
        assert(#f==8 and #events<8,'INVALID_EVENT')
        assert(f[2]=='MISSILE' or f[2]=='EXPLOSION','INVALID_KIND')
        assert(f[3]=='NUCLEAR' or f[3]=='THERMONUCLEAR','INVALID_PAYLOAD')
        events[#events+1]={id=epoch..':'..f[1],kind=f[2],payload=f[3],x=number(f[4]),
            y=f[5]~='?' and number(f[5]) or nil,z=number(f[6]),dimension=number(f[7]),tick=number(f[8])}
    end
    lastError=nil
    if #events>0 or saved.epoch~=epoch or saved.cursor~=cursor then
        local token=context.session..':'..epoch..':'..cursor
        pending={token=token,epoch=epoch,cursor=cursor,data=serialization.serialize({session=context.session,events=events,lost=number(lost)})}
        context.send('CENTRAL','NUCLEAR_EVENTS',pending.data,token)
    end
end
local function tick()
    local ok,err=pcall(poll);if not ok then lastError=tostring(err) end
end
function runtime.start(ctx)
    context=ctx;context.config=context.config or {};pending=nil
    tick();timer=event.timer(2,tick,math.huge)
end
function runtime.stop()if timer then event.cancel(timer);timer=nil end end
function runtime.status()
    return {nuclearDetection=true,satelliteType='NUCLEAR_DETECTION',satelliteAddress=station,
        ready=station~=nil and lastError==nil,error=lastError,pending=pending~=nil}
end
function runtime.onMessage(remote,command,arg1,arg2)
    if command=='NUCLEAR_ACK' and pending and arg1==pending.token then
        local old=context.config.nuclearCursor
        context.config.nuclearCursor={epoch=pending.epoch,cursor=pending.cursor}
        local ok,err=context.saveConfig(context.config)
        if ok then pending=nil else context.config.nuclearCursor=old;lastError=tostring(err) end
    elseif command=='STATUS' then context.send(remote,'STATUS',serialization.serialize(runtime.status()))
    elseif command=='PING' then context.send(remote,'PONG','nuclear') end
end
return runtime
