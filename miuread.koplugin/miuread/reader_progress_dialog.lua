local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
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
function TapBox:onTapSelect(_, ges)
    if self.enabled ~= false and self.callback then self.callback(ges) end
    return true
end
function TapBox:handleEvent(event)
    return InputContainer.handleEvent(self, event)
end

local ProgressTap = TapBox:extend{}
function ProgressTap:onTapSelect(_, ges)
    local pos = ges and ges.pos
    if not pos then return true end
    local ratio = (pos.x - self.dimen.x) / math.max(1, self.dimen.w)
    ratio = math.max(0, math.min(1, ratio))
    if self.callback then self.callback(ratio * 100) end
    return true
end

local Dialog = InputContainer:extend{
    name = "miuread_reader_progress_dialog",
    _miuread_transient = true,
    _miuread_modal_surface = true,
    covers_fullscreen = true,
    stop_events_propagation = true,
    percent = 0,
    whole_percent = nil,
    chapter_percent = nil,
    whole_percent_quality = nil,
    chapter_percent_quality = nil,
    progress_scope = "document",
    on_goto_percent = nil,
    on_adjust = nil,
    on_jump = nil,
    on_prev_chapter = nil,
    on_next_chapter = nil,
    on_back = nil,
    on_home = nil,
    closed = false,
    pending_action = nil,
}

function Dialog:handleEvent(event)
    return InputContainer.handleEvent(self, event)
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

function Dialog:_button(label, width, height, callback, primary)
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = callback ~= nil,
        callback = function() self:_close(callback) end,
    }
    tap[1] = Skin.frame(width, height, {
        bordersize = primary and Skin.line("thick") or Skin.line("thin"),
        radius = Skin.radius(6, 5, 10),
        background = Blitbuffer.COLOR_WHITE,
        color = callback and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_GRAY,
    }, Ui.textbox(tostring(label or ""), width - Skin.dp(10, 8, 15),
        height - Skin.dp(4, 2, 6), Skin.face("cfont", 11.4, 15.2, 9.8), {
            bold = primary == true, alignment = "center", halign = "center",
            fgcolor = callback and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }))
    return tap
end

