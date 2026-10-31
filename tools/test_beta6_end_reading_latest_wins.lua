package.path="./miuread.koplugin/?.lua;./miuread.koplugin/?/init.lua;"..package.path
local PR=require("miuread.position_resolution")
local function pos(ch,co) return {chapter_uid=tostring(ch),chapter_offset=co,offset_basis="wr_data_co"} end
local cases={
 {name="user close local+5s", l=105,r=100, want="local"},
 {name="cloud read+5s",l=100,r=105,want="remote"},
 {name="cloud read+1s",l=100,r=101,want="remote"},
 {name="local read+1s",l=101,r=100,want="local"},
 {name="cloud later despite local seq",l=100,r=101,seq=8,verified=7,want="remote"},
 {name="local later despite cloud seq",l=101,r=100,seq=7,verified=7,want="local"},
 {name="same timestamp no local event",l=100,r=100,want="remote"},
 {name="same timestamp local pending",l=100,r=100,seq=8,verified=7,want="local"},
 {name="no timestamps local pending",l=0,r=0,seq=8,verified=7,want="local"},
 {name="no timestamps first open",l=0,r=0,want="remote"},
}
for _,v in ipairs(cases) do
 local d=PR.decide{local_position=pos(61,2729),remote_position=pos(59,1152),
  local_seq=v.seq or 7,verified_seq=v.verified or 7,
  local_updated_at=v.l,remote_updated_at=v.r,clock_skew_grace=30}
 assert(d.winner==v.want,v.name.." expected "..v.want.." got "..tostring(d.winner))
end
assert(PR.decide{local_position=pos(59,1152),remote_position=pos(59,1152),
 local_updated_at=100,remote_updated_at=200}.winner=="aligned")
local function read(path) local f=assert(io.open(path,"rb"));local v=f:read("*a");f:close();return v end
local main=read("miuread.koplugin/main.lua")
local service=read("miuread.koplugin/miuread/read_report_service.lua")
local sync=read("miuread.koplugin/miuread/sync.lua")
local store=read("miuread.koplugin/miuread/store.lua")
local config=read("miuread.koplugin/miuread/config.lua")
assert(main:find('local authority_conflict=false',1,true),"legacy ambiguous conflict blocks issue recovery")
assert(main:find('reason=="remote_exact_unresolved"',1,true),"false reconciliation fences need targeted release")
assert(main:find('return true,reason',1,true),"other transaction fences must remain effective")
assert(main:find('verify_only=true',1,true) and main:find('web_only=true',1,true),"Web-only confirmation missing")
assert(main:find('kindle_pending_send_authoritative',1,true),
 "Kindle-first replay no longer bypasses remote timestamp veto")
assert(main:find('pending_already_saved=true',1,true),"remote-newer state discarded a saved Kindle position")
assert(service:find('next_due = run_report(control, elapsed, false, "interval")',1,true),"periodic time reporting not restored")
-- 6.2 best-effort policy: unsafe/failed time attempts must not accumulate a
-- cross-session replay debt. A dropped time interval must never affect the
-- independent final precise-progress transaction assertions above/below.
assert(service:find('local drop_time = Config.READ_TIME_BEST_EFFORT==true',1,true),
    "6.2 best-effort time failure handling missing")
assert(service:find('carry_remaining=0',1,true),
    "failed intervals could accumulate replay debt")
assert(sync:find('callback(true,"历史阅读时间补报已关闭"',1,true),
    "old durable SAFE time replay is not disabled")
assert(sync:find('"text_anchor_search_no_match"',1,true),"nil search result classification missing")
assert(sync:find('selected.selection_reason="latest_cloud_coordinate"',1,true),"source disagreement must choose newer cloud observation")
assert(not sync:find('conflict=true,conflict_reason="coordinate_mismatch"',1,true),"dual-source divergence still opens conflict gate")
assert(main:find('function Plugin:_reading_end_sync(',1,true),"reading-end transaction missing")
assert(not main:find('UIManager:scheduleIn(.08,function() if self.ui and self.ui.document then self:upload_local_progress(false) end end)',1,true),"book open triggers foreground upload")
assert(not main:find('deferred_until_reading_end',1,true),"redundant low-level ReaderUI veto reintroduced")
assert(config:find('READ_TIME_BEST_EFFORT = true',1,true),
    "6.2 best-effort policy unexpectedly disabled")
assert(sync:find('pcall(os.remove,self:_readtime_recovery_path())',1,true),
    "stale time journal cannot be retired while preserving progress state")
assert(store:find('pending_progress',1,true),
    "progress recovery must remain independent of discarded time debt")
print("6.2 latest-wins and end-reading regression: PASS (10 scenarios + best-effort time/progress contracts)")
