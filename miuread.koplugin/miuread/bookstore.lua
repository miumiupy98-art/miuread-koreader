local U=require("miuread.util")
local Data=require("miuread.bookstore_data")
local UIManager=require("ui/uimanager")
local ShelfView=require("miuread.shelf_view")
local RawButtonDialog=require("ui/widget/buttondialog")
local TransientGuard=require("miuread.transient_guard")
local logger=require("logger")
local M={}
local ButtonDialog=RawButtonDialog:extend{_miuread_transient=true,_miuread_modal_surface=true}
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
    local current=plugin._bookstore
    if not current or current.vid~=vid or current.session~=session then
        M.reset(plugin)
        current={vid=vid,session=session,cache={},order={},generation=0}
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

local function request(plugin,key,label,fn,callback,timeout)
    TransientGuard.close_all()
    local s=state(plugin)
    s.generation=s.generation+1
    local generation=s.generation
    local auth=U.copy(plugin.store:auth())
    local data_dir,temp_dir=plugin.store.data_dir,plugin.store.temp_dir
    close_loading(s)
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
    local started,err=plugin:_run_interactive_network("bookstore:"..key,label,function()
        local store=plugin:_interactive_child_store(auth,data_dir,temp_dir)
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
    end,{timeout=timeout or 40,on_cancel=function()
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
    if s then s.generation=s.generation+1 end
    close_view(plugin)
    plugin._bookstore=nil
end

local function error_message(plugin,value,label)
    return plugin:_friendly_remote_error(tostring(value or "未知错误"),label)
end

function M.open(plugin)
    state(plugin)
    close_view(plugin)
    if plugin._shelf_view then plugin:_close_current_shelf() end
    return plugin:list("微信读书 · 书城",{
        {text="为你推荐",post_text="根据阅读记录发现可能喜欢的书",callback=function()
            if plugin:require_login() then M.browse(plugin,{kind="recommend",title="为你推荐"}) end
        end},
        {text="排行榜",post_text="总榜 · 飙升 · 新书 · 热门",callback=function() M.categories(plugin,true) end},
        {text="分类浏览",post_text="按主题与子分类浏览",callback=function() M.categories(plugin,false) end},
        {text="搜索微信读书",post_text="搜索全部图书",callback=function() plugin:search_dialog("搜索微信读书") end},
        {text="微信书架",post_text="查看已加入的图书",callback=function() plugin:show_shelf(false,false,"account") end},
    })
end

local function category_rows(plugin,entries)
    local rows={}
    for _,entry in ipairs(entries) do
        local current=entry
        local function browse()
            M.browse(plugin,{kind="category",category_id=current.id,rank=current.rank,title=current.title,
                on_back=function() M.categories(plugin,current.rank) end})
        end
        if #current.children>0 then
            rows[#rows+1]={text=current.title,post_text=tostring(#current.children).." 个子分类",
                sub_item_table_func=function()
                    local children=category_rows(plugin,current.children)
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
    local function show(data,stale)
        local entries=rank and data.ranks or data.categories
        local rows=category_rows(plugin,entries or {})
        table.insert(rows,1,{text="返回书城",callback=function() M.open(plugin) end})
        rows[#rows+1]={text="刷新分类与榜单",callback=function() M.categories(plugin,rank,true) end}
        if #entries==0 then table.insert(rows,2,{text="暂时没有可用分类",enabled=false}) end
        plugin:list((rank and "排行榜" or "分类浏览")..(stale and " · 缓存" or ""),rows)
    end
    local cached=s.cache.categories
    if cached and not force then show(U.copy(cached.value),os.time()-cached.at>Data.CACHE_TTL); return true end
    return request(plugin,"categories","分类与榜单",function(api)
        return require("miuread.bookstore_data").categories(api:store_categories())
    end,function(ok,value)
        if not ok then
            if cached then show(U.copy(cached.value),true) end
            plugin:info(error_message(plugin,value,"分类加载")); return
        end
        cache(s,"categories",value)
        show(value,false)
    end)
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
        on_search=function() close_view(plugin); plugin:search_dialog("搜索微信读书") end,
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
    spec.cursor=spec.cursor or 0
    spec.page=spec.page or 1
    local key=Data.key(spec)
    local cached=s.cache[key]
    if cached and not force then
        show_page(plugin,s,spec,U.copy(cached.value),os.time()-cached.at>Data.CACHE_TTL)
        return true
    end
    local query={kind=spec.kind,category_id=spec.category_id,rank=spec.rank,book_id=spec.book_id,
        cursor=spec.cursor,session_id=spec.session_id}
    return request(plugin,"page:"..key,spec.title,function(api)
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

function M.shelf_action(plugin,book)
    local id=tostring(book.bookId or book.book_id or "")
    if id=="" then return nil end
    local _,_,entry=pending(plugin,id)
    local present=known_membership(plugin,id)
    return {text=entry and "确认微信书架状态" or (present and "从微信书架移除" or "加入微信书架"),
        callback=function()
            if present then M.remove_from_shelf(plugin,book) else M.add_to_shelf(plugin,book) end
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

local function authorize_shelf(plugin,detail)
    local vid,session=identity(plugin)
    local dialog
    dialog=ButtonDialog:new{
        title="书架管理需要客户端授权\n\n请使用微信扫描二维码，并选择与觅阅相同的微信读书账号。授权后，再重新选择移除。"
            ..(detail and ("\n\n接口错误："..shelf_error_summary(detail)) or ""),title_align="center",
        buttons={{{text="微信扫码授权",callback=function()
            UIManager:close(dialog)
            local current_vid,current_session=identity(plugin)
            if current_vid~=vid or current_session~=session then
                plugin:info("登录账号已变更，请重新选择书籍操作。")
                return
            end
            if plugin._bookstore_shelf_auth then plugin._bookstore_shelf_auth:cancel() end
            if plugin.auth_flow then plugin.auth_flow:cancel() end
            local host={
                is_online=function() return plugin:is_online() end,
                online=function(_,label,fn) plugin:online(label,fn) end,
                toast=function(_,text,duration) plugin:toast(text,duration) end,
                info=function(_,text) plugin:info(text) end,
                on_auth_success=function()
                    plugin:info("书架管理授权已保存。请重新选择要移除的书籍。")
                end,
            }
            local Client=require("miuread.shelf_client")
            local Auth=require("miuread.auth")
            local flow=Auth:new(plugin.http,plugin.store,host,Client.new(plugin.http,plugin.store))
            plugin._bookstore_shelf_auth=flow
            flow:start()
        end},{text="取消",callback=function() UIManager:close(dialog) end}}},
    }
    TransientGuard.close_all()
    UIManager:show(dialog)
    return true
end

local function change_shelf(plugin,book,desired,confirmed)
    if not plugin:require_login() then return false end
    local auth=plugin.store:auth()
    if tostring((auth.cookies or {}).wr_skey or "")=="" then
        plugin:info("管理微信书架需要网页登录，请先扫码登录或修复登录。")
        return false
    end
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
            change_shelf(plugin,target,false,true)
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
                authorize_shelf(plugin,result.error)
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

function M.add_to_shelf(plugin,book)
    return change_shelf(plugin,book,true)
end

function M.remove_from_shelf(plugin,book)
    return change_shelf(plugin,book,false)
end

return M
