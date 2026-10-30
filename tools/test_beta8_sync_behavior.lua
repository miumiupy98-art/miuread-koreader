-- Behavioral beta.8 regressions: run from repository root with lua5.1 or luajit.
package.path="./miuread.koplugin/?.lua;./miuread.koplugin/?/init.lua;"..package.path
-- Keep the original Lua 5.1 contract runnable on Lua 5.3 test hosts too.
if not loadstring then loadstring=load end
if not setfenv then
    function setfenv(fn,env)
        for i=1,32 do
            local name=debug.getupvalue(fn,i)
            if name=="_ENV" then debug.setupvalue(fn,i,env); return fn end
            if name==nil then break end
        end
        return fn
    end
end
local PR=require('miuread.position_resolution')
local function read(p) local f=assert(io.open(p,'rb'));local s=f:read('*a');f:close();return s end
local main=read('miuread.koplugin/main.lua')
local sync_source=read('miuread.koplugin/miuread/sync.lua')
local function compile_method(src,first,next_one,env)
 local a=assert(src:find(first,1,true),first)
 local b=assert(src:find(next_one,a+#first,true),next_one)
 local chunk=assert(loadstring(src:sub(a,b-1)))
 setfenv(chunk,setmetatable(env,{__index=_G}))
 chunk()
end
local function cp(v)
 if type(v)~='table' then return v end
 local out={};for k,x in pairs(v) do out[k]=cp(x) end;return out
end
local log={info=function()end,warn=function()end}
local work={}
local UI={scheduleIn=function(_,delay,cb) assert(delay>=0);work[#work+1]=cb end}
local function drain()
 local count=0
 while #work>0 do count=count+1;assert(count<100,'possible retry loop');table.remove(work,1)() end
end

-- The old session fence is not an unconditional upload prohibition. Account
-- protections remain. A new reading after a cloud check can leave that fence.
local Plugin={}
compile_method(main,'function Plugin:_progress_write_fence(book_id,position)',
 '\nfunction Plugin:_save_position_resolution',{
 Plugin=Plugin
})
local fence_state={local_position_event_seq=0,progress_epoch=1}
local host=setmetatable({store={session=function() return fence_state end},
 _progress_write_fences={a={reason='remote_exact_unresolved',blocked_event_seq=0,progress_epoch=1},
 b={reason='account:changed',blocked_event_seq=0,progress_epoch=1},
 c={reason='remote_newer:clock',blocked_event_seq=0,progress_epoch=1}}},{__index=Plugin})
local exact={safe=true,chapter_uid='12',canonical_offset=3,local_position_event_seq=0}
assert(host:_progress_write_fence('a',exact)==true,'unverified remote must remain protected')
assert(host:_progress_write_fence('b',exact)==true,'account fence bypassed')
assert(host:_progress_write_fence('c',exact)==true,'older event overwrote remote')
fence_state.local_position_event_seq=1
exact.local_position_event_seq=1
assert(host:_progress_write_fence('c',exact)==false,'new exact user event remained fenced')
assert(host:_progress_write_fence('a')==true,'coordinate-free write bypassed fence')

-- A verified anchor beats a server ack timestamp (not a reading event).
local anchor={chapter_uid='41',chapter_offset=368}
local p1={chapter_uid='43',chapter_offset=900}
local p2={chapter_uid='41',chapter_offset=368}
local d=PR.decide{local_position=p1,remote_position=p2,verified_anchor=anchor,
 local_seq=2,verified_seq=1,local_updated_at=100,remote_updated_at=101}
assert(d.winner=='local' and d.reason=='local_sequence_after_anchor','server clock overrode verified anchor')
d=PR.decide{local_position=p2,remote_position=p1,verified_anchor=anchor,
 local_seq=1,verified_seq=1,local_updated_at=120,remote_updated_at=110}
assert(d.winner=='remote' and d.reason=='remote_changed_after_anchor','stale local timestamp overrode verified anchor')

-- Safe reading-time carry must drain in per-request capped batches *after*
-- leaving the reader, saving the remainder after every accepted response.
local Sync={}
local CONFIG={READ_REPORT_MAX_ELAPSED_SECONDS=60}
compile_method(sync_source,'function Sync:retry_safe_reading_time(',
 '\nfunction Sync:begin_progress_write',{
 Sync=Sync,U={copy=cp},Config=CONFIG,UIManager=UI,logger=log
})
local function retry_scenario(seconds,fail_at,unknown_at,busy_after_first)
 work={}
 local session={pending_report_safe=true,pending_report_seconds=seconds}
 local sent={}
 local reader_active=false
 local outcome=nil
 local saved={}
 local subject=setmetatable({store={
  session=function() return session end,
  save_session=function(_,_,patch) for k,v in pairs(patch) do session[k]=v end end,
 },host={_active_reader_ui=function() return reader_active end}},{__index=Sync})
 function subject:remote_wire_anchor() return {chapter_uid='4',chapter_offset=50,protocol_progress=10} end
 function subject:_core_map_hash() return 'hash' end
 function subject:_save_safe_pending_state(_,seconds)
  session.pending_report_seconds=seconds;session.pending_report_safe=seconds>0
  saved[#saved+1]=seconds
 end
 function subject:upload(chunk,cb,options)
  assert(options.time_only and options.reading_time_retry and chunk<=60)
  sent[#sent+1]=chunk
  local n=#sent
  if fail_at==n then
   cb(false,'rejected',nil,{error_kind='context',meta={request_dispatched=false}})
  elseif unknown_at==n then
   cb(false,'unknown',nil,{error_kind='unconfirmed',meta={request_dispatched=true}})
  else
   cb(true,'accepted',nil,{accepted=true})
  end
  if busy_after_first and n==1 then reader_active=true end
  return true
 end
 local record={book={book_id='one'}}
 local position={safe=true,progress=10,chapter_uid='4'}
 subject:retry_safe_reading_time('one',record,position,function(ok,msg,kind)
  assert(not outcome,'duplicate terminal callback')
  outcome={ok=ok,msg=msg,kind=kind}
 end)
 drain()
 return sent,saved,outcome,session
end
local sent,saved,outcome,session=retry_scenario(150)
assert(#sent==3 and sent[1]==60 and sent[2]==60 and sent[3]==30,'150 seconds were not segmented 60/60/30')
assert(saved[1]==90 and saved[2]==30 and saved[3]==0 and outcome.ok,'safe carry not committed after each batch')
sent,saved,outcome,session=retry_scenario(150,2)
assert(#sent==2 and session.pending_report_seconds==90 and outcome.ok==false,
 'explicit failure lost unattempted seconds')
sent,saved,outcome,session=retry_scenario(150,nil,2)
assert(#sent==2 and session.pending_report_seconds==30 and outcome.kind=='unconfirmed',
 'uncertain request replayed or discarded safe tail')
sent,saved,outcome,session=retry_scenario(150,nil,nil,true)
assert(#sent==1 and session.pending_report_seconds==90 and outcome.kind=='reading_active',
 'background retry continued while reader active')

-- EPUB CRe exact text search: a nil first result must retry a short anchor,
-- remain scoped to its original chapter, and require post-jump co verification.
local Search={}
local U={trim=function(v)return tostring(v or ''):match('^%s*(.-)%s*$') end,
 is_valid_utf8=function() return true end,utf8_len=function(v)return #v end,
 utf8_sub=function(v,a,b)return string.sub(v,a,b) end,
 clamp=function(v,a,b) return math.min(b,math.max(a,v)) end,
 first_line=function(s)return tostring(s) end}
compile_method(sync_source,'function Sync:text_anchor_rescue(remote,options)',
 '\nfunction Sync:chapter_anchor_rescue',{
 Sync=Search,U=U,Digests={sha256=function()return string.rep('a',64)end},
 logger=log,chapter_uid=function(row)return row.chapter_uid end
})
local attempts={};local jump
local document={
 findAllText=function(_,q) attempts[#attempts+1]=q
  if #q<=16 then return {{start='xp_valid'}} end
  return nil
 end,
 getPageFromXPointer=function() return 5 end,
}
local subject=setmetatable({host={ui={document=document,toc={toc={{page=1},{page=10}}}}}},{__index=Search})
function subject:record() return {book={book_id='one'},record={chapter_map={{chapter_uid='59'},{chapter_uid='60'}}}} end
function subject:jump_cached_remote_position() return false,'remote_xpointer_cache_miss' end
function subject:jump_xpointer(xp) jump=xp;return true end
local ok,err=subject:text_anchor_rescue({search_anchor_text='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijk',chapter_uid='59',offset=1152})
assert(ok and jump=='xp_valid' and #attempts>=3,'nil initial search failed to recover a chapter-scoped hit')
document.findAllText=function() return nil end
ok,err=subject:text_anchor_rescue({search_anchor_text='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijk',chapter_uid='59',offset=1152})
assert(not ok and err=='text_anchor_search_no_match','nil no-hit misclassified as a Lua API failure')

assert(not main:find('deferred_until_reading_end',1,true),'redundant low-level upload veto reintroduced')
assert(not main:find('UIManager:scheduleIn(.08,function() if self.ui and self.ui.document then self:upload_local_progress(false) end end)',1,true),
 'book-open network write reintroduced')
assert(not main:find('kindle_pending_send_authoritative',1,true),
 'automatic pending replay still bypasses cloud authority')
assert(main:find('pending_already_saved=true',1,true) and main:find('_progress_snapshot_current(book_id,position)',1,true),
 'authoritative saved upload lost its pending snapshot or generation check')
print('beta8 sync/time/anchor behavior: PASS')
