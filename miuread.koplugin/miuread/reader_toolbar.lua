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
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local Skin = require("miuread.reader_skin")
local Ui = require("miuread.ui_components")

local Screen = Device.screen
local live_toolbar

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

local function centered_text(text, width, height, face, options)
    options = options or {}
    return Ui.textbox(text, width, height, face, {
        bold = options.bold == true,
        alignment = "center",
        halign = "center",
        fgcolor = options.fgcolor or Blitbuffer.COLOR_BLACK,
    })
end

local function icon_box(icon, width, height, context, enabled, nominal, maximum, minimum)
    local size = math.min(width, height, Skin.dp(24, 21, 33))
    if context == "reader_recent" then size = math.min(width, height, Skin.dp(20, 17, 27)) end
    return Ui.icon(icon, width, height, size, {
        icon_key = icon,
        face = Skin.face("cfont", nominal or 18, maximum or 24, minimum or 15),
        fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
end

local function action_cell(entry, width, height, close_callback)
    local enabled = entry.enabled ~= false
    local inner_w = math.max(1, width - Skin.dp(8, 6, 12))
    local inner_h = math.max(1, height - Skin.dp(6, 4, 10))
    local icon = tostring(entry.icon_key or entry.icon or "")
    local detail = tostring(entry.detail or "")
    local block_gap = Skin.dp(2, 1, 4)
    local icon_h = math.max(Skin.dp(27, 23, 36), math.floor(inner_h * .34))
    local label_h = math.max(Skin.dp(19, 16, 25), math.floor(inner_h * .25))
    local detail_h = math.max(Skin.dp(15, 13, 20), math.floor(inner_h * .18))

    local content = VerticalGroup:new{
        align = "center",
        icon_box(icon, inner_w, icon_h, "reader_quick", enabled, 18.2, 24.8, 15.2),
        VerticalSpan:new{height = block_gap},
        centered_text(tostring(entry.label or entry.text or ""), inner_w, label_h,
            Skin.face("cfont", 11.2, 15.8, 9.8), {
                bold = true,
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            }),
        VerticalSpan:new{height = block_gap},
        centered_text(detail, inner_w, detail_h, Skin.face("smallinfofont", 7.9, 10.9, 6.9), {
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }),
    }

    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = function() close_callback(entry.callback, entry.label or entry.text or entry.key or "功能") end,
    }
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, content}
    return tap
end

