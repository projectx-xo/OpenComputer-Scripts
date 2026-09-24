local factory=assert(loadfile('central/auto_counterstrike.lua'))()
local function fixture(payload)
 local f={clock=0,config={enabled=false,salvo=1},sent={},stock={nuclear=0,bunker=0,conventional=0}}
 f.track={key='R:1',firstSeen=1,payloadClass=payload,launchSiteId=1}
 f.api=factory({now=function()return f.clock end,config=function()return f.config end,site=function()return{id=1}end,
 nodes=function()return{{id='S'}}end,ready=function(_,c,n)return math.min(n,f.stock[c])end,
 dispatch=function(_,c,n)f.sent[#f.sent+1]={c,n}end,log=function()end})
 return f
end
local f=fixture('CONVENTIONAL');f.stock.conventional=3;f.api.observe(f.track);f.api.tick();assert(#f.sent==0)
f.config.enabled=true;f.api.observe(f.track);f.api.tick();assert(f.sent[1][1]=='conventional' and f.sent[1][2]==1)
f.api.observe(f.track);f.api.tick();assert(#f.sent==1)
for _,class in ipairs({'nuclear','bunker','conventional'})do
 f=fixture('NUCLEAR');f.config.enabled=true;f.config.salvo=3;f.stock[class]=4
 f.api.observe(f.track);f.api.tick();assert(f.sent[1][1]==class and f.sent[1][2]==3)
end
f=fixture('NUCLEAR');f.config.enabled=true;f.stock={nuclear=1,bunker=5,conventional=5};f.config.salvo=3
f.api.observe(f.track);f.api.tick();assert(f.sent[1][1]=='nuclear' and f.sent[1][2]==1)
f=fixture('UNKNOWN');f.config.enabled=true;f.stock.nuclear=5;f.api.observe(f.track);f.api.tick();assert(#f.sent==0)
f=fixture('CONVENTIONAL');f.config.enabled=true;f.stock.nuclear=5;f.api.observe(f.track);f.api.tick();assert(#f.sent==0)
f=fixture('NUCLEAR');f.config.enabled=true;f.stock.nuclear=1;f.track.friendly=true;f.api.observe(f.track);f.api.tick();assert(#f.sent==0)
f=fixture('NUCLEAR');f.config.enabled=true;f.api.observe(f.track);f.config.enabled=false;f.api.tick();f.config.enabled=true;f.stock.nuclear=1;f.api.tick();assert(#f.sent==0)
f=fixture('NUCLEAR');f.config.enabled=true;f.api.observe(f.track);f.clock=121;f.stock.nuclear=1;f.api.tick();assert(#f.sent==0)
f=fixture('NUCLEAR');f.config.enabled=true;f.clock=2;f.api.reset();f.stock.nuclear=1;f.api.observe(f.track);f.api.tick();assert(#f.sent==0)
print('PASS automatic counterstrike: defaults, priority, salvo, deduplication, unknown/friendly holds, disable, expiry and no old-track replay')
