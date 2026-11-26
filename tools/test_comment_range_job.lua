-- Persist chapter status before moving on, and restore paused work per account.
package.path="./miuread.koplugin/?.lua;"..package.path
local files,encoded={},{}
package.loaded["libs/libkoreader-lfs"]={}
package.loaded.logger={info=function() end,warn=function() end}
local U=require("miuread.util")
U.read_file=function(path) return files[path] end
U.file_exists=function(path) return files[path]~=nil end
U.atomic_write=function(path,body) files[path]=body;return true end
package.loaded["miuread.json"]={
    encode=function(value) encoded[#encoded+1]=U.copy(value);return tostring(#encoded) end,
    decode=function(data) return U.copy(assert(encoded[tonumber(data)])) end,
}
local Job=require("miuread.comment_range_job")
local vid="42"
local store={}
function store:auth() return {account={vid=vid},login_session_id=vid} end
function store:book_cache_path(id) return "/data/books/"..id end
function store:book_dir(id) return self:book_cache_path(id) end

local rows={{chapterUid=1,title="第一章"},{chapterUid=2,title="第二章"},
    {chapterUid=3,title="第三章"},{chapterUid=4,title="第四章"}}
local job=assert(Job.new(store,"book",rows,1,4,false))
assert(Job.save(store,job))
job.chapters[1].state,job.chapters[1].comments="cached",3
job.chapters[2].state="failed"
job.chapters[3].state,job.chapters[3].comments,job.chapters[3].resume_partial="partial",2,true
assert(Job.save(store,job))
local restored=assert(Job.load(store,"book"))
local summary=Job.summary(restored)
assert(summary.cached==1 and summary.failed==1 and summary.partial==1 and summary.pending==1)
assert(summary.comments==5 and summary.current==3)
assert(Job.next(restored).uid=="4")
Job.retry(restored)
assert(Job.next(restored).uid=="2" and restored.chapters[3].resume_partial)
assert(restored.chapters[1].state=="cached")
assert(Job.save(store,restored))
assert(Job.next(assert(Job.load(store,"book"))).uid=="2")
vid="43"
assert(not Job.load(store,"book") and not Job.save(store,restored))
local other=assert(Job.new(store,"book",rows,4,4,true))
assert(Job.save(store,other) and Job.next(assert(Job.load(store,"book"))).uid=="4")
vid="42"
local real_remove=os.remove
os.remove=function(path) files[path]=nil;return true end
assert(Job.clear(store,restored) and not Job.load(store,"book"))
os.remove=real_remove
vid="43"
assert(Job.load(store,"book"))

-- Run live controller functions from main.lua against a mocked UI lifecycle.
local source_file=assert(io.open("miuread.koplugin/main.lua","rb"))
local source=source_file:read("*a")
source_file:close()
local function inject(first,last,ctx)
    local from=assert(source:find(first,1,true))
    local to=assert(source:find(last,from+1,true))
    local fragment=assert(loadstring(source:sub(from,to-1)))
    setfenv(fragment,ctx)
    fragment()
end
local Plugin={}
local calls={}
local prefs={thoughts={enabled=true},sync={comment_auto_preload=true}}
local ctx=setmetatable({
    Plugin=Plugin,U=U,HOME_SESSION={reader_session_generation=55},
    UIManager={unschedule=function(_,timer) calls.unscheduled=timer end},
}, {__index=_G})
inject("function Plugin:_thoughts_enabled()", "function Plugin:_online_comment_likes_enabled()",ctx)
inject("function Plugin:_set_thoughts_enabled(enabled)", "function Plugin:_toggle_thoughts_enabled()",ctx)
inject("function Plugin:_comment_range_state(runtime,message)", "function Plugin:_cancel_comment_range_task(reason,quiet)",ctx)
inject("function Plugin:_schedule_next_comment_preload(delay,attempt)", "function Plugin:_comment_fetch_mode_menu(back_callback)",ctx)
inject("function Plugin:_comment_range_next(runtime)", "function Plugin:_start_comment_range(book,rows,first,last,force)",ctx)
function store:preferences() return prefs end
local host=setmetatable({store=store},{__index=Plugin})
function host:_save_ui_preferences(input) prefs=input end
function host:_apply_annotation_mark_style() end
function host:_cancel_current_comment_marks() calls.current_stopped=true end
function host:_cancel_next_comment_preload() calls.next_stopped=true end
function host:_close_active_thought_popup() calls.popup_closed=true end
function host:_cancel_interactive_network() calls.request_stopped=true end
function host:toast() end
function host:_schedule_comment_overlay_refresh(force) calls.refresh=force end
local runtime={engine=Job,job=other,advance_task="next chapter",async={}}
function runtime.async:cancel() calls.worker_stopped=true end
function runtime.async:busy() return false end
host._comment_range_task=runtime
host._interactive_network_key="comment-range:book:7:1-3"
host:_set_thoughts_enabled(false)
assert(runtime.paused and runtime.last_state.pending==1)
assert(calls.current_stopped and calls.next_stopped and calls.request_stopped
    and calls.popup_closed and calls.worker_stopped and calls.unscheduled=="next chapter")
assert(host:_schedule_next_comment_preload(1)==false)
runtime.paused=false -- a queued callback must still stop before dispatch when off.
host:_comment_range_next(runtime)
assert(runtime.paused and runtime.last_state.pending==1)
function host:_schedule_next_comment_preload() calls.next_schedule=true end
host:_set_thoughts_enabled(true)
assert(calls.refresh and calls.next_schedule and runtime.paused)
print("Comment task resume, selective retry, account isolation and network shutdown passed")
