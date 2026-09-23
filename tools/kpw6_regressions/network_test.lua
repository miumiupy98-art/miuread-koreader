require('setupkoenv')
local candidate=arg[1] or 'plugins/miuread.koplugin'
package.path=candidate..'/?.lua;plugins/miuread.koplugin/?.lua;'..package.path
local clock=require('socket').gettime
local function read(path) local f=assert(io.open(path));local s=f:read('*a');f:close();return s end
local source=read(candidate..'/main.lua')
local chunk=assert(source:match('(function Plugin:is_online%(%).-)\n%-%- Fast local hint'))
local Plugin={}
assert(loadstring('return function(Plugin) '..chunk..' end'))()(Plugin)
local dns=0
local network={isWifiOn=function() return true end,isConnected=function() return true end,isOnline=function() dns=dns+1;error('DNS MUST NOT RUN IN UI') end,getCurrentNetwork=function() return {ssid='test'} end}
package.loaded['ui/network/manager']=network
local t=clock()
for i=1,1000 do assert(Plugin:is_online()) end
assert(dns==0)
print('PREFLIGHT_1000_MS',(clock()-t)*1000)
network.isWifiOn=function() return false end;assert(not Plugin:is_online())
network.isWifiOn=function() return true end;network.isConnected=function() return false end;assert(not Plugin:is_online())
network.isConnected=function() error('local status unavailable') end;assert(Plugin:is_online())
network.isConnected=function() return true end
package.loaded.device={isKindle=function() return true end,getPowerDevice=function() return {getCapacity=function() return 80 end,isCharging=function() return false end} end}
local health={state='recovering',age=1};local writes=0
package.loaded['miuread.network_health']={snapshot=function() return health end,note_success=function() writes=writes+1;health={state="ok",age=0} end}
local Home= require('miuread.home_data')
t=clock()
for i=1,1000 do local s=Home.quick_device_state(true);assert(s.network_phase=='connected' and s.online==nil) end
assert(dns==0);print('QUICK_STATE_1000_MS',(clock()-t)*1000)
health={state='ok',age=2};assert(Home.quick_device_state(true).online==true);assert(writes==0,'UI must not renew stale health')
health={state='ok',age=2,reason='network-manager-associated'};assert(Home.quick_device_state(true).online==nil)
health={state='ok',age=61};assert(Home.quick_device_state(true).online==nil)
health={state='down',age=2};assert(Home.quick_device_state(true).online==false)
network.isWifiOn=function() return false end;assert(Home.quick_device_state(true).network_phase=='off')
assert(dns==0)
network.isWifiOn=function() return true end;health={state='unknown',age=100}
network.isOnline=function() dns=dns+1;return true end
health={state='recovering',age=1}
local probed=Home.quick_device_state(true,true)
assert(probed.online==true and probed.network_phase=='connected');assert(dns==1 and writes==1)
local extension=read(candidate..'/miuread/extension_job.lua')
local fn=assert(extension:match('(local function network_connected%(%)\n.-\nend)'))
local connected=assert(loadstring(fn..'\nreturn network_connected'))()
network.isOnline=function() error('DNS MUST NOT RUN') end
assert(connected());network.isConnected=function() return false end;assert(not connected())
local Hygiene=require('miuread.subprocess_hygiene')
assert(Hygiene.reset_resolver(),'Kindle glibc reset must work')
local ffi=require('ffi');package.loaded.ffi={cdef=function() end,C={}}
assert(Hygiene.reset_resolver()==false,'unsupported libc must be safe')
package.loaded.ffi=ffi
print('UI_NETWORK_TESTS_OK')
