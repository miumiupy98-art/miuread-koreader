local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local TransientGuard = require("miuread.transient_guard")
local Skin = require("miuread.reader_skin")
local Ui = require("miuread.ui_components")

local Screen = Device.screen
local live_dialog

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local TapBox = InputContainer:extend{dimen = nil, callback = nil, enabled = true}
function TapBox:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {TapSelect = {GestureRange:new{ges = "tap", range = self.dimen}}}
end
function TapBox:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function TapBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function TapBox:onTapSelect()
    if self.enabled ~= false and self.callback then self.callback() end
    return true
end
function TapBox:handleEvent(event)
    return InputContainer.handleEvent(self, event)
end

local SliderBox = InputContainer:extend{
    dimen = nil,
    bar_w = 1,
    value_w = 1,
    value_gap = 0,
    min = 0,
    max = 100,
    value = 0,
    on_change = nil,
    owner = nil,
    last_refresh = 0,
    refresh_callback = nil,
    slide_dimen = nil,
}

function SliderBox:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.min = tonumber(self.min) or 0
    self.max = tonumber(self.max) or (self.min + 1)
    if self.max <= self.min then self.max = self.min + 1 end
    self.value = math.max(self.min, math.min(self.max, tonumber(self.value) or self.min))
    self.slide_dimen = Geom:new{x = 0, y = 0, w = math.max(1, self.bar_w), h = self.dimen.h}
    self.ges_events = {
        TapSlide = {GestureRange:new{ges = "tap", range = self.slide_dimen}},
        PanSlide = {GestureRange:new{ges = "pan", range = self.slide_dimen}},
    }
    self.value_text = TextWidget:new{
        text = tostring(math.floor(self.value + .5)),
        face = Skin.face("smallinfofont", 9.2, 12.4, 8),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    self.refresh_callback = function()
        if not self.owner or self.owner.closed then return end
        self.last_refresh = os.clock()
        UIManager:setDirty(self.owner, function()
            return "ui", Skin.expand_region(self.dimen)
        end)
    end
end

function SliderBox:getSize()
    return Geom:new{w = self.dimen.w, h = self.dimen.h}
end

function SliderBox:_ratio()
    return math.max(0, math.min(1, (self.value - self.min) / math.max(1, self.max - self.min)))
end

function SliderBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self.slide_dimen.x, self.slide_dimen.y = x, y
    local track_h = math.max(Skin.line("medium"), Skin.dp(4, 3, 6))
    local marker_w = Skin.dp(12, 10, 16)
    local bar_y = y + math.floor((self.dimen.h - track_h) / 2)
    local ratio = self:_ratio()
    local fill_w = math.max(track_h, math.floor(self.bar_w * ratio))
    local marker_x = x + math.floor((self.bar_w - marker_w) * ratio)

    bb:paintRect(x, bar_y, self.bar_w, track_h, Blitbuffer.COLOR_GRAY)
    bb:paintRect(x, bar_y, math.min(self.bar_w, fill_w), track_h, Blitbuffer.COLOR_BLACK)
    bb:paintRect(marker_x, y + math.floor((self.dimen.h - marker_w) / 2), marker_w, marker_w, Blitbuffer.COLOR_BLACK)

    local value_size = self.value_text:getSize()
    local value_x = x + self.bar_w + self.value_gap + math.floor((self.value_w - value_size.w) / 2)
    local value_y = y + math.floor((self.dimen.h - value_size.h) / 2)
    self.value_text:paintTo(bb, value_x, value_y)
end

function SliderBox:_request_refresh(force)
    if not self.owner or self.owner.closed then return end
    local interval = Screen.low_pan_rate and .10 or .03
    local elapsed = os.clock() - (tonumber(self.last_refresh) or 0)
    if force or elapsed >= interval then
        if self.refresh_callback then pcall(UIManager.unschedule, UIManager, self.refresh_callback) end
        self.refresh_callback()
    else
        if self.refresh_callback then
            pcall(UIManager.unschedule, UIManager, self.refresh_callback)
            UIManager:scheduleIn(math.max(.01, interval - elapsed), self.refresh_callback)
        end
    end
end

function SliderBox:_set_from_position(ges, force)
    local pos = ges and ges.pos
    if not pos then return false end
    local ratio = (pos.x - self.dimen.x) / math.max(1, self.bar_w)
    ratio = math.max(0, math.min(1, ratio))
    local target = math.floor(self.min + ratio * (self.max - self.min) + .5)
    if target == self.value then
        self:_request_refresh(force)
        return true
    end

    local accepted = true
    local actual = target
    if self.on_change then
        local ok, result = pcall(self.on_change, target, force and "commit" or "drag")
        if not ok then
            logger.warn("[MiuRead][ReaderFrontlightDialog] slider action failed", tostring(result))
            accepted = false
        elseif result == false then
            accepted = false
        elseif tonumber(result) then
            actual = tonumber(result)
        end
    end
    if accepted then
        self.value = math.max(self.min, math.min(self.max, actual))
        self.value_text:setText(tostring(math.floor(self.value + .5)))
        self:_request_refresh(force)
    end
    return true
end

function SliderBox:onTapSlide(_, ges) return self:_set_from_position(ges, true) end
function SliderBox:onPanSlide(_, ges) return self:_set_from_position(ges, false) end
function SliderBox:handleEvent(event) return InputContainer.handleEvent(self, event) end

local Dialog = InputContainer:extend{
    name = "miuread_reader_frontlight_dialog",
    _miuread_transient = true,
    _miuread_modal_surface = true,
    covers_fullscreen = true,
    stop_events_propagation = true,
    opts = nil,
    closed = false,
    pending_action = nil,
}

function Dialog:handleEvent(event)
    return InputContainer.handleEvent(self, event)
end

local function resolve(value, fallback)
    if type(value) == "function" then
        local ok, result = pcall(value)
        if ok then return result end
        logger.warn("[MiuRead][ReaderFrontlightDialog] resolver failed", tostring(result))
        return fallback
    end
    if value == nil then return fallback end
    return value
end

function Dialog:_setting(name)
    local setting = self.opts and self.opts[name] or nil
    setting = resolve(setting, nil)
    if type(setting) ~= "table" then return nil end
    local minimum = tonumber(resolve(setting.min, 0)) or 0
    local maximum = tonumber(resolve(setting.max, minimum + 1)) or (minimum + 1)
    if maximum <= minimum then maximum = minimum + 1 end
    local value = tonumber(resolve(setting.value, minimum)) or minimum
    value = math.max(minimum, math.min(maximum, value))
    return {
        label = tostring(resolve(setting.label, name == "warmth" and "色温" or "亮度")),
        value = value,
        min = minimum,
        max = maximum,
        on_decrease = setting.on_decrease,
        on_increase = setting.on_increase,
        on_set = setting.on_set,
    }
end

function Dialog:_close(action, cancel_pending)
    if cancel_pending then
        self.pending_action = nil
    elseif action and not self.pending_action then
        self.pending_action = action
    end
    if self.closed then return true end
    self.closed = true
    UIManager:close(self)
    return true
end

function Dialog:_run(action, rebuild)
    if not action then return true end
    local ok, err = pcall(action)
    if not ok then logger.warn("[MiuRead][ReaderFrontlightDialog] action failed", tostring(err)) end
    if rebuild ~= false then
        UIManager:scheduleIn(.04, function()
            if not self.closed then self:_rebuild() end
        end)
    end
    return true
end

function Dialog:_step_button(label, width, height, callback)
    local enabled = callback ~= nil
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = function() self:_run(callback, true) end,
    }
    tap[1] = Skin.frame(width, height, {
        bordersize = Skin.line("thin"),
        radius = Skin.radius(6, 5, 10),
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_DARK_GRAY,
    }, Ui.icon(label == "+" and "plus" or "minus",
        width - Skin.dp(8, 6, 12), height - Skin.dp(4, 2, 6), Skin.dp(22, 19, 30), {
            face = Skin.face("cfont", 19, 24, 16),
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }))
    return tap
