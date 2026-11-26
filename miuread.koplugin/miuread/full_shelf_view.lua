local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
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
local UiScale = require("miuread.ui_scale")
local U = require("miuread.util")
local Ui = require("miuread.ui_components")

local Screen = Device.screen

local function face(name, nominal, maximum, minimum)
    return UiScale.face(name, nominal, maximum, minimum)
end

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local RoundedImage = WidgetContainer:extend{width = 1, height = 1, radius = 0, ink_boost = .10}
function RoundedImage:getSize() return Geom:new{w = self.width, h = self.height} end
function RoundedImage:paintTo(bb, x, y)
    if self[1] then self[1]:paintTo(bb, x, y) end
    if bb and type(bb.darkenRect) == "function" and (tonumber(self.ink_boost) or 0) > 0 then
        pcall(bb.darkenRect, bb, x, y, self.width, self.height, math.min(.16, tonumber(self.ink_boost) or .10))
    end
    local r = math.max(0, math.min(math.floor(self.radius or 0), math.floor(math.min(self.width, self.height) / 2)))
    if r <= 1 or not bb or type(bb.paintRect) ~= "function" then return end
    for row = 0, r - 1 do
        local dy = r - row
        local inside = math.sqrt(math.max(0, r * r - dy * dy))
        local inset = math.max(0, math.floor(r - inside + .5))
        if inset > 0 then
            bb:paintRect(x, y + row, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + self.width - inset, y + row, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x, y + self.height - 1 - row, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + self.width - inset, y + self.height - 1 - row, inset, 1, Blitbuffer.COLOR_WHITE)
        end
    end
end

local function fixed_frame(width, height, options, content)
    options = options or {}
    local border = tonumber(options.bordersize) or 0
    local padding = tonumber(options.padding) or 0
    local inset = border + padding
    return FrameContainer:new{
        bordersize = border,
        padding = padding,
        margin = 0,
        radius = options.radius or 0,
        background = options.background,
        color = options.color or Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{w = math.max(1, width - inset * 2), h = math.max(1, height - inset * 2)},
            content or Widget:new{dimen = Geom:new{w = 1, h = 1}},
        },
    }
end

local TapBox = InputContainer:extend{dimen = nil, callback = nil, hold_callback = nil, _hold_handled=false}
function TapBox:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {
        TapSelect = {GestureRange:new{ges = "tap", range = self.dimen}},
        HoldSelect = {GestureRange:new{ges = "hold", range = self.dimen}},
    }
end
function TapBox:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function TapBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function TapBox:onTapSelect()
    if self._hold_handled then
        self._hold_handled=false
        return true
    end
    if self.callback then self.callback(self.dimen and self.dimen:copy() or nil) end
    return true
end
function TapBox:onHoldSelect()
    if type(self.hold_callback)~="function" then return false end
    self._hold_handled=true
    self.hold_callback(self.dimen and self.dimen:copy() or nil)
    return true
end
function TapBox:onHoldReleaseSelect()
    if self._hold_handled then
        self._hold_handled=false
        return true
    end
    return false
end

local function tappable(width, height, child, callback, hold_callback)
    local box = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        callback = callback,
        hold_callback = hold_callback,
    }
    box[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, child}
    return box
end

local function image_widget(path, width, height)
    path = tostring(path or "")
    if path == "" then return nil end
    local image
    local ok = pcall(function()
        image = ImageWidget:new{
            file = path,
            width = width,
            height = height,
            scale_factor = 0,
            file_do_cache = true,
        }
        image:getSize()
        image.width = nil
        image.height = nil
    end)
    if not ok or not image then
        if image and type(image.free) == "function" then pcall(image.free, image) end
        return nil
    end
    local rounded = RoundedImage:new{
        width = width,
        height = height,
        radius = UiScale.radius(7, 5, 12),
        ink_boost = .11,
    }
    rounded[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, image}
    return rounded
end

