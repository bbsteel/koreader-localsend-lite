-- HTTP/1.1 transport for LocalSend. All network I/O is cooperative so the e-ink
-- UI can keep handling input while an upload waits for approval or streams.
local socket = require("socket")
local ssl = require("ssl")
local Identity = require("localsend_lite_identity")

local Http = {}
local CHUNK_SIZE = 32768
local HEADER_LIMIT = 16384
local MAX_BODY = 4294967295
local WAIT_ERRORS = { timeout = true, wantread = true, wantwrite = true }
local REASONS = {
    [100] = "Continue", [200] = "OK", [204] = "No Content",
    [400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found",
    [408] = "Request Timeout", [409] = "Conflict", [413] = "Content Too Large",
    [422] = "Unprocessable Content", [429] = "Too Many Requests", [500] = "Internal Server Error",
}

local Stream = {}
Stream.__index = Stream

function Http.stream(task, connection)
    task.connection = connection
    connection:settimeout(0)
    return setmetatable({ task = task, connection = connection, buffer = "", quantum = 0 }, Stream)
end

function Stream:pause(error_message, deadline)
    assert(WAIT_ERRORS[error_message], error_message or "Network I/O failed")
    assert(socket.gettime() < deadline, "Connection timed out")
    coroutine.yield()
end

function Stream:pace(byte_count)
    self.quantum = self.quantum + byte_count
    if self.quantum >= 131072 then
        self.quantum = 0
        coroutine.yield()
    end
end

function Stream:enableTLS(context, expected_fingerprint)
    local encrypted = assert(ssl.wrap(self.connection, context))
    self.connection = encrypted
    self.task.connection = encrypted
    encrypted:settimeout(0)
    local deadline = socket.gettime() + 10
    while true do
        local connected, handshake_error = encrypted:dohandshake()
        if connected then break end
        self:pause(handshake_error, deadline)
    end
    local actual_fingerprint = Identity.fingerprint(encrypted:getpeercertificate())
    self.task.remote_fingerprint = actual_fingerprint
    if expected_fingerprint then
        assert(actual_fingerprint == expected_fingerprint:upper(), "LocalSend certificate fingerprint changed")
    end
end

function Stream:write(data)
    local offset, deadline = 1, socket.gettime() + 20
    while offset <= #data do
        local sent, write_error, partial = self.connection:send(data, offset)
        local last_offset = sent or partial or offset - 1
        if last_offset >= offset then
            self:pace(last_offset - offset + 1)
            deadline = socket.gettime() + 20
            offset = last_offset + 1
        end
        if not sent then self:pause(write_error, deadline) end
    end
end

function Stream:fill(deadline)
    while not self.closed do
        assert(socket.gettime() < deadline, "Connection timed out")
        local data, read_error, partial = self.connection:receive(CHUNK_SIZE)
        if read_error == "closed" then self.closed = true end
        local received = data or partial
        if received and #received > 0 then
            self.buffer = self.buffer .. received
            self:pace(#received)
            return true
        end
        if not self.closed then self:pause(read_error, deadline) end
    end
end

function Stream:line(limit, deadline)
    while true do
        local newline = self.buffer:find("\n", 1, true)
        if newline then
            assert(newline <= limit and self.buffer:sub(newline - 1, newline - 1) == "\r", "Invalid HTTP line")
            local line = self.buffer:sub(1, newline - 2)
            self.buffer = self.buffer:sub(newline + 1)
            return line
        end
        assert(#self.buffer < limit and self:fill(deadline), "Incomplete or oversized HTTP line")
    end
end

function Stream:headers(timeout)
    local deadline = socket.gettime() + (timeout or 10)
    local first_line = self:line(4096, deadline)
    local remaining = HEADER_LIMIT - #first_line
    local headers = {}
    while true do
        local line = self:line(remaining, deadline)
        remaining = remaining - #line - 2
        if line == "" then break end
        local name, value = line:match("^([%w%-]+):[ \t]*(.-)[ \t]*$")
        assert(name, "Malformed HTTP header")
        name = name:lower()
        assert(not headers[name] or (name ~= "content-length" and name ~= "transfer-encoding"), "Duplicate HTTP framing")
        headers[name] = value
    end
    return first_line, headers
end

function Stream:take(length, sink)
    local remaining = length
    while remaining > 0 do
        assert(#self.buffer > 0 or self:fill(socket.gettime() + 20), "Truncated HTTP body")
        local count = math.min(remaining, #self.buffer)
        sink(self.buffer:sub(1, count))
        self.buffer = self.buffer:sub(count + 1)
        remaining = remaining - count
    end
end

function Stream:body(headers, limit, sink, until_close)
    local transfer_encoding = headers["transfer-encoding"]
    local content_length = headers["content-length"]
    if transfer_encoding then
        assert(not content_length and transfer_encoding:lower() == "chunked", "Unsupported HTTP framing")
        local received = 0
        while true do
            local deadline = socket.gettime() + 20
            local chunk_line = self:line(128, deadline)
            local hex_size = chunk_line:match("^([%da-fA-F]+)$") or chunk_line:match("^([%da-fA-F]+);")
            local chunk_size = hex_size and tonumber(hex_size, 16)
            assert(chunk_size and chunk_size <= limit - received, "Invalid or oversized HTTP chunk")
            if chunk_size == 0 then
                local trailer_budget = HEADER_LIMIT
                while true do
                    local trailer = self:line(trailer_budget, deadline)
                    if trailer == "" then return received end
                    trailer_budget = trailer_budget - #trailer - 2
                end
            end
            self:take(chunk_size, sink)
            assert(self:line(2, socket.gettime() + 20) == "", "Invalid chunk separator")
            received = received + chunk_size
        end
    end
    if content_length then
        local length = content_length:match("^%d+$") and tonumber(content_length)
        assert(length and length <= limit, "Invalid or oversized HTTP content length")
        self:take(length, sink)
        return length
    end
    if not until_close then return 0 end
    local received = 0
    while #self.buffer > 0 or self:fill(socket.gettime() + 20) do
        received = received + #self.buffer
        assert(received <= limit, "HTTP response is too large")
        sink(self.buffer)
        self.buffer = ""
    end
    return received
end

function Stream:respond(status, body)
    if status == 100 then return self:write("HTTP/1.1 100 Continue\r\n\r\n") end
    body = body or ""
    self:write(("HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s")
        :format(status, assert(REASONS[status]), #body, body))
end

function Stream:peerIsWaiting()
    if self.closed then return false end
    local _, read_error = self.connection:receive(1)
    return WAIT_ERRORS[read_error] == true
end

function Http.request(task, peer, tls_context, path, body, content_type, file, approval_timeout)
    local connection = assert(socket.tcp4())
    local stream = Http.stream(task, connection)
    local connected, connect_error = connection:connect(peer.address, peer.port)
    if not connected then
        assert(connect_error == "timeout", connect_error)
        local deadline = socket.gettime() + 5
        repeat
            stream:pause("timeout", deadline)
            connected, connect_error = connection:connect(peer.address, peer.port)
            assert(connected or connect_error == "already connected" or connect_error == "timeout"
                or connect_error == "Operation already in progress", connect_error)
        until connected or connect_error == "already connected"
    end
    if peer.protocol == "https" then
        stream:enableTLS(tls_context, peer.fingerprint)
    end
    local method = body or file
    local length = file and file.size or body and #body or 0
    stream:write(("%s %s HTTP/1.1\r\nHost: %s:%d\r\nContent-Length: %.0f\r\nContent-Type: %s\r\nConnection: close\r\n\r\n")
        :format(method and "POST" or "GET", path, peer.address, peer.port, length,
            content_type or "application/octet-stream"))
    if file then
        local handle = assert(io.open(file.path, "rb"))
        task.file = handle
        local remaining = file.size
        while remaining > 0 do
            local chunk = assert(handle:read(math.min(remaining, CHUNK_SIZE)), "Source file was shortened")
            stream:write(chunk)
            remaining = remaining - #chunk
        end
        handle:close()
        task.file = nil
    elseif body then
        stream:write(body)
    end
    local status, headers
    repeat
        local line
        line, headers = stream:headers(approval_timeout)
        status = assert(tonumber(line:match("^HTTP/1%.[01] (%d%d%d)")), "Invalid HTTP status")
    until status ~= 100
    local chunks = {}
    if status ~= 204 and status ~= 304 then
        stream:body(headers, 262144, function(chunk) chunks[#chunks + 1] = chunk end, true)
    end
    stream.connection:close()
    task.connection = nil
    return status, table.concat(chunks)
end

Http.MAX_BODY = MAX_BODY
return Http
