-- Execute the production smart-handoff function in a deterministic fake host.
local function read(path)
    local f=assert(io.open(path,'rb'))
    local s=f:read('*a');f:close();return s
end
local source=read('miuread.koplugin/miuread/sync.lua')
local a=assert(source:find('function Sync:switch_smart_time_backend(online,reason)',1,true))
local b=assert(source:find('function Sync:offline_time_controller()',a,true))
local block=source:sub(a,b-1)
Sync={}
logger={info=function() end,warn=function() end}
UIManager={unschedule=function() end}
assert(load(block))()
local function make()
  local online=false
  local events,starts,stops,callback={}, {}, {}, nil
  local record={book={book_id='test'}}
  local controller={task=nil}
  local subject={store={preferences=function() return {sync={time_enabled=true}} end},
    current=record,reading_time_backend='web',daemon={active=true,final_flush_pending=false},
    host={ui={document={}},is_online=function() return online end,
      on_readtime_route_change=function(_,...) events[#events+1]={...} end}}
  setmetatable(subject,{__index=Sync})
  function subject:reading_time_mode() return 'smart' end
  function subject:_stop_daemon(reason, persist, elapsed)
    assert(elapsed==0, 'Web history cannot be moved to E-Ink')
    stops[#stops+1]=reason
    self.daemon.active=false
    return 7
  end
  function subject:wait_writer_barrier(seq,fn,timeout)
    assert(seq==7 and timeout==12)
    callback=fn
    return true
  end
  function subject:offline_time_controller() return controller end
  function subject:start(reason)
    starts[#starts+1]=reason
    return true
  end
  return subject,events,starts,stops,controller,function(value) online=value end,function(ok) assert(callback);callback(ok) end
end
-- Offline start is gated by ack; no overlapping Web and E-Ink writers.
do
  local x,events,starts,stops,ctrl,set_online,ack=make()
  assert(x:switch_smart_time_backend(false,'network_disconnected'))
  assert(#starts==0 and x.reading_time_backend=='web')
  ack(true)
  assert(#starts==1 and starts[1]=='smart_network_offline' and x.reading_time_backend=='eink')
  assert(events[1][1]=='eink')
end
-- Reconnect before acknowledgement must not spawn another Web writer.
do
  local x,events,starts,stops,ctrl,set_online,ack=make()
  assert(x:switch_smart_time_backend(false,'network_disconnected'))
  set_online(true)
  assert(x:switch_smart_time_backend(true,'network_connected'))
  assert(#starts==0 and x.reading_time_backend=='web')
  ack(true)
  assert(#starts==1 and starts[1]=='smart_online_restored_during_handoff')
  assert(x.reading_time_backend=='web')
end
-- An unacknowledged stop cannot start a competing E-Ink clock.
do
  local x,events,starts,stops,ctrl,set_online,ack=make()
  assert(x:switch_smart_time_backend(false,'network_disconnected'))
  ack(false)
  assert(#starts==0 and x.reading_time_backend=='web' and events[1][1]=='unavailable')
end
-- Authentication-only retry clearing, preserving unknown, rate-limit and other pending rows.
do
  local code=read('miuread.koplugin/miuread/readtime_outbox.lua')
  local c=assert(code:find('function M:clear_auth_retry(account,now)',1,true))
  local e=assert(code:find('function M:unknown(account)',c,true))
  M={}
  assert(load(code:sub(c,e-1)))()
  local box=setmetatable({data={control={reason='authentication',next_send=9999},items={
    one={state='pending',reason='authentication',retry_at=9999},
    two={state='unknown',reason='authentication',retry_at=9999},
    three={state='pending',reason='rate_limited',retry_at=9999}}}}, {__index=M})
  function box:_access(account,fn) return fn(self.data) end
  local ok,changed=box:clear_auth_retry('a',500)
  assert(ok and changed and box.data.control.reason==nil)
  assert(box.data.items.one.retry_at==500 and box.data.items.one.reason==nil)
  assert(box.data.items.two.retry_at==9999 and box.data.items.two.state=='unknown')
  assert(box.data.items.three.retry_at==9999)
end
-- Pure, device-independent menu-map checks.
do
 local map=dofile('miuread.koplugin/miuread/menu_icons.lua')
 assert(map.key('阅读时长同步')=='history')
 assert(map.key('E-Ink 客户端授权')=='shield-check')
 assert(map.key('扫码登录')=='qr-code')
 assert(map.key('随机状态')==nil)
end
print('PASS beta637: Web barrier handoff, rapid reconnect, auth-only retry and menu icons')
