local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
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
local DialogTransition = require("miuread.dialog_transition")
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

local Dialog = InputContainer:extend{
    name = "miuread_reader_toc_dialog",
    _miuread_transient = true,
    _miuread_modal_surface = true,
    -- Captures full-screen input but paints only a partial frame.
    covers_fullscreen = false,
    stop_events_propagation = true,
    opts = nil,
    page = 1,
    closed = false,
    pending_action = nil,
}

function Dialog:handleEvent(event)
    return InputContainer.handleEvent(self, event)
end

function Dialog:_items()
    local items = self.opts and self.opts.items or {}
    if type(items) == "function" then
        local ok, result = pcall(items)
        if ok and type(result) == "table" then return result end
        if not ok then logger.warn("[MiuRead][ReaderTocDialog] items failed", tostring(result)) end
        return {}
    end
    return type(items) == "table" and items or {}
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

function Dialog:_row_widget(item, width, height)
    local current = item.current == true
    local depth = math.max(1, math.min(5, tonumber(item.depth) or 1))
    local pad = Skin.dp(8, 6, 11)
    local indent = (depth - 1) * Skin.dp(14, 10, 20)
    local page_text = tostring(item.page_label or item.page or "")
    local page_w = page_text ~= "" and Skin.dp(55, 44, 75) or 0
    local label_w = math.max(1, width - pad * 2 - indent - page_w)
    local layers = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    if current then
        -- The selected chapter uses one quiet, full-row background only.
        -- Previous builds also painted a black left marker and a bordered row,
        -- which looked like two stray vertical bars on e-ink screens.
        layers[#layers + 1] = Skin.frame(width, height, {
            bordersize = 0,
            padding = 0,
            radius = Skin.radius(4, 3, 7),
            background = Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
            color = Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
        }, Widget:new{dimen = Geom:new{w = 1, h = 1}})
    end

    local row = HorizontalGroup:new{align = "center"}
    if indent > 0 then row[#row + 1] = HorizontalSpan:new{width = indent} end
    row[#row + 1] = Ui.textbox(tostring(item.title or item.text or ""), label_w, height,
        Skin.face("cfont", current and 10.8 or 10.4, current and 14.8 or 14.2, 9), {
            bold = current, alignment = "left", fgcolor = Blitbuffer.COLOR_BLACK,
        })
    if page_w > 0 then
        row[#row + 1] = Ui.textbox(page_text, page_w, height,
            Skin.face("smallinfofont", 8.5, 11.2, 7.2), {
                bold = current, alignment = "right", halign = "right", fgcolor = Blitbuffer.COLOR_BLACK,
            })
    end
    layers[#layers + 1] = CenterContainer:new{dimen = Geom:new{w = width - pad * 2, h = height}, row}

    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = type(item.callback)=="function",
        callback = function() self:_close(item.callback) end,
    }
    tap[1] = layers
    return tap
end

function Dialog:_nav_button(label, width, height, enabled, callback)
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = callback,
    }
    tap[1] = Ui.textbox(label, width, height, Skin.face("cfont", 10.3, 13.8, 8.8), {
        bold = enabled, alignment = "center", halign = "center",
        fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
    })
    return tap
end