end

function Dialog:_slider(setting, width, height)
    local label_h = math.max(Skin.dp(27, 23, 36), math.floor(height * .34))
    local control_h = height - label_h
    local side_w = Skin.dp(52, 45, 70)
    local value_w = Skin.dp(48, 40, 66)
    local gap = Skin.dp(7, 5, 10)
    local bar_w = math.max(1, width - side_w * 2 - value_w - gap * 3)
    local button_h = math.max(Skin.dp(43, 37, 57), math.floor(control_h * .82))

    local label_row = Ui.textbox(setting.label, width, label_h,
        Skin.face("cfont", 11.3, 15.2, 9.6), {bold = true, alignment = "left"})

    local slider = SliderBox:new{
        dimen = Geom:new{w = bar_w + gap + value_w, h = button_h},
        bar_w = bar_w,
        value_w = value_w,
        value_gap = gap,
        min = setting.min,
        max = setting.max,
        value = setting.value,
        owner = self,
        on_change = setting.on_set,
    }

    local controls = HorizontalGroup:new{
        align = "center",
        self:_step_button("−", side_w, button_h, setting.on_decrease),
        HorizontalSpan:new{width = gap},
        slider,
        HorizontalSpan:new{width = gap},
        self:_step_button("+", side_w, button_h, setting.on_increase),
    }

    return VerticalGroup:new{align = "left", label_row, controls}
