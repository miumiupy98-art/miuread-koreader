-- Standalone regression tests: texlua tools/test_download_resource_admission.lua
-- No KOReader UI, real credentials, or real subprocess required.
local root=(arg[0] or ''):gsub('tools/test_download_resource_admission.lua$', '')
if root=='' then root='./' end
package.path=root..'miuread.koplugin/?.lua;'..root..'miuread.koplugin/?/init.lua;'..package.path
local Admission=require('miuread.download_admission')
local config={HEAVY_DOWNLOAD_START_MIN_KB=98304,HEAVY_DOWNLOAD_RESUME_MIN_KB=98304,
    DOWNLOAD_RESOURCE_RETRY_FIRST_SECONDS=5,DOWNLOAD_RESOURCE_RETRY_MAX_SECONDS=60}
local function compile(code, name, env)
    if _VERSION=='Lua 5.1' then
        local chunk=assert(loadstring(code,name));setfenv(chunk,env);return chunk
    end
    return assert(load(code,name,'t',env))
end
local count=0
local function test(name,callback)
    local ok,err=pcall(callback)
    if not ok then error(name..': '..tostring(err)) end
    count=count+1
end
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end

test('fresh and resumed must require same fork margin',function()
    eq(Admission.minimum(config),98304)
    local okay,reason=Admission.check({available_kb=85*1024},config)
    eq(okay,false);eq(reason,'low_memory')
    eq(Admission.check({available_kb=110*1024},config),true)
end)
test('defensive maximum when configs diverge',function()
    -- Standalone fallback path: without the runtime pressure profile (no
    -- /proc or its dependencies), admission keeps the defensive maximum.
    eq(Admission.minimum({HEAVY_DOWNLOAD_START_MIN_KB=100,HEAVY_DOWNLOAD_RESUME_MIN_KB=200}),200)
end)
test('meminfo not present remains compatible',function()
    eq(Admission.check(nil,config),true)
    eq(Admission.check({available_kb=nil},config),true)
end)

