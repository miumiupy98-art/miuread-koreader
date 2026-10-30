-- beta.9 behavior checks: fresh automatic open, trustworthy read-time Web tuple.
-- Run from repository root under lua5.1 or luajit.
package.path="./miuread.koplugin/?.lua;./miuread.koplugin/?/init.lua;"..package.path
local Wire=require("miuread.legacy.web_progress_wire")
local function read(f) local h=assert(io.open(f,"rb"));local s=h:read("*a");h:close();return s end
local main=read("miuread.koplugin/main.lua")
local worker=read("miuread.koplugin/miuread/legacy/read_report_worker.lua")
local function copy(v) if type(v)~="table" then return v end local x={} for k,a in pairs(v) do x[k]=copy(a) end return x end
local log={info=function()end,warn=function()end}
local tests=0
local function test(label,fn) local ok,e=pcall(fn);assert(ok,label..": "..tostring(e));tests=tests+1 end
local function load_block(source,start,finish,env,ret)
 local a=assert(source:find(start,1,true),start)
 local b=assert(source:find(finish,a+1,true),finish)
 local f=assert(loadstring(source:sub(a,b-1).."\nreturn "..ret,ret))
 setfenv(f,setmetatable(env,{__index=_G})); return f()
end
local anchor_func=load_block(worker,"local function refresh_remote_anchor(","\nlocal function last_readable_chapter_uid",
 {chapter_uid=function(ch) return ch.chapterUid or ch.uid or ch.chapter_uid end},"refresh_remote_anchor")
local function client(response,throws)
 return {get_web_progress=function() if throws then error(throws) end return response end,
 parse_web_progress=function(_,data,id) return Wire.parse(data,id) end}
end
local function book() return {chapters={{uid="41",chapterIdx=10},{uid="44",chapterIdx=11}},
 remote_chapter_uid="41",remote_chapter_idx=10,remote_chapter_offset=88,remote_raw_progress=21} end
local function response(idx) return {bookId="853116",chapterUid="44",chapterOffset=671,progress=87,chapterIdx=idx} end
test("catalog resolves missing chapter index without stale remote reuse",function()
 local b=book();local ok=anchor_func(client(response()),"853116",b)
 assert(ok and b.remote_chapter_uid=="44" and b.remote_chapter_idx==11 and b.remote_chapter_offset==671 and b.remote_raw_progress==87)
end)
test("mismatching chapter index leaves prior anchor untouched",function()
 local b=book();local ok=anchor_func(client(response(10)),"853116",b)
 assert(not ok and b.remote_chapter_uid=="41" and b.remote_chapter_idx==10)
end)
test("new chapter cannot reuse previous UID index",function()
 local b=book();b.chapters={{uid="41",chapterIdx=10}}
 local ok,err=anchor_func(client(response()),"853116",b)
 assert(not ok and err=="web_chapter_index_unresolved" and b.remote_chapter_uid=="41")
end)
test("same chapter may reuse verified same-UID index",function()
 local b=book();b.chapters={};local old=response();old.chapterUid="41"
 local ok=anchor_func(client(old),"853116",b)
 assert(ok and b.remote_chapter_idx==10 and b.remote_chapter_uid=="41")
end)
test("read-only authentication failure is separate from context failure",function()
 local b=book();local ok,err,kind=anchor_func(client(nil,"HTTP 401 cookie expired"),"853116",b)
 assert(not ok and kind=="authentication" and b.remote_chapter_uid=="41")
end)
test("Web JSON auth failure is not mistaken for missing position",function()
 local pos,msg,kind=Wire.parse({errCode=401,errMsg="login expired"},"853116")
 assert(not pos and kind=="authentication")
end)
test("incomplete or foreign Web response is rejected",function()
 assert(not Wire.parse({bookId="wrong",chapterUid="44",chapterOffset=671,progress=87},"853116"))
 assert(not Wire.parse({bookId="853116",chapterUid="44",progress=87},"853116"))
end)
test("Web progress remains raw protocol pr, not EPUB ratio",function()
 local pos=assert(Wire.parse(response(11),"853116"))
 assert(pos.protocol_progress==87 and pos.chapter_offset==671)
end)
-- Test real open-check branch: old cache aligns with Kindle while Web has moved.
local env={Plugin={},U={copy=copy},Config={},logger=log,
 monotonic_wall_time=function()return 1 end}
local method=load_block(main,"function Plugin:ensure_read_report_progress(reason,automatic)",
 "\nfunction Plugin:",env,"Plugin.ensure_read_report_progress")
test("automatic opening always reads live Web even with matching 28-second cache",function()
 local remote_calls,applied=0,nil
 local cached={chapter_uid="59",offset=6124,fetched_at=os.time()-28}
 local localp={chapter_uid="59",canonical_offset=6124,progress=74}
 local store={preferences=function()return {sync={}} end,
 session=function()return {position_state={remote_position=cached}} end}
 local sync={record=function()return {book={book_id="853116",title="Mock"}} end,
 begin_progress_sync=function()end,local_ratio=function()return 0.74 end,
 -- Live reader-position resolution is a prerequisite of fresh cloud fetch.
 -- The production method is defined in Sync; this isolated test must mock it
 -- rather than relying on the old implementation that read only the cache.
 resolve_local_progress=function(_,done,options)
  assert(options.precise==true and options.prepare_catalog==true)
  done(copy(localp),nil,{})
  return true
 end,
 remote=function(_,id,done,options)
  remote_calls=remote_calls+1
  -- Live coordinates were resolved above; the read must stay read-only.
  assert(options==nil or options.update_cloud_anchor~=true)
  done({chapter_uid="44",offset=671,percent=20})
  return true
 end}
 local host=setmetatable({store=store,sync=sync,_progress_check_running=false},
 {__index=env.Plugin})
 function host:_reader_current_page()return 1 end
 function host:_open_sync_begin()end
 function host:_position_resolution_context()return {open_local_position=copy(localp)} end
 function host:_set_progress_write_fence()end
 function host:_save_progress_state()end
 function host:_remote_matches(remote,position)
  assert(remote.chapter_uid=="44" and position.chapter_uid=="59")
  return false
 end
 function host:on_remote_progress(id,percent,remote)
  assert(id=="853116" and remote.chapter_uid=="44");applied=remote
 end
 assert(host:ensure_read_report_progress("reader_ready",true))
 assert(remote_calls==1 and applied and applied.offset==671)
end)
-- Verify PR #156's generation callback guard is unchanged by this patch.
test("PR156 verified callback gate remains present",function()
 assert(main:find("return allow_verified==true and verified==seq and latest==seq",1,true))
 assert(main:find('verify_error=="account_changed"',1,true))
end)
-- User-visible pending and verified are not conflated.
test("unconfirmed progress is not labelled upload failed",function()
 assert(main:find('upload_unconfirmed="待云端确认"',1,true))
 assert(main:find('cloud_position_changed',1,true))
end)
print("beta9 fresh-open and reading-time Web tuple: PASS ("..tests.." scenarios)")
