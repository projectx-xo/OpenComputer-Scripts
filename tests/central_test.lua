-- Run from the repository root with Lua 5.2+; hardware boundaries are simulated.
local function extract(first, following, env)
    if not env.tryMatchFriendlyTrack then env.tryMatchFriendlyTrack = function(track) return track.friendly end end
    if not env.hasEntityTarget then env.hasEntityTarget = function() return false end end
    local f = assert(io.open('central/central.lua')); local source = f:read('*a'); f:close()
    local a = assert(source:find('local function ' .. first .. '(', 1, true), first .. ' missing')
    local b = assert(source:find('local function ' .. following .. '(', a + 1, true), following .. ' missing')
    return assert(load(source:sub(a, b - 1) .. '\nreturn ' .. first, first, 't', setmetatable(env, {__index = _G})))()
end
local failures = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    print((ok and 'PASS ' or 'FAIL ') .. name .. (ok and '' or ': ' .. tostring(err)))
    if not ok then failures = failures + 1 end
end

local function iffFixture()
    local f=assert(io.open('central/central.lua'));local source=f:read('*a');f:close()
    local a=assert(source:find('local function horizontalDistance(',1,true))
    local b=assert(source:find('local function recordLaunchSite(',a,true))
    local env={defense={protectX=607,protectZ=1800,radius=300},friendlyExpectations={},nextFriendlyExpectationId=1,
        IFF_MATCH_WINDOW=30,IFF_HEADING_TOLERANCE=30,now=function()return 1440 end,
        defenseZoneConfigured=function()return true end,print=function()end}
    return assert(load(source:sub(a,b-1)..'\nreturn {register=registerFriendlyExpectation,match=tryMatchFriendlyTrack}',
        'iff','t',setmetatable(env,{__index=_G})))(),env
end

test('ordered salvo remains friendly while initially approaching protection center',function()
    local iff,env=iffFixture()
    iff.register({id='SILO-S2',role='strike'},2,1000,1000,'strike',2)
    for i=1,2 do
        env.now=function()return 1440+i end
        local track={key='RADAR-01:'..i,typeId=1,firstSeen=1440+i,firstX=630.56,firstZ=1829.36,
            x=631,z=1828,vx=3.7,vz=-8.3,threatSamples=2}
        assert((track.x-607)*track.vx+(track.z-1800)*track.vz<0,'fixture must approach protection center')
        assert(iff.match(track),'ordered friendly missile rejected')
        assert(track.friendly and track.threatSamples==0)
        assert(iff.match(track),'repeat consumed a second salvo slot')
    end
    assert(next(env.friendlyExpectations)==nil,'salvo count not consumed exactly once per missile')
end)

test('IFF rejects old, external, stationary, wrong-heading and excess contacts',function()
    local iff=iffFixture();iff.register({id='S',role='strike'},1,1000,1000,'strike',0)
    local t={key='R:1',typeId=1,firstSeen=1430,firstX=630,firstZ=1829,x=631,z=1828,vx=3.7,vz=-8.3}
    assert(not iff.match(t));t.firstSeen=1440;t.firstX=2000;assert(not iff.match(t))
    t.firstX=630;t.vx=0;t.vz=0;assert(not iff.match(t))
    t.vx=-3.7;t.vz=8.3;assert(not iff.match(t))
    t.vx=3.7;t.vz=-8.3;assert(iff.match(t))
    t.friendly=false;assert(not iff.match(t),'unregistered extra missile claimed a friendly slot')
end)

test('defense evaluates IFF on status-refreshed tracks before threat confirmation',function()
    local iff=iffFixture();iff.register({id='S',role='strike'},1,1000,1000,'strike',0)
    local sent=0
    local run=extract('evaluateTrackForDefense','defenseTick',{
        getNode=function()return {runtimeState='running'}end,nodeOnline=function()return true end,
        now=function()return 1441 end,RADAR_TRACK_STALE_AFTER=10,tryMatchFriendlyTrack=iff.match,
        defense={auto=true},defenseZoneConfigured=function()return true end,automaticThreatType=function()return true end,
        closestApproach=function()return {inbound=true}end,DEFENSE_CONFIRM_SAMPLES=3,activeEngagements={},
        createEngagement=function()sent=sent+1 end})
    local t={key='R:1',station='R',sequence=3,lastUpdate=1441,typeId=1,firstSeen=1440,firstX=630,firstZ=1829,
        x=631,z=1828,vx=3.7,vz=-8.3,threatSamples=2}
    run(t);assert(t.friendly and sent==0 and t.threatSamples==0)
end)

