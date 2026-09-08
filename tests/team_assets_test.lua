local now,team,logs=10,'Blue',{}
local nodes={radar={id='RADAR-01'},silo={id='SILO-S1'}}
local api=assert(loadfile('central/team_assets.lua'))()({now=function()return now end,team=function()return team end,
    nodes=function()return nodes end,online=function(n)return not n.offline end,log=function(s)logs[#logs+1]=s end})
local function asset(t,x,d)return{team=t,label='RadarOne',x=x,y=64,z=100,dimension=d,source='BASECENTER'}end
api.ingest(nodes.radar,{teamAssets={asset('Blue',100,0)}})
api.ingest(nodes.silo,{teamAssets={asset('Blue',0,0)}})
assert(api.describe(nodes.radar):find('FRIENDLY',1,true))
api.warn(nodes.silo,100,100);assert(#logs==1 and logs[1]:find('normal confirmation',1,true))
logs={};api.warn(nodes.silo,133,100);assert(#logs==0,'radius exceeded')
api.ingest(nodes.radar,{teamAssets={asset('Blue',100,1)}})
api.warn(nodes.silo,100,100);assert(#logs==0,'different dimension warned')
api.ingest(nodes.radar,{teamAssets={asset('Red',100,0)}})
assert(api.describe(nodes.radar):find('OTHER TEAM',1,true));api.warn(nodes.silo,100,100);assert(#logs==0)
api.report(100,100,0);assert(logs[1]:find('OTHER TEAM',1,true))
team=nil;assert(api.relation('Blue')=='UNKNOWN')
team='Blue';api.ingest(nodes.radar,{teamAssets={asset('Blue',100,0)}})
now=30;assert(api.describe(nodes.radar):find('LAST KNOWN',1,true));logs={};api.warn(nodes.silo,100,100)
assert(logs[1]:find('last known',1,true))
api.ingest(nodes.radar,{});assert(api.describe(nodes.radar):find('UNKNOWN',1,true))
local bad=asset('Blue',0/0,0);api.ingest(nodes.radar,{teamAssets={bad}});assert(#nodes.radar.teamAssets==0)
print('PASS team assets: validated identity, unknown/other/friendly, dimension, warning only, stale labels and cleared status')
