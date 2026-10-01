-- Application updates only. The stable supervisor retains activation/rollback ownership.
return function(ctx)
    local job,active,nextPoll,started=nil,nil,0,ctx.now()
    local resumeCheck=false
    local ok,saved=pcall(ctx.load)
    if ok and type(saved)=='table' and saved.schema==1 and type(saved.nodes)=='table'
        and type(saved.id)=='string' and #saved.id<=100 and type(saved.base)=='string' and #saved.base<=80
        and (saved.error==nil or (type(saved.error)=='string' and #saved.error<=512))
        and (saved.phase=='central' or saved.phase=='nodes' or saved.phase=='done')
        and (saved.phase~='nodes' or type(saved.target)=='string') then
        local valid,count=true,0
        for id,n in pairs(saved.nodes) do
            count=count+1
            if count>128 or type(id)~='string' or #id>64 or not id:match('^[%w_%-]+$')
                or type(n)~='table' or not ({queued=true,updating=true,updated=true,['needs attention']=true,['waiting for auto-update']=true})[n.state]
                or (n.detail~=nil and (type(n.detail)~='string' or #n.detail>512)) then valid=false;break end
        end
        if valid then job=saved;resumeCheck=job.phase=='central' end
    end
    local function save()
        local success,err=ctx.save(job)
        if not success then ctx.log('[UPDATE] Progress save failed: '..tostring(err));return false end
        return true
    end
    local function finishNode(id,state,detail)
        local n=job.nodes[id];n.state=state;n.detail=detail
        ctx.log('[UPDATE] '..id..': '..state..(detail and ' — '..detail or ''))
        active=nil;save()
    end
    local function capable(node)
        local a,b=tostring(node.bootstrapVersion):match('^(%d+)%.(%d+)')
        return a and (tonumber(a)>3 or (tonumber(a)==3 and tonumber(b)>=4))
    end
    local api={}
    function api.start()
        if job and job.phase~='done' then return false,'Upgrade already running; use upgrade status.' end
        local previous=job
        job={schema=1,id=ctx.token(),phase='central',base=ctx.current(),nodes={}}
        local count=0
        for id in pairs(ctx.nodes()) do
            count=count+1;if count>128 then job=previous;return false,'Too many nodes for one upgrade.' end
            job.nodes[id]={state='queued'}
        end
        if not save() then job=previous;return false,'Could not save upgrade request; nothing started.' end
        local checked,reason=ctx.check()
        if not checked then job.phase='done';job.error=reason;save();return false,reason end
        started=ctx.now();nextPoll=0
        return true,'Updating CENTRAL, then nodes. Use upgrade status; the request survives CENTRAL restarting.'
    end
    function api.status()
        if not job then return 'No fleet upgrade requested.' end
        local rows={'Upgrade: '..job.phase..' | target '..tostring(job.target or 'checking CENTRAL')}
        if job.error then rows[#rows+1]=job.error end
        local ids={};for id in pairs(job.nodes) do ids[#ids+1]=id end;table.sort(ids)
        for _,id in ipairs(ids) do local n=job.nodes[id];rows[#rows+1]=id..': '..n.state..(n.detail and ' — '..n.detail or '') end
        return table.concat(rows,'\n')
    end
    function api.tick()
        if not job or job.phase=='done' or ctx.now()<nextPoll then return end
        nextPoll=ctx.now()+2
        if job.phase=='central' then
            local s=ctx.serviceStatus()
            if ctx.pending() then return end
            if resumeCheck and ctx.current()==job.base and s.update=='idle' then
                resumeCheck=false;ctx.check();return
            end
            if ctx.current()~=job.base or s.update=='up to date' then
                job.target=ctx.current();job.phase='nodes'
                if not save() then job.phase='central';return end
                ctx.sync();ctx.log('[UPDATE] CENTRAL healthy at '..job.target..'; updating nodes.')
                started=ctx.now()
            elseif tostring(s.update):match('^error:') or tostring(s.update):match('^rejected ') then
                job.error=tostring(s.update);job.phase='done';save();ctx.log('[UPDATE] CENTRAL '..job.error)
            elseif ctx.now()-started>600 then
                job.error='CENTRAL still busy/checking; no forced restart. Run upgrade again when ready.';job.phase='done';save();ctx.log('[UPDATE] '..job.error)
            end
            return
        end
        if active then
            local node=ctx.nodes()[active.id]
            if ctx.now()>=active.deadline then finishNode(active.id,'needs attention','Timed out; no forced restart. Inspect node update status.');return end
            if node and ctx.online(node) and node.claimed then
                if ctx.now()>=active.nextSend then
                    if not active.acknowledged then
                        if active.attempts>=3 then finishNode(active.id,'needs attention','No update acknowledgment.');return end
                        active.attempts=active.attempts+1
                        ctx.send(node,'UPDATE_CHECK',active.token,job.target)
                    else ctx.send(node,'UPDATE_STATUS',active.token) end
                    active.nextSend=ctx.now()+10
                end
            end
            return
        end
        local ids,waiting={},false
        for id,n in pairs(job.nodes) do
            local node=ctx.nodes()[id]
            if n.state=='queued' or n.state=='updating' or (n.state=='waiting for auto-update' and node and capable(node)) then
                ids[#ids+1]=id
            elseif n.state=='waiting for auto-update' then waiting=true end
        end
        table.sort(ids)
        if #ids==0 then
            if waiting then
                if ctx.now()-started>3900 then
                    for id,n in pairs(job.nodes) do if n.state=='waiting for auto-update' then
                        finishNode(id,'needs attention','Automatic update did not arrive; run update check on this node once. No reinstall required.')
                    end end
                end
                return
            end
            job.phase='done';save();ctx.log('[UPDATE] Fleet pass finished. Use upgrade status for results.');return
        end
        local id=ids[1];local node=ctx.nodes()[id]
        if not node or not ctx.online(node) or not node.claimed then
            if ctx.now()-started<30 then return end
            finishNode(id,'needs attention','Offline or unclaimed; retry upgrade when connected.');return
        end
        if not capable(node) then
            finishNode(id,'waiting for auto-update','Older bootstrap; waiting for its hourly update. Optional shortcut: update check on this node.');return
        end
        job.nodes[id].state='updating'
        if not save() then job.nodes[id].state='queued';return end
        active={id=id,token=ctx.token(),deadline=ctx.now()+600,nextSend=0,attempts=0}
    end
    function api.receive(node,p)
        if not active or not node.claimed or node.id~=active.id or p[1]~=active.token or type(p[2])~='string' or #p[2]>2048 then return end
        local parsed,s=pcall(ctx.decode,p[2])
        if not parsed or type(s)~='table' or s.session~=node.session or type(s.version)~='string'
            or type(s.pending)~='boolean' or type(s.update)~='string' or type(s.ok)~='boolean' then return end
        active.acknowledged=true
        if not s.ok then finishNode(node.id,'needs attention',tostring(s.error or s.update):sub(1,160));return end
        if s.version==job.target and not s.pending then
            if ctx.runtimeCurrent(node) then finishNode(node.id,'updated',s.version)
            else
                ctx.reconcile(node)
                job.nodes[node.id].detail='Bundle ready; waiting for runtime deployment or idle state.'
            end
        elseif s.update:match('^error:') or s.update:match('^rejected ') then
            finishNode(node.id,'needs attention',s.update:sub(1,160))
        elseif s.update=='up to date' and not s.pending then
            finishNode(node.id,'needs attention','Source/version mismatch: node '..s.version..', CENTRAL '..job.target)
        else job.nodes[node.id].detail=s.update:sub(1,160) end
    end
    return api
end
