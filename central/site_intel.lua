-- One bounded, correlated verification scan at a time. No launch commands.
return function(ctx)
    local pending, active = {}, nil
    local function finish(state)
        local job = active
        if not job then return end
        job.site.intelState = state
        job.site.intelCheckedAt = ctx.now()
        if ctx.save() == false then ctx.log('[INTEL] Could not save launch-site verification; result is available in memory only.') end
        ctx.log('[INTEL] Launch site #' .. job.site.id .. ': ' .. state)
        active = nil
    end
    local function page()
        active.pageToken = ctx.token()
        active.deadline = ctx.now() + 15
        if not ctx.send(active.node.id, 'SCAN_MODEL', active.frame, 'verification:' .. active.page, active.pageToken) then
            finish('SEND_FAILED')
        end
    end
    local api = {}
    function api.enqueue(site)
        if site.verified or pending[site.id] or (active and active.site.id == site.id) then return end
        if site.intelCheckedAt and ctx.now() - site.intelCheckedAt < 300 then return end
        local count = 0; for _ in pairs(pending) do count = count + 1 end
        if count >= 32 then return end
        pending[site.id] = {site=site, expires=ctx.now()+300}
    end
    function api.busy(id) return active and (not id or active.node.id == id) or false end
    function api.tick()
        if active then
            if active.node.session ~= active.session or not ctx.available(active.node, true) then finish('NODE_UNAVAILABLE')
            elseif ctx.now() >= active.deadline then finish('SCAN_TIMEOUT') end
            return
        end
        local nextJob
        for id, job in pairs(pending) do
            if ctx.now() >= job.expires then pending[id] = nil
            elseif not nextJob or id < nextJob.site.id then nextJob = job end
        end
        if not nextJob then return end
        local selected
        for _, node in pairs(ctx.nodes()) do
            if ctx.available(node, false) and (not selected or node.id < selected.id) then selected = node end
        end
        if not selected then return end
        pending[nextJob.site.id] = nil
        active = {site=nextJob.site,node=selected,session=selected.session,token=ctx.token(),
            x=math.floor(nextJob.site.x+.5),z=math.floor(nextJob.site.z+.5),deadline=ctx.now()+180}
        nextJob.site.intelState = 'SCANNING'
        if not ctx.send(selected.id,'SCAN',active.x,active.z,active.token) then finish('SEND_FAILED') end
    end
    function api.receive(node, p)
        local job = active
        if not job or node.id ~= job.node.id or node.session ~= job.session then return end
        if p[1] == 'ERROR' and p[3] == job.token then finish('SCAN_REJECTED'); return end
        if p[1] == 'SCAN_COMPLETE' then
            local f = p[2]
            if type(f) ~= 'table' or f.session ~= job.session or f.request ~= job.token
                or f.targetX ~= job.x or f.targetZ ~= job.z or type(f.id) ~= 'string' or job.frame then return end
            if job.site.dimension ~= nil and (type(f.native) ~= 'table' or f.native.dimension ~= job.site.dimension) then
                finish('DIMENSION_UNCONFIRMED'); return
            end
            job.frame=f.id; job.page=1; page(); return
        end
        if p[1] ~= 'SCAN_MODEL' or p[2] ~= job.frame or p[3] ~= 'verification:' .. tostring(job.page)
            or p[4] ~= job.pageToken then return end
        if type(p[5]) ~= 'string' or #p[5] > 8192 or type(p[6]) ~= 'boolean' then finish('INVALID_FINDINGS'); return end
        local count = 0
        for row in p[5]:gmatch('[^|]+') do
            count=count+1
            local fields={};for value in row:gmatch('[^,]+') do fields[#fields+1]=value end
            if #fields~=11 or count>8 then finish('INVALID_FINDINGS');return end
            local v={}
            for _,i in ipairs({1,2,3,4,5,6,7,9,10}) do
                v[i]=tonumber(fields[i])
                if not v[i] or v[i]~=v[i] or math.abs(v[i])>30000000 or v[i]%1~=0 then finish('INVALID_FINDINGS');return end
            end
            local kind=fields[8]
            local target=fields[11]
            local rank=({LAUNCHPAD=true,LAUNCH_TABLE=true,COMPACT_LAUNCHER=true,SILO_HATCH=true})[target] and 1
                or (kind=='MISSILE' and (target=='LOADED_MISSILE' or target=='STORED_MISSILE') and 2 or nil)
            local distance=(v[1]-job.x)^2+(v[3]-job.z)^2
            if rank and v[1]==v[4] and v[2]==v[5] and v[3]==v[6] and v[9]>=80 and v[9]<=100
                and distance<=(job.site.verificationRadius or 100)^2 and (not job.best or rank<job.best.rank or (rank==job.best.rank and distance<job.best.distance)) then
                job.best={x=v[1],y=v[2],z=v[3],kind=kind,rank=rank,distance=distance}
            end
        end
        if not p[6] then
            if job.page>=16 then finish('INVALID_FINDINGS');return end
            job.page=job.page+1;page();return
        end
        if job.best then
            local site,b=job.site,job.best
            site.radarEstimate={x=site.x,y=site.y,z=site.z}
            site.x,site.y,site.z=b.x,b.y,b.z
            site.verified={node=node.id,frame=job.frame,kind=b.kind,at=ctx.now()}
            finish('VERIFIED at '..b.x..','..b.y..','..b.z)
        else finish('INCONCLUSIVE') end
    end
    return api
end
