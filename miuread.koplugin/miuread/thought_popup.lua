local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local function screen_ratios()
    local w, h = Screen:getWidth(), Screen:getHeight()
    if h >= w then return 0.88, 0.82 end
    return 0.84, 0.86
end

local function dirty_region(widget, dimen)
    if not dimen then return end
    UIManager:setDirty(widget, function()
        return "partial", dimen
    end)
end

local Popup = InputContainer:extend{
    html = nil,
    font_size = Screen:scaleBySize(22),
    width_ratio = nil,
    height_ratio = nil,
    css = "",
    dialog = nil,
    on_close_callback = nil,
    closing = false,
}

function Popup:init()
    self.html = tostring(self.html or "")
    if self.html == "" then self.html = "<p>没有想法内容</p>" end

    local auto_w, auto_h = screen_ratios()
    local width_ratio = math.max(0.68, math.min(0.92, tonumber(self.width_ratio) or auto_w))
    local height_ratio = math.max(0.56, math.min(0.90, tonumber(self.height_ratio) or auto_h))
    local margin = Screen:scaleBySize(18)
    self.width = math.min(math.floor(Screen:getWidth() * width_ratio), Screen:getWidth() - margin * 2)
    self.height = math.min(math.floor(Screen:getHeight() * height_ratio), Screen:getHeight() - margin * 2)
    self.popup_dimen = Geom:new{
        x = math.floor((Screen:getWidth() - self.width) / 2),
        y = math.floor((Screen:getHeight() - self.height) / 2),
        w = self.width,
        h = self.height,
    }
    self.dialog = self
    self.closing = false

    if Device:isTouchDevice() then
        self.ges_events = {
            TapPage = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{x=0, y=0, w=Screen:getWidth(), h=Screen:getHeight()},
                },
            },
        }
    end

    if Device:hasKeys() then
        local group = Device.input.group or {}
        self.key_events = { Close = { { group.Back } } }
        local previous = group.PgBack or group.PageBack or group.PageBackward or group.Left
        local following = group.PgFwd or group.PageForward or group.PageNext or group.Right
        if previous then self.key_events.ScrollUp = { { previous } } end
        if following then self.key_events.ScrollDown = { { following } } end
    end

    self:_build()
end

function Popup:_free_widgets()
    if self.htmlwidget then pcall(function() self.htmlwidget:free() end) end
    if self.close_button then pcall(function() self.close_button:free() end) end
    self.htmlwidget = nil
    self.close_button = nil
end

function Popup:_build()
    self:_free_widgets()

    local border = tonumber(Size.border.window) or 1
    local padding = tonumber(Size.padding.small) or Screen:scaleBySize(7)
    local close_size = math.max(Screen:scaleBySize(34), math.floor(self.font_size * 1.32))
    local close_inset = Screen:scaleBySize(3)
    local inner_w = self.width - padding * 2 - border * 2
    local inner_h = self.height - padding * 2 - border * 2

    self.htmlwidget = ScrollHtmlWidget:new{
        html_body = self.html,
        is_xhtml = true,
        css = self.css or "",
        default_font_size = self.font_size,
        width = inner_w,
        height = inner_h,
        scroll_bar_width = math.max(1, Screen:scaleBySize(4)),
        text_scroll_span = Screen:scaleBySize(7),
        dialog = self,
    }

    local body_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = border,
        margin = 0,
        padding = padding,
        self.htmlwidget,
    }

    -- Use a real KOReader Button instead of a painted TextBox. The previous
    -- implementation relied on a separately calculated hit box; on Kindle
    -- Voyage that tap could fall through to the card-wide page-turn handler.
    self.close_button = Button:new{
        text = "×",
        width = close_size,
        height = close_size,
        margin = 0,
        padding = 0,
        bordersize = 0,
        text_font_face = "cfont",
        text_font_size = math.max(19, math.floor(self.font_size * 1.02)),
        text_font_bold = true,
        show_parent = self,
        callback = function() self:_request_close() end,
    }
    self.close_button.overlap_offset = {
        self.width - close_size - border - close_inset,
        border + close_inset,
    }

    self.close_dimen = Geom:new{
        x = self.popup_dimen.x + self.width - close_size - border - close_inset,
        y = self.popup_dimen.y + border + close_inset,
        w = close_size,
        h = close_size,
    }

    self.container = OverlapGroup:new{
        dimen = Geom:new{w=self.width, h=self.height},
        allow_mirroring = false,
        body_frame,
        self.close_button,
    }

    -- The full-screen parent is only responsible for centering and input
    -- capture. All e-ink updates remain limited to popup_dimen.
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.container,
    }
end

function Popup:onShow()
    dirty_region(self, self.popup_dimen)
end

function Popup:onCloseWidget()
    local old_dimen = self.popup_dimen and self.popup_dimen:copy() or nil
    self.closing = true
    self:_free_widgets()
    if self.on_close_callback then
        local callback = self.on_close_callback
        self.on_close_callback = nil
        pcall(callback)
    end
    dirty_region(nil, old_dimen)
end

function Popup:_request_close()
    if self.closing then return true end
    self.closing = true
    UIManager:scheduleIn(0, function()
        pcall(function() UIManager:close(self) end)
    end)
    return true
end

function Popup:onClose() return self:_request_close() end

function Popup:onScrollDown()
    if self.closing or not self.htmlwidget then return true end
    self.htmlwidget:onScrollDown()
    return true
end

function Popup:onScrollUp()
    if self.closing or not self.htmlwidget then return true end
    self.htmlwidget:onScrollUp()
    return true
end

function Popup:onTapPage(_, ges)
    if self.closing then return true end
    local pos = ges and ges.pos
    if not pos then return true end

    -- The Button normally consumes this tap itself. Keep an absolute-screen
    -- fallback for older KOReader event ordering and for the first paint.
    local button_dimen = self.close_button and self.close_button.dimen
    if (button_dimen and not pos:notIntersectWith(button_dimen))
        or (self.close_dimen and not pos:notIntersectWith(self.close_dimen)) then
        return self:_request_close()
    end

    -- Tapping outside the visible card closes it without letting the event
    -- reach the underlying EPUB.
    if not self.popup_dimen or pos:notIntersectWith(self.popup_dimen) then
        return self:_request_close()
    end

    -- Comments are one continuous HTML document. A tap inside the card moves
    -- to the next naturally rendered page; hardware back/forward keys move in
    -- either direction.
    return self:onScrollDown()
end

local M = {}

function M.show(opts)
    opts = opts or {}
    return UIManager:show(Popup:new{
        html = opts.html,
        font_size = opts.font_size,
        width_ratio = opts.width_ratio,
        height_ratio = opts.height_ratio,
        css = opts.css or "",
        on_close_callback = opts.on_close,
    })
end

return M
