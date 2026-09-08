-- Shared awareness only: never changes launch permission or damage behavior.
return function(ctx)
    local api={}
    local function finite(v) return type(v)=='number' and v==v and math.abs(v)<=30000000 end
    function api.ingest(node,status)
        node.teamAssets={}
        if type(status.teamAssets)~='table' then return end
        for i,a in ipairs(status.teamAssets) do
            if i>32 then break end
            if type(a)=='table' and type(a.team)=='string' and #a.team<=64 and not a.team:find('%c')
                and type(a.label)=='string' and #a.label<=32 and not a.label:find('%c')
                and finite(a.x) and finite(a.y) and finite(a.z) and finite(a.dimension) and a.dimension%1==0
                and a.source=='BASECENTER' and a.team~='' then
                node.teamAssets[#node.teamAssets+1]={team=a.team,label=a.label,x=a.x,y=a.y,z=a.z,dimension=a.dimension,at=ctx.now()}
            end
        end
    end
    function api.relation(team)
        if not ctx.team() or ctx.team()=='' or not team or team=='' then return 'UNKNOWN' end
        return team==ctx.team() and 'FRIENDLY' or 'OTHER TEAM'
    end
    function api.describe(node)
        if not node.teamAssets or #node.teamAssets==0 then return 'Team: UNKNOWN (unregistered or unsupported hardware)' end
        local rows={}
        for _,a in ipairs(node.teamAssets) do
            rows[#rows+1]=a.label..' — '..api.relation(a.team)..' — '..a.team..' @ '..a.x..','..a.y..','..a.z
                ..' dim='..a.dimension..((not ctx.online(node) or ctx.now()-a.at>15) and ' [LAST KNOWN]' or '')
        end
        return table.concat(rows,'\n')
    end
    function api.near(x,z,dimension,friendlyOnly)
        local found,seen={},{}
        for _,node in pairs(ctx.nodes()) do
            for _,a in ipairs(node.teamAssets or {}) do
                if (not dimension or dimension==a.dimension) and (a.x-x)^2+(a.z-z)^2<=32^2
                    and (not friendlyOnly or api.relation(a.team)=='FRIENDLY') then
                    local key=a.dimension..':'..a.x..':'..a.y..':'..a.z
                    if not seen[key] then seen[key]=true;found[#found+1]={node=node,asset=a} end
                end
            end
        end
        return found
    end
    function api.warn(node,x,z)
        local dimension
        for _,a in ipairs(node.teamAssets or {}) do
            if dimension and dimension~=a.dimension then dimension=nil;break end
            dimension=a.dimension
        end
        for _,entry in ipairs(api.near(x,z,dimension,true)) do
            local a=entry.asset
            ctx.log('[TEAM] WARNING: target is within 32 blocks of friendly '..entry.node.id..' / '..a.label
                ..' ('..a.team..') X='..a.x..' Z='..a.z..' dimension='..a.dimension
                ..(not dimension and ' [launch dimension unknown]' or '')
                ..((not ctx.online(entry.node) or ctx.now()-a.at>15) and ' [last known location]' or '')
                ..'. Launch remains available through normal confirmation.')
        end
    end
    function api.report(x,z,dimension)
        local matches=api.near(x,z,dimension,false)
        if #matches==0 then ctx.log('[TEAM] No registered asset identified near these coordinates. Allegiance UNKNOWN.');return end
        for _,e in ipairs(matches) do
            ctx.log('[TEAM] Nearby registered asset: '..e.node.id..' / '..e.asset.label..' — '..api.relation(e.asset.team)..' — '..e.asset.team
                ..' dimension='..e.asset.dimension..((not ctx.online(e.node) or ctx.now()-e.asset.at>15) and ' [LAST KNOWN]' or '')
                ..' (coordinate proximity, not ownership proof for every finding)')
        end
    end
    return api
end
