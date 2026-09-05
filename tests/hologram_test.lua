-- Production satellite runtime -> paged mesh responses -> production viewer -> voxel device.
local failures = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    print((ok and 'PASS ' or 'FAIL ') .. name .. (ok and '' or ': ' .. tostring(err)))
    if not ok then failures = failures + 1 end
end
local function setup(depth)
    local clock, messages, requests, pixels, palettes = 0, {}, {}, {}, {}
    local s = {state='RUNNING', kind='COMBINED_INTEL', clears=0, writes=0, connected=true, requestCount=0}
    local sat = {
        isConnected=function()return s.connected end, getType=function()return s.kind end,
        intelStatus=function()return s.state,0,0,100 end,
        intelSummary=function()return 'COMBINED;102;202;100%;FINDINGS=1' end,
        intelSetTarget=function()return true,'OK' end,
        intelStartScan=function()s.state='RUNNING';return true,'STARTED' end,
        intelStructuralPage=function(page)
            if page>1 then return false,'OUT_OF_RANGE' end
            return true,2,'100,40,200,hbm:wall,0,8,LIGHT|104,42,204,hbm:concrete,0,84,HEAVY'
        end,
        intelFindingCount=function()return 1 end,
        intelGetFinding=function()return true,'MISSILE',.95,102,41,202,102,41,202,false,true,false,true,false,'MISSILE','hbm:missile',1 end,
    }
    local holo = {maxDepth=function()return depth or 2 end,
        setPaletteColor=function(index,color)
            assert(index>=1 and index<=(depth==1 and 1 or 3),'invalid palette index')
            palettes[index]=color
        end,
        clear=function()s.clears=s.clears+1;for k in pairs(pixels)do pixels[k]=nil end end,
        set=function(x,y,z,value)
            assert(x>=1 and x<=48 and y>=1 and y<=32 and z>=1 and z<=48,'out-of-range voxel')
            assert(x%1==0 and y%1==0 and z%1==0,'fractional voxel')
            assert(value>=1 and value<=(depth==1 and 1 or 3),'invalid voxel color')
            s.writes=s.writes+1;pixels[x..','..y..','..z]=value
        end}
    local devices={sat={kind='ntm_satlink',proxy=sat},holo={kind='hologram',proxy=holo}}
    local component={list=function(kind)
        local list={};for address,d in pairs(devices)do if d.kind==kind then list[#list+1]=address end end
        table.sort(list);local i=0;return function()i=i+1;return list[i] end
    end,proxy=function(address)return assert(devices[address],'device disconnected').proxy end}
    local env=setmetatable({require=function(name)
        if name=='component' then return component elseif name=='computer' then return {uptime=function()return clock end} end
        error(name)
    end},{__index=_G})
    local runtime=assert(loadfile('runtime/intel.lua','t',env))()
    runtime.start({id='INTEL-1',session='boot-A',config={},log=function()end,
        send=function(_,kind,...)messages[#messages+1]={kind,...} end})
    local viewer
    local function makeViewer()
        local chunk=loadfile('central/hologram.lua')
        assert(chunk,'CENTRAL hologram viewer is missing')
        viewer=chunk()({component=component,now=function()return clock end,log=function()end,
            send=function(node,...)s.requestCount=s.requestCount+1;requests[#requests+1]={node,...};return true end})
        return viewer
    end
    local function step(deliver)
        clock=clock+.25;runtime.tick()
        if viewer then
            local status=runtime.status()
            if status.scanFrame then viewer.offer('INTEL-1',status.scanFrame) end
            viewer.tick()
            if deliver~=false then
                while #requests>0 do
                    local request=table.remove(requests,1)
                    runtime.onMessage('CENTRAL',table.unpack(request,2))
                end
                for _,message in ipairs(messages)do
                    if message[1]=='SCAN_MODEL' then viewer.receive('INTEL-1',table.unpack(message,2)) end
                end
                messages={}
            end
        end
    end
    return {runtime=runtime,state=s,sat=sat,devices=devices,pixels=pixels,palettes=palettes,
        messages=function()return messages end,requests=requests,viewer=makeViewer,step=step,
        finish=function()s.state='COMPLETE';for _=1,100 do step()end end}
end

test('completed combined scans expose a frame and compact correlated model pages',function()
    local t=setup();t.state.state='COMPLETE';t.step()
    local frame=t.runtime.status().scanFrame
    assert(frame and frame.session=='boot-A','completed scan has no frame identity')
    t.runtime.onMessage('CENTRAL','SCAN_MODEL',frame.id,'structure:1','request-1')
    local message=t.messages()[#t.messages()]
    assert(message[1]=='SCAN_MODEL' and message[2]==frame.id and message[3]=='structure:1' and message[4]=='request-1')
    assert(message[5]=='100,40,200,1|104,42,204,2' and message[6]==true,'incorrect HBM cell projection data')
end)
test('same-coordinate rescans invalidate old frames before supplying any pages',function()
    local t=setup();t.state.state='COMPLETE';t.step();local first=t.runtime.status().scanFrame
    assert(first,'completed scan frame missing')
    t.runtime.onMessage('CENTRAL','SCAN',102,202,'start')
    t.runtime.onMessage('CENTRAL','SCAN_MODEL',first.id,'structure:1','late')
    local reply=t.messages()[#t.messages()]
    assert(reply[1]=='SCAN_MODEL' and reply[5]==false,'old scan data accepted during new scan')
    t.finish();assert(t.runtime.status().scanFrame.id~=first.id,'same-coordinate scan reused identity')
end)
test('other satellite types and disconnected links cannot export models',function()
    for _,kind in ipairs({'RADAR','COMBINED_INTEL'})do
        local t=setup();t.state.kind=kind;t.state.connected=kind~='COMBINED_INTEL';t.state.state='COMPLETE';t.step()
        assert(t.runtime.status().scanFrame==nil)
        t.runtime.onMessage('CENTRAL','SCAN_MODEL','bad','structure:1','token')
        assert(t.messages()[#t.messages()][5]==false,'ineligible satellite supplied a model')
    end
end)
local function reportedScan(t)
    local findings={
        {true,'SILO_HATCH',1,522,54,1724,522,54,1724,false,true,false,true,false,'SILO_HATCH','hbm:tile.silo_hatch_large',1},
        {true,'MISSILE',1,508,5,1709,508,5,1709,false,true,false,true,false,'LOADED_MISSILE','hbm:item.missile_custom',1},
        {true,'LAUNCH_INFRASTRUCTURE',1,508,5,1709,508,5,1709,false,true,false,true,false,'LAUNCH_TABLE','hbm:tile.launch_table',1},
        {true,'SILO_HATCH',1,508,53,1709,508,53,1709,false,true,false,true,false,'SILO_HATCH','hbm:tile.silo_hatch_large',1},
        {true,'REINFORCED_STRUCTURE',.75,507,55,1709,507,55,1709,true,false,false,false,false,'','',0},
        {true,'MACHINERY',.9,526,54,1724,526,54,1724,false,true,false,false,false,'','',0},
        {true,'POSSIBLE_SILO',1,504,7,1705,512,51,1713,true,true,false,true,false,'','',0},
        {true,'MACHINERY',.48,508,53,1713,508,53,1713,false,true,false,false,false,'','',0},
    }
    t.sat.intelFindingCount=function()return #findings end
    t.sat.intelGetFinding=function(i)return table.unpack(findings[i])end
    -- Representative front/back wall samples, not an invented full-world scan.
    t.sat.intelStructuralPage=function()return true,4,
        '503,25,1704,hbm:wall,0,84,HEAVY|513,25,1714,hbm:wall,0,84,HEAVY|507,55,1709,hbm:wall,0,84,HEAVY|522,54,1724,hbm:wall,0,84,HEAVY' end
end
test('model transfer preserves all eight reported finding identities and types',function()
    local t=setup();reportedScan(t);t.state.state='COMPLETE';t.step()
    local frame=t.runtime.status().scanFrame
    t.runtime.onMessage('CENTRAL','SCAN_MODEL',frame.id,'findings:1','typed')
    local reply=t.messages()[#t.messages()]
    assert(type(reply[5])=='string','typed findings not exported')
    assert(reply[5]:find('508,5,1709,508,5,1709,2,MISSILE',1,true),'missile identity lost')
    assert(reply[5]:find('508,5,1709,508,5,1709,3,LAUNCH_INFRASTRUCTURE',1,true),'co-located launcher identity lost')
    assert(reply[5]:find(',5,REINFORCED_STRUCTURE',1,true),'finding without equipment flags was omitted')
    local count=0;for _ in reply[5]:gmatch('[^|]+')do count=count+1 end
    assert(count==8 and reply[6]==true,'finding list does not match console')
end)
test('cutaway opens silo walls and keeps co-located missile and launcher selectable',function()
    local t=setup();reportedScan(t);local v=t.viewer();t.finish()
    local fetched=t.state.requestCount
    local ok,legend=v.command('list')
    assert(ok and legend:find('#2 MISSILE',1,true) and legend:find('#3 LAUNCH_INFRASTRUCTURE',1,true),'findings cannot be identified')
    assert(legend:find('#7 POSSIBLE_SILO',1,true),'inferred silo not identified')
    assert(v.command('select','2'));for _=1,100 do t.step()end
    assert(v.status():find('#2 MISSILE',1,true) and v.status():find('508,5,1709',1,true),v.status())
    local missile={};for p,c in pairs(t.pixels)do if c==3 then missile[p]=true end end
    assert(v.command('select','3'));for _=1,100 do t.step()end
    assert(v.status():find('#3 LAUNCH_INFRASTRUCTURE',1,true),v.status())
    local different=false;for p,c in pairs(t.pixels)do if c==3 and not missile[p] then different=true end end
    assert(different,'missile and launcher render as the same marker')
    local cut=0;for _,c in pairs(t.pixels)do if c==1 then cut=cut+1 end end
    assert(v.command('view','structure'));for _=1,100 do t.step()end
    local full=0;for _,c in pairs(t.pixels)do if c==1 then full=full+1 end end
    assert(full>cut,'cutaway did not remove obscuring wall samples')
    assert(v.command('view','findings'));for _=1,100 do t.step()end
    for _,c in pairs(t.pixels)do assert(c~=1,'findings view still contains obscuring wall samples')end
    local accepted=v.command('select','99');assert(not accepted,'nonexistent finding selected')
    assert(t.state.requestCount==fetched,'selection or view redownloaded the model')
end)
test('tier one selection isolates each co-located equipment symbol',function()
    local t=setup(1);reportedScan(t);local v=t.viewer();t.finish()
    for _,selection in ipairs({{'2',7},{'3',16},{'4',9}})do
        assert(v.command('select',selection[1]));for _=1,100 do t.step()end
        local count=0;for _,c in pairs(t.pixels)do assert(c==1);count=count+1 end
        assert(count==selection[2],'single-color selection contains other findings or loses its symbol')
    end
    assert(v.command('select','all'));for _=1,100 do t.step()end
    local count=0;for _ in pairs(t.pixels)do count=count+1 end
    assert(count>16,'select all did not restore context')
end)
test('legacy coordinate-only nodes still display with an explicit upgrade notice',function()
    local t=setup();t.state.state='COMPLETE';t.step();local frame=t.runtime.status().scanFrame
    local v=t.viewer()
    v.offer('INTEL-1',{id=frame.id,session=frame.session,sequence=2,summary=frame.summary})
    for _=1,100 do t.step()end
    assert(v.status():find('DISPLAYED',1,true) and v.status():find('Untyped legacy data',1,true),v.status())
    assert(t.pixels['24,16,24']==3,'legacy target missing')
    assert(not v.command('list'),'legacy bounds presented as typed findings')
    t.runtime.onMessage('CENTRAL','SCAN_MODEL',frame.id,'targets:1','old-central')
    assert(t.messages()[#t.messages()][5]=='102,41,202,102,41,202','old CENTRAL target format changed')
end)
test('all 128 findings survive bounded pages with stable scan numbers',function()
    local t=setup();local v=t.viewer();local read={}
    t.sat.intelStructuralPage=function()return false,'OUT_OF_RANGE'end
    t.sat.intelFindingCount=function()return 128 end
    t.sat.intelGetFinding=function(i)
        read[i]=true
        return true,'MISSILE',1,i,40,0,i,40,0,false,true,false,true,false,'LOADED_MISSILE','hbm:item.missile_custom',1
    end
    t.finish();local ok,legend=v.command('list');assert(ok,legend)
    local count=0;for _ in legend:gmatch('#%d+ MISSILE')do count=count+1 end
    assert(count==128 and read[128],'last findings page missing')
    assert(t.state.requestCount==17,'unexpected page count')
    assert(v.command('select','128'));for _=1,100 do t.step()end
    assert(v.status():find('Selected #128 MISSILE',1,true),v.status())
end)
test('markers at extreme scan corners fit inside the projector',function()
    local t=setup();local v=t.viewer()
    t.sat.intelStructuralPage=function()return false,'OUT_OF_RANGE'end
    t.sat.intelFindingCount=function()return 2 end
    t.sat.intelGetFinding=function(i)
        local x,y,z=i==1 and -30000000 or 30000000,i==1 and 0 or 255,i==1 and -30000000 or 30000000
        return true,'MISSILE',1,x,y,z,x,y,z,false,true,false,true,false,'LOADED_MISSILE','hbm:item.missile_custom',1
    end
    t.finish();assert(v.status():find('DISPLAYED',1,true),v.status())
    local count=0;for _ in pairs(t.pixels)do count=count+1 end
    assert(count==14,'edge symbols clipped or merged')
end)
test('CENTRAL automatically renders centered structures and highlighted equipment',function()
    local t=setup();local v=t.viewer();assert(v.command('view','structure'));t.finish()
    assert(t.pixels['22,15,22']==1,'light structure absent or off center')
    assert(t.pixels['26,17,26']==1,'heavy structural context absent or off center')
    assert(t.pixels['24,16,24']==3,'equipment not highlighted')
    assert(v.status():find('DISPLAYED',1,true) and v.status():find('INTEL-1',1,true),v.status())
    local clears=t.state.clears;for _=1,30 do t.step()end
    assert(t.state.clears==clears,'unchanged scan redraws continuously')
end)
test('tier one renders the same geometry without invalid palette calls',function()
    local t=setup(1);local v=t.viewer();assert(v.command('view','structure'));t.finish()
    assert(t.pixels['22,15,22']==1 and t.pixels['26,17,26']==1 and t.pixels['24,16,24']==1)
    assert(t.palettes[2]==nil and t.palettes[3]==nil)
end)
test('a missing or ambiguous projector does not fetch data or break scans',function()
    local t=setup();t.devices.holo=nil;local v=t.viewer();t.finish()
    assert(#t.requests==0 and t.state.clears==0)
    assert(v.status():find('projector',1,true),v.status())
end)
test('delayed packets cannot overwrite a newer scan and retries have a limit',function()
    local t=setup();local v=t.viewer();t.state.state='COMPLETE';t.step(false)
    local old=t.requests[1];assert(old,'model request missing')
    local newer={id='boot-A:99',session='boot-A',sequence=99,summary='COMBINED;20;30;100%'}
    v.offer('INTEL-1',newer)
    v.receive('INTEL-1',old[3],old[4],old[5],'0,0,0,1',true)
    assert(t.state.clears==0,'stale response changed display')
    for _=1,130 do t.step(false)end
    assert(#t.requests<=4,'unbounded page retries')
    assert(v.status():find('TIMEOUT',1,true),v.status())
end)
test('large world extents keep uniform proportions within projector bounds',function()
    local t=setup();local v=t.viewer();assert(v.command('view','structure'))
    t.sat.intelStructuralPage=function()return true,2,'-30000,0,-40000,hbm:a,0,8,LIGHT|30000,255,40000,hbm:b,0,84,HEAVY' end
    t.sat.intelFindingCount=function()return 0 end
    t.finish();local count=0;for _ in pairs(t.pixels)do count=count+1 end
    assert(count==2,'large scan lost sampled cells')
end)
test('full structural pages preserve false completion flags and fetch the next page',function()
    local t=setup();local v=t.viewer();local pages={}
    t.sat.intelStructuralPage=function(page)
        pages[page]=true
        if page==1 then
            local cells={};for x=1,64 do cells[#cells+1]=x..',40,0,hbm:wall,0,8,LIGHT' end
            return true,64,table.concat(cells,'|')
        end
        return true,1,'65,40,0,hbm:concrete,0,84,HEAVY'
    end
    t.sat.intelFindingCount=function()return 0 end
    t.finish()
    assert(pages[2],'full page was mistaken for end of scan or rejected')
    assert(v.status():find('DISPLAYED',1,true),v.status())
    assert(t.pixels['46,16,24']==1,'last page absent from model')
end)
test('clear stays cleared until a new scan or explicit show',function()
    local t=setup();local v=t.viewer();t.finish();assert(v.command('clear'))
    for _=1,20 do t.step()end
    assert(next(t.pixels)==nil,'cleared model reappeared')
    assert(v.command('show','INTEL-1'));for _=1,100 do t.step()end
    assert(next(t.pixels),'show did not restore completed scan')
end)
test('empty scans clear stale geometry and explicitly report an empty model',function()
    local t=setup();local v=t.viewer();t.finish();assert(next(t.pixels))
    t.runtime.onMessage('CENTRAL','SCAN',102,202,'new');t.step()
    t.sat.intelStructuralPage=function()return false,'OUT_OF_RANGE' end
    t.sat.intelFindingCount=function()return 0 end
    t.finish()
    assert(next(t.pixels)==nil,'empty scan retained old geometry')
    assert(v.status():find('EMPTY',1,true),v.status())
end)
test('malformed pages leave the previous display intact',function()
    local t=setup();local v=t.viewer();t.finish();local clears=t.state.clears
    assert(v.command('show','INTEL-1'));t.step(false);local request=t.requests[#t.requests]
    v.receive('INTEL-1',request[3],request[4],request[5],'nan,0,0,1',true)
    assert(t.state.clears==clears and next(t.pixels),'malformed response destroyed prior model')
    assert(v.status():find('ERROR',1,true),v.status())
end)
test('drawing work is bounded and unplugging the projector is recoverable',function()
    local t=setup();local v=t.viewer()
    t.sat.intelGetFinding=function()return true,'SILO_HATCH',1,100,40,200,140,60,240,false,true,false,true,false,'SILO_HATCH','hbm:silo',1 end
    t.state.state='COMPLETE'
    for _=1,100 do local before=t.state.writes;t.step();assert(t.state.writes-before<=64,'drawing monopolized the event loop')end
    assert(v.status():find('DISPLAYED',1,true),v.status())
    t.devices.holo=nil;assert(v.command('show','INTEL-1'));t.step()
    assert(v.status():find('projector',1,true),v.status())
end)
if failures>0 then error(failures..' hologram tests failed') end
