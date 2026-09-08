local function read(path)local f=assert(io.open(path));local value=f:read('*a');f:close();return value end
local function extract(source,first,following,returned,env)
    local a=assert(source:find('local function '..first..'(',1,true),first)
    local b=assert(source:find('local function '..following..'(',a+1,true),following)
    return assert(load(source:sub(a,b-1)..'\nreturn '..returned,first,'t',setmetatable(env,{__index=_G})))()
end
local failures=0
local function test(name,fn)local ok,err=pcall(fn);print((ok and 'PASS ' or 'FAIL ')..name..(ok and '' or ': '..tostring(err)));if not ok then failures=failures+1 end end

local bootstrap=read('bootstrap/bootstrap.lua')
local function classifier(devices,types,payload)
    local component={}
    component.list=function(kind)local list=devices[kind] or {};local i=0;return function()i=i+1;return list[i]end end
    component.invoke=function(_,method)assert(method=='getPayloadIdentity');return payload end
    local satlinks={}
    for address,satelliteType in pairs(types or {})do satlinks[#satlinks+1]={address=address,proxy={getType=function()return satelliteType end}}end
    return extract(bootstrap,'componentAddresses','now','classifyHardware',{component=component,satlinks=satlinks})
end

test('hardware classification is conservative and communications links are transport only',function()
    local role,state=classifier({ntm_radar={'r'}},{})();assert(role=='radar' and state=='RADAR')
    role,state=classifier({},{comm='SATCOM_RELAY'})();assert(role==nil and state=='WAITING_FOR_HARDWARE')
    role,state=classifier({}, {intel='COMBINED_INTEL'})();assert(role=='intel' and state=='INTEL')
    role,state=classifier({ntm_launch_pad={'p'}},{},'anti_ballistic')();assert(role=='defense' and state=='ABM')
    role,state=classifier({ntm_launch_pad={'p'}},{},'other')();assert(role=='strike' and state=='STRIKE')
    role,state=classifier({ntm_launch_pad={'p'}},{},'empty')();assert(role==nil and state=='WAITING_FOR_PAYLOAD')
    role,state=classifier({ntm_launch_pad={'a','b'}},{})();assert(role=='strike' and state=='LAUNCH_GROUP')
    role,state=classifier({ntm_launch_pad={'p'},ntm_radar={'r'}},{},'other')();assert(role==nil and state=='AMBIGUOUS_HARDWARE')
end)

local central=read('central/central.lua')
test('allocator follows conventions and skips IDs and aliases',function()
    local allocate=extract(central,'reservedNodeId','registerNode','allocateNodeId',{
        nodes={['SILO-S1']={}},nodePreferences={OLD={alias='SILO-S2'},['RADAR-01']={}},
        enrollments={x={id='ABM-A1',role='defense'}}})
    assert(allocate('strike')=='SILO-S3')
    assert(allocate('defense')=='ABM-A2')
    assert(allocate('radar')=='RADAR-02')
    assert(allocate('intel')=='INTEL-1')
end)

test('dual transport reuses one envelope and duplicate delivery executes once',function()
    local sent={}
    local transmit=extract(central,'transmitWire','originate','transmitEnvelope',{
        serialization={serialize=function(value)return value end},
        secure=false,
        modem={broadcast=function(_,_,encoded)sent[#sent+1]=encoded;return true end},
        satlinks={{proxy={broadcast=function(_,_,encoded)sent[#sent+1]=encoded;return 1 end}}},
    })
    local envelope={protocol=2,id='same',source='N',destination='CENTRAL',kind='BOOT_HELLO',ttl=1,payload={}}
    assert(transmit(4510,envelope) and #sent==2 and sent[1]==sent[2])

    local handled=0
    local receive=extract(central,'handleEnvelope','onModemMessage','handleEnvelope',{
        validEnvelope=function()return true end,seenMessages={},now=function()return 1 end,CENTRAL_ID='CENTRAL',
        collectOperatorReply=function()end,commandOutput=nil,pendingOperator=nil,MGMT_PORT=4510,OP_PORT=4511,
        handleMgmtEnvelope=function()handled=handled+1 end,handleRuntimeEnvelope=function()end,
    })
    receive(4510,envelope);receive(4510,envelope)
    assert(handled==1,'duplicate envelope executed twice')
end)

assert(failures==0,tostring(failures)..' failures')
