-- Stable updater: application bundles never overwrite the running application.
local fs = require('filesystem')
local M = {}
local root = '/home/stratcom'
M.defaultSource = 'https://raw.githubusercontent.com/projectx-xo/OpenComputer-Scripts/main/release.lua'
local required = {'central/central.lua','bootstrap/bootstrap.lua','runtime/manifest.lua','runtime/strike.lua','runtime/launchpad.lua','runtime/radar.lua','runtime/intel.lua','service/stratcom.lua','service/update.lua','service/rc.lua','service/console.lua','install.lua'}
M.required = required
function M.read(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('*a'); f:close(); return s
end
function M.write(path, text)
    local parent=path:match('^(.*)/')
    if not fs.exists(parent) then assert(fs.makeDirectory(parent)) end
    local f = assert(io.open(path .. '.tmp', 'w'))
    local ok, err = f:write(text)
    -- OpenOS close() returns no value on success and discards flush errors.
    local flushed, flushErr = f:flush()
    local closed, closeErr = f:close()
    assert(ok, 'write '..path..': '..tostring(err))
    assert(flushed, 'flush '..path..': '..tostring(flushErr))
    assert(closed~=false and closeErr==nil, 'close '..path..': '..tostring(closeErr))
    assert(fs.rename(path .. '.tmp', path))
    return true
end
function M.checksum(s)
    local a, b = 1, 0
    for i = 1, #s do a = (a + s:byte(i)) % 65521; b = (b + a) % 65521 end
    return string.format('%08x', b * 65536 + a)
end
-- Parse only a data subset of Lua. No execution, duplicate keys, or expressions.
local function parse(s)
    local i = 1
    local function skip() local _, e = s:find('^%s*', i); i = (e or i - 1) + 1 end
    local function token(p)
        skip(); local a, b = s:find('^' .. p, i)
        if a then local v = s:sub(a,b); i = b + 1; return v end
    end
    local value
    local function str()
        skip(); local q = s:sub(i,i)
        if q ~= '"' and q ~= "'" then return nil end
        i = i + 1; local e = assert(s:find(q, i, true), 'unterminated string')
        local v = s:sub(i,e-1); assert(not v:find('[\\\r\n]'), 'escaped strings unsupported'); i=e+1; return v
    end
    value = function()
        if token('{') then
            local t = {}
            while not token('}') do
                local k
                if token('%[') then k = assert(str(), 'string key required'); assert(token('%]'))
                else k = assert(token('[%a_][%w_]*'), 'key required') end
                assert(t[k] == nil, 'duplicate key: '..k); assert(token('='))
                t[k] = value()
                if not token(',') then assert(token('}')); break end
            end
            return t
        end
        local v = str(); if v ~= nil then return v end
        return assert(tonumber(token('%d+')), 'invalid manifest value')
    end
    assert(token('return%s+'), 'manifest must return data')
    local t = value(); skip(); assert(i > #s, 'trailing manifest code'); return t
end
local function validVersion(v) return type(v)=='string' and #v<=80 and v:match('^[%w][%w%.%_%-]*$') end
local function fetch(url, limit)
    local request = assert(require('internet').request(url))
    local chunks, size = {}, 0
    for chunk in request do
        size = size + #chunk; assert(size <= limit, 'download exceeds size limit')
        chunks[#chunks+1] = chunk
    end
    return table.concat(chunks)
end
local function sourceURL(source)
    source = source or M.read(root..'/source.txt') or M.defaultSource
    source = source:gsub('%s+$','')
    local repo = source:match('^(https://raw%.githubusercontent%.com/[%w_.%-]+/[%w_.%-]+)/.+/release%.lua$')
    assert(repo, 'source must be an HTTPS raw GitHub release.lua URL')
    return source, repo
end
function M.directory(version)
    assert(validVersion(version), 'invalid version')
    return root..'/releases/'..version
end
function M.current() return M.read(root..'/current.txt') end
function M.previous() return M.read(root..'/previous.txt') end
function M.pending() return M.read(root..'/pending.txt') end
local function stage(source, progress, localDir)
    local ok, result = pcall(function()
        local raw,repo
        if localDir then
            assert(type(localDir)=='string' and localDir~='', 'local release directory required')
            if progress then progress('checking local bundle '..localDir) end
            raw=assert(M.read(localDir..'/release.lua'),'local release.lua missing')
            assert(#raw<=65536,'manifest exceeds size limit')
        else
            local url;url,repo=sourceURL(source)
            if progress then progress('checking '..url) end
            raw=fetch(url,65536)
        end
        local manifest = parse(raw)
        assert(validVersion(manifest.version), 'invalid version')
        assert(type(manifest.ref)=='string' and #manifest.ref==40 and manifest.ref:match('^%x+$'), 'release ref must be a commit SHA')
        assert(type(manifest.files)=='table', 'missing files')
        for _, path in ipairs(required) do assert(manifest.files[path], 'incomplete release: '..path) end
        for path, meta in pairs(manifest.files) do
            assert(type(path)=='string' and path:match('^[%w_%-/%.]+%.lua$') and not path:find('..',1,true) and path:sub(1,1)~='/' and not path:find('//',1,true), 'invalid release path')
            assert(type(meta)=='table' and type(meta.size)=='number' and meta.size>=0 and meta.size<=2097152 and meta.size%1==0, 'invalid file size')
            assert(type(meta.checksum)=='string' and #meta.checksum==8 and meta.checksum:match('^%x+$'), 'invalid checksum')
        end
        local dir = M.directory(manifest.version)
        if fs.exists(dir..'/release.lua') then
            assert(M.read(dir..'/release.lua')==raw, 'version already exists with different content')
            for path,meta in pairs(manifest.files) do
                local text=assert(M.read(dir..'/'..path),'cached bundle incomplete: '..path)
                assert(#text==meta.size and M.checksum(text)==meta.checksum:lower(),'cached bundle integrity failure: '..path)
                assert(load(text,'@'..path,'t',{}))
            end
            return manifest.version
        end
        assert(manifest.version~=M.current() and manifest.version~=M.previous(), 'cannot overwrite active or previous bundle')
        for path, meta in pairs(manifest.files) do
            if progress then progress((localDir and 'copying ' or 'downloading ')..path) end
            local text
            if localDir then text=assert(M.read(localDir..'/'..path),'local bundle file missing: '..path)
            else text=fetch(repo..'/'..manifest.ref..'/'..path,meta.size) end
            assert(#text==meta.size and M.checksum(text)==meta.checksum:lower(), 'integrity failure: '..path)
            assert(load(text,'@'..path,'t',{}))
            M.write(dir..'/'..path, text)
        end
        -- Completion marker is written last; incomplete directories cannot activate.
        M.write(dir..'/release.lua',raw)
        return manifest.version
    end)
    if ok then return result end
    return nil, tostring(result)
end
function M.stage(source,progress) return stage(source,progress) end
function M.stageLocal(directory,progress) return stage(nil,progress,directory) end
local function attempt(fn) local ok,e=pcall(fn);if ok then return true end return nil,tostring(e) end
function M.activate(version)
    return attempt(function()
        assert(M.read(M.directory(version)..'/release.lua'), 'bundle incomplete')
        local current = M.current()
        if current==version then return end
        assert(not M.pending(), 'activation already pending')
        -- Journal precedes pointer changes. Recovery always restores this old value.
        M.write(root..'/pending.txt', current or '')
        if current then M.write(root..'/previous.txt',current) end
        M.write(root..'/current.txt',version)
    end)
end
function M.confirm() return attempt(function() if M.pending() then assert(fs.remove(root..'/pending.txt')) end end) end
function M.recover()
    return attempt(function()
        local old = M.pending()
        if old==nil then return end
        local bad = M.current()
        if bad and bad~=old then M.write(root..'/rejected.txt',bad) end
        if old~='' then M.write(root..'/current.txt',old)
        elseif M.current() then assert(fs.remove(root..'/current.txt')) end
        assert(fs.remove(root..'/pending.txt'))
    end)
end
function M.rollback()
    local previous=M.previous()
    if not previous then return nil,'no previous bundle' end
    return M.activate(previous)
end
return M
