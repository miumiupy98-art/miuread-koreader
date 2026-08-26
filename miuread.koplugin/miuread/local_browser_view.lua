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
local Ui = require("miuread.ui_components")
local U = require("miuread.util")

local Screen = Device.screen
local function face(name, nominal, maximum, minimum)
    return UiScale.face(name, nominal, maximum, minimum)
end

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y) self[1]:paintTo(bb, x + self.x_off, y + self.y_off) end

local function fixed_frame(width, height, options, child)
    options = options or {}
    local border = tonumber(options.bordersize) or 0
    local padding = tonumber(options.padding) or 0
    local inset = border + padding
    return FrameContainer:new{
        bordersize = border, padding = padding, margin = 0,
        radius = options.radius or 0,
        background = options.background or Blitbuffer.COLOR_WHITE,
        color = options.color or Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{w = math.max(1, width - inset * 2), h = math.max(1, height - inset * 2)},
            child or Widget:new{dimen = Geom:new{w = 1, h = 1}},
        },
    }
end

local TapBox = InputContainer:extend{dimen = nil, callback = nil, hold_callback = nil}
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
function TapBox:onTapSelect() if self.callback then self.callback() end return true end
function TapBox:onHoldSelect() if self.hold_callback then self.hold_callback() end return true end

local function tappable(width, height, child, callback, hold_callback)
    local box = TapBox:new{dimen = Geom:new{w = width, h = height}, callback = callback, hold_callback = hold_callback}
    box[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, child}
    return box
end

local function image_widget(path, width, height)
    path = tostring(path or "")
    if path == "" then return nil end
    local image
    local ok = pcall(function()
        image = ImageWidget:new{file = path, width = width, height = height, scale_factor = 0, file_do_cache = true}
        image:getSize(); image.width = nil; image.height = nil
    end)
    if ok and image then return CenterContainer:new{dimen = Geom:new{w = width, h = height}, image} end
    if image and type(image.free) == "function" then pcall(image.free, image) end
    return nil
end

local function book_placeholder(width, height, title, author)
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

local function folder_card(folder, width, height, callback)
    -- Keep folders and books on the same grid: one folder == one cover slot.
    local title_h = UiScale.dp(31, 27, 44)
    local gap = UiScale.dp(3, 2, 5)
    local cover_h = math.max(UiScale.dp(112, 94, 180), height - title_h - gap)
    local cover_w = math.max(UiScale.dp(74, 62, 122), math.min(math.floor(width * .92), math.floor(cover_h * .715)))
    local icon_size = math.max(UiScale.dp(40, 34, 58), math.min(math.floor(cover_w * .58), math.floor(cover_h * .35)))
    local cover_inset = UiScale.line("thin") + UiScale.dp(2, 1, 4)
    local icon_area_w = math.max(1, cover_w - cover_inset * 2)
    local icon_area_h = math.max(1, cover_h - cover_inset * 2)
    local cover = fixed_frame(cover_w, cover_h, {
        bordersize = UiScale.line("thin"), radius = UiScale.radius(7, 5, 12),
        padding = UiScale.dp(2, 1, 4), background = Blitbuffer.COLOR_WHITE, color = Blitbuffer.COLOR_GRAY,
    }, Ui.icon("folder", icon_area_w, icon_area_h, icon_size, {face = UiScale.iconFace("cfont", 30, 42)}))
    local body = VerticalGroup:new{
        align = "center",
        cover,
        VerticalSpan:new{height = gap},
        TextBoxWidget:new{
            text = tostring(folder.title or "文件夹"), face = face("cfont", 11.8, 16.8), bold = true,
            width = width, height = title_h, height_adjust = false,
            height_overflow_show_ellipsis = true, alignment = "center",
        },
    }
    return tappable(width, height, body, callback)
end

local function book_card(book, width, height, callback, hold_callback)
    local title_h = UiScale.dp(31, 27, 44)
    local gap = UiScale.dp(3, 2, 5)
    local cover_h = math.max(UiScale.dp(112, 94, 180), height - title_h - gap)
    local cover_w = math.max(UiScale.dp(74, 62, 122), math.min(math.floor(width * .92), math.floor(cover_h * .715)))
    local cover = image_widget(book.cover_path, cover_w, cover_h) or book_placeholder(cover_w, cover_h, book.title, book.author)
    local body = VerticalGroup:new{
        align = "center", cover, VerticalSpan:new{height = gap},
        TextBoxWidget:new{
            text = tostring(book.title or "未命名"), face = face("cfont", 11.4, 16.2), bold = true,
            width = width, height = title_h, height_adjust = false,
            height_overflow_show_ellipsis = true, alignment = "center",
        },
    }
    return tappable(width, height, body, callback, hold_callback)
