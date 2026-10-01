local M = {}

local MOD = 4294967296
local bit = rawget(_G, "bit32")
if not bit then
    local loader = load or loadstring
    local function native(source)
        local chunk = assert(loader(source))
        return chunk()
    end
    local band2 = native("return function(a,b) return (a & b) & 0xffffffff end")
    local bor2 = native("return function(a,b) return (a | b) & 0xffffffff end")
    local bxor2 = native("return function(a,b) return (a ~ b) & 0xffffffff end")
    local function fold(operation, first, ...)
        local value = first
        for index = 1, select("#", ...) do value = operation(value, select(index, ...)) end
        return value
    end
    bit = {
        band = function(first, ...) return fold(band2, first, ...) end,
        bor = function(first, ...) return fold(bor2, first, ...) end,
        bxor = function(first, ...) return fold(bxor2, first, ...) end,
        bnot = native("return function(a) return (~a) & 0xffffffff end"),
        rshift = native("return function(a,n) return (a >> n) & 0xffffffff end"),
        rrotate = native("return function(a,n) n=n%32; return ((a >> n) | (a << (32-n))) & 0xffffffff end"),
    }
end

local band, bxor, bnot, rshift, rrotate = bit.band, bit.bxor, bit.bnot, bit.rshift, bit.rrotate
local K = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}

local function add(...)
    local value = 0
    for index = 1, select("#", ...) do value = (value + select(index, ...)) % MOD end
    return value
end

local function word(value)
    return string.char(
        band(rshift(value, 24), 255), band(rshift(value, 16), 255),
        band(rshift(value, 8), 255), band(value, 255)
    )
end

