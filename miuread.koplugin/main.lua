local ButtonDialog=require("ui/widget/buttondialog")
local ConfirmBox=require("ui/widget/confirmbox")
local Event=require("ui/event")
local Dispatcher=require("dispatcher")
local InfoMessage=require("ui/widget/infomessage")
local InputDialog=require("ui/widget/inputdialog")
local Menu=require("ui/widget/menu")
local PathChooser=require("ui/widget/pathchooser")
local UIManager=require("ui/uimanager")
local WidgetContainer=require("ui/widget/container/widgetcontainer")
local logger=require("logger")
local lfs=require("libs/libkoreader-lfs")
local Config=require("miuread.config")
local Text=require("miuread.text")
local U=require("miuread.util")
local Store=require("miuread.store")
local Http=require("miuread.http")
local Api=require("miuread.api")
local Auth=require("miuread.auth")
local Reader=require("miuread.reader")
local Annotations=require("miuread.annotations")
local Downloader=require("miuread.downloader")
local DownloadProgress=require("miuread.download_progress")
local DownloadTask=require("miuread.download_task")
local CacheCleanupTask=require("miuread.cache_cleanup_task")
local EpubStyleRepairTask=require("miuread.epub_style_repair_task")
local Library=require("miuread.library")
local ShelfView=require("miuread.shelf_view")
local Async=require("miuread.async")
local Sync=require("miuread.sync")
local Updater=require("miuread.updater")
local Cookies=require("miuread.cookies")
local Thoughts=require("miuread.thoughts")
local ThoughtPopup=require("miuread.thought_popup")
local StatusToast=require("miuread.status_toast")
local _=Text.tr
local unpack_args=unpack or table.unpack
local source=debug.getinfo(1,"S").source:gsub("^@",""); local ROOT=source:match("^(.*)/main%.lua$") or "."
local Plugin=WidgetContainer:extend{name="miuread",is_doc_only=false,version=Config.VERSION}
local function normalize(v) local b=v.bookInfo or v.book or v; return {bookId=tostring(b.bookId or v.bookId or ""),title=b.title or v.title or "未命名",author=b.author or v.author or "",cover=b.cover or v.cover,category=b.category or v.category,progress=tonumber(v.progress or b.progress or 0) or 0,updateTime=tonumber(v.updateTime or b.updateTime or 0) or 0} end
local function sanitize_saved_auth(store)
    local auth=store:auth()
    local cleaned,changed=Cookies.sanitize(auth.cookies or {})
    if changed then
        auth.cookies=cleaned
        store:save_auth(auth)
        logger.info("[MiuRead][Auth] startup cookie cleanup",
            "names=",table.concat(Cookies.names(cleaned),","))
    end
end
function Plugin:init()
    math.randomseed(os.time()+math.floor(collectgarbage("count"))); self.store=Store:new(); sanitize_saved_auth(self.store); self.http=Http:new(self.store); self.api=Api:new(self.http,self.store); self.reader=Reader:new(self.http,self.store); self.annotations=Annotations:new(self.api); self.downloader=Downloader:new(self.reader,self.api,self.annotations,self.store,self.http); self.download_task=DownloadTask:new(self.store); self.cache_cleanup_task=CacheCleanupTask:new(self.store); self.epub_style_repair_task=EpubStyleRepairTask:new(self.store); self.library=Library:new(self.api,self.http,self.store); self.async=Async:new(self.store); self.search_async=Async:new(self.store,{poll_interval=.4}); self.shelf_async=Async:new(self.store,{poll_interval=.4}); self.cover_async=Async:new(self.store); self.auth_flow=Auth:new(self.http,self.store,self); self.sync=Sync:new(self.reader,self.api,self.store,self,self.async); self.updater=Updater:new(self.http,self.store,self.version,ROOT); self._suspended_at=nil; self._cover_generation=0; self._shelf_view=nil; self._last_shelf_mode=false; self._shelf_refresh_generation=0; self._downloads_menu=nil; self._download_book_menu=nil; self._cache_cleanup_dialog=nil; self._epub_style_repair_dialog=nil
    self:onDispatcherRegisterActions(); self.ui.menu:registerToMainMenu(self); local state=self.updater:startup(); if state=="updated" then UIManager:scheduleIn(1,function() self:toast(_("Update installed"),3) end) end
end
function Plugin:onDispatcherRegisterActions() Dispatcher:registerAction("miuread_show",{category="none",event="ShowMiuRead",title=Config.NAME,filemanager=true,reader=true}) end
function Plugin:addToMainMenu(items) items.miuread={text=Config.NAME,sorting_hint="tools",sub_item_table_func=function() return self.ui.document and self:reader_menu() or self:home_menu() end} end
function Plugin:info(t) UIManager:show(InfoMessage:new{text=tostring(t or "")}) end
function Plugin:toast(t,s) UIManager:show(InfoMessage:new{text=tostring(t or ""),timeout=s or 2}) end
function Plugin:status_toast(title,text,timeout)
    local ok,err=pcall(StatusToast.show,{
        title=tostring(title or ""),
        text=tostring(text or ""),
        timeout=timeout or 3,
    })
    if not ok then
        logger.warn("[MiuRead] status toast failed",tostring(err))
        self:toast(tostring(title or "").." · "..tostring(text or ""):gsub("%s+"," "),timeout or 3)
    end
end
function Plugin:safe(label,fn) return function(...) local a={...}; local ok,e=xpcall(function() return fn(unpack_args(a)) end,debug.traceback); if not ok then logger.err("[MiuRead]",label,e); self:info(_("Operation failed")..":\n"..U.first_line(e)) end end end
function Plugin:is_online() local ok,N=pcall(require,"ui/network/manager"); if not ok or not N or not N.isOnline then return true end; local g,v=pcall(N.isOnline,N); return not g or v==true end
function Plugin:online(label,fn) if not self:is_online() then self:info(_("Network unavailable")); return end; UIManager:scheduleIn(.05,self:safe(label,fn)) end
function Plugin:run_online(label,fn) return self:online(label,fn) end
function Plugin:list(title,items,empty) if not items or #items==0 then self:info(empty or _("No items")); return end; UIManager:show(Menu:new{title=title,item_table=items,is_borderless=true,title_bar_fm_style=true}) end
function Plugin:logged_in() local a=self.store:auth(); return a.api_key~="" and next(a.cookies or {})~=nil end
function Plugin:require_login() if not self:logged_in() then self:info(_("Not logged in")); return false end return true end
function Plugin:home_menu()
    return {
        {text=_("My bookshelf"),callback=self:safe("shelf",function() self:show_shelf(false) end)},
        {text="搜索书架",callback=self:safe("shelf_search",function() self:show_shelf_search_dialog(false) end)},
        {text="搜索微信读书",callback=self:safe("search",function() self:search_dialog() end)},
        {text=_("Downloads and cache"),callback=self:safe("cache",function() self:show_downloads() end)},
        {text=_("Reading sync"),sub_item_table_func=function() return self:sync_menu() end},
        {text=_("Settings"),sub_item_table_func=function() return self:settings_menu() end},
    }
end
function Plugin:reader_menu()
    return {
        {text="阅读时间同步 · "..self.sync:status_label(),checked_func=function() return self.store:preferences().sync.time_enabled end,keep_menu_open=true,callback=function() self:toggle_time_sync() end},
        {text="阅读时间同步弹窗提醒",checked_func=function() return self.store:preferences().sync.time_notice_enabled~=false end,keep_menu_open=true,callback=function() self:toggle_time_notice() end},
        {text="阅读进度同步 · "..self:progress_sync_label(),checked_func=function() return self.store:preferences().sync.progress_enabled~=false end,keep_menu_open=true,callback=function() self:toggle_progress_sync() end},
        {text="查看同步状态",callback=function() self:show_sync_status(false) end},
        {text=_("Return to MiuRead bookshelf"),callback=self:safe("shelf",function() self:show_shelf(false) end)},
        {text=_("Redownload current book"),callback=self:safe("redownload",function() self:redownload_current() end)},
        {text="阅读设置",sub_item_table_func=function() return self:reading_settings_menu() end},
        {text=_("Advanced"),sub_item_table_func=function() return self:sync_advanced_menu(true) end},
    }
