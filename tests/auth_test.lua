local auth = assert(loadfile("service/auth.lua"))()

local function equal(actual, expected)
    assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end

equal(auth.sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
equal(auth.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
equal(auth.hmac(string.rep(string.char(0x0b), 20), "Hi There"),
    "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
equal(auth.hmac("Jefe", "what do ya want for nothing?"),
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")

local root = string.rep("01", 32)
local key = auth.deriveNodeKey(root, "BLUE", "computer-1")
assert(#key == 64 and key ~= auth.deriveNodeKey(root, "BLUE", "computer-2"))
local encoded = auth.sign(key, 4510, {
    networkId="BLUE",keyId="computer-1",destination="CENTRAL",senderEpoch=3,receiverEpoch=8,
    sequence=7,hopLimit=6,body="serialized envelope",
})
local frame = assert(auth.decode(encoded))
assert(auth.verify(key, 4510, frame))
assert(not auth.verify(key, 4511, frame))
for field,replacement in pairs({networkId="RED",keyId="computer-2",destination="RADAR-01",
    senderEpoch=4,receiverEpoch=9,sequence=8,hopLimit=7,body="changed",tag=string.rep("0",64)}) do
    local changed={}
    for name,value in pairs(frame) do changed[name]=value end
    changed[field]=replacement
    assert(not auth.verify(key, 4510, changed),field.." mutation authenticated")
end

local forwarded = assert(auth.forward(frame))
local relayed = assert(auth.decode(forwarded))
equal(relayed.hopsRemaining, 5)
assert(auth.verify(key, 4510, relayed))

local replay = {epoch=3}
assert(auth.acceptSequence(replay, 3, 10, 4))
assert(auth.acceptSequence(replay, 3, 8, 4))
assert(not auth.acceptSequence(replay, 3, 10, 4))
assert(auth.acceptSequence(replay, 3, 12, 4))
assert(not auth.acceptSequence(replay, 3, 8, 4))
assert(not auth.acceptSequence(replay, 2, 13, 4))

assert(not auth.decode("garbage"))
assert(not auth.decode(encoded .. "trailing"))

local epochPath=os.tmpname()
os.remove(epochPath)
local filesystem={
    exists=function(path)local file=io.open(path,"r");if file then file:close();return true end return false end,
    rename=function(from,to)return os.rename(from,to)end,
    remove=function(path)return os.remove(path)end,
}
equal(auth.promoteEpoch(epochPath,filesystem),1)
equal(auth.promoteEpoch(epochPath,filesystem),2)
os.remove(epochPath)
assert(os.rename(epochPath..".previous",epochPath))
equal(auth.promoteEpoch(epochPath,filesystem),2)
os.remove(epochPath);os.remove(epochPath..".previous");os.remove(epochPath..".tmp")
print("PASS authenticated frames, crypto vectors, forwarding, and replay window")
