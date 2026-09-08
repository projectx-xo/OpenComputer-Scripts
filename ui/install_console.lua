-- Migrate only the unmodified shipped console; never replace supervisor helpers.
return function(appDir)
    local updater=require('stratcom.update')
    local destination='/usr/bin/stratcom.lua'
    local wanted=assert(updater.read(appDir..'/service/console.lua'),'Bundled console missing')
    assert(load(wanted,'@stratcom-console','t',{}))
    local current=updater.read(destination)
    if current==wanted then return true end
    local previous=updater.previous()
    local prior=previous and updater.read(updater.directory(previous)..'/service/console.lua')
    if current and current~=prior and updater.checksum(current)~='1a3ac368' then
        return false,'Custom console retained; use the bundled service/console.lua to try the node dashboard.'
    end
    if current then updater.write('/home/stratcom/console-backups/'..updater.checksum(current)..'.lua',current) end
    updater.write(destination,wanted)
    return true,'Node dashboard installed. Reopen stratcom to display it.'
end
