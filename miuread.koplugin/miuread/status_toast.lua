local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Screen = Device.screen

local Toast = InputContainer:extend{
    title = "",
    text = "",
    timeout = 3,
    modal = false,
    _timeout_func = nil,
    on_close_callback = nil,
}

local function repaint(widget, dimen)
    if not dimen then return end
    UIManager:setDirty(widget, function()
        return "partial", dimen
    end)
end

function Toast:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local side_margin = math.max(Screen:scaleBySize(12), math.floor(screen_w * 0.018))
    local bottom_margin = math.max(Screen:scaleBySize(28), math.floor(screen_h * 0.035))
    local padding = math.max(Screen:scaleBySize(8), tonumber(Size.padding.default) or 0)
    local gap = math.max(Screen:scaleBySize(3), 2)
    local border = math.max(1, tonumber(Size.border.window) or 1)
    local text_width = math.min(
        math.floor(screen_w * 0.50),
        screen_w - side_margin * 2 - padding * 2 - border * 2
    )

    local title_widget = TextBoxWidget:new{
        text = tostring(self.title or ""),
        face = Font:getFace("smallinfofont"),
        width = text_width,
        alignment = "left",
    }
    local body_widget = TextBoxWidget:new{
        text = tostring(self.text or ""),
        face = Font:getFace("x_smallinfofont"),
        width = text_width,
        alignment = "left",
    }

    local content = VerticalGroup:new{
        align = "left",
        title_widget,
        VerticalSpan:new{width = gap},
        body_widget,
    }

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = tonumber(Size.radius.window) or 0,
        bordersize = border,
        margin = 0,
        padding = padding,
        content,
    }

    local frame_size = self.frame:getSize()
    local x = math.max(side_margin, screen_w - frame_size.w - side_margin)
    local y = math.max(side_margin, screen_h - frame_size.h - bottom_margin)
    self.popup_dimen = Geom:new{x = x, y = y, w = frame_size.w, h = frame_size.h}
    self.frame.overlap_offset = {x, y}
    self[1] = OverlapGroup:new{
        dimen = Screen:getSize(),
        allow_mirroring = false,
        self.frame,
    }
end

function Toast:onShow()
    repaint(self, self.popup_dimen)
    local timeout = tonumber(self.timeout)
    if timeout and timeout > 0 then
        self._timeout_func = function()
            self._timeout_func = nil
            UIManager:close(self)
        end
        UIManager:scheduleIn(timeout, self._timeout_func)
    end
    return true
end

function Toast:onCloseWidget()
    local old_dimen = self.popup_dimen and self.popup_dimen:copy() or nil
    if self._timeout_func then
        UIManager:unschedule(self._timeout_func)
        self._timeout_func = nil
    end
    if self.on_close_callback then
        local callback = self.on_close_callback
        self.on_close_callback = nil
        pcall(callback)
    end
    repaint(nil, old_dimen)
end

local M = {}
local active_toast = nil

function M.show(opts)
    opts = opts or {}
    if active_toast then
        pcall(UIManager.close, UIManager, active_toast)
        active_toast = nil
    end

    local toast
    toast = Toast:new{
        title = opts.title,
        text = opts.text,
        timeout = opts.timeout or 3,
        on_close_callback = function()
            if active_toast == toast then active_toast = nil end
        end,
    }
    active_toast = toast
    UIManager:show(toast)
    return toast
end

return M
