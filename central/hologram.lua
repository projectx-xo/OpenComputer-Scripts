-- CENTRAL owns the projector. Nodes supply bounded pages from a named completed scan.
-- No projector calls run from a modem callback: receive only validates and queues data.
return function(options)
    local component, now = options.component, options.now
    local viewer, offers = {}, {}
    local job, selected, displayed, message, serial = nil, options.address, nil, "Waiting for a completed combined scan", 0
    local nextDeviceCheck = 0

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
        job={node=node,frame=frame,stage="device",kind="structure",page=1,chunks={},bounds=nil}
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
                assert(field:match("^%-?%d+$"),"Invalid model coordinate")
                local value=tonumber(field)
                assert(value and math.abs(value)<=32000000,"Model coordinate out of range")
                values[#values+1]=value
            end
            assert(#values==(kind=="structure" and 4 or 6),"Invalid model row")
            if kind=="structure" then assert(values[4]==1 or values[4]==2,"Invalid structure color")
            else for axis=1,3 do assert(values[axis]<=values[axis+3],"Reversed target bounds") end end
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
                extend(j,v[1],v[2],v[3]);if j.kind=="targets" then extend(j,v[4],v[5],v[6]) end
            end)
            j.chunks[#j.chunks+1]={kind=j.kind,data=data}
            j.pending=nil
            if done then
                if j.kind=="structure" then j.kind="targets";j.page=1
                else j.stage="prepare" end
            else
                j.page=j.page+1
                assert(j.page<=(j.kind=="structure" and 128 or 16),"Model exceeds satellite limits")
            end
        end)
        if not ok then fail("ERROR: " .. tostring(err)) end
    end

    local function prepare(j)
        local b=j.bounds or {0,0,0,0,0,0}
        local scale=math.max(1,(b[4]-b[1])/45,(b[5]-b[2])/29,(b[6]-b[3])/45)
        local offsets={math.floor((49-math.floor((b[4]-b[1])/scale))/2),
            math.floor((33-math.floor((b[5]-b[2])/scale))/2),math.floor((49-math.floor((b[6]-b[3])/scale))/2)}
        local function point(x,y,z)
            return offsets[1]+math.floor((x-b[1])/scale),offsets[2]+math.floor((y-b[2])/scale),offsets[3]+math.floor((z-b[3])/scale)
        end
        j.scale=scale
        j.draw=coroutine.create(function()
            local voxels={}
            -- Coalesced structural cells retain the strongest resistance category.
            for _,chunk in ipairs(j.chunks) do
                if chunk.kind=="structure" then
                    rows(chunk.data,chunk.kind,function(v)
                        local x,y,z=point(v[1],v[2],v[3]);local key=(x-1)*1536+(z-1)*32+y-1
                        voxels[key]=math.max(voxels[key] or 0,v[4])
                    end)
                    coroutine.yield()
                end
            end
            local holo,address=projector();j.address=address
            local colorCount=holo.maxDepth()>1 and 3 or 1
            holo.setPaletteColor(1,0x56CFE1)
            if colorCount==3 then holo.setPaletteColor(2,0xFFBE55);holo.setPaletteColor(3,0xFF5555) end
            holo.clear();j.cleared=true;displayed=nil
            local function plot(x,y,z,color)
                -- Re-check the component only once per batch in tick.
                holo.set(x,y,z,colorCount==1 and 1 or color)
                coroutine.yield()
            end
            for key,color in pairs(voxels) do
                plot(math.floor(key/1536)+1,key%32+1,math.floor(key/32)%48+1,color)
            end
            voxels=nil
            for _,chunk in ipairs(j.chunks) do
                if chunk.kind=="targets" then
                    rows(chunk.data,chunk.kind,function(v)
                        local x1,y1,z1=point(v[1],v[2],v[3]);local x2,y2,z2=point(v[4],v[5],v[6])
                        for x=x1,x2 do for _,y in ipairs({y1,y2}) do for _,z in ipairs({z1,z2}) do plot(x,y,z,3) end end end
                        for y=y1,y2 do for _,x in ipairs({x1,x2}) do for _,z in ipairs({z1,z2}) do plot(x,y,z,3) end end end
                        for z=z1,z2 do for _,x in ipairs({x1,x2}) do for _,y in ipairs({y1,y2}) do plot(x,y,z,3) end end end
                    end)
                end
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
                        displayed=j.node .. " | " .. j.frame.summary .. string.format(" | %.2f world blocks/voxel",j.scale)
                        message=(j.bounds and "DISPLAYED " or "EMPTY (no sampled structure or equipment) ") .. displayed
                        job=nil
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
            job=nil;displayed=nil;message="CLEARED; waiting for a new scan or hologram show <node>"
            return true,message
        end
        return false,"hologram status | show <node> | clear | bind <projector-address>"
    end
    return viewer
end
