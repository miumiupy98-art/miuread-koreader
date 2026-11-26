package.path="./miuread.koplugin/?.lua;"..package.path
package.loaded["libs/libkoreader-lfs"]={}
package.loaded["logger"]={info=function() end,warn=function() end}
package.loaded["miuread.digests"]={}
package.loaded["ui/event"]={}
package.loaded["ui/uimanager"]={}
package.loaded["miuread.json"]={}
package.loaded["miuread.http"]={}
package.loaded["miuread.book_integrity"]={}
package.loaded["miuread.precise_position"]={}
package.loaded["miuread.source_position"]={}
package.loaded["miuread.subprocess_hygiene"]={}
package.loaded["ffi/util"]={runInSubProcess=function() error("legacy reporter tried to spawn") end}
local Sync=require("miuread.sync")
local capture_count,stop_count=0,0
local sync=setmetatable({
    store={preferences=function()
        return {api_transport="web",sync={time_enabled=true,time_route_mode="legacy"}}
    end},
    host={},
    record=function() return {book={book_id="fixture"},record={}} end,
    _ensure_reading_time_ids=function() end,
    offline_time_controller=function()
        return {start=function() capture_count=capture_count+1; return true end}
    end,
    _stop_daemon=function(_,_,_,seconds)
        assert(seconds==0,"a legacy writer may not flush during retirement")
        stop_count=stop_count+1
    end,
},Sync)
assert(sync:reading_time_mode()=="eink" and sync:web_readtime_disabled())
assert(sync:_ensure_daemon()==false)
assert(sync:_start_daemon()==false)
assert(sync:_write_daemon_control(true,true)==false)
assert(sync:upload(30)==false)
assert(sync:start("fresh test") and sync.reading_time_backend=="eink" and capture_count==1)
sync.daemon={active=false,final_flush_pending=true}
assert(sync:start("retire old writer")==false and capture_count==1 and stop_count==1)

local file=assert(io.open("miuread.koplugin/main.lua","rb"))
local main=file:read("*a")
file:close()
for _,old in ipairs({"测试 30 秒阅读时间","智能切换（推荐）","function Plugin:_retry_safe_reading_time",
    'text="Web 定位补全"'}) do
    assert(not main:find(old,1,true),"old sync UI remains: "..old)
end
local function find_method(name)
    return assert(main:match("(function Plugin:"..name.."%b().-)\r?\nfunction Plugin:"))
end
local Plugin={}
local Env=setmetatable({Plugin=Plugin,reading_time_duration=tostring},{__index=_G})
local menu_code=assert(loadstring(find_method("reading_time_menu")))
setfenv(menu_code,Env)()
local replay_code=assert(loadstring(find_method("_progress_snapshot_replayable")))
setfenv(replay_code,Env)()
local wake_count,message=0,nil
local current=setmetatable({
    store={preferences=function() return {sync={time_enabled=true}} end},
    sync={offline_time_controller=function()
        return {summary=function() return {pending=42,in_flight=0,unverified_seconds=58,unverified_batches=1} end}
    end,wake_offline_reading_time=function() wake_count=wake_count+1 end},
    _eink_auth_status_text=function() return "已验证" end,
    reading_time_status_label=function() return "E-Ink" end,
    _active_reader_ui=function() return false end,
    toast=function(_,text) message=text end,
}, {__index=Plugin})
local rows={}
for _,row in ipairs(current:reading_time_menu()) do rows[row.text]=row end
assert(rows["上传通道"].post_text=="E-Ink")
assert(rows["待上传"].post_text=="42" and not rows["待确认"])
assert(rows["最近云端确认"].post_text=="暂无确认记录")
assert(rows["未核实历史"].post_text=="58" and rows["未核实历史"].enabled)
assert(rows["同步已记录时长"].enabled)
rows["同步已记录时长"].callback()
assert(wake_count==1 and message=="已安排同步，等待 E-Ink 回执")
local ok,reason=current:_progress_snapshot_replayable({native_offset=true,offset_basis="wr_data_co"})
assert(ok==false and reason=="eink_coordinate_unverified")
Env.U=require("miuread.util")
Env.logger=package.loaded["logger"]
local function install_method(name)
    setfenv(assert(loadstring(find_method(name))),Env)()
end
install_method("_normalize_exact_progress_snapshot")
install_method("_progress_sync_issue_items")
install_method("_submit_saved_pending_progress")
install_method("_schedule_home_progress_recovery")

