-- Regression against the two observed failures: read event reset and
-- an early no-snapshot fence that blocked legitimate automatic uploads.
local function file(path)
    local f=assert(io.open(path,"rb"));local s=f:read("*a");f:close();return s
end
local main=file("miuread.koplugin/main.lua")
local sync=file("miuread.koplugin/miuread/sync.lua")
local store=file("miuread.koplugin/miuread/store.lua")
assert(main:find("function Plugin:upload_local_progress(manual,callback)",1,true))
local start=assert(main:find("function Plugin:upload_local_progress(manual,callback)",1,true))
local finish=assert(main:find("function Plugin:_use_remote_position(",start,true))
local gate=main:sub(start,finish-1)
assert(not gate:find("self:_progress_write_fence(id)",1,true),"unsafe no-snapshot pre-fence remains")
assert(main:find("local blocked,block_reason=self:_progress_write_fence(book_id,snapshot)",1,true),
    "canonical upload guard must remain")
assert(main:find("local_seq=tonumber(session.local_position_event_seq or 0)",1,true),
    "opening decision must consume human reading event")
assert(main:find("verified_seq=tonumber(session.progress_verified_read_event_seq or 0)",1,true),
    "opening decision must use corresponding event baseline")
assert(store:find("current.progress_source_backfill=nil",1,true),"queue needs replace-not-merge")
local Event=require("miuread.position_event")
assert(Event.next_sequence({local_position_event_seq=1,progress_write_guard={blocked_event_seq=9}})==10,
    "reading event regressed behind durable fence")
assert(Event.next_sequence({local_position_event_seq=2,position_state={local_position={local_position_event_seq=8}}})==9,
    "reading event regressed behind saved position")
assert(sync:find('self:_defer_session_flush(1.0)',1,true),"human reading event needs deferred durability")
print("PASS beta4: exact-snapshot fence, genuine-event sequence, job replacement")
