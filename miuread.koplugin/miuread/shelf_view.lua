local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local GestureBridge = require("miuread.gesture_bridge")
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
local logger = require("logger")
local U = require("miuread.util")
local UiScale = require("miuread.ui_scale")

local Screen = Device.screen
local DIVIDER_COLOR = Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_DARK_GRAY
local function face(name, nominal, maximum, minimum) return UiScale.face(name, nominal, maximum, minimum) end

local function status_text(book)
    if book.status_text and tostring(book.status_text)~="" then return tostring(book.status_text) end
    if book.download_status and tostring(book.download_status)~="" then return tostring(book.download_status) end
    local progress = tonumber(book.progress or 0) or 0
    if progress >= 100 then return "已读完" end
    if progress > 0 then return "阅读 " .. tostring(math.floor(progress + .5)) .. "%" end
    return "未开始"
end

local function supported_image(path)
    path=tostring(path or "")
    if path=="" then return false end
    local ok,registry=pcall(require,"document/documentregistry")
    if ok and registry and type(registry.isImageFile)=="function" then
        local checked,value=pcall(registry.isImageFile,registry,path)
        if checked then return value==true end
    end
    local ext=path:lower():match("%.([%w]+)$")
    return ext=="png" or ext=="jpg" or ext=="jpeg" or ext=="gif"
        or ext=="webp" or ext=="svg"
end

local function placeholder(cover_w,cover_h,title)
    local mark=U.utf8_sub(tostring(title or "书"):gsub("^%s+",""),1,1)
    if mark=="" then mark="书" end
    local border=Size.border.thin
    return FrameContainer:new{
        bordersize=border,
        padding=0,
        margin=0,
        background=Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen=Geom:new{
                w=math.max(1,cover_w-border*2),
                h=math.max(1,cover_h-border*2),
            },
            TextWidget:new{text=mark, face=face("cfont", 15, 19)},
        },
    }
end

