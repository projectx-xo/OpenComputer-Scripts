local service = require('stratcom.service')
local event = require('event')
local computer = require('computer')
local term = require('term')
local args = {...}
local forceConsole=args[1]=='console'
local forceDashboard=args[1]=='dashboard'
if forceConsole or forceDashboard then table.remove(args,1) end
local function hasDashboard()
    local chunk=loadfile('/home/stratcom/service-config.lua')
    if not chunk then return false end
    local ok,c=pcall(chunk);return ok and type(c)=='table' and (c.kind=='node' or c.kind=='central')
end
local function dashboard()
    while true do
        local version=service.status().version
        if type(version)~='string' or not version:match('^[%w][%w%.%_%-]*$') then return 'console' end
        local dir='/home/stratcom/releases/'..version..'/ui/'
        local view=loadfile(dir..'node_status.lua');local model=loadfile(dir..'node_status_model.lua')
        if not view or not model then return 'console' end
        local ok,result=pcall(function()return view()(service,model())end)
        if not ok then print('Dashboard unavailable: '..tostring(result));return 'console' end
        if result~='reload' then return result end
    end
end
local alertCursor=0
local function readAlerts()
    if not service.alerts then return '' end
    local batch,nextCursor,missed=service.alerts(alertCursor)
    alertCursor=nextCursor
    local lines={}
    if (missed or 0)>0 then lines[#lines+1]='[ALERT] '..missed..' older alerts expired; check logs.' end
    for _,entry in ipairs(batch) do lines[#lines+1]='[ALERT] '..entry.text end
    if #lines>0 and computer.beep then pcall(computer.beep,1000,0.1) end
    return table.concat(lines,'\n')
end
local function showAlerts()
    local text=readAlerts();if text~='' then print(text) end
end
local function execute(line)
    local ok,text=service.command(line)
    if text~=nil then print(text);return end
    local id,e=service.submit(line)
    if not id then print(e);return end
    local deadline=computer.uptime()+60
    while computer.uptime()<deadline do
        showAlerts()
        local reply=service.result(id)
        if reply then print((reply.ok and '' or 'ERROR: ')..reply.text);return end
        local signal=event.pull(0.1)
        if signal=='interrupted' then return end
    end
    print('Command timed out; outcome unknown. Do not repeat one-shot actions without checking status.')
end
if #args>0 then
    local line=table.concat(args,' ')
    -- Local service actions are usable while the app is stopped.
    if not line:match('^service ') and not line:match('^update ') and line~='doctor' and not line:match('^logs') then
        local ok,e=service.start();if not ok then print(e);return end
        local deadline=computer.uptime()+25
        while service.status().state=='starting' and computer.uptime()<deadline do event.pull(0.1) end
    end
    execute(line);return
end
local ok,e=service.start();if not ok then print(e);return end
if hasDashboard() and not forceConsole then
    if dashboard()~='console' then return end
end
print('STRATCOM console. quit or Ctrl+C detaches; service stop stops the application.')
local history={}
-- OpenOS term.read accepts cursor methods on its history table. Handle the wake-up
-- inside the input reader so no detached thread writes over an active edit.
function history:handle(name,...)
    local text=readAlerts()
    if text~='' then
        local data,index,length,hindex,cache=self.data,self.index,self.len,self.hindex,self.cache
        self:move(-self.index)
        self:echo(self.clear)
        self:echo('\n'..text..'\nstratcom> ')
        self:update()
        self:update(data,index-length)
        self.hindex,self.cache=hindex,cache
    end
    return self.super.handle(self,name,...)
end
while true do
    showAlerts()
    io.write('stratcom> ')
    local success,line=pcall(term.read,history)
    if not success or not line then break end
    line=line:gsub('%s+$','')
    if line=='quit' or line=='exit' then break end
    if line=='dashboard' and hasDashboard() then
        if dashboard()~='console' then break end
    elseif line~='' then execute(line) end
end
