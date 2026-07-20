local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

local function status_text(book)
    local state
    if book.downloaded then state = "已下载"
    elseif book.local_only then state = "仅本地"
    else state = "仅云端" end
    local progress = tonumber(book.progress or 0) or 0
    if progress >= 100 then return state .. " · 已读完" end
    if progress > 0 then return state .. " · " .. tostring(math.floor(progress + .5)) .. "%" end
    return state
end

local ShelfItem = InputContainer:extend{
    entry = nil,
    menu = nil,
    dimen = nil,
}

function ShelfItem:init()
    self.ges_events = {
        TapSelect = {GestureRange:new{ges="tap", range=self.dimen}},
        HoldSelect = {GestureRange:new{ges="hold", range=self.dimen}},
    }

    local h = self.dimen.h
    if self.entry and self.entry._miu_action_row then
        local divider = TextWidget:new{
            text="│",
            face=Font:getFace("smallinfofont", math.min(17, Screen:scaleBySize(15))),
            padding=0,
        }
        local divider_w = divider:getSize().w
        local half_w = math.max(1, math.floor((self.dimen.w - divider_w) / 2))
        local action_face = Font:getFace("cfont", math.min(20, Screen:scaleBySize(17)))
        local row = HorizontalGroup:new{
            align="center",
            CenterContainer:new{
                dimen=Geom:new{w=half_w, h=h},
                TextWidget:new{text="搜索书架", face=action_face, bold=true},
            },
            divider,
            CenterContainer:new{
                dimen=Geom:new{w=half_w, h=h},
                TextWidget:new{text="排序筛选", face=action_face, bold=true},
            },
        }
        self._underline = UnderlineContainer:new{
            dimen=self.dimen:copy(),
            linesize=Size.line.thin,
            color=Blitbuffer.COLOR_DARK_GRAY,
            padding=0,
            vertical_align="center",
            row,
        }
        self[1] = self._underline
        return
    end
    local side = math.max(Size.padding.small, Screen:scaleBySize(4))
    local show_cover = self.entry.show_cover ~= false
    local cover_h = math.max(Screen:scaleBySize(58), h - side * 2)
    local cover_w = show_cover and math.max(1, math.floor(cover_h * 0.69)) or 0
    local cover

    if show_cover and self.entry.cover_path then
        cover = ImageWidget:new{
            file=self.entry.cover_path,
            width=cover_w,
            height=cover_h,
            scale_factor=0,
            file_do_cache=true,
        }
    elseif show_cover then
        cover = FrameContainer:new{
            width=cover_w,
            height=cover_h,
            bordersize=Size.border.thin,
            padding=0,
            margin=0,
            background=Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen=Geom:new{w=cover_w, h=cover_h},
                TextWidget:new{text="", face=Font:getFace("smallinfofont", 12)},
            },
        }
    end

    local gap = show_cover and Size.padding.large or 0
    local text_w = math.max(Screen:scaleBySize(120), self.dimen.w - cover_w - gap - side * 2)
    local title = TextBoxWidget:new{
        text=tostring(self.entry.title or "未命名"),
        face=Font:getFace("cfont", math.min(22, Screen:scaleBySize(18))),
        width=text_w,
        height=math.floor(h * .52),
        height_adjust=true,
        height_overflow_show_ellipsis=true,
        alignment="left",
        bold=true,
    }

    local details = tostring(self.entry.author or "")
    if details ~= "" and tostring(self.entry.status or "") ~= "" then details = details .. " · " end
    details = details .. tostring(self.entry.status or "")
    local info = TextBoxWidget:new{
        text=details,
        face=Font:getFace("smallinfofont", math.min(17, Screen:scaleBySize(14))),
        width=text_w,
        height=math.floor(h * .30),
        height_adjust=true,
        height_overflow_show_ellipsis=true,
        alignment="left",
        fgcolor=Blitbuffer.COLOR_DARK_GRAY,
    }

    local text_group = VerticalGroup:new{
        align="left",
        title,
        VerticalSpan:new{height=math.max(1, Screen:scaleBySize(2))},
        info,
    }
    local row = HorizontalGroup:new{
        align="center",
        HorizontalSpan:new{width=side},
    }
    if cover then
        table.insert(row, cover)
        table.insert(row, HorizontalSpan:new{width=gap})
    end
    table.insert(row, LeftContainer:new{dimen=Geom:new{w=text_w, h=h}, text_group})
    table.insert(row, HorizontalSpan:new{width=side})

    self._underline = UnderlineContainer:new{
        dimen=self.dimen:copy(),
        linesize=Size.line.thin,
        color=Blitbuffer.COLOR_DARK_GRAY,
        padding=0,
        vertical_align="center",
        row,
    }
    self[1] = self._underline
