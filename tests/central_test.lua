-- Run from the repository root with Lua 5.2+; hardware boundaries are simulated.
local function extract(first, following, env)
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

test('counterstrike suggestions require a fired interceptor and the same track origin',function()
    local lines={}
    local env={now=function()return 20 end,activeEngagements={},historyPush=function()end,
        launchSites={[7]={id=7,x=507,z=1709,confidence='LOW'}},print=function(s)lines[#lines+1]=s end}
    local finish=extract('finishEngagement','launchPendingEngagement',env)
    finish({trackKey='RADAR:2',launchSiteId=7},'UNCONFIRMED','CONTACT_LOST_AFTER_ENGAGEMENT')
    assert(env.latestCounterstrike==nil,'unacknowledged launch produced a retaliation suggestion')
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

if failures > 0 then error(tostring(failures) .. ' central regression tests failed') end
