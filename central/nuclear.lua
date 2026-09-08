-- Bounded, acknowledged observations; damage views use the existing intel runtime.
return function(ctx)
    local seen, order, pending, active = {}, {}, {}, nil
    local function finite(n) return type(n)=='number' and n==n and math.abs(n)<1e15 end
    local function finish(reason)
        ctx.log('[NUCLEAR] Post-blast scan '..active.event.id..': '..reason)
        active=nil
    end
    local api={}
    function api.busy(id) return active and (not id or active.node.id==id) or false end
    function api.receive(node,p)
        if p[1]=='NUCLEAR_EVENTS' then
            if node.role~='nuclear' or not node.claimed or type(p[2])~='string' or #p[2]>8192
                or type(p[3])~='string' or #p[3]>200 then return end
            local ok,b=pcall(ctx.decode,p[2])
            if not ok or type(b)~='table' or b.session~=node.session or not node.session
                or type(b.events)~='table' or #b.events>8 or not finite(b.lost) or b.lost<0 or b.lost%1~=0 then return end
            local count=0
            for k,e in pairs(b.events) do
                count=count+1
                if type(k)~='number' or k%1~=0 or k<1 or k>#b.events or count>8
                    or type(e)~='table' or type(e.id)~='string' or #e.id==0 or #e.id>100
                    or (e.kind~='MISSILE' and e.kind~='EXPLOSION')
                    or (e.payload~='NUCLEAR' and e.payload~='THERMONUCLEAR')
                    or not finite(e.x) or not finite(e.z) or math.abs(e.x)>30000000 or math.abs(e.z)>30000000
                    or (e.y~=nil and not finite(e.y)) or not finite(e.dimension) or e.dimension%1~=0
                    or not finite(e.tick) or e.tick<0 or e.tick%1~=0 then return end
            end
            if b.lost>0 and node.nuclearBatch~=p[3] then
                ctx.log('[NUCLEAR] Detector history gap: '..b.lost..' observations expired or exceeded retention.')
            end
            node.nuclearBatch=p[3]
            for _,e in ipairs(b.events) do
                if not seen[e.id] then
                    seen[e.id]=true;order[#order+1]=e.id
                    if #order>256 then seen[table.remove(order,1)]=nil end
                    ctx.log('[NUCLEAR] '..e.payload..' '..e.kind..' observed X='..e.x
                        ..(e.y and ' Y='..e.y or '')..' Z='..e.z..' dimension='..e.dimension..' tick='..e.tick)
                    if e.kind=='EXPLOSION' then
                        if #pending<16 then pending[#pending+1]={event=e,ready=ctx.now()+60,expires=ctx.now()+600}
                        else ctx.log('[NUCLEAR] Post-blast scan queue full; observation retained in logs.') end
                    end
                end
            end
            ctx.send(node.id,'NUCLEAR_ACK',p[3])
            return
        end
        if not active or node.id~=active.node.id or node.session~=active.session then return end
        if p[1]=='ERROR' and p[3]==active.token then finish('SCAN_REJECTED')
        elseif p[1]=='SCAN_COMPLETE' then
            local f=p[2]
            if type(f)~='table' or f.session~=active.session or f.request~=active.token
                or f.targetX~=active.x or f.targetZ~=active.z or type(f.id)~='string' then return end
            if type(f.native)~='table' or f.native.dimension~=active.event.dimension then
                finish('DIMENSION_UNCONFIRMED');return
            end
            finish('COMPLETE; terrain snapshot '..f.id..' available to the projection system')
        end
    end
    function api.tick()
        if active then
            if active.node.session~=active.session or not ctx.available(active.node,true) then finish('NODE_UNAVAILABLE')
            elseif ctx.now()>=active.deadline then finish('TIMEOUT') end
            return
        end
        for i=#pending,1,-1 do
            if ctx.now()>=pending[i].expires then
                ctx.log('[NUCLEAR] No intelligence satellite available for post-blast scan '..pending[i].event.id)
                table.remove(pending,i)
            end
        end
        local job=pending[1]
        if not job or ctx.now()<job.ready then return end
        local selected
        for _,node in pairs(ctx.nodes()) do
            if ctx.available(node,false) and (not selected or node.id<selected.id) then selected=node end
        end
        if not selected then return end
        table.remove(pending,1)
        active={event=job.event,node=selected,session=selected.session,token=ctx.token(),
            x=math.floor(job.event.x+.5),z=math.floor(job.event.z+.5),deadline=ctx.now()+180}
        ctx.log('[NUCLEAR] Post-blast scan started on '..selected.id..' X='..active.x..' Z='..active.z)
        if not ctx.send(selected.id,'SCAN',active.x,active.z,active.token) then finish('SEND_FAILED') end
    end
    return api
end
