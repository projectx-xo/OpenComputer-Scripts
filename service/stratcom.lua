local thread = require('thread')
local event = require('event')
local computer = require('computer')
local update = require('stratcom.update')
local M = {}
local root = '/home/stratcom'
local supervisor, worker, updater
local state, failures, stopRequested, restartRequested = 'stopped', 0, false, false
local readyAt, busy, candidate, updateState = nil, false, nil, 'idle'
local logs, queue, replies, sequence = {}, {}, {}, 0
local activeCommand, lastCommand = nil, 0
local function now() return computer.uptime() end
local function log(s)
    logs[#logs+1]=string.format('[%.1f] %s',now(),tostring(s))
    if #logs>200 then table.remove(logs,1) end
end
local function config()
    local f,e=loadfile(root..'/service-config.lua'); assert(f,e)
    local c=f();assert(type(c)=='table' and (c.kind=='central' or c.kind=='node'),'invalid service config');return c
end
function M.status() return {state=state,version=update.current(),failures=failures,busy=busy,update=updateState,candidate=candidate} end
function M.logs(count)
    local result={};count=math.max(1,math.min(200,tonumber(count) or 30))
    for i=math.max(1,#logs-count+1),#logs do result[#result+1]=logs[i] end
    return table.concat(result,'\n')
end
local function endCommands(reason)
    for id,r in pairs(replies) do if not r.done then replies[id]={done=true,ok=false,text=reason,time=now()} end end
    queue={}
    activeCommand=nil
end
local function haltWorker()
    stopRequested=true
    if worker then
        local deadline=now()+3
        while worker:status()~='dead' and now()<deadline do event.pull(0.1) end
        worker:kill(); worker=nil
    end
    endCommands('application stopped; command was not replayed')
    busy=false
end
local function checkUpdate()
    if updater and updater:status()~='dead' then return nil,'update already in progress' end
    updateState='checking'
    updater=thread.create(function()
        local v,e=update.stage(nil,function(s)updateState=s end)
        if not v then updateState='error: '..tostring(e);log(updateState)
        elseif v==update.current() then updateState='up to date'
        elseif v==update.read(root..'/rejected.txt') then updateState='rejected '..v..'; use update apply to retry'
        else candidate=v;updateState='downloaded '..v..'; waiting for idle' end
    end)
    -- Created from console commands as well as supervisor; survive console exit.
    updater:detach()
    return true,'update check started'
end
local function run()
    local c=config()
    local nextCheck=0
    while not stopRequested do
        state='starting';readyAt=nil;busy=false
        local started=now();local finished=false;local errorText
        local dir=update.directory(assert(update.current(),'no installed bundle'))
        worker=thread.create(function()
            local ok,e=pcall(function()
                local chunk=assert(loadfile(dir..(c.kind=='central' and '/central/central.lua' or '/bootstrap/bootstrap.lua')))
                chunk({appDir=dir,log=log,ready=function()readyAt=now();state='running' end,
                    stopping=function()return stopRequested or restartRequested end,
                    setBusy=function(value)busy=not not value end,
                    nextCommand=function()local request=table.remove(queue,1);if request then activeCommand=request.id end;return request end,
                    reply=function(id,ok,text)if activeCommand==id then activeCommand=nil;lastCommand=now() end;if replies[id] then replies[id]={done=true,ok=not not ok,text=tostring(text or ''),time=now()} end end})
            end)
            finished=true;errorText=ok and 'application exited' or tostring(e)
        end)
        while not stopRequested and not restartRequested do
            if finished or worker:status()=='dead' then break end
            if not readyAt and now()-started>20 then errorText='startup health timeout';break end
            if readyAt then
                if update.pending() and now()-readyAt>=15 then
                    local ok,e=update.confirm();if not ok then error(e)end;log('activation healthy')
                end
                if now()-readyAt>=60 then failures=0 end
                if c.autoUpdate~=false and now()>=nextCheck and not candidate and
                    (not updater or updater:status()=='dead') then
                    nextCheck=now()+3600
                    checkUpdate()
                end
                if candidate and not busy and not activeCommand and #queue==0 and now()-lastCommand>=1 and not update.pending() then restartRequested=true;break end
            end
            for id,r in pairs(replies) do if now()-r.time>120 then replies[id]=nil end end
            event.pull(0.1)
        end
        local explicitStop=stopRequested
        local restarting=restartRequested
        haltWorker()
        if explicitStop then break end
        stopRequested=false;restartRequested=false
        if restarting then
            if candidate then
                local ok,e=update.activate(candidate)
                if ok then log('activating '..candidate);candidate=nil;updateState='startup probation; stable helpers require reinstall when changed'
                else updateState='activation failed: '..tostring(e);candidate=nil;log(updateState) end
            end
        else
            failures=failures+1;log(errorText or 'application stopped')
            if update.pending() then
                local ok,e=update.recover();assert(ok,e);log('candidate rejected; restored previous bundle')
            end
            if failures>=5 then state='failed';log('restart limit reached; use service start');return end
            state='backoff'
            local deadline=now()+math.min(30,2^(failures-1))
            while not stopRequested and now()<deadline do event.pull(0.1) end
        end
    end
    state='stopped'
end
function M.start()
    if supervisor and supervisor:status()~='dead' then return true,'service '..state end
    local ok,e=pcall(function()config();assert(update.recover());assert(update.current(),'no installed bundle')end)
    if not ok then return nil,tostring(e) end
    stopRequested=false;restartRequested=false;failures=0;state='starting'
    supervisor=thread.create(function()
        local success,reason=pcall(run)
        if not success then haltWorker();state='failed';log(reason) end
    end)
    supervisor:detach()
    return true,'service starting'
end
function M.stop()
    stopRequested=true
    if updater then updater:kill();updater=nil end
    candidate=nil
    if not supervisor or supervisor:status()=='dead' then state='stopped' end
    return true,'stop requested'
end
function M.restart()
    if not supervisor or supervisor:status()=='dead' then return M.start() end
    restartRequested=true;return true,'restart requested'
end
function M.submit(line)
    if state~='running' then return nil,'service '..state end
    local n=0;for _ in pairs(replies)do n=n+1 end
    if #queue>=16 or n>=64 then return nil,'command queue full' end
    sequence=sequence+1;replies[sequence]={time=now()};queue[#queue+1]={id=sequence,line=line};return sequence
end
function M.result(id)
    local r=replies[id]
    if r and r.done then replies[id]=nil;return r end
end
function M.doctor()
    local lines={'service: '..state,'bundle: '..tostring(update.current()),'config: '..tostring(update.read(root..'/config.lua')~=nil),
        'runtime: '..tostring(update.read(root..'/runtime/version.txt') or 'none'),'update: '..updateState}
    local rc={};local chunk=loadfile('/etc/rc.cfg','t',rc);local enabled=false
    if chunk and pcall(chunk) then for _,n in ipairs(rc.enabled or {})do if n=='stratcom' then enabled=true end end end
    lines[#lines+1]='boot enabled: '..tostring(enabled)
    local found,component=pcall(require,'component')
    if found then for address,kind in component.list()do lines[#lines+1]=kind..': '..address end end
    return table.concat(lines,'\n')
end
function M.apply(version)
    if not update.read(update.directory(version)..'/release.lua') then return nil,'bundle incomplete' end
    if update.pending() then return nil,'activation pending' end
    candidate=version
    return true,'activation queued; waiting for idle'
end
function M.command(line)
    local action=line:match('^service%s+(%w+)%s*$')
    if action then
        if action=='status' then return true,state..' '..tostring(update.current()) end
        if action=='start' then return M.start() end
        if action=='stop' then return M.stop() end
        if action=='restart' then return M.restart() end
        return nil,'unknown service action'
    end
    if line=='doctor' then return true,M.doctor() end
    if line=='logs' or line:match('^logs%s+%d+$') then return true,M.logs(line:match('%d+')) end
    action=line:match('^update%s+(%w+)%s*$')
    if action then
        if action=='status' then return true,updateState end
        if action=='check' then return checkUpdate() end
        if action=='rollback' then
            if busy then return nil,'application busy' end
            if update.pending() then return nil,'activation pending' end
            local previous=update.previous();if not previous then return nil,'no previous bundle' end
            return M.apply(previous)
        end
        if action=='apply' then
            candidate=candidate or update.read(root..'/rejected.txt')
            if not candidate then return nil,'no downloaded candidate; use update check' end
            return M.apply(candidate)
        end
        return nil,'unknown update action'
    end
    return nil,nil
end
return M