function Dialog:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local portrait = sw < sh
    local outer_margin = Skin.dp(10, 8, 18)
    local top_inset = Skin.dp(3, 2, 5)
    local pad = Skin.dp(11, 9, 17)
    local gap = Skin.dp(8, 6, 11)
    local panel_w = sw - outer_margin * 2
    local content_w = panel_w - pad * 2
    local header_h = math.max(Skin.dp(40, 34, 53), math.floor(sh * .04))
    local value_h = math.max(Skin.dp(58, 48, 74), math.floor(sh * (portrait and .055 or .078)))
    local value_track_gap = Skin.dp(8, 6, 12)
    local track_h = math.max(Skin.dp(24, 20, 34), math.floor(sh * (portrait and .024 or .035)))
    local progress_h = value_h + value_track_gap + track_h
    local small_h = math.max(Skin.dp(42, 36, 55), math.floor(sh * (portrait and .04 or .058)))
    local wide_h = math.max(Skin.dp(45, 39, 58), math.floor(sh * (portrait and .043 or .062)))
    local handle_h = Skin.dp(18, 15, 25)
    local content_h = header_h + progress_h + gap + small_h + gap + wide_h + gap + wide_h + handle_h
    self.panel_h = math.min(sh - top_inset - math.max(28, math.floor(sh * .052)), pad * 2 + content_h)
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.frame_dimen = Geom:new{x = outer_margin, y = top_inset, w = panel_w, h = self.panel_h}
    self.ges_events = {
        TapDismiss = {GestureRange:new{ges = "tap", range = self.dimen}},
        SwipeDismiss = {GestureRange:new{ges = "swipe", range = self.dimen}},
    }
    if Device:hasKeys() and Device.input and Device.input.group and Device.input.group.Back then
        self.key_events = {Close = {{Device.input.group.Back}}}
    end

    local root = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin,
        y_off = top_inset,
        Skin.paper(panel_w, self.panel_h, {accent = false, seed = 9}, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }

    local y = top_inset + pad
    local back_w = Skin.dp(44, 38, 58)
    local title_w = math.max(1, content_w - back_w * 2)
    local back_tap = TapBox:new{
        dimen = Geom:new{w = back_w, h = header_h},
        callback = function() self:_close(self.on_back) end,
    }
    back_tap[1] = Ui.icon("back", back_w, header_h, Skin.dp(21, 18, 28), {
        face = Skin.face("cfont", 21, 26, 18),
    })
    local home_tap = TapBox:new{
        dimen = Geom:new{w = back_w, h = header_h},
        enabled = type(self.on_home) == "function",
        callback = function() self:_close(self.on_home) end,
    }
    home_tap[1] = Ui.icon("home", back_w, header_h, Skin.dp(21, 18, 28), {
        face = Skin.face("cfont", 15.8, 20.8, 13.2),
        fgcolor = type(self.on_home) == "function" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
    local header = HorizontalGroup:new{
        align = "center",
        back_tap,
        Ui.textbox("当前进度", title_w, header_h, Skin.face("cfont", 16.2, 20.8, 13.6), {
            bold = true, alignment = "center", halign = "center",
        }),
        home_tap,
    }
    root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, header}
    y = y + header_h

    local function pct_text(value,quality)
        value=math.max(0,math.min(100,tonumber(value) or 0))
        quality=tostring(quality or "")
        if quality:match("^exact") or quality:match("^precise") then
            return string.format("%.2f%%",value)
        end
        return "≈"..tostring(math.floor(value+.5)).."%"
    end
    local document_percent=math.max(0,math.min(100,tonumber(self.percent) or 0))
    local whole_percent=tonumber(self.whole_percent)
    local chapter_percent=tonumber(self.chapter_percent)
    local whole_quality=tostring(self.whole_percent_quality or "")
    local chapter_quality=tostring(self.chapter_percent_quality or "")
    local scope=tostring(self.progress_scope or "document")
    local primary,secondary
    if scope=="chapter" then
        primary=whole_percent~=nil and ("整书进度  "..pct_text(whole_percent,whole_quality)) or "整书进度  暂无法换算"
        secondary="本章位置  "..pct_text(chapter_percent~=nil and chapter_percent or document_percent,
            chapter_percent~=nil and chapter_quality or "estimated_document_ratio")
    elseif scope=="range" then
        primary=whole_percent~=nil and ("整书进度  "..pct_text(whole_percent,whole_quality)) or "整书进度  暂无法换算"
        local chapter=chapter_percent~=nil and ("本章 "..pct_text(chapter_percent,chapter_quality).."  ·  ") or ""
        secondary=chapter.."章节版位置 "..pct_text(document_percent,"estimated_document_ratio")
    elseif scope=="whole" then
        primary="整书进度  "..pct_text(whole_percent~=nil and whole_percent or document_percent,
            whole_percent~=nil and whole_quality or "estimated_document_ratio")
        secondary=chapter_percent~=nil and ("本章位置  "..pct_text(chapter_percent,chapter_quality)) or ""
    else
        primary="当前文档  "..pct_text(document_percent,"estimated_document_ratio")
        secondary=""
    end
    local primary_h=math.floor(value_h*.58)
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + pad,
        y_off = y,
        Ui.textbox(primary, content_w, primary_h, Skin.face("cfont", 18.5, 24, 15.5), {
            bold = true, alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
        }),
    }
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + pad,
        y_off = y + primary_h,
        Ui.textbox(secondary, content_w, math.max(1,value_h-primary_h), Skin.face("cfont", 11.4, 15.0, 9.6), {
            alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }),
    }

    local bar_w = math.max(1, content_w - math.floor(content_w * .04))
    local bar_h = math.max(2, Skin.line("thick"))
    local pct = math.max(0, math.min(100, tonumber(self.percent) or 0))
    local filled = math.max(1, math.floor(bar_w * pct / 100))
    local marker = Skin.dp(13, 10, 18)
    local bar_x = outer_margin + pad + math.floor((content_w - bar_w) / 2)
    local track_y = y + value_h + value_track_gap
    local bar_y = track_y + math.floor((track_h - bar_h) / 2)
    root[#root + 1] = OffsetContainer:new{x_off = bar_x, y_off = bar_y, LineWidget:new{
        background = Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{w = bar_w, h = bar_h},
    }}
    root[#root + 1] = OffsetContainer:new{x_off = bar_x, y_off = bar_y, LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{w = math.min(bar_w, filled), h = bar_h},
    }}
    root[#root + 1] = OffsetContainer:new{
        x_off = bar_x + math.max(0, math.min(bar_w - marker, filled - math.floor(marker / 2))),
        y_off = track_y + math.floor((track_h - marker) / 2),
        Skin.frame(marker, marker, {
            bordersize = 0,
            radius = math.floor(marker / 2),
            background = Blitbuffer.COLOR_BLACK,
            color = Blitbuffer.COLOR_BLACK,
        }, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }
    local progress_tap = ProgressTap:new{
        dimen = Geom:new{w = bar_w, h = value_track_gap + track_h},
        callback = function(target)
            self:_close(function() if self.on_goto_percent then self.on_goto_percent(target) end end)
        end,
    }
    progress_tap[1] = Widget:new{dimen = Geom:new{w = bar_w, h = value_track_gap + track_h}}
    root[#root + 1] = OffsetContainer:new{x_off = bar_x, y_off = y + value_h, progress_tap}
    y = y + progress_h + gap

    local small_gap = Skin.dp(6, 4, 9)
    local small_w = math.max(1, math.floor((content_w - small_gap * 3) / 4))
    local deltas = {-5, -1, 1, 5}
    local labels = {"−5%", "−1%", "+1%", "+5%"}
    for index, delta in ipairs(deltas) do
        local value = delta
        root[#root + 1] = OffsetContainer:new{
            x_off = outer_margin + pad + (index - 1) * (small_w + small_gap),
            y_off = y,
            self:_button(labels[index], small_w, small_h, function()
                if self.on_adjust then self.on_adjust(value) end
            end, false),
        }
    end
    y = y + small_h + gap

    local wide_gap = Skin.dp(8, 6, 12)
    local wide_w = math.max(1, math.floor((content_w - wide_gap) / 2))
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + pad,
        y_off = y,
        self:_button("上一章", wide_w, wide_h, self.on_prev_chapter, false),
    }
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + pad + wide_w + wide_gap,
        y_off = y,
        self:_button("下一章", wide_w, wide_h, self.on_next_chapter, false),
    }
    y = y + wide_h + gap

    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + pad,
        y_off = y,
        self:_button("输入位置", content_w, wide_h, self.on_jump, true),
    }

    local handle_w = Skin.dp(34, 28, 48)
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + math.floor((panel_w - handle_w) / 2),
        y_off = top_inset + self.panel_h - math.floor(handle_h * .55),
        LineWidget:new{
            background = Blitbuffer.COLOR_DARK_GRAY,
            dimen = Geom:new{w = handle_w, h = math.max(1, Skin.line("thin"))},
        },
    }
    self[1] = root
