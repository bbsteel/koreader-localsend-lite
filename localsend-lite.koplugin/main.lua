local Device = require("device")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local gettext = require("gettext")
local translate = require("localsend_lite_locale")

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

local function displayAlias(alias)
    return "「" .. alias .. "」"
end

function LocalSend:init()
    self.ui.menu:registerToMainMenu(self)
end

function LocalSend:log(event, ...)
    if not self.write_log then
        self.write_log = require("localsend_lite_log")(DataStorage:getSettingsDir() .. "/localsend-lite.log")
    end
    self.write_log(event, ...)
end

function LocalSend:addToMainMenu(menu_items)
    menu_items[PLUGIN_ID] = {
        text = translate("LocalSend Lite"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = translate("Send files"), callback = function() self:chooseFiles(true) end },
            { text = translate("Receive files"), callback = function() self:begin("receive") end },
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

function LocalSend:chooseFiles(use_library_selection)
    if use_library_selection and self.ui.selected_files and next(self.ui.selected_files) then
        local paths = {}
        for path, selected in pairs(self.ui.selected_files) do
            if selected then paths[#paths + 1] = path end
        end
        table.sort(paths)
        if #paths > 0 then return self:useSendFiles(paths) end
    end
    UIManager:show(require("localsend_lite_picker"):new{
        path = self:defaultDirectory(),
        height = Device.screen:getHeight(),
        preview_file = function(path) self:previewFile(path) end,
        on_files_selected = function(paths) self:useSendFiles(paths) end,
    })
end

function LocalSend:useSendFiles(paths)
    if not self.peer_menu then return self:begin("send", paths) end
    local prepared, files = pcall(self.prepareFiles, self, self.service, paths)
    if not prepared then notify(tostring(files), 4); return end
    self.send_files = files
    self:updatePeers(true)
end

function LocalSend:prepareFiles(service, paths)
    local maximum = require("localsend_lite_service").MAX_FILES
    assert(#paths <= maximum, T(translate("At most %1 files per transfer."), maximum))
    local files = {}
    for _, path in ipairs(paths) do
        local extension = path:match("%.([^./]+)$") or ""
        files[#files + 1] = service:file(path, MIME_TYPES[extension:lower()])
    end
    return files
end

function LocalSend:previewFile(path)
    local attributes = require("libs/libkoreader-lfs").attributes(path)
    if not attributes or attributes.mode ~= "file" then
        notify(translate("Cannot read source file"), 3)
        return
    end
    local util = require("util")
    local filename = path:match("[^/]+$")
    local details = util.getFriendlySize(attributes.size)
    if path:lower():match("%.txt$") then
        local file = io.open(path, "rb")
        if file then
            local excerpt = file:read(4096) or ""
            file:close()
            details = details .. "\n\n" .. util.fixUtf8(excerpt, "�")
            if attributes.size > #excerpt then details = details .. "…" end
            UIManager:show(require("ui/widget/textviewer"):new{ title = filename, text = details })
            return
        end
    end
    local dialog
    local buttons = {{ { text = translate("Close"), callback = function() UIManager:close(dialog) end } }}
    if self.ui.bookinfo and require("document/documentregistry"):hasProvider(path) and not path:lower():match("%.txt$") then
        buttons[1][2] = { text = translate("Show cover"), callback = function()
            local ok = pcall(self.ui.bookinfo.onShowBookCover, self.ui.bookinfo, path)
            if not ok then notify(translate("Cannot preview this file."), 3) end
        end }
    end
    dialog = require("ui/widget/buttondialog"):new{ title = filename .. "\n\n" .. details, buttons = buttons }
    UIManager:show(dialog)
end

function LocalSend:begin(mode, paths)
    if self.service or self.startup or self.closing_firewall then return end
    self:log("start.requested", mode)
    require("ui/network/manager"):runWhenConnected(function()
        if not self.ui.tearing_down then self:start(mode, paths) end
    end)
end

function LocalSend:start(mode, paths)
    if self.service or self.startup or self.closing_firewall then return end
    self:log("start.begin", mode, Device.model)
    if not Device:isKindle() then return self:startService(mode, paths) end

    local startup = {}
    self.startup = startup
    self.startup_dialog = require("ui/widget/buttondialog"):new{
        title = translate("Starting LocalSend Lite…"),
        dismissable = false,
        buttons = {{ { text = translate("Cancel"), callback = function()
            self:log("start.cancelled")
            self:stop()
        end } }},
    }
    UIManager:show(self.startup_dialog)
    UIManager:tickAfterNext(function()
        coroutine.wrap(function()
            if not startup.cancelled then self:startService(mode, paths, startup) end
            self.startup = nil
            self:closeWidget("startup_dialog")
        end)()
    end)
end

function LocalSend:startService(mode, paths, startup)
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
                translate("Wi-Fi has no IPv4 address."))
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
                receiveEnded = function(session, reason) self:showReceiveEnded(session, reason) end,
                receiveFailed = function(filename, failure)
                    local reason = tostring(failure):gsub("^.-:%d+: ", "")
                    require("logger").warn("LocalSend Lite receive failed:", filename, reason)
                    notify(T(translate("Could not receive %1: %2"), filename, translate(reason)), 4)
                end,
                networkError = function(message) require("logger").dbg("LocalSend Lite", message) end,
                diagnostic = self.write_log,
            },
        }
        if mode == "send" then
            prepared_files = self:prepareFiles(service, paths)
        end
        self.service = service
        self:log("listener.begin", port)
        service:start()
        if kindle_network then
            self:log("firewall.open.begin", wifi_interface)
            self.close_firewall = assert(kindle_network.openFirewall(wifi_interface, wifi_address,
                port, service.discovery_port, Service.MULTICAST_GROUP, nil, self.write_log))
            self:log("firewall.open.done")
        end
        if not startup or not startup.cancelled then assert(service:announce(true)) end
    end)
    if startup and startup.cancelled then
        self:closeKindleFirewall()
        return
    end
    if not success then
        local reason = tostring(failure):gsub("^.-:%d+: ", "")
        self:log("start.failed", mode, reason)
        self:stop()
        require("logger").warn("LocalSend Lite startup failed:", reason)
        notify(T(translate("LocalSend Lite could not start: %1"), translate(reason)))
        return
    end

    local service = self.service
    self:log("start.ready", mode, service.info.port)
    if mode == "send" then self:showPeers(prepared_files) else self:showReceiver() end
    local socket = require("socket")
    local next_announcement = socket.gettime() + 2
    self.poll = function()
        local ok, error_message = pcall(service.tick, service)
        if not ok then
            self:log("listener.failed", error_message)
            self:stop()
            notify(T(translate("LocalSend Lite stopped: %1"), tostring(error_message)))
        elseif self.service == service then
            if self.finish_cancellation then
                local cancellation_pending
                for _, task in ipairs(service.tasks) do
                    if task.kind == "cancel" then cancellation_pending = true; break end
                end
                if not cancellation_pending then self.finish_cancellation = nil end
            end
            if (self.peer_menu or self.receive_dialog and not service.incoming)
                and socket.gettime() >= next_announcement then
                service:announce(true)
                next_announcement = socket.gettime() + (self.peer_menu and 2 or 5)
            end
            if self.peer_menu then self:updatePeers() end
            if self.receive_dialog then self:updateReceiveStatus() end
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

