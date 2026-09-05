-- Run from a checkout, or download this installer from the trusted source channel.
local args = {...}
local kind, role, id = args[1], args[2], args[3]
local source,bundle
for i=1,#args do
    if args[i]=='--source' then assert(args[i+1], '--source requires URL');source=args[i+1] end
    if args[i]=='--bundle' then assert(args[i+1] and args[i+1]~='', '--bundle requires directory');bundle=args[i+1] end
end
assert(kind=='central' or kind=='node', 'usage: install.lua central | node <strike|defense|radar|intel> <id> [--source URL | --bundle DIRECTORY]')
if kind=='node' then
    assert(({strike=true,defense=true,radar=true,intel=true})[role], 'invalid node role')
    assert(type(id)=='string' and id:match('^[%w_%-]+$') and #id<=64, 'invalid node id')
    id=id:upper()
end
assert(not (source and bundle),'choose --source or --bundle')
source=source or 'https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/main/release.lua'
assert(source:match('^https://raw%.githubusercontent%.com/[%w_.%-]+/[%w_.%-]+/.+/release%.lua$'), 'invalid source URL')
local root='/home/stratcom'
local fs=require('filesystem')
-- Check identity before any network access or file changes.
local previous
if fs.exists(root..'/config.lua') then previous=assert(loadfile(root..'/config.lua'))() end
if previous then
    assert(kind=='node' and tostring(previous.id):upper()==id and previous.role==role,
        'existing role/id differs; migrate configuration explicitly before installing')
end
if fs.exists(root..'/service-config.lua') then
    assert(assert(loadfile(root..'/service-config.lua'))().kind==kind, 'existing service kind differs')
end
local ok,update
if bundle then
    -- The copied archive has the same trust boundary as this installer.
    update=assert(loadfile(bundle..'/service/update.lua'))();ok=true
else
    ok,update=pcall(require,'stratcom.update')
end
if not ok then
    local chunk=loadfile('service/update.lua')
    if not chunk then
        -- Same trust boundary as the downloaded installer. The full release below
        -- is pinned and checked before any installed helper or app is replaced.
        local parts,size={},0
        -- string.gsub returns the replacement count as a second value. Keep it
        -- out of internet.request, whose second argument is the request body.
        local updaterURL = source:gsub('release%.lua$','service/update.lua')
        for part in assert(require('internet').request(updaterURL)) do
            size=size+#part;assert(size<131072,'updater too large');parts[#parts+1]=part
        end
        chunk=assert(load(table.concat(parts),'@update-bootstrap','t',_ENV))
    end
    update=chunk()
end
local version,err
if bundle then version,err=update.stageLocal(bundle,print) else version,err=update.stage(source,print) end
assert(version,err)
local dir=update.directory(version)
local helpers={['service/update.lua']='/usr/lib/stratcom/update.lua',['service/stratcom.lua']='/usr/lib/stratcom/service.lua',
    ['service/rc.lua']='/etc/rc.d/stratcom.lua',['service/console.lua']='/usr/bin/stratcom.lua'}
-- Do not replace stable code under an existing supervisor. A stopped service can
-- be reinstalled; the currently loaded module stays in memory until next boot.
local loaded=package.loaded['stratcom.service']
if loaded then
    local state=loaded.status().state
    assert(state=='stopped' or state=='failed','stop the service before reinstalling stable helpers')
end
for from,to in pairs(helpers) do update.write(to,assert(update.read(dir..'/'..from))) end
if kind=='node' and not previous then
    update.write(root..'/config.lua',string.format('return {id=%q,role=%q,managementPort=4510,operationalPort=4511}\n',id,role))
end
if not fs.exists(root..'/service-config.lua') then update.write(root..'/service-config.lua',string.format('return {kind=%q,autoUpdate=%s}\n',kind,tostring(not bundle))) end
update.write(root..'/source.txt',source)
if kind=='node' and not fs.exists(root..'/runtime/current.lua') then
    local manifest=assert(loadfile(dir..'/runtime/manifest.lua'))()
    local runtime=assert(manifest.roles[role],'role missing from runtime manifest')
    local text=assert(update.read(dir..'/'..runtime.path),'runtime missing')
    update.write(root..'/runtime/current.lua',text)
    update.write(root..'/runtime/version.txt',runtime.version..'\n')
end
assert(update.recover())
local fresh=not update.current()
if fresh then assert(update.activate(version));assert(update.confirm()) end
local rcenv={}
local rcchunk=loadfile('/etc/rc.cfg','t',rcenv)
if rcchunk then assert(pcall(rcchunk)) end
local enabled=false
for _,name in ipairs(rcenv.enabled or {}) do if name=='stratcom' then enabled=true end end
if not enabled then assert(require('shell').execute('rc stratcom enable'), 'could not enable boot service') end
if loaded then
    package.loaded['stratcom.service']=nil
    package.loaded['stratcom.update']=nil
    local hasRC,rc=pcall(require,'rc')
    if hasRC and rc.loaded then rc.loaded.stratcom=nil end
end
local service=require('stratcom.service')
assert(service.start())
if not fresh and version~=update.current() then assert(service.apply(version)) end
print('Installed '..version..'. Use stratcom to attach; no reboot required.')