test('ABM range uses all three axes and rejects unavailable or stale coordinates',function()
    local check=extract('abmInRange','historyPush',{now=function()return 100 end,RADAR_TRACK_STALE_AFTER=10})
    local node={status={position={x=0,y=50,z=0}}}
    local track={x=600,y=850,z=0,lastUpdate=100}
    assert(not check(node,track),'exactly 1000 blocks is outside the seeker acquisition radius')
    track.y=849;assert(check(node,track),'in-range target held')
    track.y=1051;track.x=0;assert(not check(node,track),'altitude ignored')
    track.y=50;track.lastUpdate=80;assert(not check(node,track),'stale target accepted')
    track.lastUpdate=100;track.y=0/0;assert(not check(node,track),'NaN accepted')
    assert(not check({},track),'old runtime without position accepted')
    assert(not check({status={position=42}},track),'malformed position accepted')
end)

test('automatic engagement waits for range before sending ARM',function()
    local sent,allowed=0,false
    local track={key='R:1',x=0,z=0}
    local run=extract('createEngagement','evaluateTrackForDefense',{
        abmReady=function()return true,{}end,abmInRange=function()return allowed,'TARGET_OUT_OF_RANGE'end,
        now=function()return 100 end,activeEngagements={},DEFENSE_LEAD_SECONDS=2,
        sendOperational=function()sent=sent+1 end,print=function()end})
    assert(not run(track,{closest=0,t=5}) and sent==0)
    allowed=true;assert(run(track,{closest=0,t=5}) and sent==1)
end)