local function placeholder(width, height, title, author)
    title = U.trim(tostring(title or "未命名"))
    author = U.trim(tostring(author or ""))
    if title == "" then title = "未命名" end
    local pad = UiScale.dp(3, 2, 5)
    local content_w = math.max(1, width - pad * 2)
    local content_h = math.max(1, height - pad * 2)
    local title_h = math.max(1, math.floor(content_h * (author ~= "" and .60 or .80)))
    local body = VerticalGroup:new{align = "center", TextBoxWidget:new{
        text = U.utf8_truncate(title, 24, "…"), face = face("cfont", 10.8, 15.5), bold = true,
        width = math.max(1, content_w - UiScale.dp(4, 3, 7)), height = title_h,
        height_adjust = false, height_overflow_show_ellipsis = true, alignment = "center",
    }}
    if author ~= "" then
        body[#body + 1] = TextBoxWidget:new{
            text = U.utf8_truncate(author, 18, "…"), face = face("smallinfofont", 7.8, 10.8),
            width = math.max(1, content_w - UiScale.dp(4, 3, 7)), height = math.max(1, content_h - title_h),
            height_adjust = false, height_overflow_show_ellipsis = true, alignment = "center",
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
    end
    return fixed_frame(width, height, {
        bordersize = UiScale.line("thin"), radius = UiScale.radius(7, 5, 12),
        padding = pad, background = Blitbuffer.COLOR_WHITE, color = Blitbuffer.COLOR_GRAY,
    }, body)
end

local function outlined_badge(text, width, height)
    local layer = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    local radius = math.max(2, UiScale.dp(2, 2, 3))
    local offsets = {
        {-radius,0},{radius,0},{0,-radius},{0,radius},
        {-radius,-radius},{-radius,radius},{radius,-radius},{radius,radius},
    }
    for _, off in ipairs(offsets) do
        layer[#layer + 1] = OffsetContainer:new{x_off = off[1], y_off = off[2],
            CenterContainer:new{dimen = Geom:new{w = width, h = height}, TextWidget:new{
                text = text, face = face("smallinfofont", 9.0, 13), bold = true, fgcolor = Blitbuffer.COLOR_WHITE,
            }}}
    end
    layer[#layer + 1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, TextWidget:new{
        text = text, face = face("smallinfofont", 9.0, 13), bold = true, fgcolor = Blitbuffer.COLOR_BLACK,
    }}
    return layer
end

