package.path="./miuread.koplugin/?.lua;"..package.path
local function copy(v)
    if type(v)~="table" then return v end
    local out={}
    for k,value in pairs(v) do out[k]=copy(value) end
    return out
end
local function noop() end
local function trim(v) return tostring(v or ""):match("^%s*(.-)%s*$") end
local U={copy=copy,trim=trim,utf8_truncate=function(v) return v end}
package.loaded["miuread.util"]=U
package.loaded["miuread.api_transport"]={preference=function() return "eink" end}
package.loaded["ui/uimanager"]={close=noop}
package.loaded["miuread.shelf_view"]={}
package.loaded["ui/widget/buttondialog"]={extend=function(_,klass) return klass end}
package.loaded["miuread.transient_guard"]={close_all=noop}
local repaints=0
package.loaded["miuread.reader_list_dialog"]={refresh=function() repaints=repaints+1 end}
package.loaded.logger={info=noop,warn=noop}
local Data=require("miuread.bookstore_data")
local Storefront=require("miuread.bookstore")
local rank={{categoryId="rising",title="飙升榜"}}
local api={}
local calls={}
function api:recommend_books() calls[#calls+1]="recommend"; return {books={{bookId="r",title="推荐书",author="作者甲"}}} end
function api:store_categories() calls[#calls+1]="categories"; return {_api_channel="eink",data={{categories=rank}}} end
function api:for_channel(channel) assert(channel=="eink"); return self end
function api:category_books(id,offset,is_rank)
    assert(id=="rising" and offset==0 and is_rank)
    calls[#calls+1]="rank"
    return {books={{bookId="s",title="榜单书",author="作者乙"}}}
end
package.loaded["miuread.api"]={new=function() return api end}
package.loaded["miuread.reader"]={new=function() end}
package.loaded["miuread.http"]={new=function() end}
local menu,opened,online
local host={store={auth=function() return {account={vid="fixture"},login_session_id="a"} end}}
function host:_interactive_child_store() return {snapshot=function() return {},false end} end
function host:logged_in() return true end
function host:is_online() return online end
function host:_show_miuread_menu(title,rows,opts) menu={title=title,rows=rows,opts=opts}; return menu end
function host:_run_interactive_network(_,_,worker,done,opts)
    assert(opts.silent)
    done{ok=true,value=worker()}
    return true
end
function host:book_menu(book,back) opened=book; back() end
function host:show_book_sources() opened="sources" end
online=true
Storefront.open(host)
assert(#calls==3 and calls[3]=="rank" and repaints==1)
assert(menu.title=="微信读书" and menu.rows[2].text=="推荐书" and menu.rows[4].text=="榜单书")
menu.rows[2].callback()
assert(opened.bookId=="r" and #calls==3,"return to discovery must reuse loaded books")
menu.opts.on_back()
assert(opened=="sources")
online=false
Storefront.open(host)
assert(menu.rows[4].text=="榜单书" and #calls==3)

local cloud=Data.recent_books({items={
    {book={bookId="fresh",title="云端最新"},readUpdateTime=1800000000000},
    {book={bookId="fresh",title="重复"}},
    {isTTS=true,book={bookId="audio"}},
    {isRecommend=1,book={bookId="promo"}},
    {book={bookId="article",type=1}},
    {book={bookId="unknown",title="无时间戳"}},
}})
assert(#cloud.books==2 and cloud.books[1].last_opened==1800000000 and cloud.books[2].cloud_recent_order==2)
assert(Data.recent_books({items={}}).unchanged)
package.loaded.datastorage={getDataDir=function() return "/app" end,getSettingsDir=function() return "/settings" end}
package.loaded.luasettings={}
package.loaded.pluginloader={getPluginInstance=function() end}
package.loaded["libs/libkoreader-lfs"]={attributes=function() end}
local Library=require("miuread.unified_library")
local data=Library.build{account={{bookId="older",title="旧书"}},recent_weread=cloud.books}
assert(#data.shelf==1 and #data.all==1 and #data.recent==2)
assert(data.recent[1].bookId=="fresh" and data.recent[2].bookId=="unknown")
assert(not data.recent[1].in_shelf and not data.recent[1].local_available)

local file=assert(io.open("miuread.koplugin/main.lua","rb"))
local source=file:read("*a")
file:close()
local from=assert(source:find("function Plugin:_show_zlibrary_search(",1,true))
local to=assert(source:find("function Plugin:show_zlibrary()",from,true))
local menu_calls,zquery,page_calls,recorded={},nil,0,nil
local plugin={store={get=function() return {} end,set=function(_,_,rows) recorded=rows; return true end}}
function plugin:_show_miuread_menu(title,rows,opts) menu_calls[#menu_calls+1]={title=title,rows=rows,opts=opts} end
function plugin:_zlibrary_run(key,_,worker,complete)
    local value=worker()
    if key=="search" then page_calls=page_calls+1 end
    complete(value)
    return true
end
function plugin:_refresh_local_files() end
function plugin:_notify_home_data_changed() end
local target="/books/test.epub"
package.loaded["miuread.zlibrary_source"]={
    search=function(_,_,query,page) zquery=query; assert(page==2); return {
        books={{title="检索结果",author="作者丙",extension="epub"}},
    } end,
    download=function() return target end,
}
local env=setmetatable({Plugin=plugin,U=U,UnifiedLibrary=Library,LocalLibrary={normalize=function(v) return v end},
    lfs={attributes=function() return {mode="file",size=25,modification=8} end}},{__index=_G})
setfenv(assert(loadstring(source:sub(from,to-1))),env)()
plugin:_show_zlibrary_search({},"标题",2)
local result=menu_calls[#menu_calls]
assert(result.rows[1].post_text=="作者丙 · EPUB")
result.opts.on_page_change(3)
result.rows[1].callback()
menu_calls[#menu_calls].rows[1].callback()
assert(recorded[target].size==25 and menu_calls[#menu_calls].title=="下载完成")
menu_calls[#menu_calls].rows[2].callback()
result=menu_calls[#menu_calls]
assert(result.title=="Z-Library · 标题" and result.opts.initial_page==3 and page_calls==1 and zquery=="标题")
print("Book sources, same-result return, and isolated cloud history passed")