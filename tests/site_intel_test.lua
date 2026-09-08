local factory=assert(loadfile('central/site_intel.lua'))()
local function fixture()
    local f={clock=0,sent={},saved=0,site={id=1,x=100,y=90,z=200},node={id='INTEL-1',session='A'}}
    local serial=0
    f.api=factory({now=function()return f.clock end,token=function()serial=serial+1;return tostring(serial)end,
        nodes=function()return {f.node}end,available=function(_,active)return not f.offline and (active or not f.busy)end,
        send=function(...)f.sent[#f.sent+1]={...};return true end,save=function()f.saved=f.saved+1 end,log=function()end})
    function f:start()self.api.enqueue(self.site);self.api.tick();return self.sent[#self.sent] and self.sent[#self.sent][5]end
    function f:complete(token)
        self.api.receive(self.node,{'SCAN_COMPLETE',{id='A:1',session='A',request=token,targetX=100,targetZ=200}})
    end
    function f:rows(rows,done)
        local p=self.sent[#self.sent]
        self.api.receive(self.node,{'SCAN_MODEL',p[3],p[4],p[5],rows,done})
    end
    return f
end
local f=fixture();local token=f:start()
f:complete('wrong');assert(#f.sent==1,'unrelated frame accepted')
f:complete(token);assert(f.sent[2][4]=='verification:1')
f.api.receive(f.node,{'SCAN_MODEL','A:1','verification:1','old-page','bad',true})
assert(f.api.busy() and not f.site.verified,'stale page accepted')
f:rows('99,40,200,99,40,200,1,MISSILE,100,1,LOADED_MISSILE',false)
f:rows('103,38,201,103,38,201,2,LAUNCH_INFRASTRUCTURE,100,1,LAUNCHPAD',true)
assert(f.site.x==103 and f.site.y==38 and f.site.z==201 and f.site.verified)
assert(f.site.radarEstimate.x==100 and f.saved==1 and not f.api.busy())
f.api.enqueue(f.site);f.api.tick();assert(#f.sent==3,'verified site rescanned')
for _,row in ipairs({
    '100,40,200,100,40,200,1,MISSILE,100,1,FLYING_MISSILE',
    '100,40,200,100,40,200,1,LAUNCH_INFRASTRUCTURE,100,1,MISSILE_ASSEMBLY',
    '100,40,200,110,45,210,1,LAUNCH_INFRASTRUCTURE,100,1,LAUNCHPAD',
    '100,40,200,100,40,200,1,LAUNCH_INFRASTRUCTURE,50,1,LAUNCHPAD',
    '999,40,200,999,40,200,1,LAUNCH_INFRASTRUCTURE,100,1,LAUNCHPAD',''}) do
    f=fixture();token=f:start();f:complete(token);f:rows(row,true)
    assert(not f.site.verified and f.site.x==100 and f.site.intelState=='INCONCLUSIVE')
end
f=fixture();token=f:start();f:complete(token)
f:rows('100,40,200,100,40,200,1,SILO_HATCH,100,1,SILO_HATCH',true)
assert(f.site.verified,'silo hatch rejected')
f=fixture();f.busy=true;f:start();assert(#f.sent==0)
f.busy=false;f.api.tick();assert(#f.sent==1)
f.clock=181;f.api.tick();assert(f.site.intelState=='SCAN_TIMEOUT' and not f.site.verified)
f.api.enqueue(f.site);f.api.tick();assert(#f.sent==1,'timeout retried without cooldown')
f=fixture();token=f:start();f.node.session='B';f.api.tick();assert(not f.api.busy() and f.site.intelState=='NODE_UNAVAILABLE')
f=fixture();token=f:start();f:complete(token);f:rows('malformed',true)
assert(f.site.intelState=='INVALID_FINDINGS' and not f.site.verified)
f=fixture();token=f:start();f.api.receive(f.node,{'ERROR','busy',token})
assert(f.site.intelState=='SCAN_REJECTED' and not f.api.busy())
f=fixture();f.site.dimension=0;token=f:start();f:complete(token)
assert(f.site.intelState=='DIMENSION_UNCONFIRMED' and not f.site.verified)
print('PASS launch-site verification: correlation, paginated selection, exact coordinates, exclusions, busy nodes, timeout, restart and errors')

f=fixture();f.site.verificationRadius=4;token=f:start();f:complete(token)
f:rows('108,40,200,108,40,200,1,LAUNCH_INFRASTRUCTURE,100,1,LAUNCHPAD',true)
assert(not f.site.verified,'neighboring launch pad incorrectly verified this origin')
