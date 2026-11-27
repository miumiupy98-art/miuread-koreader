-- Verify controller quarantines deterministic errors before any transport
-- dispatch. The async worker is executed synchronously only in this test.
local TOOL_DIR=tostring(arg and arg[0] or ""):gsub("\\","/"):match("^(.*)/[^/]+$") or "."
package.path=TOOL_DIR.."/../miuread.koplugin/?.lua;"..package.path
package.preload["ui/uimanager"]=function() return {} end
package.preload["miuread.async"]=function() return {} end
package.preload["miuread.readtime_outbox"]=function() return {} end
package.preload["miuread.readtime_stats"]=function() return {} end
package.preload["miuread.diagnostic_log"]=function() return {now=os.time,record=function() end} end
package.preload["miuread.readtime_clock"]=function() return {} end
package.preload["miuread.readtime_metadata"]=function() return {} end
package.preload["miuread.api_transport"]=function() return {new=function() return {selected="eink"} end} end
package.preload["miuread.eink_client"]=function() return {new=function() return {request=function() error("unexpected request") end} end} end
package.preload["miuread.eink_readtime"]=function()
    return {prepare=function() error("overlapping reading-time hour",0) end,
        send=function() error("transport must not be called after preflight failure") end}
end
package.preload["miuread.http"]=function()
    return {rate_limit_details=function() return nil end,is_auth_error=function() return false end,
        is_network_error=function() return false end}
end
local M=require("miuread.readtime_controller")
local function controller(batch)
    local logs,scheduled,dispatched={},nil,false
    local store={data_dir="test",preferences=function() return {sync={time_enabled=true,time_route_mode="eink"}} end,
        auth=function() return {account={vid="test-user"},login_session_id="s1"} end}
    local queue={pending=function() return batch end,quarantine=function(_,account,rows,reason)
        assert(account=="test-user" and #rows==2 and reason=="overlapping_reading_time_hour")
        return {rows=2,seconds=120}
    end,
    quarantine_overlap_batch=function(_,account,rows)
        assert(account=="test-user" and #rows==2)
        return {rows=1,seconds=60}
    end,
    defer=function() return {next_send=os.time()+60} end,
    finish=function() error("preflight failure must not claim anything") end}
    local worker={busy=function() return false end,run=function(_,_,task,finished)
        dispatched=true
        local ok,value=pcall(task)
        finished({ok=ok,value=value})
        return true
    end}
    local c=setmetatable({store=store,queue=queue,worker=worker,
        host={is_online=function() return true end},
        recovered={}},M)
    function c:_recover() return true end
    function c:summary() return {pending=120,control={next_send=0}} end
    function c:schedule(delay) scheduled=delay end
    function c:log(phase,outcome,values) logs[#logs+1]={phase=phase,outcome=outcome,values=values} end
    return c,logs,function() return dispatched,scheduled end
end

-- Queue-side preflight prevention: no worker should ever be started.
do
    local c,logs,flags=controller({book_id="book",book_version=1,rows={},seconds=0,
        invalid_rows={{id="1",duration=60},{id="2",duration=60}}})
    assert(c:send()==false)
    local dispatched,delay=flags()
    assert(dispatched==false and delay==10)
    assert(logs[1].phase=="quarantine" and logs[1].values.request_dispatched==false)
end

-- Defensive fallback: the E-Ink protocol rejects while constructing a body.
-- Isolate only matching rows, never send an HTTP POST or claim in-flight.
do
    local c,logs,flags=controller({book_id="book",book_version=1,
        rows={{id="1",duration=60},{id="2",duration=60}},seconds=120,invalid_rows={}})
    assert(c:send()==true)
    local launched,delay=flags()
    assert(launched and delay>=10)
    local found=false
    for _,entry in ipairs(logs) do
        if entry.phase=="quarantine" then
            assert(entry.values.request_dispatched==false)
            found=true
        end
    end
    assert(found,"controller must log quarantined preflight and never dispatch")
end
-- A fresh unresolved position on the same book must not suppress queued time.
do
    local row={id="1",book_id="book",book_version=1,start_time=os.time()-61,duration=60}
    local batch={book_id="book",book_version=1,rows={row},seconds=60,invalid_rows={}}
    local c,logs=controller(batch)
    local selected=false
    c.store.read_persisted=function(_,key)
        if key=="sessions" then
            return {book={pending_unresolved_position={captured_at=os.time()}}}
        end
        return {account={vid="test-user"},login_session_id="s1"}
    end
    c.queue.pending=function(_,_,_,eligible)
        selected=eligible(row)
        return selected and batch or {rows={},invalid_rows={}}
    end
    c.queue.quarantine_overlap_batch=function() return {rows=0} end
    assert(c:send()==true and selected,"position recovery must not prevent batch selection")
end

-- Confirm the actual controller seals only the verified prefix at expiry.
do
    local c=controller({})
    local now=os.time()
    local Stats=require("miuread.readtime_stats")
    function Stats.snapshot()
        return {{page=1,start_time=now-40,duration=30},{page=2,start_time=now-10,duration=10},
            {page=3,start_time=now-12,duration=12}}
    end
    function Stats.persisted() return {} end
    require("miuread.readtime_clock").sample=function() return {wall=now,zone="+00:00"} end
    local sync={}
    function sync:entitlement_page(_,_,page,_,start)
        local expiry=now-20
        if page==3 then return nil end
        return start<expiry,expiry
    end
    c.active={vid="test-user",sync=sync,record={},entitlement={},stats_book=7,
        stats={id_curr_book=7,isEnabledAndNotFrozen=function() return true end},
        book_id="book",last_scan=now-50,sources={},
        window={id="licensed-window",time_zone="+00:00",capture_not_before=now-50}}
    function c.queue:observe() return {zone="+00:00"} end
    function c.queue:collect(_,id,spans,_,close)
        assert(id=="licensed-window" and close and #spans==1 and spans[1].page==1 and spans[1].duration==20)
        return {seconds=20,rows=1}
    end
    assert(c:collect(true) and c.active==nil)
end
print("readtime controller pre-dispatch quarantine and preflight fallback passed")
