local Device = require("device")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local gettext = require("gettext")

local PLUGIN_ID = "localsend-lite"
local LocalSend = WidgetContainer:extend{ name = PLUGIN_ID }

local MIME_TYPES = {
    epub = "application/epub+zip", pdf = "application/pdf", txt = "text/plain",
    mobi = "application/x-mobipocket-ebook", azw3 = "application/x-mobipocket-ebook",
    zip = "application/zip", jpg = "image/jpeg", jpeg = "image/jpeg", png = "image/png",
}

local function notify(message, timeout)
    UIManager:show(require("ui/widget/infomessage"):new{ text = message, timeout = timeout })
end

function LocalSend:init()
    self.ui.menu:registerToMainMenu(self)
end

function LocalSend:addToMainMenu(menu_items)
    menu_items[PLUGIN_ID] = {
        text = gettext("LocalSend Lite"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = gettext("Send files"), callback = function() self:chooseFiles() end },
            { text = gettext("Receive files"), callback = function() self:begin("receive") end },
        },
    }
    -- KOReader adds items with sorting_hint at the end of the tab.
    -- Set the default order explicitly so LocalSend is visible on page one.
    local menu_order = self.ui.document and "ui/elements/reader_menu_order"
        or "ui/elements/filemanager_menu_order"
    local tools_order = require(menu_order).tools
    if tools_order and tools_order[1] ~= PLUGIN_ID then
        for index, menu_id in ipairs(tools_order) do
            if menu_id == PLUGIN_ID then
                table.remove(tools_order, index)
                break
            end
        end
        table.insert(tools_order, 1, PLUGIN_ID)
    end
end

function LocalSend:defaultDirectory()
    if self.ui.file_chooser and self.ui.file_chooser.path then return self.ui.file_chooser.path end
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    return filemanagerutil.getHomeFolder() or filemanagerutil.getDefaultDir()
end

