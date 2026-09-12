local function read(path) local f=assert(io.open(path));local s=f:read('*a');f:close();return s end
local source=read(assert(arg[1]))
assert(source:find('self.store:save_preferences_deferred(preferences,delay==false)',1,true),
    'navigation must survive Store reloads from other plugin paths')
assert(loadstring(source),'main.lua syntax')
local function method(name)
    local a=assert(source:find('function Plugin:'..name..'(',1,true))
    local b=assert(source:find('\nfunction Plugin:',a+1,true))
    return source:sub(a,b-1)
end
local UI={tasks={}}
function UI:scheduleIn(delay,task) self.tasks[task]=delay end
function UI:unschedule(task) self.tasks[task]=nil end
local code='local UIManager,logger,HomeView,U=...;local Plugin={}\n'
for _,name in ipairs({'_save_home_preferences_deferred','_pause_home_preferences_flush','_resume_home_preferences_flush','_flush_home_preferences'}) do code=code..method(name)..'\n' end
local Plugin=assert(loadstring(code..'return Plugin'))(UI,{info=function() end,warn=function() end},{is_shown=function() return true end},{first_line=tostring})
local writes=0
local store={preferences=function(self) return self.value end,save_preferences_deferred=function(self,p) self.value=p end,flush=function() writes=writes+1;return true end}
local host=setmetatable({store=store,_active_reader_ui=function() return false end,_home_ui_busy=function() return false end},{__index=Plugin})
local function tasks() local n=0;for _ in pairs(UI.tasks) do n=n+1 end;return n end
local function fire() local t=UI.tasks;UI.tasks={};for fn in pairs(t) do fn() end end
host:_save_home_preferences_deferred({active_section='shelf'},{},false)
local stale=function() end
for _,section in ipairs({'device','recent','shelf','recent'}) do
    host:_save_home_preferences_deferred({active_section=section},{},false)
    if arg[2]=='baseline' then fire() else assert(tasks()==0,'navigation must not queue full settings writes') end
end
if arg[2]=='baseline' then assert(writes==4);print('BASELINE_NAVIGATION_FULL_WRITES',writes);return end
stale();assert(writes==0,'stale timer must not flush')
assert(store.value.home_ui.active_section=='recent')
host:_pause_home_preferences_flush('reader')
assert(host:_resume_home_preferences_flush()==false and tasks()==0,'return to home must not rearm navigation flush')
assert(host:_flush_home_preferences()==true and writes==1,'lifecycle saves latest navigation')
assert(host:_flush_home_preferences()==false and writes==1,'do not save twice')
host:_save_home_preferences_deferred({active_section='device',display_size='large'},{},2)
assert(tasks()==1,'ordinary settings retain timer')
fire();assert(writes==2 and not host._home_state_save_pending)
host:_save_home_preferences_deferred({active_section='shelf'},{},false)
host:_save_home_preferences_deferred({active_section='shelf',display_size='small'},{},2)
assert(tasks()==1,'a later settings change restores normal persistence');fire();assert(writes==3)
-- A navigation after a real setting must not cancel that setting's timer.
host:_save_home_preferences_deferred({active_section='shelf',display_size='large'},{},2)
local replaced=host._home_state_save_task
host:_save_home_preferences_deferred({active_section='recent',display_size='large'},{},false)
assert(tasks()==1 and not host._home_state_save_on_exit)
replaced();assert(writes==3,'superseded callback must not flush')
fire();assert(writes==4 and store.value.home_ui.display_size=='large')
-- Store:flush can restore old disk data on failure; keep pending values retryable.
host:_save_home_preferences_deferred({active_section='device'},{},false)
store.flush=function(self) self.value={home_ui={active_section='shelf'}};return false,'simulated disk failure' end
assert(host:_flush_home_preferences()==false and host._home_state_save_pending)
assert(store.value.home_ui.active_section=='device','failed flush must preserve intended navigation')
store.flush=function() writes=writes+1;return true end
assert(host:_flush_home_preferences()==true and writes==5)
for _,name in ipairs({'_home_change_page' ,'_home_apply_section','_set_home_section'}) do
    assert(method(name):find('preferences,false)',1,true),name..' must use navigation persistence')
end
assert(method('onSuspend'):find('if self._home_state_save_on_exit then self:_flush_home_preferences() end',1,true))
print('NAVIGATION_NO_UI_FLUSH_LIFECYCLE_AND_SETTINGS_OK')
