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
local api={}
local calls={}
function api:store_home()
    calls[#calls+1]="home"
    local recommendations={}
    for i=1,7 do
        recommendations[i]={bookInfo={bookId="r"..i,title="推荐书"..i,author="作者甲"}}
    end
    return {search={text="书城搜索"},data={
        {type=23,name="旧推荐"},
        {type=1001,name="榜单",categories={{categoryId="raw-only",title="raw-only"},{categoryId="rising",title="飙升榜",
            lectureBooks={{bookInfo={bookId="s",title="榜单书",author="作者乙"}}}}}},
        {type=40,name="分类",categories={{categoryId="fiction",title="文学",covers={"cover1","cover2"},
            sublist={{categoryId="fiction2",title="小说"}}}}},
        {type=9999,name="忽略"},
    },updated={{type=23,name="猜你喜欢",books=recommendations}}}
end
function api:store_categories()
    calls[#calls+1]="categories"
    return {data={{categories={{categoryId="raw-only",title="raw-only"},
        {categoryId="rising",title="飙升榜"},{categoryId="1",title="文学"}}}}}
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
function host:search_dialog(title,back) opened=title; back() end
online=true
Storefront.open(host)
assert(#calls==1 and calls[1]=="home" and repaints==1)
assert(menu.title=="微信读书书城" and menu.rows[1].text=="猜你喜欢" and menu.rows[1].cards[1].title=="推荐书1")
assert(menu.opts.toolbar[1][1].label=="搜索书名、作者")
menu.opts.on_page_change(2)
menu.opts.toolbar[1][1].callback()
assert(opened=="搜索微信读书" and menu.opts.initial_page==2)
assert(menu.rows[1].section_actions[1].label=="换一批")
menu.rows[1].section_actions[1].callback()
assert(menu.rows[1].cards[1].title=="推荐书4")
menu.rows[1].section_actions[2].callback()
assert(menu.title=="猜你喜欢" and #menu.rows==7)
menu.rows[2].callback()
assert(opened.bookId=="r2" and #calls==1,"return to discovery must reuse loaded books")
menu.opts.on_back()
menu.opts.toolbar[2][2].callback()
assert(menu.title=="榜单" and #menu.rows==1 and menu.rows[1].text=="飙升榜")
menu.opts.on_back()
menu.opts.on_back()
assert(opened=="sources")
online=false
Storefront.open(host)
assert(menu.rows[2].text=="榜单" and #calls==2)
local home=Data.home(api:store_home())
assert(home.search_hint=="书城搜索" and #home.sections==3)
assert(home.sections[2].categories[1].rank and home.sections[2].categories[1].id=="rising"
    and home.sections[2].books[1].bookId=="s")
assert(not home.sections[3].categories[1].rank and #home.sections[3].categories[1].covers==2)

local pending,finished,cover_runs
package.loaded["ui/uimanager"].scheduleIn=function(_,_,fn) pending=fn end
package.loaded["miuread.async"]={new=function() return {
    available=function() return true end,cancel=noop,
    run=function(_,_,_,done) cover_runs=(cover_runs or 0)+1; finished=done end,
} end}
host.library={}
host.store.temp_dir="/app/tmp"
online=true
Storefront.open(host)
local home_view=menu
local repaint_before=repaints
local first_book=menu.rows[1].cards[1].book
first_book.cover="https://synthetic.invalid/cover"
menu.opts.on_visible(menu,menu.rows,1,1)
assert(pending and not cover_runs)
pending()
assert(cover_runs==1 and finished and repaints==repaint_before)
menu.opts.on_dismiss()
finished{ok=true,value={[first_book.cover]="/app/cover.jpg"}}
assert(repaints==repaint_before and not home_view.rows[1].cards[1].path())

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