function LocalSend:closeKindleFirewall()
    local close_firewall = self.close_firewall
    if not close_firewall then return end
    self.close_firewall = nil
    self.closing_firewall = true
    self:log("firewall.close.begin")
    coroutine.wrap(function()
        local completed, removed = pcall(close_firewall)
        self.closing_firewall = nil
        if completed and removed then
            self:log("firewall.close.done")
        else
            self:log("firewall.close.failed", removed)
            if not completed then require("logger").warn("LocalSend Lite firewall cleanup failed:", removed) end
        end
    end)()
end

function LocalSend:stop(reason)
    if self.service then
        local session = self.service.incoming
        self:log("listener.stop", reason or "closed", session and session.saved, session and session.total_files)
    end
    if self.startup then self.startup.cancelled = true end
    if self.poll then UIManager:unschedule(self.poll) end
    if self.service then self.service:stop() end
    self:closeKindleFirewall()
    self.service, self.poll, self.finish_cancellation = nil, nil, nil
    self.peer_snapshot = nil
    self.send_files = nil
    self.receive_progress = nil
    self:closeOffer()
    self:closeWidget("startup_dialog")
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
function LocalSend:onExit() self:stop("KOReader exit") end
function LocalSend:onSuspend() self:stop("device suspended") end
function LocalSend:onNetworkDisconnected() self:stop("network disconnected") end