end

local LocalBrowserWidget = InputContainer:extend{
    name = "miuread_local_browser", _miuread_transient = true,
    covers_fullscreen = true, opts = nil, page = 1, pages = 1, view_mode = "books",
    _closed = false, _miu_closed = false,
}

function LocalBrowserWidget:_metrics()
    local m = UiScale.metrics()
    local margin = math.max(UiScale.dp(9, 8, 17), math.floor(math.min(m.sw, m.sh) * .012))
    local header_h = UiScale.dp(54, 48, 74)
    local tab_h = UiScale.dp(38, 34, 52)
    local footer_h = UiScale.dp(45, 40, 62)
    local gap = UiScale.dp(6, 5, 10)
    local rows = m.portrait and 3 or 2
    return m, margin, header_h, tab_h, footer_h, gap, rows
end

function LocalBrowserWidget:_close()
    if self._closed then return true end
    self._closed = true
    UIManager:close(self)
    return true
end

function LocalBrowserWidget:_back()
    if self.opts and self.opts.on_back then
        self.opts.on_back(self)
        return true
    end
    return self:_close()
end

function LocalBrowserWidget:_entries()
    local entries = {}
    if self.opts and self.opts.mixed_view == true then
        for _, folder in ipairs((self.opts and self.opts.folders) or {}) do
            entries[#entries + 1] = {kind = "folder", value = folder, weight = 1}
        end
        for _, book in ipairs((self.opts and self.opts.books) or {}) do
            entries[#entries + 1] = {kind = "book", value = book, weight = 1}
        end
    elseif self.view_mode == "folders" then
        for _, folder in ipairs((self.opts and self.opts.folders) or {}) do
            entries[#entries + 1] = {kind = "folder", value = folder, weight = 1}
        end
    else
        for _, book in ipairs((self.opts and self.opts.books) or {}) do
            entries[#entries + 1] = {kind = "book", value = book, weight = 1}
        end
    end
    return entries
end

function LocalBrowserWidget:_set_view_mode(mode)
    mode = mode == "books" and "books" or "folders"
    if mode == self.view_mode then return true end
    self.view_mode = mode
    self.page = 1
    self:_build()
    UIManager:setDirty(self, "full")
    if self.opts and self.opts.on_page_changed then
        self.opts.on_page_changed(self.page, self:visibleBooks(), self)
    end
    return true
end

function LocalBrowserWidget:_page_map(capacity)
    local pages, current, used = {}, {}, 0
    for _, entry in ipairs(self:_entries()) do
        local weight = entry.weight or 1
        if used > 0 and used + weight > capacity then
            pages[#pages + 1] = current; current, used = {}, 0
        end
        current[#current + 1] = entry; used = used + weight
    end
    if #current > 0 or #pages == 0 then pages[#pages + 1] = current end
    return pages
end

function LocalBrowserWidget:_add(group, x, y, child)
    group[#group + 1] = OffsetContainer:new{x_off = x, y_off = y, child}
end

function LocalBrowserWidget:_build()
    local m, margin, header_h, tab_h, footer_h, gap, rows = self:_metrics()
    local sw, sh = m.sw, m.sh
    self._last_screen_w, self._last_screen_h = sw, sh
    self._last_rotation = Screen.getRotationMode and Screen:getRotationMode() or nil
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.ges_events = {BrowserSwipe = {GestureRange:new{ges = "swipe", range = self.dimen}}}
    local columns, capacity = 4, 4 * rows
    local pages = self:_page_map(capacity)
    self.pages = math.max(1, #pages)
    self.page = math.max(1, math.min(self.pages, tonumber(self.page) or 1))

    local layers = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    self:_add(layers, 0, 0, fixed_frame(sw, sh, {background = Blitbuffer.COLOR_WHITE}))

    local inner_w = math.max(1, sw - margin * 2)
    local back_w = UiScale.dp(54, 49, 78)
    local refresh_w = UiScale.dp(60, 54, 88)
    local title_gap = UiScale.dp(5, 4, 8)
    local title_w = math.max(1, inner_w - back_w - refresh_w - title_gap * 2)
    local header = HorizontalGroup:new{
        align = "center",
        tappable(back_w, header_h, Ui.icon("back", back_w, header_h, UiScale.dp(20, 18, 28), {
            face = UiScale.iconFace("cfont", 20, 28),
        }), function() self:_back() end),
        HorizontalSpan:new{width = title_gap},
        Ui.textbox(tostring(self.opts and self.opts.title or "本地书库"), title_w, header_h,
            face("cfont", 16, 22), {bold = true, alignment = "left", halign = "left", valign = "center"}),
        HorizontalSpan:new{width = title_gap},
        tappable(refresh_w, header_h, Ui.icon("refresh", refresh_w, header_h, UiScale.dp(19, 17, 27), {
            face = UiScale.iconFace("cfont", 17, 24),
        }), self.opts and self.opts.on_refresh or nil),
    }
    self:_add(layers, margin, margin, header)
    self:_add(layers, margin, margin + header_h, LineWidget:new{
        background = Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{w = sw - margin * 2, h = UiScale.line("thin")},
    })

    local folder_count = #((self.opts and self.opts.folders) or {})
    local book_count = #((self.opts and self.opts.books) or {})
    local mixed_view = self.opts and self.opts.mixed_view == true
    if not mixed_view then
        if self.view_mode == "folders" and folder_count == 0 and book_count > 0 then self.view_mode = "books" end
        if self.view_mode == "books" and book_count == 0 and folder_count > 0 then self.view_mode = "folders" end
        local tab_w = math.floor(inner_w / 2)
        local function tab(label, mode, width)
            local selected = self.view_mode == mode
            local layers_tab = OverlapGroup:new{dimen = Geom:new{w = width, h = tab_h}, allow_mirroring = false}
            layers_tab[#layers_tab + 1] = Ui.textbox(label, width, tab_h, face("cfont", 10.8, 15.2), {
                bold = selected, alignment = "center", halign = "center", valign = "center",
                fgcolor = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
            })
            if selected then
                local line_w = math.max(UiScale.dp(38, 32, 58), math.floor(width * .28))
                layers_tab[#layers_tab + 1] = OffsetContainer:new{
                    x_off = math.floor((width - line_w) / 2), y_off = tab_h - UiScale.line("thick"),
                    LineWidget:new{background = Blitbuffer.COLOR_BLACK, dimen = Geom:new{w = line_w, h = UiScale.line("thick")}},
                }
            end
            return tappable(width, tab_h, layers_tab, function() self:_set_view_mode(mode) end)
        end
        local tabs = HorizontalGroup:new{align = "center",
            tab("全部书籍 " .. tostring(book_count), "books", tab_w),
            tab("文件夹 " .. tostring(folder_count), "folders", inner_w - tab_w),
        }
        self:_add(layers, margin, margin + header_h + UiScale.line("thin"), tabs)
    end

    local grid_y = margin + header_h + UiScale.line("thin") + (mixed_view and 0 or tab_h) + gap
    local grid_h = math.max(1, sh - grid_y - footer_h - margin)
    local col_gap = UiScale.dp(4, 3, 7)
    local row_gap = UiScale.dp(5, 4, 9)
    local card_w = math.floor((sw - margin * 2 - col_gap * (columns - 1)) / columns)
    local card_h = math.floor((grid_h - row_gap * (rows - 1)) / rows)
    self._visible_books = {}
    local slot = 0
    for _, entry in ipairs(pages[self.page] or {}) do
        local row = math.floor(slot / columns)
        local col = slot % columns
        if entry.kind == "folder" then
            self:_add(layers, margin + col * (card_w + col_gap), grid_y + row * (card_h + row_gap),
                folder_card(entry.value, card_w, card_h, function()
                    if self.opts and self.opts.on_open_folder then self.opts.on_open_folder(entry.value, self) end
                end))
            slot = slot + 1
        else
            self._visible_books[#self._visible_books + 1] = entry.value
            self:_add(layers, margin + col * (card_w + col_gap), grid_y + row * (card_h + row_gap),
                book_card(entry.value, card_w, card_h,
                    function() if self.opts and self.opts.on_open_book then self.opts.on_open_book(entry.value, self) end end,
                    function() if self.opts and self.opts.on_hold_book then self.opts.on_hold_book(entry.value, self) end end))
            slot = slot + 1
        end
    end

    if #(pages[self.page] or {}) == 0 then
        local empty_label = (self.opts and self.opts.mixed_view == true) and tostring(self.opts and self.opts.empty_text or "这个文件夹里没有可显示的书籍") or (self.view_mode == "folders" and "这个位置没有包含本地书的子文件夹" or tostring(self.opts and self.opts.empty_text or "这个文件夹里没有可显示的书籍"))
        self:_add(layers, margin, grid_y, Ui.textbox(empty_label,
            inner_w, grid_h, face("smallinfofont", 11, 15), {
                bold = true, alignment = "center", halign = "center", valign = "center",
            }))
    end

    local arrow_w = UiScale.dp(74, 66, 108)
    local middle_w = math.max(1, sw - margin * 2 - arrow_w * 2)
    local footer = HorizontalGroup:new{
        align = "center",
        tappable(arrow_w, footer_h, TextWidget:new{text = "‹", face = UiScale.iconFace("cfont", 18, 25), bold = true,
            fgcolor = self.page > 1 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY},
            self.page > 1 and function() self:_change_page(-1) end or nil),
        CenterContainer:new{dimen = Geom:new{w = middle_w, h = footer_h}, TextWidget:new{
            text = tostring(self.page) .. " / " .. tostring(self.pages), face = face("smallinfofont", 10.5, 14.5), bold = true,
        }},
        tappable(arrow_w, footer_h, TextWidget:new{text = "›", face = UiScale.iconFace("cfont", 18, 25), bold = true,
            fgcolor = self.page < self.pages and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY},
            self.page < self.pages and function() self:_change_page(1) end or nil),
    }
    self:_add(layers, margin, sh - margin - footer_h, footer)
    self[1] = layers
end

function LocalBrowserWidget:visibleBooks()
    local out = {}
    for _, book in ipairs(self._visible_books or {}) do out[#out + 1] = book end
    return out
end

function LocalBrowserWidget:_change_page(delta)
    local next_page = math.max(1, math.min(self.pages, self.page + (tonumber(delta) or 0)))
    if next_page == self.page then return true end
    self.page = next_page
    self:_build()
    UIManager:setDirty(self, "full")
    if self.opts and self.opts.on_page_changed then
        self.opts.on_page_changed(self.page, self:visibleBooks(), self)
    end
    return true
end
function LocalBrowserWidget:init()
    self.page = tonumber(self.opts and self.opts.page) or 1
    local folders = (self.opts and self.opts.folders) or {}
    local books = (self.opts and self.opts.books) or {}
    self.view_mode = (self.opts and self.opts.default_view == "folders") and "folders" or "books"
    if #books == 0 and #folders > 0 then self.view_mode = "folders" end
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        if Device.input and Device.input.group and Device.input.group.Back then self.key_events.Back = {{Device.input.group.Back}} end
        if Device.input and Device.input.group and Device.input.group.PgFwd then self.key_events.BrowserNext = {{Device.input.group.PgFwd}} end
        if Device.input and Device.input.group and Device.input.group.PgBack then self.key_events.BrowserPrevious = {{Device.input.group.PgBack}} end
    end
    self:_build()
end
function LocalBrowserWidget:updateItems()
    if self._miu_closed then return false end
    self:_build(); UIManager:setDirty(self, "full"); return true
end
function LocalBrowserWidget:updateData(snapshot)
    if self._miu_closed then return false end
    self.opts.folders = snapshot.folders or {}
    self.opts.books = snapshot.books or {}
    if not (self.opts and self.opts.mixed_view == true) then
        if self.view_mode == "folders" and #self.opts.folders == 0 and #self.opts.books > 0 then self.view_mode = "books" end
        if self.view_mode == "books" and #self.opts.books == 0 and #self.opts.folders > 0 then self.view_mode = "folders" end
    end
    self.page = 1
    self.opts.empty_text = snapshot.error and ("无法读取文件夹\n" .. tostring(snapshot.error)) or self.opts.empty_text
    self:_build()
    UIManager:setDirty(self, "full")
    if self.opts and self.opts.on_page_changed then
        self.opts.on_page_changed(self.page, self:visibleBooks(), self)
    end
    return true
end
function LocalBrowserWidget:onBrowserSwipe(_, ges)
    if ges and ges.direction == "west" then return self:_change_page(1) end
    if ges and ges.direction == "east" then return self:_change_page(-1) end
    return false
end
function LocalBrowserWidget:onBrowserNext() return self:_change_page(1) end
function LocalBrowserWidget:onBrowserPrevious() return self:_change_page(-1) end
function LocalBrowserWidget:onBack() return self:_back() end
function LocalBrowserWidget:onShow() UIManager:setDirty(self, "full") end
function LocalBrowserWidget:onCloseWidget()
    self._miu_closed = true
    self._dimension_generation=(tonumber(self._dimension_generation) or 0)+1
    if self._dimension_task then UIManager:unschedule(self._dimension_task); self._dimension_task=nil end
    if self.opts and self.opts.on_close then pcall(self.opts.on_close, self) end
end
function LocalBrowserWidget:_schedule_dimension_refresh()
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
function LocalBrowserWidget:onSetDimensions() return self:_schedule_dimension_refresh() end
function LocalBrowserWidget:onScreenResize() return self:_schedule_dimension_refresh() end
function LocalBrowserWidget:onRotation() return self:_schedule_dimension_refresh() end

local LocalBrowserView = {}
function LocalBrowserView.show(opts)
    local view = LocalBrowserWidget:new{opts = opts or {}}
    UIManager:show(view)
    return view
end
return LocalBrowserView
