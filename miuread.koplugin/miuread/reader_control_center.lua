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
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local TransientGuard = require("miuread.transient_guard")
local DialogTransition = require("miuread.dialog_transition")
local Skin = require("miuread.reader_skin")
local Ui = require("miuread.ui_components")

local Screen = Device.screen
local live_center

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

local function list_icon(icon, width, height, enabled)
    return Ui.icon(icon, width, height, Skin.dp(20, 17, 27), {
        icon_key = icon,
        face = Skin.face("cfont", 15.8, 21.2, 13.2),
        fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
end

local Center = InputContainer:extend{
    name = "miuread_reader_control_center",
    _miuread_transient = true,
    _miuread_modal_surface = true,
    modal = true,
    -- Full-screen gesture capture, partial opaque ink frame.
    covers_fullscreen = false,
    stop_events_propagation = true,
    opts = nil,
    closed = false,
    pending_action = nil,
    selected_key = nil,
}

function Center:handleEvent(event)
    return InputContainer.handleEvent(self, event)
end

function Center:_close(action, cancel_pending)
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

function Center:_categories()
    local categories = self.opts and self.opts.categories or {}
    return type(categories) == "table" and categories or {}
end

function Center:_selected_category()
    local categories = self:_categories()
    if #categories == 0 then return nil end
    for _, category in ipairs(categories) do
        if tostring(category.key or "") == tostring(self.selected_key or "") then return category end
    end
    return categories[1]
end

function Center:_run_item(item)
    if not item or item.enabled == false then return true end
    if item.keep_open == true then
        if item.callback then item.callback() end
        return true
    end
    return self:_close(item.callback)
end

function Center:_row_widget(item, width, height)
    local enabled = item.enabled ~= false
    local pad = Skin.dp(10, 8, 14)
    local icon = tostring(item.icon or "")
    local value = tostring(item.value or item.detail or "")
    local arrow = item.arrow ~= false and item.callback ~= nil
    local icon_w = Skin.dp(34, 28, 46)
    local arrow_w = arrow and Skin.dp(18, 15, 24) or 0
    local value_w = value ~= "" and math.max(Skin.dp(94, 78, 128), math.floor(width * .34)) or 0
    local gap = Skin.dp(5, 4, 7)
    local label_w = math.max(1, width - pad * 2 - icon_w - value_w - arrow_w
        - gap * ((value_w > 0 and 1 or 0) + (arrow_w > 0 and 1 or 0)))
    local inner_h = math.max(1, height - pad * 2)

    local row = HorizontalGroup:new{align = "center"}
    row[#row + 1] = list_icon(icon, icon_w, inner_h, enabled)
    row[#row + 1] = Ui.textbox(tostring(item.label or item.text or ""), label_w, inner_h,
        Skin.face("cfont", 10.9, 14.8, 9.4), {
            bold = item.bold == true, alignment = "left",
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        })
    if value_w > 0 then
        row[#row + 1] = HorizontalSpan:new{width = gap}
        row[#row + 1] = Ui.textbox(value, value_w, inner_h,
            Skin.face("cfont", 10.0, 13.3, 8.5), {
                bold = item.value_bold == true, alignment = "right", halign = "right",
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
            })
    end
    if arrow_w > 0 then
        row[#row + 1] = HorizontalSpan:new{width = gap}
        row[#row + 1] = Ui.icon("chevron-right", arrow_w, inner_h, Skin.dp(15, 13, 20), {
            face = Skin.face("cfont", 13.2, 17.8, 11),
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        })
    end

    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = function() self:_run_item(item) end,
    }
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, row}
    return tap
end

function Center:_section_widget(section, width, item_h)
    local items = type(section.items) == "table" and section.items or {}
    local height = math.max(item_h, #items * item_h)
    local layers = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    -- Flat list: section hierarchy comes from spacing and hairlines rather than
    -- nested rounded frames, which keeps the e-ink page lighter and clearer.
    local inset = Skin.dp(4, 3, 6)
    for index = 1, #items - 1 do
        layers[#layers + 1] = OffsetContainer:new{
            x_off = inset,
            y_off = index * item_h,
            Skin.divider(math.max(1, width - inset * 2), Blitbuffer.COLOR_GRAY),
        }
    end
    for index, item in ipairs(items) do
        layers[#layers + 1] = OffsetContainer:new{
            x_off = 0,
            y_off = (index - 1) * item_h,
            self:_row_widget(item, width, item_h),
        }
    end
    if #items == 0 then
        layers[#layers + 1] = CenterContainer:new{
            dimen = Geom:new{w = width, h = height},
            Ui.textbox("当前没有可用功能", width - Skin.dp(20, 16, 30), height,
                Skin.face("smallinfofont", 9.6, 12.6, 8.2), {
                    alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
                }),
        }
    end
    return layers, height
end

function Center:_tab_widget(category, width, height, selected)
    local key = tostring(category.key or "")
    local layers = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    layers[#layers + 1] = Ui.textbox(tostring(category.label or key), width, height,
        Skin.face("cfont", 10.4, 14, 9), {
            bold = selected, alignment = "center", halign = "center",
            fgcolor = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        })
    if selected then
        local line_w = math.max(Skin.dp(26, 21, 36), math.floor(width * .42))
        layers[#layers + 1] = OffsetContainer:new{
            x_off = math.floor((width - line_w) / 2),
            y_off = height - Skin.line("thick"),
            LineWidget:new{
                background = Blitbuffer.COLOR_BLACK,
                dimen = Geom:new{w = line_w, h = math.max(1, Skin.line("thick"))},
            },
        }
    end
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        callback = function()
            if self.selected_key ~= key then
                self.selected_key = key
                -- A new category starts on its first page, not the former tab's page.
                self._section_page = 1
                self:_rebuild()
            end
        end,
    }
    tap[1] = layers
    return tap
end

function Center:_sections_height(sections, section_title_h, item_h, gap)
    sections = type(sections) == "table" and sections or {}
    if #sections == 0 then return item_h end
    local total = 0
    for index, section in ipairs(sections) do
        local items = type(section.items) == "table" and section.items or {}
        local title = tostring(section.title or "")
        if title ~= "" then total = total + section_title_h end
        total = total + math.max(1, #items) * item_h
        if index < #sections then total = total + gap end
    end
    return total
end

function Center:_build_root()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local portrait = sw < sh
    local outer_margin = Skin.dp(8, 6, 14)
    local top_inset = 0
    local pad = Skin.dp(14, 11, 21)
    local gap = Skin.dp(9, 7, 13)
    local panel_w = sw - outer_margin * 2
    local content_w = panel_w - pad * 2
    local header_h = math.max(Skin.dp(42, 36, 56), math.floor(sh * .041))
    local tab_h = math.max(Skin.dp(38, 33, 50), math.floor(sh * .037))
    local section_title_h = Skin.dp(28, 24, 37)
    local item_h = math.max(Skin.dp(46, 40, 60), math.floor(sh * (portrait and .043 or .060)))
    local categories = self:_categories()
    local category = self:_selected_category()
    if category then self.selected_key = tostring(category.key or "") end
    local sections = category and category.sections or (self.opts.sections or {})
    sections = type(sections) == "table" and sections or {}

    local tabs_h = #categories > 1 and tab_h or 0
    local max_h = sh - top_inset - math.max(28, math.floor(sh * .052))
    local row_budget = math.max(1, max_h - (pad * 2 + header_h + tabs_h + gap))
    -- Keep category switching stable while bounding every row. When available
    -- height is short, shrink rows down to a readable minimum before paging.
    local function section_rows(list)
        local count, titles, gaps = 0, 0, math.max(0, #list - 1)
        for _, section in ipairs(list) do
            if tostring(section.title or "") ~= "" then titles = titles + 1 end
            count = count + math.max(1, #(section.items or {}))
        end
        return count, titles, gaps
    end
    local most_rows, most_titles, most_gaps = section_rows(sections)
    for _, candidate in ipairs(categories) do
        local n,t,g = section_rows(candidate.sections or {})
        if n > most_rows then most_rows,most_titles,most_gaps=n,t,g end
    end
    local fixed_sections = most_titles * section_title_h + most_gaps * gap
    local minimum_row = Skin.dp(34, 29, 45)
    local room = math.floor((row_budget - fixed_sections) / math.max(1, most_rows))
    item_h = math.min(item_h, math.max(minimum_row, room))
    -- If a category is still taller than the screen, show a bounded subset.
    -- The full set is kept in opts so the next page can be opened.
    local capacity = math.max(1, math.floor(math.max(1, row_budget - section_title_h) / math.max(1,item_h)))
    local flat = {}
    for _, section in ipairs(sections) do
        for _, item in ipairs(section.items or {}) do
            flat[#flat+1] = {item=item, title=tostring(section.title or "")}
        end
    end
    local paging = #flat > capacity
    if paging then
        -- Reserve both navigation rows *before* measuring visible content.
        -- Otherwise Next/Previous can paint past the panel bottom.
        capacity = math.max(1, math.floor(row_budget / math.max(1,item_h)) - 2)
        local pages = math.max(1, math.ceil(#flat / capacity))
        self._section_page = math.max(1, math.min(pages, tonumber(self._section_page) or 1))
        local first=(self._section_page-1)*capacity+1
        local page_sections={}
        if self._section_page>1 then
            page_sections[#page_sections+1]={items={{icon="back",label="上一页",keep_open=true,callback=function()
                self._section_page=self._section_page-1; self:_rebuild()
            end}}}
        end
        for i=first,math.min(#flat,first+capacity-1) do
            local entry=flat[i]
            local tail=page_sections[#page_sections]
            if not tail or tostring(tail.title or "")~=entry.title or tail._nav then
                tail={title=entry.title,items={}}
                page_sections[#page_sections+1]=tail
            end
            tail.items[#tail.items+1]=entry.item
        end
        if self._section_page<pages then
            page_sections[#page_sections+1]={items={{icon="chevron-right",label="下一页",keep_open=true,callback=function()
                self._section_page=self._section_page+1; self:_rebuild()
            end}}}
        end
        -- Recalculate with section headers; shrink rows if this page contains more headers.
        sections=page_sections
        while item_h>1 and self:_sections_height(sections,section_title_h,item_h,gap)>row_budget do
            item_h=item_h-1
        end
    end
    local body_h = self:_sections_height(sections, section_title_h, item_h, gap)
    local content_h = header_h + tabs_h + gap + body_h
    if pad * 2 + content_h > max_h then
        -- Safe last resort: every painted row still stays inside the frame.
        item_h = math.max(1, math.floor((row_budget - section_title_h) / math.max(1,#(sections[1] and sections[1].items or {}))))
        body_h = self:_sections_height(sections, section_title_h, item_h, gap)
        content_h = header_h + tabs_h + gap + body_h
    end
    self.panel_h = math.min(max_h, pad * 2 + content_h)
    self._stable_panel_h = math.max(tonumber(self._stable_panel_h) or 0, self.panel_h)
    self.panel_h = self._stable_panel_h
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.panel_dimen = Geom:new{x = outer_margin, y = top_inset, w = panel_w, h = self.panel_h}
    local refresh_y = top_inset + pad + header_h
    self.content_dimen = Geom:new{
        x = outer_margin,
        y = refresh_y,
        w = panel_w,
        h = math.max(1, top_inset + self.panel_h - refresh_y),
    }

    local root = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin,
        y_off = top_inset,
        Skin.frame(panel_w, self.panel_h, {
            bordersize = 0, padding = 0, radius = 0,
            background = Blitbuffer.COLOR_WHITE, color = Blitbuffer.COLOR_WHITE,
        }, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin,
        y_off = top_inset + self.panel_h - math.max(1, Skin.line("thin")),
        LineWidget:new{background = Blitbuffer.COLOR_DARK_GRAY, dimen = Geom:new{w = panel_w, h = math.max(1, Skin.line("thin"))}},
    }

    local y = top_inset + pad
    local back_w = Skin.dp(44, 38, 58)
    local title_w = math.max(1, content_w - back_w * 2)
    local back_tap = TapBox:new{
        dimen = Geom:new{w = back_w, h = header_h},
        callback = function() self:_close(self.opts and self.opts.on_back or nil) end,
    }
    back_tap[1] = Ui.icon("back", back_w, header_h, Skin.dp(21, 18, 28), {
        face = Skin.face("cfont", 21, 26, 18), fgcolor = Blitbuffer.COLOR_BLACK,
    })
    local home_action = self.opts and self.opts.on_home or nil
    local home_tap = TapBox:new{
        dimen = Geom:new{w = back_w, h = header_h},
        enabled = type(home_action) == "function",
        callback = function() self:_close(home_action) end,
    }
    home_tap[1] = Ui.icon("home", back_w, header_h, Skin.dp(21, 18, 28), {
        face = Skin.face("cfont", 15.8, 20.8, 13.2),
        fgcolor = type(home_action) == "function" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
    local header = HorizontalGroup:new{
        align = "center",
        back_tap,
        Ui.textbox(tostring(self.opts.title or "全部阅读功能"), title_w, header_h,
            Skin.face("cfont", 16.2, 20.8, 13.6), {
                bold = true, alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
            }),
        home_tap,
    }
    root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, header}
    y = y + header_h

    if #categories > 1 then
        local tab_w = math.max(1, math.floor(content_w / #categories))
        for index, tab in ipairs(categories) do
            root[#root + 1] = OffsetContainer:new{
                x_off = outer_margin + pad + (index - 1) * tab_w,
                y_off = y,
                self:_tab_widget(tab, tab_w, tab_h, tostring(tab.key or "") == tostring(self.selected_key or "")),
            }
        end
        y = y + tab_h
    end

    y = y + gap
    if #sections == 0 then
        root[#root + 1] = OffsetContainer:new{
            x_off = outer_margin + pad,
            y_off = y,
            Ui.textbox("当前没有可用功能", content_w, item_h,
                Skin.face("smallinfofont", 10.5, 13.5, 9), {
                    alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
                }),
        }
    else
        for section_index, section in ipairs(sections) do
            local section_title = tostring(section.title or "")
            if section_title ~= "" then
                root[#root + 1] = OffsetContainer:new{
                    x_off = outer_margin + pad,
                    y_off = y,
                    Ui.textbox(section_title, content_w, section_title_h,
                        Skin.face("smallinfofont", 9.5, 12.6, 8.2), {
                            bold = true, alignment = "left", fgcolor = Blitbuffer.COLOR_BLACK,
                        }),
                }
                y = y + section_title_h
            end
            local section_widget, section_h = self:_section_widget(section, content_w, item_h)
            root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, section_widget}
            y = y + section_h
            if section_index < #sections then y = y + gap end
        end
    end

    return root
end

function Center:_rebuild()
    local old = self.content_dimen and self.content_dimen:copy() or nil
    self[1] = self:_build_root()
    local dirty = self.content_dimen or self.panel_dimen
    if old and self.content_dimen then
        dirty = Geom:new{
            x = math.min(old.x, self.content_dimen.x),
            y = math.min(old.y, self.content_dimen.y),
            w = math.max(old.x + old.w, self.content_dimen.x + self.content_dimen.w) - math.min(old.x, self.content_dimen.x),
            h = math.max(old.y + old.h, self.content_dimen.y + self.content_dimen.h) - math.min(old.y, self.content_dimen.y),
        }
    end
    UIManager:setDirty(self, function() return "ui", Skin.expand_region(dirty) end)
end

function Center:init()
    self.opts = self.opts or {}
    self.selected_key = tostring(self.opts.initial_category or "")
    self[1] = self:_build_root()
    self.ges_events = {
        TapDismiss = {GestureRange:new{ges = "tap", range = self.dimen}},
        SwipeDismiss = {GestureRange:new{ges = "swipe", range = self.dimen}},
    }
    if Device:hasKeys() and Device.input and Device.input.group and Device.input.group.Back then
        self.key_events = {Close = {{Device.input.group.Back}}}
    end
end

function Center:onTapDismiss(_, ges)
    local pos = ges and ges.pos
    if pos and (pos.y < self.panel_dimen.y or pos.y > self.panel_dimen.y + self.panel_dimen.h
        or pos.x < self.panel_dimen.x or pos.x > self.panel_dimen.x + self.panel_dimen.w) then
        return self:_close(nil, true)
    end
    return false
end
function Center:onSwipeDismiss(_, ges)
    if ges and ges.direction == "north" then return self:_close(nil, true) end
    return false
end
function Center:onClose()
    return self:_close(self.opts and self.opts.on_back or nil)
end
function Center:onShow()
    UIManager:setDirty(self, function() return "ui", Skin.expand_region(self.panel_dimen) end)
end
function Center:onCloseWidget()
    local region = self.panel_dimen and Skin.expand_region(self.panel_dimen) or nil
    local action = self.pending_action
    self.pending_action = nil
    self.closed = true
    if live_center == self then live_center = nil end
    DialogTransition.after_close(region, action, "ReaderControlCenter")
end

local M = {}
function M.close()
    if live_center and not live_center.closed then live_center:_close(nil, true) end
    live_center = nil
end
function M.show(opts)
    TransientGuard.close_all()
    M.close()
    local ok, center = pcall(Center.new, Center, {opts = opts or {}})
    if not ok or not center then
        logger.warn("[MiuRead][ReaderControlCenter] build failed", tostring(center))
        return nil, tostring(center)
    end
    live_center = center
    UIManager:show(center, "ui", center.panel_dimen)
    return center
end
return M
