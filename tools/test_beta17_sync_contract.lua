-- Release-specific integration invariants for 6.1.0-beta.17.
local script=arg and arg[0] or ""
local root=script:match("^(.*)/tools/[^/]+$") or "."
local function read(path)
    local f=assert(io.open(root.."/"..path,"rb")); local value=f:read("*a"); f:close(); return value
end
local function fragment(source,start_marker,end_marker)
    local begin_at=assert(source:find(start_marker,1,true),"missing "..start_marker)
    local end_at=end_marker and source:find(end_marker,begin_at+1,true)
    return source:sub(begin_at,(end_at and end_at-1) or #source)
end
local config=read("miuread.koplugin/miuread/config.lua")
local main=read("miuread.koplugin/main.lua")
local worker=read("miuread.koplugin/miuread/legacy/read_report_worker.lua")
local sync=read("miuread.koplugin/miuread/sync.lua")
local service=read("miuread.koplugin/miuread/read_report_service.lua")
assert(config:match('VERSION%s*=%s*"%d+%.%d+%.%d+%-beta%.%d+"'),"beta release metadata")

-- The 6.1.0-beta.17 Kindle-first policy is retired.  Keep this legacy
-- contract file runnable, but assert the CURRENT safe Web-preflight replay
-- behavior rather than force_write / bypassing a newer cloud position.
local replay=fragment(main,"function Plugin:_submit_saved_pending_progress","function Plugin:_submit_all_saved_pending_progress")
assert(replay:find("_progress_snapshot_current(book_id,position)",1,true),
    "stale pending progress can be replayed")
assert(replay:find("self.sync:remote(book_id,on_remote",1,true),
    "pending replay no longer consults the remote position")
assert(replay:find("web_only=true,verify_only=true,raw_coordinate=true,update_cloud_anchor=false",1,true),
    "pending replay must use read-only Web coordinate preflight")
assert(replay:find("PR.same_position(remote,position)",1,true),
    "same exact cloud position is no longer detected")
assert(replay:find('done(true,"already_verified",remote)',1,true),
    "identical exact remote position must be verified without a second POST")
assert(replay:find("PR.trusted_verified_anchor(session,session.position_state)",1,true),
    "trusted verified anchor is not checked")
assert(replay:find("if not anchor or not PR.same_position(remote,anchor) then",1,true),
    "changed or untrusted cloud position may be overwritten")
assert(replay:find('parked(anchor and "cloud_changed_since_anchor" or "verified_anchor_missing",remote)',1,true),
    "cloud change must park, not force-send pending progress")
assert(not replay:find("force_write=true",1,true),
    "retired Kindle-first force_write reintroduced into automatic replay")
assert(replay:find("_submit_progress_snapshot(book_id,position",1,true),
    "safe replay no longer submits the verified current pending position")
assert(main:find("_verify_progress_submission",1,true),
    "cloud readback verification missing")

-- 6.2: time and progress use separate position authorities.
local compat=fragment(worker,"if reading_time_compat then","local accepted, result")
assert(compat:find('local anchor=type(job.cloud_anchor)=="table" and job.cloud_anchor or {}',1,true),
    "time worker does not consume opening Web session snapshot")
assert(compat:find('and catalog_idx~=nil and catalog_idx==idx',1,true),
    "time worker does not validate the Web chapter tuple against the book catalog")
assert(compat:find('observed_at>=session_started-2',1,true),
    "time worker does not reject old reading-session anchors")
assert(compat:find('opening Web session position not ready or untrusted',1,true),
    "missing or unsafe opening snapshot can reach the POST")
assert(not compat:find('refresh_remote_anchor(client,book_id,book)',1,true),
    "periodic compatibility report still invokes the failing Legacy GET")
assert(not compat:find("estimate_position(book,progress_ratio)",1,true),"time wrongly depends on Kindle offset")
assert(compat:find("request_dispatched=false",1,true),"unsafe time context may dispatch")
assert(worker:find("validate_terminal_progress(book,position)",1,true),"terminal progress safety removed")
assert(sync:find("if not time_only then",1,true),"time-only daemon still maps foreground position")
assert(sync:find("position_safe = time_only or",1,true),"time daemon wrongly requires Kindle coordinates")
assert(service:find("(not time_only and (control.position_safe",1,true),"service rejects Web-based time")
assert(service:find('next_due = run_report(control, elapsed, false, "interval")',1,true),"periodic reading time is disabled")

-- Existing manual resolution and lossless pending state stay available.
local store=read("miuread.koplugin/miuread/store.lua")
assert(store:find("pending_unresolved_position",1,true),"pending position persistence removed")
assert(main:find('text="以云端为准"',1,true),"manual remote resolution lost")
assert(main:find('text="以本机为准"',1,true),"manual Kindle resolution lost")
print("current safe Web-preflight replay / historical time separation contracts: PASS")
