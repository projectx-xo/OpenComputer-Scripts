-- rc unload discards this wrapper; the package.loaded service retains its worker.
local service = require('stratcom.service')
function start() return service.start() end
function stop() return service.stop() end
function restart() return service.restart() end
function status() local s=service.status();print(s.state..' '..tostring(s.version)) end