end

function Dialog:_action_button(entry, width, height)
    entry = type(entry) == "table" and entry or {}
    local callback = entry.callback
    local enabled = resolve(entry.enabled, callback ~= nil) ~= false and callback ~= nil
    local selected = resolve(entry.selected, false) == true
    local label = tostring(resolve(entry.label, ""))
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = function() self:_run(callback, true) end,
    }
    tap[1] = Skin.frame(width, height, {
        bordersize = selected and Skin.line("medium") or Skin.line("thin"),
        radius = Skin.radius(6, 5, 10),
        background = Blitbuffer.COLOR_WHITE,
        color = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
    }, Ui.textbox(label, width - Skin.dp(10, 8, 14),
        height - Skin.dp(4, 2, 6), Skin.face("cfont", 10.4, 14, 8.9), {
            bold = true, alignment = "center", halign = "center",
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }))
    return tap
end

function Dialog:_header_toggle(width, height)
    local source = resolve(self.opts and self.opts.toggle, nil)
    source = type(source) == "table" and source or {}
    local callback = source.callback
    local enabled = resolve(source.enabled, callback ~= nil) ~= false and callback ~= nil
    local selected = resolve(source.selected, false) == true
    local label = tostring(resolve(source.label, "前光"))
    local value = tostring(resolve(source.value, ""))
    local text = value ~= "" and (label .. "：" .. value) or label
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = function() self:_run(callback, true) end,
    }
    tap[1] = Skin.frame(width, height, {
        bordersize = selected and Skin.line("medium") or Skin.line("thin"),
        radius = Skin.radius(7, 6, 11),
        background = Blitbuffer.COLOR_WHITE,
        color = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
    }, Ui.textbox(text, width - Skin.dp(8, 6, 12), height - Skin.dp(4, 2, 6),
        Skin.face("smallinfofont", 9.2, 12.2, 7.9), {
            bold = true, alignment = "center", halign = "center",
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }))
    return tap
end