end

function ShelfItem:onTapSelect(arg, ges)
    local pos
    local dimen = self[1] and self[1].dimen
    if dimen and ges and ges.pos then
        pos = {
            x=(ges.pos.x - dimen.x) / math.max(1, dimen.w),
            y=(ges.pos.y - dimen.y) / math.max(1, dimen.h),
        }
    end
    self.menu:onMenuSelect(self.entry, pos)
    return true
end

function ShelfItem:onHoldSelect()
    if self.entry and self.entry.hold_callback then self.entry.hold_callback() end
    return true
end

function ShelfItem:onFocus()
    self._underline.color = Blitbuffer.COLOR_BLACK
    return true
end

function ShelfItem:onUnfocus()
    self._underline.color = Blitbuffer.COLOR_DARK_GRAY
    return true
end

local ShelfMenu = Menu:extend{
    on_page_changed = nil,
    on_close_callback = nil,
    _miu_closed = false,
    _suppress_page_callback = false,
}

function ShelfMenu:onMenuSelect(entry, pos)
    if entry and entry._miu_action_row then
        local callback
        if pos and tonumber(pos.x) and pos.x >= 0.5 then
            callback = entry.sort_callback
        elseif pos then
            callback = entry.search_callback
        else
            callback = entry.sort_callback or entry.search_callback
        end
        if callback then callback() end
        return true
    end
    return Menu.onMenuSelect(self, entry)
end

function ShelfMenu:updateItems(select_number, no_recalculate_dimen)
    local old_dimen = self.dimen and self.dimen:copy()
    self.layout = {}
    self.item_group:clear()
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()
    Menu._recalculateDimen(self, no_recalculate_dimen)
    local offset = (self.page - 1) * self.perpage
    for index_on_page = 1, self.perpage do
        local index = offset + index_on_page
        local entry = self.item_table[index]
        if not entry then break end
        entry.idx = index
        if index == self.itemnumber then select_number = index_on_page end
        local item = ShelfItem:new{
            entry=entry,
            menu=self,
            dimen=self.item_dimen:copy(),
        }
        table.insert(self.item_group, item)
        table.insert(self.layout, {item})
    end
    self:updatePageInfo(select_number)
    self:mergeTitleBarIntoLayout()
    UIManager:setDirty(self.show_parent, function()
        return "ui", old_dimen and old_dimen:combine(self.dimen) or self.dimen
    end)
    if not self._suppress_page_callback and not self._miu_closed and self.on_page_changed then
        local page = tonumber(self.page) or 1
        local first = (page - 1) * self.perpage + 1
        local last = math.min(#self.item_table, first + self.perpage - 1)
        UIManager:scheduleIn(0, function()
            if not self._miu_closed and self.on_page_changed then
                pcall(self.on_page_changed, page, first, last, self)
            end
        end)
    end
end

function ShelfMenu:onCloseWidget()
    self._miu_closed = true
    if self.on_close_callback then
        local callback = self.on_close_callback
        self.on_close_callback = nil
        pcall(callback, self)
    end
    if Menu.onCloseWidget then return Menu.onCloseWidget(self) end
end

local ShelfView = {}

function ShelfView.show(opts)
    opts = opts or {}
    local items = {}
    local action_count = 0
    if opts.show_actions ~= false and (opts.on_search or opts.on_sort) then
        action_count = 1
        items[#items + 1] = {
            _miu_action_row=true,
            search_callback=opts.on_search,
            sort_callback=opts.on_sort,
        }
    end
    for _, book in ipairs(opts.books or {}) do
        items[#items + 1] = {
            book_id=book.bookId or book.book_id,
            title=book.title,
            author=book.author,
            status=status_text(book),
            cover_path=book.cover_path,
            show_cover=opts.show_covers ~= false,
            callback=function() if opts.on_select then opts.on_select(book) end end,
            hold_callback=function() if opts.on_hold then opts.on_hold(book) end end,
        }
    end
    local page_callback
    if opts.on_page_changed then
        page_callback=function(page, first, last, current)
            local book_first = math.max(1, (tonumber(first) or 1) - action_count)
            local book_last = math.min(#(opts.books or {}), (tonumber(last) or 0) - action_count)
            if book_last >= book_first then
                opts.on_page_changed(page, book_first, book_last, current)
            end
        end
    end
    local menu = ShelfMenu:new{
        title=opts.title or "书架",
        item_table=items,
        items_per_page=action_count > 0 and 8 or 7,
        is_borderless=true,
        title_bar_fm_style=true,
        on_page_changed=page_callback,
        on_close_callback=opts.on_close,
    }
    UIManager:show(menu)
    return menu
end

return ShelfView
