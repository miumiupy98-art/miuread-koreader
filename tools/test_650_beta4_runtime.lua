-- Isolated end-to-end execution of beta.4 queue -> Web fetch -> cache ->
-- persistent completion, with no external network or Kindle APIs.
local function source(path)
    local f=assert(io.open(path,"rb"));local s=f:read("*a");f:close();return s
end
local hits={}
package.preload["miuread.source_position"]=function()
    return {
        cachedChapterExists=function(_,_,uid) return uid=="20" end,
        cacheChapter=function(_,book,uid,version,coord)
            assert(book=="book" and uid=="10" and version==123 and coord=="<p>verified Web content</p>")
            hits[#hits+1]=uid;return true,"/sidecar"
        end,
    }
end
package.preload["miuread.http"]=function()
    return {new=function()return {_shared_rate_limit=function()return 0 end}end,
        rate_limit_details=function()return nil end}
end
package.preload["miuread.reader"]=function()
    return {new=function()return {web_chapter=function(_,book,chapter)
        assert(book.bookId=="book" and chapter.uid=="10")
        return "unused","",{},{coord_html="<p>verified Web content</p>"}
    end}end}
end
package.preload["miuread.api_transport"]=function()
    return {preference=function()return "auto" end}
end
local function copy(t)
    if type(t)~="table" then return t end
    local r={};for k,v in pairs(t) do r[k]=copy(v) end;return r
end
local Plugin={}
local ctx={Plugin=Plugin,HomeView={is_shown=function()return true end},
    HOME_SESSION={suspended=false}, HOME_EXITING=false,
    UIManager={scheduleIn=function()end,unschedule=function()end},
    interactive_child_store=function(auth)
        return {auth=function()return auth end,snapshot=function()return auth,false end}
    end,
    U={copy=copy,first_line=function(s)return s end},
    logger={info=function()end,warn=function()end}}
setmetatable(ctx,{__index=_G})
local main=source("miuread.koplugin/main.lua")
local first=assert(main:find("-- 6.5.0-beta.4: download source backfill",1,true))
local last=assert(main:find("function Plugin:_finish_download_runtime",first,true))
local fn=assert(load(main:sub(first,last-1),"beta4_runtime","t",ctx))
fn()
local sessions={}
local store={data_dir="/data",temp_dir="/tmp"}
function store:session(id) return sessions[id] end
function store:auth() return {login_session_id="login",account={vid="test"}} end
function store:book(id) return {title="Test",author="Author"} end
function store:book_dir() return "/tmp/book" end
function store:save_session(id,patch)
    sessions[id]=sessions[id] or {}
    for k,v in pairs(patch) do sessions[id][k]=copy(v) end
end
local host=setmetatable({store=store,interactive_network_async={busy=function()return false end},
    logged_in=function()return true end,_network_radio_hint=function()return true end,
    _active_reader_ui=function()return false end,
    _persisted_sessions=function()return sessions end,
    _run_interactive_network=function(_,_,_,worker,callback)
        local value=worker();callback({ok=true,value=value});return true
    end}, {__index=Plugin})
local book={book_id="book",progress_source_book_version=123,core_map_hash="h",
    chapter_map={{uid="10",title="first"},{uid="20",title="second"}},
    progress_source_complete=false}
assert(host:_queue_source_backfill(book)==true)
assert(#sessions.book.progress_source_backfill.jobs==1)
assert(host:_pump_source_backfill()==true)
assert(#hits==1 and #sessions.book.progress_source_backfill.jobs==0)
assert(host:_pump_source_backfill()==false)
assert(#hits==1,"finished chapter was fetched twice")
print("PASS beta4 runtime: download queue, Web-only source, sidecar, no repeated fetch")
