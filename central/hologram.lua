-- CENTRAL owns the projector. Nodes supply bounded pages from a named completed scan.
-- No projector calls run from a modem callback: receive only validates and queues data.
return function(options)
    local component, now = options.component, options.now
    local viewer, offers = {}, {}
    local job, selected, displayed, message, serial = nil, options.address, nil, "Waiting for a completed combined scan", 0
    local nextDeviceCheck = 0
    local model, selectedFinding, view = nil, nil, "cutaway"

    local function projector()
        local addresses={}
        for address in component.list("hologram") do addresses[#addresses+1]=address end
        if selected then
            for _,address in ipairs(addresses) do if address==selected then return component.proxy(address),address end end
            error("Selected projector disconnected: " .. selected)
        end
        if #addresses~=1 then error("Connect one hologram projector, or use hologram bind <address>") end
        return component.proxy(addresses[1]),addresses[1]
    end

    local function fail(text)
        job=nil; message=tostring(text)
        if options.log then options.log("[HOLOGRAM] " .. message) end
    end

    local function begin(node,frame)
        model=nil;selectedFinding=nil
        job={node=node,frame=frame,stage="device",kind="structure",page=1,chunks={},bounds=nil,findings={}}
        nextDeviceCheck=0
        message="Preparing " .. node .. " | " .. frame.summary
    end

    function viewer.offer(node,frame)
        if type(node)~="string" or type(frame)~="table" or type(frame.id)~="string" or #frame.id>160
            or type(frame.session)~="string" or type(frame.summary)~="string" or #frame.summary>2048
            or type(frame.sequence)~="number" or frame.sequence%1~=0 or frame.sequence<1 then return end
        local prior=offers[node]
        if prior and prior.session==frame.session and prior.sequence>=frame.sequence then return end
        offers[node]=frame
        begin(node,frame)
    end

    local function rows(data,kind,consume)
        assert(type(data)=="string" and #data<=4096,"Invalid model page")
        local count=0
        for row in data:gmatch("[^|]+") do
            local values={}
            for field in row:gmatch("[^,]+") do
                if kind=="findings" and #values==7 then
                    assert(#field<=40 and field:match('^[A-Z_]+$'),"Invalid finding classification")
                    values[#values+1]=field
                else
                    assert(field:match("^%-?%d+$"),"Invalid model coordinate")
                    local value=tonumber(field)
                    assert(value and math.abs(value)<=32000000,"Model coordinate out of range")
                    values[#values+1]=value
                end
            end
            assert(#values==(kind=="structure" and 4 or kind=="findings" and 10 or 6),"Invalid model row")
            if kind=="structure" then assert(values[4]==1 or values[4]==2,"Invalid structure color")
            else for axis=1,3 do assert(values[axis]<=values[axis+3],"Reversed target bounds") end end
            if kind=="findings" then
                assert(values[7]>=1 and values[7]<=128 and values[9]>=0 and values[9]<=100 and values[10]>=0,"Invalid finding metadata")
            end
            count=count+1;assert(count<=(kind=="structure" and 64 or 8),"Oversized model page")
            consume(values)
        end
    end

    local function extend(j,x,y,z)
        if not j.bounds then j.bounds={x,y,z,x,y,z};return end
        local b=j.bounds
        b[1]=math.min(b[1],x);b[2]=math.min(b[2],y);b[3]=math.min(b[3],z)
        b[4]=math.max(b[4],x);b[5]=math.max(b[5],y);b[6]=math.max(b[6],z)
    end

    function viewer.receive(node,frame,page,token,data,done)
        local j=job
        if not j or j.stage~="fetch" or not j.pending or node~=j.node or frame~=j.frame.id
            or page~=j.pending.page or token~=j.pending.token then return end
        if data==false then fail("ERROR: " .. tostring(done));return end
        local ok,err=pcall(function()
            assert(type(done)=="boolean","Invalid model completion flag")
            rows(data,j.kind,function(v)
                extend(j,v[1],v[2],v[3])
                if j.kind~="structure" then
                    extend(j,v[4],v[5],v[6])
                    if j.kind=="findings" then
                        assert(v[7]==#j.findings+1,"Finding IDs must match scan order")
                        j.findings[v[7]]=v
                    end
                end
            end)
            j.chunks[#j.chunks+1]={kind=j.kind,data=data}
            j.pending=nil
            if done then
                if j.kind=="structure" then j.kind=j.frame.modelVersion==2 and "findings" or "targets";j.page=1
                else j.stage="prepare" end
            else
                j.page=j.page+1
                assert(j.page<=(j.kind=="structure" and 128 or 16),"Model exceeds satellite limits")
            end
        end)
        if not ok then fail("ERROR: " .. tostring(err)) end
    end

    local contextTypes={STRUCTURE=true,REINFORCED_STRUCTURE=true,POSSIBLE_SILO=true,BUNKER=true,CAVITY=true,TUNNEL=true}
    local function describe(f)
        return string.format("#%d %s | %d,%d,%d to %d,%d,%d | confidence=%d%% | count=%d",
            f[7],f[8],f[1],f[2],f[3],f[4],f[5],f[6],f[9],f[10])
    end

    local function prepare(j)
        local b=j.bounds or {0,0,0,0,0,0}
        -- Reserve two voxels on every side for symbols centered on detections.
        local scale=math.max(1,(b[4]-b[1])/43,(b[5]-b[2])/27,(b[6]-b[3])/43)
        local offsets={math.floor((49-math.floor((b[4]-b[1])/scale))/2),
            math.floor((33-math.floor((b[5]-b[2])/scale))/2),math.floor((49-math.floor((b[6]-b[3])/scale))/2)}
        local function point(x,y,z)
            return offsets[1]+math.floor((x-b[1])/scale),offsets[2]+math.floor((y-b[2])/scale),offsets[3]+math.floor((z-b[3])/scale)
        end
        j.scale=scale
        local drawView, selection=view,selectedFinding
        local function visible(x,y,z)
            if drawView=="structure" then return true end
            if drawView=="findings" then return false end
            -- Open the +Z half of each inferred enclosure, including its sampled
            -- walls just outside the cavity bounds. Other structures use the scene plane.
            for _,f in pairs(j.findings) do
                if contextTypes[f[8]] and f[6]>f[3] and f[5]>f[2]
                    and x>=f[1]-2*scale and x<=f[4]+2*scale
                    and y>=f[2]-2*scale and y<=f[5]+2*scale
                    and z>=f[3]-2*scale and z<=f[6]+2*scale then
                    return z<(f[3]+f[6])/2
                end
            end
            return b[6]-b[3]<scale or z<(b[3]+b[6])/2
        end
        j.draw=coroutine.create(function()
            local voxels={}
            -- Structure is dim context. Finding symbols are drawn after it.
            for _,chunk in ipairs(j.chunks) do
                if chunk.kind=="structure" then
                    rows(chunk.data,chunk.kind,function(v)
                        if visible(v[1],v[2],v[3]) then
                            local x,y,z=point(v[1],v[2],v[3]);local key=(x-1)*1536+(z-1)*32+y-1
                            voxels[key]=1
                        end
                    end)
                    coroutine.yield()
                end
            end
            local holo,address=projector();j.address=address
            local colorCount=holo.maxDepth()>1 and 3 or 1
            holo.setPaletteColor(1,0x20505C)
            if colorCount==3 then holo.setPaletteColor(2,0xA87824);holo.setPaletteColor(3,0xE04040) end
            holo.clear();j.cleared=true;displayed=nil
            local function plot(x,y,z,color)
                -- Re-check the component only once per batch in tick.
                holo.set(x,y,z,colorCount==1 and 1 or color)
                coroutine.yield()
            end
            for key,color in pairs(voxels) do
                if colorCount~=1 or not selection then
                    plot(math.floor(key/1536)+1,key%32+1,math.floor(key/32)%48+1,color)
                end
            end
            voxels=nil
            local function box(v,color)
                local x1,y1,z1=point(v[1],v[2],v[3]);local x2,y2,z2=point(v[4],v[5],v[6])
                for x=x1,x2 do for _,y in ipairs({y1,y2}) do for _,z in ipairs({z1,z2}) do plot(x,y,z,color) end end end
                for y=y1,y2 do for _,x in ipairs({x1,x2}) do for _,z in ipairs({z1,z2}) do plot(x,y,z,color) end end end
                for z=z1,z2 do for _,x in ipairs({x1,x2}) do for _,y in ipairs({y1,y2}) do plot(x,y,z,color) end end end
            end
            local function marker(v,color)
                local x,y,z=point((v[1]+v[4])/2,(v[2]+v[5])/2,(v[3]+v[6])/2)
                -- Symbols indicate finding type, not the object's physical dimensions.
                local kind=v[8]
                if kind=="MISSILE" then
                    for dy=-2,2 do plot(x,y+dy,z,color) end
                    plot(x-1,y,z,color);plot(x+1,y,z,color)
                elseif kind=="LAUNCH_INFRASTRUCTURE" or kind=="SILO_HATCH" then
                    local radius=kind=="SILO_HATCH" and 1 or 2
                    for d=-radius,radius do
                        plot(x+d,y,z-radius,color);plot(x+d,y,z+radius,color)
                        plot(x-radius,y,z+d,color);plot(x+radius,y,z+d,color)
                    end
                    if kind=="SILO_HATCH" then plot(x,y,z,color) end
                else
                    plot(x,y,z,color);plot(x-1,y,z,color);plot(x+1,y,z,color)
                    plot(x,y,z-1,color);plot(x,y,z+1,color)
                end
            end
            -- Inferred bounds first, equipment second, selected finding last.
            for pass=1,3 do
                for _,v in ipairs(j.findings) do
                    local isContext=contextTypes[v[8]]
                    local priority=selection==v[7] and 3 or isContext and 1 or 2
                    if priority==pass and (colorCount~=1 or not selection or selection==v[7]) then
                        local color=(selection and selection==v[7] or not selection and not isContext) and 3 or 2
                        if v[1]~=v[4] or v[2]~=v[5] or v[3]~=v[6] then box(v,color) end
                        if not isContext or (v[1]==v[4] and v[2]==v[5] and v[3]==v[6]) then marker(v,color) end
                    end
                end
            end
            -- Older intel runtimes can still display coordinate-only bounds.
            for _,chunk in ipairs(j.chunks) do
                if chunk.kind=="targets" then rows(chunk.data,chunk.kind,function(v)box(v,3)end) end
            end
            j.detail=" | view="..drawView.." | "..#j.findings.." findings"
            if j.frame.modelVersion~=2 then
                j.detail=j.detail.." | Untyped legacy data; deploy the updated intel runtime"
            elseif selection and j.findings[selection] then
                j.detail=j.detail.." | Selected "..describe(j.findings[selection])
            else
                j.detail=j.detail.." | hologram list / select <finding-number>"
            end
        end)
        j.stage="draw"
    end

    function viewer.tick()
        local j=job;if not j then return end
        local ok,err=pcall(function()
            if j.stage=="device" then
                if now()<nextDeviceCheck then return end
                nextDeviceCheck=now()+5
                local found,_,address=pcall(projector)
                if not found then message="Waiting for projector: " .. tostring(_);return end
                j.address=address;j.stage="fetch"
            end
            if j.stage=="fetch" then
                if j.pending and now()-j.pending.at<8 then return end
                if j.pending and j.pending.tries>=3 then fail("TIMEOUT: scan model from " .. j.node .. "; use hologram show " .. j.node);return end
                if not j.pending then
                    serial=serial+1
                    j.pending={page=j.kind .. ":" .. j.page,token="holo-"..serial,tries=0}
                end
                local p=j.pending;p.at=now();p.tries=p.tries+1
                message="FETCHING " .. j.node .. " " .. p.page .. " | " .. j.frame.summary
                options.send(j.node,"SCAN_MODEL",j.frame.id,p.page,p.token)
            elseif j.stage=="prepare" then prepare(j)
            elseif j.stage=="draw" then
                local _,address=projector();assert(address==j.address,"Selected projector changed")
                message="DRAWING " .. j.node .. " | " .. j.frame.summary
                for _=1,64 do
                    local resumed,problem=coroutine.resume(j.draw);assert(resumed,problem)
                    if coroutine.status(j.draw)=="dead" then
                        displayed=j.node .. " | " .. j.frame.summary .. string.format(" | %.2f world blocks/voxel",j.scale)..j.detail
                        message=(j.bounds and "DISPLAYED " or "EMPTY (no sampled structure or equipment) ") .. displayed
                        model=j;job=nil
                        if options.log then options.log("[HOLOGRAM] " .. message) end
                        break
                    end
                end
            end
        end)
        if not ok then fail("ERROR: " .. tostring(err)) end
    end

    function viewer.status()
        return message .. (displayed and message:sub(1,9)~="DISPLAYED" and message:sub(1,5)~="EMPTY"
            and (" | Previous display: " .. displayed) or "")
    end

    function viewer.busy() return job~=nil and job.stage~="device" end

    function viewer.command(action,arg)
        action=action or "status"
        if action=="status" then return true,viewer.status() end
        if action=="list" then
            if not model then return false,"Wait for a completed hologram model" end
            if model.frame.modelVersion~=2 then return false,"Deploy the updated intel runtime for typed findings" end
            local lines={"Findings for "..model.node.." | numbers match scan results"}
            for _,f in ipairs(model.findings) do lines[#lines+1]=describe(f) end
            return true,table.concat(lines,"\n")
        elseif action=="select" then
            if not model or job then return false,"Wait for the model to finish drawing" end
            local index=tonumber(arg)
            if arg~="all" and (not index or not model.findings[index]) then return false,"Finding not found; use hologram list" end
            selectedFinding=arg~="all" and index or nil
            job=model;job.stage="prepare"
            return true,selectedFinding and ("Selected "..describe(model.findings[index])) or "Showing all findings"
        elseif action=="view" then
            if arg~="cutaway" and arg~="structure" and arg~="findings" then return false,"Use hologram view cutaway|structure|findings" end
            if job then return false,"Wait for the model to finish drawing" end
            view=arg
            if model then job=model;job.stage="prepare" end
            return true,"View: "..view..(view=="cutaway" and " (+Z half opened)" or "")
        end
        if action=="show" then
            if not offers[arg] then return false,"No completed combined scan from " .. tostring(arg) end
            begin(arg,offers[arg]);return true,"Queued hologram from " .. arg
        elseif action=="bind" then
            local found=false
            for address in component.list("hologram") do if address==arg then found=true end end
            if not found then return false,"Projector address not found" end
            selected=arg
            if job then begin(job.node,job.frame) end
            return true,"Projector selected: " .. arg
        elseif action=="clear" then
            local ok,err=pcall(function()local holo=projector();holo.clear()end)
            if not ok then return false,tostring(err) end
            job=nil;model=nil;displayed=nil;message="CLEARED; waiting for a new scan or hologram show <node>"
            return true,message
        end
        return false,"hologram status | list | select <number|all> | view cutaway|structure|findings | show <node> | clear | bind <address>"
    end
    return viewer
end
