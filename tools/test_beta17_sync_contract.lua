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

-- A user-authorized or genuinely pending local upload keeps its exact Kindle
-- coordinate, but automatic open reconciliation must preserve newer remote
-- positions until an actual new reading event proves local freshness.
-- Old beta.17's unconditional cloud-fence bypass is no longer a safe contract.
local replay=fragment(main,"function Plugin:_submit_saved_pending_progress","function Plugin:_submit_all_saved_pending_progress")
assert(replay:find("force_write=true",1,true),"local submission not authoritative")
assert(replay:find("_progress_snapshot_current(book_id,position)",1,true),"stale local snapshot not rejected")
assert(not replay:find("self.sync:remote(book_id",1,true),"remote freshness still blocks Kindle")
-- Historical authority mode was a blanket bypass: explicitly reject it.
assert(not main:find('reason="kindle_coordinate_authoritative"',1,true),
    "obsolete unconditional cloud-fence bypass reintroduced")
local fence=fragment(main,"function Plugin:_progress_write_fence","function Plugin:_save_position_resolution")
assert(fence:find('reason=="remote_exact_unresolved"',1,true),
    "unverified remote-exact position not protected")
assert(fence:find('local fresh_event=current_event>previous_event and current_event>=blocked_at',1,true),
    "new local reading event not required before remote-fence release")
assert(fence:find('position.safe==true',1,true),
    "unsafe local position could bypass remote fence")
assert(fence:find('return true,reason',1,true),
    "remote-exact uncertainty no longer blocks unsafe writes")
assert(main:find("_verify_progress_submission",1,true),"cloud readback verification missing")

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
print("beta17 guarded Kindle progress / time separation contracts: PASS")
