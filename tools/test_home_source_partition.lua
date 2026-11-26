-- Verify provider ownership even when generated EPUBs sit inside a local directory.
package.path="./miuread.koplugin/?.lua;"..package.path
package.loaded.datastorage={getSettingsDir=function() return "/settings" end,getDataDir=function() return "/app" end}
package.loaded.luasettings={open=function()
    return {readSetting=function(_,k) if k=="zlibrary_download_dir" then return "/zed" end end}
end}
package.loaded.pluginloader={getPluginInstance=function() end}
package.loaded.logger={warn=function() end}
package.loaded["miuread.util"]={}
local files={["/settings/zlibrary.lua"]="file",["/zed"]="directory",["/zed/shared.epub"]="file",
    ["/zed/z-book.epub"]="file",["/library/shared.epub"]="file",["/library/article.html"]="file",
    ["/library/off-shelf.epub"]="file",["/other/history.epub"]="file"}
package.loaded["libs/libkoreader-lfs"]={
    attributes=function(path,field)
        if field=="mode" then return files[path] end
        if files[path] then return {mode=files[path],modification=100} end
    end,
    dir=function(path)
        assert(path=="/zed")
        local i,result=0,{"shared.epub","z-book.epub"}
        return function() i=i+1; return result[i] end
    end,
}
package.loaded["miuread.local_library"]={
    normalize=function(path) return tostring(path or "") end,
    book_from_path=function(path) return {file=path,title=path:match("[^/]+$"),local_file=true,source="local"} end,
}
local Library=require("miuread.unified_library")
local input={
    account={{bookId="remote",title="Remote only"},{bookId="download",title="Downloaded"}},
    generated={{book_id="download",file="/zed/shared.epub"},{book_id="off-shelf",file="/library/off-shelf.epub"}},
    mp_articles={{unified_source_id="article",file="/library/article.html",title="Article"}},
    local_rows={
        {file="/zed/shared.epub",title="Same managed file"},{file="/library/shared.epub",title="Same name, different file"},
        {file="/library/article.html",title="Article discovered by filesystem"},{file="/zed/z-book.epub",title="Z book"},
        {file="/library/off-shelf.epub",title="Other managed file"},
    },
    recent_local={
        {file="/zed/shared.epub",read_at=30},{file="/library/shared.epub",read_at=20},
        {file="/other/history.epub",read_at=10},{file="/library/article.html",read_at=25},
    },
    weread_state="ready",
}
local data=Library.build(input)
assert(#data.all==6 and #data.shelf==5 and #data.device==1)
assert(data.device[1].file=="/library/shared.epub")
local weread=Library.apply(data.shelf,{source="weread"},"shelf")
assert(#weread==3)
local downloaded,off_shelf
for _,book in ipairs(weread) do
    if book.book_id=="download" then downloaded=book end
    if book.book_id=="off-shelf" then off_shelf=book end
end
assert(downloaded.local_available and downloaded.file=="/zed/shared.epub" and downloaded.in_shelf)
assert(off_shelf.local_available and not off_shelf.in_shelf)
assert(#Library.apply(data.shelf,{source="zlibrary"},"shelf")==1)
assert(#Library.apply(data.shelf,{source="wechat_mp"},"shelf")==1)
assert(Library.managed_source(data.files,"/zed/shared.epub")=="weread")
assert(not Library.managed_source(data.files,"/library/shared.epub"))
assert(#Library.apply(data.recent,{source="local"},"recent")==2)
assert(#Library.apply(data.recent,{source="weread"},"recent")==1)
assert(#Library.apply(data.recent,{source="wechat_mp"},"recent")==1)
assert(Library.section_source("device","weread")=="local")
assert(Library.section_source("shelf","all")=="weread")
assert(Library.section_source("shelf","local")=="weread")
assert(Library.section_source("recent","local")=="local")
input.weread_state="logged_out"
data=Library.build(input)
weread=Library.apply(data.shelf,{source="weread"},"shelf")
assert(#weread==2 and weread[1].local_available and weread[2].local_available)
assert(not weread[1].in_shelf and not weread[2].in_shelf)
assert(#data.device==1 and data.device[1].file=="/library/shared.epub")
print("Source partition preserves downloads, local namesakes, article ownership, recents and offline books")

-- Exercise the production plugin's small entry-point methods with device
-- stubs so a section switch can't silently repaint the top card.
local function load_methods(first,last,plugin,env)
    local file=assert(io.open("miuread.koplugin/main.lua","rb"))
    local source=file:read("*a")
    file:close()
    local a=assert(source:find(first,1,true))
    local b=assert(source:find(last,a+1,true))
    env.Plugin=plugin
    setfenv(assert(loadstring(source:sub(a,b-1))),setmetatable(env,{__index=_G}))()
end
local hero={title="Previous reading"}
local plugin={_home_hero=hero,_home_unified_raw=data,_home_sections={shelf={rows={}}}}
load_methods("function Plugin:_home_apply_library_filter","function Plugin:_home_set_library_filter",plugin,{
    HomeView={is_shown=function() return true end},
    UnifiedLibrary=Library,Time={now=function() return 1 end},
})
function plugin:_home_apply_weread_group(rows) return rows end
function plugin:_home_shelf_empty_text() return "Empty" end
function plugin:_home_cancel_visible_page_work() end
function plugin:_home_bump_interaction_generation() end
function plugin:_home_clear_cloud_page_cache() end
function plugin:_home_bump_section_revision() end
function plugin:_home_rebuild_row_indexes() end
function plugin:_home_apply_section(section)
    assert(section=="shelf")
    assert(self._home_hero==hero)
    assert(#self._home_sections.shelf.rows==1)
end
function plugin:_refresh_home_view() error("unexpected full home refresh") end
plugin:_home_apply_library_filter("shelf",{source="wechat_mp"},{})

local online="/settings/miuread/prefetch/book/7-online.epub"
local complete="/books/Book.epub"
local partial="/books/Chapter.epub"
local records={{file=online,variant="online",chapter_uid="7"},{file=complete,complete=true},{file=partial,variant="clean"}}
local book={book_id="book",variants={clean=records[2]},chapters={["7"]={online=records[1],clean=records[3]}}}
local library={session={last_read_path=online,pending={chapter_uid="7",chapter_percent=73}},prefetch_dir="/settings/miuread/prefetch"}
local history={saved={}}
function history:addItem(file) self.saved[#self.saved+1]=file end
package.loaded.readhistory=history
function library:variant() return book.variants.clean end
function library:book() return book end
function library:file_record_fast() return book,records[1] end
local session=library.session
function library:session() return session end
local function copy(row) local result={} for k,v in pairs(row) do result[k]=v end return result end
local host={store=library,_current_document_path=function() end}
package.loaded["miuread.online_cache"]={
    is_online_file=function(_,path) return path==online end,
    is_limited_file=function() return false end,
    reusable=function(record) return record~=nil and record.file~=nil end,
    matches=function(_,id,uid,path) return id=="book" and uid=="7" and path==online end,
}
load_methods("function Plugin:_whole_offline_record","local function mp_date",host,{
    normalized_reader_file=function(path) return path end,
    LocalLibrary=require("miuread.local_library"),
    U={file_exists=function() return true end,file_size=function() return 12 end,copy=copy,
        clamp=function(v,a,b) return math.max(a,math.min(b,v)) end},
})
host:_register_online_history_filter()
history:addItem(online)
history:addItem(complete)
history:addItem("/separate/7-online.epub")
assert(#history.saved==2 and history.saved[1]==complete)
assert(host:_preferred_record("book").file==complete)
local handoff=assert(host:_whole_online_resume(complete,"book"))
assert(handoff.position.chapter_uid=="7" and handoff.position.chapter_ratio==.73)
local identify=library.file_record_fast
function library:file_record_fast() end
assert(host:_whole_online_resume(complete,"book").position.chapter_uid=="7")
library.file_record_fast=identify
records[2].restricted_chapter_count=2
assert(host:_preferred_record("book").file==online)
records[2].restricted_chapter_count=0
session.last_read_path=partial
assert(host:_preferred_record("book").file==partial)
session.last_read_path="/missing/online/8-online.epub"
session.pending={chapter_uid="8",chapter_percent=35}
records[2].restricted_chapter_count=1
local missing,_,visited=host:_home_resume_record("book")
assert(missing==nil and visited,"continue must not choose an unrelated downloaded chapter")
session.pending={chapter_uid="7",chapter_percent=35}
local resume,position=host:_home_resume_record("book")
assert(resume==records[3] and position.chapter_uid=="7")
records[2].restricted_chapter_count=0
assert(host:_home_resume_record("book")==records[2],"whole file covers the saved position")
assert(Library.section_source("recent","all")=="all")
print("Home filters, hidden history, and complete-book handoff passed")

-- Shelf taps use the same menu before and after a complete download.
local opened,sheet,state,queue,chosen
local full,preferred
local managed={bookId="book",title="Book",source="weread"}
local shell={store={},book_delete_service={summary=function()
    return {has_local=preferred~=nil,variants=full and {full} or {},
        downloaded_chapter_count=preferred and not full and preferred.variant~="online" and 1 or 0}
end}}
local env={
    U={copy=copy,file_exists=function(path) return path==complete or path==partial or path==online end,
        trim=function(value) return value end},
    Protocol={is_mp=function() return false end,is_mp_account=function() return false end},
    UnifiedLibrary={canonical_source=function(row) return row.source end},
    ActionSheet={show=function(options) sheet=options end},
    BookIntegrity={partial_repairs=function() return {} end},
    BookLocalFilesDialog={open_generated=function(_,id) chosen="files:"..id end,
        open_variant=function(_,id,kind) chosen=id..":"..kind end},
    b4_content_only_options=copy,
    monotonic_wall_time=function() return 20 end,
}
package.loaded["miuread.eink_pdf"]={is_book=function() return false end}
package.loaded["miuread.bookstore"]={shelf_action=function() return nil end}
load_methods("function Plugin:_home_download_is_whole_book","function Plugin:_home_book_key",shell,env)
load_methods("function Plugin:_home_hold_book","function Plugin:_home_action_function_actions",shell,env)
load_methods("function Plugin:_shelf_select","function Plugin:show_shelf_search_dialog",shell,env)
function shell:_download_state() return state or {} end
function shell.store:download_queue() return queue or {} end
function shell:_local_entry_mode() end
function shell:_home_attach_local_record() end
function shell:_whole_offline_record() return full end
function shell:_variant_exists() end
function shell:_preferred_record() return preferred end
function shell:_home_resume_record() return preferred,nil,preferred~=nil end
function shell:_network_radio_hint() return true end
function shell:_finished_status_action() end
function shell:_open_file_direct(path) opened=path; return true end
function shell:_open_eink_book_online() chosen="online"; return true end
function shell:_download_percent() return 37 end
function shell:book_menu() chosen="legacy menu" end
function shell:choose_download_mode(book,opts)
    assert(book.bookId=="book" and opts.annotations==false)
    chosen="start"
end
function shell:show_waiting_downloads() chosen="queue" end
function shell:show_downloads() chosen="downloads" end
local function action(label)
    for _,item in ipairs(sheet.actions) do if item.label==label then return item end end
end
assert(shell:_home_open_book(managed))
assert(not opened and action("下载整本").icon=="cloud-download" and action("按章节下载"))
action("阅读").callback()
assert(chosen=="online")

preferred={file=partial,variant="clean"}
assert(shell:_home_open_book(managed) and not opened)
assert(action("按章节下载（已下载 1 章）") and action("下载整本"))

full={file=complete,complete=true}
preferred=full
assert(shell:_home_open_book(managed) and not opened)
assert(action("整本已下载").icon=="download-complete" and action("本机文件") and not action("按章节下载"))
action("本机文件").callback()
assert(chosen=="files:book")
action("整本已下载").callback()
assert(chosen=="files:book")
action("更多").callback()
assert(action("按章节下载"))
shell:_shelf_select(managed)
assert(chosen=="legacy menu" and not opened)
assert(shell:_home_open_book(managed,nil,nil,true) and opened==complete,"recent-reading shortcut opens directly")

preferred,full=nil,nil
queue={{book={bookId="book"},options={annotations=false,read_online=true}}}
assert(shell:_home_open_book(managed) and action("下载整本"))
queue={{book={bookId="book"},options={annotations=false}}}
assert(shell:_home_open_book(managed) and action("整本等待下载").icon=="history")
action("整本等待下载").callback()
assert(chosen=="queue")
queue=nil
state={book_id="book",status="active",options={annotations=false}}
assert(shell:_home_open_book(managed) and action("整本下载中（37%）").icon=="progress")
action("整本下载中（37%）").callback()
assert(chosen=="downloads")
state.status="failed"
assert(shell:_home_open_book(managed) and action("继续下载整本").icon=="warning")
action("继续下载整本").callback()
assert(chosen=="start")
print("Shelf taps, offline menu, direct resume, and whole-book download states passed")

load_methods("function Plugin:_offline_download_scope","function Plugin:_shelf_select",shell,env)
env.ShelfProgress={is_finished=function() return false end}
env.DownloadResult=require("miuread.download_result")
local stored={}
function shell.store:book() return stored end
local row={bookId="book"}
local function shelf(state,queued)
    shell:_apply_shelf_download_state(row,state or {},queued or {})
    return shell:_shelf_status_text(row)
end
stored={chapters={["1"]={online={file=online,variant="online",eink_content_mode="eink-online"}}}}
assert(shelf()=="未下载" and row.offline_download=="none")
stored.chapters["1"].clean={file=partial,variant="clean"}
assert(shelf()=="已下载部分章节" and row.offline_download=="partial")
full={file=complete,complete=true}
assert(shelf()=="整本已下载" and row.offline_download=="whole")
full=nil
assert(shelf({status="active",book_id="book",options={read_online=true}})=="已下载部分章节")
assert(shelf({status="active",book_id="book",options={annotations=false}})=="下载中 37%")
shell.download_task={is_paused=function() return true end}
assert(shelf({status="active",book_id="book",options={annotations=false}})=="下载已暂停")
assert(shelf({},{book=true})=="等待下载")
stored.chapters={}
assert(shelf()=="未下载" and row.offline_download=="none")
print("Shelf state separates online cache, partial files, verified whole books, and pending jobs")
