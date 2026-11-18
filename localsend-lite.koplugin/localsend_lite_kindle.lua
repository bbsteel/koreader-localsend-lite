local KindleNetwork = {}

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

local function runIptables(operation, rule)
    -- Resolve iptables on the Kindle's PATH and pass every argument separately.
    return require("ffi/util").execute("/bin/sh", "-c", 'exec iptables "$@"',
        "localsend", operation, unpack(rule)) == 0
end

function KindleNetwork.openFirewall(interface, address, transfer_port, discovery_port, group, iptables)
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
    local function closeFirewall()
        for index = #applied_rules, 1, -1 do
            local rule = applied_rules[index]
            if not iptables("-D", rule) then
                require("logger").warn("LocalSend: failed to remove Kindle firewall rule", table.concat(rule, " "))
            end
            applied_rules[index] = nil
        end
    end
    for _, rule in ipairs(rules) do
        if not iptables("-I", rule) then
            closeFirewall()
            return nil, "Could not open the LocalSend ports on the Kindle Wi-Fi firewall"
        end
        applied_rules[#applied_rules + 1] = rule
    end
    return closeFirewall
end

return KindleNetwork
