local factory=assert(loadfile('central/fleet_update.lua'))()
local function fixture(saved)
    local f={time=0,version='old',status={update='idle'},nodes={N={id='N',claimed=true,bootstrapVersion='3.4.0',session='S'}},sent={},logs={},checks=0}
    f.ctx={now=function()return f.time end,current=function()return f.version end,pending=function()return f.pending end,
        nodes=function()return f.nodes end,online=function(n)return not n.offline end,
        token=function()f.tokens=(f.tokens or 0)+1;return 'token'..f.tokens end,
        load=function()return saved end,save=function(j)if f.diskFail then return false,'disk full'end;f.saved=j;return true end,
        check=function()f.checks=f.checks+1;return not f.checkFail,'checking'end,
        serviceStatus=function()return f.status end,sync=function()f.synced=true end,
        log=function(s)f.logs[#f.logs+1]=s end,decode=function()return f.reply end,
        runtimeCurrent=function()return not f.runtimeOld end,reconcile=function()f.reconciled=true end,
        send=function(...)f.sent[#f.sent+1]={...}end}
    f.api=factory(f.ctx)
    function f:tick(t)self.time=self.time+(t or 2);self.api.tick()end
    function f:ready()
        assert(self.api.start());self.version='new';self:tick();self:tick();self:tick()
    end
    function f:report(values)
        local sent=self.sent[#self.sent]
        self.reply=values or {ok=true,version='new',pending=false,update='up to date',session='S'}
        self.api.receive(self.nodes.N,{sent[3],'data'})
    end
    return f
end
local f=fixture();f:ready();assert(f.synced and f.sent[1][2]=='UPDATE_CHECK' and f.sent[1][4]=='new')
f:report();f:tick();assert(f.api.status():find('N: updated',1,true) and f.saved.phase=='done')
f=fixture();f.diskFail=true;assert(not f.api.start() and f.checks==0)
f=fixture();assert(f.api.start());f.version='new';f.pending=true;f:tick();assert(#f.sent==0)
f.pending=nil;f:tick();assert(f.saved.phase=='nodes')
f=fixture();f:ready();f.reply={ok=true,version='new',pending=false,update='up to date',session='old'}
f.api.receive(f.nodes.N,{f.sent[1][3],'data'});assert(not f.api.status():find('N: updated',1,true))
f:report({ok=true,version='old',pending=false,update='error: offline',session='S'})
assert(f.api.status():find('needs attention',1,true))
f=fixture();f:ready();f.runtimeOld=true;f:report();assert(f.reconciled and not f.api.status():find('N: updated',1,true))
f.runtimeOld=false;f:report();assert(f.api.status():find('N: updated',1,true))
f=fixture();f.nodes.N.bootstrapVersion='3.3.0';f:ready();assert(#f.sent==0 and f.api.status():find('waiting for auto-update',1,true))
f.nodes.N.bootstrapVersion='3.4.0';f:tick();f:tick();assert(#f.sent==1)
f=fixture();f:ready();f:tick(601);assert(f.api.status():find('needs attention',1,true))
f=fixture();f:ready();local saved=f.saved
local restored=fixture(saved);restored.version='new';restored:tick();restored:tick();assert(#restored.sent==1,'restart lost node work')
f=fixture();assert(f.api.start());f.status.update='up to date';f:tick();assert(f.saved.target=='old','up-to-date CENTRAL did not update nodes')
print('PASS fleet upgrades: saved intent, central probation, remote checks, legacy migration, correlation, timeout, runtime reconciliation and restart')

f=fixture({schema=1,id='broken',base='old',phase='nodes',target='new',nodes={N={state='unknown'}}})
assert(f.api.status()=='No fleet upgrade requested.','corrupt saved state was accepted')
f=fixture();assert(f.api.start());local interrupted=f.saved
local resumed=fixture(interrupted);resumed:tick();assert(resumed.checks==1,'interrupted central check was not resumed')
f=fixture();f:ready();f:report({ok=true,version='other',pending=false,update='up to date',session='S'})
assert(f.api.status():find('Source/version mismatch',1,true))
