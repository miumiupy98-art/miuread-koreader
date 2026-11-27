local U=require("miuread.util")
local Data=require("miuread.bookstore_data")
local UIManager=require("ui/uimanager")
local ShelfView=require("miuread.shelf_view")
local ReaderList=require("miuread.reader_list_dialog")
local RawButtonDialog=require("ui/widget/buttondialog")
local TransientGuard=require("miuread.transient_guard")
local logger=require("logger")
local has_socket,socket=pcall(require,"socket")
local clock=has_socket and socket.gettime or os.time
local M={}
local ButtonDialog=RawButtonDialog:extend{modal=true,_miuread_transient=true,_miuread_modal_surface=true}
function ButtonDialog:handleEvent(event)
    return require("miuread.gesture_bridge").handle(RawButtonDialog,self,event)
end

local function close_loading(s)
    local dialog=s and s.loading
    if not dialog then return end
    s.loading=nil
    dialog.bookstore_done=true
    UIManager:close(dialog)
end

local function identity(plugin)
    local a=plugin.store:auth()
    local vid=tostring((a.account or {}).vid or "")
    if vid=="" then vid=tostring((a.cookies or {}).wr_vid or "") end
    return vid,tostring(a.login_session_id or "")
end

local function state(plugin)
    local vid,session=identity(plugin)
    local mode=require("miuread.api_transport").preference(plugin.store)
    local current=plugin._bookstore
    if not current or current.vid~=vid or current.session~=session or current.mode~=mode then
        M.reset(plugin)
        current={vid=vid,session=session,mode=mode,cache={},order={},generation=0}
        plugin._bookstore=current
    end
    return current
end

local function close_view(plugin)
    local s=plugin._bookstore
    close_loading(s)
    local view=s and s.view
    if s then s.view=nil end
    if view and not view._miu_closed then UIManager:close(view) end
    if plugin._interactive_network_key and plugin._interactive_network_key:find("^bookstore:") then
        plugin:_cancel_interactive_network("bookstore navigation")
    end
end

