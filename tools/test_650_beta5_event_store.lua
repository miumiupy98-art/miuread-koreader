-- Exercises the real store event allocation and cross-instance watermark merge.
local function src(path)
  local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s
end
local s=src('miuread.koplugin/miuread/store.lua')
local function cp(t)
 if type(t)~='table' then return t end
 local o={};for k,v in pairs(t) do o[k]=cp(v) end;return o
end
local env=setmetatable({Store={},U={copy=cp},logger={info=function()end}}, {__index=_G})
local a=assert(s:find('function Store:record_user_position_event(id)',1,true))
local b=assert(s:find('function Store:invalidate_book_sync_context(',a,true))
local f=assert(loadstring(s:sub(a,b-1),'record-event'));setfenv(f,env);f()
local shared={book={local_position_event_seq=29,progress_write_guard={blocked_event_seq=29,progress_epoch=1}}}
local function instance()
 local store=setmetatable({local_sessions=cp(shared)},{__index=env.Store})
 function store:session(id) return self.local_sessions[id] end
 function store:_read_settings_file()return {sessions=cp(shared)} end
 function store:save_session(id,patch)
  local live=self.local_sessions[id] or {};self.local_sessions[id]=live
  local disk=shared[id] or {};shared[id]=disk
  for k,v in pairs(patch) do live[k]=cp(v);disk[k]=cp(v) end
  return live,true
 end
 return store
end
local reader=instance();local home=instance()
assert(reader:record_user_position_event('book')==30)
assert(home:record_user_position_event('book')==31,'stale Home counter reset')
assert(reader:record_user_position_event('book')==32,'stale Reader counter reset')
assert(shared.book.local_position_event_seq==32)
-- Extract and exercise the production flush merge policy.
local c=assert(s:find('local PROGRESS_SESSION_FIELDS={',1,true))
local d=assert(s:find('local function pending_home_navigation(',c,true))
local chunk=assert(loadstring(s:sub(c,d-1)..'\nreturn merge_newer_progress_sessions','merge-event'))
local env2=setmetatable({U={copy=cp},PROGRESS_SYNC_RESET_KEYS={},logger={info=function()end}},{__index=_G})
setfenv(chunk,env2)
local merge=chunk()
local mem={book={progress_latest_sequence=20,local_position_event_seq=29,local_read_event_at=100}}
local disk={book={progress_latest_sequence=19,local_position_event_seq=32,local_read_event_at=200}}
local out=merge(mem,disk)
assert(out.book.local_position_event_seq==32 and out.book.local_read_event_at==200,
 'stale Home overwrite of durable event')
local mem2={book={progress_latest_sequence=19,local_position_event_seq=33,local_read_event_at=250}}
local disk2={book={progress_latest_sequence=20,local_position_event_seq=30,local_read_event_at=200}}
local out2=merge(mem2,disk2)
assert(out2.book.local_position_event_seq==33,'progress transaction rank reset genuine event')
print('PASS beta5: genuine reading events persist across Home/Reader and stale progress merges')