function Dialog:_build_content()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local outer_margin = Skin.dp(10, 8, 18)
    local top_inset = Skin.dp(3, 2, 5)
    local pad = Skin.dp(11, 9, 17)
    local gap = Skin.dp(6, 4, 9)
    local panel_w = sw - outer_margin * 2
    local content_w = panel_w - pad * 2
    local header_h = math.max(Skin.dp(40, 34, 53), math.floor(sh * .04))
    local row_h = math.max(Skin.dp(42, 36, 54), math.floor(sh * .039))
    local footer_h = Skin.dp(40, 34, 52)
    local handle_h = Skin.dp(18, 15, 25)
    local max_h = sh - top_inset - math.max(28, math.floor(sh * .052))
    local row_budget = max_h - pad * 2 - header_h - footer_h - handle_h - gap * 2
    local max_rows = math.max(1, math.min(10, math.floor(math.max(1, row_budget) / row_h)))
    -- On very short viewports one row still has to fit inside the frame.
    if max_rows == 1 then row_h = math.min(row_h, math.max(1, row_budget)) end
    local items = self:_items()
    -- Follow the current reading chapter once whenever the directory is opened.
    -- After that, manual directory paging is respected until the dialog closes.
    if self.opts and self.opts.auto_follow ~= false and not self._auto_follow_applied then
        for index, item in ipairs(items) do
            if item.current == true then
                self.page = math.max(1, math.ceil(index / max_rows))
                break
            end
        end
        self._auto_follow_applied = true
    end
    local total_pages = math.max(1, math.ceil(math.max(1, #items) / max_rows))
    self.page = math.max(1, math.min(total_pages, tonumber(self.page) or 1))
    local first = (self.page - 1) * max_rows + 1
    local last = math.min(#items, first + max_rows - 1)
    -- Keep every directory page at the same height. A shorter final page used
    -- to expose the lower part of the previous page after a partial refresh.
    local rows_h = max_rows * row_h
    self.panel_h = math.min(max_h, pad * 2 + header_h + gap + rows_h + gap + footer_h + handle_h)
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.frame_dimen = Geom:new{x = outer_margin, y = top_inset, w = panel_w, h = self.panel_h}

    local root = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin,
        y_off = top_inset,
        Skin.paper(panel_w, self.panel_h, {seed = 11, accent = false}, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }

    local y = top_inset + pad
    local side_w = Skin.dp(44, 38, 58)
    local title_w = math.max(1, content_w - side_w * 2)
    local back_tap = TapBox:new{
        dimen = Geom:new{w = side_w, h = header_h},
        callback = function() self:_close(self.opts and self.opts.on_back or nil) end,
    }
    back_tap[1] = Ui.icon("back", side_w, header_h, Skin.dp(21, 18, 28), {face = Skin.face("cfont", 21, 26, 18)})
    local home_action = self.opts and self.opts.on_home or nil
    local home_tap = TapBox:new{
        dimen = Geom:new{w = side_w, h = header_h},
        enabled = type(home_action) == "function",
        callback = function() self:_close(home_action) end,
    }
    home_tap[1] = Ui.icon("home", side_w, header_h, Skin.dp(21, 18, 28), {
        face = Skin.face("cfont", 15.8, 20.8, 13.2),
        fgcolor = type(home_action) == "function" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
    local header = HorizontalGroup:new{
        align = "center",
        back_tap,
        Ui.textbox(tostring(self.opts and self.opts.title or "目录"), title_w, header_h,
            Skin.face("cfont", 16.2, 20.8, 13.6), {bold = true, alignment = "center", halign = "center"}),
        home_tap,
    }
    root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, header}
    y = y + header_h + gap

    local list_layers = OverlapGroup:new{dimen = Geom:new{w = content_w, h = rows_h}, allow_mirroring = false}
    -- Do not draw a second full outline around the chapter list. Combined with
    -- per-row dividers it created the comb/spider-leg marks along the page
    -- numbers. The panel itself already provides the structural outline.
    if #items == 0 then
        list_layers[#list_layers + 1] = CenterContainer:new{dimen = Geom:new{w = content_w, h = rows_h}, TextBoxWidget:new{
            text = "当前书籍没有目录",
            face = Skin.face("smallinfofont", 10, 13, 8.6),
            width = content_w - Skin.dp(20, 16, 30),
            height = rows_h,
            height_adjust = false,
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_BLACK,
        }}
    else
        local local_index = 0
        for index = first, last do
            local_index = local_index + 1
            list_layers[#list_layers + 1] = OffsetContainer:new{
                x_off = 0,
                y_off = (local_index - 1) * row_h,
                self:_row_widget(items[index], content_w, row_h),
            }
        end
    end
    root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, list_layers}
    y = y + rows_h + gap

    local nav_w = math.floor(content_w * .28)
    local page_w = math.max(1, content_w - nav_w * 2)
    local prev = self.page > 1
    local next = self.page < total_pages
    local footer = HorizontalGroup:new{
        align = "center",
        self:_nav_button("‹  上一页", nav_w, footer_h, prev, function()
            if prev then self.page = self.page - 1; self:_rebuild() end
        end),
        Ui.textbox(string.format("第 %d / %d 页", self.page, total_pages), page_w, footer_h,
            Skin.face("smallinfofont", 9.4, 12.4, 8.1), {bold = true, alignment = "center", halign = "center"}),
        self:_nav_button("下一页  ›", nav_w, footer_h, next, function()
            if next then self.page = self.page + 1; self:_rebuild() end
        end),
    }
    root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, footer}

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
    self.page = tonumber(self.opts.page) or 1
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
    DialogTransition.after_close(region,action,"ReaderTocDialog")
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
        logger.warn("[MiuRead][ReaderTocDialog] build failed", tostring(dialog))
        return nil, tostring(dialog)
    end
    live_dialog = dialog
    UIManager:show(dialog, "ui", dialog.frame_dimen)
    return dialog
end
return M
