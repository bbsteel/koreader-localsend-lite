local PathChooser = require("ui/widget/pathchooser")
local UIManager = require("ui/uimanager")
local ffi_util = require("ffi/util")
local T = ffi_util.template
local translate = require("localsend_lite_locale")

local Picker = PathChooser:extend{
    select_directory = false,
    show_unsupported = true,
}

function Picker:init()
    self.selection = {}
    self.selection_count = 0
    self.title = T(translate("Send files (%1)"), 0)
    PathChooser.init(self)
    self:setTitleBarLeftIcon("check")
    self.onLeftButtonTap = function() self:confirmSelection() end
end

function Picker:getListItem(...)
    local item = PathChooser.getListItem(self, ...)
    if item.is_file then item.dim = self.selection[item.path] end
    return item
end

function Picker:changeToPath(path, focused_path)
    local destination = ffi_util.realpath(path)
    if not destination then return end
    if destination ~= self.path then
        self.selection = {}
        self.selection_count = 0
        self.title_bar:setTitle(T(translate("Send files (%1)"), 0))
    end
    PathChooser.changeToPath(self, destination, focused_path)
end

function Picker:onMenuSelect(item)
    if not item.is_file then return PathChooser.onMenuSelect(self, item) end
    if self.selection[item.path] then
        self.selection[item.path] = nil
        self.selection_count = self.selection_count - 1
    else
        self.selection[item.path] = true
        self.selection_count = self.selection_count + 1
    end
    item.dim = self.selection[item.path]
    self.title_bar:setTitle(T(translate("Send files (%1)"), self.selection_count))
    self:updateItems(self.itemnumber, true)
    return true
end

function Picker:onMenuHold(item)
    if item.is_file then self.preview_file(item.path) end
    return true
end

function Picker:confirmSelection()
    if self.selection_count == 0 then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = translate("Tap files to select them. Long-press to preview."),
            timeout = 3,
        })
        return
    end
    local paths = {}
    for path in pairs(self.selection) do paths[#paths + 1] = path end
    table.sort(paths)
    UIManager:close(self)
    self.on_files_selected(paths)
end

return Picker
