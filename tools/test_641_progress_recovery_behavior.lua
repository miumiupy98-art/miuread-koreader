-- Runtime contract for both beta and stable. No network or Kindle needed.
local function read(path)
 local f=assert(io.open(path,"rb")); local s=f:read("*a");f:close();return s
end
local code=read("miuread.koplugin/main.lua")
local sync=read("miuread.koplugin/miuread/sync.lua")
local compile=loadstring or load
local function method(source,head,stop,env)
 local a=assert(source:find(head,1,true),"missing "..head)
 local b=assert(source:find(stop,a+#head,true),"missing "..stop)
 local src=source:sub(a,b-1)
 if setfenv then
  local fn=assert(compile(src)); setfenv(fn,setmetatable(env,{__index=_G}));fn()
 else
  local fn=assert(load(src,"method","t",setmetatable(env,{__index=_G})));fn()
 end
end
local Plugin={}
local logger={info=function()end,warn=function()end}
method(code,"function Plugin:_progress_write_fence(","\nfunction Plugin:_save_position_resolution",{Plugin=Plugin})
method(code,"function Plugin:_pending_remote_preflight_decision(","\nfunction Plugin:_pending_progress_auto_safe",{Plugin=Plugin})
method(code,"function Plugin:_pending_progress_auto_safe(","\nfunction Plugin:_submit_saved_pending_progress",{Plugin=Plugin})
method(code,"function Plugin:_submit_saved_pending_progress(","\nfunction Plugin:_submit_all_saved_pending_progress",{Plugin=Plugin,U={copy=function(t) local o={} for k,v in pairs(t)do o[k]=v end return o end}})
local pos={safe=true,progress=12,chapter_uid="10",canonical_offset=0,local_position_event_seq=2,progress_sequence=3}
local session={progress_upload_state="pending_send",progress_submission_phase="unsent",progress_epoch=1,
 progress_latest_sequence=3,progress_verified_sequence=2,
 progress_write_guard={reason="remote_exact_unresolved",blocked_event_seq=2,progress_epoch=1},pending_progress=pos}
session.verified_chapter_uid="10"
session.verified_chapter_offset=0
session.progress_verified_read_event_seq=2
local upload_calls=0
local host=setmetatable({store={session=function() return session end,save_session=function(_,_,patch) for k,v in pairs(patch)do session[k]=v end end,
 auth=function()return {account={vid="test"},login_session_id="session1"}end},
 _active_reader_ui=function()return false end,
 _progress_write_fences={},_persisted_sessions=function()return {book=session}end,
 _progress_snapshot_replayable=function() return true end,
 _stored_progress_record=function()return {book={book_id="book"}}end,
 sync={remote=function(_,_,callback)
     callback({chapter_uid="10",chapter_offset=0},nil)
     return true
 end},
 logged_in=function()return true end,_network_radio_hint=function()return true end,
 _prepare_progress_snapshot=function(_,_,p)return p end,
 _progress_snapshot_current=function()return true end,
 _save_progress_state=function()end,
 _submit_progress_snapshot=function(_,_,_,opts,cb)upload_calls=upload_calls+1;assert(opts.force_write~=true);cb(true,{},nil);return true end}, {__index=Plugin})
local result
host:_submit_saved_pending_progress({book_id="book"},function(ok,reason)result={ok,reason}end)
assert(upload_calls==0 and result[1]==false and result[2]=="remote_guard_unresolved","blocked pending auto POST")
-- Restart: memory fence is lost, durable guard still blocks replay.
assert(host:_progress_write_fence("book",pos)==true,"restart lost durable fence")
local legacy={safe=true,chapter_uid="10",canonical_offset=0,local_position_event_seq=0,pending_reason="write_fenced:remote_exact_unresolved"}
assert(Plugin._pending_progress_auto_safe(host,session,legacy)==false,"legacy pending silently upgraded")
session.progress_write_guard=false
assert(Plugin._pending_progress_auto_safe(host,session,legacy)==false,"legacy no-guard item replayed")
-- A NEW immutable position created after the fence (not an old pending item)
-- is eligible, provided it is precise, same generation and explicitly unsent.
session.progress_write_guard={reason="remote_exact_unresolved",blocked_event_seq=2,progress_epoch=1}
local newpos={safe=true,progress=13,chapter_uid="10",canonical_offset=125,local_position_event_seq=3,progress_sequence=4}
session.pending_progress=newpos
local allowed=Plugin._pending_progress_auto_safe(host,session,newpos)
assert(allowed==true,"fresh exact snapshot was blocked")
assert(host:_progress_write_fence("book",newpos)==false,"fresh event could not lift remote guard")
host:_submit_saved_pending_progress({book_id="book"},function(ok)result={ok}end)
assert(upload_calls==1 and result[1]==true,"safe retry did not pass fresh cloud preflight")
session.progress_submission_phase="submitted_unverified"
assert(Plugin._pending_progress_auto_safe(host,session,newpos)==false,"unknown dispatched request replayable")
assert(Plugin._pending_remote_preflight_decision(host,session,newpos,{chapter_uid="10",chapter_offset=77})=="wait",
  "changed remote was overwritten")
assert(Plugin._pending_remote_preflight_decision(host,session,newpos,{chapter_uid="10",chapter_offset=0})=="send",
  "unchanged verified cloud should permit a newer local event")
assert(Plugin._pending_remote_preflight_decision(host,session,newpos,{chapter_uid="10",chapter_offset=125})=="verified",
  "same cloud coordinate should be verify-only, no duplicate POST")
-- Independent event sequence must never advance on automatic jump or first page.
local Sync={}
method(sync,"function Sync:on_page(page, genuine_user_event)","\nfunction Sync:_defer_session_flush",{Sync=Sync,logger=logger})
local book_session={local_position_event_seq=10,local_read_event_at=0}
local obj=setmetatable({current={book={book_id="book"}},time_enabled=false,last_page=nil,
 store={session=function()return book_session end,save_session=function(_,_,patch)for k,v in pairs(patch)do book_session[k]=v end end}}, {__index=Sync})
obj:on_page(1,true)
assert(book_session.local_position_event_seq==10,"first page counted as read event")
obj:on_page(5,false)
assert(book_session.local_position_event_seq==10,"programmatic jump counted as read event")
obj:on_page(6,true)
assert(book_session.local_position_event_seq==11,"human page change not durable")
print("PASS: pending replay fence, durable guard, user event sequence, no forced auto POST")
