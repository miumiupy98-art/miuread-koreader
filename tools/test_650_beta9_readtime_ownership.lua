-- Deterministic test against the production preemption function. No Kindle or Web required.
local f=assert(io.open('miuread.koplugin/miuread/sync.lua','rb'))
local source=f:read('*a');f:close()
local a=assert(source:find('function Sync:preempt_reading_time_for_progress(',1,true))
local b=assert(source:find('function Sync:_cancel_record_retry()',a,true))
local body=source:sub(a,b-1)
Sync={}
FINAL_FLUSH_GRACE_POLLS=24
local scheduled={}
UIManager={scheduleIn=function(_,delay,fn) scheduled[#scheduled+1]=fn end}
logger={info=function() end,warn=function() end}
U={atomic_write=function() end}
local signals=0
signal_process=function() signals=signals+1 end
subprocess_done=function() return false end
process_alive=function() return true end
local fn=assert(loadstring or load)(body)
fn()
local function make()
    local old={pid=111,paths={stop='/unused'},final_flush_pending=true}
    local x={daemon=old,reading_time_session_id='S',reading_time_segment_id='A',async={cancel=function() error('new async cancelled') end}}
    setmetatable(x,{__index=Sync})
    function x:_import_daemon_status() end
    function x:cancel_writer_barrier_waits() error('new barrier cancelled') end
    return x,old
end
local function run_one_scheduled()
    local fn=table.remove(scheduled,1)
    assert(fn,'scheduled callback expected')
    fn()
end
-- Old suspend finalizer already stale when invoked: cannot stop the new worker.
do
    local x,old=make()
    local new={pid=222,paths={stop='/new'}}
    x.daemon=new
    x.reading_time_segment_id='B'
    local ok,state
    x:preempt_reading_time_for_progress('suspend',function(result,metadata)
        ok=result;state=metadata.state
    end,false,{daemon=old,session='S',segment='A'})
    assert(ok==false and state=='writer_owner_changed')
    assert(x.daemon==new and signals==0)
end
-- Grace wait begins before wake. Wake occurs before its next tick.
do
    scheduled={}
    local x,old=make()
    local ok,state
    x:preempt_reading_time_for_progress('suspend',function(result,metadata)
        ok=result;state=metadata.state
    end)
    assert(#scheduled==1)
    local new={pid=333,paths={stop='/new'}}
    x.daemon=new;x.reading_time_segment_id='B'
    run_one_scheduled()
    assert(ok==false and state=='writer_owner_changed')
    assert(x.daemon==new and signals==0)
end
-- Even if the daemon object is reused, an altered segment must be rejected.
do
    scheduled={}
    local x,old=make()
    x.reading_time_segment_id='B'
    local result
    x:preempt_reading_time_for_progress('suspend',function(ok) result=ok end,false,
        {daemon=old,session='S',segment='A'})
    assert(result==false and signals==0)
end
print('PASS beta.9 read-time finalizer ownership across wake and delayed callbacks')