local function cache(s,key,value)
    s.cache[key]={value=U.copy(value),at=os.time()}
    for i=#s.order,1,-1 do if s.order[i]==key then table.remove(s.order,i) end end
    s.order[#s.order+1]=key
    while #s.order>Data.CACHE_LIMIT do s.cache[table.remove(s.order,1)]=nil end
end

local function request(plugin,key,label,fn,callback,timeout,quiet)
    if not quiet then TransientGuard.close_all() end
    local s=state(plugin)
    s.generation=s.generation+1
    local generation=s.generation
    local auth=U.copy(plugin.store:auth())
    local data_dir,temp_dir=plugin.store.data_dir,plugin.store.temp_dir
    close_loading(s)
    if not quiet then
    local dialog
    dialog=ButtonDialog:new{
        title=label.."\n\n"..(key:find("^shelf:") and "正在确认微信书架，请稍候。" or "正在后台获取，请稍候。"),title_align="center",
        close_callback=function()
            if dialog.bookstore_done then return end
            dialog.bookstore_done=true
            if s.loading==dialog then s.loading=nil end
            if generation==s.generation then
                s.generation=s.generation+1
                if plugin._interactive_network_key=="bookstore:"..key then
                    plugin:_cancel_interactive_network("bookstore cancelled")
                end
            end
        end,
        buttons={{{text="取消",callback=function() UIManager:close(dialog) end}}},
    }
    s.loading=dialog
    UIManager:show(dialog)
    end
    local api_mode=require("miuread.api_transport").preference(plugin.store)
    local started,err=plugin:_run_interactive_network("bookstore:"..key,label,function()
        local store=plugin:_interactive_child_store(auth,data_dir,temp_dir,api_mode)
        local Api=require("miuread.api")
        local Http=require("miuread.http")
        local Reader=require("miuread.reader")
        local http=Http:new(store)
        local ok,value=pcall(fn,Api:new(http,store,Reader:new(http,store)))
        local current,changed=store:snapshot()
        return {request_ok=ok,value=ok and value or nil,error=not ok and tostring(value) or nil,
            auth=current,auth_changed=changed}
    end,function(result)
        if generation~=s.generation then return end
        close_loading(s)
        local vid,session=identity(plugin)
        if plugin._bookstore~=s or vid~=s.vid or session~=s.session then return end
        if not result or result.ok~=true then callback(false,result and result.error or "后台请求未完成"); return end
        local payload=type(result.value)=="table" and result.value or {}
        if payload.auth_changed then plugin:_apply_interactive_auth{auth=payload.auth,changed=true} end
        callback(payload.request_ok==true,payload.request_ok and payload.value or payload.error)
    end,{timeout=timeout or 40,silent=quiet,on_cancel=function()
        if generation~=s.generation then return end
        s.generation=s.generation+1
        close_loading(s)
    end})
    if not started then close_loading(s) end
    return started,err
end

function M.reset(plugin)
    if plugin._bookstore_shelf_auth then
        plugin._bookstore_shelf_auth:cancel()
        plugin._bookstore_shelf_auth=nil
    end
    local s=plugin._bookstore
    if s then
        s.generation=s.generation+1
        if s.cover_worker then s.cover_worker:cancel("bookstore reset") end
        s.cover_view=nil
    end
    close_view(plugin)
    plugin._bookstore=nil
end

local function error_message(plugin,value,label)
    return plugin:_friendly_remote_error(tostring(value or "未知错误"),label)
end

local category_rows

local function load_visible_covers(plugin,s,view,items,first,last)
    if not plugin.library or not plugin:is_online() or not plugin.store.temp_dir then return end
    local batch,keys,seen={},{},{}
    s.cover_paths=s.cover_paths or {}
    s.cover_attempts=s.cover_attempts or {}
    for i=first,last do
        for _,card in ipairs(items[i].cards or {}) do
            local book=card.book
            if book and book.cover~="" and not seen[book.cover] and not s.cover_attempts[book.cover] then
                seen[book.cover]=true
                batch[#batch+1]={bookId=book.bookId,cover=book.cover}
                keys[#keys+1]=book.cover
            end
        end
    end
    local signature=table.concat(keys,"\n")
    if s.cover_view==view and s.cover_batch==signature then return end
    if s.cover_worker then s.cover_worker:cancel("visible books changed") end
    s.cover_view,s.cover_batch=view,signature
    if #batch==0 then return end
    UIManager:scheduleIn(.20,function()
        if view.closed or s.cover_view~=view or s.cover_batch~=signature then return end
        s.cover_worker=s.cover_worker or require("miuread.async"):new(plugin.store,{disable_fallback=true})
        if not s.cover_worker:available() then return end
        local covers_dir=plugin.store.covers_dir
        local started_at=clock()
        s.cover_worker:run("bookstore_cover_batch",function()
            local store={covers_dir=covers_dir,auth=function() return {} end,get=function(_,_,default) return default end}
            local http=require("miuread.http"):new(store)
            local library=require("miuread.library"):new(nil,http,store)
            local result={}
            for _,book in ipairs(batch) do
                local ok,path=pcall(library.cache_cover,library,book,{thumbnail=true,cache_suffix="store",
                    persist_index=false,skip_index_lookup=true,retries=0,timeout={3,5}})
                if ok and path then result[book.cover]=path end
            end
            return result
        end,function(result)
            if view.closed or s.cover_view~=view or s.cover_batch~=signature then return end
            logger.info("[MiuRead][Bookstore] covers","count=",#batch,"ms=",math.floor((clock()-started_at)*1000))
            for _,key in ipairs(keys) do s.cover_attempts[key]=true end
            if result and result.ok and next(result.value or {}) then
                for key,path in pairs(result.value) do s.cover_paths[key]=path end
                ReaderList.refresh(view)
            end
        end,38)
    end)
end

function M.open(plugin,force)
    local started_at=clock()
    close_view(plugin)
    if plugin._shelf_view then plugin:_close_current_shelf() end
    local s=state(plugin)
    local cached=s.cache.discovery
    local logged_in=plugin:logged_in()
    local data=U.copy(cached and cached.value or {})
    local failed=false
    local loading=logged_in and plugin:is_online()
        and (force==true or not cached or os.time()-cached.at>Data.CACHE_TTL)
    local rows={}
    local function close_discovery()
        s.cover_view,s.cover_batch=nil,nil
        if s.cover_worker then s.cover_worker:cancel("bookstore home closed") end
        if plugin._interactive_network_key=="bookstore:discovery" then
            plugin:_cancel_interactive_network("source page closed")
        end
    end
    local function back()
        close_discovery()
        plugin:show_book_sources()
    end
    local function reopen() M.open(plugin) end
    local view
    local function book_row(book,on_back)
        return {text=book.title,post_text=book.author,
            callback=function() close_discovery(); plugin:book_menu(book,on_back) end}
    end
    local function open_section(section)
        local items=category_rows(plugin,section.categories,function() open_section(section) end)
        for _,book in ipairs(section.books) do
            items[#items+1]=book_row(book,function() open_section(section) end)
        end
        if #section.books==0 and #section.categories==1 and #section.categories[1].children==0 then
            return items[1].callback()
        end
        plugin:_show_miuread_menu(section.title,items,{page_size=8,on_back=reopen})
    end
    local function render()
        for i=#rows,1,-1 do rows[i]=nil end
        local function add_section(section)
            local function show_all() close_discovery(); open_section(section) end
            if #section.books==0 then
                rows[#rows+1]={text=section.title,bold=true,post_text="查看分类",callback=show_all}
                return
            end
            local cards={}
            local actions={{label="查看全部",callback=show_all}}
            local offset=s.home_offsets and s.home_offsets[section.kind] or 0
            for i=1,math.min(#section.books,3) do
                local book=section.books[(offset+i-1)%#section.books+1]
                cards[#cards+1]={book=book,title=book.title,callback=book_row(book,reopen).callback,
                    path=function() return s.cover_paths and s.cover_paths[book.cover] end}
            end
            if section.kind==23 and #section.books>3 then
                table.insert(actions,1,{label="换一批",stay=true,callback=function()
                    s.home_offsets=s.home_offsets or {}
                    s.home_offsets[section.kind]=(offset+3)%#section.books
                    render()
                end})
            end
            rows[#rows+1]={text=section.title,cards=cards,section_actions=actions}
        end
        local recent=plugin._home_cloud_recent
        if recent and recent.id==plugin:_home_cloud_recent_key() and #recent.books>0 then
            add_section{title="最近阅读",books=recent.books,categories={}}
        end
        for _,section in ipairs(data.sections or {}) do
            add_section(section)
        end
        if not logged_in then
            rows[#rows+1]={text="扫码登录",callback=function() plugin:require_login("浏览微信读书",reopen) end}
        elseif not data.sections and loading then
            rows[#rows+1]={text="正在加载书城…",enabled=false}
        elseif not data.sections or failed then
            rows[#rows+1]={text=plugin:is_online() and "重新加载书城" or "联网后加载书城",callback=function()
                if plugin:is_online() then M.open(plugin,true) else plugin:toast("请先连接网络",2) end
            end}
        end
    end
    render()
    view=plugin:_show_miuread_menu("微信读书书城",rows,{
        page_size=3,card_rows=true,initial_page=s.home_page,on_page_change=function(page) s.home_page=page end,
        on_visible=function(...) load_visible_covers(plugin,s,...) end,
        on_back=back,toolbar={
            {{label="搜索书名、作者",callback=function()
                close_discovery()
                plugin:search_dialog("搜索微信读书",reopen)
            end}},
            {{label="分类",callback=function() close_discovery(); M.categories(plugin,false) end},
             {label="榜单",callback=function() close_discovery(); M.categories(plugin,true) end}},
        },
        on_dismiss=close_discovery,
    })
    logger.info("[MiuRead][Bookstore] first frame built","ms=",math.floor((clock()-started_at)*1000))
    if not view or not loading then return view end
    local started=request(plugin,"discovery","微信读书书城",function(api)
        local home=Data.home(api:store_home())
        if #home.sections==0 then error("微信读书书城没有返回可展示的栏目",0) end
        return home
    end,function(ok,value)
        if ok then
            data=value
            cache(s,"discovery",data)
        else
            failed=true
            logger.warn("[MiuRead][Bookstore] native homepage load failed",U.first_line(value,120))
        end
        loading=false
        if view.closed then return end
        render()
        ReaderList.refresh(view)
    end,55,true)
    if not started then
        loading=false
        render()
        ReaderList.refresh(view)
    end
    return view
end

category_rows=function(plugin,entries,on_back)
    local rows={}
    for _,entry in ipairs(entries) do
        local current=entry
        local function browse()
            M.browse(plugin,{kind="category",category_id=current.id,rank=current.rank,title=current.title,
                channel=current.channel,
                on_back=on_back or function() M.categories(plugin,current.rank) end})
        end
        if #current.children>0 then
            rows[#rows+1]={text=current.title,post_text=tostring(#current.children).." 个子分类",
                sub_item_table_func=function()
                    local children=category_rows(plugin,current.children,on_back)
                    table.insert(children,1,{text="全部 · "..current.title,callback=browse})
                    return children
                end}
        else rows[#rows+1]={text=current.title,callback=browse} end
    end
    return rows
end

function M.categories(plugin,rank,force)
    close_view(plugin)
    local s=state(plugin)
    local cached=s.cache.categories
    local home=s.cache.discovery
    local title=rank and "榜单" or "分类"
    local function back() return M.open(plugin) end
    local function return_to_picker() return M.categories(plugin,rank) end
    local function home_entries()
        local entries,seen={},{}
        for _,section in ipairs(home and home.value.sections or {}) do
            for _,entry in ipairs(section.categories) do
                if entry.rank==rank and not seen[entry.id] then
                    entries[#entries+1]=entry
                    seen[entry.id]=true
                end
            end
        end
        return entries
    end
    local entries=cached and (rank and cached.value.ranks or cached.value.categories) or home_entries()
    local rows={}
    local loading=plugin:is_online() and (force or not cached or os.time()-cached.at>Data.CACHE_TTL)
    local function render()
        for i=#rows,1,-1 do rows[i]=nil end
        for _,row in ipairs(category_rows(plugin,entries,return_to_picker)) do rows[#rows+1]=row end
        if loading then
            if #rows==0 then rows[1]={text="正在加载"..title.."…",enabled=false} end
        elseif #rows==0 then
            rows[1]={text=plugin:is_online() and "重新加载"..title or "联网后加载"..title,
                callback=function() if plugin:is_online() then M.categories(plugin,rank,true) end end}
        end
    end
    render()
    local view=plugin:_show_miuread_menu(title,rows,{page_size=7,on_back=back,on_close=back,dismiss_to_back=true,
        on_dismiss=function()
            if plugin._interactive_network_key=="bookstore:categories" then
                plugin:_cancel_interactive_network("bookstore picker closed")
            end
        end})
    if not view or not loading then return view end
    local started=request(plugin,"categories",title,function(api)
        return require("miuread.bookstore_data").categories(api:store_categories())
    end,function(ok,value)
        if ok then
            cache(s,"categories",value)
            entries=rank and value.ranks or value.categories
        end
        loading=false
        if not view.closed then render(); ReaderList.refresh(view) end
    end,40,true)
    if not started then loading=false; render(); ReaderList.refresh(view) end
    return view
end

local function book_status(book)
    local parts={}
    if book.newRating then parts[#parts+1]=string.format("推荐 %.0f%%",book.newRating) end
    local reason=U.trim(tostring(book.reason or "")):gsub("[%c]+"," ")
    if reason~="" then parts[#parts+1]=U.utf8_truncate(reason,32,"…") end
    return table.concat(parts," · ")
end

local function show_page(plugin,s,spec,page,cached)
    TransientGuard.close_all()
    close_view(plugin)
    spec.channel=page.channel or spec.channel
    local books=U.copy(page.books)
    local show_covers=not plugin._shelf_covers_enabled or plugin:_shelf_covers_enabled()
    local cover_index=plugin.store:get("cover_index",{})
    for _,book in ipairs(books) do
        book.status_text=book_status(book)
        if spec.rank and book.searchIdx then book.display_title=tostring(book.searchIdx)..". "..book.title end
        if show_covers then book.cover_path=plugin.library:cached_cover_path(book.bookId,cover_index) end
    end
    local title=spec.title.." · 第 "..tostring(spec.page or 1).." 页"..(cached and " · 缓存" or "")
    local function previous()
        local previous_spec=spec.previous
        if previous_spec then M.browse(plugin,U.copy(previous_spec))
        else plugin:toast("已是第一页",2) end
    end
    local function next_page()
        if not page.has_more then plugin:toast("已是最后一页",2); return end
        local next_spec=U.copy(spec)
        next_spec.previous=U.copy(spec)
        next_spec.cursor=page.next_cursor
        next_spec.session_id=page.session_id~="" and page.session_id or spec.session_id
        next_spec.page=(spec.page or 1)+1
        M.browse(plugin,next_spec)
    end
    local function back() if spec.on_back then spec.on_back() else M.open(plugin) end end
    local function select(book)
        close_view(plugin)
        plugin:book_menu(book,function() M.browse(plugin,U.copy(spec)) end)
    end
    if #books==0 then
        plugin:list(title,{
            {text="这一页暂无书籍",enabled=false},
            {text="返回",callback=back},
            {text="上一页",callback=previous},
            {text="刷新",callback=function() M.browse(plugin,U.copy(spec),true) end},
        })
        return
    end
    if plugin._shelf_view then plugin:_close_current_shelf() end
    s.view=ShelfView.show{
        title=title,books=books,show_covers=show_covers,selected_tab="",
        tabs={{id="back",label="返回",callback=back},
            {id="previous",label="上一页",callback=previous},
            {id="next",label=page.has_more and "下一页" or "已到底",callback=next_page}},
        left_action_label="搜索微信读书",right_action_label="刷新",
        on_search=function()
            close_view(plugin)
            plugin:search_dialog("搜索微信读书",function() M.browse(plugin,U.copy(spec)) end)
        end,
        on_refresh=function() M.browse(plugin,U.copy(spec),true) end,
        on_select=select,on_hold=select,
        on_page_changed=function(view_page,first,last,view)
            -- Never use the legacy foreground network fallback for covers.
            if show_covers and plugin.cover_async and plugin.cover_async:available() then
                plugin:_on_shelf_page(books,view,view_page,first,last)
            end
        end,
        on_rendered=function() plugin:_clear_cover_guard() end,
        on_close=function(view)
            if s.view==view then s.view=nil end
            plugin:_cancel_cover_loading()
            if plugin._interactive_network_key and plugin._interactive_network_key:find("^bookstore:page:") then
                plugin:_cancel_interactive_network("bookstore closed")
            end
        end,
    }
end

function M.browse(plugin,spec,force)
    local s=state(plugin)
    spec=U.copy(spec)
    if spec.channel=="eink" and s.mode=="web" then
        plugin:info("接口设置已变化，请重新打开书城后重试。")
        return false
    end
    spec.cursor=spec.cursor or 0
    spec.page=spec.page or 1
    local key=Data.key(spec)
    local cached=s.cache[key]
    if cached and not force then
        show_page(plugin,s,spec,U.copy(cached.value),os.time()-cached.at>Data.CACHE_TTL)
        return true
    end
    local query={kind=spec.kind,category_id=spec.category_id,rank=spec.rank,book_id=spec.book_id,
        cursor=spec.cursor,session_id=spec.session_id,channel=spec.channel}
    return request(plugin,"page:"..key,spec.title,function(api)
        -- Category IDs, cursors and recommendation sessions belong to the
        -- source that produced them. A fresh list can choose another source.
        if query.channel then api=api:for_channel(query.channel) end
        local raw
        if query.kind=="recommend" then raw=api:recommend_books(query.cursor,Data.PAGE_SIZE)
        elseif query.kind=="similar" then raw=api:similar_books(query.book_id,query.cursor,Data.PAGE_SIZE,query.session_id)
        else raw=api:category_books(query.category_id,query.cursor,query.rank) end
        return require("miuread.bookstore_data").page(query.kind,raw,query.cursor,Data.PAGE_SIZE)
    end,function(ok,value)
        if not ok then
            if cached then show_page(plugin,s,spec,U.copy(cached.value),true) end
            plugin:info(error_message(plugin,value,"书城加载")); return
        end
        cache(s,key,value)
        show_page(plugin,s,spec,value,false)
    end)
end

function M.similar(plugin,book,back)
    if not plugin:require_login() then return false end
    return M.browse(plugin,{kind="similar",book_id=tostring(book.bookId),
        title="相似推荐 · "..tostring(book.title),on_back=back})
end

local function pending(plugin,id)
    local vid=identity(plugin)
    local all=U.copy(plugin.store:get("bookstore_shelf_pending",{}))
    if type(all)~="table" then all={} end
    if type(all[vid])~="table" then all[vid]=nil end
    return all,vid,(all[vid] or {})[id]
end

local function save_pending(plugin,id,value)
    local before=plugin.store:get("bookstore_shelf_pending",{})
    local all,vid=pending(plugin,id)
    all[vid]=all[vid] or {}
    all[vid][id]=value
    if next(all[vid])==nil then all[vid]=nil end
    local saved=plugin.store:set("bookstore_shelf_pending",all)
    if saved~=true then plugin.store:set_deferred("bookstore_shelf_pending",before) end
    return saved
end

local function known_membership(plugin,id)
    local observed=state(plugin).cache["shelf:"..id]
    if observed and os.time()-observed.at<=Data.CACHE_TTL then return observed.value end
    local snapshot=plugin.store:shelf_cache()
    local rows=type(snapshot.raw_books)=="table" and #snapshot.raw_books>0 and snapshot.raw_books or snapshot.books
    for _,cached in ipairs(rows or {}) do
        if tostring(cached.bookId or cached.book_id or "")==id then return true end
    end
    return false
end

function M.shelf_action(plugin,book,on_verified)
    local id=tostring(book.bookId or book.book_id or "")
    if id=="" then return nil end
    local _,_,entry=pending(plugin,id)
    local present=known_membership(plugin,id)
    return {text=entry and "确认微信书架状态" or (present and "从微信书架移除" or "加入微信书架"),
        callback=function()
            if present then M.remove_from_shelf(plugin,book,on_verified) else M.add_to_shelf(plugin,book,on_verified) end
        end}
end

local function shelf_error_summary(value)
    if not value then return "none" end
    local Http=require("miuread.http")
    local text=tostring(value)
    local code=tonumber(Http.auth_error_code(text))
        or tonumber(text:lower():match('"errcode"%s*:%s*(%-?%d+)'))
    local status=text:match("HTTP (%d+)")
    local kind=Http.is_auth_error(text) and "auth" or (Http.is_network_error(text) and "network" or "response")
    return kind..(code and (":code="..tostring(code)) or "")..(status and (":http="..status) or "")
end

local function shelf_error_message(plugin,value,desired)
    if require("miuread.http").is_auth_error(value) then
        return "当前凭证未通过书架接口验证。"..(desired and "加入" or "移除")
            .."请求不会自动重试。\n接口错误："..shelf_error_summary(value)
    end
    return error_message(plugin,value,"书架确认")
end

local function authorize_shelf(plugin)
    return plugin:confirm_eink_authorization()
end

local function change_shelf(plugin,book,desired,confirmed,on_verified)
    if not plugin:require_login() then return false end
    local id=tostring(book.bookId or book.book_id or "")
    if id=="" then return false end
    if plugin._interactive_network_key=="bookstore:shelf:"..id then
        plugin:toast("正在确认书架状态",2); return false
    end
    if not plugin:is_online() then plugin:info("网络不可用，请联网后重试。"); return false end
    local _,_,old=pending(plugin,id)
    -- A pending operation always verifies its original target, even if a stale
    -- menu now requests the opposite action. Old add-only records remain valid.
    if old then desired=not (type(old)=="table" and old.desired==false) end
    if not desired and not old and not confirmed then
        local vid,session=identity(plugin)
        local target=U.copy(book)
        plugin:_confirm_shelf_removal(target,function()
            local current_vid,current_session=identity(plugin)
            if current_vid~=vid or current_session~=session then
                plugin:info("登录账号已变更，请重新选择书籍操作。")
                return
            end
            change_shelf(plugin,target,false,true,on_verified)
        end)
        return true
    end
    -- Persist before handing the POST to a subprocess. On cancellation, death
    -- or stale callbacks the next user action performs verification only.
    if not old and save_pending(plugin,id,{started_at=os.time(),desired=desired})~=true then
        plugin:info("无法保存书架变更任务，请稍后重试。")
        return false
    end
    local s=state(plugin)
    local shelf_view=plugin._shelf_view
    local started=request(plugin,"shelf:"..id,"微信书架",function(api)
        return require("miuread.shelf_membership").run(api,id,desired,old~=nil)
    end,function(ok,value)
        local result=ok and type(value)=="table" and value or {}
        local log=(result.state=="verified" or result.state=="mismatch") and logger.info or logger.warn
        -- Only log stages and numeric codes: no response body or credentials.
        log("[MiuRead][Bookstore] shelf result","book=",id,"target=",desired and "present" or "absent",
            "state=",result.state or "worker_failed","stage=",result.stage or "membership",
            "present=",tostring(result.present),"error=",shelf_error_summary(not ok and value or result.error),
            "write=",shelf_error_summary(result.write_error),"read=",shelf_error_summary(result.read_error))
        if result.state=="blocked" and not old then
            if save_pending(plugin,id,nil)~=true then
                logger.warn("[MiuRead][Bookstore] shelf preflight persistence failed")
            end
            if type(result.present)=="boolean" then cache(s,"shelf:"..id,result.present) end
            if result.stage=="credentials" and (require("miuread.http").is_auth_error(result.error)
                or tostring(result.error):find("[MiuReadShelfAuthorization]",1,true)) then
                authorize_shelf(plugin)
            else
                plugin:info("未提交"..(desired and "加入" or "移除").."，可稍后重新操作。\n\n"
                    ..shelf_error_message(plugin,result.error,desired))
            end
            return
        end
        if ok and type(value)=="table" and (value.state=="verified" or value.state=="mismatch") then
            local saved=save_pending(plugin,id,nil)
            if saved~=true then logger.warn("[MiuRead][Bookstore] shelf verification persistence failed") end
            cache(s,"shelf:"..id,value.present)
            if value.state=="verified" then
                plugin:toast(desired and (value.already and "已在微信书架" or "已加入微信书架")
                    or (value.already and "已不在微信书架" or "已从微信书架移除"),3)
            else
                plugin:info(value.present and "已确认本书仍在微信书架，可再次选择移除。"
                    or "已确认本书不在微信书架，可再次选择加入。")
            end
            plugin:_refresh_shelf_async(function(_,_,err)
                local vid,session=identity(plugin)
                if err or plugin._bookstore~=s or vid~=s.vid or session~=s.session then return end
                if plugin._home_enabled and plugin:_home_enabled() then
                    plugin:_home_apply_remote_cache_snapshot()
                end
                if value.state=="verified" and shelf_view and plugin._shelf_view==shelf_view
                    and not shelf_view._miu_closed then
                    plugin:_reopen_shelf(plugin._last_shelf_mode,plugin._last_shelf_section)
                end
            end,true,{skip_online_probe=true})
            if value.state=="verified" and on_verified then on_verified() end
            return
        end
        local message=ok and type(value)=="table" and value.error or value
        plugin:info((desired and "加入" or "移除").."结果尚未确认。再次点击书架操作将先核对云端状态。\n\n"
            ..shelf_error_message(plugin,message,desired))
    end,75)
    -- A worker that never started cannot have submitted a write.
    if not started and not old then save_pending(plugin,id,nil) end
    return started
end

function M.add_to_shelf(plugin,book,on_verified)
    return change_shelf(plugin,book,true,false,on_verified)
end

function M.remove_from_shelf(plugin,book,on_verified)
    return change_shelf(plugin,book,false,false,on_verified)
end

return M