local function compact_button(entry, width, height, close_callback)
    local enabled = entry.enabled ~= false
    local pad = Skin.dp(6, 5, 9)
    local icon = tostring(entry.icon or "")
    local icon_w = icon ~= "" and Skin.dp(25, 21, 34) or 0
    local gap = icon_w > 0 and Skin.dp(3, 2, 5) or 0
    local label_w = math.max(1, width - pad * 2 - icon_w - gap)
    local inner_h = math.max(1, height - Skin.line("thin") * 2)
    local row = HorizontalGroup:new{align = "center"}
    if icon_w > 0 then
        row[#row + 1] = icon_box(icon, icon_w, inner_h, "reader_recent", enabled, 14.4, 19.8, 12.0)
        row[#row + 1] = HorizontalSpan:new{width = gap}
    end
    row[#row + 1] = Ui.textbox(tostring(entry.label or entry.text or ""), label_w, inner_h,
        Skin.face("smallinfofont", 9.2, 12.4, 8), {
            bold = entry.bold == true,
            alignment = icon_w > 0 and "left" or "center",
            halign = icon_w > 0 and "left" or "center",
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        })

    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = function() close_callback(entry.callback, entry.label or entry.text or entry.key or "最近功能") end,
    }
    tap[1] = Skin.frame(width, height, {
        bordersize = Skin.line("thin"),
        padding = pad,
        radius = Skin.radius(5, 4, 9),
        background = Blitbuffer.COLOR_WHITE,
        color = enabled and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_GRAY,
    }, row)
    return tap
end

local function action_grid(entries, width, cell_h, columns, close_callback)
    local rows = math.max(1, math.ceil(math.max(1, #entries) / columns))
    local cell_gap = Skin.dp(6, 4, 9)
    local height = rows * cell_h + math.max(0, rows - 1) * cell_gap
    local cell_w = math.max(1, math.floor((width - math.max(0, columns - 1) * cell_gap) / columns))
    local layers = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    for row_index = 1, rows - 1 do
        layers[#layers + 1] = OffsetContainer:new{
            x_off = math.floor(width * .06),
            y_off = row_index * cell_h + math.floor((row_index - .5) * cell_gap),
            Skin.divider(math.max(1, math.floor(width * .88)), Blitbuffer.COLOR_GRAY),
        }
    end
    for index, entry in ipairs(entries) do
        local row = math.floor((index - 1) / columns)
        local col = (index - 1) % columns
        local x = col * (cell_w + cell_gap)
        local actual_w = col == columns - 1 and (width - x) or cell_w
        layers[#layers + 1] = OffsetContainer:new{
            x_off = x,
            y_off = row * (cell_h + cell_gap),
            action_cell(entry, actual_w, cell_h, close_callback),
        }
    end
    return layers, height
end

local Toolbar = InputContainer:extend{
    name = "miuread_reader_toolbar",
    _miuread_transient = true,
    covers_fullscreen = true,
    stop_events_propagation = true,
    opts = nil,
    closed = false,
    pending_action = nil,
    action_locked = false,
}

function Toolbar:handleEvent(event)
    return InputContainer.handleEvent(self, event)
end

function Toolbar:_activate(action, label)
    if self.closed or self.action_locked then return true end
    -- The native ReaderUI menu handler already consumes the gesture that opens
    -- this toolbar. Do not block a later, valid tap with a fixed time window.
    self.action_locked = true
    logger.info("[MiuRead][ReaderToolbar] tapped", tostring(label or "unknown"))
    return self:_close(action)
end

function Toolbar:_activate_immediate(action, label)
    if self.closed or self.action_locked then return true end
    self.action_locked = true
    self.pending_action = nil
    logger.info("[MiuRead][ReaderToolbar] tapped", tostring(label or "unknown"))
    -- Navigation and device-lifecycle actions must start before this transient
    -- widget closes. Waiting for onCloseWidget can silently lose the action when
    -- another surface changes the window stack at the same time.
    local ok, err = xpcall(function()
        if type(action) == "function" then action() end
    end, debug.traceback)
    if not ok then logger.warn("[MiuRead][ReaderToolbar] action failed", tostring(err)) end
    if not self.closed then self:_close(nil, true) end
    return true
end

function Toolbar:_close(action, cancel_pending)
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

function Toolbar:init()
    self.opts = self.opts or {}
    self.action_locked = false
    self._swipe_armed = false -- 打开面板的同一次下滑仍会派发到面板，先禁用二次下滑
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local portrait = sw < sh
    local outer_margin = Skin.dp(10, 8, 18)
    local top_inset = Skin.dp(3, 2, 5)
    local pad = Skin.dp(11, 9, 17)
    local gap = Skin.dp(7, 5, 10)
    local buttons = type(self.opts.buttons) == "table" and self.opts.buttons or {}
    local recent = type(self.opts.recent_buttons) == "table" and self.opts.recent_buttons or {}
    local columns = math.max(2, math.min(3, tonumber(self.opts.columns) or 3))
    local title_h = math.max(Skin.dp(34, 30, 46), math.floor(sh * .036))
    local subtitle_h = tostring(self.opts.subtitle or "") ~= "" and math.max(Skin.dp(21, 18, 29), math.floor(sh * .022)) or 0
    local progress_h = self.opts.progress_percent ~= nil and Skin.dp(18, 14, 24) or 0
    local card_h = math.max(Skin.dp(62, 54, 86), math.floor(sh * (portrait and .061 or .088)))
    local recent_title_h = #recent > 0 and Skin.dp(23, 19, 30) or 0
    local recent_h = #recent > 0 and Skin.dp(39, 34, 50) or 0
    local footer_h = self.opts.footer_action and Skin.dp(43, 37, 54) or 0
    local handle_h = Skin.dp(18, 15, 25)
    local panel_w = sw - outer_margin * 2
    local content_w = panel_w - pad * 2
    local _, grid_h = action_grid(buttons, content_w, card_h, columns, function() end)

    local content_h = title_h + subtitle_h + progress_h + gap + grid_h
        + (recent_title_h > 0 and (gap + recent_title_h + recent_h) or 0)
        + (footer_h > 0 and (gap + footer_h) or 0)
        + handle_h
    self.panel_h = math.min(sh - top_inset - math.max(36, math.floor(sh * .075)), pad * 2 + content_h)
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.panel_dimen = Geom:new{x = outer_margin, y = top_inset, w = panel_w, h = self.panel_h}
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
        Skin.paper(panel_w, self.panel_h, {seed = 3, accent = false}, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }

    local y = top_inset + pad
    local side_w = Skin.dp(50, 44, 64)
    local title_w = math.max(1, content_w - side_w * 2)
    local close_tap = TapBox:new{
        dimen = Geom:new{w = side_w, h = title_h},
        callback = function() self:_activate(nil, "关闭面板") end,
    }
    close_tap[1] = Ui.icon("close", side_w, title_h, Skin.dp(21, 18, 28), {
        face = Skin.face("cfont", 17.5, 22.5, 14.8),
        fgcolor = Blitbuffer.COLOR_BLACK,
    })
    local home_action = self.opts and self.opts.on_home or nil
    local home_tap = TapBox:new{
        dimen = Geom:new{w = side_w, h = title_h},
        enabled = type(home_action) == "function",
        callback = function() self:_activate_immediate(home_action, "返回主页") end,
    }
    home_tap[1] = Ui.icon("home", side_w, title_h, Skin.dp(28, 24, 36), {
        face = Skin.face("cfont", 19.2, 25.2, 16.2),
        fgcolor = type(home_action) == "function" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + pad,
        y_off = y,
        HorizontalGroup:new{
            align = "center",
            close_tap,
            Ui.textbox(tostring(self.opts.title or "阅读快捷面板"), title_w, title_h,
                Skin.face("cfont", 16.8, 21.5, 14), {
                    bold = true, alignment = "center", halign = "center",
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }),
            home_tap,
        },
    }
    y = y + title_h

    if subtitle_h > 0 then
        root[#root + 1] = OffsetContainer:new{
            x_off = outer_margin + pad,
            y_off = y,
            Ui.textbox(tostring(self.opts.subtitle or ""), content_w, subtitle_h,
                Skin.face("smallinfofont", 8.8, 11.7, 7.6), {
                    alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
                }),
        }
        y = y + subtitle_h
    end

    if progress_h > 0 then
        local bar_h = math.max(1, Skin.line("thick"))
        local bar_w = math.max(1, content_w - math.floor(content_w * .08))
        local pct = math.max(0, math.min(100, tonumber(self.opts.progress_percent) or 0))
        local filled = math.max(1, math.floor(bar_w * pct / 100))
        local bar_x = outer_margin + pad + math.floor((content_w - bar_w) / 2)
        local bar_y = y + math.floor((progress_h - bar_h) / 2)
        root[#root + 1] = OffsetContainer:new{x_off = bar_x, y_off = bar_y, LineWidget:new{
            background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{w = bar_w, h = bar_h},
        }}
        root[#root + 1] = OffsetContainer:new{x_off = bar_x, y_off = bar_y, LineWidget:new{
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new{w = math.min(bar_w, filled), h = bar_h},
        }}
        local marker = Skin.dp(7, 5, 10)
        root[#root + 1] = OffsetContainer:new{
            x_off = bar_x + math.max(0, math.min(bar_w - marker, filled - math.floor(marker / 2))),
            y_off = bar_y - math.floor((marker - bar_h) / 2),
            Skin.frame(marker, marker, {
                bordersize = 0,
                radius = math.floor(marker / 2),
                background = Blitbuffer.COLOR_BLACK,
                color = Blitbuffer.COLOR_BLACK,
            }, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
        }
        y = y + progress_h
    end

    y = y + gap
    local grid, actual_grid_h = action_grid(buttons, content_w, card_h, columns, function(action, label) self:_activate(action, label) end)
    root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, grid}
    y = y + actual_grid_h

    if #recent > 0 then
        y = y + gap
        root[#root + 1] = OffsetContainer:new{
            x_off = outer_margin + pad,
            y_off = y,
            Ui.textbox(tostring(self.opts.recent_title or "最近使用"), content_w, recent_title_h,
                Skin.face("smallinfofont", 9.2, 12.2, 8), {
                    bold = true, alignment = "left", fgcolor = Blitbuffer.COLOR_BLACK,
                }),
        }
        y = y + recent_title_h
        local count = math.min(3, #recent)
        local recent_gap = Skin.dp(6, 4, 9)
        local max_recent_w = math.max(Skin.dp(112, 92, 150), math.floor(content_w * .31))
        local recent_w = math.min(max_recent_w, math.max(1, math.floor((content_w - recent_gap * 2) / 3)))
        for index = 1, count do
            root[#root + 1] = OffsetContainer:new{
                x_off = outer_margin + pad + (index - 1) * (recent_w + recent_gap),
                y_off = y,
                compact_button(recent[index], recent_w, recent_h, function(action, label) self:_activate(action, label) end),
            }
        end
        y = y + recent_h
    end

    if footer_h > 0 then
        y = y + gap
        local footer = self.opts.footer_action
        local footer_tap = TapBox:new{
            dimen = Geom:new{w = content_w, h = footer_h},
            enabled = footer.enabled ~= false,
            callback = function() self:_activate(footer.callback, footer.label or "全部阅读功能") end,
        }
        local footer_layers = OverlapGroup:new{dimen = Geom:new{w = content_w, h = footer_h}, allow_mirroring = false}
        footer_layers[#footer_layers + 1] = OffsetContainer:new{
            x_off = 0,
            y_off = 0,
            Skin.divider(content_w, Blitbuffer.COLOR_GRAY),
        }
        footer_layers[#footer_layers + 1] = Ui.textbox(
            tostring(footer.label or "进入阅读控制中心  ›"), content_w, footer_h,
            Skin.face("cfont", 10.1, 13.5, 8.7), {
                bold = true, alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
            })
        footer_tap[1] = footer_layers
        root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, footer_tap}
        y = y + footer_h
    end

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

function Toolbar:onTapDismiss(_, ges)
    local pos = ges and ges.pos
    if pos and (pos.y > self.panel_dimen.y + self.panel_dimen.h or pos.x < self.panel_dimen.x or pos.x > self.panel_dimen.x + self.panel_dimen.w) then
        return self:_close()
    end
    return false
end

function Toolbar:onSwipeDismiss(_, ges)
    if ges and ges.direction == "north" then return self:_close() end
    if ges and ges.direction == "south" and self._swipe_armed == true
        and type(self.opts.on_swipe_down) == "function" then
        -- 觅阅面板已打开时再次从顶部下滑：交给原生 KOReader 菜单。
        -- 限定在顶部条带内，避免占用面板下方区域的翻页下滑。
        local start = ges.start_pos or ges.pos
        local sh = Screen:getHeight()
        local in_top = start and start.y >= 0 and start.y <= math.floor(sh * 0.12)
        if in_top then
            local ok, err = xpcall(self.opts.on_swipe_down, debug.traceback)
            if not ok then logger.warn("[MiuRead][ReaderToolbar] on_swipe_down failed", tostring(err)) end
            self:_close(nil, true)
            return true
        end
    end
    return false
end

function Toolbar:onClose() return self:_close() end
function Toolbar:onShow()
    UIManager:setDirty(self, function() return "ui", Skin.expand_region(self.panel_dimen) end)
    -- 打开面板的那次下滑仍可能再次派发到本面板；短暂延迟后才启用
    -- "再次下滑打开原生 KOReader 菜单"，避免首次下滑就同时打开两个菜单。
    self._swipe_armed = false
    UIManager:scheduleIn(.3, function()
        if not self.closed then self._swipe_armed = true end
    end)
end
function Toolbar:onCloseWidget()
    local region = self.panel_dimen and Skin.expand_region(self.panel_dimen) or nil
    local action = self.pending_action
    self.pending_action = nil
    self.closed = true
    if live_toolbar == self then live_toolbar = nil end
    if region then UIManager:setDirty(nil, function() return "ui", region end) end
    if action then
        UIManager:scheduleIn(.04, function()
            local ok, err = pcall(action)
            if not ok then logger.warn("[MiuRead][ReaderToolbar] action failed", tostring(err)) end
        end)
    end
end

local M = {}
function M.close()
    if live_toolbar and not live_toolbar.closed then live_toolbar:_close(nil, true) end
    live_toolbar = nil
end
function M.show(opts)
    M.close()
    local ok, toolbar = pcall(Toolbar.new, Toolbar, {opts = opts or {}})
    if not ok or not toolbar then return nil, tostring(toolbar) end
    live_toolbar = toolbar
    UIManager:show(toolbar, "ui", toolbar.panel_dimen)
    return toolbar
end
return M