local function book_card(book, width, height, on_select, on_hold)
    local title_h = UiScale.dp(31, 27, 44)
    local gap = UiScale.dp(3, 2, 5)
    local cover_h = math.max(UiScale.dp(116, 98, 190), height - title_h - gap)
    local cover_w = math.max(UiScale.dp(76, 65, 126), math.min(math.floor(width * .92), math.floor(cover_h * .715)))
    local cover = image_widget(book.cover_path, cover_w, cover_h) or placeholder(cover_w, cover_h, book.title, book.author)
    local layer = OverlapGroup:new{dimen = Geom:new{w = cover_w, h = cover_h}, allow_mirroring = false}
    layer[#layer + 1] = cover

    local status = U.trim(tostring(book.status_text or book.download_status or ""))
    local offline=book.offline_download
    local downloaded=offline=="whole" or (offline==nil and (book.generated == true or book.downloaded == true
        or tostring(book.shelf_section or "") == "generated"
        or status == "已生成" or status == "已下载"
        or (book.file and tostring(book.file) ~= "" and U.file_exists(tostring(book.file)))))
    local progress = math.max(0, math.min(100, tonumber(book.progress) or 0))
    if downloaded or offline=="partial" then
        local badge = offline=="partial" and UiScale.dp(34,29,38) or UiScale.dp(20,18,28)
        local inset = UiScale.dp(3, 2, 5)
        layer[#layer + 1] = OffsetContainer:new{x_off = inset, y_off = inset, outlined_badge(offline=="partial" and "部分" or "✓",badge,UiScale.dp(20,18,28))}
    end
    if progress > 0 then
        local text = progress >= 100 and "已读" or tostring(math.floor(progress + .5)) .. "%"
        local badge_w = math.max(UiScale.dp(32, 28, 48), U.utf8_len(text) * UiScale.dp(8, 7, 11) + UiScale.dp(11, 9, 15))
        local badge_h = UiScale.dp(20, 18, 28)
        local inset = UiScale.dp(3, 2, 5)
        layer[#layer + 1] = OffsetContainer:new{
            x_off = math.max(0, cover_w - badge_w - inset),
            y_off = inset,
            outlined_badge(text, badge_w, badge_h),
        }
    end

    local body = VerticalGroup:new{
        align = "center",
        layer,
        VerticalSpan:new{height = gap},
        TextBoxWidget:new{
            text = tostring(book.title or "未命名"),
            face = face("cfont", 11.6, 16.5),
            bold = true,
            width = width,
            height = title_h,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "center",
        },
    }
    return tappable(width, height, body,
        function(anchor) if on_select then on_select(book, anchor) end end,
        on_hold and function(anchor) on_hold(book, anchor) end or nil)
end

local GridShelfWidget = InputContainer:extend{
    name = "miuread_full_shelf",
    _miuread_transient = true,
    covers_fullscreen = true,
    opts = nil,
    page = 1,
    pages = 1,
    perpage = 12,
    _closed = false,
    _miu_closed = false,
}

function GridShelfWidget:_metrics()
    local m = UiScale.metrics()
    local sw, sh = m.sw, m.sh
    local margin = math.max(UiScale.dp(9, 8, 17), math.floor(math.min(sw, sh) * .012))
    local header_h = UiScale.dp(54, 48, 74)
    local footer_h = UiScale.dp(45, 40, 62)
    local gap = UiScale.dp(6, 5, 10)
    local rows = m.portrait and 3 or 2
    return m, margin, header_h, footer_h, gap, rows
end

function GridShelfWidget:_close()
    if self._closed then return true end
    self._closed = true
    UIManager:close(self)
    return true
end

function GridShelfWidget:_change_page(delta)
    local next_page = math.max(1, math.min(self.pages, self.page + (tonumber(delta) or 0)))
    if next_page == self.page then return true end
    self.page = next_page
    self:_build()
    UIManager:setDirty(self, "ui")
    self:_notify_page()
    return true
end

function GridShelfWidget:_notify_page()
    if not self.opts or not self.opts.on_page_changed then return end
    local first = (self.page - 1) * self.perpage + 1
    local last = math.min(#(self.opts.books or {}), first + self.perpage - 1)
    pcall(self.opts.on_page_changed, self.page, first, last, self)
end

function GridShelfWidget:_add(group, x, y, child)
    group[#group + 1] = OffsetContainer:new{x_off = x, y_off = y, child}
end

function GridShelfWidget:_build()
    local m, margin, header_h, footer_h, gap, rows = self:_metrics()
    local sw, sh = m.sw, m.sh
    self._last_screen_w, self._last_screen_h = sw, sh
    self._last_rotation = Screen.getRotationMode and Screen:getRotationMode() or nil
    local columns = 4
    self.perpage = columns * rows
    self.pages = math.max(1, math.ceil(#(self.opts.books or {}) / self.perpage))
    self.page = math.max(1, math.min(self.pages, tonumber(self.page) or 1))
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.ges_events = {
        ShelfSwipe = {GestureRange:new{ges = "swipe", range = self.dimen}},
    }

    local layers = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    self:_add(layers, 0, 0, fixed_frame(sw, sh, {background = Blitbuffer.COLOR_WHITE}))

    local inner_w = math.max(1, sw - margin * 2)
    local back_w = UiScale.dp(54, 49, 78)
    local action_w = self.opts.show_actions and UiScale.dp(62, 56, 92) or 0
    local action_gap = self.opts.show_actions and UiScale.dp(5, 4, 8) or 0
    local right_w = self.opts.show_actions and (action_w * 2 + action_gap) or 0
    local title_gap = UiScale.dp(5, 4, 8)
    local title_w = math.max(1, inner_w - back_w - title_gap - right_w)
    local header = HorizontalGroup:new{
        align = "center",
        tappable(back_w, header_h, Ui.icon("back", back_w, header_h, UiScale.dp(20, 18, 28), {
            face = UiScale.iconFace("cfont", 20, 28),
        }), function() self:_close() end),
        HorizontalSpan:new{width = title_gap},
        Ui.textbox(tostring(self.opts.title or "全部书籍"), title_w, header_h,
            face("cfont", 16, 22), {
                bold = true, alignment = "left", halign = "left", valign = "center",
            }),
    }
    if self.opts.show_actions then
        local left_label=tostring(self.opts.left_action_label or "")
        local right_label=tostring(self.opts.right_action_label or "筛选")
        local left_child
        if left_label=="" or left_label=="搜索" then
            left_child=Ui.icon("search", action_w, header_h, UiScale.dp(19, 17, 27), {
                face = UiScale.iconFace("cfont", 17, 24),
            })
        else
            left_child=Ui.text(left_label, action_w, header_h, face("smallinfofont", 9.6, 13.5), {
                bold=true, halign="center", valign="center",
            })
        end
        header[#header + 1] = tappable(action_w, header_h, left_child, self.opts.on_left_action)
        header[#header + 1] = HorizontalSpan:new{width = action_gap}
        header[#header + 1] = tappable(action_w, header_h,
            Ui.text(right_label, action_w, header_h, face("smallinfofont", 9.6, 13.5), {
                bold = true, halign = "center", valign = "center",
            }), self.opts.on_right_action)
    end
    self:_add(layers, margin, margin, header)
    self:_add(layers, margin, margin + header_h, LineWidget:new{
        background = Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{w = sw - margin * 2, h = UiScale.line("thin")},
    })

    local grid_y = margin + header_h + UiScale.line("thin") + gap
    local grid_h = math.max(1, sh - grid_y - footer_h - margin)
    local col_gap = UiScale.dp(4, 3, 7)
    local row_gap = UiScale.dp(5, 4, 9)
    local card_w = math.floor((sw - margin * 2 - col_gap * (columns - 1)) / columns)
    local card_h = math.floor((grid_h - row_gap * (rows - 1)) / rows)
    local first = (self.page - 1) * self.perpage + 1
    local last = math.min(#(self.opts.books or {}), first + self.perpage - 1)
    local slot = 0
    for index = first, last do
        local row = math.floor(slot / columns)
        local col = slot % columns
        local book = self.opts.books[index]
        self:_add(layers,
            margin + col * (card_w + col_gap),
            grid_y + row * (card_h + row_gap),
            book_card(book, card_w, card_h, self.opts.on_select, self.opts.on_hold))
        slot = slot + 1
    end

    local arrow_w = UiScale.dp(74, 66, 108)
    local middle_w = math.max(1, sw - margin * 2 - arrow_w * 2)
    local footer = HorizontalGroup:new{
        align = "center",
        tappable(arrow_w, footer_h, TextWidget:new{
            text = "‹",
            face = UiScale.iconFace("cfont", 18, 25),
            bold = true,
            fgcolor = self.page > 1 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }, self.page > 1 and function() self:_change_page(-1) end or nil),
        CenterContainer:new{dimen = Geom:new{w = middle_w, h = footer_h}, TextWidget:new{
            text = tostring(self.page) .. " / " .. tostring(self.pages),
            face = face("smallinfofont", 10.5, 14.5),
            bold = true,
        }},
        tappable(arrow_w, footer_h, TextWidget:new{
            text = "›",
            face = UiScale.iconFace("cfont", 18, 25),
            bold = true,
            fgcolor = self.page < self.pages and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }, self.page < self.pages and function() self:_change_page(1) end or nil),
    }
    self:_add(layers, margin, sh - margin - footer_h, footer)
    self[1] = layers
end

function GridShelfWidget:init()
    self.page = tonumber(self.opts and self.opts.page) or 1
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        if Device.input and Device.input.group and Device.input.group.Back then self.key_events.Back = {{Device.input.group.Back}} end
        if Device.input and Device.input.group and Device.input.group.PgFwd then self.key_events.ShelfNext = {{Device.input.group.PgFwd}} end
        if Device.input and Device.input.group and Device.input.group.PgBack then self.key_events.ShelfPrevious = {{Device.input.group.PgBack}} end
    end
    self:_build()
end

function GridShelfWidget:updateItems()
    if self._miu_closed then return false end
    self:_build()
    UIManager:setDirty(self, "ui")
    return true
end

function GridShelfWidget:onShelfSwipe(_, ges)
    if ges and ges.direction == "west" then return self:_change_page(1) end
    if ges and ges.direction == "east" then return self:_change_page(-1) end
    return false
end
function GridShelfWidget:onShelfNext() return self:_change_page(1) end
function GridShelfWidget:onShelfPrevious() return self:_change_page(-1) end
function GridShelfWidget:onBack() return self:_close() end
function GridShelfWidget:onShow()
    UIManager:setDirty(self, "full")
    self:_notify_page()
    if self.opts and self.opts.on_rendered then UIManager:scheduleIn(0, function() pcall(self.opts.on_rendered, self) end) end
end
function GridShelfWidget:onCloseWidget()
    self._miu_closed = true
    self._dimension_generation=(tonumber(self._dimension_generation) or 0)+1
    if self._dimension_task then UIManager:unschedule(self._dimension_task); self._dimension_task=nil end
    if self.opts and self.opts.on_close then
        local callback = self.opts.on_close
        self.opts.on_close = nil
        pcall(callback, self)
    end
end
function GridShelfWidget:onSetDimensions()
    return self:_schedule_dimension_refresh()
end
function GridShelfWidget:_schedule_dimension_refresh()
    self._dimension_generation = (tonumber(self._dimension_generation) or 0) + 1
    local generation = self._dimension_generation
    if self._dimension_task then UIManager:unschedule(self._dimension_task) end
    local last_w, last_h, stable, attempts = nil, nil, 0, 0
    local task
    task=function()
        if self._miu_closed or self._dimension_task~=task or generation~=self._dimension_generation then return end
        attempts=attempts+1
        local sw,sh=Screen:getWidth(),Screen:getHeight()
        local rotation=Screen.getRotationMode and Screen:getRotationMode() or nil
        if sw==last_w and sh==last_h then stable=stable+1 else last_w,last_h,stable=sw,sh,0 end
        if stable>=1 or attempts>=8 then
            self._dimension_task=nil
            if sw==self._last_screen_w and sh==self._last_screen_h and rotation==self._last_rotation then return end
            self:_build()
            UIManager:setDirty(self,"full")
            return
        end
        UIManager:scheduleIn(.08,task)
    end
    self._dimension_task=task
    UIManager:scheduleIn(.06,task)
    return true
end
function GridShelfWidget:onScreenResize() return self:_schedule_dimension_refresh() end
function GridShelfWidget:onRotation() return self:_schedule_dimension_refresh() end

local FullShelfView = {}
function FullShelfView.show(opts)
    local view = GridShelfWidget:new{opts = opts or {}}
    UIManager:show(view)
    return view
end

return FullShelfView
