local model=assert(loadfile('ui/node_status_model.lua'))()
local snapshot={id='SILO-S1',role='strike',bootstrap='3.5.0',runtime='3.3.0',state='running',intent='running',controller='CENTRAL',centralAge=1,
 assets={{source='BASECENTER',team='Blue'}},health={multiLauncher=true,readyCount=2,launcherCount=2,armedCount=0,strikeRemaining=0,
 launchers={{index=1,missileLabel='Bunker Buster',ready=true,armed=false},{index=2,missileLabel='Stealth Missile',ready=true,armed=false}}}}
local rows=model(snapshot,{state='running',version='3.11.0',update='up to date'},'event one\nevent two',0)
local text='';for _,r in ipairs(rows)do text=text..r.text..'\n' end
assert(text:find('RECENT CONTACT',1,true) and text:find('Stealth Missile',1,true) and not text:find('Team:',1,true))
rows=model(snapshot,{state='running'},'',20);assert(rows[6].text:find('NO RECENT CONTACT',1,true),'stale central contact stayed online')
local function run(exitChar,width,height,resize,reload)
 local clock,submitted,stopped,pulls=0,0,0,0
 local version="3.11.0"
 local fg,bg,blink=0xFFFFFF,0,true
 local grid,captured={},nil
 local gpu={getForeground=function()return fg,false end,getBackground=function()return bg,false end,
  setForeground=function(c)fg=c end,setBackground=function(c)bg=c end,
  set=function(x,y,s)assert(x==1 and y>=1 and y<=height and #s==width,'out-of-bounds draw');grid[y]={text=s,color=fg}end}
 local term={gpu=function()return gpu end,isAvailable=function()return true end,
  getCursor=function()return 1,1 end,getCursorBlink=function()return blink end,setCursorBlink=function(v)blink=v end,
  getViewport=function()return width,height,0,0 end,clear=function()end,setCursor=function()end}
 local service={status=function()return{state='running',version=version,update='up to date'}end,
  submit=function(command)assert(command=='snapshot','dashboard sent a control command');submitted=submitted+1;return submitted end,
  result=function()return{ok=true,text='snapshot'}end,logs=function()return'Connected to CENTRAL'end,
  stop=function()stopped=stopped+1 end}
 local modules={term=term,computer={uptime=function()return clock end},serialization={unserialize=function()return snapshot end},
  unicode={len=string.len,wlen=string.len,sub=string.sub},event={pull=function()
   clock=clock+.25;pulls=pulls+1
   if reload and pulls==2 then version="3.12.0";return end
   if resize and pulls==1 then width,height=30,10;grid={};return end
   if pulls>=3 then captured=grid;return 'key_down','keyboard',exitChar,0 end
  end}}
 local env=setmetatable({require=function(n)return assert(modules[n],n)end},{__index=_G})
 local view=assert(loadfile('ui/node_status.lua','t',env))()
 local result=view(service,model)
 assert(fg==0xFFFFFF and bg==0 and blink==true,'terminal settings not restored')
 assert(stopped==0 and submitted>0,'view stopped service or never polled')
 return result,captured
end
local result,capture=run(99,80,25);assert(result=='console')
assert(run(113,80,25,false,true)=='reload','bundle update did not reload dashboard');
assert(run(113,40,12)=='detach');assert(run(113,8,3)=='detach');assert(run(113,80,25,true)=='detach')
local f=assert(io.open('work/dashboard-preview.txt','w'))
for _,row in ipairs(capture)do f:write(row.text,'\n')end;f:close()
local colors=assert(io.open('work/dashboard-preview.colors','w'));for _,row in ipairs(capture)do colors:write(string.format('%06x',row.color),'\n')end;colors:close()
print('PASS node dashboard: role details, stale contact, bounded drawing, resize, C/Q controls, settings restoration and read-only polling')

local source=assert(io.open('service/console.lua')):read('*a')
for _,kind in ipairs({'node','central'})do
 for _,mode in ipairs({'dashboard','console'})do
 local shown,read=0,0
 local service={start=function()return true end,status=function()return{version='new'}end,alerts=function()return{},0,0 end}
 local modules={['stratcom.service']=service,event={},computer={},term={read=function()read=read+1;return'quit'end}}
 local env=setmetatable({print=function()end,io={write=function()end},require=function(n)return modules[n]end,
  loadfile=function(path)
   if path:find('service-config',1,true)then return function()return{kind=kind}end end
   if path:find('node_status_model',1,true)then return function()return model end end
   return function()return function()shown=shown+1;return'detach'end end
  end},{__index=_G})
 assert(load(source,'console','t',env))(mode)
 assert((mode=='dashboard' and shown==1 and read==0) or (mode=='console' and shown==0 and read==1),'incorrect surface')
 end
end
print('PASS console routing: nodes and CENTRAL default to dashboard')

local central=model({role='central',auth='AUTHENTICATED',network='BLUE',defenseAuto=true,total=1,online=1,
 nodes={{id='INTEL-1',role='intel',version='1.5.0',state='running',online=true}}},{state='running',version='3.13.0'},'',0)
assert(central[1].text=='STRATCOM  /  CENTRAL')
assert(central[6].text:find('INTEL-1  SAT',1,true))

local file=assert(io.open('central/central.lua'));local source=file:read('*a');file:close()
local start=assert(source:find('function options.dashboardSnapshot()',1,true))
local finish=assert(source:find('local function execute(',start,true))
local env=setmetatable({options={},nodes={A={role='radar',runtimeState='running',runtimeVersion='1.3.0'},B={role='intel',runtimeState='stopped'}},
 nodeOnline=function(n)return n.runtimeState=='running'end,secure=true,authState={networkId='BLUE'},defense={auto=false}},{__index=_G})
assert(load(source:sub(start,finish-1),'snapshot','t',env))()
local data=env.options.dashboardSnapshot()
assert(data.total==2 and data.online==1 and data.network=='BLUE' and data.defenseAuto==false)
assert(data.nodes[1].id=='A' and data.nodes[2].online==false)
