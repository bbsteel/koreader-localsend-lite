-- Run with KOReader's LuaJIT and its bundled Lua modules. Argument is a scratch
-- directory that the runner will clean up.
require("setupkoenv")
local Identity = require("localsend_lite_identity")
local Service = require("localsend_lite_service")
local Http = require("localsend_lite_http")
local socket = require("socket")
local lfs = require("libs/libkoreader-lfs")
local json = require("rapidjson")
local KindleNetwork = require("localsend_lite_kindle")
local openLog = require("localsend_lite_log")
local root = assert(arg[1])
local payload = ("KOReader\0LocalSend\n"):rep(65536)
local sender_dir, receiver_dir = root .. "/sender", root .. "/receiver"
assert(lfs.mkdir(sender_dir))
assert(lfs.mkdir(receiver_dir))

local installed_rules = {}
local function fakeIptables(operation, rule)
    local rule_key = table.concat(rule, " ")
    assert(rule_key:find("wlan0", 1, true) and rule_key:find("53317", 1, true))
    if operation == "-I" then
        assert(not installed_rules[rule_key])
        installed_rules[rule_key] = true
    else
        assert(operation == "-D" and installed_rules[rule_key])
        installed_rules[rule_key] = nil
    end
    return true
end
local close_firewall = assert(KindleNetwork.openFirewall("wlan0", "192.168.1.5",
    53317, 53317, Service.MULTICAST_GROUP, fakeIptables))
local rule_count = 0
for _ in pairs(installed_rules) do rule_count = rule_count + 1 end
assert(rule_count == 4)
close_firewall()
close_firewall()
assert(next(installed_rules) == nil)
local failed_firewall = KindleNetwork.openFirewall("wlan0", "192.168.1.5",
    53317, 53317, Service.MULTICAST_GROUP, function(operation, rule)
        if operation == "-I" and rule[1] == "OUTPUT" then return false end
        return fakeIptables(operation, rule)
    end)
assert(not failed_firewall and next(installed_rules) == nil)

local source_path = sender_dir .. "/sample.epub"
local function write(path, contents)
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end
local function read(path)
    local file = assert(io.open(path, "rb"))
    local content = assert(file:read("*a"))
    file:close()
    return content
end
write(source_path, payload)
write(receiver_dir .. "/sample.epub", "existing")
write(sender_dir .. "/empty.txt", "")

local sender_identity = Identity.open(sender_dir)
local receiver_identity = Identity.open(receiver_dir)
assert(Identity.open(sender_dir).fingerprint == sender_identity.fingerprint)
assert(sender_identity.fingerprint ~= receiver_identity.fingerprint)

