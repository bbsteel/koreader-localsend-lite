local KindleNetwork = {}
local FIREWALL_COMMAND_TIMEOUT = 4

function KindleNetwork.wifiAddress(interface)
    local network_info = require("ffi/netinfo"):new()
    local success, interfaces = pcall(network_info.retrieve, network_info)
    network_info:free()
    assert(success, interfaces)
    for _, network_interface in ipairs(interfaces) do
        if network_interface.name == interface and network_interface.ipv4 then
            return network_interface.ipv4:match("^[%d.]+")
        end
    end
end

local function waitForProcess(process_id, timeout, wait_on_ui)
    if not process_id then return false, "could not start subprocess" end
    local ffi = require("ffi")
    local ffi_util = require("ffi/util")
    local socket = require("socket")
    local waiting_coroutine = wait_on_ui and coroutine.running()
    local ui_manager = waiting_coroutine and require("ui/uimanager")

    local process_status = ffi.new("int[1]")
    local deadline = socket.gettime() + timeout
    while true do
        local finished_process = ffi.C.waitpid(process_id, process_status, ffi.C.WNOHANG)
        if finished_process == process_id then
            if process_status[0] == 0 then return true end
            return false, "wait status " .. process_status[0]
        elseif finished_process < 0 then
            return false, "waitpid failed"
        end
        if socket.gettime() >= deadline then
            ffi_util.terminateSubProcess(process_id)
            if ui_manager then
                local function reapProcess()
                    if not ffi_util.isSubProcessDone(process_id) then ui_manager:scheduleIn(0.1, reapProcess) end
                end
                reapProcess()
            else
                ffi_util.isSubProcessDone(process_id, true)
            end
            return false, "timed out after " .. timeout .. " seconds"
        end
        if waiting_coroutine then
            ui_manager:scheduleIn(0.05, function()
                local resumed, failure = coroutine.resume(waiting_coroutine)
                if not resumed then require("logger").warn("LocalSend Lite firewall", failure) end
            end)
            coroutine.yield()
        else
            socket.sleep(0.05)
        end
    end
end

local function runIptables(operation, rule, wait_on_ui)
    local ffi = require("ffi")
    local command_arguments = { "/bin/sh", "-c", 'exec iptables "$@"', "localsend-lite", operation, unpack(rule) }
    local process_id = require("ffi/util").runInSubProcess(function()
        ffi.C.execl(command_arguments[1], unpack(command_arguments, 1, #command_arguments + 1))
        ffi.C._exit(127)
    end)
    return waitForProcess(process_id, FIREWALL_COMMAND_TIMEOUT, wait_on_ui)
end

function KindleNetwork.openFirewall(interface, address, transfer_port, discovery_port, group, iptables, diagnostic)
    iptables = iptables or runIptables
    local rules = {
        { "INPUT", "-i", interface, "-d", address, "-p", "tcp", "--dport", tostring(transfer_port),
            "-m", "conntrack", "--ctstate", "NEW,ESTABLISHED", "-j", "ACCEPT" },
        { "OUTPUT", "-o", interface, "-s", address, "-p", "tcp", "--sport", tostring(transfer_port),
            "-m", "conntrack", "--ctstate", "ESTABLISHED", "-j", "ACCEPT" },
        { "INPUT", "-i", interface, "-d", group, "-p", "udp", "--dport", tostring(discovery_port),
            "-j", "ACCEPT" },
        { "OUTPUT", "-o", interface, "-s", address, "-d", group, "-p", "udp",
            "--dport", tostring(discovery_port), "-j", "ACCEPT" },
    }
    local applied_rules = {}
    local function removeRules(wait_on_ui)
        local removed = true
        for index = #applied_rules, 1, -1 do
            local rule = applied_rules[index]
            local success, failure = iptables("-D", rule, wait_on_ui)
            if not success then
                removed = false
                if diagnostic then diagnostic("firewall.rule.failed", "-D", rule[1], failure) end
            end
            applied_rules[index] = nil
        end
        return removed
    end
    local function closeFirewall()
        if #applied_rules == 0 then return end
        local removed
        if iptables == runIptables then
            -- Start all cleanup in a subprocess so it can finish after KOReader exits.
            local ffi = require("ffi")
            local cleanup_process = require("ffi/util").runInSubProcess(function()
                ffi.C._exit(removeRules(false) and 0 or 1)
            end)
            if cleanup_process then
                local cleanup_timeout = FIREWALL_COMMAND_TIMEOUT * #applied_rules + 2
                applied_rules = {}
                removed = waitForProcess(cleanup_process, cleanup_timeout, true)
            else
                removed = removeRules(true)
            end
        else
            removed = removeRules(true)
        end
        if not removed then require("logger").warn("LocalSend Lite could not remove all Kindle firewall rules") end
        return removed
    end
    for _, rule in ipairs(rules) do
        local success, failure = iptables("-I", rule, true)
        if not success then
            if diagnostic then diagnostic("firewall.rule.failed", "-I", rule[1], failure) end
            closeFirewall()
            return nil, "Could not open the LocalSend ports on the Kindle Wi-Fi firewall"
        end
        applied_rules[#applied_rules + 1] = rule
    end
    return closeFirewall
end

return KindleNetwork
