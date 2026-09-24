local function run(current,prior,fail)
 local files={['/usr/bin/stratcom.lua']=current,['bundle/service/console.lua']='return "new"',
  ['previous/service/console.lua']=prior}
 local updater={read=function(p)return files[p]end,previous=function()return'previous'end,directory=function(v)return v end,
  checksum=function(s)return s=='legacy' and '1a3ac368' or 'custom'end,
  write=function(p,s)if p==fail then error('disk full')end;files[p]=s;return true end}
 local env=setmetatable({require=function()return updater end},{__index=_G})
 local migrate=assert(loadfile('ui/install_console.lua','t',env))()
 local ok,result=pcall(migrate,'bundle')
 return files,ok,result
end
local f,ok,result=run('legacy');assert(ok and result and f['/usr/bin/stratcom.lua']=='return "new"' and f['/home/stratcom/console-backups/1a3ac368.lua']=='legacy')
f,ok,result=run('custom');assert(ok and not result and f['/usr/bin/stratcom.lua']=='custom','custom launcher overwritten')
f,ok,result=run('older','older');assert(ok and result and f['/usr/bin/stratcom.lua']=='return "new"')
f,ok=run('legacy',nil,'/home/stratcom/console-backups/1a3ac368.lua');assert(not ok and f['/usr/bin/stratcom.lua']=='legacy')
f,ok=run('legacy',nil,'/usr/bin/stratcom.lua');assert(not ok and f['/usr/bin/stratcom.lua']=='legacy')
print('PASS console migration: shipped baseline, previous bundle, custom preservation and backup/write failures')