function LocalSend:showReceiver()
    local dialog = require("ui/widget/buttondialog"):new{
        title = translate("LocalSend Lite"),
        title_align = "center",
        use_info_style = false,
        buttons = {{ { text = translate("Stop"), callback = function() self:stop() end } }},
        tap_close_callback = function()
            self.receive_dialog = nil
            self:stop()
        end,
    }
    dialog.status_widget = require("ui/widget/textboxwidget"):new{
        text = self:waitingForFilesStatus(),
        width = dialog:getAddedWidgetAvailableWidth(),
        face = dialog.info_face,
        parent = dialog,
        not_focusable = true,
    }
    dialog:addWidget(dialog.status_widget)
    self.receive_dialog = dialog
    UIManager:show(dialog)
end

function LocalSend:waitingForFilesStatus()
    return T(translate("Waiting for files as %1\n\nSave to %2"),
        displayAlias(self.service.info.alias), self.service.receive_directory)
end

function LocalSend:setReceiveStatus(status)
    local dialog = self.receive_dialog
    if dialog.status_widget.text ~= status then
        dialog.status_widget:setText(status)
        dialog:reinit()
        UIManager:setDirty("all", "ui")
    end
end

function LocalSend:updateReceiveStatus()
    if not self.receive_dialog then return end
    local session = self.service.incoming
    if not session or not session.accepted then
        if self.receive_progress then
            self.receive_progress = nil
            self:setReceiveStatus(self:waitingForFilesStatus())
        end
        return
    end

    local now = require("socket").gettime()
    local previous = self.receive_progress
    local bytes_per_second = 0
    if previous and previous.session == session then
        local elapsed = now - previous.updated_at
        if elapsed < 1 then return end
        bytes_per_second = math.max(0, (session.received_bytes - previous.received_bytes) / elapsed)
    end
    self.receive_progress = { session = session, updated_at = now, received_bytes = session.received_bytes }

    local current_file
    local active_count = 0
    for _, file in ipairs(session.ordered_files) do
        if file.busy and not file.saved then
            active_count = active_count + 1
            if not current_file or file.receive_order < current_file.receive_order then current_file = file end
        end
    end
    local current_status = translate("Waiting for the next file…")
    if current_file then
        local file_percent = current_file.size == 0 and 100
            or math.floor(100 * current_file.received_bytes / current_file.size)
        current_status = T(translate("Current file: %1 (%2%)"), current_file.name, file_percent)
        if active_count > 1 then
            current_status = current_status .. "\n" .. T(translate("%1 other files receiving"), active_count - 1)
        end
    end

    local batch_percent = session.total_bytes > 0
        and math.floor(100 * session.received_bytes / session.total_bytes)
        or math.floor(100 * session.saved / session.total_files)
    local speed = require("util").getFriendlySize(math.floor(bytes_per_second))
    self:setReceiveStatus(table.concat({
        T(translate("Receiving from %1"), displayAlias(session.alias)),
        current_status,
        T(translate("%1/%2 files saved · %3% · %4/s"), session.saved, session.total_files, batch_percent, speed),
    }, "\n\n"))
end

