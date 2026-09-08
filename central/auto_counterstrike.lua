-- Automatic responses consume each new threat once; uncertain sends are never retried.
return function(ctx)
    local pending,seen,order={}, {}, {}
    local enabledAt=ctx.now()
    local api={}
    function api.reset() pending={};enabledAt=ctx.now() end
    function api.observe(track)
        if not ctx.config().enabled or track.friendly or not track.firstSeen or track.firstSeen<=enabledAt then return end
        local key=track.entityUuid or track.key
        if track.autoCounterstrikeHandled then return end
        if not key or seen[key] then return end
        if pending[key] then pending[key].track=track;return end
        if track.payloadClass~='NUCLEAR' and track.payloadClass~='THERMONUCLEAR' and track.payloadClass~='CONVENTIONAL' then return end
        local count=0;for _ in pairs(pending)do count=count+1 end
        if count>=32 then return end
        pending[key]={track=track,expires=ctx.now()+120}
    end
    function api.tick()
        if not ctx.config().enabled then pending={};return end
        local keys={};for k in pairs(pending)do keys[#keys+1]=k end;table.sort(keys)
        for _,key in ipairs(keys)do
            local job=pending[key];local t=job.track
            if t.friendly or ctx.now()>=job.expires then pending[key]=nil
            else
                local site=ctx.site(t.launchSiteId)
                if site then
                    local choices=t.payloadClass=='CONVENTIONAL' and {'conventional'} or {'nuclear','bunker','conventional'}
                    local nodes=ctx.nodes();table.sort(nodes,function(a,b)return a.id<b.id end)
                    for _,class in ipairs(choices)do
                        local plan,total={},0
                        for _,node in ipairs(nodes)do
                            local count=ctx.ready(node,class,ctx.config().salvo-total)
                            if count>0 then plan[#plan+1]={node=node,count=count};total=total+count end
                            if total>=ctx.config().salvo then break end
                        end
                        if total>0 then
                            -- Reserve before any yielding dispatch. No retry on unknown outcome.
                            pending[key]=nil;seen[key]=true;order[#order+1]=key
                            if #order>512 then seen[table.remove(order,1)]=nil end
                            t.autoCounterstrikeHandled=true
                            ctx.log('[COUNTERSTRIKE] AUTO '..class:upper()..' salvo='..total..'/'..ctx.config().salvo..' site #'..site.id)
                            for _,part in ipairs(plan)do
                                if not ctx.config().enabled then break end
                                ctx.dispatch(part.node,class,part.count,site)
                            end
                            return
                        end
                    end
                end
            end
        end
    end
    return api
end