test('ARM acknowledgement rechecks range and disarms when contact moved out',function()
    local sent,state={},nil
    local engagement={state='ARMING',trackKey='R:1',targetX=0,targetZ=0}
    local env={ABM_NODE_ID='ABM-A1',pendingArm=engagement,getNode=function()return {}end,nodeOnline=function()return true end,
        radarTracks={['R:1']={}},defense={auto=true},abmReady=function()return true end,
        abmInRange=function()return false,'TARGET_OUT_OF_RANGE'end,
        sendOperational=function(_,cmd)sent[#sent+1]=cmd end,
        finishEngagement=function(_,s)state=s end,now=function()return 100 end,print=function()end}
    local run=extract('launchPendingEngagement','createEngagement',env)
    run();assert(state=='ABORTED' and #sent==1 and sent[1]=='DISARM')
    sent={};env.abmInRange=function()return true end
    run();assert(#sent==1 and sent[1]=='LAUNCH')
end)

test('launch origin needs low-altitude ascending observations, not just radar visibility',function()
    local sites=0
    local evaluate=extract('evaluateLaunchSiteCandidate','nextMessageId',{
        LAUNCH_SITE_MAX_ACQUIRE_Y=160,LAUNCH_SITE_MIN_CLIMB=35,LAUNCH_SITE_MIN_DEPARTURE=40,
        LAUNCH_SITE_CONFIRM_SAMPLES=2,horizontalDistance=function(x,z,a,b)return math.sqrt((a-x)^2+(b-z)^2)end,
        recordLaunchSite=function()sites=sites+1;return {id=7}end})
    local track={typeId=1,firstX=0,firstY=56,firstZ=0,x=50,y=100,z=0,vy=10}
    evaluate(track);assert(sites==0)
    track.y=110;evaluate(track);assert(sites==1 and track.launchSiteId==7)
    evaluate(track);assert(sites==1)
    evaluate({typeId=1,firstY=200,y=300});assert(sites==1,'high acquisition invented a launch origin')
end)

test('entity handoff bypasses search range but retains freshness and dimension checks',function()
    local env={now=function()return 100 end,RADAR_TRACK_STALE_AFTER=10}
    env.hasEntityTarget=extract('hasEntityTarget','abmInRange',{})
    local check=extract('abmInRange','historyPush',env)
    local node={status={entityTargeting=true,dimension=0}}
    local track={entityId=5,entityUuid='12345678-1234-1234-1234-123456789abc',dimension=0,lastUpdate=100,x=5000,y=2000,z=0}
    assert(check(node,track),'handoff incorrectly uses pad distance')
    track.dimension=1;assert(not check(node,track));track.dimension=0
    track.lastUpdate=80;assert(not check(node,track));track.lastUpdate=100
    node.status.entityTargeting=false;assert(not check(node,track),'old pad bypassed range gate')
end)

test('handoff sends the captured identity and aborts an identity change during ARM',function()
    local target={entityId=5,entityUuid='12345678-1234-1234-1234-123456789abc',dimension=0}
    local node={status={entityTargeting=true,dimension=0}}
    local engagement={state='ARMING',trackKey='R:1',targetX=5000,targetZ=0,entityTarget=target}
    local track={entityId=5,entityUuid=target.entityUuid,dimension=0}
    local sent,state
    local env={ABM_NODE_ID='ABM',pendingArm=engagement,getNode=function()return node end,nodeOnline=function()return true end,
        radarTracks={['R:1']=track},defense={auto=true},abmReady=function()return true end,
        abmInRange=function()return true end,hasEntityTarget=extract('hasEntityTarget','abmInRange',{}),
        sendOperational=function(_,cmd,arg)sent={cmd,arg}end,serialization={serialize=function(t)return t end},
        finishEngagement=function(_,s)state=s end,now=function()return 100 end,print=function()end}
    local run=extract('launchPendingEngagement','createEngagement',env)
    run();assert(sent[1]=='LAUNCH_ENTITY' and sent[2]==target)
    engagement.state='ARMING';track.entityId=6;run();assert(sent[1]=='DISARM' and state=='ABORTED')
end)

test('slow status replies are not invalidated by the next background poll',function()
    local clock, serial, sent=0,0,0
    local node={claimed=true,runtimeState='running'}
    local request=extract('requestRuntimeStatus','pollRuntimeStatus',{
        now=function()return clock end,nodeOnline=function()return true end,
        STATUS_INTERVAL=5,STATUS_REQUEST_TIMEOUT=15,
        nextMessageId=function()serial=serial+1;return 'status-'..serial end,
        sendOperational=function()sent=sent+1;return true end})
    local token=request(node)
    clock=6;request(node)
    assert(node.pendingStatus==token and sent==1,'poll replaced the token before a six-second response could arrive')
    clock=16;request(node)
    assert(node.pendingStatus~=token and sent==2,'lost request did not expire')
end)

test('status errors finish the matching request and reach the operator without a false timeout',function()
    local clock, lines, node = 0, {}, {id='SILO-S1',claimed=true,runtimeState='running',statusError='previous error'}
    local env={now=function()return clock end,nodeOnline=function()return true end,
        STATUS_INTERVAL=5,STATUS_REQUEST_TIMEOUT=15,nextMessageId=function()return 'fresh' end,
        sendOperational=function()return true end,getNode=function()return node end,
        print=function(line)lines[#lines+1]=line end}
    env.requestRuntimeStatus=extract('requestRuntimeStatus','pollRuntimeStatus',env)
    local receive=extract('handleRuntimeEnvelope','collectOperatorReply',env)
    env.event={pull=function()
        clock=clock+0.1
        assert(node.statusError==nil,'new request retained old error')
        receive({source=node.id,payload={'ERROR','unrelated error','old'}})
        assert(node.statusError==nil,'stale error replaced pending status')
        receive({source=node.id,payload={'ERROR','getEnergyInfo unavailable','fresh'}})
    end}
    local await=extract('awaitStatus','awaitControl',env)
    assert(await(node)==false,'failed status reported success')
    assert(clock<1,'matching error waited for timeout')
    assert(env.commandFailed==true,'console command reported success')
    local text=table.concat(lines,'\n')
    assert(text:find('getEnergyInfo unavailable',1,true),'actual node error hidden')
    assert(not text:find('TIMEOUT',1,true),'received error described as missing reply')
end)

test('confirmed interceptor failure releases the same surviving threat for reengagement',function()
    local clock, finished=10,nil
    local node={id='ABM',session='A'}
    local track={entityId=5,entityUuid='target',dimension=0,lastUpdate=10}
    local e={state='FIRED',abmNode='ABM',abmSession='A',entityTarget={entityId=5,entityUuid='target',dimension=0}}
    local env={now=function()return clock end,activeEngagements={T=e},radarTracks={T=track},
        RADAR_TRACK_STALE_AFTER=10,DEFENSE_REENGAGE_COOLDOWN=10,print=function()end}
    env.finishEngagement=function(_,state)finished=state;env.activeEngagements.T=nil end
    local receive=extract('handleInterceptorOutcome','handleRuntimeEnvelope',env)
    e.outcomeToken='1';receive(node,{'INTERCEPT_STATUS','MISS','old'});assert(not e.missSamples)
    for i=1,3 do
        clock=9+i;track.lastUpdate=clock;e.outcomeToken=tostring(i)
        receive(node,{'INTERCEPT_STATUS','MISS',tostring(i)})
        if i<3 then assert(not finished,'single or immediate death report caused retry') end
    end
    assert(finished=='MISS' and not env.activeEngagements.T and track.lastEngaged==2 and track.threatSamples==0)
    -- New threats still pass through normal automatic-defense qualification.
    assert(not track.reengageUnconfirmed)
end)

test('unknown or surviving interceptor never confirms a miss',function()
    for _,outcome in ipairs({'IN_FLIGHT','UNKNOWN','TARGET_UNAVAILABLE'}) do
        local e={state='FIRED',abmNode='ABM',abmSession='A',outcomeToken='1',missSamples=2,firstMiss=1}
        local receive=extract('handleInterceptorOutcome','handleRuntimeEnvelope',{
            now=function()return 10 end,activeEngagements={T=e},radarTracks={},finishEngagement=function()error('false miss')end})
        receive({id='ABM',session='A'},{'INTERCEPT_STATUS',outcome,'1'})
        assert(e.missSamples==0 and e.firstMiss==nil)
    end
end)

test('live interceptor monitoring outlasts the old flight timeout without launching again',function()
    local sent=0
    local e={state='FIRED',firedAt=1,lastOutcomeAt=99,interceptor='shot',entityTarget={entityId=1,entityUuid='target',dimension=0},
        abmNode='ABM',abmSession='A'}
    local run=extract('defenseTick','handleTrackLostForDefense',{
        now=function()return 100 end,pruneFriendlyExpectations=function()end,defense={auto=false},
        activeEngagements={T=e},radarTracks={},getNode=function()return {session='A'}end,nodeOnline=function()return true end,
        nextMessageId=function()return 'poll'end,serialization={serialize=function(q)return q end},
        sendOperational=function(_,command)assert(command=='INTERCEPT_STATUS');sent=sent+1 end,
        finishEngagement=function()error('live flight ended on timer')end})
    run();run();assert(sent==1,'poll burst or premature flight timeout')
end)

test('observation timeout cannot establish a miss, even with a fresh hostile contact',function()
    for _, sample in ipairs({{lastUpdate=30},{lastUpdate=1},{},false}) do
        local clock, outcome = 29, nil
        local engagement={state='FIRED',firedAt=10,trackKey='R:1'}
        local track=sample or nil
        local tick=extract('defenseTick','handleTrackLostForDefense',{
            now=function()return clock end,pruneFriendlyExpectations=function()end,
            defense={auto=false},activeEngagements={['R:1']=engagement},radarTracks={['R:1']=track},
            DEFENSE_POST_LAUNCH_TIMEOUT=20,RADAR_TRACK_STALE_AFTER=10,
            finishEngagement=function(_,state,detail)outcome={state,detail}end})
        tick();assert(not outcome,'observation ended early')
        clock=30;tick()
        assert(outcome and outcome[1]=='UNCONFIRMED','timeout falsely declared a miss or left engagement open')
        local expected=track and track.lastUpdate==30 and 'CONTACT_ACTIVE_AT_OBSERVATION_TIMEOUT'
            or 'RADAR_TELEMETRY_UNAVAILABLE_AT_OBSERVATION_TIMEOUT'
        assert(outcome[2]==expected,'cached or missing contact described as live')
        if track then assert(track.lastEngaged==30,'existing reengagement cooldown lost') end
    end
end)

test('counterstrike suggestions require a fired interceptor and the same track origin',function()
    local lines={}
    local env={now=function()return 20 end,activeEngagements={},historyPush=function()end,
        launchSites={[7]={id=7,x=507,z=1709,confidence='LOW'}},print=function(s)lines[#lines+1]=s end}
    local finish=extract('finishEngagement','launchPendingEngagement',env)
    finish({trackKey='RADAR:2',launchSiteId=7},'UNCONFIRMED','CONTACT_LOST_AFTER_ENGAGEMENT')
    assert(env.latestCounterstrike==nil,'unacknowledged launch produced a retaliation suggestion')
    finish({trackKey='RADAR:2',launchSiteId=7,firedAt=10},'UNCONFIRMED','CONTACT_ACTIVE_AT_OBSERVATION_TIMEOUT')
    finish({trackKey='RADAR:2',launchSiteId=7,firedAt=10},'UNCONFIRMED','RADAR_TELEMETRY_UNAVAILABLE_AT_OBSERVATION_TIMEOUT')
    assert(env.latestCounterstrike==nil,'observation timeout incorrectly reported lost contact')
    finish({trackKey='RADAR:2',launchSiteId=7,firedAt=10},'UNCONFIRMED','CONTACT_LOST_AFTER_ENGAGEMENT')
    assert(env.latestCounterstrike==7,'known origin did not produce a suggestion')
    assert(table.concat(lines,'\n'):find('counterstrike',1,true),'no operator hint')
end)

test('counterstrike resolves the suggested site without requiring coordinates',function()
    local planned
    local node={id='SILO-S2',role='strike',claimed=true,runtimeState='running',lastStatus=99,multiLauncher=true}
    local env={nodes={['SILO-S2']=node},launchSites={[7]={id=7,x=507.2,z=1709.2,confidence='LOW'}},latestCounterstrike=7,
        now=function()return 100 end,STATUS_INTERVAL=5,VALID_CLASSES={nuclear=true},print=function()end,
        getNode=function(id)return id=='SILO-S2' and node end,nodeOnline=function()return true end,
        selectPayloadLaunchers=function()return {1,2,3,4}end,
        executeStrike=function(n,c,count,x,z,interval)planned={n.id,c,count,x,z,interval}end}
    local run=extract('executeCounterstrike','printHelp',env)
    run({'counterstrike','nuclear','4','7','SILO-S2','3'})
    assert(planned and planned[1]=='SILO-S2' and planned[3]==4 and planned[4]==507 and planned[5]==1709 and planned[6]==3,'wrong origin or pacing')
    planned=nil;run({'counterstrike','nuclear','1'})
    assert(planned and planned[3]==1 and planned[4]==507,'short command did not use latest suggestion')
    planned=nil;env.latestCounterstrike=nil;run({'counterstrike','nuclear','1'})
    assert(not planned,'counterstrike guessed a site without a suggestion')
end)

test('operator STOP and maintenance survive reconciliation', function()
    for _, state in ipairs({'stopped', 'maintenance'}) do
        local sent = {}
        local reconcile = extract('reconcileNode', 'reconcileAll', {
            nodeOnline = function() return true end, now = function() return 100 end,
            nodePreferences = {SILO = {desiredState = state}}, nodes = {},
            desiredState = function() return state end,
            RECONCILE_INTERVAL = 10, desiredRuntimes = {strike = {version = '2'}},
            sendMgmt = function(_, command) sent[#sent + 1] = command end,
            requestRuntimeStatus = function() end, print = function() end
        })
        reconcile({id = 'SILO', role = 'strike', claimed = true, runtimeVersion = '2', runtimeState = 'stopped'})
        for _, command in ipairs(sent) do assert(command ~= 'START', 'STOP was undone') end
    end
end)

test('duplicate and stale samples never qualify an engagement', function()
    local count = 0
    local evaluate = extract('evaluateTrackForDefense', 'defenseTick', {
        now = function() return 100 end, nodeOnline = function(n) return n ~= nil end,
        nodes = {RADAR = {runtimeState = 'running'}}, getNode = function() return {runtimeState = 'running'} end,
        RADAR_TRACK_STALE_AFTER = 10, defense = {auto = true},
        defenseZoneConfigured = function() return true end, automaticThreatType = function() return true end,
        closestApproach = function() return {inbound = true} end,
        DEFENSE_CONFIRM_SAMPLES = 3, activeEngagements = {}, DEFENSE_REENGAGE_COOLDOWN = 10,
        createEngagement = function() count = count + 1 end
    })
    local stale = {key = 'RADAR:1', station = 'RADAR', lastUpdate = 1, sequence = 1, session = 'A'}
    evaluate(stale); evaluate(stale); evaluate(stale)
    assert(count == 0, 'stale data qualified')
    local fresh = {key = 'RADAR:1', station = 'RADAR', lastUpdate = 100, sequence = 1, session = 'A'}
    evaluate(fresh); evaluate(fresh); evaluate(fresh)
    assert(count == 0, 'one observation counted three times')
    fresh.sequence = 2; evaluate(fresh)
    fresh.sequence = 3; evaluate(fresh)
    assert(count == 1, 'three new observations did not qualify')
end)

test('a restarted radar cannot inherit an old track identity', function()
    local tracks = {['RADAR:1'] = {friendly = true, session = 'old', sequence = 9}}
    local apply = extract('applyRadarTrack', 'applyRadarStatus', {
        now = function() return 100 end, radarTracks = tracks,
        radarTrackKey = function(node, id) return node .. ':' .. id end,
        radarTypeName = function() return 'TIER20' end
    })
    local node = {id = 'RADAR'}
    local saved = apply(node, {id = 1, session = 'new', sequence = 1, x = 5, y = 6, z = 7})
    assert(saved and not saved.friendly, 'friendly identity leaked across restart')
    local duplicate = apply(node, {id = 1, session = 'new', sequence = 1, x = 999})
    assert(not duplicate or duplicate.x == 5, 'duplicate overwrote newer observation')
end)

test('restarted field nodes are claimed again before accepting remote status',function()
    local claims=0
    local node={id='SILO-S1',session='old',claimed=true,desiredState='stopped',lastStatus=90,pendingStatus='old-request'}
    local env={nodes={['SILO-S1']=node},now=function()return 100 end,radarTracks={},
        sendMgmt=function(n,command)assert(n==node and command=='CLAIM');claims=claims+1 end,
        print=function()end}
    local register=extract('registerNode','deploymentChunk',env)
    register('SILO-S1','strike','3.0.0','3.1.0','running','stopped','new')
    assert(claims==1 and node.claimed==false,'restart retained stale claim and skipped handshake')
    assert(node.lastStatus==nil and node.pendingStatus==nil,'old status survived restart')
    assert(node.desiredState=='stopped','restart overwrote stop intent')
    -- A heartbeat retries a lost claim; after acknowledgement it must not spam claims.
    register('SILO-S1','strike','3.0.0','3.1.0','running','stopped','new')
    assert(claims==2,'lost claim was not retried')
    node.claimed=true
    register('SILO-S1','strike','3.0.0','3.1.0','running','stopped','new')
    assert(claims==2 and node.claimed,'same session unnecessarily lost ownership')
    register('SILO-S1','strike','3.0.0','3.1.0','running','stopped','old')
    assert(claims==2 and node.session=='new','retired heartbeat reset current ownership')
end)

test('new launch observations preserve satellite coordinates and enqueue verification',function()
    local site={id=5,x=100,y=40,z=200,launches=3,verified={kind='LAUNCHPAD'}}
    local enqueued
    local record=extract('recordLaunchSite','evaluateLaunchSiteCandidate',{
        launchSites={[5]=site},LAUNCH_SITE_MERGE_DISTANCE=100,now=function()return 100 end,
        horizontalDistance=function(x,z,a,b)return math.sqrt((x-a)^2+(z-b)^2)end,
        launchSiteConfidence=function()return 'HIGH'end,saveLaunchSites=function()end,print=function()end,
        siteIntel={enqueue=function(s)enqueued=s end}})
    record({firstX=105,firstY=90,firstZ=205})
    assert(site.x==100 and site.y==40 and site.z==200,'radar averaged away exact target')
    assert(site.launches==4 and enqueued==site)
end)

test('new radar observations retain the existing range-hold reason',function()
    local tracks={['R:1']={session='A',sequence=1,lastDefenseHoldReason='TARGET_OUT_OF_RANGE'}}
    local apply=extract('applyRadarTrack','applyRadarStatus',{
        now=function()return 100 end,radarTracks=tracks,radarTrackKey=function()return 'R:1'end,radarTypeName=function()return 'TIER1'end})
    local track=apply({id='R'},{id=1,session='A',sequence=2,x=0,y=2000,z=0})
    assert(track.lastDefenseHoldReason=='TARGET_OUT_OF_RANGE','range-hold alert repeats on every observation')
end)

test('summary status retains tracked objects', function()
    local tracks = {['RADAR:1'] = {station = 'RADAR'}}
    local apply = extract('applyRadarStatus', 'applyRuntimeStatus', {radarTracks = tracks})
    apply({id = 'RADAR'}, {radarStation = true, activeTrackCount = 1})
    assert(tracks['RADAR:1'], 'summary erased tracks without a snapshot')
end)

test('track loss is not claimed as destruction', function()
    local state
    local lost = extract('handleTrackLostForDefense', 'handleMgmtEnvelope', {
        activeEngagements = {track = {state = 'FIRED'}},
        finishEngagement = function(_, value) state = value end
    })
    lost('track')
    assert(state == 'UNCONFIRMED', 'loss was reported as a confirmed intercept')
end)

test('retired runtime sessions cannot replace current telemetry', function()
    local tracks = {}
    local apply = extract('applyRadarTrack', 'applyRadarStatus', {
        now=function()return 100 end,radarTracks=tracks,radarTrackKey=function(id,n)return id..":"..n end,radarTypeName=function()return "TIER20" end
    })
    assert(apply({id='R',session='new'},{id=1,session='old',sequence=99})==nil,'retired track accepted')
    local nodes={R={id='R',claimed=true,session='new',retiredSessions={old=90}}}
    local register=extract('registerNode','deploymentChunk',{nodes=nodes,radarTracks=tracks,now=function()return 100 end,print=function()end})
    assert(register('R','radar','3','1','running','running','old')==nil,'retired heartbeat accepted')
    assert(nodes.R.session=='new')
end)

test('old deployment errors cannot cancel the current transaction', function()
    local cancelled=false
    local node={id='N',deployment={id='new'},deploying=true}
    local handle=extract('handleMgmtEnvelope','handleRadarTrackEvent',{
        getNode=function()return node end,now=function()return 100 end,
        failDeployment=function()cancelled=true end
    })
    handle({source='N',kind='MGMT_ERROR',payload={'DEPLOY_COMMIT','NO_DEPLOYMENT',nil,'old'}})
    assert(not cancelled,'old transaction cancelled current deployment')
end)

test('maintenance intent is retried until the node enters maintenance', function()
    local sent
    local reconcile=extract('reconcileNode','reconcileAll',{
        nodeOnline=function()return true end,now=function()return 100 end,desiredState=function()return 'maintenance' end,
        sendMgmt=function(_,command)sent=command end
    })
    reconcile({id='N',claimed=true,runtimeState='running'})
    assert(sent=='MAINTENANCE','lost maintenance command was never retried')
end)

test('intelligence asset label is complete and link columns align',function()
    local summary=extract('nodeAssetSummary','printNodes',{clip=function(v)return v or '---'end})
    assert(summary({role='intel'})=='Combined Intelligence')
    local lines={}
    local render=extract('printNodes','printLauncherTable',{
        nodes={I={role='intel'},R={role='radar'}},nodeAssetSummary=summary,
        nodeOnline=function()return true end,clip=function(v)return v or '---'end,
        print=function(v)lines[#lines+1]=v end})
    render()
    local column
    for _,line in ipairs(lines)do
        local position=line:find('ONLINE',1,true)
        if position then if column then assert(column==position)else column=position end end
    end
    assert(column)
end)

if failures > 0 then error(tostring(failures) .. ' central regression tests failed') end