local pending={progress_sequence=7,chapter_uid="42",offset=1016,chapter_offset=1016,
    eink_coordinate=true,offset_basis="wr_data_co",native_offset=true,progress=14,captured_at=100,book_version=17}
local session={progress_sync_state="local_coordinate_unresolved",progress_upload_state="pending_coordinate",
    pending_progress=pending,pending_unresolved_position={progress_sequence=8,source_anchor={chapter_uid="44"}}}
function current:_persisted_sessions() return {fixture=session} end
function current:_persisted_library() return {fixture={title="Fixture"}} end
local issue=current:_progress_sync_issue_items()[1]
assert(issue.pending_sequence==8 and issue.can_recover_anchor and not issue.can_verify and not issue.pending_progress)

session.pending_unresolved_position=false
session.progress_upload_state="pending_send"
session.progress_sync_state="deferred"
assert(current:_progress_sync_issue_items()[1].can_send)
session.progress_sync_state="local_selected"
assert(current:_progress_sync_issue_items()[1].can_send,"opening status must not hide the unsent position")
session.progress_sync_state="checking"
session.progress_upload_state="submitted"
local verifying=current:_progress_sync_issue_items()[1]
assert(verifying.can_verify and not verifying.can_send,"a submitted write may only be verified")
session.progress_sync_state="deferred"
session.progress_upload_state="pending_send"
local callbacks={}
Env.HomeView={is_shown=function() return true end}
Env.UIManager={scheduleIn=function(_,_,callback) callbacks[#callbacks+1]=callback end,unschedule=function() end}
function current:logged_in() return true end
function current:_network_radio_hint() return true end
function current:_clear_verified_progress_ghosts() end
local sent_after_recovery=false
function current:_recover_all_pending_progress_anchors(_,done)
    session.pending_unresolved_position=false
    session.progress_upload_state="pending_send"
    session.progress_sync_state="deferred"
    done(true,1)
end
function current:_submit_all_saved_pending_progress(items)
    sent_after_recovery=items[1].can_send
end
session.pending_unresolved_position={progress_sequence=8,source_anchor={chapter_uid="44"}}
session.progress_upload_state="pending_coordinate"
session.progress_sync_state="local_coordinate_unresolved"
assert(current:_schedule_home_progress_recovery(0))
callbacks[1]()
assert(sent_after_recovery)

-- A fresh anchor bypasses the global cool-down but selects only its own book.
local forwarded
function current:_recover_all_pending_progress_anchors(items)
    forwarded=items
end
function current:_active_reader_ui() return false end
function current:_persisted_sessions()
    return {fixture=session,other={progress_sync_state="deferred",progress_upload_state="pending_coordinate",
        pending_unresolved_position={progress_sequence=9,source_anchor={chapter_uid="45"}}}}
end
function current:_persisted_library() return {fixture={title="Fixture"},other={title="Other"}} end
session.pending_unresolved_position={progress_sequence=8,source_anchor={chapter_uid="44"}}
session.progress_upload_state="pending_coordinate"
session.progress_sync_state="local_coordinate_unresolved"
current._home_progress_recovery_at=os.time()
assert(current:_schedule_home_progress_recovery(1.2,"fixture"))
assert(not current:_schedule_home_progress_recovery(20),"ordinary scan must not displace the current book")
callbacks[#callbacks]()
assert(#forwarded==1 and forwarded[1].book_id=="fixture" and forwarded[1].pending_sequence==8)

-- An older, dispatched request must never be sent by the close fast path.
session.pending_unresolved_position=false
session.progress_upload_state="submitted"
session.progress_sync_state="submitted"
forwarded=false
function current:_retry_all_saved_progress_verifications() error("fast path should not read back an already-dispatched position") end
assert(current:_schedule_home_progress_recovery(1.2,"fixture"))
callbacks[#callbacks]()
assert(forwarded==false)
session.progress_upload_state="pending_send"
session.progress_sync_state="deferred"

install_method("_same_submitted_close_progress")
install_method("_progress_position_fingerprint")
session.progress_upload_state="submitted"
session.progress_latest_sequence=7
pending.progress_epoch=1
assert(current:_same_submitted_close_progress("fixture",pending))
local fresh=Env.U.copy(pending)
fresh.offset,fresh.chapter_offset=1216,1216
assert(not current:_same_submitted_close_progress("fixture",fresh),"changed E-Ink position must be eligible to submit")
fresh=Env.U.copy(pending)
fresh.book_version=18
assert(not current:_same_submitted_close_progress("fixture",fresh),"old edition must not block a new position")
session.progress_upload_state="pending_send"
session.progress_sync_state="deferred"

local submitted=0
current.sync.remote=function() error("the saved retry must let the native worker own the preflight") end
function current:_stored_progress_record() return {} end
function current:_prepare_progress_snapshot(_,value) return value end
function current:_progress_snapshot_current() return true end
function current:_remote_matches() return false end
function current:_save_progress_state() end
function current:_clear_progress_write_fence() end
function current.store:save_session(_,patch) for key,value in pairs(patch) do session[key]=value end end
function current:_submit_progress_snapshot(_,pos,options,done)
    assert(pos.eink_resend==true and options.native_preflight==true)
    submitted=submitted+1
    done(true)
    return true
end
assert(current:_submit_saved_pending_progress({book_id="fixture"},function(success) assert(success) end))
assert(submitted==1)

install_method("_whole_offline_record")
install_method("_home_download_is_whole_book")
install_method("_home_download_task_options")
install_method("_home_variant_download_context")
install_method("_home_variant_download_action")
install_method("_reader_toolbar_header")
Env.Protocol={is_mp=function() return false end}
local offline={file="/Fixture.epub",complete=true}
Env.U.file_exists=function(file) return file==offline.file end
Env.U.file_size=function() return 12 end
current.store.variant=function(_,id,kind) assert(id=="fixture" and kind=="clean"); return offline end
current.store.download_queue=function() return {} end
function current:_download_state() return {} end
current.sync.record=function() return {book={book_id="fixture"}} end
function current:_reader_session_is_weread() return true end
function current:_reader_wifi_summary() return "Wi-Fi" end
function current:_reader_battery_label() return "80%" end
function current:_bluetooth_state() return {} end
function current:_reader_sync_summary() return "" end
function current:_reader_toolbar_cache() return {} end
function current:_reader_toolbar_cached_percent() return 14 end
function current:_home_enabled() return true end
function current:_display_time() return "12:00" end
assert(current:_reader_toolbar_header("Fixture").download_complete)
offline.pending_install=true
assert(not current:_reader_toolbar_header("Fixture").download_complete)
offline.pending_install=false
offline.partial_range=true
assert(not current:_reader_toolbar_header("Fixture").download_complete)
print("E-Ink-only menus, legacy-writer fences, upload states and coordinate replay gate passed")

-- The production progress worker leases durable time after the write fence.
-- The claim must occur at dispatch, after the current sequence is checked.
local book_id="fixture"
local session_state={progress_epoch=2,progress_latest_sequence=8,progress_verified_sequence=7}
local track={claims=0,finished=0,posts=0}
local readtime={summary_cache=true}
local row={book_id=book_id,book_version=17,duration=18}
local lease={vid="account",id="lease",batch={rows={row},seconds=18}}
function readtime:position_time(_,position)
    assert(position.book_version==17)
    return lease
end
readtime.queue={claim=function(_,vid,batch,id)
    assert(vid==lease.vid and batch==lease.batch and id==lease.id)
    track.claims=track.claims+1
    return true
end}
function readtime:finish_position_time(attempt,receipt)
    assert(attempt==lease and receipt.state=="confirmed" and receipt.dispatched)
    track.finished=track.finished+1
end
function readtime:log() end
package.loaded["miuread.eink_client"]={new=function()
    return {write_position=function(_,_,can_send,rows)
        assert(rows[1]==row)
        if not can_send(true) then return {accepted=false,request_dispatched=false} end
        track.posts=track.posts+1
        return {accepted=true,request_dispatched=true,time_receipt={state="confirmed",dispatched=true}}
    end}
end}
local worker_sync=setmetatable({
    offline_time=readtime,reader={http={}},
    begin_progress_write=function(_,_,ready) ready(true); return true end,
    end_progress_write=function() end,
    store={
        auth=function() return {login_session_id="launch-session"} end,
        reload=function() end,
        read_persisted=function(_,key)
            if key=="auth" then return {login_session_id="launch-session"} end
            return {[book_id]=session_state}
        end,
    },
    async={
        available=function() return true end,busy=function() return false end,
        run=function(_,_,work,done) done({ok=true,value=work()}); return true end,
    },
},Sync)
local candidate={book_id=book_id,book_version=17,progress_sequence=8,progress_epoch=2,eink_coordinate=true}
local options={position_override=candidate,record_override={book={book_id=book_id}}}
assert(worker_sync:upload_progress(function(ok) assert(ok) end,options))
assert(track.claims==1 and track.posts==1 and track.finished==1)
session_state.progress_latest_sequence=9
assert(worker_sync:upload_progress(function(ok) assert(not ok) end,options))
assert(track.claims==1 and track.posts==1 and track.finished==1)
print("Progress and reading time share one guarded dispatch")

-- The synced notice uses the actual landing UID and never displays an API index.
local map_sync=setmetatable({record=function() return {
    record={chapter_map={{uid=61,title="第六章"}}}
} end,_progress_catalog=function() return {{uid=43,title="第五章"}, {uid=99,title=""}} end},Sync)
assert(map_sync:progress_chapter_title({chapter_uid="61",chapter_idx=10})=="第六章")
assert(map_sync:progress_chapter_title({chapter_uid="43",chapter_idx=10})=="第五章")
assert(not map_sync:progress_chapter_title({chapter_uid="99",chapter_idx=10}))
assert(not map_sync:progress_chapter_title({chapter_idx=10}))

-- Reproduce a confirmed seq 15 followed by seq 16, first stored as a text
-- anchor and then recovered to chapter 61. Compare both directions: an older
-- Home instance must not discard or reintroduce an earlier stage.
local store_file=assert(io.open("miuread.koplugin/miuread/store.lua","rb"))
local store_source=store_file:read("*a")
store_file:close()
local merge_start=assert(store_source:find("local PROGRESS_SESSION_FIELDS",1,true))
local merge_end=assert(store_source:find("local function pending_home_navigation",merge_start,true))
local load_merge=assert(loadstring(store_source:sub(merge_start,merge_end-1).."\nreturn merge_newer_progress_sessions"))
setfenv(load_merge,setmetatable({U=Env.U,logger=Env.logger,PROGRESS_SYNC_RESET_KEYS={}},{__index=_G}))
local merge=load_merge()
local anchor={progress_sequence=16,progress_epoch=2,captured_at=120,source_anchor={}}
local recovered={progress_sequence=16,progress_epoch=2,captured_at=120,chapter_uid="61",
    chapter_offset=795,book_version=5,eink_coordinate=true}
local disk={progress_epoch=2,progress_latest_sequence=16,progress_verified_sequence=15,
    progress_upload_state="pending_coordinate",pending_unresolved_position=anchor,progress_decided_at=127}
local recovered_memory={progress_epoch=2,progress_latest_sequence=16,progress_verified_sequence=15,
    progress_upload_state="pending_send",pending_progress=recovered,pending_unresolved_position=false,progress_decided_at=126}
local merged=merge({book=Env.U.copy(recovered_memory)},{book=Env.U.copy(disk)}).book
assert(merged.pending_progress.chapter_uid=="61" and merged.progress_upload_state=="pending_send")
merged=merge({book=Env.U.copy(disk)},{book=Env.U.copy(recovered_memory)}).book
assert(merged.pending_progress.chapter_uid=="61" and not merged.pending_unresolved_position)
local verified_disk={progress_epoch=2,progress_latest_sequence=16,progress_verified_sequence=16,
    pending_progress=false,progress_upload_state="verified",progress_decided_at=125}
merged=merge({book=Env.U.copy(recovered_memory)},{book=verified_disk}).book
assert(not merged.pending_progress and merged.progress_verified_sequence==16)
local coordinate_disk={progress_epoch=2,progress_latest_sequence=16,progress_verified_sequence=15,
    pending_progress_coordinate={progress_sequence=16,chapter_uid="61",chapter_offset=795},progress_decided_at=125}
merged=merge({book=Env.U.copy(disk)},{book=coordinate_disk}).book
assert(merged.pending_progress_coordinate.chapter_uid=="61")

-- Reopening may compare a stale rendered position from chapter 43 with the
-- cloud. A different, durable chapter 61 takes part in the decision.
local Resolver=require("miuread.position_resolution")
local durable=assert(Resolver.current_pending(recovered_memory))
local cloud={source="eink",chapter_uid="43",offset=1096,updated_at=150,version=5}
local comparison={local_position={chapter_uid="43",offset=1096},remote_position=cloud,
    pending_position=durable,remote_other_device=false}
assert(Resolver.decide(comparison).reason=="unconfirmed_local_read_event")
comparison.remote_other_device=true
assert(Resolver.decide(comparison).reason=="newer_cloud_device")
cloud.updated_at=110
assert(Resolver.decide(comparison).winner=="local")
cloud.chapter_uid,cloud.offset="61",795
assert(Resolver.decide(comparison).reason=="cloud_matches_saved_position")
assert(not Resolver.current_pending(verified_disk))
assert(Resolver.current_pending(disk)==anchor)
print("Prior receipts cannot discard a recovered position; reopening respects durable pending positions")
