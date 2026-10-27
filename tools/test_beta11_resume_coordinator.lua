-- Unit-level test of the real Plugin coordinator, without KOReader UI/device.
local source=assert(io.open('miuread.koplugin/main.lua','rb')):read('*a')
local first=assert(source:find('function Plugin:_schedule_hibernated_download_resume(reason)',1,true))
local last=assert(source:find('function Plugin:_set_foreground(owner)',first+1,true))
local timers={}
local warnings={}
local manager={}
function manager:scheduleIn(delay,fn) timers[#timers+1]={delay=delay,fn=fn} end
function manager:unschedule(fn)
    for i=#timers,1,-1 do if timers[i].fn==fn then table.remove(timers,i) end end
end
local function fire()
    assert(#timers>0,'no timer')
    local task=table.remove(timers,1)
    task.fn()
    return task.delay
end
local env={Plugin={},UIManager=manager,Config={DOWNLOAD_IDLE_PUMP_SECONDS=75,DOWNLOAD_INTERACTION_RESUME_DELAY=2.5},
    U={copy=function(value) local ret={};for k,v in pairs(value) do ret[k]=v end;return ret end},
    logger={warn=function(_,...) warnings[#warnings+1]={...} end},
    require=require,math=math,tonumber=tonumber,tostring=tostring,type=type,os=os}
setmetatable(env,{__index=_G})
local code=source:sub(first,last-1)
local f
if _VERSION=='Lua 5.1' then f=assert(loadstring(code));setfenv(f,env)
else f=assert(load(code,'coordinator','t',env)) end
f()
local state='home'
local response='low_memory'
local resumes=0
local book={bookId='one'}
local task={hibernated={book=book,reason='memory_pressure'}}
function task:is_hibernated() return self.hibernated~=nil end
function task:hibernated_reason() return self.hibernated and self.hibernated.reason or nil end
function task:hibernated_cooldown_remaining() return 0 end
function task:resume_hibernated()
    resumes=resumes+1
    if response=='ok' then self.hibernated=nil;return true end
    return false,response
end
local plugin=setmetatable({download_task=task,_hibernated_low_memory_retry_count=0},{__index=env.Plugin})
function plugin:_navigation_state() return state end
function plugin:_network_radio_hint() return true end
-- Three wake events must share a single timer.
assert(plugin:_schedule_hibernated_download_resume('ui event'))
assert(plugin:_download_idle_pump_ensure('idle event'))
assert(plugin:_schedule_hibernated_download_resume('wake event'))
assert(#timers==1)
fire()
assert(resumes==1 and #timers==1 and plugin._hibernated_low_memory_retry_count==1)
response='cooldown_active';fire()
assert(resumes==2 and #timers==1 and plugin._hibernated_low_memory_retry_count==1)
response='ok';fire()
assert(resumes==3 and #timers==0 and not plugin._hibernated_download_resume_task)
-- Canceling or replacing a task invalidates its old callback.
task.hibernated={book={bookId='old'},reason='memory_pressure'}
assert(plugin:_schedule_hibernated_download_resume('old'))
task.hibernated={book={bookId='new'},reason='memory_pressure'}
fire()
assert(resumes==3 and #timers==1,'stale timer restarted a new book')
plugin:_download_idle_pump_stop()
assert(#timers==0,'coordinator not canceled')
-- Explicit cancellation never restarts a parked task.
task.hibernated={book={bookId='cancelled'},reason='memory_pressure'}
plugin:_schedule_hibernated_download_resume('before cancel')
task.hibernated=nil
fire()
assert(resumes==3 and #timers==0)
-- An app leaving the foreground stops until the wake event re-arms it.
task.hibernated={book={bookId='paused'},reason='memory_pressure'}
state='suspended';plugin:_schedule_hibernated_download_resume('suspend');fire()
assert(resumes==3 and #timers==0)
state='home';response='ok';plugin:_download_idle_pump_ensure('resume');fire()
assert(resumes==4 and #timers==0)
print('beta11 coordinator: PASS (single timer / memory / cooldown / book identity / cancel / suspend)')
