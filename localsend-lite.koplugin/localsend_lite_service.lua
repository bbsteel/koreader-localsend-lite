local socket = require("socket")
local url = require("socket.url")
local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local Http = require("localsend_lite_http")
local Identity = require("localsend_lite_identity")

local Service = {}
Service.__index = Service

local PREFIX = "/api/localsend/v2"
local GROUP = "224.0.0.167"
local DEFAULT_PORT = 53317
local MAX_CONNECTIONS = 16
local MAX_FILES = 128
local METADATA_LIMIT = 262144
local APPROVAL_TIMEOUT = 120
local BATCH_IDLE_TIMEOUT = 300
local UPLOAD_IDLE_TIMEOUT = 60

local function decode(body)
    local ok, data = pcall(json.decode, body)
    if ok and type(data) == "table" then return data end
end

local function validString(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum
end

local function ipv4(address)
    local first, second, third, fourth = address:match("^(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)$")
    if not first then return false end
    return tonumber(first) > 0 and tonumber(first) < 224
        and tonumber(second) <= 255 and tonumber(third) <= 255 and tonumber(fourth) <= 255
end

local function fingerprint(value)
    return type(value) == "string" and #value == 64 and value:match("^%x+$") ~= nil
end

local function releaseTask(task)
    if task.connection then task.connection:close() end
    if task.file then task.file:close() end
    if task.partial_path then os.remove(task.partial_path) end
    local incoming_file = task.incoming_file
    if incoming_file then
        incoming_file.busy = nil
        if not incoming_file.saved then
            task.session.received_bytes = task.session.received_bytes - incoming_file.received_bytes
            incoming_file.received_bytes = 0
        end
    end
end

local function queryParameters(query)
    local parameters = {}
    for key, value in query:gmatch("([^&=]+)=([^&]*)") do
        parameters[url.unescape(key)] = url.unescape(value)
    end
    return parameters
end

local function queryString(parameters)
    local fields = {}
    for key, value in pairs(parameters) do
        fields[#fields + 1] = key .. "=" .. url.escape(value)
    end
    return "?" .. table.concat(fields, "&")
end

local function safeName(name)
    if not validString(name, 1024) then return end
    local leaf = name:match("([^/\\]+)$")
    if not leaf then return end
    leaf = leaf:gsub('[%c<>:"|?*]', "_"):gsub("^[ .]+", ""):gsub("[ .]+$", "")
    if #leaf == 0 or #leaf > 220 then return end
    return leaf
end

local function availablePath(directory, name)
    local stem, extension = name:match("^(.*)(%.[^%.]+)$")
    stem, extension = stem or name, extension or ""
    for duplicate_number = 0, 999 do
        local suffix = duplicate_number == 0 and "" or (" (%d)"):format(duplicate_number)
        local candidate = directory .. "/" .. stem .. suffix .. extension
        if not lfs.symlinkattributes(candidate) then return candidate end
    end
    error("Too many files with the same name")
end

local function metadata(stream, headers)
    local chunks = {}
    if (headers.expect or ""):lower() == "100-continue" then stream:respond(100) end
    stream:body(headers, METADATA_LIMIT, function(chunk) chunks[#chunks + 1] = chunk end)
    return decode(table.concat(chunks))
end

function Service.new(options)
    local service = setmetatable({
        identity = options.identity,
        info = {
            alias = options.alias,
            version = "2.2",
            deviceModel = options.model,
            deviceType = "mobile",
            fingerprint = options.identity.fingerprint,
            protocol = options.protocol or "https",
            port = options.port or DEFAULT_PORT,
            download = false,
        },
        receive_directory = options.receive_directory,
        discovery_port = options.discovery_port or DEFAULT_PORT,
        wifi_address = options.wifi_address,
        callbacks = options.callbacks or {},
        tasks = {},
        peers = {},
    }, Service)
    return service
end

function Service:emit(event, ...)
    local callback = self.callbacks[event]
    if callback then callback(...) end
end

function Service:start()
    local listener = assert(socket.tcp4())
    self.listener = listener
    assert(listener:setoption("reuseaddr", true))
    assert(listener:bind(self.wifi_address or "*", self.info.port))
    assert(listener:listen(MAX_CONNECTIONS))
    listener:settimeout(0)
    local multicast = assert(socket.udp4())
    self.multicast = multicast
    multicast:setoption("reuseaddr", true)
    multicast:setoption("reuseport", true)
    assert(multicast:setsockname("*", self.discovery_port))
    multicast:settimeout(0)
    if self.wifi_address then
        assert(multicast:setoption("ip-multicast-if", self.wifi_address))
    end
    assert(multicast:setoption("ip-add-membership", {
        multiaddr = GROUP, interface = self.wifi_address or "*",
    }))
    multicast:setoption("ip-multicast-ttl", 1)
end

function Service:stop()
    if self.listener then self.listener:close() end
    if self.multicast then self.multicast:close() end
    self.listener, self.multicast = nil, nil
    for _, task in ipairs(self.tasks) do releaseTask(task) end
    self.tasks, self.peers, self.incoming, self.outgoing = {}, {}, nil, nil
end

function Service:announce(announce)
    if not self.multicast then return end
    local payload = {}
    for key, value in pairs(self.info) do payload[key] = value end
    payload.announce = announce
    return self.multicast:sendto(json.encode(payload), GROUP, self.discovery_port)
end

function Service:remember(address, info)
    if type(info) ~= "table" or not validString(info.alias, 128)
        or not validString(info.version, 16) or not info.version:match("^2%.%d+$")
        or not ipv4(address) then return end
    local port = info.port
    local protocol = info.protocol
    if type(port) ~= "number" or port < 1 or port > 65535 or port % 1 ~= 0 then return end
    if protocol ~= "http" and protocol ~= "https" then return end
    if not validString(info.fingerprint, 128) or info.fingerprint:upper() == self.info.fingerprint then return end
    if protocol == "https" and not fingerprint(info.fingerprint) then return end
    local peer = {
        address = address, port = port, protocol = protocol, alias = info.alias,
        fingerprint = protocol == "https" and info.fingerprint:upper() or info.fingerprint,
    }
    local key = address .. ":" .. port
    if not self.peers[key] then
        local peer_count = 0
        for _ in pairs(self.peers) do peer_count = peer_count + 1 end
        if peer_count >= 128 then return end
    end
    self.peers[key] = peer
    return peer
end

function Service:addTask(run, done, kind)
    if #self.tasks >= MAX_CONNECTIONS then return end
    local task = { done = done, kind = kind }
    task.thread = coroutine.create(function() return run(task) end)
    self.tasks[#self.tasks + 1] = task
    return task
end

function Service:register(peer)
    self:addTask(function(task)
        local status, response = Http.request(task, peer, self.identity.client,
            PREFIX .. "/register", json.encode(self.info), "application/json")
        if status ~= 200 then return false end
        local remote_info = decode(response)
        if remote_info then
            remote_info.port, remote_info.protocol, remote_info.fingerprint = peer.port, peer.protocol, peer.fingerprint
            self:remember(peer.address, remote_info)
        end
        return true
    end, function(ok, registered)
        if not ok or not registered then self:announce(false) end
    end, "discovery")
end

function Service:listPeers()
    local peers = {}
    for _, peer in pairs(self.peers) do peers[#peers + 1] = peer end
    table.sort(peers, function(first, second)
        if first.alias ~= second.alias then return first.alias < second.alias end
        return first.address < second.address
    end)
    return peers
end

function Service:prepare(task, stream, headers, address)
    local function rejectOffer(status, reason)
        self:emit("diagnostic", "receive.offer_rejected", status, reason)
        return stream:respond(status)
    end
    if self.incoming then return rejectOffer(409, "receiver busy") end
    local request = metadata(stream, headers)
    if self.incoming then return rejectOffer(409, "receiver busy") end
    if not request or type(request.info) ~= "table" or not validString(request.info.alias, 128)
        or type(request.files) ~= "table" then return rejectOffer(400, "invalid offer metadata") end
    if task.remote_fingerprint and (not fingerprint(request.info.fingerprint)
        or request.info.fingerprint:upper() ~= task.remote_fingerprint) then
        return rejectOffer(403, "sender fingerprint mismatch")
    end
    local session = {
        id = Identity.randomId(), address = address, alias = request.info.alias,
        fingerprint = task.remote_fingerprint,
        files = {}, ordered_files = {}, remaining = 0, saved = 0,
        total_files = 0, total_bytes = 0, received_bytes = 0, upload_count = 0,
        expires = socket.gettime() + APPROVAL_TIMEOUT,
    }
    local offered_count = 0
    for file_id, entry in pairs(request.files) do
        offered_count = offered_count + 1
        if not validString(file_id, 128) or type(entry) ~= "table" or entry.id ~= file_id
            or not validString(entry.fileName, 1024) or type(entry.size) ~= "number"
            or entry.size < 0 or entry.size > Http.MAX_BODY or entry.size % 1 ~= 0
            or not validString(entry.fileType, 255) or offered_count > MAX_FILES then
            return rejectOffer(400, "invalid file metadata or too many files")
        end
        -- LocalSend puts a standalone message in preview. A .txt attachment
        -- uses the normal file upload and has no message preview.
        local media_type = entry.fileType:lower():match("^%s*([^;%s]+)")
        local is_message = media_type == "text/plain" and type(entry.preview) == "string"
        if not is_message then
            local file = { size = entry.size, token = Identity.randomId(), received_bytes = 0 }
            file.name = safeName(entry.fileName)
            if not file.name then return rejectOffer(400, "invalid file name") end
            if fingerprint(entry.sha256) then file.sha256 = entry.sha256:upper() end
            session.files[file_id] = file
            session.ordered_files[#session.ordered_files + 1] = file
            session.remaining = session.remaining + 1
            session.total_bytes = session.total_bytes + file.size
        end
    end
    if session.remaining == 0 then
        return rejectOffer(offered_count == 0 and 400 or 403, "no supported files")
    end
    session.total_files = session.remaining
    self.incoming = session
    task.preparing_session = session
    self:emit("diagnostic", "receive.offered", session.alias, session.total_files, session.total_bytes)
    self:emit("offer", session, function(accepted)
        if self.incoming == session then
            session.accepted = accepted == true
            if session.accepted then session.expires = socket.gettime() + BATCH_IDLE_TIMEOUT end
        end
    end)
    while session.accepted == nil and socket.gettime() < session.expires do
        coroutine.yield()
        if session.accepted == nil and not stream:peerIsWaiting() then
            self:emit("diagnostic", "receive.offer_disconnected")
            if self.incoming == session then self.incoming = nil end
            self:emit("offerClosed", session)
            return
        end
    end
    if not session.accepted then
        if self.incoming == session then self.incoming = nil end
        self:emit("offerClosed", session)
        if session.accepted == false then return rejectOffer(403, "declined") end
        return rejectOffer(408, "approval timeout")
    end
    local tokens = {}
    for file_id, file in pairs(session.files) do
        tokens[file_id] = file.token
    end
    stream:respond(200, json.encode({ sessionId = session.id, files = tokens }))
    task.preparing_session = nil
    self:emit("diagnostic", "receive.accepted", session.total_files)
    for _, file in ipairs(session.ordered_files) do
        self:emit("diagnostic", "receive.expected", file.name, file.size)
    end
end

function Service:upload(task, stream, headers, parameters, address)
    local function rejectUpload(status, reason, file)
        self:emit("diagnostic", "receive.upload_rejected", status, reason, file and file.name)
        return stream:respond(status)
    end
    if not parameters.sessionId or not parameters.fileId or not parameters.token then
        return rejectUpload(400, "missing parameters")
    end
    local session = self.incoming
    if not session or not session.accepted or session.id ~= parameters.sessionId then
        return rejectUpload(409, "no matching accepted session")
    end
    local file = session.files[parameters.fileId]
    if session.address ~= address or session.fingerprint ~= task.remote_fingerprint
        or not file or file.token ~= parameters.token then
        return rejectUpload(403, "sender or file authorization mismatch")
    end
    if file.busy or file.saved then return rejectUpload(409, file.saved and "already saved" or "already uploading", file) end
    if not headers["content-length"] and not headers["transfer-encoding"] then
        return rejectUpload(400, "missing body framing", file)
    end
    if headers["content-length"] and tonumber(headers["content-length"]) ~= file.size then
        return rejectUpload(400, "content length mismatch", file)
    end
    file.busy = true
    session.upload_count = session.upload_count + 1
    file.receive_order = session.upload_count
    task.incoming_file = file
    task.session = session
    self:emit("diagnostic", "receive.upload_started", file.name, file.size)
    task.partial_path = self.receive_directory .. "/.localsend-lite-" .. file.token .. ".part"
    task.file = assert(io.open(task.partial_path, "wb"))
    local digest = file.sha256 and Identity.sha256()
    if (headers.expect or ""):lower() == "100-continue" then stream:respond(100) end
    local size = stream:body(headers, file.size, function(chunk)
        assert(self.incoming == session, "Transfer was cancelled")
        assert(task.file:write(chunk))
        if digest then digest(chunk) end
        file.received_bytes = file.received_bytes + #chunk
        session.received_bytes = session.received_bytes + #chunk
        session.expires = socket.gettime() + BATCH_IDLE_TIMEOUT
    end, nil, UPLOAD_IDLE_TIMEOUT)
    local handle = task.file
    task.file = nil
    assert(handle:close())
    if size ~= file.size then
        self:emit("receiveFailed", file.name, "Truncated HTTP body")
        return rejectUpload(400, "truncated body", file)
    end
    if digest and digest() ~= file.sha256 then
        self:emit("receiveFailed", file.name, "Checksum mismatch")
        return rejectUpload(422, "checksum mismatch", file)
    end
    local destination = availablePath(self.receive_directory, file.name)
    assert(os.rename(task.partial_path, destination))
    task.partial_path = nil
    file.saved = true
    session.saved = session.saved + 1
    session.remaining = session.remaining - 1
    if session.remaining == 0 then self.incoming = nil end
    self:emit("diagnostic", "receive.saved", file.name, session.saved, session.total_files)
    stream:respond(200)
    self:emit("diagnostic", "receive.response_sent", file.name, 200)
    self:emit("received", destination, session)
end

function Service:serve(task, connection, address)
    local stream = Http.stream(task, connection)
    local batch_from_sender = self.incoming and self.incoming.accepted and self.incoming.address == address
    if batch_from_sender then task.receive_stage = "TLS handshake" end
    if self.info.protocol == "https" then stream:enableTLS(self.identity.server) end
    batch_from_sender = self.incoming and self.incoming.accepted and self.incoming.address == address
    task.receive_stage = batch_from_sender and "HTTP headers" or nil
    local line, headers = stream:headers(batch_from_sender and UPLOAD_IDLE_TIMEOUT or nil)
    task.receive_stage = nil
    local method, target = line:match("^(%u+) ([^%s]+) HTTP/1%.[01]$")
    if not method then return stream:respond(400) end
    local route, query = target:match("^([^?]+)%??(.*)$")
    if method == "GET" and route == PREFIX .. "/info" then
        return stream:respond(200, json.encode(self.info))
    end
    if method ~= "POST" then return stream:respond(404) end
    if route == PREFIX .. "/register" then
        local remote_info = metadata(stream, headers)
        if not remote_info then return stream:respond(400) end
        if task.remote_fingerprint and remote_info.protocol == "https"
            and (not fingerprint(remote_info.fingerprint) or remote_info.fingerprint:upper() ~= task.remote_fingerprint) then
            return stream:respond(403)
        end
        self:remember(address, remote_info)
        return stream:respond(200, json.encode(self.info))
    end
    if route == PREFIX .. "/prepare-upload" then
        task.receive_stage = "prepare-upload"
        return self:prepare(task, stream, headers, address)
    end
    local parameters = queryParameters(query or "")
    if route == PREFIX .. "/upload" then
        task.receive_stage = "upload"
        return self:upload(task, stream, headers, parameters, address)
    end
    if route == PREFIX .. "/cancel" then
        local session = self.incoming
        if not session or parameters.sessionId ~= session.id or address ~= session.address
            or session.fingerprint ~= task.remote_fingerprint then
            return stream:respond(403)
        end
        session.accepted = false
        self.incoming = nil
        self:emit("diagnostic", "receive.ended", "sender cancelled", session.saved, session.total_files)
        self:emit("offerClosed", session)
        self:emit("receiveEnded", session, "cancelled")
        return stream:respond(200)
    end
    return stream:respond(404)
end

function Service:file(path, file_type)
    local source = assert(lfs.attributes(path), "Cannot read source file")
    assert(source.mode == "file" and source.size <= Http.MAX_BODY, "Select a regular file smaller than 4 GiB")
    return {
        id = Identity.randomId(), fileName = assert(path:match("([^/]+)$")),
        size = source.size, fileType = file_type or "application/octet-stream", path = path,
    }
end

function Service:send(peer, files, pin, callback)
    if self.outgoing then callback(false, "A transfer is already in progress"); return end
    self:emit("diagnostic", "send.started", peer.alias, #files)
    local outgoing = {}
    local offered_files = {}
    for _, file in ipairs(files) do
        offered_files[file.id] = {
            id = file.id, fileName = file.fileName, size = file.size,
            fileType = file.fileType,
        }
    end
    local task = self:addTask(function(send_task)
        local prepare_url = PREFIX .. "/prepare-upload"
        if pin and pin ~= "" then prepare_url = prepare_url .. queryString({ pin = pin }) end
        local status, response = Http.request(send_task, peer, self.identity.client, prepare_url,
            json.encode({ info = self.info, files = offered_files }), "application/json", nil, APPROVAL_TIMEOUT)
        self:emit("diagnostic", "send.response", "prepare-upload", status)
        if status == 204 then return true end
        if status ~= 200 then return false, status end
        local accepted = decode(response)
        assert(accepted and validString(accepted.sessionId, 128) and type(accepted.files) == "table",
            "Invalid LocalSend approval")
        outgoing.session_id = accepted.sessionId
        local sent_count = 0
        for _, file in ipairs(files) do
            local token = accepted.files[file.id]
            if token then
                assert(validString(token, 128), "Invalid LocalSend upload token")
                local upload_url = PREFIX .. "/upload" .. queryString({
                    sessionId = outgoing.session_id, fileId = file.id, token = token,
                })
                status = Http.request(send_task, peer, self.identity.client, upload_url,
                    nil, "application/octet-stream", file)
                self:emit("diagnostic", "send.response", file.fileName, status)
                if status < 200 or status >= 300 then return false, status end
                sent_count = sent_count + 1
            end
        end
        return sent_count > 0, sent_count
    end, function(ok, success, detail)
        self.outgoing = nil
        self:emit("diagnostic", ok and success and "send.done" or "send.failed", ok and detail or success)
        if not ok or not success then self:cancelRemote(peer, outgoing.session_id) end
        if ok then callback(success, detail) else callback(false, success) end
    end, "outgoing")
    if not task then callback(false, "LocalSend is busy"); return end
    outgoing.task, outgoing.peer = task, peer
    self.outgoing = outgoing
end

function Service:cancelRemote(peer, session_id)
    if not session_id then return end
    self:addTask(function(task)
        Http.request(task, peer, self.identity.client,
            PREFIX .. "/cancel" .. queryString({ sessionId = session_id }), "")
    end, nil, "cancel")
end

function Service:cancelSend()
    local outgoing = self.outgoing
    if not outgoing then return end
    self:emit("diagnostic", "send.cancelled")
    outgoing.task.cancelled = true
    self.outgoing = nil
    self:cancelRemote(outgoing.peer, outgoing.session_id)
end

function Service:tick()
    if self.incoming and self.incoming.accepted and socket.gettime() >= self.incoming.expires then
        local expired_session = self.incoming
        self.incoming = nil
        self:emit("diagnostic", "receive.ended", "idle timeout", expired_session.saved, expired_session.total_files)
        self:emit("receiveEnded", expired_session, "timeout")
    end
    if self.multicast then
        for _ = 1, 8 do
            local packet, address = self.multicast:receivefrom(4096)
            if not packet then break end
            local info = decode(packet)
            local peer = self:remember(address, info)
            if peer and info.announce == true then self:register(peer) end
        end
    end
    for _ = 1, 4 do
        if #self.tasks >= MAX_CONNECTIONS then break end
        local connection = self.listener:accept()
        if not connection then break end
        local address = connection:getpeername()
        if address then
            local task = self:addTask(function(incoming_task)
                self:serve(incoming_task, connection, address)
            end, nil, "incoming")
            task.connection = connection
        else
            connection:close()
        end
    end
    for task_index = #self.tasks, 1, -1 do
        local task = self.tasks[task_index]
        if task and task.cancelled then
            table.remove(self.tasks, task_index)
            releaseTask(task)
        elseif task then
            local ok, result, detail = coroutine.resume(task.thread)
            if not ok or coroutine.status(task.thread) == "dead" then
                table.remove(self.tasks, task_index)
                if not ok and task.receive_stage then
                    local file = task.incoming_file
                    self:emit("diagnostic", "receive.request_failed", task.receive_stage,
                        file and file.name, file and file.received_bytes, result)
                end
                releaseTask(task)
                if task.preparing_session and self.incoming == task.preparing_session then
                    self.incoming = nil
                    self:emit("offerClosed", task.preparing_session)
                end
                if task.done then task.done(ok, result, detail) end
                if not ok and task.kind == "incoming" then
                    self:emit("networkError", result)
                    if task.incoming_file and not task.incoming_file.saved and self.incoming == task.session then
                        self:emit("receiveFailed", task.incoming_file.name, result)
                    end
                end
            end
        end
    end
end

Service.DEFAULT_PORT = DEFAULT_PORT
Service.MULTICAST_GROUP = GROUP
Service.MAX_FILES = MAX_FILES
return Service
