local function read(p) local f=assert(io.open(p));local s=f:read('*a');f:close();return s end
local sources={update=read('service/update.lua')}
local function harness()
 local files,net,threads={}, {}, {};local clock,http=0,0
 local env=setmetatable({}, {__index=_G})
 env.io={open=function(p,m)
  if m=='r' and files[p]==nil then return nil,'missing' end
  if m=='w' then files[p]='' end
  return {read=function(_,fmt)return fmt=='*l' and files[p]:match('[^\n]+') or files[p]end,write=function(_,s)files[p]=files[p]..s;return true end,close=function()return true end}
 end}
 local fs={exists=function(p)return files[p]~=nil end,makeDirectory=function(p)if files[p] then return nil,'already exists' end files[p]=true;return true end,remove=function(p)files[p]=nil;return true end,rename=function(a,b)if files[a]==nil then return nil,'missing' end files[b]=files[a];files[a]=nil;return true end}
 local mods={filesystem=fs,computer={uptime=function()return clock end},internet={request=function(url)http=http+1;local s=net[url];if not s then error('offline')end;return function()local x=s;s=nil;return x end end}}
 env.require=function(n)return assert(mods[n],n)end
 env.loadfile=function(p)return load(files[p]or'',p,'t',env)end
 env.dofile=function(p)return assert(env.loadfile(p))()end
 mods.event={pull=function(t)coroutine.yield(t or 0.1)end}
 mods.thread={create=function(fn)local t={co=coroutine.create(fn)};function t:status()return self.dead and 'dead' or coroutine.status(self.co)=='dead' and 'dead' or 'running'end;function t:kill()self.dead=true end;function t:detach()self.detached=true;return self end;threads[#threads+1]=t;return t end}
 local function step(n)for i=1,n do clock=clock+1;for _,t in ipairs(threads)do if t:status()=='running' then local ok,e=coroutine.resume(t.co);assert(ok,e)end end end end
 local u=assert(load(sources.update,'update','t',env))();mods['stratcom.update']=u
 return {files=files,net=net,env=env,mods=mods,u=u,step=step,http=function()return http end}
end
local function eq(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local paths={'central/central.lua','bootstrap/bootstrap.lua','runtime/manifest.lua','runtime/strike.lua','runtime/launchpad.lua','runtime/radar.lua','runtime/intel.lua','service/stratcom.lua','service/update.lua','service/rc.lua','service/console.lua','install.lua'}
local sha=string.rep('a',40)
local function release(h,v,app)
 local parts={'return {version="'..v..'",ref="'..sha..'",files={'}
 for _,p in ipairs(paths)do local s=p=='central/central.lua' and (app or 'return true')or (p=='runtime/manifest.lua' and 'return {roles={radar={path="runtime/radar.lua",version="1.0.0"}}}' or 'return {}');h.net['https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/'..sha..'/'..p]=s;parts[#parts+1]='["'..p..'"]={size='..#s..',checksum="'..h.u.checksum(s)..'"},'end
 parts[#parts+1]='}}';h.net[h.u.defaultSource]=table.concat(parts);return table.concat(parts)
end
local tests={}
function tests.download_failure_retains_current()
 local h=harness();h.files['/home/stratcom/current.txt']='old';release(h,'new');h.net['https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/'..sha..'/runtime/radar.lua']=nil
 local b,e=h.u.stage();eq(b,nil);assert(e);eq(h.files['/home/stratcom/current.txt'],'old')
end
function tests.validation_and_transaction()
 local h=harness();release(h,'new');local b=assert(h.u.stage());eq(b,'new');assert(h.u.activate(b));eq(h.u.current(),'new');assert(h.u.confirm());release(h,'bad','this is not lua');eq(h.u.stage(),nil);eq(h.u.current(),'new')
 release(h,'next');assert(h.u.stage());assert(h.u.activate('next'));eq(h.u.current(),'next');assert(h.u.recover());eq(h.u.current(),'new')
end
function tests.checksum_and_manifest_rejection()
 local h=harness();release(h,'x');h.net['https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/'..sha..'/central/central.lua']='return false';eq(h.u.stage(),nil)
 h.net[h.u.defaultSource]='return {version="x",version="y"}';eq(h.u.stage(),nil)
end
local function service(h)
 local m=assert(load(read('service/stratcom.lua'),'service','t',h.env))();h.mods['stratcom.service']=m;return m
end
local function installed(h,app)
 release(h,'old',app);assert(h.u.stage());assert(h.u.activate('old'));assert(h.u.confirm())
 h.files['/home/stratcom/service-config.lua']='return {kind="central",autoUpdate=false}'
end
function tests.offline_ready_commands_and_detach()
 local h=harness();installed(h,'local o=...;o.ready();while not o.stopping() do local c=o.nextCommand();if c then o.reply(c.id,true,"actual "..c.line)end;require("event").pull(0.1)end')
 local before=h.http();local s=service(h);assert(s.start());h.step(5);eq(s.status().state,'running');eq(h.http(),before)
 local id=assert(s.submit('status'));h.step(2);local r=assert(s.result(id));eq(r.text,'actual status')
 h.mods.term={read=function()return 'quit\n'end};h.env.print=function()end;h.env.io.write=function()end
 assert(load(read('service/console.lua'),'console','t',h.env))();eq(s.status().state,'running')
 assert(s.stop());h.step(5);eq(s.status().state,'stopped')
end
function tests.startup_failure_rolls_back_and_backoff_is_bounded()
 local h=harness();installed(h,'local o=...;o.ready();while not o.stopping() do require("event").pull(0.1)end')
 release(h,'bad','error("candidate crash")');assert(h.u.stage());assert(h.u.activate('bad'))
 local s=service(h);assert(s.start());h.step(15);eq(h.u.current(),'old');eq(s.status().state,'running')
 local h2=harness();installed(h2,'error("crash")');local s2=service(h2);assert(s2.start());h2.step(400);eq(s2.status().state,'failed');eq(s2.status().failures,5);assert(s2.stop());eq(s2.status().state,'stopped')
end
function tests.install_preserves_config_and_rejects_role_change()
 local h=harness();release(h,'old');h.env.package={loaded={}};h.env.print=function()end
 local executions={};h.mods.shell={execute=function(s)executions[#executions+1]=s;return true end}
 h.mods['stratcom.service']={start=function()return true end}
 h.files['/home/stratcom/config.lua']='return {id="N1",role="radar",custom="keep"}'
 h.files['/home/stratcom/runtime/current.lua']='saved runtime';h.files['/home/stratcom/runtime/version.txt']='saved version'
 local install=assert(load(read('install.lua'),'install','t',h.env))
 install('node','radar','N1');eq(h.files['/home/stratcom/config.lua'],'return {id="N1",role="radar",custom="keep"}')
 eq(h.files['/home/stratcom/runtime/current.lua'],'saved runtime');eq(executions[1],'rc stratcom enable')
 local ok=pcall(install,'node','strike','N1');eq(ok,false)
end
function tests.post_ready_crash_rolls_back()
 local h=harness();installed(h,'local o=...;o.ready();while not o.stopping() do require("event").pull(0.1)end')
 local s=service(h);assert(s.start());h.step(4)
 release(h,'bad','local o=...;o.ready();require("event").pull(0.1);error("late crash")');assert(h.u.stage())
 assert(s.apply('bad'));h.step(30);eq(h.u.current(),'old');eq(s.status().state,'running')
 eq(h.files['/home/stratcom/rejected.txt'],'bad')
end
function tests.fresh_install_seeds_runtime_and_offline_boot()
 local h=harness();release(h,'fresh');h.env.package={loaded={}};h.env.print=function()end
 h.mods.shell={execute=function()return true end};h.mods['stratcom.service']={start=function()return true end}
 assert(load(read('install.lua'),'install','t',h.env))('node','radar','R1')
 eq(h.files['/home/stratcom/runtime/current.lua'],'return {}');eq(h.files['/home/stratcom/runtime/version.txt'],'1.0.0\n')
 eq(h.u.current(),'fresh');eq(h.u.pending(),nil)
end
function tests.interrupted_pointer_write_recovers_old()
 local h=harness();release(h,'old');assert(h.u.stage());assert(h.u.activate('old'));assert(h.u.confirm())
 release(h,'new');assert(h.u.stage())
 local rename=h.mods.filesystem.rename
 h.mods.filesystem.rename=function(a,b)if b=='/home/stratcom/current.txt' then return nil,'power loss' end return rename(a,b)end
 eq(h.u.activate('new'),nil);eq(h.u.current(),'old')
 h.mods.filesystem.rename=rename;assert(h.u.recover());eq(h.u.current(),'old');eq(h.u.pending(),nil)
end
function tests.background_download_waits_for_ready_and_idle()
 local h=harness();installed(h,'local o=...;o.setBusy(true);require("event").pull(0.1);require("event").pull(0.1);o.ready();while not o.stopping() do local c=o.nextCommand();if c then o.reply(c.id,true,"idle");o.setBusy(false)end;require("event").pull(0.1)end')
 h.files['/home/stratcom/service-config.lua']='return {kind="central",autoUpdate=true}'
 release(h,'new','local o=...;o.ready();while not o.stopping() do require("event").pull(0.1)end')
 local before=h.http();local s=service(h);assert(s.start());h.step(1);eq(h.http(),before)
 h.step(8);assert(h.http()>before);eq(h.u.current(),'old');eq(s.status().candidate,'new')
 assert(s.submit('idle'));h.step(30);eq(h.u.current(),'new');eq(h.u.pending(),nil);eq(s.status().state,'running')
end
function tests.hourly_checks_retry_offline_only_at_interval()
 local h=harness();installed(h,'local o=...;o.ready();while not o.stopping() do require("event").pull(0.1)end')
 h.files['/home/stratcom/service-config.lua']='return {kind="central",autoUpdate=true}'
 h.net[h.u.defaultSource]=nil
 local before=h.http();local s=service(h);assert(s.start());h.step(10);eq(h.http(),before+1)
 h.step(3500);eq(h.http(),before+1);h.step(100);eq(h.http(),before+2)
 h.step(100);eq(h.http(),before+2);eq(s.status().state,'running')
end
local function localBundle(h)
 local raw=release(h,'offline')
 local dummy='return {}'
 local old='["service/update.lua"]={size='..#dummy..',checksum="'..h.u.checksum(dummy)..'"}'
 local new='["service/update.lua"]={size='..#sources.update..',checksum="'..h.u.checksum(sources.update)..'"}'
 local a,b=assert(raw:find(old,1,true));raw=raw:sub(1,a-1)..new..raw:sub(b+1)
 h.files['/media/release/release.lua']=raw
 for _,path in ipairs(paths)do h.files['/media/release/'..path]=h.net['https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/'..sha..'/'..path]end
 h.files['/media/release/service/update.lua']=sources.update
end
function tests.offline_install_bootstraps_local_updater_without_network()
 local h=harness();localBundle(h);h.mods['stratcom.update']=nil
 h.env.package={loaded={}};h.env.print=function()end
 local enabled=false;h.mods.shell={execute=function(command)eq(command,'rc stratcom enable');enabled=true;return true end}
 h.mods['stratcom.service']={start=function()return true end}
 assert(load(read('install.lua'),'install','t',h.env))('node','radar','R1','--bundle','/media/release')
 eq(h.http(),0);assert(enabled);eq(h.u.current(),'offline')
 eq(h.files['/home/stratcom/runtime/current.lua'],'return {}');eq(h.files['/home/stratcom/runtime/version.txt'],'1.0.0\n')
 local c=assert(h.env.loadfile('/home/stratcom/service-config.lua'))();eq(c.autoUpdate,false)
 h.files['/home/stratcom/config.lua']='return {id="R1",role="radar",mapping="preserved"}'
 h.files['/home/stratcom/runtime/current.lua']='saved runtime'
 h.files['/home/stratcom/runtime/version.txt']='saved version'
 assert(load(read('install.lua'),'install','t',h.env))('node','radar','R1','--bundle','/media/release')
 eq(h.files['/home/stratcom/config.lua'],'return {id="R1",role="radar",mapping="preserved"}')
 eq(h.files['/home/stratcom/runtime/current.lua'],'saved runtime')
 eq(h.files['/home/stratcom/runtime/version.txt'],'saved version');eq(h.http(),0)
end
function tests.fresh_online_install_passes_nil_request_body_to_openos_internet_api()
 local h=harness();local branch='https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/codex/stratcom-reliability/'
 local raw=release(h,'fresh');h.net[branch..'release.lua']=raw;h.net[branch..'service/update.lua']=sources.update
 h.mods['stratcom.update']=nil;h.env.package={loaded={}};h.env.print=function()end
 h.env.loadfile=function(path)
  if path=='service/update.lua' then return nil end
  return load(h.files[path] or '',path,'t',h.env)
 end
 h.mods.shell={execute=function()return true end};h.mods['stratcom.service']={start=function()return true end}
 local calls=0
 h.mods.internet.request=function(url,body)
  calls=calls+1;assert(body==nil,'OpenOS internet.request received gsub replacement count as body')
  local content=h.net[url];assert(content,'missing fixture for '..url);local sent=false
  return function()if sent then return end;sent=true;return content end
 end
 local install=assert(load(read('install.lua'),'install','t',h.env))
 install('node','radar','R1','--source',branch..'release.lua')
 assert(calls>=1,'fallback updater was not fetched')
end
function tests.local_bundle_rejects_corrupt_files()
 local h=harness();localBundle(h);h.files['/media/release/runtime/radar.lua']='broken'
 local v,e=h.u.stageLocal('/media/release');eq(v,nil);assert(e);eq(h.u.current(),nil);eq(h.http(),0)
end
function tests.hourly_check_does_not_overlap_slow_download()
 local h=harness();installed(h,'local o=...;o.ready();while not o.stopping() do require("event").pull(0.1)end')
 h.files['/home/stratcom/service-config.lua']='return {kind="central",autoUpdate=true}'
 local request=h.mods.internet.request
 h.mods.internet.request=function(url)
  local iterator=request(url)
  return function()for i=1,3700 do h.mods.event.pull(0.1)end;return iterator()end
 end
 local before=h.http();local s=service(h);assert(s.start());h.step(3650)
 eq(h.http(),before+1);eq(s.status().state,'running');assert(s.stop())
end
function tests.update_waits_for_inflight_operator_command()
 local h=harness();installed(h,'local o=...;o.ready();while not o.stopping() do local c=o.nextCommand();if c then for i=1,20 do require("event").pull(0.1)end;o.reply(c.id,true,"finished")end;require("event").pull(0.1)end')
 local s=service(h);assert(s.start());h.step(5)
 local id=assert(s.submit('operation'));h.step(1)
 release(h,'new','local o=...;o.ready();while not o.stopping() do require("event").pull(0.1)end');assert(h.u.stage());assert(s.apply('new'))
 h.step(10);eq(h.u.current(),'old')
 h.step(40);eq(h.u.current(),'new');local reply=assert(s.result(id));eq(reply.ok,true);eq(reply.text,'finished')
end
for n,t in pairs(tests)do t();print('PASS '..n)end
