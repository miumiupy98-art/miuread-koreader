-- Beta.13: execute the ACTUAL beta.12/beta.13 pending-replay implementation
-- against deterministic stand-ins for network, store and time.  This test
-- is not loaded into the KOReader plugin and performs no real network I/O.
local script = arg and arg[0] or ""
local root = script:match("^(.*)/tools/[^/]+$") or "."
local f = assert(io.open(root .. "/miuread.koplugin/main.lua", "rb"))
local main = assert(f:read("*a")); f:close()
local start_marker = "function Plugin:_submit_saved_pending_progress"
local stop_marker = "function Plugin:_submit_all_saved_pending_progress"
local start_at = assert(main:find(start_marker, 1, true), "missing production pending replay function")
local stop_at = assert(main:find(stop_marker, start_at + 1, true), "missing end marker")

local Plugin = {}
U = { copy = function(t)
    local result = {}
    for k, v in pairs(t) do result[k] = v end
    return result
end }
logger = {warn = function() end}
local factory = assert((loadstring or load)(main:sub(start_at, stop_at - 1)))
-- The extracted production definition is executed unchanged.
-- Lua 5.1 loadstring normally binds the global Plugin, so provide that name.
_G.Plugin = Plugin
factory()
assert(type(Plugin._submit_saved_pending_progress) == "function")

local function same(a,b)
    return a and b and tostring(a.chapter_uid) == tostring(b.chapter_uid)
        and tonumber(a.chapter_offset or a.canonical_offset) == tonumber(b.chapter_offset or b.canonical_offset)
end
_G.__MIUREAD_POSITION_RESOLUTION = {
    same_position = same,
    trusted_verified_anchor = function(session) return session.trusted_anchor end,
}

local book = "book-13"
local function make(opts)
    opts=opts or {}
    local pending = opts.pending ~= false and {
        chapter_uid = 12, chapter_offset = 345, progress = 21,
        progress_sequence = 7, progress_epoch = 2,
    } or nil
    local session = {
        pending_progress = pending, progress_upload_state = "pending_send",
        trusted_anchor = opts.anchor,
    }
    local calls={post=0,reads=0,verify=0,commit=0,park=0,cb=nil}
    local self=setmetatable({store={},sync={},calls=calls,session=session,seq=7}, {__index=Plugin})
    function self:_persisted_sessions() return {[book]=session} end
    function self.store:session() return session end
    function self.store:save_session(_,changes)
        for k,v in pairs(changes) do session[k]=v end
    end
    function self:_progress_snapshot_replayable() return true end
    function self:_stored_progress_record() return {book_id=book} end
    function self:logged_in() return opts.online ~= false end
    function self:_network_radio_hint() return opts.online ~= false end
    function self:_prepare_progress_snapshot(_,p) return p end
    function self:_progress_snapshot_current(_,p) return self.seq == p.progress_sequence end
    function self:_clear_progress_write_fence() end
    function self:_save_progress_state(_,status) if status=="verification_required" then calls.park=calls.park+1 end end
    function self.sync:mark_verified() calls.verify=calls.verify+1 end
    function self:_commit_progress_verified() calls.commit=calls.commit+1 end
    function self:_submit_progress_snapshot(_,position,options,callback)
        calls.post=calls.post+1
        assert(options.pending_already_saved==true and options.reason=="pending_web_preflight_passed")
        callback(true,opts.remote,nil)
        return true
    end
    function self.sync:remote(_,callback,options)
        calls.reads=calls.reads+1
        assert(options.detached==true and options.web_only==true
            and options.verify_only==true and options.raw_coordinate==true
            and options.update_cloud_anchor==false, "unsafe remote preflight options")
        calls.cb=callback
        if not opts.defer_remote then callback(opts.remote,opts.remote_error) end
    end
    return self,calls,session
end
local function run(opts)
    local self,calls,session=make(opts)
    local result=nil
    local started=self:_submit_saved_pending_progress({book_id=book},function(ok,reason,remote)
        result={ok=ok,reason=reason,remote=remote}
    end)
    return self,calls,session,result,started
end
local p={chapter_uid=12,chapter_offset=345}
local anchor={chapter_uid=8,chapter_offset=10}
local changed={chapter_uid=9,chapter_offset=400}

-- 1. No pending record: no fetch or POST.
do
    local _,calls,_,result=run({pending=false})
    assert(result and result.ok and result.reason=="no_pending")
    assert(calls.post==0 and calls.reads==0)
end
-- 2. Network unavailable: preserve current record, no POST.
do
    local _,calls,session,result=run({online=false,remote=p})
    assert(result and result.reason=="network_unavailable")
    assert(calls.post==0 and calls.reads==0 and session.pending_progress)
end
-- 3. Identical Web position: confirm without duplicate POST.
do
    local _,calls,_,result=run({remote=p})
    assert(result and result.ok and result.reason=="already_verified")
    assert(calls.reads==1 and calls.post==0 and calls.verify==1 and calls.commit==1)
end
-- 4. Remote changed since trusted anchor: park, never force POST.
do
    local _,calls,session,result=run({remote=changed,anchor=anchor})
    assert(result and not result.ok and result.reason=="cloud_changed_since_anchor")
    assert(calls.post==0 and calls.park==1 and session.pending_progress)
end
-- 5. Untrusted/missing anchor: park, never force POST.
do
    local _,calls,session,result=run({remote=changed})
    assert(result and not result.ok and result.reason=="verified_anchor_missing")
    assert(calls.post==0 and calls.park==1 and session.pending_progress)
end
-- 6. Web fetch failure: pending preserved and POST is suppressed.
do
    local _,calls,session,result=run({remote_error="connection_timeout"})
    assert(result and not result.ok and result.reason=="web_preflight_unavailable:connection_timeout")
    assert(calls.post==0 and session.pending_progress)
end
-- 7. Remote still equals trusted original anchor: existing business logic may submit.
do
    local _,calls,_,result=run({remote=anchor,anchor=anchor})
    assert(result and result.ok and calls.post==1 and calls.reads==1)
end
-- 8. Delayed remote callback after a newer local event must not submit old snapshot.
do
    local self,calls,session,_,started=run({defer_remote=true,remote=anchor,anchor=anchor})
    assert(started and calls.cb and calls.post==0)
    self.seq=8
    -- Invoke the actual callback captured from the production implementation.
    calls.cb(anchor,nil)
    assert(calls.post==0 and session.pending_progress)
end
print("PASS: eight production pending-replay safety scenarios (no runtime modification)")
