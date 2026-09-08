-- Presentation only. No hardware writes or control commands.
return function(snapshot, service, logText, age)
    local rows={}
    local function clean(v)
        local s=tostring(v==nil and '--' or v)
        return (s:gsub('[%c]',' '))
    end
    local function row(text,tone)rows[#rows+1]={text=clean(text),tone=tone or 'normal'}end
    local function yes(v)return v==nil and '--' or (v and 'YES' or 'NO')end
    snapshot=snapshot or {};service=service or {};local h=type(snapshot.health)=='table' and snapshot.health or {}
    row('STRATCOM  /  FIELD NODE','title')
    row(clean(snapshot.id or 'WAITING FOR NODE')..'  ['..clean(snapshot.role=='intel' and 'sat' or snapshot.role or 'unassigned'):upper()..']','title')
    row('Service: '..clean(service.state)..'   Runtime: '..clean(snapshot.state),service.state=='running' and 'good' or 'warn')
    row('Intent: '..clean(snapshot.intent)..'   Bundle: '..clean(service.version))
    row('Bootstrap: '..clean(snapshot.bootstrap)..'   Role version: '..clean(snapshot.runtime))
    local centralAge=tonumber(snapshot.centralAge)
    if centralAge then centralAge=centralAge+(age or 0) end
    row('CENTRAL: '..(snapshot.controller and (centralAge and centralAge<=15 and 'RECENT CONTACT' or 'NO RECENT CONTACT') or 'UNCLAIMED'),
        snapshot.controller and centralAge and centralAge<=15 and 'good' or 'warn')
    local teams,seen={},{}
    for _,a in ipairs(type(snapshot.assets)=='table' and snapshot.assets or {}) do
        if a.source=='BASECENTER' and type(a.team)=='string' and a.team~='' and not seen[a.team] then seen[a.team]=true;teams[#teams+1]=clean(a.team) end
    end
    row('Team: '..(#teams>0 and table.concat(teams,' / ') or 'UNKNOWN - register equipment'))
    row('EQUIPMENT','section')
    if snapshot.error then row(snapshot.error,'bad') end
    if h.multiLauncher then
        row('Ready '..clean(h.readyCount)..'/'..clean(h.launcherCount)..'   Armed '..clean(h.armedCount)..'   Queued '..clean(h.strikeRemaining),h.armed and 'warn' or 'normal')
        for i,l in ipairs(h.launchers or {}) do
            if i>16 then row('Additional launchers omitted. Use console status.','warn');break end
            row('L'..clean(l.index or i)..'  '..clean(l.missileLabel)..'  READY '..yes(l.ready)..'  ARMED '..yes(l.armed),l.armed and 'warn' or (l.ready and 'good' or 'normal'))
        end
        if h.logisticsBusy then row('Logistics transfer active','warn') end
    elseif h.radarStation then
        row('Radars: '..clean(h.radarCount)..'   Active tracks: '..clean(h.activeTrackCount),'good')
    elseif h.intelligence then
        row(clean(h.satelliteType or 'Intelligence satellite'))
        row('Scan: '..clean(h.scanState)..'   '..clean(h.scanProgress),h.busy and 'warn' or 'normal')
    elseif h.nuclearDetection then
        row('Nuclear Detection Satellite')
        row('Ready: '..yes(h.ready)..'   Report awaiting ACK: '..yes(h.pending),h.ready and 'good' or 'warn')
    elseif snapshot.role=='defense' or snapshot.role=='strike' then
        row('Payload: '..clean(h.missileLabel))
        row('Ready: '..yes(h.ready)..'   Armed: '..yes(h.armed),h.armed and 'warn' or (h.ready and 'good' or 'normal'))
        row('Energy: '..clean(h.energy)..'   Fuel: '..clean(h.fuel)..'   Oxidizer: '..clean(h.oxidizer))
    else row('Waiting for hardware / runtime enrollment.','warn') end
    if h.error then row(h.error,'bad') end
    row('UPDATE','section')
    row(clean(service.update):gsub('; stable helpers require reinstall when changed',''))
    if service.busy then row('Busy: updates wait for idle.','warn') end
    row('RECENT EVENTS','section')
    local n=0
    for line in tostring(logText or ''):gmatch('[^\n]+') do
        n=n+1;if n<=6 then row(line) end
    end
    return rows
end
