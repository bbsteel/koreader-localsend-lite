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
local screenshot_directory = os.getenv("LOCALSEND_UI_SCREENSHOTS")
local function captureDialog(name, dialog)
    if not screenshot_directory then return end
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    for index = #UIManager._window_stack, 1, -1 do
        local widget = UIManager._window_stack[index].widget
        if getmetatable(widget) == InfoMessage then UIManager:close(widget) end
    end
    UIManager:_repaint()
    local bounds = dialog.movable.dimen
    local image = Device.screen.bb:viewport(bounds.x, bounds.y, bounds.w, bounds.h)
    image:writePNG(screenshot_directory .. "/" .. name .. ".png")
end
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
assert(plugin.receive_dialog.title == "LocalSend Lite")
assert(plugin.receive_dialog.status_widget.text:find("「" .. alias .. "」", 1, true))
if screenshot_directory then
    local receive_directory = plugin.service.receive_directory
    plugin.service.receive_directory = "/mnt/us/documents"
    plugin:setReceiveStatus(plugin:waitingForFilesStatus())
    captureDialog("receive-waiting", plugin.receive_dialog)
    plugin.service.receive_directory = receive_directory
    plugin:setReceiveStatus(plugin:waitingForFilesStatus())
end
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
local offer_accepted
plugin:showOffer(incoming, function(accepted) offer_accepted = accepted end)
assert(plugin.offer_dialog.ok_text == "Accept" and plugin.offer_dialog.text:find("Page 1 of 2", 1, true))
assert(plugin.offer_dialog.text:find("「Gentle Kiwi」", 1, true))
for index = 1, 5 do
    assert(plugin.offer_dialog.text:find("• " .. index .. ".epub", 1, true))
end
assert(not plugin.offer_dialog.text:find("6.epub", 1, true))
captureDialog("receive-batch", plugin.offer_dialog)
plugin.offer_dialog.other_buttons[1][1].callback()
assert(plugin.offer_dialog.text:find("Page 2 of 2", 1, true))
assert(plugin.offer_dialog.text:find("• 6.epub", 1, true))
assert(not plugin.offer_dialog.text:find("5.epub", 1, true))
assert(offer_accepted == nil)
plugin.offer_dialog.other_buttons[1][1].callback()
assert(plugin.offer_dialog.text:find("Page 1 of 2", 1, true))
plugin.offer_dialog.ok_callback()
assert(offer_accepted and not plugin.offer_dialog)
local file = { name = "sample.epub", size = 4096, received_bytes = 0, busy = true, receive_order = 1 }
local transfer = {
    alias = "Gentle Kiwi", ordered_files = {file}, accepted = true,
    total_files = 1, saved = 0, total_bytes = 4096, received_bytes = 0,
}
plugin.service.incoming = transfer
plugin:updateReceiveStatus()
assert(plugin.receive_dialog.status_widget.text:find("Receiving from 「Gentle Kiwi」", 1, true))
file.received_bytes, transfer.received_bytes = 2048, 2048
socket.gettime = function() return plugin.receive_progress.updated_at + 2 end
plugin:updateReceiveStatus()
socket.gettime = real_gettime
assert(plugin.receive_dialog.title == "LocalSend Lite")
local progress_status = plugin.receive_dialog.status_widget.text
assert(progress_status:find("Current file: sample.epub (50%)", 1, true), progress_status)
assert(progress_status:find("0/1 files saved", 1, true))
assert(progress_status:find(require("util").getFriendlySize(1024) .. "/s", 1, true), progress_status)
captureDialog("receive-progress", plugin.receive_dialog)
plugin.service.incoming = nil
plugin:updateReceiveStatus()
assert(plugin.receive_dialog.title == "LocalSend Lite")
assert(plugin.receive_dialog.status_widget.text:find("Waiting for files as", 1, true))
plugin.receive_dialog:onClose()
assert(not plugin.service and not plugin.receive_dialog)

local sample_path = os.getenv("KO_HOME") .. "/sample.epub"
local sample = assert(io.open(sample_path, "wb"))
assert(sample:write("LocalSend menu test"))
sample:close()
local text_path = os.getenv("KO_HOME") .. "/preview.txt"
local text_file = assert(io.open(text_path, "wb"))
text_file:write("LocalSend quick preview")
text_file:close()
local child_directory = os.getenv("KO_HOME") .. "/send-child"
assert(require("libs/libkoreader-lfs").mkdir(child_directory))
for index = 1, 40 do
    local filler = assert(io.open(os.getenv("KO_HOME") .. ("/q-%02d.txt"):format(index), "wb"))
    filler:close()
