local function read(path) local file=assert(io.open(path));local value=file:read("*a");file:close();return value end
local function extract(source, first, following, returned, environment)
    local start=assert(source:find("local function "..first.."(",1,true),first)
    local finish=assert(source:find("local function "..following.."(",start+1,true),following)
    return assert(load(source:sub(start,finish-1).."\nreturn "..returned,first,"t",setmetatable(environment,{__index=_G})))()
end

local auth=assert(loadfile("service/auth.lua"))()
local root=string.rep("01",32)
local identity="computer-12345678"
local key=auth.deriveNodeKey(root,"BLUE",identity)
local bodies={}
local unserialized=0
local serialization={
    serialize=function(value) local token="body-"..tostring(#bodies+1);bodies[token]=value;return token end,
    unserialize=function(value) unserialized=unserialized+1;return bodies[value] end,
}
local function envelope(source,destination,kind,payload)
    return {protocol=3,id=kind.."-id",source=source,destination=destination,kind=kind,ttl=6,payload=payload or {}}
end
local function frame(port,body,senderEpoch,receiverEpoch,sequence,frameKey,network)
    return auth.sign(frameKey or key,port,{networkId=network or "BLUE",keyId=identity,
        destination=body.destination,senderEpoch=senderEpoch,receiverEpoch=receiverEpoch,
        sequence=sequence,hopLimit=6,body=serialization.serialize(body)})
end

do
    local delivered,welcome=0
    local environment={secure=true,auth=auth,authState={networkId="BLUE",key=root},authEpoch=9,
        securePeers={},secureKeys={},enrollments={},MGMT_PORT=4510,OP_PORT=4511,CENTRAL_ID="CENTRAL",DEFAULT_TTL=6,
        serialization=serialization,validEnvelope=function(value)return value and value.protocol==3 end,
        handleEnvelope=function()delivered=delivered+1 end,
        originate=function(_,destination,kind,payload,_,peer)welcome={destination,kind,payload,peer};return true end}
    local receive=extract(read("central/central.lua"),"authenticatedPeer","onModemMessage","handleWire",environment)
    local hello=envelope("PENDING-COMPUTER","CENTRAL","AUTH_HELLO",{identity,4})
    receive(4510,"STRATCOM_AUTH",frame(4510,hello,4,0,1))
    assert(welcome and welcome[2]=="AUTH_WELCOME" and welcome[3][1]==9 and welcome[3][2]==4)
    local enroll=envelope("PENDING-COMPUTER","CENTRAL","BOOT_ENROLL",{identity,"radar","RADAR","{}"})
    local authenticated=frame(4510,enroll,4,9,2)
    receive(4510,"STRATCOM_AUTH",authenticated)
    receive(4510,"STRATCOM_AUTH",authenticated)
    assert(delivered==1,"authenticated duplicate was executed")
    receive(4510,"STRATCOM_NET",enroll)
    local parsedBeforeForgery=unserialized
    receive(4510,"STRATCOM_AUTH",frame(4510,enroll,4,9,3,auth.deriveNodeKey(string.rep("02",32),"BLUE",identity)))
    assert(unserialized==parsedBeforeForgery,"forged body was deserialized before authentication")
    receive(4510,"STRATCOM_AUTH",frame(4510,enroll,4,9,4,key,"RED"))
    assert(delivered==1,"legacy, cross-team, or forged traffic was accepted")
    local restartedHello=envelope("PENDING-COMPUTER","CENTRAL","AUTH_HELLO",{identity,5})
    receive(4510,"STRATCOM_AUTH",frame(4510,restartedHello,5,0,1))
    receive(4510,"STRATCOM_AUTH",frame(4510,enroll,4,9,3))
    receive(4510,"STRATCOM_AUTH",frame(4510,enroll,5,9,2))
    assert(delivered==2,"node epoch restart did not reject the retired session")
end

do
    bodies={}
    local delivered,authenticated=0,0
    local environment={secure=true,auth=auth,authState={networkId="BLUE",identity=identity,key=key},
        authEpoch=4,centralEpoch=nil,authReplay=nil,NODE_ID="RADAR-01",CENTRAL_ID="CENTRAL",
        MGMT_PORT=4510,OP_PORT=4511,serialization=serialization,seenFrames={},now=function()return 1 end,
        validEnvelope=function(value)return value and value.protocol==3 end,
        handleEnvelope=function()delivered=delivered+1 end,autoEnroll=false,
        broadcastEnrollment=function()end,broadcastHello=function()authenticated=authenticated+1 end,
        broadcastHeartbeat=function()end,log=function()end,transmitWire=function()end}
    local bootstrap=read("bootstrap/bootstrap.lua")
    local start=assert(bootstrap:find("local function handleModemMessage(",1,true))
    local finish=assert(bootstrap:find("\nif modem then",start,true))
    local receive=assert(load(bootstrap:sub(start,finish-1).."\nreturn handleModemMessage","node-wire","t",
        setmetatable(environment,{__index=_G})))()
    local welcome=envelope("CENTRAL","RADAR-01","AUTH_WELCOME",{9,4})
    receive(4510,"STRATCOM_AUTH",frame(4510,welcome,9,4,1))
    assert(authenticated==1,"node did not establish authenticated session")
    local command=envelope("CENTRAL","RADAR-01","MGMT",{"CLAIM"})
    local authenticatedCommand=frame(4510,command,9,4,2)
    receive(4510,"STRATCOM_AUTH",authenticatedCommand)
    receive(4510,"STRATCOM_AUTH",authenticatedCommand)
    receive(4510,"STRATCOM_NET",command)
    assert(delivered==1,"node accepted duplicate or legacy command")
    local restartedWelcome=envelope("CENTRAL","RADAR-01","AUTH_WELCOME",{10,4})
    receive(4510,"STRATCOM_AUTH",frame(4510,restartedWelcome,10,4,1))
    receive(4510,"STRATCOM_AUTH",frame(4510,command,9,4,3))
    receive(4510,"STRATCOM_AUTH",frame(4510,command,10,4,2))
    assert(delivered==2 and authenticated==2,"CENTRAL epoch restart did not retire old commands")
end

print("PASS authenticated CENTRAL/node handshake, team isolation, and fail-closed transport")
