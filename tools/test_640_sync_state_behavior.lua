-- Execute real standalone production methods with mocked session data.
-- These are behavioral assertions, not source-string presence checks.
local function read(path)
    local f=assert(io.open(path,"rb")); local s=f:read("*a"); f:close(); return s
end
local source=read("miuread.koplugin/main.lua")
Plugin={}
logger={info=function() end,warn=function() end}
local function load_method(name,next_name)
    local from="function Plugin:"..name.."("
    local stop="\nfunction Plugin:"..next_name.."("
    local a=assert(source:find(from,1,true),"missing "..name)
    local b=assert(source:find(stop,a+1,true),"missing method after "..name)
    local loader=loadstring or load
    local chunk,err=loader(source:sub(a,b-1),"@"..name)
    assert(chunk,err); chunk()
end
load_method("_progress_write_fence","_save_position_resolution")
load_method("_effective_progress_status","_sync_user_issue")
load_method("_home_sync_status_label_from_summary","_home_sync_status_label")
local session={local_position_event_seq=0,progress_epoch=1}
local obj={store={session=function() return session end,preferences=function() return {} end},
    _progress_write_fences={a={reason="remote_exact_unresolved",blocked_event_seq=0,progress_epoch=1}}}
local exact={safe=true,chapter_uid="12",canonical_offset=6100}
local blocked=Plugin._progress_write_fence(obj,"a",exact)
assert(blocked==true,"precise coordinates cannot bypass a remote-exact fence")
assert(Plugin._progress_write_fence(obj,"a")==true,"pre-mapping fence must block too")
session.local_position_event_seq=1
exact.local_position_event_seq=1
assert(Plugin._progress_write_fence(obj,"a",exact)==false,"new real reading event may authorize exact write")
local chapter_start={safe=true,chapter_uid="12",canonical_offset=0,local_position_event_seq=1}
assert(Plugin._progress_write_fence(obj,"a",chapter_start)==false,"co=0 is a valid exact chapter-start coordinate")
assert(Plugin._progress_write_fence(obj,"a") == true,"no coordinate cannot bypass fence")
for _,reason in ipairs({"remote_newer:later", "conflict:ambiguous_clock_conflict", "remote_exact_coordinate_missing"}) do
    obj._progress_write_fences.a={reason=reason,blocked_event_seq=1,progress_epoch=1}
    assert(Plugin._progress_write_fence(obj,"a",exact)==true,reason)
end
obj._progress_write_fences.a=nil
assert(Plugin._progress_write_fence(obj,"a",exact)==false,"no fence")
local function status(row) return Plugin._effective_progress_status(obj,row) end
assert(status{progress_sync_state="remote_selected"}=="位置已对齐")
assert(status{progress_sync_state="aligned",sync_repair_required=true}=="位置已对齐")
assert(status{progress_sync_state="upload_failed",pending_progress={progress_sequence=9},progress_verified_sequence=8}=="同步失败")
assert(status{progress_sync_state="submitted",pending_progress={progress_sequence=9},progress_verified_sequence=8}=="待云端确认")
assert(status{progress_sync_state="submitted",pending_progress={progress_sequence=9},progress_verified_sequence=9}=="已同步")
assert(status{progress_sync_state="remote_jump_unconfirmed"}=="章内位置待确认")
assert(status{progress_sync_state="waiting_network"}=="等待网络")
assert(status{progress_sync_state="local_uploaded"}=="已同步")
assert(status{progress_sync_state="source_conflict",position_state={resolved={reason="remote_position_verified"}}}=="同步失败")
obj.annotation_async=nil
assert(Plugin._home_sync_status_label_from_summary(obj,{failed_total=0,pending_total=2})=="待处理 2")
assert(Plugin._home_sync_status_label_from_summary(obj,{failed_total=1,pending_total=2})=="同步失败 1")
assert(Plugin._home_sync_status_label_from_summary(obj,{failed_total=0,pending_total=0,checking=true})=="同步检查中")
-- Comment preload retries at most twice on transient UI busyness.
load_method("_schedule_next_comment_preload","_comment_fetch_mode_menu")
HOME_SESSION={reader_session_generation=3,suspended=false}
local scheduled={}
UIManager={unschedule=function() end,scheduleIn=function(_,delay,callback)
    scheduled[#scheduled+1]=callback
end}
local preloader={
    store={preferences=function() return {sync={comment_auto_preload=true}} end},
    _reader_background_idle=function() return false end,
    _reader_session_is_weread=function() return true end,
    is_online=function() return true end,
}
setmetatable(preloader,{__index=Plugin})
assert(preloader:_schedule_next_comment_preload(1)==true)
for i=1,3 do
    local task=scheduled[i]
    assert(type(task)=="function", "expected bounded retry "..i)
    task()
end
assert(#scheduled==3,"comment preloader must not poll indefinitely")
-- Re-arming at an actual idle transition with cached next-chapter comments
-- must finish without any additional network work or new retry.
preloader._reader_background_idle=function() return true end
preloader._chapter_navigation_context=function() return {
    state="NEXT",catalog_complete=true,book_id="book",next_uid="22"
} end
preloader.comment_sync={status=function() return {has_cache=true,status="cached"} end}
assert(preloader:_schedule_next_comment_preload(1)==true)
scheduled[4]()
assert(#scheduled==4,"cached next chapter must not request again")

print("PASS: exact-progress fences, Reader/Home state, bounded comment preload")
