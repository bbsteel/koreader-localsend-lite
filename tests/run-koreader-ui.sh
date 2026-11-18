#!/usr/bin/env bash
set -euo pipefail

project_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
koreader_directory=${1:-$(flatpak info --show-location rocks.koreader.KOReader)/files/lib/koreader}
export TMPDIR="$HOME/tmp"
mkdir -p -- "$TMPDIR"
scratch_directory=$(mktemp -d -p "$TMPDIR" koreader-localsend-ui.XXXXXX)
trap 'rm -rf -- "$scratch_directory"' EXIT
cd -- "$koreader_directory"
export KO_HOME="$scratch_directory" SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
export LD_LIBRARY_PATH="$PWD/libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
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
    actions[2].callback()
    local localized_alias = plugin.service.info.alias
    assert(localized_alias == alias_for(plugin.service.info.fingerprint, locale))
    assert(localized_alias:find("的", 1, true) and localized_alias ~= alias)
    assert(plugin.receive_dialog.title:find(localized_alias, 1, true))
    plugin:stop()
end
print("PASS: native menus, live device list, language-aware nicknames, and listener cleanup")
LUA