function LocalSend:showPeers(files)
    self.send_files = files
    local menu = require("ui/widget/menu"):new{
        title = T(translate("Send files (%1)"), #files),
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
        item_table = {},
        onMenuSelect = function(_, item)
            if item.callback then item.callback() end
            if item.peer then self:send(item.peer, self.send_files) end
            return true
        end,
        close_callback = function()
            self.peer_menu = nil
            self:stop()
        end,
    }
    self.peer_menu = menu
    self:updatePeers(true)
    UIManager:show(menu)
end

function LocalSend:previewSendFiles()
    local items = {}
    for _, file in ipairs(self.send_files) do
        items[#items + 1] = { text = file.fileName, mandatory = require("util").getFriendlySize(file.size), path = file.path }
    end
    UIManager:show(require("ui/widget/menu"):new{
        title = translate("Preview files"),
        item_table = items,
        onMenuSelect = function(_, item) self:previewFile(item.path); return true end,
    })
end

function LocalSend:updatePeers(force)
    local peers = self.service:listPeers()
    local previous = self.peer_snapshot or {}
    local changed = force or #peers ~= #previous
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
    local items = {
        { text = translate("Choose files…"), callback = function() self:chooseFiles() end },
        { text = translate("Preview files"), callback = function() self:previewSendFiles() end },
    }
    if #peers == 0 then
        items[#items + 1] = { text = translate("Looking for nearby devices…"), select_enabled = false }
    end
    for _, peer in ipairs(peers) do
        local label = displayAlias(peer.alias)
        if peer.protocol == "http" then label = T(translate("%1 (unencrypted)"), label) end
        items[#items + 1] = { text = label, peer = peer }
    end
    self.peer_menu:switchItemTable(T(translate("Send files (%1)"), #self.send_files), items)
end

function LocalSend:requestPin(peer, files)
    self.pin_dialog = require("ui/widget/inputdialog"):new{
        title = translate("Receiver PIN"),
        buttons = {{
            { text = translate("Cancel"), id = "close", callback = function() self:closeWidget("pin_dialog") end },
            { text = translate("Send"), callback = function()
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
    if self.transfer_dialog or self.finish_cancellation or self.pin_dialog then return end
    self.transfer_dialog = require("ui/widget/buttondialog"):new{
        title = T(translate("Sending to %1…"), displayAlias(peer.alias)),
        dismissable = false,
        buttons = {{ { text = translate("Cancel"), callback = function()
            self.service:cancelSend()
            self:closeWidget("transfer_dialog")
            self.finish_cancellation = true
        end } }},
    }
    UIManager:show(self.transfer_dialog)
    self.service:send(peer, files, pin, function(success, detail)
        self:closeWidget("transfer_dialog")
        if detail == 401 and not success then self:requestPin(peer, files); return end
        if success then
            if type(detail) == "number" and detail < #files then
                notify(T(translate("Sent %1 of %2 files."), detail, #files), 3)
            else
                notify(translate("LocalSend Lite transfer complete."), 2)
            end
        elseif detail == 403 then
            notify(translate("The receiver declined the transfer."), 3)
        elseif detail == 409 then
            notify(translate("The receiver is busy with another transfer."), 3)
        else
            notify(T(translate("LocalSend Lite transfer failed: %1"), tostring(detail or translate("No files were accepted"))))
        end
    end)
end

function LocalSend:closeOffer(session)
    if self.offer_dialog and (not session or session == self.offer_session) then
        self.offer_session = nil
        self:closeWidget("offer_dialog")
    end
end

function LocalSend:showOffer(session, respond, page)
    local files_per_page = 5
    page = page or 1
    local page_count = math.ceil(#session.ordered_files / files_per_page)
    local lines = { T(translate("Receive files from %1?"), displayAlias(session.alias)), "" }
    local file_prefix = #session.ordered_files > 1 and "• " or ""
    for index = (page - 1) * files_per_page + 1, math.min(page * files_per_page, #session.ordered_files) do
        lines[#lines + 1] = file_prefix .. session.ordered_files[index].name
    end
    local page_buttons
    if page_count > 1 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = T(translate("Page %1 of %2"), page, page_count)
        local buttons = {}
        local function goToPage(target_page)
            self:closeOffer(session)
            self:showOffer(session, respond, target_page)
        end
        if page > 1 then
            buttons[#buttons + 1] = { text = translate("Previous"), callback = function() goToPage(page - 1) end }
        end
        if page < page_count then
            buttons[#buttons + 1] = { text = translate("Next"), callback = function() goToPage(page + 1) end }
        end
        page_buttons = { buttons }
    end
    self.offer_session = session
    local function decide(accepted)
        if accepted and page_buttons then self:closeOffer(session) end
        self.offer_session, self.offer_dialog = nil, nil
        respond(accepted)
        if accepted then self:updateReceiveStatus() end
    end
    self.offer_dialog = require("ui/widget/confirmbox"):new{
        text = table.concat(lines, "\n"),
        ok_text = translate("Accept"),
        cancel_text = translate("Decline"),
        other_buttons = page_buttons,
        other_buttons_first = true,
        keep_dialog_open = page_buttons ~= nil,
        ok_callback = function() decide(true) end,
        cancel_callback = function() decide(false) end,
        dismissable = false,
    }
    UIManager:show(self.offer_dialog)
end

function LocalSend:showReceived(path, session)
    self.received_files = true
    if session.remaining == 0 then
        local message = session.saved == 1 and T(translate("Received %1"), path:match("[^/]+$"))
            or T(translate("Received %1 files."), session.saved)
        notify(message, 3)
    end
end

function LocalSend:showReceiveEnded(session, reason)
    self:updateReceiveStatus()
    if session.saved > 0 then self.received_files = true end
    local message = reason == "timeout" and translate("Saved %1 of %2 files. Transfer timed out.")
        or translate("Saved %1 of %2 files. Sender cancelled.")
    notify(T(message, session.saved, session.total_files), 4)
end

return LocalSend