end
function Plugin:account_menu()
    local out={{text=_("QR login"),callback=self:safe("login",function() self.auth_flow:start() end)},{text=_("Manual credentials"),callback=self:safe("manual",function() self:manual_credentials() end)},{text=_("Account status"),callback=function() local a=self.store:auth(); self:info((self:logged_in() and _("Logged in") or _("Not logged in")).."\n"..tostring(a.account.name or "").."\nVID: "..tostring(a.account.vid or "")) end}}
    if self:logged_in() then out[#out+1]={text=_("Clear account data"),callback=function() UIManager:show(ConfirmBox:new{text="清除当前账户信息？\n\n将退出微信读书账户，但不会删除已下载书籍。",ok_callback=function() self.auth_flow:cancel(); self.store:clear_auth(); self:toast(_("Logout")) end}) end} end; return out
end
function Plugin:manual_credentials()
    local d; d=InputDialog:new{title=_("Enter API key"),input=self.store:auth().api_key or "",buttons={{{text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},{text=_("Confirm"),is_enter_default=true,callback=function() local key=U.trim(d:getInputText()); UIManager:close(d); self:manual_cookie(key) end}}}}; UIManager:show(d); d:onShowKeyboard()
end
function Plugin:manual_cookie(key)
    local d; d=InputDialog:new{title=_("Enter Cookie header"),input="",buttons={{{text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},{text=_("Confirm"),is_enter_default=true,callback=function() local jar=Cookies.parse_header(d:getInputText()); self.store:save_auth({api_key=key,cookies=jar,account={name="Manual",vid=jar.wr_vid or "",logged_at=os.time()}}); UIManager:close(d); self:toast(_("Logged in")) end}}}}; UIManager:show(d); d:onShowKeyboard()
end
local SORT_LABELS={read="最近阅读",download="最近下载",update="最近更新",title="书名",author="作者",progress="阅读进度"}
local SCOPE_LABELS={all="全部",downloaded="已下载",unread="未开始",reading="阅读中",finished="已读完"}
function Plugin:_shelf_summary()
    local p=self.store:preferences()
    return tostring(SCOPE_LABELS[p.shelf_scope] or "全部").." · "
        ..tostring(SORT_LABELS[p.shelf_sort] or "最近阅读")
end
function Plugin:show_shelf_tabs()
    self:list(_("My bookshelf"),{
        {text=_("Books"),post_text=self:_shelf_summary(),callback=function() self:show_shelf(false) end},
        {text=_("Official accounts"),callback=function() self:show_shelf(true) end},
        {text="搜索书架",callback=function() self:show_shelf_search_dialog(self._last_shelf_mode or false) end},
        {text="排序和筛选",post_text=self:_shelf_summary(),callback=function() self:show_shelf_controls(self._last_shelf_mode or false) end},
    })
end
function Plugin:_friendly_remote_error(err, context)
    local text=tostring(err or "未知错误")
    local lower=text:lower()
    if lower:find("http 401",1,true) or lower:find("http 403",1,true)
        or lower:find("api key",1,true) or lower:find("authorization",1,true) then
        return "登录凭证已失效或被拒绝，请在账户设置中重新扫码登录。"
    end
    if lower:find("timeout",1,true) then return "网络请求超时，请检查 Wi-Fi 后重试。" end
    if lower:find("network request failed",1,true) then return "网络连接失败，请检查 Wi-Fi 后重试。" end
    return tostring(context or "请求").."失败：\n"..U.first_line(text,180)
end

function Plugin:_refresh_shelf_async(on_ready,silent)
    local function fail(err)
        local message=self:_friendly_remote_error(err,"书架加载")
        if on_ready then
            on_ready({}, {}, message)
        elseif not silent or message:find("重新扫码登录",1,true) then
            self:toast(message,4)
        end
        return false,err
    end
    if not self:is_online() then
        return fail("network request failed: offline")
    end
    if not self.shelf_async or not self.shelf_async:available() then
        return fail("当前设备不支持后台书架刷新。")
    end
    if self.shelf_async:busy() then
        return fail("书架正在刷新，请稍后重试。")
    end
    self._shelf_refresh_generation=(tonumber(self._shelf_refresh_generation) or 0)+1
    local generation=self._shelf_refresh_generation
    local auth=U.copy(self.store:auth())
    local started,err=self.shelf_async:run("shelf_refresh",function()
        local HttpChild=require("miuread.http")
        local ApiChild=require("miuread.api")
        local UtilChild=require("miuread.util")
        local child_store={
            auth=function() return UtilChild.copy(auth) end,
            save_auth=function() end,
        }
        return ApiChild:new(HttpChild:new(child_store),child_store):shelf()
    end,function(result)
        if generation~=self._shelf_refresh_generation then return end
        if result and result.ok==true then
            local books,mp=self.library:normalize(result.value or {})
            self.store:save_shelf_cache({books=books,mp=mp,updated_at=os.time()})
            if on_ready then on_ready(books,mp,nil) end
            return
        end
        fail(result and result.error or "未知错误")
    end,32)
    if not started then return fail(err or "无法启动异步任务") end
    return true
end

function Plugin:load_shelf(cb,force_remote)
    local cached_books,cached_mp=self.library:cached()
    local library_snapshot=self.store:library()
    local local_books,local_mp=self.library:local_books(library_snapshot,self.store:get("sessions",{}))
    if not force_remote then
        if #cached_books+#cached_mp>0 then
            cb(cached_books,cached_mp,nil)
            if self:logged_in() then self:_refresh_shelf_async(nil,true) end
            return
        end
        if #local_books+#local_mp>0 then
            self:toast("云端书架暂未加载，先显示本地书籍。",3)
            cb({}, {}, nil)
            if self:logged_in() then self:_refresh_shelf_async(nil,true) end
            return
        end
    end
    if not self:logged_in() then
        cb(cached_books,cached_mp,"当前未登录，只显示本地和已缓存书架。")
        return
    end
    self:_refresh_shelf_async(function(books,mp,err)
        if err and #cached_books+#cached_mp>0 then cb(cached_books,cached_mp,err) else cb(books,mp,err) end
    end,false)
end

function Plugin:_combined_shelf_rows(mp_mode,remote_books,remote_mp)
    if remote_books==nil or remote_mp==nil then remote_books,remote_mp=self.library:cached() end
    local library_snapshot=self.store:library()
    local sessions=self.store:get("sessions",{})
    local books,mp=self.library:combined(remote_books or {},remote_mp or {},library_snapshot,sessions)
    return mp_mode and mp or books
end

function Plugin:_prepare_shelf_rows(rows)
    local cover_index=self.store:get("cover_index",{})
    for _,b in ipairs(rows or {}) do
        b.cover_path=self.library:cached_cover_path(b.bookId,cover_index)
    end
    return rows
end

function Plugin:_shelf_status_text(b)
    local state=b.file_missing and "文件丢失" or (b.downloaded and "已下载" or (b.local_only and "仅本地" or "仅云端"))
    local progress=tonumber(b.progress or 0) or 0
    if progress>=100 then return state.." · 已读完" end
    if progress>0 then return state.." · "..tostring(math.floor(progress+.5)).."%" end
    return state
end

function Plugin:_shelf_select(b)
    local available={}
    for _,kind in ipairs({"notes","clean"}) do
        local r=self.store:variant(b.bookId,kind)
        if r and r.file and U.file_exists(r.file) then available[#available+1]=r end
    end
    if #available==1 then self:open_file(available[1].file) else self:book_menu(b) end
end

function Plugin:show_shelf_search_dialog(mp_mode,source_rows)
    source_rows=source_rows or self:_combined_shelf_rows(mp_mode)
    local d
    d=InputDialog:new{
        title="搜索书架",input="",
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},
            {text=_("Search"),is_enter_default=true,callback=function()
                local q=U.trim(d:getInputText())
                UIManager:close(d)
                if q=="" then return end
                local results=self.library:search(source_rows,q)
                if #results==0 then self:info("没有找到相关书籍") return end
                self:_prepare_shelf_rows(results)
                local prefs=self.store:preferences()
                local ok,view=pcall(ShelfView.show,{
                    title="搜索 · "..q.." · "..tostring(#results).."本",
                    books=results,
                    show_actions=false,
                    show_covers=prefs.shelf_covers~=false and not prefs.low_resource,
                    on_select=function(b) self:_shelf_select(b) end,
                    on_hold=function(b) self:book_menu(b) end,
                    on_page_changed=function(page,first,last,current)
                        if prefs.shelf_covers~=false and not prefs.low_resource then self:_on_shelf_page(results,current,page,first,last) end
                    end,
                    on_close=function()
                        self:_cancel_cover_loading()
                        collectgarbage("step",120)
                    end,
                })
                if ok and view then return end
                logger.warn("[MiuRead][ShelfSearch] custom view unavailable",tostring(view))
                local items={}
                for _,book in ipairs(results) do
                    local b=book
                    items[#items+1]={
                        text=(b.downloaded and "✓ " or "")..tostring(b.title or "未命名"),
                        post_text=(tostring(b.author or "")~="" and (tostring(b.author).." · ") or "")..self:_shelf_status_text(b),
                        callback=function() self:_shelf_select(b) end,
                        hold_callback=function() self:book_menu(b) end,
                    }
                end
                self:list("搜索书架 · "..q,items)
            end},
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
end
function Plugin:_cancel_cover_loading()
    self._cover_generation=(tonumber(self._cover_generation) or 0)+1
    if self.cover_async then self.cover_async:cancel("shelf page changed") end
end
function Plugin:_cache_shelf_page_covers(rows,view,page,first,last,generation,index)
    index=index or first
    if generation~=self._cover_generation or not view or view._miu_closed or tonumber(view.page or 1)~=tonumber(page) then return end
    if index>last then return end
    local book=rows[index]
    if not book or not book.cover or book.cover=="" then
        UIManager:scheduleIn(.03,function() self:_cache_shelf_page_covers(rows,view,page,first,last,generation,index+1) end)
        return
    end
    local cached=book.cover_path or self.library:cached_cover_path(book.bookId)
    if cached then
        book.cover_path=cached
        local changed=false
        for _,entry in ipairs(view.item_table or {}) do
            if tostring(entry.book_id)==tostring(book.bookId) then
                if entry.cover_path~=cached then entry.cover_path=cached; changed=true end
                break
            end
        end
        if changed then
            view._suppress_page_callback=true
            pcall(view.updateItems,view,nil,true)
            view._suppress_page_callback=false
        end
        UIManager:scheduleIn(.03,function() self:_cache_shelf_page_covers(rows,view,page,first,last,generation,index+1) end)
        return
    end
    if self.cover_async:busy() then
        UIManager:scheduleIn(.25,function() self:_cache_shelf_page_covers(rows,view,page,first,last,generation,index) end)
        return
    end
    local book_copy={bookId=book.bookId,cover=book.cover}
    local started=self.cover_async:run("shelf_cover_page",function()
        local StoreChild=require("miuread.store")
        local HttpChild=require("miuread.http")
        local ApiChild=require("miuread.api")
        local LibraryChild=require("miuread.library")
        local store=StoreChild:new(); local http=HttpChild:new(store)
        return LibraryChild:new(ApiChild:new(http,store),http,store):cache_cover(book_copy)
    end,function(result)
        if generation~=self._cover_generation or not view or view._miu_closed or tonumber(view.page or 1)~=tonumber(page) then return end
        if result and result.ok and result.value then
            book.cover_path=result.value
            for _,entry in ipairs(view.item_table or {}) do if tostring(entry.book_id)==tostring(book.bookId) then entry.cover_path=result.value; break end end
            view._suppress_page_callback=true
            pcall(view.updateItems,view,nil,true)
            view._suppress_page_callback=false
            collectgarbage("step",120)
        end
        self:_cache_shelf_page_covers(rows,view,page,first,last,generation,index+1)
    end,35)
    if not started then UIManager:scheduleIn(.3,function() self:_cache_shelf_page_covers(rows,view,page,first,last,generation,index) end) end
end
function Plugin:_on_shelf_page(rows,view,page,first,last)
    self:_cancel_cover_loading()
    local generation=self._cover_generation
    self:_cache_shelf_page_covers(rows,view,page,first,last,generation,first)
end
function Plugin:_close_current_shelf()
    local view=self._shelf_view
    self._shelf_view=nil
    self:_cancel_cover_loading()
    if view and not view._miu_closed then pcall(function() UIManager:close(view) end) end
end
function Plugin:_reopen_shelf(mp_mode)
    UIManager:scheduleIn(0,function() self:_close_current_shelf(); self:show_shelf(mp_mode) end)
end
function Plugin:show_shelf(mp_mode,force_remote)
    self._last_shelf_mode=mp_mode==true
    self:load_shelf(function(remote_books,remote_mp,remote_error)
        local all_rows=self:_combined_shelf_rows(mp_mode,remote_books,remote_mp)
        local rows=self.library:sort_filter(all_rows)
        self:_prepare_shelf_rows(rows)
        local prefs=self.store:preferences()
        local base_title=mp_mode and "公众号" or "书架"
        local scope_label=SCOPE_LABELS[prefs.shelf_scope] or "全部"
        local title=base_title.." · "..scope_label
        if remote_error and #rows>0 then self:toast(remote_error,3) end
        if #rows==0 then
            local items={
                {text="搜索书架",callback=function() self:show_shelf_search_dialog(mp_mode,all_rows) end},
                {text="排序和筛选",post_text=self:_shelf_summary(),callback=function() self:show_shelf_controls(mp_mode) end},
            }
            if self:logged_in() then items[#items+1]={text="重新加载书架",callback=function() self:show_shelf(mp_mode,true) end}
            else items[#items+1]={text="扫码登录",callback=function() self.auth_flow:start() end} end
            if remote_error then table.insert(items,1,{text=remote_error,enabled=false}) end
            self:list(title,items,"书架为空")
            return
        end
        local ok,view=pcall(ShelfView.show,{
            title=title.." · "..tostring(#rows).."本",
            books=rows,
            show_covers=prefs.shelf_covers~=false and not prefs.low_resource,
            on_search=function() self:show_shelf_search_dialog(mp_mode,all_rows) end,
            on_sort=function() self:show_shelf_controls(mp_mode) end,
            on_select=function(b) self:_shelf_select(b) end,
            on_hold=function(b) self:book_menu(b) end,
            on_page_changed=function(page,first,last,current)
                if prefs.shelf_covers~=false and not prefs.low_resource then self:_on_shelf_page(rows,current,page,first,last) end
            end,
            on_close=function(current)
                if self._shelf_view==current then self._shelf_view=nil end
                self:_cancel_cover_loading()
                collectgarbage("step",160)
            end,
        })
        if ok and view then self._shelf_view=view; return end
        logger.warn("[MiuRead][Shelf] custom view unavailable",tostring(view))
        local items={{text="搜索书架",callback=function() self:show_shelf_search_dialog(mp_mode,all_rows) end},{text="排序和筛选",post_text=self:_shelf_summary(),callback=function() self:show_shelf_controls(mp_mode) end}}
        for _,b in ipairs(rows) do
            local book=b
            items[#items+1]={text=(book.downloaded and "✓ " or "")..book.title,post_text=self:_shelf_status_text(book),callback=function() self:_shelf_select(book) end,hold_callback=function() self:book_menu(book) end}
        end
        self:list(title,items)
    end,force_remote)
end

function Plugin:show_shelf_controls(mp_mode)
    local menu
    local prefs=self.store:preferences()
    local current_scope=tostring(prefs.shelf_scope or "all")
    local current_sort=tostring(prefs.shelf_sort or "read")

    local function close_menu()
        if menu then pcall(function() UIManager:close(menu) end) end
    end
    local function apply(change)
        change()
        close_menu()
        self:_reopen_shelf(mp_mode)
    end

    local shelf_type_items={
        {
            text=(not mp_mode and "✓ " or "").."普通书籍",
            radio=true,
            checked_func=function() return not mp_mode end,
            callback=function()
                close_menu()
                if mp_mode then self:_reopen_shelf(false) end
            end,
        },
        {
            text=(mp_mode and "✓ " or "").."公众号",
            radio=true,
            checked_func=function() return mp_mode end,
            callback=function()
                close_menu()
                if not mp_mode then self:_reopen_shelf(true) end
            end,
        },
    }

    local scope_items={}
    for _,row in ipairs({{"all","全部"},{"downloaded","已下载"},{"unread","未开始"},{"reading","阅读中"},{"finished","已读完"}}) do
        local key,label=row[1],row[2]
        local selected=current_scope==key
        scope_items[#scope_items+1]={
            text=(selected and "✓ " or "")..label,
            radio=true,
            checked_func=function() return tostring(self.store:preferences().shelf_scope or "all")==key end,
            callback=function()
                apply(function()
                    local next_prefs=self.store:preferences()
                    next_prefs.shelf_scope=key
                    next_prefs.shelf_filters={}
                    self.store:save_preferences(next_prefs)
                end)
            end,
        }
    end

    local sort_items={}
    for _,row in ipairs({{"read","最近阅读"},{"download","最近下载"},{"update","最近更新"},{"progress","阅读进度（高到低）"},{"title","书名"},{"author","作者"}}) do
        local key,label=row[1],row[2]
        local selected=current_sort==key
        sort_items[#sort_items+1]={
            text=(selected and "✓ " or "")..label,
            radio=true,
            checked_func=function() return tostring(self.store:preferences().shelf_sort or "read")==key end,
            callback=function()
                apply(function()
                    local next_prefs=self.store:preferences()
                    next_prefs.shelf_sort=key
                    self.store:save_preferences(next_prefs)
                end)
            end,
        }
    end

    local items={
        {
            text="书架类型",
            post_text=mp_mode and "公众号" or "普通书籍",
            sub_item_table=shelf_type_items,
        },
        {
            text="筛选范围",
            post_text=SCOPE_LABELS[current_scope] or "全部",
            sub_item_table=scope_items,
        },
        {
            text="排序方式",
            post_text=SORT_LABELS[current_sort] or "最近阅读",
            sub_item_table=sort_items,
        },
        {
            text="刷新书架",
            enabled=self:logged_in(),
            callback=function()
                close_menu()
                UIManager:scheduleIn(0,function() self:_close_current_shelf(); self:show_shelf(mp_mode,true) end)
            end,
        },
    }
    menu=Menu:new{title="书架选项",item_table=items,is_borderless=true,title_bar_fm_style=true}
    UIManager:show(menu)
end
function Plugin:sort_menu() return {{text="打开书架排序与筛选",callback=function() self:show_shelf_controls(self._last_shelf_mode or false) end}} end
function Plugin:filter_menu() return self:sort_menu() end
function Plugin:search_dialog()
    if not self:require_login() then return end
    local d
    d=InputDialog:new{
        title=_("Search books"), input="",
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},
            {text=_("Search"),is_enter_default=true,callback=function()
                local q=U.trim(d:getInputText())
                UIManager:close(d)
                if q~="" then self:search(q) end
            end},
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
end

function Plugin:_cancel_search(reason)
    self._search_generation=(tonumber(self._search_generation) or 0)+1
    if self.search_async then self.search_async:cancel(reason or "cancelled") end
    local dialog=self._search_dialog
    self._search_dialog=nil
    if dialog then pcall(UIManager.close,UIManager,dialog) end
end

function Plugin:search(q)
    if not self:require_login() then return end
    if not self:is_online() then self:info(_("Network unavailable")); return end
    if self.search_async and self.search_async:busy() then self:_cancel_search("new_search") end

    self._search_generation=(tonumber(self._search_generation) or 0)+1
    local generation=self._search_generation
    local closing=false
    local dialog
    dialog=ButtonDialog:new{
        title="正在搜索《"..tostring(q).."》……\n\n可按返回键或点击取消。",
        title_align="center",
        close_callback=function()
            if closing then return end
            closing=true
            if generation==self._search_generation and self.search_async then
                self.search_async:cancel("search_dialog_closed")
                self._search_generation=self._search_generation+1
            end
            self._search_dialog=nil
        end,
        buttons={
            {{text="取消搜索",callback=function()
                if closing then return end
                closing=true
                if generation==self._search_generation and self.search_async then
                    self.search_async:cancel("user_cancelled")
                end
                self._search_generation=self._search_generation+1
                self._search_dialog=nil
                UIManager:close(dialog)
            end}},
        },
    }
    self._search_dialog=dialog
    UIManager:show(dialog)

    local function finish(result)
        if generation~=self._search_generation then return end
        closing=true
        self._search_dialog=nil
        UIManager:close(dialog)
        if not result or result.ok~=true then
            self:info(self:_friendly_remote_error(result and result.error or "未知错误","搜索"))
            return
        end
        local data=result.value or {}
        local items={}
        local function add(r)
            local b=normalize(r)
            if b.bookId~="" then
                items[#items+1]={text=b.title,post_text=b.author,callback=function() self:book_menu(b) end}
            end
        end
        for _,g in ipairs(data.results or data.books or {}) do
            if g.books then for _,r in ipairs(g.books) do add(r) end else add(g) end
        end
        self:list(_("Search").." · "..q,items,"没有找到相关书籍")
    end

    local function run_on_main_thread()
        UIManager:scheduleIn(.10,function()
            if generation~=self._search_generation then return end
            local ok,value=xpcall(function() return self.api:search(q,0,40) end,debug.traceback)
            finish(ok and {ok=true,value=value} or {ok=false,error=tostring(value)})
        end)
    end

    if not self.search_async or not self.search_async:available() then
        run_on_main_thread()
        return
    end

    local auth=U.copy(self.store:auth())
    local started,err=self.search_async:run("book_search",function()
        local HttpChild=require("miuread.http")
        local ApiChild=require("miuread.api")
        local UtilChild=require("miuread.util")
        local child_store={
            auth=function() return UtilChild.copy(auth) end,
            save_auth=function() end,
        }
        local api=ApiChild:new(HttpChild:new(child_store),child_store)
        return api:search(q,0,40)
    end,finish,32)
    if not started then
        logger.warn("[MiuRead][Search] async unavailable; falling back",tostring(err or "worker busy"))
        run_on_main_thread()
    end
end
function Plugin:_variant_exists(book_id,kind)
    local r=self.store:variant(book_id,kind)
    return r and r.file and U.file_exists(r.file) and r or nil
end
function Plugin:_book_has_cache(book_id)
    local stored=self.store:book(book_id)
    if not stored then return false end
    for _,r in pairs(stored.variants or {}) do if r.file and U.file_exists(r.file) then return true end end
    for _,row in pairs(stored.chapters or {}) do for _,r in pairs(row or {}) do if r.file and U.file_exists(r.file) then return true end end end
    return false
end
function Plugin:book_menu(b)
    b=normalize(b)
    local clean=self:_variant_exists(b.bookId,"clean")
    local notes=self:_variant_exists(b.bookId,"notes")
    local items={}
    if clean and notes then
        items[#items+1]={text="阅读纯净版",callback=function() self:open_file(clean.file) end}
        items[#items+1]={text="阅读划线与想法版",callback=function() self:open_file(notes.file) end}
        items[#items+1]={text="重新下载",callback=function() self:choose_download(b,nil,false) end}
    elseif clean or notes then
        local current=clean or notes
        local current_label=clean and "纯净版" or "划线与想法版"
        items[#items+1]={text="继续阅读 · "..current_label,callback=function() self:open_file(current.file) end}
        if clean then
            items[#items+1]={text="下载划线与想法版",callback=function() self:download(b,{annotations=true},false) end}
        else
            items[#items+1]={text="下载纯净版",callback=function() self:download(b,{annotations=false},false) end}
        end
        items[#items+1]={text="重新下载",callback=function() self:choose_download(b,nil,false) end}
    else
        items[#items+1]={text=_("Download full book"),callback=function() self:choose_download(b,nil,false) end}
        items[#items+1]={text=_("Read first chapter"),callback=function() self:choose_download(b,1,true) end}
    end
    items[#items+1]={text=_("Chapter list"),callback=function() self:chapters(b) end}
    items[#items+1]={text=_("Book details"),callback=function() self:book_details(b) end}
    items[#items+1]={text=_("View cover"),callback=function() self:view_cover(b) end}
    if self:_book_has_cache(b.bookId) or self.store:book_has_partial_cache(b.bookId) then
        items[#items+1]={text="管理已下载内容",callback=function() self:downloaded_book_menu(tostring(b.bookId)) end}
    end
    self:list(b.title,items)
end
function Plugin:book_details(b)
    self:online("details",function() local x=self.api:book(b.bookId); local z=normalize(x); self:info(z.title.."\n"..z.author.."\n\n"..tostring(x.intro or x.description or "")) end)
end
function Plugin:view_cover(b)
    self:online("cover",function() local path=self.library:cache_cover(b); if not path then self:info("没有可用封面") return end; local ok,Viewer=pcall(require,"ui/widget/imageviewer"); if ok then local good,obj=pcall(Viewer.new,Viewer,{file=path,title=b.title,with_title_bar=true}); if good then UIManager:show(obj); return end end; self:info(path) end)
end
function Plugin:open_variant(b,kind) local r=self.store:variant(b.bookId,kind); if r and r.file and U.file_exists(r.file) then self:open_file(r.file) else self:info(_("No cached file")) end end
function Plugin:choose_download(b,limit,open_after,uid)
    self:list(_("Download"),{{text=_("Clean version"),callback=function() self:download(b,{annotations=false,limit=limit,chapter_uid=uid},open_after) end},{text=_("Notes version"),callback=function() self:download(b,{annotations=true,limit=limit,chapter_uid=uid},open_after) end},{text=_("Both versions"),callback=function() self:download_both(b,limit,uid,open_after) end}})
end
function Plugin:_download_summary(rec,opt)
    local lines={
        "下载完成",
        "保存位置："..tostring(rec.file or ""),
        "打开一次后会出现在 KOReader 最近阅读中",
    }
    if opt and opt.annotations then
        local a=rec.annotation_summary or {}
        lines[#lines+1]="划线："..tostring(a.underlines or 0)
        lines[#lines+1]="含想法的划线："..tostring(a.thoughts or 0)
    end
    return table.concat(lines,"\n")
end

function Plugin:_refresh_local_files()
    local ui=self.ui
    if not ui then return end
    local chooser=ui.file_chooser
    if chooser then
        if type(chooser.refreshPath)=="function" then pcall(chooser.refreshPath,chooser)
        elseif type(chooser.refresh)=="function" then pcall(chooser.refresh,chooser) end
    end
    if type(ui.onRefresh)=="function" then pcall(ui.onRefresh,ui) end
end
function Plugin:_show_download_complete(rec,opt)
    local dialog
    dialog=ButtonDialog:new{title=self:_download_summary(rec,opt),title_align="center",buttons={
        {{text="立即阅读",callback=function() UIManager:close(dialog); self:open_file(rec.file) end}},
        {{text="关闭",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end
function Plugin:_show_both_complete(clean,notes)
    local dialog
    dialog=ButtonDialog:new{title="两个版本均已下载完成",title_align="center",buttons={
        {{text="阅读划线与想法版",callback=function() UIManager:close(dialog); self:open_file(notes.file) end}},
        {{text="阅读纯净版",callback=function() UIManager:close(dialog); self:open_file(clean.file) end}},
        {{text="关闭",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end
function Plugin:download_both(b,limit,uid,open_after)
    self:download(b,{annotations=false,limit=limit,chapter_uid=uid},false,function(clean)
        self:download(b,{annotations=true,limit=limit,chapter_uid=uid},false,function(notes)
            if open_after then self:open_file(notes.file) else self:_show_both_complete(clean,notes) end
        end)
    end)
end
function Plugin:download(b,opt,open_after,done)
    if not self:require_login() then return end
    if not self:is_online() then self:info(_("Network unavailable")); return end
    if self.download_task and self.download_task:busy() then self:info("已有下载任务正在运行"); return end
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存正在清理，完成后再开始下载。") return end
    if self.epub_style_repair_task and self.epub_style_repair_task:busy() then self:info("旧书样式正在修复，完成后再开始下载。") return end
    if b and b.bookId and tostring(b.bookId)~="" then self.store:save_book(b.bookId,{book_id=tostring(b.bookId),title=b.title,author=b.author,updated_at=os.time()}) end
    local prefs=self.store:preferences(); opt=U.copy(opt or {})
    opt.images=tostring(b.bookId):sub(1,7)=="MP_WXS_" and prefs.mp_images or prefs.images
    local resume_time_sync=prefs.sync and prefs.sync.time_enabled and self.sync and self.sync:record()~=nil
    if self.sync then self.sync:stop("download") end
    local dialog=DownloadProgress:new{title="正在下载《"..tostring(b.title or "未命名").."》",on_cancel=function() if self.download_task then self.download_task:cancel() end end}
    dialog:show()
    local function finish(result)
        dialog:close(); self.store:reload()
        if resume_time_sync and self.sync then self.sync:start("download_finished") end
        if not result or result.ok~=true then local err=result and result.error or "未知下载错误"; logger.warn("[MiuRead][Download] failed",tostring(err)); self:info("下载失败：\n"..U.first_line(err)); return end
        local rec=result.value or {}
        self:_refresh_local_files()
        if done then done(rec); return end
        if open_after and rec.file then self:open_file(rec.file) else self:_show_download_complete(rec,opt) end
    end
    local ok,err=self.download_task:start(b,opt,function(state) if dialog then dialog:set_state(state) end end,finish)
    if not ok then
        dialog:close()
        if resume_time_sync and self.sync then self.sync:start("download_start_failed") end
        self:info("无法启动下载任务：\n"..tostring(err))
    end
end
function Plugin:chapters(b)
    self:online("chapters",function()
        local _,rows=self.downloader:catalog(b.bookId)
        local items={}
        for _,ch in ipairs(rows) do
            local chapter=ch
            items[#items+1]={text=chapter.title or tostring(chapter.chapterUid),post_text=tostring(chapter.wordCount or ""),callback=function() self:chapter_menu(b,chapter) end}
        end
        self:list(b.title,items)
    end)
end
function Plugin:chapter_menu(b,ch)
    local uid=ch.chapterUid
    local clean=self.store:chapter_variant(b.bookId,uid,"clean")
    local notes=self.store:chapter_variant(b.bookId,uid,"notes")
    if not (clean and clean.file and U.file_exists(clean.file)) then clean=nil end
    if not (notes and notes.file and U.file_exists(notes.file)) then notes=nil end
    local items={}
    if clean and notes then
        items[#items+1]={text="阅读纯净版",callback=function() self:open_file(clean.file) end}
        items[#items+1]={text="阅读划线与想法版",callback=function() self:open_file(notes.file) end}
        items[#items+1]={text="重新下载本章",callback=function() self:choose_download(b,nil,false,uid) end}
    elseif clean or notes then
        local current=clean or notes
        local label=clean and "纯净版" or "划线与想法版"
        items[#items+1]={text="继续阅读 · "..label,callback=function() self:open_file(current.file) end}
        if clean then
            items[#items+1]={text="下载本章划线与想法版",callback=function() self:download(b,{annotations=true,chapter_uid=uid},true) end}
        else
            items[#items+1]={text="下载本章纯净版",callback=function() self:download(b,{annotations=false,chapter_uid=uid},true) end}
        end
    else
        items[#items+1]={text=_("Download chapter"),callback=function() self:choose_download(b,nil,true,uid) end}
    end
    if clean or notes then
        items[#items+1]={text=_("Delete chapter cache"),callback=function() self:_confirm_delete_chapter_cache(b.bookId,uid,ch.title or tostring(uid)) end}
    end
    self:list(ch.title or tostring(uid),items)
end
function Plugin:open_file(path)
    if not path or not U.file_exists(path) then self:info(_("No cached file")); return end
    local b=self.store:file_record(path)
    if b then self.store:mark_last_read(b.book_id,path) end
    if self.ui.document then self.ui:switchDocument(path) else self.ui:openFile(path) end
end
function Plugin:_variant_label(kind)
    return kind=="notes" and "划线与想法版" or "纯净版"
end
function Plugin:_close_download_menus()
    local detail=self._download_book_menu; self._download_book_menu=nil
    local root=self._downloads_menu; self._downloads_menu=nil
    if detail then pcall(function() UIManager:close(detail) end) end
    if root and root~=detail then pcall(function() UIManager:close(root) end) end
end
function Plugin:_cache_action_blocked()
    if self.download_task and self.download_task:busy() then self:info("下载任务进行中，暂时不能修改下载文件。") return true end
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存正在清理，请勿重复操作。") return true end
    if self.epub_style_repair_task and self.epub_style_repair_task:busy() then self:info("旧书样式正在修复，请稍候。") return true end
    return false
end
function Plugin:_notes_epub_paths(book_id)
    self.store:reload()
    local out,seen={},{}
    local function add(record)
        local path=record and tostring(record.file or "") or ""
        if path~="" and path:lower():match("%.epub$") and U.file_exists(path) and not seen[path] then
            seen[path]=true; out[#out+1]=path
        end
    end
    local function add_book(book)
        if not book then return end
        add(book.variants and book.variants.notes)
        for _,row in pairs(book.chapters or {}) do add(row and row.notes) end
    end
    if book_id then add_book(self.store:book(book_id))
    else for _,book in ipairs(self.store:all_books()) do add_book(book) end end
    table.sort(out)
    return out
end
function Plugin:_current_document_path()
    local doc=self.ui and self.ui.document
    return doc and (doc.file or (doc.getFilePath and doc:getFilePath())) or nil
end
function Plugin:_run_epub_style_repair(paths,options)
    options=options or {}
    if self:_cache_action_blocked() then return end
    local unique,seen={},{}
    for _,path in ipairs(paths or {}) do
        path=tostring(path or "")
        if path~="" and not seen[path] then seen[path]=true; unique[#unique+1]=path end
    end
    if #unique==0 then self:info("没有可修复的划线与想法版 EPUB。") return end
    local current=tostring(self:_current_document_path() or "")
    if current~="" then
        for _,path in ipairs(unique) do
            if tostring(path)==current then
                self:info("当前书籍仍在阅读器中打开。\n\n请先返回文件管理器或书架，再执行样式修复；不会要求重新下载书籍。")
                return
            end
        end
    end
    self:_close_download_menus()
    local dialog=InfoMessage:new{text=tostring(options.progress_text or "正在修复旧划线书籍样式，请稍候……")}
    self._epub_style_repair_dialog=dialog
    UIManager:show(dialog)
    local function finish(result)
        if self._epub_style_repair_dialog then pcall(function() UIManager:close(self._epub_style_repair_dialog) end) end
        self._epub_style_repair_dialog=nil
        local repaired=tonumber(result and result.repaired or 0) or 0
        local skipped=tonumber(result and result.skipped or 0) or 0
        local errors=result and result.errors or {}
        if result and result.ok==true then
            local lines={"旧书样式修复完成"}
            if repaired>0 then lines[#lines+1]="已修复："..tostring(repaired).." 个 EPUB" end
            if skipped>0 then lines[#lines+1]="无需修改："..tostring(skipped).." 个 EPUB" end
            lines[#lines+1]=""
            lines[#lines+1]="修复会删除旧实线规则并改写评论正文标签。重新打开书籍即可生效，不需要重新下载正文。"
            self:info(table.concat(lines,"\n"))
        else
            local lines={"旧书样式修复未完全完成","","已修复："..tostring(repaired).." 个 EPUB"}
            if skipped>0 then lines[#lines+1]="无需修改："..tostring(skipped).." 个 EPUB" end
            if #errors>0 then lines[#lines+1]=""; lines[#lines+1]=U.first_line(table.concat(errors,"\n"),420) end
            lines[#lines+1]=""; lines[#lines+1]="失败文件已自动恢复原版。"
            self:info(table.concat(lines,"\n"))
        end
        if options.refresh~=false then UIManager:scheduleIn(.08,function() self:show_downloads() end) end
    end
    local ok,err=self.epub_style_repair_task:start(unique,finish)
    if not ok then
        pcall(function() UIManager:close(dialog) end); self._epub_style_repair_dialog=nil
        self:info("无法开始修复：\n"..tostring(err))
        if options.refresh~=false then UIManager:scheduleIn(.08,function() self:show_downloads() end) end
    end
end
function Plugin:_confirm_repair_book_style(book_id,title)
    local paths=self:_notes_epub_paths(book_id)
    if #paths==0 then self:info("《"..tostring(title or book_id).."》没有可修复的划线与想法版 EPUB。") return end
    UIManager:show(ConfirmBox:new{
        text="修复《"..tostring(title or book_id).."》的划线样式？\n\n会同时改写现有 EPUB 的评论正文标签和觅阅样式，清除实线与虚线叠加；不重新下载正文。操作前会临时备份，失败会自动恢复。",
        ok_text="开始修复",
        ok_callback=function()
            self:_run_epub_style_repair(paths,{progress_text="正在修复本书划线样式……"})
        end,
    })
end
function Plugin:_confirm_repair_all_styles()
    local paths=self:_notes_epub_paths()
    if #paths==0 then self:info("没有可修复的划线与想法版 EPUB。") return end
    UIManager:show(ConfirmBox:new{
        text="修复全部旧划线书籍样式？\n\n共检测到 "..tostring(#paths).." 个划线与想法版 EPUB。会清除旧实线规则并改写评论正文标签，不重新下载正文；失败文件会自动恢复。",
        ok_text="修复全部",
        ok_callback=function()
            self:_run_epub_style_repair(paths,{progress_text="正在修复全部旧划线书籍样式……"})
        end,
    })
end
function Plugin:_run_cache_cleanup(paths,options)
    options=options or {}
    if self:_cache_action_blocked() then return end
    local unique,seen={},{}
    for _,path in ipairs(paths or {}) do
        path=tostring(path or "")
        if path~="" and not seen[path] then seen[path]=true; unique[#unique+1]=path end
    end
    self:_close_download_menus()
    local dialog=InfoMessage:new{text=tostring(options.progress_text or "正在清理缓存，请稍候……")}
    self._cache_cleanup_dialog=dialog
    UIManager:show(dialog)
    local function finish(result)
        if self._cache_cleanup_dialog then pcall(function() UIManager:close(self._cache_cleanup_dialog) end) end
        self._cache_cleanup_dialog=nil
        self.store:reload()
        local commit_ok=true
        if result and result.ok==true then
            if options.commit then
                local ok,err=xpcall(options.commit,debug.traceback)
                if not ok then
                    commit_ok=false
                    logger.err("[MiuRead][CacheCleanup] commit failed",tostring(err))
                    self.store:prune_missing_files()
                    self:info("文件已清理，但下载记录刷新失败。重启 KOReader 后会自动重新检查。")
                end
            end
        else
            self.store:prune_missing_files()
        end
        U.mkdir(self.store.cache_books_dir); U.mkdir(self.store.covers_dir)
        self:_refresh_local_files()
        if result and result.ok==true and commit_ok then
            self:toast(options.done_text or _("Cache cleared"),2)
        elseif not (result and result.ok==true) then
            local err=result and (result.error or table.concat(result.errors or {},"\n")) or "未知错误"
            self:info("缓存清理未完全完成：\n"..U.first_line(err,220))
        end
        if options.refresh~=false then UIManager:scheduleIn(.08,function() self:show_downloads() end) end
    end
    if #unique==0 then finish({ok=true,removed=0}); return end
    local ok,err=self.cache_cleanup_task:start(unique,finish)
    if not ok then
        pcall(function() UIManager:close(dialog) end); self._cache_cleanup_dialog=nil
        self:info("无法开始清理：\n"..tostring(err))
        UIManager:scheduleIn(.08,function() self:show_downloads() end)
    end
end
function Plugin:_confirm_delete_variant(book_id,kind,title)
    if self:_cache_action_blocked() then return end
    local record=self.store:variant(book_id,kind)
    if not (record and record.file and U.file_exists(record.file)) then self.store:forget_variant(book_id,kind); self:toast("该版本已经不存在"); self:show_downloads(); return end
    local label=self:_variant_label(kind)
    UIManager:show(ConfirmBox:new{
        text="删除《"..tostring(title or book_id).."》的"..label.."？\n\n只删除这个 EPUB，其他版本和下载断点会保留。",
        ok_callback=function()
            local paths=self.store:variant_paths(book_id,kind)
            self:_run_cache_cleanup(paths,{
                progress_text="正在删除"..label.."……",
                done_text=label.."已删除",
                commit=function() self.store:forget_variant(book_id,kind) end,
            })
        end,
    })
end
function Plugin:_confirm_delete_chapter_cache(book_id,uid,title)
    if self:_cache_action_blocked() then return end
    local paths=self.store:chapter_paths(book_id,uid)
    if #paths==0 then self.store:forget_chapter_all(book_id,uid); self:toast("本章缓存已经不存在"); return end
    UIManager:show(ConfirmBox:new{
        text="删除“"..tostring(title or uid).."”的全部单章文件？",
        ok_callback=function()
            self:_run_cache_cleanup(self.store:chapter_paths(book_id,uid),{
                progress_text="正在删除本章文件……",
                done_text="本章文件已删除",
                commit=function() self.store:forget_chapter_all(book_id,uid) end,
            })
        end,
    })
end
function Plugin:_confirm_clear_partial_cache(book_id,title)
    if self:_cache_action_blocked() then return end
    local paths=self.store:partial_cache_paths(book_id)
    if #paths==0 then self:toast("没有未完成下载缓存"); return end
    UIManager:show(ConfirmBox:new{
        text="清理《"..tostring(title or book_id).."》的未完成下载缓存？\n\n已生成的 EPUB 不会删除；下次下载将重新获取尚未完成的内容。",
        ok_callback=function()
            self:_run_cache_cleanup(self.store:partial_cache_paths(book_id),{
                progress_text="正在清理未完成下载缓存……",
                done_text="下载断点已清理",
                commit=function() self.store:prune_missing_files() end,
            })
        end,
    })
end
function Plugin:_confirm_delete_book_downloads(book_id,title)
    if self:_cache_action_blocked() then return end
    local paths=self.store:book_paths(book_id,true)
    if #paths==0 then self.store:forget_book(book_id); self:show_downloads(); return end
    UIManager:show(ConfirmBox:new{
        text="删除《"..tostring(title or book_id).."》的全部下载内容？\n\n将删除纯净版、划线与想法版、单章文件和下载断点，不会退出账户。",
        ok_callback=function()
            self:_run_cache_cleanup(self.store:book_paths(book_id,true),{
                progress_text="正在删除本书全部下载内容……",
                done_text="本书下载内容已删除",
                commit=function() self.store:forget_book(book_id) end,
            })
        end,
    })
end
function Plugin:_download_book_labels(b)
    local labels={}
    for _,kind in ipairs({"clean","notes"}) do
        local r=b.variants and b.variants[kind]
        if r and r.file and U.file_exists(r.file) then labels[#labels+1]=self:_variant_label(kind) end
    end
    local chapter_count=0
    for _,row in pairs(b.chapters or {}) do for _,r in pairs(row or {}) do if r.file and U.file_exists(r.file) then chapter_count=chapter_count+1 end end end
    if chapter_count>0 then labels[#labels+1]="单章 "..tostring(chapter_count) end
    if self.store:book_has_partial_cache(b.book_id) then labels[#labels+1]="未完成缓存" end
    return labels,chapter_count
end
function Plugin:show_downloads()
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存正在清理，请稍候。") return end
    if self.epub_style_repair_task and self.epub_style_repair_task:busy() then self:info("旧书样式正在修复，请稍候。") return end
    self.store:reload(); self.store:prune_missing_files()
    if self._download_book_menu then pcall(function() UIManager:close(self._download_book_menu) end); self._download_book_menu=nil end
    if self._downloads_menu then pcall(function() UIManager:close(self._downloads_menu) end); self._downloads_menu=nil end
    local items={}
    local repair_paths=self:_notes_epub_paths()
    if #repair_paths>0 then
        items[#items+1]={text="样式修复",enabled=false}
        items[#items+1]={
            text="修复全部旧划线书籍样式",
            post_text=tostring(#repair_paths).." 个 EPUB · 无需重新下载",
            callback=function() self:_confirm_repair_all_styles() end,
        }
        items[#items+1]={text="已下载书籍",enabled=false}
    end
    for _,b in ipairs(self.store:all_books()) do
        local labels=self:_download_book_labels(b)
        if #labels>0 then
            local book_id=tostring(b.book_id)
            items[#items+1]={
                text=b.title or book_id,
                post_text=table.concat(labels," · "),
                callback=function() self:downloaded_book_menu(book_id) end,
            }
        end
    end
    if #items==0 then self:info(_("No downloaded books")); return end
    local menu=Menu:new{title=_("Downloads and cache"),item_table=items,is_borderless=true,title_bar_fm_style=true}
    self._downloads_menu=menu
    UIManager:show(menu)
end
function Plugin:downloaded_chapters_menu(book_id)
    self.store:reload()
    local b=self.store:book(book_id)
    if not b then self:toast("下载记录已不存在"); self:show_downloads(); return end
    local items={}
    for uid,row in pairs(b.chapters or {}) do
        for kind,r in pairs(row or {}) do
            if r.file and U.file_exists(r.file) then
                local file=r.file
                items[#items+1]={text=tostring(r.title or uid),post_text=self:_variant_label(kind),callback=function() self:open_file(file) end}
            end
        end
    end
    table.sort(items,function(a,c) return tostring(a.text)..tostring(a.post_text)<tostring(c.text)..tostring(c.post_text) end)
    self:list("单章文件 · "..tostring(b.title or book_id),items,"没有单章文件")
end
function Plugin:downloaded_book_menu(book_ref)
    local book_id=type(book_ref)=="table" and tostring(book_ref.book_id or book_ref.bookId) or tostring(book_ref)
    self.store:reload(); self.store:prune_missing_files()
    local b=self.store:book(book_id)
    if not b then self:toast("下载记录已不存在"); self:show_downloads(); return end
    local items={}
    local variants={}
    for _,kind in ipairs({"clean","notes"}) do
        local r=b.variants and b.variants[kind]
        if r and r.file and U.file_exists(r.file) then variants[#variants+1]={kind=kind,file=r.file,label=self:_variant_label(kind)} end
    end
    if #variants>0 then
        items[#items+1]={text="可阅读版本",enabled=false}
        for _,variant in ipairs(variants) do
            local kind_key=variant.kind; local file=variant.file; local label=variant.label
            items[#items+1]={text="阅读"..label,post_text="EPUB",callback=function() self:open_file(file) end}
            items[#items+1]={text="删除"..label,post_text="仅删除该版本",callback=function() self:_confirm_delete_variant(book_id,kind_key,b.title) end}
        end
    end
    local notes_paths=self:_notes_epub_paths(book_id)
    if #notes_paths>0 then
        items[#items+1]={text="样式修复",enabled=false}
        items[#items+1]={text="修复本书划线样式",post_text=tostring(#notes_paths).." 个 EPUB · 无需重新下载",callback=function() self:_confirm_repair_book_style(book_id,b.title) end}
    end
    local _,chapter_count=self:_download_book_labels(U.merge(b,{book_id=book_id}))
    local has_partial=self.store:book_has_partial_cache(book_id)
    if chapter_count>0 or has_partial then
        items[#items+1]={text="缓存与断点",enabled=false}
        if chapter_count>0 then
            items[#items+1]={text="查看单章文件",post_text=tostring(chapter_count).." 个",callback=function() self:downloaded_chapters_menu(book_id) end}
        end
        if has_partial then
            items[#items+1]={text="清理未完成下载缓存",post_text="保留已生成 EPUB",callback=function() self:_confirm_clear_partial_cache(book_id,b.title) end}
        end
    end
    if #variants>0 or chapter_count>0 or has_partial then
        items[#items+1]={text="本书管理",enabled=false}
        items[#items+1]={text="删除本书全部下载内容",post_text="不可恢复",callback=function() self:_confirm_delete_book_downloads(book_id,b.title) end}
    end
    if #items==0 then self:toast("本书没有可管理的下载内容"); self:show_downloads(); return end
    if self._download_book_menu then pcall(function() UIManager:close(self._download_book_menu) end) end
    local menu=Menu:new{title=b.title or book_id,item_table=items,is_borderless=true,title_bar_fm_style=true}
    self._download_book_menu=menu
    UIManager:show(menu)
end
function Plugin:progress_sync_label()
    local prefs=self.store:preferences().sync or {}
    if prefs.progress_enabled==false then return "已关闭" end
    local r=self.sync:record()
    local session=r and self.store:session(r.book.book_id) or {}
    local state=session and session.progress_sync_state or nil
    local labels={checking="正在检查",mapping_pending="等待章节换算",aligned="已同步",local_ahead="使用本机位置",local_selected="使用本机位置",remote_selected="已采用云端位置",remote_ahead="等待选择",deferred="本次暂不处理",remote_unavailable="稍后重试",remote_jump_unconfirmed="跳转待确认"}
    return labels[state] or "已开启"
end
function Plugin:sync_advanced_menu(from_reader)
    local items={
        {text="立即测试阅读时间上传",callback=function() self:test_read_report() end},
        {text=_("Detailed sync information"),callback=function() self:show_sync_status(true) end},
        {text=_("Clear current sync state"),callback=function()
            local r=self.sync:record()
            if r then self.store:clear_session(r.book.book_id); self.sync:clear_verified("manual_clear"); self:toast(_("Cache cleared"))
            else self:info(_("No matching MiuRead book is open.")) end
        end},
    }
    if from_reader then items[#items+1]={text="全部觅阅设置",sub_item_table_func=function() return self:settings_menu() end} end
    return items
end
function Plugin:sync_menu()
    return {
        {text="阅读时间同步 · "..self.sync:status_label(),checked_func=function() return self.store:preferences().sync.time_enabled end,keep_menu_open=true,callback=function() self:toggle_time_sync() end},
        {text="阅读时间同步弹窗提醒",checked_func=function() return self.store:preferences().sync.time_notice_enabled~=false end,keep_menu_open=true,callback=function() self:toggle_time_notice() end},
        {text="阅读进度同步 · "..self:progress_sync_label(),checked_func=function() return self.store:preferences().sync.progress_enabled~=false end,keep_menu_open=true,callback=function() self:toggle_progress_sync() end},
        {text="查看同步状态",callback=function() self:show_sync_status(false) end},
        {text=_("Advanced"),sub_item_table_func=function() return self:sync_advanced_menu(false) end},
    }
end
function Plugin:toggle_time_sync()
    local p=self.store:preferences(); p.sync.time_enabled=not p.sync.time_enabled; self.store:save_preferences(p)
    if p.sync.time_enabled then
        self.sync:start("enabled")
        self:status_toast("阅读时间同步","已开启",3)
    else
        self.sync:stop("disabled")
        self:status_toast("阅读时间同步","已关闭",3)
    end
end
function Plugin:toggle_time_notice()
    local p=self.store:preferences()
    p.sync=p.sync or {}
    p.sync.time_notice_enabled=not (p.sync.time_notice_enabled~=false)
    self.store:save_preferences(p)
    self:status_toast("阅读时间同步弹窗提醒",p.sync.time_notice_enabled and "已开启" or "已关闭",3)
end
function Plugin:toggle_progress_sync()
    local p=self.store:preferences(); p.sync.progress_enabled=not (p.sync.progress_enabled~=false); p.sync.pull_on_open=p.sync.progress_enabled; self.store:save_preferences(p)
    local r=self.sync:record()
    if p.sync.progress_enabled then
        self:toast("阅读进度同步已开启",3)
        if r then UIManager:scheduleIn(.1,function() self:ensure_read_report_progress("enabled",false) end) end
    else
        if r then self.store:save_session(r.book.book_id,{progress_sync_state="disabled",progress_sync_message="阅读进度同步已关闭"}) end
        self:toast("阅读进度同步已关闭",3)
    end
end
function Plugin:test_read_report()
    local r=self.sync:record(); if not r then self:info("请先打开一本觅阅下载的书籍再测试。"); return end
    self:status_toast("阅读时间测试","正在上传 30 秒……",3)
    local started=self.sync:test_upload(function(ok,result,position,detail)
        if ok then
            local progress=tostring(position and position.progress or "—")
            self:status_toast(
                "阅读时间测试成功",
                "已接收 30 秒 · 当前位置 "..progress.."%",
                4
            )
        else
            self:info("测试失败\n\n"..tostring(result or "未知错误").."\n\n可在‘同步状态’中查看当前阶段。")
        end
    end)
    if not started then self:info("无法启动测试：同步任务可能正在运行。") end
end
function Plugin:_save_progress_state(id,state,message,localp,remotep)
    self.store:save_session(id,{
        progress_sync_state=state,
        progress_sync_message=message,
        progress_local_percent=localp,
        progress_remote_percent=remotep,
        progress_decided_at=os.time(),
    })
end
function Plugin:ensure_read_report_progress(reason,automatic)
    local prefs=self.store:preferences().sync or {}
    if prefs.progress_enabled==false then
        if not automatic then self:info("阅读进度同步已关闭。") end
        return false
    end
    local r=self.sync:record()
    if not r then
        if not automatic then self:info(_("No matching MiuRead book is open.")) end
        return false
    end
    local id=tostring(r.book.book_id)
    if self._progress_check_running then
        if not automatic then self:toast("正在读取云端位置……",2) end
        return false
    end
    self._progress_check_running=true
    local local_position=self.sync:local_position()
    if not local_position or local_position.safe~=true or local_position.progress==nil then
        local chapter_percent=local_position and local_position.chapter_percent
            or math.floor((self.sync:local_ratio() or 0)*100+.5)
        self:_save_progress_state(id,"mapping_pending","正在取得完整目录以换算单章进度",chapter_percent,nil)
        self._progress_check_running=false
        self.sync:end_progress_sync("单章位置等待完整目录；阅读时间继续运行")
        if not automatic then
            self:info("当前打开的是单章文件。\n\n正在等待完整目录用于换算整书进度；在换算完成前，不会把本章百分比直接上传成整书百分比。阅读时间同步不受影响。")
        end
        return false
    end
    local localp=math.floor((tonumber(local_position.progress) or 0)+.5)
    self:_save_progress_state(id,"checking","正在读取云端位置",localp,nil)
    self.sync:begin_progress_sync(reason or "读取云端进度")
    self.sync:remote(id,function(remote,remote_err)
        self._progress_check_running=false
        if not remote then
            self:_save_progress_state(id,"remote_unavailable","暂时无法读取云端位置",localp,nil)
            self.sync:end_progress_sync("云端位置暂时不可用；阅读时间继续运行")
            if not automatic then self:info("暂时无法读取云端位置。\n\n阅读时间同步不受影响，将在下次打开书籍时重试。") end
            return
        end
        local remotep=math.floor((tonumber(remote.percent) or 0)+.5)
        local cmp=self.sync:compare(localp,remote)
        if cmp=="same" then
            self.sync:mark_verified(id,"positions_aligned",localp,remotep)
            self:_save_progress_state(id,"aligned","本机与云端位置接近",localp,remotep)
            self.sync:end_progress_sync("位置接近；阅读时间继续运行")
            if not automatic then self:info("本机位置："..localp.."%\n云端位置："..remotep.."%\n\n位置接近，无需处理。") end
            return
        end
        if cmp=="local_ahead" then
            self.sync:mark_verified(id,"local_position_ahead",localp,remotep)
            self:_save_progress_state(id,"local_ahead","本机位置较新，本次使用本机位置",localp,remotep)
            self.sync:end_progress_sync("使用本机位置；阅读时间继续运行")
            if not automatic then self:info("本机位置："..localp.."%\n云端位置："..remotep.."%\n\n本机位置较新，继续使用本机位置。") end
            return
        end
        self:_save_progress_state(id,"remote_ahead","发现更新的云端位置",localp,remotep)
        self.sync:end_progress_sync("等待用户选择；阅读时间继续运行")
        self:on_remote_progress(id,localp,remote,automatic==true)
    end)
    return true
end
function Plugin:_legacy_ensure_read_report_progress(reason,automatic)
    return self:ensure_read_report_progress(reason,automatic)
end
function Plugin:manual_sync()
    return self:ensure_read_report_progress("manual_progress_sync",false)
end
function Plugin:on_remote_progress(id,localp,remote,automatic)
    local remotep=math.floor((tonumber(remote.percent) or 0)+.5)
    if automatic and self._progress_prompted_book_id==tostring(id) then return end
    self._progress_prompted_book_id=tostring(id)
    local text="发现更新的云端阅读位置\n\n本机位置："..localp.."%\n云端位置："..remotep.."%"
    local dialog,closing_for_action
    local function defer()
        self:_save_progress_state(id,"deferred","本次暂不处理位置差异",localp,remotep)
    end
    dialog=ButtonDialog:new{title=text,title_align="center",close_callback=function()
        if not closing_for_action then defer() end
    end,buttons={
        {{text="跳到云端位置",callback=function()
            closing_for_action=true
            UIManager:close(dialog)
            local jumped,jump_error=self.sync:jump_remote(remote)
            if not jumped then
                self:_save_progress_state(id,"remote_jump_unconfirmed","无法跳转到云端位置",localp,remotep)
                self:info(tostring(jump_error or "无法跳转到云端位置。").."\n\n阅读时间同步仍会继续运行。")
                return
            end
            UIManager:scheduleIn(1.2,function()
                local actual_position=self.sync:local_position()
                local actual=actual_position and actual_position.progress
                    and math.floor(actual_position.progress+.5) or localp
                local threshold=tonumber(self.store:preferences().sync.threshold) or 2
                if math.abs(actual-remotep)<=threshold then
                    self.sync:mark_verified(id,"remote_position_selected",actual,remotep)
                    self:_save_progress_state(id,"remote_selected","已采用云端位置",actual,remotep)
                    self:toast("已跳到云端位置",3)
                else
                    self:_save_progress_state(id,"remote_jump_unconfirmed","已请求跳转，位置仍待确认",actual,remotep)
                    self:info("已请求跳到云端位置，但当前显示位置为 "..actual.."%。\n\n阅读时间同步不会暂停。")
                end
            end)
        end}},
        {{text="继续使用本机位置",callback=function()
            closing_for_action=true
            UIManager:close(dialog)
            self.sync:mark_verified(id,"local_position_selected",localp,remotep)
            self:_save_progress_state(id,"local_selected","本次阅读使用本机位置",localp,remotep)
            self:toast("本次阅读继续使用本机位置",3)
        end}},
        {{text="取消",callback=function()
            closing_for_action=true
            UIManager:close(dialog)
            defer()
        end}},
    }}
    UIManager:show(dialog)
end
function Plugin:_relative_time(ts)
    ts=tonumber(ts or 0) or 0
    if ts<=0 then return "尚未同步" end
    local delta=math.max(0,os.time()-ts)
    if delta<10 then return "刚刚" end
    if delta<60 then return tostring(delta).."秒前" end
    if delta<3600 then return tostring(math.floor(delta/60)).."分钟前" end
    if delta<86400 then return tostring(math.floor(delta/3600)).."小时前" end
    return U.now_text(ts)
end
function Plugin:show_sync_status(detail)
    local s=self.sync:status()
    local prefs=self.store:preferences().sync or {}
    local remote=s.remote and math.floor((s.remote.percent or 0)+.5) or nil
    local session=s.record and self.store:session(s.record.book.book_id) or {}
    local local_text=s.local_percent~=nil and (tostring(s.local_percent).."%")
        or (s.local_chapter_percent~=nil and ("本章 "..tostring(s.local_chapter_percent).."% · 等待整书换算") or "—")
    if detail then
        local next_text=(tonumber(s.next_due or 0)>os.time()) and (tostring(math.max(0,s.next_due-os.time())).." 秒后") or "—"
        local t="阅读同步诊断\n\n"
            .."阅读时间开关："..(s.time_enabled and "已开启" or "已关闭").."\n"
            .."同步弹窗提醒："..(prefs.time_notice_enabled~=false and "已开启" or "已关闭").."\n"
            .."阅读进度开关："..(prefs.progress_enabled~=false and "已开启" or "已关闭").."\n"
            .."当前状态："..tostring(s.state_label or s.state).."\n"
            .."当前书籍："..tostring(s.record and s.record.book and s.record.book.title or "未识别").."\n"
            .."本机位置："..local_text.."\n"
            .."云端位置："..tostring(remote and (remote.."%") or "未获取").."\n"
            .."进度状态："..tostring(session.progress_sync_state or "—").."\n"
            .."本次成功上传："..tostring(s.session_uploads).." 次\n"
            .."上次尝试："..U.now_text(s.last_attempt).."\n"
            .."上次成功："..U.now_text(s.last_upload).."\n"
            .."下次计划："..next_text.."\n"
            .."当前阶段："..tostring(s.last_stage or "—").."\n"
            .."连续失败："..tostring(s.consecutive_failures or 0)
            .."\n\n最近成功路径："..tostring(s.last_path or "—")
            .."\n最近响应："..tostring(s.last_response_summary or "—")
            .."\nHTTP 状态："..tostring(s.last_http_code or "—")
            .."\n响应长度："..tostring(s.last_http_length or "—")
            .."\n服务 PID："..tostring(s.service_pid or "—")
            .."\n最近错误："..tostring(type(s.last_error)=="string" and s.last_error or "—")
        self:info(t)
        return
    end
    local time_text
    if not s.time_enabled then time_text="已关闭"
    elseif not s.record or s.state=="stopped" then time_text="未运行"
    elseif type(s.last_error)=="string" and (tonumber(s.consecutive_failures) or 0)>=2 then time_text="暂时同步失败"
    elseif s.state=="uploading" then time_text="正在同步"
    else time_text="运行中" end
    local progress_text=self:progress_sync_label()
    local lines={"阅读同步","","阅读时间："..time_text,"阅读进度："..progress_text,"当前位置："..local_text}
    if remote then lines[#lines+1]="云端位置："..remote.."%" end
    lines[#lines+1]="上次同步："..self:_relative_time(s.last_upload)
    if time_text=="暂时同步失败" then lines[#lines+1]="将在稍后自动重试" end
    self:info(table.concat(lines,"\n"))
end
function Plugin:_time_notice_enabled()
    return self.store:preferences().sync.time_notice_enabled~=false
end
function Plugin:on_read_report_ready()
    if self:_time_notice_enabled() then
        self:status_toast("阅读时间同步","后台运行已开始",3)
    end
end
function Plugin:on_read_report_success(path)
    if self:_time_notice_enabled() then
        self:status_toast("阅读时间同步","首次上传成功",3)
    end
    local r=self.sync:record()
    local session=r and self.store:session(r.book.book_id) or {}
    if r and session.progress_sync_state=="mapping_pending"
        and self.store:preferences().sync.progress_enabled~=false then
        UIManager:scheduleIn(.5,function()
            if self.ui and self.ui.document then self:ensure_read_report_progress("catalog_ready",true) end
        end)
    end
end
function Plugin:on_read_report_failure(err)
    if self:_time_notice_enabled() then
        self:status_toast("阅读时间同步","连续上传失败，请查看同步状态",5)
    end
end
function Plugin:jump_dialog() local d; d=InputDialog:new{title=_("Enter percentage"),input="",buttons={{{text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},{text=_("Confirm"),is_enter_default=true,callback=function() local p=tonumber(d:getInputText()); UIManager:close(d); if p then self.sync:jump(p) end end}}}}; UIManager:show(d); d:onShowKeyboard() end
function Plugin:_annotation_mode() return "epub_inline_dashed" end
function Plugin:annotation_mode_label() return "EPUB 内置虚线" end
function Plugin:_set_annotation_visibility(_show_lines,_show_stars) return true end
function Plugin:annotation_mode_menu()
    return {{text="EPUB 内置虚线",radio=true,checked_func=function() return true end,
        callback=function() self:info("新下载的划线与想法版会把评论正文写成普通 inline span + 2px 虚线底边。旧书可在‘下载管理’或‘存储与缓存’中直接修复，无需重新下载正文。") end}}
end
function Plugin:toggle_annotations()
    self:toast("评论正文使用 EPUB 内置虚线",3)
end
function Plugin:_current_book_record()
    self.store:reload()
    local r=self.sync:record()
    if r then return r end
    local doc=self.ui and self.ui.document
    local path=doc and (doc.file or (doc.getFilePath and doc:getFilePath()))
    local b,rec,variant=self.store:file_record(path)
    if b then return {book=b,record=rec,variant=variant,path=path} end
    local raw=path and U.read_file(path,true)
    local id=raw and (raw:match('"book_id"%s*:%s*"([^"]+)"') or raw:match('miuread://book/([^<"]+)'))
    local fallback=id and self.store:book(id)
    if fallback then return {book=fallback,record=fallback.variants and (fallback.variants.notes or fallback.variants.clean),variant=nil,path=path} end
end
function Plugin:redownload_current()
    local r=self:_current_book_record()
    if not r or not r.book then self:info(_("No matching MiuRead book is open.")); return end
    local b={bookId=r.book.book_id,title=r.book.title,author=r.book.author,cover=r.book.cover}
    local current=(r.variant=="notes" or r.variant=="clean") and r.variant or (r.record and r.record.variant)
    local dialog
    local buttons={}
    if current=="notes" then buttons[#buttons+1]={{text="重新下载当前划线与想法版",callback=function() UIManager:close(dialog); self:download(b,{annotations=true},false) end}}
    elseif current=="clean" then buttons[#buttons+1]={{text="重新下载当前纯净版",callback=function() UIManager:close(dialog); self:download(b,{annotations=false},false) end}} end
    buttons[#buttons+1]={{text="重新下载纯净版",callback=function() UIManager:close(dialog); self:download(b,{annotations=false},false) end}}
    buttons[#buttons+1]={{text="重新下载划线与想法版",callback=function() UIManager:close(dialog); self:download(b,{annotations=true},false) end}}
    buttons[#buttons+1]={{text="关闭",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title="重新下载《"..tostring(b.title or "本书").."》",title_align="center",buttons=buttons}
    UIManager:show(dialog)
end
function Plugin:_toggle_preference(key)
    local p=self.store:preferences(); p[key]=not p[key]; self.store:save_preferences(p)
end
function Plugin:download_settings_menu()
    return {
        {text=_("Images"),checked_func=function() return self.store:preferences().images end,keep_menu_open=true,callback=function() self:_toggle_preference("images") end},
        {text=_("Official account images"),checked_func=function() return self.store:preferences().mp_images end,keep_menu_open=true,callback=function() self:_toggle_preference("mp_images") end},
        {text="下载时保持设备唤醒",checked_func=function() return self.store:preferences().download_keep_awake~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("download_keep_awake") end},
        {text="下载目录",post_text=self:_download_dir_label(),callback=function() self:directory_dialog() end},
    }
end
function Plugin:reading_settings_menu()
    return {
        {text="划线显示 · "..self:annotation_mode_label(),sub_item_table_func=function() return self:annotation_mode_menu() end},
        {text="想法字体大小",sub_item_table_func=function() return self:thought_font_menu() end},
    }
end
function Plugin:shelf_settings_menu()
    return {
        {text=_("Show shelf covers"),checked_func=function() return self.store:preferences().shelf_covers~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("shelf_covers") end},
    }
end
function Plugin:performance_settings_menu()
    return {{text=_("Low resource mode"),checked_func=function() return self.store:preferences().low_resource end,keep_menu_open=true,callback=function() self:_toggle_preference("low_resource") end}}
end
function Plugin:_confirm_clear_covers()
    if self:_cache_action_blocked() then return end
    UIManager:show(ConfirmBox:new{
        text="清除全部书架封面缓存？",
        ok_callback=function()
            self:_run_cache_cleanup({self.store.covers_dir},{
                progress_text="正在清理封面缓存……",
                done_text="封面缓存已清理",
                refresh=false,
                commit=function() self.store:set("cover_index",{}) end,
            })
        end,
    })
end
function Plugin:_confirm_clear_all_downloads()
    if self:_cache_action_blocked() then return end
    UIManager:show(ConfirmBox:new{
        text="清除全部觅阅下载内容和封面缓存？\n\n将删除全部 EPUB、单章文件和下载断点，但不会退出当前账户。",
        ok_callback=function()
            self:_run_cache_cleanup(self.store:all_download_paths(true),{
                progress_text="正在清理全部下载内容……",
                done_text="全部下载内容已清理",
                refresh=false,
                commit=function() self.store:forget_all_books(); self.store:set("cover_index",{}) end,
            })
        end,
    })
end
function Plugin:storage_settings_menu()
    return {
        {text="修复全部旧划线书籍样式",post_text="无需重新下载",callback=function() self:_confirm_repair_all_styles() end},
        {text=_("Clear covers"),callback=function() self:_confirm_clear_covers() end},
        {text=_("Clear all cache"),callback=function() self:_confirm_clear_all_downloads() end},
    }
end
function Plugin:update_about_menu()
    return {
        {text=_("Check update"),callback=self:safe("update",function() self:check_update() end)},
        {text="当前版本 · "..tostring(self.version),enabled=false},
        {text=_("About"),callback=function() self:show_about() end},
    }
end
function Plugin:settings_menu()
    local a=self.store:auth().account or {}
    local account=self:logged_in() and ("账户 · "..tostring(a.name or a.vid or "已登录")) or "账户 · 未登录"
    return {
        {text="下载设置",sub_item_table_func=function() return self:download_settings_menu() end},
        {text="阅读与想法",sub_item_table_func=function() return self:reading_settings_menu() end},
        {text="书架显示",sub_item_table_func=function() return self:shelf_settings_menu() end},
        {text="性能",sub_item_table_func=function() return self:performance_settings_menu() end},
        {text="存储与缓存",sub_item_table_func=function() return self:storage_settings_menu() end},
        {text=account,sub_item_table_func=function() return self:account_menu() end},
        {text="更新与关于",sub_item_table_func=function() return self:update_about_menu() end},
    }
end
function Plugin:thought_font_menu()
    local choices={{"standard","较小（默认）"},{"large","跟随正文"},{"xlarge","稍大"}}
    local rows={}
    for _,choice in ipairs(choices) do
        local key,label=choice[1],choice[2]
        rows[#rows+1]={text=label,radio=true,checked_func=function() return (self.store:preferences().thoughts or {}).font==key end,callback=function()
            local p=self.store:preferences(); p.thoughts=p.thoughts or {}; p.thoughts.font=key; self.store:save_preferences(p); self:toast("想法字体已设为："..label)
        end}
    end
    return rows
end
function Plugin:_download_dir_path()
    local custom=U.trim((self.store:preferences() or {}).download_dir or "")
    if custom~="" then return custom end
    return self.store.default_books_dir
end
function Plugin:_download_dir_label()
    local path=self:_download_dir_path()
    if path==self.store.default_books_dir then return "默认 · "..tostring(path) end
    return tostring(path)
end
function Plugin:_validate_download_dir(path)
    path=U.trim(path)
    if path=="" or path:sub(1,1)~="/" then return nil,"路径无效" end
    local attr=lfs.attributes(path)
    if not attr or attr.mode~="directory" then return nil,"文件夹不存在" end
    local probe=path.."/.miuread-write-test-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))
    local f=io.open(probe,"wb")
    if not f then return nil,"该文件夹不可写" end
    f:write("ok"); f:close(); os.remove(probe)
    return true
end
function Plugin:directory_dialog()
    local current=self:_download_dir_path()
    if lfs.attributes(current,"mode")~="directory" then
        if lfs.attributes("/mnt/us/documents","mode")=="directory" then current="/mnt/us/documents"
        elseif lfs.attributes("/mnt/us","mode")=="directory" then current="/mnt/us"
        else current="/" end
    end
    local chooser=PathChooser:new{
        title="选择下载文件夹（长按文件夹名称确认）",
        select_directory=true,
        select_file=false,
        show_files=false,
        path=current,
        onConfirm=function(path)
            local ok,err=self:_validate_download_dir(path)
            if not ok then self:info("无法使用此文件夹：\n"..tostring(err)); return end
            local old=self:_download_dir_path()
            local p=self.store:preferences(); p.download_dir=path; self.store:save_preferences(p)
            local note="下载目录已设置为：\n"..tostring(path)
            if old~=path then note=note.."\n\n只影响以后下载的书籍；已下载内容保留在原位置。" end
            self:info(note)
        end,
    }
    UIManager:show(chooser)
end
function Plugin:check_update()
    self:online("update",function()
        local m,e=self.updater:check()
        if not m then self:info("检查更新失败：\n"..tostring(e)); return end
        if m.current then self:info("当前已是最新版本\n\n当前版本："..tostring(self.version)); return end
        local text="发现新版本："..tostring(m.version)
        if m.name and tostring(m.name)~="" then text=text.."\n"..tostring(m.name) end
        if m.notes and tostring(m.notes)~="" then text=text.."\n\n更新说明：\n"..tostring(m.notes) end
        text=text.."\n\n是否下载并安装？"
        UIManager:show(ConfirmBox:new{text=text,ok_text="下载并安装",ok_callback=function()
            self:online("install",function()
                local path=self.updater:download(m)
                local ok,er=self.updater:install(path,m)
                if ok then self:info("更新已安装\n\n请完全退出并重新启动 KOReader。") else self:info("更新失败：\n"..tostring(er)) end
            end)
        end})
    end)
end
function Plugin:show_about() self:info(Config.NAME.." "..self.version.."\n\n".."过渡版 · 后续采用 Release 全量更新".."\n".."阅读时间上报沿用 0.3.6.7 兼容链路".."\n".._("Unofficial client").."\n\n".._("This build has not been verified with every Kindle model or every WeRead book.")) end
function Plugin:onShowMiuRead() self:show_shelf(false) end
local function extract_thought_href(value,seen,depth)
    if depth>4 or value==nil then return nil end
    if type(value)=="string" then return value:match("(#?miuthought%-[%x%.]+)") end
    if type(value)~="table" then return nil end
    seen=seen or {}; if seen[value] then return nil end; seen[value]=true
    for _,key in ipairs({"href","url","target","link","uri","dest","destination"}) do local found=extract_thought_href(value[key],seen,depth+1); if found then return found end end
    for _,child in pairs(value) do local found=extract_thought_href(child,seen,depth+1); if found then return found end end
end
function Plugin:_teardown_thought_tap()
    if self._thought_tap_setup and self.ui and self.ui.unRegisterTouchZones then pcall(function() self.ui:unRegisterTouchZones({{id="miuread_thought_popup",overrides={"tap_link"}}}) end) end
    self._thought_tap_setup=nil
end
function Plugin:_thought_font_size(level)
    local Device=require("device")
    local doc=self.ui and self.ui.document
    local configurable=doc and doc.configurable or {}
    local candidates={
        configurable.font_size,
        configurable.fontsize,
        self.ui and self.ui.rolling and self.ui.rolling.font_size,
    }
    local base
    for _,value in ipairs(candidates) do
        value=tonumber(value)
        if value and value>=10 and value<=80 then base=value; break end
    end
    if not base and _G.G_reader_settings and _G.G_reader_settings.readSetting then
        local ok,value=pcall(_G.G_reader_settings.readSetting,_G.G_reader_settings,"cre_font_size",22)
        if ok then base=tonumber(value) end
    end
    base=math.max(14,math.min(48,base or 22))
    local factors={standard=0.86,large=1.00,xlarge=1.15}
    local factor=factors[tostring(level or "standard")] or 1
    return Device.screen:scaleBySize(math.floor(base*factor+.5))
end
function Plugin:_thought_font_face()
    local ui=self.ui
    local face=ui and ui.font and ui.font.font_face
    if type(face)=="string" and U.trim(face)~="" then return U.trim(face) end
    local doc=ui and ui.document
    if doc and type(doc.getFontFace)=="function" then
        local ok,value=pcall(doc.getFontFace,doc)
        if ok and type(value)=="string" and U.trim(value)~="" then return U.trim(value) end
    end
    if _G.G_reader_settings and _G.G_reader_settings.readSetting then
        local ok,value=pcall(_G.G_reader_settings.readSetting,_G.G_reader_settings,"cre_font")
        if ok and type(value)=="string" and U.trim(value)~="" then return U.trim(value) end
    end
    return "serif"
end
function Plugin:_thought_popup_css()
    local face=self:_thought_font_face()
    local definitions,seen={},{ }
    local ok,cre=pcall(function() return require("document/credocument"):engineInit() end)
    if ok and cre and type(cre.getFontFaceFilenameAndFaceIndex)=="function" then
        for index=1,4 do
            local bold=index>=3
            local italic=index==2 or index==4
            local got,path=pcall(cre.getFontFaceFilenameAndFaceIndex,face,bold,italic)
            if got and type(path)=="string" and path~="" and not seen[path] then
                seen[path]=true
                local safe=path:gsub("\\","\\\\"):gsub('"','\\"'):gsub("[%c]","")
                definitions[#definitions+1]='@font-face{font-family:"MiuReadThoughtFont";src:url("'..safe..'")'
                    ..(bold and ";font-weight:bold" or "")
                    ..(italic and ";font-style:italic" or "").."}"
            end
        end
    end
    if #definitions>0 then face="MiuReadThoughtFont" end
    return Thoughts.popup_css(face,table.concat(definitions,"\n"))
end
function Plugin:_show_thought_href(href)
    local info=Thoughts.parse_href(href); if not info then return false end
    local group,err=Thoughts.find(self.store,info.book_id,info.chapter_uid,info.range)
    if not group then self:info(tostring(err or "没有想法内容")); return true end
    local prefs=self.store:preferences().thoughts or {}
    local source_html,html,metrics=Thoughts.popup_parts(group)
    if html=="" then self:info("没有想法内容"); return true end
    ThoughtPopup.show{
        source_html=source_html,
        html=html,
        font_size=self:_thought_font_size(prefs.font),
        width_ratio=tonumber(prefs.width_ratio) or 0.91,
        height_ratio=tonumber(prefs.height_ratio) or 0.60,
        css=self:_thought_popup_css(),
        metrics=metrics,
    }
    return true
end
function Plugin:_on_thought_tap(ges)
    if not self.ui or not self.ui.link or not self.ui.link.getLinkFromGes then return false end
    local ok,link=pcall(self.ui.link.getLinkFromGes,self.ui.link,ges); if not ok or not link then return false end
    local href=extract_thought_href(link,{},0); if not href then return false end
    return self:_show_thought_href(href)
end
function Plugin:_setup_thought_tap()
    if self._thought_tap_setup or not self.ui or not self.ui.registerTouchZones then return end
    local ok,Device=pcall(require,"device"); if ok and Device.isTouchDevice and not Device:isTouchDevice() then return end
    self.ui:registerTouchZones({{id="miuread_thought_popup",ges="tap",screen_zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=1},overrides={"tap_link"},handler=function(ges) return self:_on_thought_tap(ges) end}})
    self._thought_tap_setup=true
end
function Plugin:onReadSettings() end
function Plugin:onReaderReady()
    logger.info("[MiuRead][Sync] reader ready")
    self:_teardown_thought_tap(); self:_setup_thought_tap()
    self._progress_prompted_book_id=nil
    self._progress_check_running=false
    self.sync:on_reader_ready()
    local current=self.sync:record()
    if current and current.book then self.store:mark_last_read(current.book.book_id,current.path) end
    if self.store:preferences().sync.progress_enabled~=false then
        UIManager:scheduleIn(1,function()
            if self.ui and self.ui.document then self:ensure_read_report_progress("reader_ready",true) end
        end)
    end
end
function Plugin:onPageUpdate(page)
    self.sync:on_page(page)
end
function Plugin:onSuspend() self._suspended_at=os.time(); self.sync:on_suspend() end
function Plugin:onResume() local slept=self._suspended_at and os.time()-self._suspended_at or 0; self._suspended_at=nil; self.sync:on_resume(slept) end
function Plugin:onCloseDocument() self:_teardown_thought_tap(); self._progress_prompted_book_id=nil; self._progress_check_running=false; self.sync:on_close() end
function Plugin:onFlushSettings() self.store:flush() end
return Plugin
