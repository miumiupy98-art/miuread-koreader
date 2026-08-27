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

local Screen = Device.screen

local Toast = InputContainer:extend{
    title = "",
    toast = true,
    _miuread_transient = true,
    text = "",
    timeout = 3,
    modal = false,
    _timeout_func = nil,
    on_close_callback = nil,
    closed = false,
    _closing_with_refresh = false,
}

local function repaint(widget, dimen, refresh_type)
    if not dimen then return end
    UIManager:setDirty(widget, refresh_type or "ui", dimen)
end

local function repaint_uncovered(dimen)
    if not dimen then return end
    local region=dimen:copy()
    UIManager:nextTick(function()
        -- CloseWidget is dispatched before UIManager removes the toast from its
        -- window stack. Repaint on the next tick so the widgets now exposed
        -- underneath it are actually painted before the E-Ink refresh.
        UIManager:setDirty("all", "ui", region)
    end)
end

local function clean_line(value)
    return tostring(value or ""):gsub("[ \t]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function toast_text(title, text)
    local left = clean_line(title)
    local right = tostring(text or ""):gsub("[ \t]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if left == "" then return right end
    if right == "" then return left end
    return left .. "\n" .. right
end

function Toast:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local side_margin = math.max(Screen:scaleBySize(12), math.floor(screen_w * 0.018))
    local bottom_margin = math.max(Screen:scaleBySize(24), math.floor(screen_h * 0.030))
    local padding_h = math.max(Screen:scaleBySize(10), tonumber(Size.padding.default) or 0)
    local padding_v = math.max(Screen:scaleBySize(6), tonumber(Size.padding.small) or 0)
    local border = math.max(1, tonumber(Size.border.window) or 1)

    local max_text_w = math.max(Screen:scaleBySize(180), math.floor(screen_w * 0.82))
    local label = TextBoxWidget:new{
        text = toast_text(self.title, self.text),
        face = Font:getFace("x_smallinfofont"),
        width = max_text_w,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "center",
    }

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = tonumber(Size.radius.window) or 0,
        bordersize = border,
        margin = 0,
        padding = math.max(padding_h, padding_v),
        label,
    }

    local frame_size = self.frame:getSize()
    local x = math.max(side_margin, math.floor((screen_w - frame_size.w) / 2))
    local y = math.max(side_margin, screen_h - frame_size.h - bottom_margin)
    self.popup_dimen = Geom:new{x = x, y = y, w = frame_size.w, h = frame_size.h}
    self.frame.overlap_offset = {x, y}
    self[1] = OverlapGroup:new{
        dimen = Screen:getSize(),
        allow_mirroring = false,
        self.frame,
    }
end

function Toast:_close()
    if self.closed then return true end
    self.closed = true
    self._closing_with_refresh = true
    local region = self.popup_dimen and self.popup_dimen:copy() or nil
    -- A toast may sit over ReaderUI or over a MiuRead full-screen menu. Use an
    -- UI waveform for the small former-toast rectangle so menu pixels cannot
    -- remain as ghosting after the timer fires.
    UIManager:close(self, "ui", region)
    return true
end

function Toast:onShow()
    repaint(self, self.popup_dimen, "ui")
    local timeout = tonumber(self.timeout)
    if timeout and timeout > 0 then
        self._timeout_func = function()
            self._timeout_func = nil
            self:_close()
        end
        UIManager:scheduleIn(timeout, self._timeout_func)
    end
    return true
end

function Toast:onCloseWidget()
    local old_dimen = self.popup_dimen and self.popup_dimen:copy() or nil
    self.closed = true
    if self._timeout_func then
        UIManager:unschedule(self._timeout_func)
        self._timeout_func = nil
    end
    if self.on_close_callback then
        local callback = self.on_close_callback
        self.on_close_callback = nil
        pcall(callback)
    end
    -- Always repaint the newly uncovered stack after this CloseWidget event.
    -- This is deliberately deferred because UIManager removes us from the
    -- stack only after CloseWidget returns. It fixes stale toast pixels on
    -- Kindle when a status message expires while a MiuRead menu is open.
    repaint_uncovered(old_dimen)
    self._closing_with_refresh = false
end

local M = {blocked = false}
local active_toast = nil

function M.close()
    if active_toast then
        local toast=active_toast
        active_toast=nil
        pcall(toast._close,toast)
    end
    return true
end

function M.set_blocked(blocked)
    M.blocked=blocked==true
    if M.blocked then M.close() end
    return true
end

function M.show(opts)
    opts = opts or {}
    if M.blocked then return nil end
    if active_toast then
        pcall(active_toast._close, active_toast)
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