local approve, received_files = true, {}
local waiting_offer, closed_offer
local sender = Service.new {
    alias = "KOReader sender", identity = sender_identity, port = 53318,
    receive_directory = sender_dir,
    wifi_address = os.getenv("LOCALSEND_TEST_WIFI_ADDRESS"),
}
local receiver = Service.new {
    alias = "KOReader receiver", identity = receiver_identity, port = 53319,
    receive_directory = receiver_dir,
    wifi_address = os.getenv("LOCALSEND_TEST_WIFI_ADDRESS"),
    callbacks = {
        diagnostic = openLog(root .. "/transfer.log"),
        offer = function(session, respond)
            waiting_offer = session
            if approve ~= nil then respond(approve) end
        end,
        offerClosed = function(session) closed_offer = session end,
        received = function(path) received_files[#received_files + 1] = path end,
    },
}
sender:start()
receiver:start()

local function pump(condition)
    local deadline = socket.gettime() + 8
    repeat
        sender:tick()
        receiver:tick()
        if condition() then return end
        socket.sleep(0.002)
    until socket.gettime() >= deadline
    error("Timed out waiting for LocalSend")
end

local function discover(peers, target)
    for _, candidate in ipairs(peers) do
        if candidate.alias == target.info.alias and candidate.port == target.info.port
            and candidate.protocol == target.info.protocol then return candidate end
    end
end
assert(sender:announce(true))
local peer
pump(function()
    peer = discover(sender:listPeers(), receiver)
    return peer and discover(receiver:listPeers(), sender)
end)

local function send(files)
    local finished, succeeded, result
    sender:send(peer, files, nil, function(ok, detail)
        finished, succeeded, result = true, ok, detail
    end)
    pump(function() return finished end)
    return succeeded, result
end

local invalid_peer = {}
for key, value in pairs(peer) do invalid_peer[key] = value end
invalid_peer.fingerprint = ("F"):rep(64)
local fingerprint_rejected
sender:addTask(function(task)
    Http.request(task, invalid_peer, sender_identity.client, "/api/localsend/v2/info")
end, function(ok, message)
    assert(not ok and message:find("fingerprint changed", 1, true))
    fingerprint_rejected = true
end)
pump(function() return fingerprint_rejected end)

assert(send({ sender:file(source_path, "application/epub+zip"), sender:file(sender_dir .. "/empty.txt", "text/plain") }))
assert(#received_files == 2)
assert(read(receiver_dir .. "/sample.epub") == "existing")
assert(read(receiver_dir .. "/sample (1).epub") == payload)
assert(read(receiver_dir .. "/empty.txt") == "")

local queued_files = {}
local queued_payload = payload:sub(1, 256 * 1024)
for index = 1, 4 do
    local file_id = tostring(index)
    queued_files[file_id] = {
        id = file_id, fileName = "queued-" .. index .. ".epub", size = #queued_payload,
        fileType = "application/epub+zip",
    }
end
local queued_approval
sender:addTask(function(task)
    local status, response = Http.request(task, peer, sender_identity.client, "/api/localsend/v2/prepare-upload",
        json.encode({ info = sender.info, files = queued_files }), "application/json")
    assert(status == 200)
    return json.decode(response)
end, function(ok, result)
    assert(ok, result)
    queued_approval = result
end)
pump(function() return queued_approval end)
local queued_session = receiver.incoming
local completed_uploads = 0
local function uploadQueuedFile(index)
    sender:addTask(function(task)
        local file_id = tostring(index)
        local upload_path = "/api/localsend/v2/upload?sessionId=" .. queued_approval.sessionId
            .. "&fileId=" .. file_id .. "&token=" .. queued_approval.files[file_id]
        assert(Http.request(task, peer, sender_identity.client, upload_path, queued_payload) == 200)
    end, function(ok, failure)
        assert(ok, failure)
        completed_uploads = completed_uploads + 1
    end)
end
for index = 1, 3 do uploadQueuedFile(index) end
pump(function() return completed_uploads == 3 end)
assert(queued_session.total_files == 4 and queued_session.saved == 3)
assert(queued_session.received_bytes == 3 * #queued_payload)
local real_gettime = socket.gettime
socket.gettime = function() return real_gettime() + 125 end
uploadQueuedFile(4)
pump(function() return completed_uploads == 4 end)
socket.gettime = real_gettime
assert(not receiver.incoming and queued_session.saved == 4)
for index = 1, 4 do assert(read(receiver_dir .. "/queued-" .. index .. ".epub") == queued_payload) end
local transfer_log = read(root .. "/transfer.log")
local expected_file = assert(transfer_log:find("receive.expected\tqueued-4.epub", 1, true))
local started_file = assert(transfer_log:find("receive.upload_started\tqueued-4.epub", expected_file, true))
local saved_file = assert(transfer_log:find("receive.saved\tqueued-4.epub\t4\t4", started_file, true))
assert(transfer_log:find("receive.response_sent\tqueued-4.epub\t200", saved_file, true))
assert(not transfer_log:find(queued_approval.files["4"], 1, true))

waiting_offer = nil
local text_offer_rejected
sender:addTask(function(task)
    local status = Http.request(task, peer, sender_identity.client, "/api/localsend/v2/prepare-upload",
        json.encode({ info = sender.info, files = { message = {
            id = "message", fileName = "message.txt", size = 5,
            fileType = "text/plain", preview = "hello",
        } } }), "application/json")
    assert(status == 403)
end, function(ok, failure)
    assert(ok, failure)
    text_offer_rejected = true
end)
pump(function() return text_offer_rejected end)
assert(waiting_offer == nil and not lfs.attributes(receiver_dir .. "/message.txt"))

approve = false
local success, status = send({ sender:file(source_path) })
assert(not success and status == 403)
assert(not lfs.attributes(receiver_dir .. "/sample (2).epub"))
approve, waiting_offer, closed_offer = nil, nil, nil
sender:send(peer, { sender:file(source_path) }, nil, function() error("Cancelled send callback fired") end)
pump(function() return waiting_offer ~= nil end)
sender:cancelSend()
pump(function() return closed_offer == waiting_offer end)
assert(receiver.incoming == nil)

approve = true
local checksum_rejected
sender:addTask(function(task)
    local status, response = Http.request(task, peer, sender_identity.client, "/api/localsend/v2/prepare-upload",
        json.encode({ info = sender.info, files = { checksum = {
            id = "checksum", fileName = "checksum.bin", size = 3,
            fileType = "application/octet-stream", sha256 = ("0"):rep(64),
        } } }), "application/json")
    assert(status == 200)
    local approval = json.decode(response)
    local upload_path = "/api/localsend/v2/upload?sessionId=" .. approval.sessionId
        .. "&fileId=checksum&token=" .. approval.files.checksum
    local upload_status = Http.request(task, peer, sender_identity.client, upload_path, "abc")
    assert(upload_status == 422)
    sender:cancelRemote(peer, approval.sessionId)
end, function(ok, failure)
    assert(ok, failure)
    checksum_rejected = true
end)
pump(function() return checksum_rejected and not receiver.incoming end)
assert(not lfs.attributes(receiver_dir .. "/checksum.bin"))
assert(read(root .. "/transfer.log"):find("receive.upload_rejected\t422\tchecksum mismatch\tchecksum.bin", 1, true))
for name in lfs.dir(receiver_dir) do assert(not name:match("%.part$")) end

receiver.info.protocol = "http"
receiver:announce(true)
pump(function()
    peer = discover(sender:listPeers(), receiver)
    return peer
end)
assert(send({ sender:file(source_path) }))
assert(read(receiver_dir .. "/sample (2).epub") == payload)
sender:stop()
receiver:stop()

local rotation_path = root .. "/rotation.log"
local write_log = openLog(rotation_path)
for index = 1, 450 do write_log("test.entry", index, ("x"):rep(500)) end
write_log("test.sanitized", "line\nbreak", ".localsend-lite-ABC012.part")
local current_log, previous_log = read(rotation_path), read(rotation_path .. ".1")
assert(#current_log <= 65536 and #previous_log <= 65536)
assert(current_log:find("test.sanitized\tline break\t.localsend-lite-<temporary>.part", 1, true))
assert(not previous_log:find("test.entry\t1\t", 1, true))
openLog(root .. "/missing-directory/log")("test.write_failure")
print("PASS: discovery, transfer, delayed fourth upload, per-file diagnostics, and bounded log rotation")
