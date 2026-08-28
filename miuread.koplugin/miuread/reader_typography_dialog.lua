local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local FaceFactory = require("miuread.thought_face_factory")
local Skin = require("miuread.reader_skin")
local Ui = require("miuread.ui_components")

local Screen = Device.screen
local live_dialog

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local TapBox = InputContainer:extend{
    dimen = nil,
    callback = nil,
    hold_callback = nil,
    enabled = true,
    _hold_handled = false,
    _miu_tap_block_until = 0,
}
function TapBox:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {
        TapSelect = {GestureRange:new{ges = "tap", range = self.dimen}},
        HoldSelect = {GestureRange:new{ges = "hold", range = self.dimen}},
        HoldReleaseSelect = {GestureRange:new{ges = "hold_release", range = self.dimen}},
    }
end
function TapBox:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function TapBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function TapBox:onTapSelect()
    if self._hold_handled then self._hold_handled = false; return true end
    if os.clock() < (tonumber(self._miu_tap_block_until) or 0) then return true end
    if self.enabled ~= false and self.callback then self.callback() end
    return true
end
function TapBox:onHoldSelect()
    if self.enabled == false or not self.hold_callback then return false end
    self._hold_handled = true
    return true
end
function TapBox:onHoldReleaseSelect()
    if self._hold_handled then
        self._hold_handled = false
        self._miu_tap_block_until = os.clock() + .20
        if self.enabled ~= false and self.hold_callback then self.hold_callback() end
        return true
    end
    return false
end
function TapBox:handleEvent(event) return InputContainer.handleEvent(self, event) end

local function resolved(value, fallback)
    if type(value) == "function" then
        local ok, result = pcall(value)
        if ok then return result end
        logger.warn("[MiuRead][TypographyDialog] provider failed", tostring(result))
        return fallback
    end
    if value == nil then return fallback end
    return value
end

local Dialog = InputContainer:extend{
    name = "miuread_reader_typography_dialog",
    _miuread_transient = true,
    _miuread_modal_surface = true,
    covers_fullscreen = true,
    stop_events_propagation = true,
    opts = nil,
    closed = false,
    pending_action = nil,
    rebuild_task = nil,
}
function Dialog:handleEvent(event) return InputContainer.handleEvent(self, event) end

function Dialog:_close(action)
    if action and not self.pending_action then self.pending_action = action end
    if self.closed then return true end
    self.closed = true
    UIManager:close(self)
    return true
end

function Dialog:_controls()
    local rows = resolved(self.opts and self.opts.controls, {})
    return type(rows) == "table" and rows or {}
end

function Dialog:_actions()
    local rows = resolved(self.opts and self.opts.actions, {})
    return type(rows) == "table" and rows or {}
end

function Dialog:_run(row, held)
    if not row or row.enabled == false then return true end
    local callback = held and row.hold_callback or row.callback
    if row.close == true then return self:_close(callback) end
    if callback then
        local ok, err = pcall(callback)
        if not ok then logger.warn("[MiuRead][TypographyDialog] action failed", tostring(err)) end
    end
    self:_schedule_rebuild(.09)
    return true
end

function Dialog:_schedule_rebuild(delay)
    if self.closed then return false end
    if self.rebuild_task then UIManager:unschedule(self.rebuild_task) end
    local task
    task=function()
        if self.rebuild_task~=task then return end
        self.rebuild_task=nil
        if not self.closed then self:_rebuild() end
    end
    self.rebuild_task=task
    UIManager:scheduleIn(math.max(.05,tonumber(delay) or .09),task)
    return true
end

function Dialog:_step_button(icon, w, h, callback, hold_callback)
    local tap = TapBox:new{
        dimen = Geom:new{w = w, h = h},
        enabled = callback ~= nil,
        callback = callback and function() self:_run({callback = callback}, false) end or nil,
        hold_callback = (hold_callback or callback) and function()
            local cb = hold_callback or callback
            -- A hold performs a larger step while staying on the same page.
            self:_run({callback = cb}, false)
        end or nil,
    }
    tap[1] = Skin.frame(w, h, {
        bordersize = Skin.line("thin"), radius = math.floor(h / 2),
        background = Blitbuffer.COLOR_WHITE, color = Blitbuffer.COLOR_DARK_GRAY,
    }, Ui.icon(icon, w, h, Skin.dp(19, 16, 25), {
        icon_key = icon, face = Skin.face("cfont", 18, 23, 15),
    }))
    return tap
