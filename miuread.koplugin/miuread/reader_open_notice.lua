local InfoMessage = require("ui/widget/infomessage")
local BD = require("ui/bidi")
local FileManagerUtil = require("apps/filemanager/filemanagerutil")
local FFIUtil = require("ffi/util")
local _ = require("gettext")

local Notice = {}

function Notice.install(reader, pending)
    if reader._miuread_open_notice or type(reader.showReaderCoroutine) ~= "function" then return end
    local show = reader.showReaderCoroutine
    reader.showReaderCoroutine = function(self, path, ...)
        local target = pending()
        if not target or (target ~= path and (not FFIUtil.realpath or FFIUtil.realpath(target) ~= path)) then
            return show(self, path, ...)
        end

        local opening = FFIUtil.template(_("Opening file '%1'."), BD.filepath(FileManagerUtil.abbreviate(path)))
        local original = InfoMessage.new
        local own_constructor = rawget(InfoMessage, "new")
        -- KOReader constructs its loading widget before scheduling the document open.
        -- Change that widget's text while preserving its lifetime and repaint behavior.
        InfoMessage.new = function(widget, options, ...)
            if widget == InfoMessage and options and options.text == opening then
                InfoMessage.new = own_constructor
                options.text = "正在打开书…"
            end
            return original(widget, options, ...)
        end
        local ok, result = pcall(show, self, path, ...)
        InfoMessage.new = own_constructor
        if not ok then error(result, 0) end
        return result
    end
    reader._miuread_open_notice = true
end

return Notice