end
local UIManager = require("ui/uimanager")
local function findWidget(widget_type)
    for index = #UIManager._window_stack, 1, -1 do
        local widget = UIManager._window_stack[index].widget
        if getmetatable(widget) == widget_type then return widget end
    end
end
actions[1].callback()
local picker_type = require("localsend_lite_picker")
local picker = assert(findWidget(picker_type))
assert(not plugin.service, "Selecting and previewing files should work offline")
local function findFile(path)
    for index, item in ipairs(picker.item_table) do
        if item.path == path then return item, math.ceil(index / picker.perpage) end
    end
end
picker:onMenuHold(assert(findFile(text_path)))
local preview = assert(findWidget(require("ui/widget/textviewer")))
assert(preview.text:find("LocalSend quick preview", 1, true))
UIManager:close(preview)
local sample_item, sample_page = findFile(sample_path)
local text_item, text_page = findFile(text_path)
assert(sample_item and text_item and sample_page ~= text_page)
picker:onGotoPage(text_page)
picker:onMenuSelect(text_item)
picker:onGotoPage(sample_page)
picker:onMenuSelect(sample_item)
picker:onGotoPage(text_page)
assert(picker.page == text_page and text_item.dim and sample_item.dim)
assert(picker.selection_count == 2)
picker:changeToPath(picker.path .. "/.")
assert(picker.selection_count == 2, "A refresh of the same folder should preserve the batch")
picker:onMenuSelect(assert(findFile(child_directory)))
assert(picker.path == child_directory and picker.selection_count == 0 and not next(picker.selection))
picker:onFolderUp()
assert(not findFile(sample_path).dim and not findFile(text_path).dim)
picker:onMenuSelect(assert(findFile(sample_path)))
picker:onMenuSelect(assert(findFile(text_path)))
assert(picker.selection_count == 2)
picker:onLeftButtonTap()
assert(plugin.service.info.alias == alias)
local device_menu = assert(plugin.peer_menu)
assert(#plugin.send_files == 2 and device_menu.item_table[3].select_enabled == false)
device_menu:onMenuSelect(device_menu.item_table[2])
local batch_preview = assert(findWidget(require("ui/widget/menu")))
assert(batch_preview.title == "Preview files" and #batch_preview.item_table == 2)
batch_preview:onClose()
plugin.service:remember("192.168.0.2", {
    alias = "Quiet Peach", version = "2.2", protocol = "http", port = 53317, fingerprint = "test",
})
plugin:updatePeers()
local device_item = device_menu.item_table[3]
assert(device_item.peer.alias == "Quiet Peach")
assert(device_item.text == "「Quiet Peach」 (unencrypted)")
local finish_send
plugin.service.send = function(_, _, files, _, callback)
    assert(#files == 2 and files[1].path == text_path and files[2].path == sample_path)
    finish_send = callback
end
device_menu:onMenuSelect(device_item)
assert(plugin.transfer_dialog.title:find("「Quiet Peach」", 1, true))
finish_send(true, 2)
assert(plugin.peer_menu == device_menu and plugin.service and not plugin.transfer_dialog)
device_menu:onMenuSelect(device_menu.item_table[1])
picker = assert(findWidget(picker_type))
picker:onMenuSelect(assert(findFile(sample_path)))
picker:onLeftButtonTap()
assert(plugin.peer_menu == device_menu and #plugin.send_files == 1 and plugin.send_files[1].path == sample_path)
device_menu:onClose()
assert(not plugin.service and not plugin.poll and not plugin.peer_menu)
FileManager.instance.selected_files = { [sample_path] = true, [text_path] = false }
actions[1].callback()
assert(plugin.peer_menu and #plugin.send_files == 1 and plugin.send_files[1].path == sample_path)
plugin:stop()
FileManager.instance.selected_files = nil

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
    assert(plugin.receive_dialog.title == "LocalSend Lite")
    assert(plugin.receive_dialog.status_widget.text:find("「" .. localized_alias .. "」", 1, true))
    plugin.service.incoming = transfer
    plugin:updateReceiveStatus()
    assert(plugin.receive_dialog.status_widget.text:find(locale == "zh_CN" and "当前文件" or "目前檔案", 1, true))
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
