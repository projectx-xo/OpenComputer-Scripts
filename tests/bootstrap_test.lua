local source = assert(io.open('bootstrap/bootstrap.lua')):read('*a')
local function run(steps, files, options, faults)
    files = files or {}
    if not files._missingConfig then files['/home/stratcom/config.lua'] = 'config' end
    local sent, metrics, clock, cursor = {}, {starts=0,stops=0}, 0, 0
    local env = setmetatable({}, {__index=_G})
    env.io = {stderr=io.stderr, open=function(path,mode)
        if mode == 'r' and not files[path] then return end
        if mode == 'w' then files[path]='' end
        return {read=function(_,fmt) if fmt=='*l' then return files[path]:match('[^\n]+') end return files[path] end,
          write=function(_,s) files[path]=files[path]..s; return true end,
          flush=function() if files._flushFail == path then return nil,"disk full" end; return true end,
          close=function() if files._closeFail == path then files._closeFail=nil; return nil,"close failed" end end}
    end}
    local fs = {exists=function(p) return files[p]~=nil end, makeDirectory=function() end, remove=function(p) files[p]=nil; return true end, rename=function(a,b) if faults and faults[a] then return false,"rename failed" end files[b]=files[a];files[a]=nil;return true end}
    local serial = {serialize=function(x) if type(x)=="table" and x.id and not x.protocol then return '{id="'..x.id..'"}' end return x end,unserialize=function(x)return x end}
    env.loadfile=function(path) return load(files[path] or '',path,'t',env) end
    env.dofile=function() return files._configTable or {id='N1',role='RADAR'} end
    env.metrics=metrics
    env.print=function() end
    local modem={open=function()end,close=function()end,broadcast=function(_,_,e)sent[#sent+1]=e end}
    local component={}
    component.list=function(kind)
        local values = files._components and files._components[kind] or (kind == 'modem' and {'modem'} or {})
        local index=0
        return function()index=index+1;return values[index]end
    end
    component.proxy=function(address)return files._proxies and files._proxies[address] or modem end
    component.invoke=function(address,method,...)return component.proxy(address)[method](...)end
    local modules={filesystem=fs,serialization=serial,computer={uptime=function()return clock end,address=function()return 'computer-12345678' end},keyboard={keys={c=46},isControlDown=function()return true end},component=component}
    modules.event={pull=function()
        cursor=cursor+1;clock=clock+1
        local s=steps[cursor]
        if not s then return 'key_down',nil,nil,46 end
        if type(s)=='function' then s(files,sent,metrics);return end
        if type(s)=='number' then clock=clock+s;return end
        return 'modem_message',nil,nil,s.port or 4510,nil,'STRATCOM_NET',{protocol=2,id=tostring(cursor),source='CENTRAL',destination=s.destination or 'N1',kind=s.kind or 'MGMT',ttl=1,payload=s}
    end}
    env.require=function(n)return assert(modules[n],n)end
    assert(load(source,'bootstrap','t',env))(options)
    return files,sent,metrics
end
local base='/home/stratcom/runtime/'
local good='return {start=function(ctx) metrics.starts=metrics.starts+1 end,stop=function() metrics.stops=metrics.stops+1 end,status=function() return "fine" end}'
local function files()return {[base..'current.lua']=good,[base..'version.txt']='old\n'}end
local function eq(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local tests={}
tests.transfer_keeps_runtime=function()
 run({{'CLAIM'},{'START'},{'DEPLOY_BEGIN','new',1,'t'},function(_,_,m)eq(m.stops,0)end,{'DEPLOY_ABORT','t'},function(f)eq(f[base..'incoming.lua'],nil)end},files())
end
tests.failed_candidate_rolls_back=function()
 local f,s,m=run({{'CLAIM'},{'START'},{'DEPLOY_BEGIN','new',1,'t'},{'DEPLOY_CHUNK',1,'return {start=function() error("bad") end,stop=function() metrics.stops=metrics.stops+1 end}','t'},{'DEPLOY_COMMIT','new','t'},function(f)eq(f[base..'current.lua'],good);eq(f[base..'version.txt'],'old\n')end},files())
 eq(m.starts,2)
end
tests.duplicate_commit=function()
 local f,s=run({{'CLAIM'},{'START'},{'DEPLOY_BEGIN','new',1,'t'},{'DEPLOY_CHUNK',1,good,'t'},{'DEPLOY_BEGIN','new',1,'t'},{'DEPLOY_COMMIT','new','t'},{'DEPLOY_COMMIT','new','t'}},files())
 local n=0 for _,e in ipairs(s)do if e.kind=='MGMT_DEPLOY_RESULT' then eq(e.payload[1],true);eq(e.payload[4],'t');n=n+1 end end eq(n,2)
end
tests.timeout_and_malformed=function()
 run({{'CLAIM'},{'DEPLOY_BEGIN','new',1,'t'},65,function(f)eq(f[base..'incoming.lua'],nil)end,{'DEPLOY_BEGIN','new',1.5,'x'},function(f)eq(f[base..'incoming.lua'],nil)end},files())
end
tests.stop_survives_restart=function()
 local f=run({{'CLAIM'},{'START'},{'STOP'}},files())
 local _,_,m=run({},f);eq(m.starts,0)
 eq(f['/home/stratcom/node-state.txt'],'stopped\n')
end
tests.invalid_transfer_cleans_up=function()
 run({{'CLAIM'},{'DEPLOY_BEGIN','new',1,'t'},{'DEPLOY_CHUNK',2,good,'t'},function(f,_,m)eq(f[base..'incoming.lua'],nil);eq(m.stops,0)end},files())
end
tests.checksum_rejection=function()
 run({{'CLAIM'},{'DEPLOY_BEGIN','new',1,'t','00000000'},{'DEPLOY_CHUNK',1,good,'t'},{'DEPLOY_COMMIT','new','t'},function(f,_,m)eq(f[base..'current.lua'],good);eq(m.stops,0);eq(f[base..'incoming.lua'],nil)end},files())
end
tests.status_token_and_context=function()
 local f=files()
 f[base..'current.lua']='return {start=function(ctx) assert(ctx.config.id=="N1"); assert(type(ctx.saveConfig)=="function"); assert(type(ctx.session)=="string") end,status=function(detail) return detail end}'
 local _,sent=run({{'CLAIM'},{'STATUS','full','request',port=4511,kind='CMD'}},f)
 local found=false
 for _,e in ipairs(sent)do if e.kind=='RUNTIME' and e.payload[1]=='STATUS' then eq(e.payload[2],'full');eq(e.payload[3],'request');found=true end end
 eq(found,true)
end
tests.stopped_deploy_remains_stopped=function()
 run({{'CLAIM'},{'STOP'},{'DEPLOY_BEGIN','new',1,'t'},{'DEPLOY_CHUNK',1,good,'t'},{'DEPLOY_COMMIT','new','t'},function(f,s,m)eq(m.starts,2);eq(m.stops,2);eq(f['/home/stratcom/node-state.txt'],'stopped\n');eq(f[base..'previous-version.txt'],'old\n')end},files())
end
tests.service_queue_and_shutdown=function()
 local commands={{id=1,line='maintenance'},{id=2,line='status'},{id=3,line='start'},{id=4,line='scan status'}}
 local replies,ready,index={},false,0
 local f=files()
 f[base..'current.lua']='return {start=function(ctx) metrics.starts=metrics.starts+1; metrics.ctx=ctx end,stop=function() metrics.stops=metrics.stops+1 end,status=function() return "healthy" end,onMessage=function(source,command) metrics.ctx.send(source,command,"ready") end}'
 local _,_,m=run({1,1,1,1},f,{ready=function()ready=true end,log=function()end,stopping=function()return index>=4 end,nextCommand=function()index=index+1;return commands[index]end,reply=function(id,ok,text)replies[id]={ok,text}end})
 eq(ready,true);eq(replies[1][2],'maintenance');assert(replies[2][2]:find('intent=maintenance',1,true));eq(replies[4][2],'SCAN_STATUS ready');eq(m.stops,2)
end
tests.runtime_arguments_and_hello=function()
 local f=files()
 f[base..'current.lua']='return {start=function(ctx) metrics.session=ctx.session end,onMessage=function(source,cmd,a,b,c,d,e) assert(cmd=="MAP");assert(a=="a");assert(b=="b");assert(c=="c");assert(d=="d");assert(e=="e");metrics.forwarded=true end}'
 local _,sent,m=run({{'CLAIM'},{'MAP','a','b','c','d','e',port=4511,kind='CMD'}},f)
 eq(m.forwarded,true)
 local found=false
 for _,e in ipairs(sent) do if e.kind=='BOOT_HELLO' then eq(e.payload[6],'running');eq(e.payload[7],m.session);found=true end end
 eq(found,true)
end
tests.config_save_preserves_previous=function()
 local f=files()
 f[base..'current.lua']='return {start=function(ctx) metrics.saved=ctx.saveConfig({id="NEW"}) end}'
 local saved,_,m=run({},f)
 eq(m.saved,true);eq(saved['/home/stratcom/config.lua'],'return {id="NEW"}\n');eq(saved['/home/stratcom/config.lua.previous'],'config')
 local f2=files()
 f2[base..'current.lua']=f[base..'current.lua']
 local restored,_,m2=run({},f2,nil,{['/home/stratcom/config.lua.pending']=true})
 eq(m2.saved,false);eq(restored['/home/stratcom/config.lua'],'config');eq(restored['/home/stratcom/config.lua.pending'],nil)
end
tests.automatic_enrollment_classifies_abm_and_persists_assignment=function()
 local f={_configTable={autoEnroll=true},_components={modem={'modem'},ntm_launch_pad={'pad'}},
  _proxies={pad={getPayloadIdentity=function()return 'anti_ballistic'end}}}
 local disk,sent=run({{[1]='ASSIGN',[2]='computer-12345678',[3]='ABM-A1',[4]='defense',destination='PENDING-COMPUTER'},
  {[1]='CLAIM',destination='ABM-A1'}},f)
 assert(disk['/home/stratcom/config.lua']:find('ABM%-A1'))
 local enrolled,hello=false,false
 for _,e in ipairs(sent)do
  if e.kind=='ENROLL_ACK' and e.source=='ABM-A1' then enrolled=true end
  if e.kind=='BOOT_HELLO' and e.source=='ABM-A1' and e.payload[2]=='defense' then hello=true end
 end
 assert(enrolled and hello,'assignment did not become active')
end
tests.interrupted_activation_restores_matching_runtime_and_version=function()
 local f=files()
 f[base..'current.lua']='return {start=function() error("unconfirmed") end}'
 f[base..'previous.lua']=good; f[base..'previous-version.txt']='old\n'
 f[base..'activation.txt']='new\n'; f[base..'version.txt']='new\n'
 local disk,_,m=run({},f)
 eq(disk[base..'current.lua'],good);eq(disk[base..'version.txt'],'old\n');eq(m.starts,1)
 eq(disk[base..'activation.txt'],nil)
end
tests.interrupted_config_save_recovers_backup=function()
 local f=files();f._missingConfig=true;f['/home/stratcom/config.lua.previous']='config'
 local disk,_,m=run({},f);eq(m.starts,1);eq(disk['/home/stratcom/config.lua'],'config')
end
tests.corrupt_intent_does_not_enable_runtime=function()
 local f=files();f['/home/stratcom/node-state.txt']=''
 local _,_,m=run({},f);eq(m.starts,0)
end
tests.failed_staging_close_keeps_old_runtime=function()
 local f=files();f._closeFail=base..'incoming.lua'
 run({{'CLAIM'},{'DEPLOY_BEGIN','new',1,'t'},{'DEPLOY_CHUNK',1,good,'t'}, {'DEPLOY_COMMIT','new','t'},function(d,_,m)eq(d[base..'version.txt'],'old\n');eq(m.stops,0)end},f)
end
tests.failed_staging_flush_keeps_old_runtime=function()
 local f=files();f._flushFail=base..'incoming.lua'
 run({{'CLAIM'},{'DEPLOY_BEGIN','new',1,'t'},{'DEPLOY_CHUNK',1,good,'t'}, {'DEPLOY_COMMIT','new','t'},function(d,_,m)eq(d[base..'current.lua'],good);eq(d[base..'version.txt'],'old\n');eq(m.stops,0)end},f)
end
tests.first_tick_failure_rolls_back_before_success=function()
 local bad='return {start=function() end,tick=function()error("tick failed")end,stop=function()end}'
 local f,s=run({{'CLAIM'},{'DEPLOY_BEGIN','new',1,'t'},{'DEPLOY_CHUNK',1,bad,'t'}, {'DEPLOY_COMMIT','new','t'}},files())
 eq(f[base..'current.lua'],good);eq(f[base..'version.txt'],'old\n')
 for _,e in ipairs(s)do if e.kind=='MGMT_DEPLOY_RESULT' then eq(e.payload[1],false)end end
end
tests.local_map_builds_runtime_mapping_payload=function()
 local f=files();local done=false;local reply
 f[base..'current.lua']='return {start=function(ctx) metrics.ctx=ctx end,onMessage=function(remote,command,mapping) assert(command=="MAP" and type(mapping)=="table" and mapping.label=="Bravo" and mapping.side==2 and mapping.slot==3);metrics.ctx.send(remote,"HARDWARE","saved")end}'
 run({},f,{ready=function()end,stopping=function()return done end,nextCommand=function()done=true;return{id=1,line='map Bravo pad inventory 2 3'}end,reply=function(_,ok,text)reply={ok,text}end})
 eq(reply[1],true);assert(reply[2]:find('saved',1,true))
end
tests.automatic_enrollment_classifies_nuclear_satellite=function()
 local f={_configTable={autoEnroll=true},_components={modem={'modem'},ntm_satlink={'station'}},
  _proxies={station={getType=function()return 'NUCLEAR_DETECTION'end,open=function()end}}}
 local disk,sent=run({{[1]='ASSIGN',[2]='computer-12345678',[3]='NUC-1',[4]='nuclear',destination='PENDING-COMPUTER'}},f)
 local assigned=false
 for _,e in ipairs(sent)do if e.kind=='ENROLL_ACK' and e.source=='NUC-1' then assigned=true end end
 assert(assigned,'nuclear satellite was not automatically assigned')
end
tests.team_asset_reply_is_separate_from_status=function()
 local f=files();f._components={modem={'modem'},ntm_radar={'radar'}}
 f._proxies={radar={getTeamIdentity=function()return 'Blue','RADAR-01',12,64,30,0,'BASECENTER','Tester'end}}
 f[base..'current.lua']='return {start=function()end,status=function()return {ready=true}end}'
 local _,sent=run({{'CLAIM'},{'STATUS','full','request',port=4511,kind='CMD'}},f)
 local status,identity
 for _,e in ipairs(sent)do
  if e.kind=='RUNTIME' and e.payload[1]=='STATUS' then status=e.payload[2] end
  if e.kind=='RUNTIME' and e.payload[1]=='TEAM_ASSETS' then identity=e.payload[2] end
 end
 assert(status and not status.teamAssets and identity and identity.session)
 assert(identity.teamAssets[1].team=='Blue' and identity.teamAssets[1].x==12)
end
local failed=0
for name,test in pairs(tests)do local ok,err=pcall(test);print((ok and 'PASS ' or 'FAIL ')..name..(ok and '' or ': '..err));if not ok then failed=failed+1 end end
assert(failed==0,tostring(failed)..' failures')
