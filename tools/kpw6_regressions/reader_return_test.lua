local f=assert(io.open(assert(arg[1])));local source=f:read('*a');f:close()
local a=assert(source:find('function Plugin:_request_reader_close(',1,true))
local b=assert(source:find('\nfunction Plugin:',a+1,true))
local close={generation=1,state='reader_closing'}
local shown=true
local env={Plugin={},READER_CLOSE=close,HomeView={is_shown=function() return shown end},
 Event={new=function() return {} end},monotonic_wall_time=function() return 100 end,
 logger={info=function() end,warn=function() end}}
setmetatable(env,{__index=_G})
local chunk=assert(loadstring(source:sub(a,b-1)));setfenv(chunk,env);chunk()
local fn=env.Plugin._request_reader_close
local state,after_close,fail='active','closed',false
local saved,finished,scheduled,events=0,0,0,0
local reader={document={}}
function reader:handleEvent() events=events+1 end
function reader:onClose(force)
 assert(force==false);if fail then error('close failed') end
 saved=saved+1;state=after_close
end
local host={_reader_lifecycle_state=function() return state,reader end,
 _reader_session_is_local=function() return false end,
 _finish_reader_return=function() assert(state=='closed' and saved>0);finished=finished+1;return true end,
 _schedule_reader_return_finish=function() scheduled=scheduled+1 end}
assert(fn(host,1,'test'));assert(saved==1 and finished==1 and scheduled==0 and events==2)
for _,phase in ipairs({'active','closing'}) do state='active';after_close=phase;assert(fn(host,1,'test')) end
assert(saved==3 and finished==1 and scheduled==2,'incomplete close bypassed native settle')
state='active';after_close='closed';shown=false;assert(fn(host,1,'test'))
assert(finished==1 and scheduled==3,'missing parked Home bypassed native recovery')
state='active';shown=true;fail=true;assert(not fn(host,1,'test'))
assert(finished==1 and scheduled==4,'failed close was treated as complete')
assert(not fn(host,2,'stale'));assert(scheduled==4 and finished==1)
print('READER_RETURN_AFTER_CLOSE_AND_FALLBACK_OK')
