#!/usr/bin/env bash
set -euo pipefail

project_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
koreader_directory=${1:-$(flatpak info --show-location rocks.koreader.KOReader)/files/lib/koreader}
export TMPDIR="$HOME/tmp"
mkdir -p -- "$TMPDIR"
scratch_directory=$(mktemp -d -p "$TMPDIR" koreader-localsend-ui.XXXXXX)
cleanup_test_files() {
    case "$scratch_directory" in
        "$HOME"/tmp/koreader-localsend-ui.*)
            printf 'Removing test directory %s\n' "$scratch_directory"
            rm -rf -- "$scratch_directory"
            ;;
    esac
}
trap cleanup_test_files EXIT
cd -- "$koreader_directory"
export KO_HOME="$scratch_directory" SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
export LD_LIBRARY_PATH="$PWD/libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cat > "$scratch_directory/iptables" <<'SH'
#!/bin/sh
sleep 0.5
printf '%s\n' "$*" >> "$KO_HOME/iptables.log"
SH
chmod +x "$scratch_directory/iptables"
export PATH="$scratch_directory:$PATH"
./luajit - "$project_directory" <<'LUA'
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(os.getenv("KO_HOME") .. "/settings.reader.lua")
G_reader_settings:saveSetting("extra_plugin_paths", { arg[1] })
G_reader_settings:saveSetting("localsend-lite", { port = 53321, alias = "KOReader (Emulator)" })
local Device = require("device")
require("document/canvascontext"):init(Device)
local FileManager = require("apps/filemanager/filemanager")
FileManager:showFiles(os.getenv("KO_HOME"))
local plugin = assert(require("pluginloader"):getPluginInstance("localsend-lite"))
assert(package.loaded.localsend_lite_service == nil, "Idle plugin should not load network transport")
FileManager.instance.menu:setUpdateItemTable()
local native_menu = FileManager.instance.menu
local tools_tab = assert(require("ui/menusorter"):findById(native_menu.tab_item_table, "tools"))
local menu_item = assert(tools_tab[1])
assert(menu_item.id == "localsend-lite", "LocalSend must be first on the Tools tab")
for index = 2, #tools_tab do assert(tools_tab[index].id ~= "localsend-lite") end
plugin:addToMainMenu({})
local filemanager_order = require("ui/elements/filemanager_menu_order").tools
assert(filemanager_order[1] == "localsend-lite")
for index = 2, #filemanager_order do assert(filemanager_order[index] ~= "localsend-lite") end
plugin.addToMainMenu({ ui = { document = true } }, {})
assert(require("ui/elements/reader_menu_order").tools[1] == "localsend-lite")
local actions = menu_item.sub_item_table
assert(menu_item.text == "LocalSend Lite" and #actions == 2)
assert(actions[1].text == "Send files" and actions[2].text == "Receive files")
actions[2].callback()
assert(plugin.service and plugin.receive_dialog)
local alias = plugin.service.info.alias
assert(alias:match("^%a+ %a+$") and not alias:find("KOReader", 1, true))
assert(plugin.receive_dialog.title:find(alias, 1, true))
local socket = require("socket")
local real_gettime = socket.gettime
local announcements = 0
plugin.service.announce = function(_, announce)
    assert(announce)
    announcements = announcements + 1
    return true
end
socket.gettime = function() return real_gettime() + 6 end
plugin.poll()
socket.gettime = real_gettime
assert(announcements == 1, "The receive panel must keep announcing")
local incoming = { alias = "Gentle Kiwi", ordered_files = {} }
for index = 1, 6 do incoming.ordered_files[index] = { name = index .. ".epub" } end
plugin:showOffer(incoming, function() end)
assert(plugin.offer_dialog.ok_text == "Accept" and plugin.offer_dialog.text:find("+1 more", 1, true))
plugin:closeOffer(incoming)
local file = { name = "sample.epub", size = 4096, received_bytes = 0, busy = true, receive_order = 1 }
local transfer = {
    alias = "Gentle Kiwi", ordered_files = {file}, accepted = true,
    total_files = 1, saved = 0, total_bytes = 4096, received_bytes = 0,
}
plugin.service.incoming = transfer
plugin:updateReceiveStatus()
assert(plugin.receive_dialog.title:find("Receiving from Gentle Kiwi", 1, true))
file.received_bytes, transfer.received_bytes = 2048, 2048
socket.gettime = function() return plugin.receive_progress.updated_at + 2 end
plugin:updateReceiveStatus()
socket.gettime = real_gettime
local progress_title = plugin.receive_dialog.title
assert(progress_title:find("Current file: sample.epub (50%)", 1, true), progress_title)
assert(progress_title:find("0/1 files saved", 1, true))
assert(progress_title:find(require("util").getFriendlySize(1024) .. "/s", 1, true), progress_title)
plugin.service.incoming = nil
plugin:updateReceiveStatus()
assert(plugin.receive_dialog.title:find("Waiting for files as", 1, true))
plugin.receive_dialog:onClose()
assert(not plugin.service and not plugin.receive_dialog)

local sample_path = os.getenv("KO_HOME") .. "/sample.epub"
local sample = assert(io.open(sample_path, "wb"))
assert(sample:write("LocalSend menu test"))
sample:close()
local UIManager = require("ui/uimanager")
actions[1].callback()
local path_chooser_type = require("ui/widget/pathchooser")
local file_picker
for _, window in ipairs(UIManager._window_stack) do
    if getmetatable(window.widget) == path_chooser_type then file_picker = window.widget end
end
assert(file_picker, "KOReader's native file picker should be open")
assert(not plugin.service and file_picker.select_file and not file_picker.select_directory)
UIManager:close(file_picker)
FileManager.instance.selected_files = { [sample_path] = true }
actions[1].callback()
assert(plugin.service.info.alias == alias)
local device_menu = assert(plugin.peer_menu)
assert(#device_menu.item_table == 1 and device_menu.item_table[1].select_enabled == false)
plugin.service:remember("192.168.0.2", {
    alias = "Quiet Peach", version = "2.2", protocol = "http", port = 53317, fingerprint = "test",
})
plugin:updatePeers()
assert(#device_menu.item_table == 1 and device_menu.item_table[1].peer.alias == "Quiet Peach")
device_menu:onClose()
assert(not plugin.service and not plugin.poll and not plugin.peer_menu)

local gettext = require("gettext")
local alias_for = require("localsend_lite_alias")
local fingerprint = ("0"):rep(64)
assert(alias_for(fingerprint, "zh-CN.UTF-8") == "热心的杏子")
assert(alias_for(fingerprint, "zh-Hant-HK") == "熱心的杏桃")
assert(alias_for(fingerprint, "ja-JP") == "元気なりんご")
assert(alias_for(fingerprint, "fr_CA") == "Pomme joyeuse")
assert(alias_for(fingerprint, "en_GB") == "Amber Apricot")
assert(alias_for(fingerprint, "xx_YY") == "Amber Apricot")
for _, locale in ipairs({ "zh_CN", "zh_TW" }) do
    assert(gettext.changeLang(locale))
    local localized_menu = {}
    plugin:addToMainMenu(localized_menu)
    local receive_action = localized_menu["localsend-lite"].sub_item_table[2]
    assert(receive_action.text == (locale == "zh_CN" and "接收文件" or "接收檔案"))
    receive_action.callback()
    local localized_alias = plugin.service.info.alias
    assert(localized_alias == alias_for(plugin.service.info.fingerprint, locale))
    assert(localized_alias:find("的", 1, true) and localized_alias ~= alias)
    assert(plugin.receive_dialog.title:find(localized_alias, 1, true))
    plugin.service.incoming = transfer
    plugin:updateReceiveStatus()
    assert(plugin.receive_dialog.title:find(locale == "zh_CN" and "当前文件" or "目前檔案", 1, true))
    plugin:stop()
end

Device.isKindle = function() return true end
local kindle_network = require("localsend_lite_kindle")
kindle_network.wifiAddress = function() return "127.0.0.1" end
local network_manager = require("ui/network/manager")
network_manager.getNetworkInterfaceName = function() return "wlan0" end
local function awaitState(condition)
    local deadline = socket.gettime() + 8
    repeat
        UIManager:_checkTasks()
        if condition() then return end
        socket.sleep(0.01)
    until socket.gettime() > deadline
    error("Timed out waiting for Kindle startup or cleanup")
end
plugin:start("receive")
assert(plugin.startup_dialog and not plugin.receive_dialog)
awaitState(function() return plugin.service or not plugin.startup end)
assert(plugin.startup_dialog and plugin.service and not plugin.receive_dialog,
    ("Kindle startup should yield with the receiver still starting (startup=%s, service=%s, receiver=%s)")
        :format(tostring(plugin.startup), tostring(plugin.service), tostring(plugin.receive_dialog)))
local other_task_ran
UIManager:nextTick(function()
    other_task_ran = true
end)
awaitState(function() return not plugin.startup end)
assert(other_task_ran and plugin.receive_dialog)
plugin:stop()
awaitState(function() return not plugin.closing_firewall end)
local firewall_log = assert(io.open(os.getenv("KO_HOME") .. "/iptables.log"))
local operations = firewall_log:read("*a")
firewall_log:close()
local _, inserted = operations:gsub("%-I ", "")
local _, removed = operations:gsub("%-D ", "")
assert(inserted == 4 and removed == 4, operations)
local log_path = require("datastorage"):getSettingsDir() .. "/localsend-lite.log"
local diagnostic_log = assert(io.open(log_path))
local diagnostics = diagnostic_log:read("*a")
diagnostic_log:close()
local firewall_start = assert(diagnostics:find("firewall.open.begin", 1, true))
local firewall_ready = assert(diagnostics:find("firewall.open.done", firewall_start, true))
assert(diagnostics:find("start.ready\treceive", firewall_ready, true))
assert(diagnostics:find("firewall.close.done", firewall_ready, true))
print("PASS: native menus, receive progress, Chinese interface, and Kindle startup diagnostics")
LUA