end

function Dialog:_control_widget(row, width, height)
    local kind = tostring(row.kind or "select")
    local enabled = row.enabled ~= false
    local pad = Skin.dp(7, 6, 10)
    local inner_h = math.max(1, height - pad * 2)
    if kind == "step" then
        local label_w = math.max(Skin.dp(84, 72, 116), math.floor(width * .25))
        local button = math.min(inner_h, Skin.dp(42, 36, 56))
        local gap = Skin.dp(7, 5, 10)
        local value_w = math.max(1, width - label_w - button * 2 - gap * 3)
        local group = HorizontalGroup:new{align = "center"}
        group[#group + 1] = Ui.textbox(tostring(row.label or ""), label_w, inner_h,
            Skin.face("cfont", 10.8, 14.6, 9.2), {alignment = "left", bold = row.bold == true})
        group[#group + 1] = HorizontalSpan:new{width = gap}
        group[#group + 1] = self:_step_button("minus", button, button,
            row.on_decrease and function() row.on_decrease() end or nil,
            row.on_decrease_hold and function() row.on_decrease_hold() end or nil)
        group[#group + 1] = HorizontalSpan:new{width = gap}
        group[#group + 1] = Ui.textbox(tostring(resolved(row.value, "")), value_w, inner_h,
            Skin.face("cfont", 15.5, 20.5, 13.0), {alignment = "center", halign = "center", bold = true})
        group[#group + 1] = HorizontalSpan:new{width = gap}
        group[#group + 1] = self:_step_button("plus", button, button,
            row.on_increase and function() row.on_increase() end or nil,
            row.on_increase_hold and function() row.on_increase_hold() end or nil)
        return CenterContainer:new{dimen = Geom:new{w = width, h = height}, group}
    end

    local value = tostring(resolved(row.value, "") or "")
    local value_w = value ~= "" and math.max(Skin.dp(118, 94, 160), math.floor(width * .39)) or 0
    local arrow_w = row.close == true and Skin.dp(18, 15, 24) or 0
    local gap = Skin.dp(5, 4, 7)
    local label_w = math.max(1, width - pad * 2 - value_w - arrow_w - (value_w > 0 and gap or 0) - (arrow_w > 0 and gap or 0))
    local group = HorizontalGroup:new{align = "center"}
    group[#group + 1] = Ui.textbox(tostring(row.label or ""), label_w, inner_h,
        Skin.face("cfont", 10.8, 14.6, 9.2), {
            alignment = "left", bold = row.bold == true,
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        })
    if value_w > 0 then
        group[#group + 1] = HorizontalSpan:new{width = gap}
        group[#group + 1] = Ui.textbox(value, value_w, inner_h,
            Skin.face("cfont", 10.0, 13.4, 8.5), {
                alignment = "right", halign = "right", bold = row.value_bold == true,
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
            })
    end
    if arrow_w > 0 then
        group[#group + 1] = HorizontalSpan:new{width = gap}
        group[#group + 1] = Ui.icon("chevron-right", arrow_w, inner_h, Skin.dp(14, 12, 19), {})
    end
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height}, enabled = enabled,
        callback = function() self:_run(row, false) end,
        hold_callback = row.hold_callback and function() self:_run(row, true) end or nil,
    }
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, group}
    return tap
end

function Dialog:_preview_face(size)
    local name = resolved(self.opts and self.opts.preview_font, nil)
    local fallback = tostring(resolved(self.opts and self.opts.preview_fallback, "cfont") or "cfont")
    local ok, face = pcall(FaceFactory.getFace, FaceFactory, name, size, fallback)
    if ok and face then return face end
    return Skin.face("cfont", size, size, size)
end

function Dialog:_preview_widget(width, height)
    local label_h = Skin.dp(27, 22, 35)
    local inset = Skin.dp(11, 9, 16)
    local text_w = math.max(1, width - inset * 2)
    local text_h = math.max(1, height - label_h - Skin.dp(8, 6, 11))
    local logical_size = math.max(12, math.min(48, tonumber(resolved(self.opts and self.opts.preview_size, 22)) or 22))
    local line_height = tonumber(resolved(self.opts and self.opts.preview_line_height, .18)) or .18
    local text = tostring(resolved(self.opts and self.opts.preview_text,
        "这是一段预览文字，用来查看当前字体、字号和实际阅读效果。") or "")
    local layers = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    layers[#layers + 1] = OffsetContainer:new{x_off = 0, y_off = 0,
        LineWidget:new{background = Blitbuffer.COLOR_LIGHT_GRAY, dimen = Geom:new{w = width, h = Skin.line("thin")}}}
    layers[#layers + 1] = OffsetContainer:new{x_off = inset, y_off = Skin.dp(4, 3, 6),
        Ui.textbox(tostring(resolved(self.opts and self.opts.preview_label, "预览")), text_w, label_h,
            Skin.face("smallinfofont", 9.2, 12.3, 7.8), {alignment = "left", bold = true, fgcolor = Blitbuffer.COLOR_DARK_GRAY})}
    local preview_text = TextBoxWidget:new{
        text = text,
        face = self:_preview_face(logical_size),
        width = text_w,
        height = text_h,
        height_adjust = false,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        auto_para_direction = true,
        justified = false,
        line_height = line_height,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    layers[#layers + 1] = OffsetContainer:new{x_off = inset, y_off = label_h,
        Ui.align(preview_text, text_w, text_h, "left", "center")}
    return layers
end

function Dialog:_action_button(action, width, height)
    local enabled = action and action.enabled ~= false
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height}, enabled = enabled,
        callback = function() self:_run(action, false) end,
    }
    tap[1] = Skin.frame(width, height, {
        bordersize = Skin.line("thin"), radius = Skin.dp(6, 5, 9),
        background = Blitbuffer.COLOR_WHITE,
        color = action and action.primary == true and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    }, Ui.textbox(tostring(action and (action.label or action.text) or ""), width - Skin.dp(8, 6, 12), height,
        Skin.face("cfont", 9.8, 13.2, 8.3), {
            alignment = "center", halign = "center", bold = action and action.primary == true,
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }))
    return tap
end

function Dialog:_build_content()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local outer = Skin.dp(9, 7, 15)
    local pad = Skin.dp(12, 10, 18)
    local panel_w = sw - outer * 2
    local panel_h = sh - outer * 2
    local content_w = panel_w - pad * 2
    local header_h = Skin.dp(47, 40, 62)
    local subtitle = tostring(resolved(self.opts and self.opts.subtitle, "") or "")
    local subtitle_h = subtitle ~= "" and Skin.dp(28, 23, 36) or 0
    local controls = self:_controls()
    local row_h = Skin.dp(54, 46, 70)
    local action_h = Skin.dp(47, 40, 61)
    local action_gap = Skin.dp(8, 6, 12)
    local actions = self:_actions()
    local actions_h = #actions > 0 and action_h or 0
    local fixed = pad * 2 + header_h + subtitle_h + #controls * row_h + actions_h + Skin.dp(24, 18, 32)
    local preview_h = math.max(Skin.dp(150, 120, 205), panel_h - fixed)
    -- Keep preview around the lower third even on very tall screens.
    preview_h = math.min(preview_h, math.floor(panel_h * .36))
    local used_h = pad * 2 + header_h + subtitle_h + #controls * row_h + preview_h + actions_h + Skin.dp(18, 14, 24)
    if used_h > panel_h then
        row_h = math.max(Skin.dp(44, 38, 56), row_h - math.ceil((used_h - panel_h) / math.max(1, #controls)))
    end

    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.frame_dimen = Geom:new{x = outer, y = outer, w = panel_w, h = panel_h}
    local root = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    root[#root + 1] = OffsetContainer:new{x_off = outer, y_off = outer,
        Skin.paper(panel_w, panel_h, {accent = false, seed = 11}, Widget:new{dimen = Geom:new{w = 1, h = 1}})}

    local y = outer + pad
    local back_w = Skin.dp(44, 38, 58)
    local title_w = math.max(1, content_w - back_w * 2)
    local back = TapBox:new{dimen = Geom:new{w = back_w, h = header_h}, callback = function()
        self:_close(self.opts and self.opts.on_back or nil)
    end}
    back[1] = Ui.icon("back", back_w, header_h, Skin.dp(21, 18, 28), {})
    root[#root + 1] = OffsetContainer:new{x_off = outer + pad, y_off = y, back}
    root[#root + 1] = OffsetContainer:new{x_off = outer + pad + back_w, y_off = y,
        Ui.textbox(tostring(resolved(self.opts and self.opts.title, "字体与排版")), title_w, header_h,
            Skin.face("cfont", 13.2, 17.6, 11.2), {alignment = "center", halign = "center", bold = true})}
    local home_cb = self.opts and self.opts.on_home or nil
    if home_cb then
        local home = TapBox:new{dimen = Geom:new{w = back_w, h = header_h}, callback = function() self:_close(home_cb) end}
        home[1] = Ui.icon("home", back_w, header_h, Skin.dp(20, 17, 27), {})
        root[#root + 1] = OffsetContainer:new{x_off = outer + pad + back_w + title_w, y_off = y, home}
    end
    y = y + header_h
    if subtitle_h > 0 then
        root[#root + 1] = OffsetContainer:new{x_off = outer + pad, y_off = y,
            Ui.textbox(subtitle, content_w, subtitle_h, Skin.face("smallinfofont", 9.1, 12.1, 7.7), {
                alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_DARK_GRAY})}
        y = y + subtitle_h
    end

    for index, row in ipairs(controls) do
        if index > 1 then
            root[#root + 1] = OffsetContainer:new{x_off = outer + pad + Skin.dp(2, 2, 3), y_off = y,
                LineWidget:new{background = Blitbuffer.COLOR_LIGHT_GRAY, dimen = Geom:new{w = content_w - Skin.dp(4, 4, 6), h = Skin.line("thin")}}}
        end
        root[#root + 1] = OffsetContainer:new{x_off = outer + pad, y_off = y, self:_control_widget(row, content_w, row_h)}
        y = y + row_h
    end

    local bottom_reserve = actions_h + Skin.dp(14, 10, 20)
    local available_preview = math.max(Skin.dp(112, 92, 150), outer + panel_h - pad - bottom_reserve - y)
    preview_h = math.min(preview_h, available_preview)
    root[#root + 1] = OffsetContainer:new{x_off = outer + pad, y_off = y,
        self:_preview_widget(content_w, preview_h)}
    y = y + preview_h + Skin.dp(10, 8, 14)

    if #actions > 0 then
        local count = #actions
        local button_w = math.floor((content_w - action_gap * (count - 1)) / count)
        local group = HorizontalGroup:new{align = "center"}
        for index, action in ipairs(actions) do
            local actual = index == count and math.max(1, content_w - (button_w + action_gap) * (count - 1)) or button_w
            group[#group + 1] = self:_action_button(action, actual, action_h)
            if index < count then group[#group + 1] = HorizontalSpan:new{width = action_gap} end
        end
        root[#root + 1] = OffsetContainer:new{x_off = outer + pad, y_off = math.min(y, outer + panel_h - pad - action_h), group}
    end
    return root
end

function Dialog:_rebuild()
    if self.closed then return false end
    local old = self.frame_dimen and self.frame_dimen:copy() or nil
    self[1] = self:_build_content()
    local dirty = self.frame_dimen and self.frame_dimen:copy() or old
    UIManager:setDirty(self, function() return "ui", dirty end)
    return true
end

function Dialog:init()
    self[1] = self:_build_content()
end

function Dialog:onShow()
    if self.frame_dimen then
        UIManager:setDirty(self, function() return "ui", Skin.expand_region(self.frame_dimen) end)
    end
    return true
end

function Dialog:onCloseWidget()
    local old_region=self.frame_dimen and Skin.expand_region(self.frame_dimen) or nil
    if live_dialog == self then live_dialog = nil end
    if self.rebuild_task then
        UIManager:unschedule(self.rebuild_task)
        self.rebuild_task=nil
    end
    local action = self.pending_action
    self.pending_action = nil
    -- CloseWidget is dispatched before UIManager actually removes this dialog
    -- from the window stack. Reopen the parent (when requested) and repaint the
    -- newly uncovered area on the next tick so Kindle/E-Ink does not keep the
    -- old typography page as ghost pixels.
    UIManager:nextTick(function()
        if action then
            local ok,err=pcall(action)
            if not ok then logger.warn("[MiuRead][TypographyDialog] close action failed",tostring(err)) end
        end
        if old_region then UIManager:setDirty("all", "ui", old_region) end
    end)
    return true
end

local M = {}
function M.show(opts)
    if live_dialog and not live_dialog.closed then UIManager:close(live_dialog) end
    local dialog = Dialog:new{opts = opts or {}}
    live_dialog = dialog
    UIManager:show(dialog)
    return dialog
end
function M.close()
    if live_dialog and not live_dialog.closed then return live_dialog:_close() end
    return false
end
return M
