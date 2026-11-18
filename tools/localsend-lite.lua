require("ffi").log = function(message) io.stderr:write(message, "\n") end
require("setupkoenv")
local Identity = require("localsend_lite_identity")
local Service = require("localsend_lite_service")
local json = require("rapidjson")
local socket = require("socket")

local usage = "localsend-lite list | localsend-lite send --to NICKNAME --file PATH [--file PATH ...]"
local service

local function parseSendArguments()
    local recipient, paths = nil, {}
    for index = 4, #arg, 2 do
        local option, value = arg[index], arg[index + 1]
        assert(value and value ~= "", usage)
        if option == "--to" and not recipient then
            recipient = value
        elseif option == "--file" then
            paths[#paths + 1] = value:sub(1, 1) == "/" and value or arg[2] .. "/" .. value
        else
            error(usage, 0)
        end
    end
    assert(recipient and #paths > 0 and #paths <= Service.MAX_FILES, usage)
    return recipient, paths
end

local function run()
    local command = arg[3]
    assert(command == "list" and #arg == 3 or command == "send", usage)
    local recipient, source_paths
    if command == "send" then recipient, source_paths = parseSendArguments() end
    local identity = Identity.open(arg[1])
    service = Service.new{
        alias = "LocalSend Lite CLI",
        model = "Linux",
        identity = identity,
        port = 53324,
        receive_directory = arg[1],
        callbacks = { offer = function(_, respond) respond(false) end },
    }
    local source_files = {}
    for _, path in ipairs(source_paths or {}) do
        source_files[#source_files + 1] = service:file(path)
    end
    service:start()
    assert(service:announce(true))
    local discovery_deadline = socket.gettime() + 4
    local repeat_announcement = socket.gettime() + 2
    while socket.gettime() < discovery_deadline do
        service:tick()
        if repeat_announcement and socket.gettime() >= repeat_announcement then
            assert(service:announce(true))
            repeat_announcement = nil
        end
        socket.sleep(0.02)
    end

    local peers = service:listPeers()
    if command == "list" then
        return { devices = json.array(peers) }
    end
    local target
    for _, peer in ipairs(peers) do
        if peer.alias == recipient or peer.fingerprint == recipient then
            assert(not target or target.fingerprint == peer.fingerprint,
                "Several devices match; target an exact fingerprint")
            if not target or target.protocol ~= "https" then target = peer end
        end
    end
    assert(target, "No device matched; open Receive files on the reader and check the displayed nickname")
    assert(target.protocol == "https", "The target must use HTTPS")
    local finished, succeeded, detail
    service:send(target, source_files, nil, function(success, result)
        finished, succeeded, detail = true, success, result
    end)
    while not finished do
        service:tick()
        socket.sleep(0.005)
    end
    assert(succeeded, "Transfer failed: " .. tostring(detail))
    return { recipient = target.alias, sent = detail or #source_files, requested = #source_files }
end

local success, result = pcall(run)
if service then service:stop() end
if not success then
    io.write(json.encode({ error = tostring(result) }), "\n")
    os.exit(1)
end
io.write(json.encode(result), "\n")
if result.sent and result.sent < result.requested then os.exit(1) end
