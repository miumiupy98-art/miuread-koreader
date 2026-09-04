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

local TapBox = InputContainer:extend{
    dimen = nil, callback = nil, hold_callback = nil, enabled = true,
    _hold_handled = false, _pending_hold_anchor = nil, _miu_tap_block_until = 0,
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
    if self._hold_handled then
        self._hold_handled = false
        return true
    end
    local now = os.clock()
    if now < (tonumber(self._miu_tap_block_until) or 0) then return true end
    self._miu_tap_block_until = now + .20
    if self.enabled ~= false and self.callback then
        self.callback(self.dimen and self.dimen:copy() or nil)
    end
    return true
end
function TapBox:onHoldSelect()
    if self.enabled == false or not self.hold_callback then return false end
    self._hold_handled = true
    self._pending_hold_anchor = self.dimen and self.dimen:copy() or nil
    return true
end
function TapBox:onHoldReleaseSelect()
    if self._hold_handled then
        local anchor = self._pending_hold_anchor
        self._hold_handled = false
        self._pending_hold_anchor = nil
        self._miu_tap_block_until = os.clock() + .20
        if self.enabled ~= false and self.hold_callback then self.hold_callback(anchor) end
        return true
    end
    return false
end
function TapBox:handleEvent(event) return InputContainer.handleEvent(self, event) end

local function resolved(value, fallback)
    if type(value) == "function" then
        local ok, result = pcall(value)
        if ok then return result end
        logger.warn("[MiuRead][ReaderListDialog] provider failed", tostring(result))
        return fallback
    end
    if value == nil then return fallback end
    return value
end

local Dialog = InputContainer:extend{
    name = "miuread_reader_list_dialog",
    _miuread_transient = true,
    _miuread_modal_surface = true,
    -- Full-screen input layer, but only the centered dialog frame is opaque.
    -- Keeping this false lets UIManager repaint HomeView beneath us and then
    -- paint this dialog on top instead of treating transparent margins as opaque.
    covers_fullscreen = false,
    stop_events_propagation = true,
    opts = nil,
    closed = false,
    pending_action = nil,
    selected_key = nil,
    page = 1,
    expanded_index = nil,
    stack = nil,
    _session_panel_h = nil,
}

function Dialog:handleEvent(event) return InputContainer.handleEvent(self, event) end

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

function Dialog:_push(title, items, subtitle)
    self.stack = type(self.stack) == "table" and self.stack or {}
    self.stack[#self.stack + 1] = {
        opts = self.opts, page = self.page, selected_key = self.selected_key,
        expanded_index = self.expanded_index,
    }
    local parent = self.opts or {}
    self.opts = {
        title = tostring(title or parent.title or "觅阅"),
        subtitle = subtitle or "",
        items = items,
        page_size = parent.page_size,
        empty_text = parent.empty_text,
        on_close = parent.on_close,
        on_back = parent.on_back,
    }
    self.page = 1
    self.selected_key = ""
    self.expanded_index = nil
    self:_rebuild()
    return true
end

function Dialog:_pop()
    if type(self.stack) == "table" and #self.stack > 0 then
        local frame = table.remove(self.stack)
        self.opts = frame.opts or self.opts
        self.page = tonumber(frame.page) or 1
        self.selected_key = tostring(frame.selected_key or "")
        self.expanded_index = frame.expanded_index
        self:_rebuild()
        return true
    end
    local back = self.opts and self.opts.on_back or nil
    return self:_close(back)
end

function Dialog:_categories()
    local categories = resolved(self.opts and self.opts.categories, nil)
    if type(categories) == "table" and #categories > 0 then return categories end
    return {{key = "all", label = "", items = resolved(self.opts and self.opts.items, {})}}
end

function Dialog:_selected_category()
    local categories = self:_categories()
    for _, category in ipairs(categories) do
        if tostring(category.key or "") == tostring(self.selected_key or "") then return category end
    end
    return categories[1]
end

function Dialog:_items(category)
    local items = resolved(category and (category.items or category.rows), {})
    return type(items) == "table" and items or {}
end

function Dialog:_page_size()
    local requested = tonumber(self.opts and self.opts.page_size)
    if requested and requested >= 2 then return math.floor(requested) end
    local _, sh = Screen:getWidth(), Screen:getHeight()
    return sh > 1100 and 7 or 6
end

function Dialog:_inline_actions(item)
    local actions = resolved(item and item.inline_actions, {})
    return type(actions) == "table" and actions or {}
end

function Dialog:_run_item(item, index)
    if not item or item.enabled == false then return true end
    if type(item.children_provider) == "function" or type(item.children) == "table" then
        local children=item.children
        if type(item.children_provider)=="function" then
            local provider=item.children_provider
            children=function()
                local ok,value=xpcall(provider,debug.traceback)
                if not ok then
                    logger.warn("[MiuRead][ReaderListDialog] child provider failed",tostring(value))
                    return {}
                end
                return type(value)=="table" and value or {}
            end
        end
        return self:_push(item.child_title or item.label or item.text or "觅阅",children,item.child_subtitle or "")
    end
    local inline_actions = self:_inline_actions(item)
    if #inline_actions > 0 then
        self.expanded_index = self.expanded_index == index and nil or index
        self:_rebuild()
        return true
    end
    if item.keep_open == true then
        if item.callback then
            local ok, err = pcall(item.callback)
            if not ok then logger.warn("[MiuRead][ReaderListDialog] action failed", tostring(err)) end
        end
        UIManager:scheduleIn(.04, function()
            if not self.closed then self:_rebuild() end
        end)
        return true
    end
    return self:_close(item.callback)
end

function Dialog:_row_widget(item, width, height, index)
    local enabled = item.enabled ~= false
    local pad = Skin.dp(7, 6, 10)
    local icon_w = tostring(item.icon or "") ~= "" and Skin.dp(31, 27, 41) or 0
    local value = tostring(item.value or item.post_text or "")
    local value_w = value ~= "" and math.max(Skin.dp(92, 76, 126), math.floor(width * .30)) or 0
    local inline_actions = self:_inline_actions(item)
    local arrow = item.arrow ~= false and ((#inline_actions > 0) or item.children_provider ~= nil or item.children ~= nil
        or (item.callback ~= nil and item.keep_open ~= true))
    local arrow_w = arrow and Skin.dp(15, 13, 20) or 0
    local gap = Skin.dp(5, 4, 7)
    local text_w = math.max(1, width - pad * 2 - icon_w - value_w - arrow_w
        - gap * ((icon_w > 0 and 1 or 0) + (value_w > 0 and 1 or 0) + (arrow_w > 0 and 1 or 0)))
    local detail = tostring(item.detail or "")
    local label_h = detail ~= "" and math.floor(height * .52) or height
    local detail_h = math.max(1, height - label_h)

    local text_layers = OverlapGroup:new{dimen = Geom:new{w = text_w, h = height}, allow_mirroring = false}
    text_layers[#text_layers + 1] = OffsetContainer:new{
        x_off = 0, y_off = 0,
        Ui.textbox(tostring(item.label or item.text or ""), text_w, label_h,
            Skin.face("cfont", detail ~= "" and 11.1 or 11.6, detail ~= "" and 14.9 or 15.6, detail ~= "" and 9.4 or 9.9), {
                bold = item.bold == true or item.checked == true,
                alignment = "left",
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            }),
    }
    if detail ~= "" then
        text_layers[#text_layers + 1] = OffsetContainer:new{
            x_off = 0, y_off = label_h,
            Ui.textbox(detail, text_w, detail_h, Skin.face("smallinfofont", 9.0, 11.9, 7.7), {
                alignment = "left",
                fgcolor = enabled and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_GRAY,
            }),
        }
    end

    local row = HorizontalGroup:new{align = "center"}
    if icon_w > 0 then
        row[#row + 1] = Ui.icon(tostring(item.icon), icon_w, height - pad * 2, Skin.dp(19, 16, 25), {
            icon_key = tostring(item.icon),
            face = Skin.face("cfont", 14.5, 19.5, 12.2),
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        })
        row[#row + 1] = HorizontalSpan:new{width = gap}
    end
    row[#row + 1] = text_layers
    if value_w > 0 then
        row[#row + 1] = HorizontalSpan:new{width = gap}
        row[#row + 1] = Ui.textbox(value, value_w, height - pad * 2, Skin.face("cfont", 10.5, 13.9, 8.9), {
            bold = item.value_bold == true or item.checked == true,
            alignment = "right", halign = "right",
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        })
    end
    if arrow_w > 0 then
        row[#row + 1] = HorizontalSpan:new{width = gap}
        row[#row + 1] = Ui.icon("chevron-right", arrow_w, height - pad * 2, Skin.dp(14, 12, 19), {
            face = Skin.face("cfont", 12.8, 17.2, 10.8),
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        })
    end

    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height}, enabled = enabled,
        callback = function() self:_run_item(item, index) end,
        hold_callback = (#inline_actions == 0 and item.hold_callback) and function(anchor)
            return self:_close(function() item.hold_callback(anchor) end)
        end or nil,
    }
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, row}
    return tap
end

function Dialog:_inline_actions_widget(item, width, height)
    local actions = self:_inline_actions(item)
    local count = math.max(1, #actions)
    local gap = Skin.dp(5, 4, 7)
    local button_w = math.max(1, math.floor((width - gap * (count - 1)) / count))
    local group = HorizontalGroup:new{align = "center"}
    for index, action in ipairs(actions) do
        local actual_w = index == count and math.max(1, width - (button_w + gap) * (count - 1)) or button_w
        local label = tostring(action.label or action.text or "操作")
        local enabled = action.enabled ~= false
        local tap = TapBox:new{
            dimen = Geom:new{w = actual_w, h = height},
            enabled = enabled,
            callback = function()
                if action.close == true then
                    return self:_close(action.callback)
                end
                if type(action.callback) == "function" then
                    local ok, err = pcall(action.callback)
                    if not ok then
                        logger.warn("[MiuRead][ReaderListDialog] inline action failed", tostring(err))
                    end
                end
                UIManager:scheduleIn(.05, function()
                    if not self.closed then self:_rebuild() end
                end)
                return true
            end,
        }
        tap[1] = Skin.frame(actual_w, height, {
            bordersize = Skin.line("thin"), padding = Skin.dp(2, 1, 3), radius = Skin.dp(5, 4, 7),
            background = Blitbuffer.COLOR_WHITE,
            color = action.danger == true and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_GRAY,
        }, Ui.textbox(label, math.max(1, actual_w - Skin.dp(6, 4, 8)), height - Skin.dp(4, 2, 6),
            Skin.face("smallinfofont", count >= 4 and 8.6 or 9.3, count >= 4 and 11.4 or 12.3, count >= 4 and 7.2 or 7.9), {
                bold = action.danger == true or action.bold == true,
                alignment = "center", halign = "center",
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            }))
        group[#group + 1] = tap
        if index < count then group[#group + 1] = HorizontalSpan:new{width = gap} end
    end
    return group
end

function Dialog:_tab_widget(category, width, height, selected)
    local key = tostring(category.key or "")
    local layers = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    layers[#layers + 1] = Ui.textbox(tostring(category.label or key), width, height,
        Skin.face("cfont", 11.0, 14.8, 9.4), {
            bold = selected, alignment = "center", halign = "center",
            fgcolor = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        })
    if selected then
        local line_w = math.max(Skin.dp(26, 22, 38), math.floor(width * .36))
        layers[#layers + 1] = OffsetContainer:new{
            x_off = math.floor((width - line_w) / 2),
            y_off = height - Skin.line("thick"),
            LineWidget:new{background = Blitbuffer.COLOR_BLACK, dimen = Geom:new{w = line_w, h = Skin.line("thick")}},
        }
    end
    local tap = TapBox:new{dimen = Geom:new{w = width, h = height}, callback = function()
        if self.selected_key ~= key then
            self.selected_key = key
            self.page = 1
            self.expanded_index = nil
            self:_rebuild()
        end
    end}
    tap[1] = layers
    return tap
end

function Dialog:_pager_button(icon, width, height, callback, enabled)
    local tap = TapBox:new{dimen = Geom:new{w = width, h = height}, enabled = enabled ~= false, callback = callback}
    tap[1] = Ui.icon(icon, width, height, Skin.dp(19, 16, 25), {
        icon_key = icon,
        face = Skin.face("cfont", 17, 22, 14),
        fgcolor = enabled ~= false and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
    return tap
end

function Dialog:_build_content()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local portrait = sw < sh
    local pad = Skin.dp(13, 10, 19)
    local panel_ratio = portrait and .82 or .72
    local panel_w = math.max(Skin.dp(330, 300, 430), math.floor(sw * panel_ratio))
    panel_w = math.min(panel_w, sw - Skin.dp(36, 28, 54))
    local content_w = panel_w - pad * 2
    local header_h = math.max(Skin.dp(42, 36, 56), math.floor(sh * .041))
    local subtitle = tostring(resolved(self.opts and self.opts.subtitle, "") or "")
    local subtitle_h = subtitle ~= "" and Skin.dp(27, 23, 36) or 0
    local categories = self:_categories()
    local selected = self:_selected_category()
    self.selected_key = tostring(selected and selected.key or "all")
    local tab_h = #categories > 1 and math.max(Skin.dp(37, 32, 49), math.floor(sh * .036)) or 0
    local pager_h_default = Skin.dp(34, 29, 45)
    local row_h = math.max(Skin.dp(61, 52, 82), math.floor(sh * (portrait and .057 or .080)))
    local action_h = Skin.dp(40, 35, 52)
    local action_gap = Skin.dp(5, 4, 7)
    local requested_page_size = self:_page_size()
    local max_h = math.floor(sh * (portrait and .76 or .84))
    local fixed_h = pad * 2 + header_h + subtitle_h + tab_h + Skin.dp(8, 6, 12)
    local possible_slots = math.max(2, math.floor((max_h - fixed_h - pager_h_default) / row_h))
    local page_size = math.max(2, math.min(requested_page_size, possible_slots))
    local items = self:_items(selected)
    local pages = math.max(1, math.ceil(#items / page_size))
    self.page = math.max(1, math.min(pages, tonumber(self.page) or 1))
    local first = (self.page - 1) * page_size + 1
    local last = math.min(#items, first + page_size - 1)

    local visible_slots = math.min(page_size, math.max(1, #items))
    local has_pager = #items > page_size
    for _, candidate in ipairs(categories) do
        local candidate_items = self:_items(candidate)
        visible_slots = math.max(visible_slots, math.min(page_size, math.max(1, #candidate_items)))
        if #candidate_items > page_size then has_pager = true end
    end
    local pager_h = has_pager and pager_h_default or 0
    if self.expanded_index and (self.expanded_index < first or self.expanded_index > last) then
        self.expanded_index = nil
    end
    local expanded_h = self.expanded_index and (action_gap + action_h) or 0
    local body_h = visible_slots * row_h + expanded_h
    local requested_h = math.min(max_h, fixed_h + body_h + pager_h)
    -- Keep one stable white rectangle while navigating inside the same dialog.
    -- A child page may be shorter than its parent; shrinking a transparent modal
    -- would leave the parent's pixels behind on e-ink until a full refresh.
    self._session_panel_h = math.max(tonumber(self._session_panel_h) or 0, requested_h)
    local panel_h = math.min(max_h, self._session_panel_h)
    local panel_x = math.floor((sw - panel_w) / 2)
    local panel_y = math.max(Skin.dp(12, 10, 18), math.floor((sh - panel_h) / 2))

    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.panel_h = panel_h
    self.frame_dimen = Geom:new{x = panel_x, y = panel_y, w = panel_w, h = panel_h}

    local root = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    root[#root + 1] = OffsetContainer:new{
        x_off = panel_x, y_off = panel_y,
        Skin.frame(panel_w, panel_h, {
            bordersize = Skin.line("thin"), padding = 0, radius = Skin.dp(7, 6, 10),
            background = Blitbuffer.COLOR_WHITE, color = Blitbuffer.COLOR_DARK_GRAY,
        }, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }

    local y = panel_y + pad
    local side_w = Skin.dp(44, 38, 58)
    local has_parent = type(self.stack) == "table" and #self.stack > 0
    local can_back = has_parent or type(self.opts and self.opts.on_back) == "function"
    local back = TapBox:new{dimen = Geom:new{w = side_w, h = header_h}, enabled = can_back, callback = function()
        return self:_pop()
    end}
    if can_back then
        back[1] = Ui.icon("back", side_w, header_h, Skin.dp(21, 18, 28), {face = Skin.face("cfont", 20, 26, 17)})
    else
        back[1] = Widget:new{dimen = Geom:new{w = side_w, h = header_h}}
    end
    local close = TapBox:new{dimen = Geom:new{w = side_w, h = header_h}, callback = function()
        return self:_close(self.opts and self.opts.on_close or nil, false)
    end}
    close[1] = Ui.icon("close", side_w, header_h, Skin.dp(20, 17, 27), {face = Skin.face("cfont", 16, 21, 13.5)})
    root[#root + 1] = OffsetContainer:new{
        x_off = panel_x + pad, y_off = y,
        HorizontalGroup:new{
            align = "center",
            back,
            Ui.textbox(tostring(self.opts.title or "觅阅"), math.max(1, content_w - side_w * 2), header_h,
                Skin.face("cfont", 16.0, 20.6, 13.4), {bold = true, alignment = "center", halign = "center"}),
            close,
        },
    }
    y = y + header_h

    if subtitle_h > 0 then
        root[#root + 1] = OffsetContainer:new{x_off = panel_x + pad, y_off = y,
            Ui.textbox(subtitle, content_w, subtitle_h, Skin.face("smallinfofont", 8.7, 11.5, 7.4), {
                alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            })}
        y = y + subtitle_h
    end

    if tab_h > 0 then
        local tab_w = math.max(1, math.floor(content_w / #categories))
        for index, category in ipairs(categories) do
            local x = panel_x + pad + (index - 1) * tab_w
            local actual_w = index == #categories and (panel_x + pad + content_w - x) or tab_w
            root[#root + 1] = OffsetContainer:new{x_off = x, y_off = y,
                self:_tab_widget(category, actual_w, tab_h, tostring(category.key or "") == self.selected_key)}
        end
        y = y + tab_h
    end

    if #items == 0 then
        root[#root + 1] = OffsetContainer:new{x_off = panel_x + pad, y_off = y,
            Ui.textbox(tostring(selected and selected.empty_text or self.opts.empty_text or "当前没有内容"), content_w, row_h,
                Skin.face("cfont", 11.0, 14.8, 9.4), {alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_DARK_GRAY})}
    else
        for index = first, last do
            local item = items[index]
            root[#root + 1] = OffsetContainer:new{x_off = panel_x + pad, y_off = y, self:_row_widget(item, content_w, row_h, index)}
            y = y + row_h
            if self.expanded_index == index then
                y = y + action_gap
                root[#root + 1] = OffsetContainer:new{x_off = panel_x + pad, y_off = y,
                    self:_inline_actions_widget(item, content_w, action_h)}
                y = y + action_h
            end
            if index < last then
                local strong=item.separator==true
                root[#root + 1] = OffsetContainer:new{x_off = panel_x + pad + Skin.dp(4, 3, 6), y_off = y,
                    Skin.divider(math.max(1, content_w - Skin.dp(8, 6, 12)),
                        strong and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
                        strong and Skin.line("thick") or Skin.line("thin"))}
            end
        end
    end

    if pages > 1 then
        local prev_w = Skin.dp(54, 46, 72)
        local next_w = prev_w
        local page_w = math.max(1, content_w - prev_w - next_w)
        root[#root + 1] = OffsetContainer:new{x_off = panel_x + pad, y_off = panel_y + panel_h - pad - pager_h,
            HorizontalGroup:new{
                align = "center",
                self:_pager_button("back", prev_w, pager_h, function()
                    if self.page > 1 then self.page = self.page - 1; self.expanded_index = nil; self:_rebuild() end
                end, self.page > 1),
                Ui.textbox(tostring(self.page).." / "..tostring(pages), page_w, pager_h, Skin.face("cfont", 10.0, 13.3, 8.5), {
                    alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                }),
                self:_pager_button("chevron-right", next_w, pager_h, function()
                    if self.page < pages then self.page = self.page + 1; self.expanded_index = nil; self:_rebuild() end
                end, self.page < pages),
            }}
    end

    self[1] = root
end

function Dialog:_rebuild()
    local old = self.frame_dimen and self.frame_dimen:copy() or nil
    self:_build_content()
    local dirty = self.frame_dimen
    if old then
        dirty = Geom:new{
            x = math.min(old.x, self.frame_dimen.x), y = math.min(old.y, self.frame_dimen.y),
            w = math.max(old.x + old.w, self.frame_dimen.x + self.frame_dimen.w) - math.min(old.x, self.frame_dimen.x),
            h = math.max(old.y + old.h, self.frame_dimen.y + self.frame_dimen.h) - math.min(old.y, self.frame_dimen.y),
        }
    end
    UIManager:setDirty(self, function() return "full", Skin.expand_region(dirty) end)
end

function Dialog:init()
    self.opts = self.opts or {}
    self.selected_key = tostring(self.opts.initial_category or "")
    self.page = tonumber(self.opts.initial_page) or 1
    self.expanded_index = nil
    self.stack = {}
    self._session_panel_h = nil
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
    if type(self.stack) == "table" and #self.stack > 0 then return self:_pop() end
    return self:_close(self.opts and self.opts.on_back or nil)
end
function Dialog:onShow()
    UIManager:setDirty(self, function() return "full", Skin.expand_region(self.frame_dimen) end)
end
function Dialog:onCloseWidget()
    local region = self.frame_dimen and Skin.expand_region(self.frame_dimen) or nil
    local action = self.pending_action
    self.pending_action = nil
    self.closed = true
    if live_dialog == self then live_dialog = nil end
    DialogTransition.after_close(region, action, "ReaderListDialog")
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
        logger.warn("[MiuRead][ReaderListDialog] build failed", tostring(dialog))
        return nil, tostring(dialog)
    end
    live_dialog = dialog
    UIManager:show(dialog, "full", dialog.frame_dimen)
    return dialog
end
return M