function Dialog:_build_content()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local portrait = sw < sh
    local outer_margin = Skin.dp(10, 8, 18)
    local top_margin = Skin.dp(3, 2, 5)
    local pad = Skin.dp(12, 9, 18)
    local gap = Skin.dp(10, 7, 14)
    local panel_w = sw - outer_margin * 2
    local content_w = panel_w - pad * 2
    local header_h = math.max(Skin.dp(40, 34, 53), math.floor(sh * .04))
    local slider_h = math.max(Skin.dp(95, 82, 124), math.floor(sh * (portrait and .095 or .14)))
    local action_h = Skin.dp(44, 38, 58)
    local handle_h = Skin.dp(18, 15, 25)
    local brightness = self:_setting("brightness")
    local warmth = self:_setting("warmth")
    local setting_count = brightness and 1 or 0
    if warmth then setting_count = setting_count + 1 end
    setting_count = math.max(1, setting_count)

    local desired_h = pad * 2 + header_h + gap + slider_h * setting_count
        + gap * math.max(0, setting_count - 1) + gap + action_h + handle_h
    self.panel_h = math.min(sh - outer_margin * 2, desired_h)
    self._stable_panel_h = math.max(tonumber(self._stable_panel_h) or 0, self.panel_h)
    self.panel_h = self._stable_panel_h
    local placement = tostring(self.opts and self.opts.placement or "top")
    local panel_y = placement == "center" and math.max(outer_margin, math.floor((sh - self.panel_h) / 2)) or top_margin

    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.frame_dimen = Geom:new{x = outer_margin, y = panel_y, w = panel_w, h = self.panel_h}

    local root = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin,
        y_off = panel_y,
        Skin.paper(panel_w, self.panel_h, {accent = false, seed = 13}, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }

    local y = panel_y + pad
    local back_action = self.opts and self.opts.on_back or nil
    local back_w = type(back_action) == "function" and Skin.dp(42, 36, 56) or 0
    local close_w = Skin.dp(42, 36, 56)
    local toggle_w = math.max(Skin.dp(92, 78, 124), math.floor(content_w * .22))
    local header_gap = Skin.dp(5, 4, 8)
    local title_w = math.max(1, content_w - back_w - close_w - toggle_w - header_gap * 2)

    local back = TapBox:new{
        dimen = Geom:new{w = back_w, h = header_h},
        enabled = type(back_action) == "function",
        callback = function() self:_close(back_action) end,
    }
    if type(back_action) == "function" then
        back[1] = Ui.icon("back", back_w, header_h, Skin.dp(21, 18, 28), {
            face = Skin.face("cfont", 21, 26, 18),
        })
    else
        back[1] = Widget:new{dimen = Geom:new{w = back_w, h = header_h}}
    end

    local close = TapBox:new{
        dimen = Geom:new{w = close_w, h = header_h},
        callback = function() self:_close(nil, true) end,
    }
    close[1] = Ui.icon("close", close_w, header_h, Skin.dp(21, 18, 28), {
        face = Skin.face("cfont", 17.5, 22.5, 14.8),
    })

    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + pad,
        y_off = y,
        HorizontalGroup:new{
            align = "center",
            back,
            Ui.textbox(tostring(self.opts and self.opts.title or "前光"), title_w, header_h,
                Skin.face("cfont", 16.2, 20.8, 13.6), {
                    bold = true, alignment = "left", halign = "center",
                }),
            HorizontalSpan:new{width = header_gap},
            self:_header_toggle(toggle_w, header_h),
            HorizontalSpan:new{width = header_gap},
            close,
        },
    }
    y = y + header_h + gap

    local settings = {}
    if brightness then settings[#settings + 1] = brightness end
    if warmth then settings[#settings + 1] = warmth end
    if #settings == 0 then
        root[#root + 1] = OffsetContainer:new{
            x_off = outer_margin + pad,
            y_off = y,
            Ui.textbox("当前设备没有可调前光", content_w, slider_h,
                Skin.face("smallinfofont", 10, 13, 8.5), {
                    alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
                }),
        }
        y = y + slider_h
    else
        for index, setting in ipairs(settings) do
            local inner_pad = Skin.dp(10, 8, 14)
            local card = Skin.frame(content_w, slider_h, {
                bordersize = Skin.line("thin"),
                padding = inner_pad,
                radius = Skin.radius(7, 5, 11),
                background = Blitbuffer.COLOR_WHITE,
                color = Blitbuffer.COLOR_DARK_GRAY,
            }, self:_slider(setting, content_w - inner_pad * 2, slider_h - inner_pad * 2))
            root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, card}
            y = y + slider_h
            if index < #settings then y = y + gap end
        end
    end

    y = y + gap
    local actions = self.opts and self.opts.actions or {}
    local action_count = math.max(1, #actions)
    local action_gap = Skin.dp(7, 5, 10)
    local action_w = math.floor((content_w - action_gap * (action_count - 1)) / action_count)
    local action_row = HorizontalGroup:new{align = "center"}
    for index, entry in ipairs(actions) do
        action_row[#action_row + 1] = self:_action_button(entry, action_w, action_h)
        if index < #actions then action_row[#action_row + 1] = HorizontalSpan:new{width = action_gap} end
    end
    root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, action_row}

    local handle_w = Skin.dp(34, 28, 48)
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + math.floor((panel_w - handle_w) / 2),
        y_off = panel_y + self.panel_h - math.floor(handle_h * .55),
        LineWidget:new{
            background = Blitbuffer.COLOR_DARK_GRAY,
            dimen = Geom:new{w = handle_w, h = math.max(1, Skin.line("thin"))},
        },
    }
    self[1] = root
end

function Dialog:_rebuild()
    local old = self.frame_dimen and self.frame_dimen:copy() or nil
    self:_build_content()
    local dirty = self.frame_dimen
    if old then
        dirty = Geom:new{
            x = math.min(old.x, self.frame_dimen.x),
            y = math.min(old.y, self.frame_dimen.y),
            w = math.max(old.x + old.w, self.frame_dimen.x + self.frame_dimen.w) - math.min(old.x, self.frame_dimen.x),
            h = math.max(old.y + old.h, self.frame_dimen.y + self.frame_dimen.h) - math.min(old.y, self.frame_dimen.y),
        }
    end
    UIManager:setDirty(self, function() return "ui", Skin.expand_region(dirty) end)
end

function Dialog:init()
    self.opts = self.opts or {}
    self:_build_content()
    self.ges_events = {
        TapDismiss = {GestureRange:new{ges = "tap", range = self.dimen}},
        SwipeDismiss = {GestureRange:new{ges = "swipe", range = self.dimen}},
    }
    if Device:hasKeys() and Device.input and Device.input.group and Device.input.group.Back then
        self.key_events = {Close = {{Device.input.group.Back}}}
    end
end

function Dialog:onTapDismiss(_, ges)
    local pos = ges and ges.pos
    if pos and (pos.y < self.frame_dimen.y or pos.y > self.frame_dimen.y + self.frame_dimen.h
        or pos.x < self.frame_dimen.x or pos.x > self.frame_dimen.x + self.frame_dimen.w) then
        -- Outside taps dismiss the whole menu stack. Returning to the parent is
        -- reserved for the explicit back button and hardware Back key.
        return self:_close(nil, true)
    end
    return false
end
function Dialog:onSwipeDismiss(_, ges)
    if ges and ges.direction == "north" then return self:_close(nil, true) end
    return false
end
function Dialog:onClose()
    return self:_close(self.opts and self.opts.on_back or nil)
end
function Dialog:onShow()
    UIManager:setDirty(self, function() return "ui", Skin.expand_region(self.frame_dimen) end)
end
function Dialog:onCloseWidget()
    local region = self.frame_dimen and Skin.expand_region(self.frame_dimen) or nil
    local action = self.pending_action
    self.pending_action = nil
    self.closed = true
    if live_dialog == self then live_dialog = nil end
    if region then UIManager:setDirty(nil, function() return "ui", region end) end
    if action then
        UIManager:scheduleIn(.04, function()
            local ok, err = pcall(action)
            if not ok then logger.warn("[MiuRead][ReaderFrontlightDialog] deferred action failed", tostring(err)) end
        end)
    end
end

local M = {}
function M.close()
    if live_dialog and not live_dialog.closed then live_dialog:_close(nil, true) end
    live_dialog = nil
end
function M.show(opts)
    TransientGuard.close_all()
    M.close()
    local ok, dialog = pcall(Dialog.new, Dialog, {opts = opts or {}})
    if not ok or not dialog then
        logger.warn("[MiuRead][ReaderFrontlightDialog] build failed", tostring(dialog))
        return nil, tostring(dialog)
    end
    live_dialog = dialog
    UIManager:show(dialog, "ui", dialog.frame_dimen)
    return dialog
end
return M