local function safe_cover(path,cover_w,cover_h,book_id)
    if not supported_image(path) then return nil,"unsupported" end
    local image
    local ok,err=pcall(function()
        image=ImageWidget:new{
            file=path,
            width=cover_w,
            height=cover_h,
            scale_factor=0,
            file_do_cache=false,
        }
        image:getSize()
        image.width=nil
        image.height=nil
    end)
    if ok and image then
        return CenterContainer:new{dimen=Geom:new{w=cover_w,h=cover_h},image}
    end
    if image and type(image.free)=="function" then pcall(image.free,image) end
    logger.warn("[MiuRead][Cover] render failed","book_id=",tostring(book_id or ""),"path=",tostring(path),"error=",tostring(err))
    return nil,tostring(err or "render failed")
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
    if self.entry and (self.entry._miu_action_row or self.entry._miu_tab_row) then
        local row_face=face("cfont", self.entry._miu_tab_row and 13 or 12, self.entry._miu_tab_row and 17 or 16)
        local row=HorizontalGroup:new{align="center"}
        if self.entry._miu_tab_row then
            local tabs=type(self.entry.tabs)=="table" and self.entry.tabs or {}
            local count=math.max(1,#tabs)
            local gap=count>1 and math.max(Size.padding.small,Screen:scaleBySize(5)) or 0
            local width=math.max(1,math.floor((self.dimen.w-gap*(count-1))/count))
            for index,tab in ipairs(tabs) do
                local selected=tostring(self.entry.selected_tab or "")==tostring(tab.id or index)
                local text=(selected and "●  " or "")..tostring(tab.label or tab.id or index)
                table.insert(row,CenterContainer:new{
                    dimen=Geom:new{w=width,h=h},
                    TextWidget:new{text=text,face=row_face,bold=selected},
                })
                if index<count then table.insert(row,HorizontalSpan:new{width=gap}) end
            end
        else
            local gap=math.max(Size.padding.small,Screen:scaleBySize(8))
            local half_w=math.max(1,math.floor((self.dimen.w-gap)/2))
            table.insert(row,CenterContainer:new{dimen=Geom:new{w=half_w,h=h},TextWidget:new{text=tostring(self.entry.left_label or "搜索书架"),face=row_face}})
            table.insert(row,HorizontalSpan:new{width=gap})
            table.insert(row,CenterContainer:new{dimen=Geom:new{w=half_w,h=h},TextWidget:new{text=tostring(self.entry.right_label or "刷新书架"),face=row_face}})
        end
        self._underline=UnderlineContainer:new{
            dimen=self.dimen:copy(),linesize=UiScale.line("thin"),color=DIVIDER_COLOR,
            padding=0,vertical_align="center",row,
        }
        self[1]=self._underline
        return
    end
    local side = math.max(Size.padding.small, UiScale.dp(3, 3, 7))
    local show_cover = self.entry.show_cover ~= false
    local cover_h = math.max(UiScale.dp(46, 42, 62), h - side * 2)
    local cover_w = show_cover and math.max(1, math.floor(cover_h * 0.69)) or 0
    local cover

    if show_cover and self.entry.cover_path then
        cover=safe_cover(self.entry.cover_path,cover_w,cover_h,self.entry.book_id)
    end
    if show_cover and not cover then cover=placeholder(cover_w,cover_h,self.entry.title) end

    local gap = show_cover and Size.padding.large or 0
    local text_w = math.max(Screen:scaleBySize(96), self.dimen.w - cover_w - gap - side * 2)
    local title = TextBoxWidget:new{
        text=tostring(self.entry.title or "未命名"),
        face=face("cfont", 14, 18),
        width=text_w,
        height=math.floor(h * .50),
        height_adjust=false,
        height_overflow_show_ellipsis=true,
        alignment="left",
        bold=true,
    }

    local details = tostring(self.entry.author or "")
    if details ~= "" and tostring(self.entry.status or "") ~= "" then details = details .. " · " end
    details = details .. tostring(self.entry.status or "")
    local info = TextBoxWidget:new{
        text=details,
        face=face("smallinfofont", 10, 13),
        width=text_w,
        height=math.floor(h * .28),
        height_adjust=false,
        height_overflow_show_ellipsis=true,
        alignment="left",
        fgcolor=Blitbuffer.COLOR_DARK_GRAY,
    }

    local text_group = VerticalGroup:new{
        align="left",
        title,
        VerticalSpan:new{height=UiScale.dp(2, 1, 4)},
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
        linesize=UiScale.line("thin"),
        color=DIVIDER_COLOR,
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

function ShelfItem:onHoldSelect(arg, ges)
    if self.menu and self.menu.onMenuHold then
        self.menu:onMenuHold(self.entry)
    end
    return true
end

function ShelfItem:onFocus()
    self._underline.color = Blitbuffer.COLOR_BLACK
    return true
end

function ShelfItem:onUnfocus()
    self._underline.color = DIVIDER_COLOR
    return true
end

local ShelfMenu = Menu:extend{
    _miuread_transient = true,
    on_select_callback = nil,
    on_hold_callback = nil,
    on_page_changed = nil,
    on_close_callback = nil,
    on_rendered_callback = nil,
    _miu_closed = false,
    _suppress_page_callback = false,
}

function ShelfMenu:handleEvent(event)
    return GestureBridge.handle(Menu, self, event)
end

function ShelfMenu:onMenuSelect(entry, pos)
    if entry and (entry._miu_action_row or entry._miu_tab_row) then
        local callback
        if entry._miu_tab_row then
            local tabs=type(entry.tabs)=="table" and entry.tabs or {}
            if #tabs>0 then
                local x=pos and tonumber(pos.x) or 0
                local index=math.floor(math.max(0,math.min(.999999,x))*#tabs)+1
                callback=tabs[index] and tabs[index].callback or nil
                if not callback then
                    for _,tab in ipairs(tabs) do if tab.callback then callback=tab.callback; break end end
                end
            end
        elseif pos and tonumber(pos.x) and pos.x >= 0.5 then
            callback=entry.right_callback or entry.refresh_callback
        elseif pos then
            callback=entry.left_callback or entry.search_callback
        else
            callback=entry.right_callback or entry.refresh_callback or entry.left_callback or entry.search_callback
        end
        if callback then callback() end
        return true
    end
    if entry and entry.book and self.on_select_callback then
        self.on_select_callback(entry.book)
        return true
    end
    return Menu.onMenuSelect(self,entry)
end

function ShelfMenu:onMenuHold(entry)
    if entry and entry.book and self.on_hold_callback then
        self.on_hold_callback(entry.book)
        return true
    end
    return true
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
    if self.on_rendered_callback and not self._miu_closed then
        local callback=self.on_rendered_callback
        UIManager:scheduleIn(0,function()
            if not self._miu_closed and callback then pcall(callback,self) end
        end)
    end
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
    opts=opts or {}
    local items={}
    local action_count=0
    local tabs=opts.tabs
    if type(tabs)~="table" and (opts.on_account_tab or opts.on_generated_tab) then
        tabs={
            {id="account",label="账号书架",callback=opts.on_account_tab},
            {id="generated",label="已生成书籍",callback=opts.on_generated_tab},
        }
    end
    if opts.show_tabs~=false and type(tabs)=="table" and #tabs>0 then
        action_count=action_count+1
        items[#items+1]={
            _miu_tab_row=true,
            selected_tab=opts.selected_tab or tostring(tabs[1].id or 1),
            tabs=tabs,
        }
    end
    if opts.show_actions~=false and (opts.on_search or opts.on_refresh or opts.on_left_action or opts.on_right_action) then
        action_count=action_count+1
        items[#items+1]={
            _miu_action_row=true,
            left_label=opts.left_action_label or "搜索书架",
            right_label=opts.right_action_label or "刷新书架",
            left_callback=opts.on_left_action or opts.on_search,
            right_callback=opts.on_right_action or opts.on_refresh,
            search_callback=opts.on_search,
            refresh_callback=opts.on_refresh,
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
            book=book,
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
        items_per_page=8+action_count,
        is_borderless=true,
        title_bar_fm_style=true,
        on_select_callback=opts.on_select,
        on_hold_callback=opts.on_hold,
        on_page_changed=page_callback,
        on_close_callback=opts.on_close,
        on_rendered_callback=opts.on_rendered,
    }
    UIManager:show(menu)
    return menu
end

return ShelfView