end

function Dialog:onTapDismiss(_, ges)
    local pos = ges and ges.pos
    if pos and (pos.y < self.frame_dimen.y or pos.y > self.frame_dimen.y + self.frame_dimen.h
        or pos.x < self.frame_dimen.x or pos.x > self.frame_dimen.x + self.frame_dimen.w) then
        return self:_close(nil, true)
    end
    return false
end
function Dialog:onSwipeDismiss(_, ges)
    if ges and ges.direction == "north" then return self:_close(nil, true) end
    return false
end
function Dialog:onClose() return self:_close(self.on_back) end
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
            if not ok then logger.warn("[MiuRead][ReaderProgressDialog] action failed", tostring(err)) end
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
    opts = opts or {}
    M.close()
    local ok, dialog = pcall(Dialog.new, Dialog, {
        percent = opts.percent,
        whole_percent = opts.whole_percent,
        chapter_percent = opts.chapter_percent,
        whole_percent_quality = opts.whole_percent_quality,
        chapter_percent_quality = opts.chapter_percent_quality,
        progress_scope = opts.progress_scope,
        on_goto_percent = opts.on_goto_percent,
        on_adjust = opts.on_adjust,
        on_jump = opts.on_jump,
        on_prev_chapter = opts.on_prev_chapter,
        on_next_chapter = opts.on_next_chapter,
        on_back = opts.on_back,
        on_home = opts.on_home,
    })
    if not ok or not dialog then
        logger.warn("[MiuRead][ReaderProgressDialog] build failed", tostring(dialog))
        return nil, tostring(dialog)
    end
    live_dialog = dialog
    UIManager:show(dialog, "ui", dialog.frame_dimen)
    return dialog
end
return M
