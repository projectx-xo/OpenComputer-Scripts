local service = require('stratcom.service')
local event = require('event')
local computer = require('computer')
local term = require('term')
local args = {...}
local function execute(line)
    local ok,text=service.command(line)
    if text~=nil then print(text);return end
    local id,e=service.submit(line)
    if not id then print(e);return end
    local deadline=computer.uptime()+60
    while computer.uptime()<deadline do
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
print('STRATCOM console. quit or Ctrl+C detaches; service stop stops the application.')
local history={}
while true do
    io.write('stratcom> ')
    local success,line=pcall(term.read,history)
    if not success or not line then break end
    line=line:gsub('%s+$','')
    if line=='quit' or line=='exit' then break end
    if line~='' then execute(line) end
end