local function sha256Raw(message)
    assert(type(message) == "string", "message must be a string")
    local bitLength = #message * 8
    local high = math.floor(bitLength / MOD)
    local low = bitLength % MOD
    local padding = (56 - ((#message + 1) % 64)) % 64
    message = message .. "\128" .. string.rep("\0", padding) .. word(high) .. word(low)
    local h = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}
    local w = {}
    for offset = 1, #message, 64 do
        for index = 0, 15 do
            local a,b,c,d = message:byte(offset + index * 4, offset + index * 4 + 3)
            w[index] = ((a * 256 + b) * 256 + c) * 256 + d
        end
        for index = 16, 63 do
            local x, y = w[index - 15], w[index - 2]
            local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
            local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
            w[index] = add(w[index - 16], s0, w[index - 7], s1)
        end
        local a,b,c,d,e,f,g,hh = h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8]
        for index = 0, 63 do
            local s1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
            local choice = bxor(band(e, f), band(bnot(e), g))
            local t1 = add(hh, s1, choice, K[index + 1], w[index])
            local s0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
            local majority = bxor(band(a, b), band(a, c), band(b, c))
            local t2 = add(s0, majority)
            hh,g,f,e,d,c,b,a = g,f,e,add(d,t1),c,b,a,add(t1,t2)
        end
        h[1],h[2],h[3],h[4] = add(h[1],a),add(h[2],b),add(h[3],c),add(h[4],d)
        h[5],h[6],h[7],h[8] = add(h[5],e),add(h[6],f),add(h[7],g),add(h[8],hh)
    end
    local result = {}
    for index = 1, 8 do result[index] = word(h[index]) end
    return table.concat(result)
end

local function toHex(value)
    return (value:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end

local function fromHex(value)
    if type(value) ~= "string" or #value % 2 ~= 0 or value:find("[^0-9a-fA-F]") then return nil end
    return (value:gsub("..", function(byte) return string.char(tonumber(byte, 16)) end))
end

function M.sha256(value) return toHex(sha256Raw(value)) end

function M.hmac(key, message)
    assert(type(key) == "string" and type(message) == "string", "HMAC inputs must be strings")
    if #key > 64 then key = sha256Raw(key) end
    key = key .. string.rep("\0", 64 - #key)
    local inner, outer = {}, {}
    for index = 1, 64 do
        local byte = key:byte(index)
        inner[index], outer[index] = string.char(bxor(byte, 0x36)), string.char(bxor(byte, 0x5c))
    end
    return toHex(sha256Raw(table.concat(outer) .. sha256Raw(table.concat(inner) .. message)))
end

function M.fromHex(value) return fromHex(value) end

local function lp(value)
    value = tostring(value)
    return tostring(#value) .. ":" .. value
end

function M.deriveNodeKey(rootHex, networkId, identity)
    local root = assert(fromHex(rootHex), "invalid root key")
    assert(#root == 32, "root key must contain 32 bytes")
    return M.hmac(root, lp("STRATCOM-NODE-v1") .. lp(networkId) .. lp(identity))
end

function M.constantEquals(left, right)
    if type(left) ~= "string" or type(right) ~= "string" then return false end
    local difference = #left == #right and 0 or 1
    local length = math.max(#left, #right)
    for index = 1, length do
        difference = bit.bor(difference, bxor(left:byte(index) or 0, right:byte(index) or 0))
    end
    return difference == 0
end

local function validText(value, maximum, pattern)
    return type(value) == "string" and #value > 0 and #value <= maximum and (not pattern or value:match(pattern))
end

local function validInteger(value, maximum)
    return type(value) == "number" and value >= 0 and value <= maximum and value % 1 == 0
end

local function macInput(port, frame)
    local values = {"STRATCOM-AUTH-3", port, frame.networkId, frame.keyId, frame.destination,
        frame.senderEpoch, frame.receiverEpoch, frame.sequence, frame.hopLimit, frame.body}
    local result = {}
    for index, value in ipairs(values) do result[index] = lp(value) end
    return table.concat(result)
end

function M.sign(keyHex, port, fields)
    local key = assert(fromHex(keyHex), "invalid node key")
    assert(#key == 32, "node key must contain 32 bytes")
    local frame = {
        networkId = assert(fields.networkId), keyId = assert(fields.keyId), destination = assert(fields.destination),
        senderEpoch = assert(fields.senderEpoch), receiverEpoch = assert(fields.receiverEpoch),
        sequence = assert(fields.sequence), hopLimit = assert(fields.hopLimit),
        hopsRemaining = fields.hopsRemaining == nil and fields.hopLimit or fields.hopsRemaining,
        body = assert(fields.body),
    }
    frame.tag = M.hmac(key, macInput(port, frame))
    local values = {frame.networkId,frame.keyId,frame.destination,frame.senderEpoch,frame.receiverEpoch,
        frame.sequence,frame.hopLimit,frame.hopsRemaining,frame.body,frame.tag}
    local encoded = {}
    for index, value in ipairs(values) do encoded[index] = lp(value) end
    return table.concat(encoded)
end

function M.decode(encoded)
    if type(encoded) ~= "string" or #encoded > 140000 then return nil, "FRAME_SIZE" end
    local values, position = {}, 1
    for index = 1, 10 do
        local colon = encoded:find(":", position, true)
        if not colon or colon - position > 7 then return nil, "FRAME_FORMAT" end
        local sizeText = encoded:sub(position, colon - 1)
        if sizeText == "" or sizeText:find("[^0-9]") then return nil, "FRAME_FORMAT" end
        local size = tonumber(sizeText)
        if not size or size > 131072 or colon + size > #encoded then return nil, "FRAME_SIZE" end
        values[index] = encoded:sub(colon + 1, colon + size)
        position = colon + size + 1
    end
    if position <= #encoded then return nil, "FRAME_TRAILING" end
    local frame = {
        networkId=values[1],keyId=values[2],destination=values[3],senderEpoch=tonumber(values[4]),
        receiverEpoch=tonumber(values[5]),sequence=tonumber(values[6]),hopLimit=tonumber(values[7]),
        hopsRemaining=tonumber(values[8]),body=values[9],tag=values[10],
    }
    if not validText(frame.networkId, 32, "^[%w_.%-]+$")
        or not validText(frame.keyId, 64, "^[%w_.%-]+$")
        or not validText(frame.destination, 64, "^[%w_%-]+$")
        or not validInteger(frame.senderEpoch, 9007199254740991)
        or not validInteger(frame.receiverEpoch, 9007199254740991)
        or not validInteger(frame.sequence, 9007199254740991)
        or not validInteger(frame.hopLimit, 16)
        or not validInteger(frame.hopsRemaining, frame.hopLimit)
        or #frame.body > 131072
        or not validText(frame.tag, 64, "^[0-9a-f]+$") or #frame.tag ~= 64 then return nil, "FRAME_FIELDS" end
    return frame
end

function M.verify(keyHex, port, frame)
    local key = fromHex(keyHex)
    if not key or #key ~= 32 or type(frame) ~= "table" then return false end
    return M.constantEquals(frame.tag, M.hmac(key, macInput(port, frame)))
end

function M.forward(frame)
    if type(frame) ~= "table" or frame.hopsRemaining <= 0 then return nil end
    local copy = {}
    for key, value in pairs(frame) do copy[key] = value end
    copy.hopsRemaining = copy.hopsRemaining - 1
    local values = {copy.networkId,copy.keyId,copy.destination,copy.senderEpoch,copy.receiverEpoch,
        copy.sequence,copy.hopLimit,copy.hopsRemaining,copy.body,copy.tag}
    local encoded = {}
    for index, value in ipairs(values) do encoded[index] = lp(value) end
    return table.concat(encoded)
end

function M.acceptSequence(state, epoch, sequence, window)
    window = window or 64
    if type(state) ~= "table" or state.epoch ~= epoch or not validInteger(sequence, 9007199254740991) then return false end
    state.maximum, state.seen = state.maximum or -1, state.seen or {}
    if sequence <= state.maximum - window then return false end
    if state.seen[sequence] then return false end
    state.seen[sequence] = true
    if sequence > state.maximum then state.maximum = sequence end
    local minimum = state.maximum - window
    for value in pairs(state.seen) do if value <= minimum then state.seen[value] = nil end end
    return true
end

function M.readKeyFile(path)
    local file = assert(io.open(path, "r"), "cannot open key file")
    local text = assert(file:read("*a")); file:close()
    local header = (text:match("^([^\n]*)") or ""):gsub("\r$", "")
    assert(header == "STRATCOM-KEY-1", "invalid key file header")
    local networkId = text:match("network=([%w_.%-]+)")
    local rootKey = text:match("key=([0-9a-fA-F]+)")
    assert(networkId and #networkId <= 32, "invalid network ID")
    assert(rootKey and #rootKey == 64, "key must be 64 hexadecimal characters")
    return networkId, rootKey:lower()
end

function M.readState(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local mode, networkId, identity, key = file:read("*l"),file:read("*l"),file:read("*l"),file:read("*l")
    file:close()
    if (mode ~= "central" and mode ~= "node") or not validText(networkId, 32, "^[%w_.%-]+$")
        or not validText(identity, 64, "^[%w_.%-]+$") or not key or #key ~= 64 or key:find("[^0-9a-f]") then return nil end
    return {mode=mode,networkId=networkId,identity=identity,key=key}
end

function M.stateText(mode, networkId, identity, key)
    assert(mode == "central" or mode == "node", "invalid auth mode")
    assert(validText(networkId, 32, "^[%w_.%-]+$"), "invalid network ID")
    assert(validText(identity, 64, "^[%w_.%-]+$"), "invalid identity")
    assert(type(key) == "string" and #key == 64 and not key:find("[^0-9a-f]"), "invalid key")
    return table.concat({mode, networkId, identity, key, ""}, "\n")
end

function M.promoteEpoch(path, filesystem)
    local backup = path .. ".previous"
    if not filesystem.exists(path) and filesystem.exists(backup) then
        assert(filesystem.rename(backup, path), "cannot recover auth epoch")
    end
    local current = 0
    local input = io.open(path, "r")
    if input then current = tonumber(input:read("*l")) or 0; input:close() end
    assert(current >= 0 and current < 9007199254740990 and current % 1 == 0, "invalid auth epoch")
    local nextEpoch, temporary = current + 1, path .. ".tmp"
    local output = assert(io.open(temporary, "w"))
    assert(output:write(tostring(nextEpoch) .. "\n")); assert(output:flush())
    local closed, closeError = output:close()
    assert(closed ~= false and closeError == nil, tostring(closeError))
    if filesystem.exists(backup) then assert(filesystem.remove(backup)) end
    if filesystem.exists(path) then assert(filesystem.rename(path, backup), "cannot back up auth epoch") end
    local promoted, promoteError = filesystem.rename(temporary, path)
    if not promoted then
        if filesystem.exists(backup) then filesystem.rename(backup, path) end
        error("cannot promote auth epoch: " .. tostring(promoteError))
    end
    return nextEpoch
end

return M
