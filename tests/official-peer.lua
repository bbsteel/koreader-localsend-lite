-- Small test entry point for the plugin transport. The official CLI is the other peer.
require("setupkoenv")
local Service = require("localsend_lite_service")
local Identity = require("localsend_lite_identity")
local nickname = require("localsend_lite_alias")
local socket = require("socket")

local root, mode, path = assert(arg[1]), assert(arg[2]), arg[3]
local service = Service.new{
    alias = nickname(("0"):rep(64), "zh_TW"),
    identity = Identity.open(root),
    port = 53319,
    receive_directory = root,
    callbacks = {
        offer = function(session, decide)
            io.stdout:write("OFFER ", session.alias, "\n")
            decide(true)
        end,
        received = function(received_path) io.stdout:write("RECEIVED ", received_path, "\n") end,
        networkError = function(failure) io.stderr:write(failure, "\n") end,
    },
}
io.stdout:setvbuf("no")
service:start()
io.stdout:write("READY\n")
local deadline, next_announcement = socket.gettime() + 30, 0
local started = false
while socket.gettime() < deadline do
    if socket.gettime() > next_announcement then
        service:announce(true)
        next_announcement = socket.gettime() + 1
    end
    service:tick()
    if mode == "send" and not started then
        for _, peer in ipairs(service:listPeers()) do
            if peer.alias == "Official LocalSend test" then
                started = true
                service:send(peer, { service:file(path) }, nil, function(ok, detail)
                    io.stdout:write(ok and "SENT\n" or ("FAILED " .. tostring(detail) .. "\n"))
                end)
                break
            end
        end
    end
    socket.sleep(0.005)
end
service:stop()
