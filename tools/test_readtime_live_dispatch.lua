-- Dependency-light regression for the production Native dispatch gate.
-- It must not POST or even enter the queue while reading; after stop_fast
-- the cached Sync.current must not suppress a closed session forever.
package.path = './miuread.koplugin/?.lua;' .. package.path
package.preload['ui/uimanager'] = function() return {} end
package.preload['miuread.async'] = function() return {} end
package.preload['miuread.readtime_outbox'] = function() return {} end
package.preload['miuread.readtime_stats'] = function() return {} end
package.preload['miuread.diagnostic_log'] = function() return {now=os.time} end
package.preload['miuread.readtime_clock'] = function() return {} end
package.preload['miuread.readtime_metadata'] = function() return {} end
local Controller = require('miuread.readtime_controller')
local checks = 0
local session = {current={book={book_id='book'}},state='waiting',reading_time_backend='eink'}
local store = {
  auth = function() return {account={vid='test'},login_session_id='sid'} end,
  preferences = function() return {sync={time_enabled=true,time_eink_only=true}} end,
}
local pending_checks=0
local queue={
  summary=function() return {pending=20,control={next_send=0}} end,
  pending=function()
    pending_checks=pending_checks+1
    return {rows={}}
  end,
}
local host={sync=session,is_online=function() return true end}
local c=setmetatable({store=store,host=host,sync=session,queue=queue,
  active={book_id='book'},recovered={test=true},worker={busy=function() return false end},
  schedule=function() end},Controller)
assert(not c:send() and pending_checks==0, 'live clock entered dispatch')
c.active=nil
assert(not c:send() and pending_checks==0, 'live reader entered dispatch')
session.state='stopped'
host._reading_end_sync_active=true
assert(not c:send() and pending_checks==0, 'close barrier was bypassed')
host._reading_end_sync_active=false
assert(not c:send() and pending_checks==1, 'closed cached Sync.current blocked queue forever')
print('PASS: live session blocks dispatch; stopped sync with stale current may resume queued work')
