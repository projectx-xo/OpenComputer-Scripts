local factory=assert(loadfile('central/nuclear.lua'))()
local function fixture()
    local f={clock=0,sent={},logs={},node={id='INTEL-1',session='I'},detector={id='NUC-1',role='nuclear',session='N',claimed=true}}
    f.batch={session='N',lost=0,events={{id='epoch:1',kind='EXPLOSION',payload='NUCLEAR',x=12.4,z=30,dimension=0,tick=100}}}
    f.api=factory({now=function()return f.clock end,token=function()return 'request'end,
        nodes=function()return {f.node}end,available=function()return not f.unavailable end,
        decode=function()return f.batch end,log=function(s)f.logs[#f.logs+1]=s end,
        send=function(...)f.sent[#f.sent+1]={...};return not f.sendFailure end})
    function f:report()self.api.receive(self.detector,{'NUCLEAR_EVENTS','data','ack'})end
    function f:complete(dimension,request)
        self.api.receive(self.node,{'SCAN_COMPLETE',{id='I:1',session='I',request=request or 'request',targetX=12,targetZ=30,native={dimension=dimension}}})
    end
    return f
end
local f=fixture();f:report();assert(f.sent[1][2]=='NUCLEAR_ACK')
f:report();assert(#f.logs==1 and #f.sent==2,'retry duplicated observation')
f.clock=59;f.api.tick();assert(not f.api.busy())
f.clock=60;f.api.tick();assert(f.api.busy() and f.sent[3][2]=='SCAN' and f.sent[3][3]==12)
f:complete(0,'old');assert(f.api.busy(),'uncorrelated completion accepted')
f:complete(0);assert(not f.api.busy() and f.logs[#f.logs]:match('COMPLETE'))
f=fixture();f:report();f.clock=60;f.api.tick();f:complete(1)
assert(f.logs[#f.logs]:match('DIMENSION_UNCONFIRMED'))
f=fixture();f:report();f.unavailable=true;f.clock=60;f.api.tick();assert(not f.api.busy())
f.clock=601;f.api.tick();assert(f.logs[#f.logs]:match('No intelligence'))
f=fixture();f:report();f.clock=60;f.api.tick();f.clock=241;f.api.tick();assert(f.logs[#f.logs]:match('TIMEOUT'))
f=fixture();f:report();f.clock=60;f.api.tick();f.node.session='new';f.api.tick();assert(f.logs[#f.logs]:match('NODE_UNAVAILABLE'))
for _,mutate in ipairs({function(f)f.batch.session='old'end,function(f)f.detector.role='radar'end,
    function(f)f.batch.events[1].x=0/0 end,function(f)f.batch.events[2]={}end,
    function(f)f.batch.events[1].dimension=.5 end}) do
    f=fixture();mutate(f);f:report();assert(#f.sent==0 and #f.logs==0,'invalid batch had side effects')
end
f=fixture();f.batch.events[1].kind='MISSILE';f:report();f.clock=60;f.api.tick();assert(not f.api.busy(),'missile started damage scan')
print('PASS nuclear events: validation, deduplication, ACK, delayed intel handoff, correlation, dimension, expiry and timeout')
