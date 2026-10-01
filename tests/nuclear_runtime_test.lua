local saved, sent, tick, packet, config = {}, {}, nil, nil, {}
package.loaded.component={list=function()local once=false;return function()if not once then once=true;return 'station'end end end,
    invoke=function(_,method,epoch,cursor)
        if method=='getType' then return 'NUCLEAR_DETECTION' end
        if cursor==1 then return true,'epoch',1,'',0,false end
        return true,'epoch',1,'1,EXPLOSION,NUCLEAR,12,?,30,0,100',0,false
    end}
package.loaded.event={timer=function(_,fn)tick=fn;return 1 end,cancel=function()end}
package.loaded.serialization={serialize=function(t)packet=t;return 'serialized'end}
local runtime=assert(loadfile('runtime/nuclear.lua'))()
local fail=false
runtime.start({session='S',config=config,send=function(...)sent[#sent+1]={...}end,
    saveConfig=function(value)if fail then return false,'disk'end;saved=value;return true end})
assert(packet.events[1].y==nil and packet.events[1].kind=='EXPLOSION')
assert(runtime.status().ready and runtime.status().pending and not config.nuclearCursor)
local token=sent[1][4];tick();assert(sent[2][4]==token,'retry changed identity')
runtime.onMessage('CENTRAL','NUCLEAR_ACK','wrong');assert(not config.nuclearCursor)
fail=true;runtime.onMessage('CENTRAL','NUCLEAR_ACK',token);assert(not config.nuclearCursor and runtime.status().pending)
fail=false;runtime.onMessage('CENTRAL','NUCLEAR_ACK',token);assert(saved.nuclearCursor.cursor==1 and not runtime.status().pending)
tick();assert(#sent==2,'acknowledged batch resent')
runtime.stop()
print('PASS nuclear runtime: typed observations, stable retry, correlated ACK and failed-save retention')