local handle=assert(io.open(root..'miuread.koplugin/main.lua','rb'))
local source=handle:read('*a');handle:close()
local start=assert(source:find('function Plugin:_schedule_resource_download_retry',1,true))
local finish=assert(source:find('function Plugin:show_waiting_downloads()',start,true))
local snippet=source:sub(start,finish-1)
local pending,used_mem,normal,background,events,scheduled
local _G_ENV=_G
local sandbox={Plugin={},Config=config,
    UIManager={_exit_code=nil,scheduleIn=function(_,delay,cb)
        scheduled[#scheduled+1]={delay=delay,cb=cb}
    end},
    PowerState={state=function() return normal and 'NORMAL' or 'SUSPENDED' end},
    RuntimePressure={memory_snapshot=function() return {available_kb=used_mem,total_kb=512*1024} end},
    DownloadAdmission=Admission,collectgarbage=function() end,
    logger={info=function() end,warn=function() end},HOME_SESSION={suspended=false},
    HOME_EXITING=false,math=math,tonumber=tonumber,tostring=tostring,type=type,os=os,
}
setmetatable(sandbox,{__index=_G_ENV})
compile(snippet,'@download_resource_methods',sandbox)()
local function new_env()
    used_mem=85*1024;normal=true;background=nil
    scheduled={};events={}
    pending={{key='x',book={bookId='x',title='test'},options={},open_after=false,wait_reason='low_memory',account_vid='account1'}}
    local store={}
    function store:download_queue() return pending end
    function store:auth() return {account={vid='account1'}} end
    function store:enqueue_download(job)
        if #pending>0 then return nil,'full' end
        pending={job};return 1
    end
    function store:download_state() return {status='idle'} end
    function store:save_download_queue(q) pending=q end
    function store:dequeue_download()
        if #pending==0 then return nil end
        return table.remove(pending,1)
    end
    local plugin=setmetatable({
       store=store,download_task={busy=function() return false end},
       background_scheduler={active=nil,set_foreground_barrier=function() end},_download_runtime=nil,
       _resource_retry_attempt=0,_resource_retry_task=nil,
    },{__index=sandbox.Plugin})
    function plugin:logged_in() return true end
    function plugin:_network_radio_hint() return true end
    function plugin:_active_reader_ui() return nil end
    function plugin:download(book,options,open_after)
        events[#events+1]='start:'..book.bookId
        self._download_runtime={book=book}
    end
    function plugin:_queue_download(book,opt,open_after,extra)
        pending={{book=book,options=opt,open_after=open_after,wait_reason=extra.reason}}
        events[#events+1]='queued:'..tostring(extra.reason)
        return true
    end
    return plugin
end
local function run_next()
    local item=table.remove(scheduled,1)
    assert(item,'no task scheduled')
    item.cb()
    return item.delay
end

test('85 MiB parks durable queue and schedules retry',function()
    local p=new_env()
    eq(p:_start_next_queued_download(),false)
    eq(#pending,1);eq(#events,0);eq(#scheduled,1)
    eq(scheduled[1].delay,5)
    eq(p:_start_next_queued_download(),false)
    eq(#scheduled,1) -- one timer only
end)
test('memory recovers and queued download starts exactly once',function()
    local p=new_env()
    p:_start_next_queued_download()
    used_mem=110*1024
    run_next() -- retry: leave queued job durable until launch callback
    eq(#pending,1);eq(#scheduled,1)
    run_next()
    eq(#events,1);eq(events[1],'start:x')
end)
test('explicit removal of waiting task is respected',function()
    local p=new_env();p:_start_next_queued_download()
    pending={};used_mem=110*1024
    run_next()
    eq(#events,0);eq(#scheduled,0)
end)
test('suspend cannot spawn new worker',function()
    local p=new_env();normal=false
    eq(p:_start_next_queued_download(),false)
    eq(#pending,1);eq(#events,0)
end)
test('background lease must release before download',function()
    local p=new_env(); used_mem=110*1024
    p.background_scheduler.active={key='home_cover'}
    eq(p:_start_next_queued_download(),false)
    eq(#pending,1);eq(#scheduled,1)
    p.background_scheduler.active=nil
    run_next();run_next()
    eq(#events,1)
end)
test('retry delay is bounded exponential',function()
    local p=new_env()
    local expected={5,10,20,40,60,60}
    for i,v in ipairs(expected) do
        p:_start_next_queued_download()
        eq(#scheduled,1)
        eq(scheduled[1].delay,v)
        run_next()
    end
end)
test('fork race requeues instead of starting after lifecycle change',function()
    local p=new_env();used_mem=110*1024
    p:_start_next_queued_download()
    normal=false
    run_next()
    eq(#pending,1)
    eq(#events,0) -- recheck lifecycle; do not start or dequeue
    eq(#pending,1)
end)
test('removal after retry admission cancels already scheduled launch',function()
    local p=new_env();used_mem=110*1024
    eq(p:_start_next_queued_download(),true)
    eq(#pending,1)
    pending={} -- user clears the queue during the 150ms launch delay
    run_next()
    eq(#events,0);eq(#pending,0)
end)
test('network loss after admission cannot dequeue the waiting job',function()
    local p=new_env();used_mem=110*1024
    eq(p:_start_next_queued_download(),true)
    function p:_network_radio_hint() return false end
    run_next()
    eq(#events,0);eq(#pending,1)
end)
test('account switch prevents queued job launch',function()
    local p=new_env();used_mem=110*1024
    pending[1].account_vid='account2'
    eq(p:_start_next_queued_download(),false)
    eq(#events,0);eq(#pending,1)
end)
test('legacy waiting task without account identity requires confirmation',function()
    local p=new_env();used_mem=110*1024
    pending[1].account_vid=nil
    eq(p:_start_next_queued_download(),false)
    eq(#pending,1);eq(#events,0);eq(#scheduled,0)
end)
test('task replacement invalidates delayed launch',function()
    local p=new_env();used_mem=110*1024
    pending[1].queue_nonce='old'
    eq(p:_start_next_queued_download(),true)
    pending[1]={key='new',queue_nonce='new',book={bookId='new'},options={},wait_reason='low_memory'}
    run_next()
    eq(#events,0);eq(#pending,1)
end)
-- The scheduler may release a stale lease only when its worker is
-- independently confirmed absent, never just because 300 seconds elapsed.
local schedule_file=assert(io.open(root..'miuread.koplugin/miuread/background_scheduler.lua','rb'))
local schedule_source=schedule_file:read('*a');schedule_file:close()
local s1=assert(schedule_source:find('function Scheduler:_clear_stale_active()',1,true))
local s2=assert(schedule_source:find('function Scheduler:claim(',s1,true))
local sched_methods=schedule_source:sub(s1,s2-1)
local sched_env={Scheduler={},Config={BACKGROUND_LEASE_TIMEOUT_SECONDS=300},
    logger=sandbox.logger,monotonic=function() return 1000 end,
    tostring=tostring,tonumber=tonumber,math=math,pcall=pcall,type=type}
compile(sched_methods,'@background_lease_probe',sched_env)()
test('long lived background worker keeps its lease',function()
    local s=setmetatable({active={key='home_cover',started=100},liveness_probe=function() return true end},{__index=sched_env.Scheduler})
    s:_clear_stale_active();assert(s.active);s:_clear_stale_active();assert(s.active)
end)
test('confirmed dead worker releases expired lease',function()
    local s=setmetatable({active={key='home_cover',started=100},liveness_probe=function() return false end},{__index=sched_env.Scheduler})
    s:_clear_stale_active();eq(s.active,nil)
end)
test('unknown worker health never causes automatic force-release',function()
    local s=setmetatable({active={key='home_cover',started=100},liveness_probe=function() return nil end},{__index=sched_env.Scheduler})
    s:_clear_stale_active();assert(s.active)
end)

local download_file=assert(io.open(root..'miuread.koplugin/miuread/download_task.lua','rb'))
local download_source=download_file:read('*a');download_file:close()
local d1=assert(download_source:find('function DownloadTask:resume_hibernated(reason)',1,true))
local d2=assert(download_source:find('function DownloadTask:_restart_interrupted',d1,true))
local download_methods=download_source:sub(d1,d2-1)
local env={DownloadTask={},RuntimePressure=sandbox.RuntimePressure,
    Config=config,DownloadAdmission=Admission,logger=sandbox.logger,
    serializable_copy=function(x) return x end,os={time=os.time,remove=function() end},
    tonumber=tonumber,type=type,tostring=tostring,math=math}
compile(download_methods,'@resume_fork_admission',env)()
test('hibernated task cannot fork at 85 MiB',function()
    used_mem=85*1024
    local h={book={bookId='x'},options={},restart_count=0}
    local dt=setmetatable({hibernated=h,heavy_watch_path='/fake'}, {__index=env.DownloadTask})
    function dt:start() error('must not fork below threshold') end
    local yes,why=dt:resume_hibernated('test')
    eq(yes,false);eq(why,'low_memory');eq(dt.hibernated,h)
end)
test('fork-time pressure race still retains hibernation descriptor',function()
    used_mem=110*1024
    local h={book={bookId='x'},options={},restart_count=0}
    local dt=setmetatable({hibernated=h,heavy_watch_path='/fake'}, {__index=env.DownloadTask})
    function dt:start() return false,'low_memory' end
    local yes,why=dt:resume_hibernated('test')
    eq(yes,false);eq(why,'low_memory');eq(dt.hibernated,h)
end)
test('hibernated task stays parked during cooldown window',function()
    used_mem=110*1024
    local h={book={bookId='x'},options={},restart_count=0,cooldown_until=os.time()+3600}
    local dt=setmetatable({hibernated=h,heavy_watch_path='/fake'}, {__index=env.DownloadTask})
    function dt:start() error('must not fork during cooldown') end
    local yes,why=dt:resume_hibernated('test')
    eq(yes,false);eq(why,'low_memory');eq(dt.hibernated,h)
end)
-- The existing one-slot SQLite queue is now the resource-wait store.
-- Failed durable writes must never be presented as accepted/removed work.
local store_file=assert(io.open(root..'miuread.koplugin/miuread/store.lua','rb'))
local store_source=store_file:read('*a');store_file:close()
local e1=assert(store_source:find('function Store:enqueue_download(job)',1,true))
local e2=assert(store_source:find('function Store:pending_installs()',e1,true))
local store_snippet=store_source:sub(e1,e2-1)
local store_env={Store={},U={copy=function(t)
    local c={};for k,v in pairs(t) do c[k]=v end;return c
end},logger=sandbox.logger,table=table,tostring=tostring,tonumber=tonumber}
compile(store_snippet,'@durable_queue',store_env)()
local function queue_store()
    local disk={};local can_save=true
    local store=setmetatable({}, {__index=store_env.Store})
    function store:download_queue()
        local out={};for k,v in ipairs(disk) do out[k]=v end;return out
    end
    function store:save_download_queue(q)
        if not can_save then return nil,'disk_full' end
        disk={};for k,v in ipairs(q) do disk[k]=v end
        return true
    end
    return store,function() return disk end,function(x) can_save=x end
end
test('failed enqueue does not claim a durable waiting job',function()
    local s,disk,writable=queue_store();writable(false)
    local at,why=s:enqueue_download({key='book1'})
    eq(at,nil);assert(why:find('queue_save_failed',1,true));eq(#disk(),0)
end)
test('failed dequeue cannot remove a queued job',function()
    local s,disk,writable=queue_store()
    eq(s:enqueue_download({key='book1'}),1)
    writable(false)
    eq(s:dequeue_download(),nil)
    eq(#disk(),1)
end)
test('successful dequeue consumes persisted job exactly once',function()
    local s,disk,writable=queue_store()
    eq(s:enqueue_download({key='book1'}),1)
    local job=s:dequeue_download()
    eq(job.key,'book1');eq(#disk(),0)
    eq(s:dequeue_download(),nil)
end)
print('PASS: '..count..' download admission regression tests')