function LocalSend:chooseFiles()
    if self.ui.selected_files and next(self.ui.selected_files) then
        local paths = {}
        for path in pairs(self.ui.selected_files) do paths[#paths + 1] = path end
        table.sort(paths)
        self:begin("send", paths)
        return
    end
    UIManager:show(require("ui/widget/pathchooser"):new{
        path = self:defaultDirectory(),
        height = Device.screen:getHeight(),
        select_directory = false,
        show_unsupported = true,
        onConfirm = function(path)
            UIManager:nextTick(function() self:begin("send", { path }) end)
        end,
    })
end

function LocalSend:begin(mode, paths)
    if self.service then return end
    require("ui/network/manager"):runWhenConnected(function()
        if not self.ui.tearing_down then self:start(mode, paths) end
    end)
end

function LocalSend:start(mode, paths)
    if self.service then return end
    local prepared_files
    local success, failure = pcall(function()
        local Identity = require("localsend_lite_identity")
        local Service = require("localsend_lite_service")
        local settings = G_reader_settings:readSetting(PLUGIN_ID, {})
        local port = tonumber(settings.port)
        if not port or port < 1 or port > 65535 or port % 1 ~= 0 then port = Service.DEFAULT_PORT end
        local directory = settings.receive_directory or self:defaultDirectory()
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(directory, "mode") ~= "directory" then directory = self:defaultDirectory() end
        local identity = Identity.open(DataStorage:getSettingsDir())
        local kindle_network, wifi_interface, wifi_address
        if Device:isKindle() then
            kindle_network = require("localsend_lite_kindle")
            wifi_interface = require("ui/network/manager"):getNetworkInterfaceName()
            wifi_address = assert(kindle_network.wifiAddress(wifi_interface),
                gettext("Wi-Fi has no IPv4 address."))
        end
        local service = Service.new{
            alias = require("localsend_lite_alias")(identity.fingerprint, gettext.current_lang),
            model = Device.model,
            identity = identity,
            receive_directory = directory,
            port = port,
            wifi_address = wifi_address,
            callbacks = {
                offer = function(session, respond)
                    if mode == "receive" then self:showOffer(session, respond) else respond(false) end
                end,
                offerClosed = function(session) self:closeOffer(session) end,
                received = function(path, session) self:showReceived(path, session) end,
                networkError = function(message) require("logger").dbg("LocalSend", message) end,
            },
        }
        if mode == "send" then
            assert(#paths <= Service.MAX_FILES, T(gettext("At most %1 files per transfer."), Service.MAX_FILES))
            prepared_files = {}
            for _, path in ipairs(paths) do
                local extension = path:match("%.([^./]+)$") or ""
                prepared_files[#prepared_files + 1] = service:file(path, MIME_TYPES[extension:lower()])
            end
        end
        self.service = service
        service:start()
        if kindle_network then
            self.close_firewall = assert(kindle_network.openFirewall(wifi_interface, wifi_address,
                port, service.discovery_port, Service.MULTICAST_GROUP))
        end
        assert(service:announce(true))
    end)
    if not success then
        self:stop()
        notify(T(gettext("LocalSend Lite could not start: %1"), tostring(failure)))
        return
    end

    local service = self.service
    if mode == "send" then self:showPeers(prepared_files) else self:showReceiver() end
    local socket = require("socket")
    local next_announcement = socket.gettime() + 2
    self.poll = function()
        local ok, error_message = pcall(service.tick, service)
        if not ok then
            self:stop()
            notify(T(gettext("LocalSend Lite stopped: %1"), tostring(error_message)))
        elseif self.service == service then
            if self.finish_cancellation then
                local cancellation_pending
                for _, task in ipairs(service.tasks) do
                    if task.kind == "cancel" then cancellation_pending = true; break end
                end
                if not cancellation_pending then self:stop(); return end
            end
            if (self.peer_menu or self.receive_dialog and not service.incoming)
                and socket.gettime() >= next_announcement then
                service:announce(true)
                next_announcement = socket.gettime() + (self.peer_menu and 2 or 5)
            end
            if self.peer_menu then self:updatePeers() end
            UIManager:scheduleIn(#service.tasks > 0 and 0.02 or 0.15, self.poll)
        end
    end
    UIManager:scheduleIn(0.02, self.poll)
end

function LocalSend:closeWidget(field)
    local widget = self[field]
    self[field] = nil
    if widget then UIManager:close(widget) end
end

function LocalSend:stop()
    if self.poll then UIManager:unschedule(self.poll) end
    if self.service then self.service:stop() end
    if self.close_firewall then
        self.close_firewall()
        self.close_firewall = nil
    end
    self.service, self.poll, self.finish_cancellation = nil, nil, nil
    self.peer_snapshot = nil
    self:closeOffer()
    self:closeWidget("transfer_dialog")
    self:closeWidget("receive_dialog")
    self:closeWidget("peer_menu")
    self:closeWidget("pin_dialog")
    if self.ui.file_chooser and self.received_files and not self.ui.tearing_down then
        self.ui.file_chooser:refreshPath()
    end
    self.received_files = nil
end

function LocalSend:stopPlugin()
    self:stop()
    return true
end

LocalSend.onCloseWidget = LocalSend.stop
LocalSend.onExit = LocalSend.stop
LocalSend.onSuspend = LocalSend.stop
LocalSend.onNetworkDisconnected = LocalSend.stop

function LocalSend:showReceiver()
    local service = self.service
    self.receive_dialog = require("ui/widget/buttondialog"):new{
        title = T(gettext("Waiting for files as %1\n\nSave to %2"), service.info.alias, service.receive_directory),
        buttons = {{ { text = gettext("Stop"), callback = function() self:stop() end } }},
        tap_close_callback = function()
            self.receive_dialog = nil
            self:stop()
        end,
    }
    UIManager:show(self.receive_dialog)
end

function LocalSend:showPeers(files)
    local menu = require("ui/widget/menu"):new{
        title = gettext("LocalSend Lite"),
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
        item_table = { { text = gettext("Looking for nearby devices…"), select_enabled = false } },
        onMenuSelect = function(_, item)
            if item.peer then
                self:closeWidget("peer_menu")
                self:send(item.peer, files)
            end
            return true
        end,
        close_callback = function()
            self.peer_menu = nil
            self:stop()
        end,
    }
    self.peer_menu = menu
    UIManager:show(menu)
end

function LocalSend:updatePeers()
    local peers = self.service:listPeers()
    local previous = self.peer_snapshot or {}
    local changed = #peers ~= #previous
    for index, peer in ipairs(peers) do
        local prior = previous[index]
        if not prior or prior.alias ~= peer.alias or prior.address ~= peer.address
            or prior.port ~= peer.port or prior.protocol ~= peer.protocol
            or prior.fingerprint ~= peer.fingerprint then
            changed = true
            break
        end
    end
    if not changed then return end

    self.peer_snapshot = peers
    local items = {}
    for _, peer in ipairs(peers) do
        local label = peer.alias
        if peer.protocol == "http" then label = T(gettext("%1 (unencrypted)"), label) end
        items[#items + 1] = { text = label, peer = peer }
    end
    self.peer_menu:switchItemTable(nil, items)
end

function LocalSend:requestPin(peer, files)
    self.pin_dialog = require("ui/widget/inputdialog"):new{
        title = gettext("Receiver PIN"),
        buttons = {{
            { text = gettext("Cancel"), id = "close", callback = function() self:stop() end },
            { text = gettext("Send"), callback = function()
                local pin = self.pin_dialog:getInputText()
                self:closeWidget("pin_dialog")
                self:send(peer, files, pin)
            end },
        }},
    }
    UIManager:show(self.pin_dialog)
    self.pin_dialog:onShowKeyboard()
end

function LocalSend:send(peer, files, pin)
    self.transfer_dialog = require("ui/widget/buttondialog"):new{
        title = T(gettext("Sending to %1…"), peer.alias),
        dismissable = false,
        buttons = {{ { text = gettext("Cancel"), callback = function()
            self.service:cancelSend()
            self:closeWidget("transfer_dialog")
            self.finish_cancellation = true
        end } }},
    }
    UIManager:show(self.transfer_dialog)
    self.service:send(peer, files, pin, function(success, detail)
        self:closeWidget("transfer_dialog")
        if detail == 401 and not success then self:requestPin(peer, files); return end
        self:stop()
        if success then
            if type(detail) == "number" and detail < #files then
                notify(T(gettext("Sent %1 of %2 files."), detail, #files), 3)
            else
                notify(gettext("LocalSend Lite transfer complete."), 2)
            end
        elseif detail == 403 then
            notify(gettext("The receiver declined the transfer."), 3)
        elseif detail == 409 then
            notify(gettext("The receiver is busy with another transfer."), 3)
        else
            notify(T(gettext("LocalSend Lite transfer failed: %1"), tostring(detail or gettext("No files were accepted"))))
        end
    end)
end

function LocalSend:closeOffer(session)
    if self.offer_dialog and (not session or session == self.offer_session) then
        self.offer_session = nil
        self:closeWidget("offer_dialog")
    end
end

function LocalSend:showOffer(session, respond)
    local lines = { T(gettext("Receive files from %1?"), session.alias), "" }
    for index, file in ipairs(session.ordered_files) do
        if index > 5 then lines[#lines + 1] = T(gettext("+%1 more"), #session.ordered_files - 5); break end
        lines[#lines + 1] = file.name
    end
    self.offer_session = session
    local function decide(accepted)
        self.offer_session, self.offer_dialog = nil, nil
        respond(accepted)
    end
    self.offer_dialog = require("ui/widget/confirmbox"):new{
        text = table.concat(lines, "\n"),
        ok_text = gettext("Accept"),
        cancel_text = gettext("Decline"),
        ok_callback = function() decide(true) end,
        cancel_callback = function() decide(false) end,
        dismissable = false,
    }
    UIManager:show(self.offer_dialog)
end

function LocalSend:showReceived(path, session)
    self.received_files = true
    if session.remaining == 0 then
        local message = session.saved == 1 and T(gettext("Received %1"), path:match("[^/]+$"))
            or T(gettext("Received %1 files."), session.saved)
        notify(message, 3)
    end
end

return LocalSend
