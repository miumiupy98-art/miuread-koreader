-- Exercise real submission, Web verification and persisted generation checks.
-- Only timers, transport responses and device/store boundaries are simulated.
-- Run from the repository root with lua5.1 or luajit; no selftest feature needed.
local function read(path)
    local file=assert(io.open(path,"rb"))
    local source=file:read("*a");file:close();return source
end
local main=read("miuread.koplugin/main.lua")
local sync_source=read("miuread.koplugin/miuread/sync.lua")
local function copy(value)
    if type(value)~="table" then return value end
    local out={};for key,item in pairs(value) do out[key]=copy(item) end;return out
end
local function install(source,owner,name,env)
    local start=assert(source:find("function "..owner..":"..name.."(",1,true),name)
    local following=assert(source:find("\nfunction "..owner..":",start+1,true),name)
    local chunk=assert(loadstring(source:sub(start,following-1),name))
    setfenv(chunk,env);chunk()
end
local function target(co)
    return {chapter_uid="27",chapter_idx=3,offset=co,canonical_offset=co,
        chapter_offset=co,progress=2,safe=true,precise=true,native_offset=true,
        offset_basis="wr_data_co"}
end
local function fixture()
    local f={now=0,timers={},sessions={},posts=0,reads=0,callbacks=0,
        auth={account={vid="account-a"},login_session_id="login-a"},
        cloud={chapter_uid="27",offset=336,percent=0,source="web_cookie",updated_at=os.time()}}
    local ui={}
    function ui:scheduleIn(delay,fn) f.timers[#f.timers+1]={at=f.now+delay,fn=fn} end
    function f:tick()
        for _=1,100 do
            if #self.timers==0 then return end
            table.sort(self.timers,function(a,b) return a.at<b.at end)
            local task=table.remove(self.timers,1);self.now=task.at;task.fn()
        end
        error("timer loop")
    end
    local env=setmetatable({Plugin={},Sync={},U={copy=copy},UIManager=ui,
        logger={info=function() end,warn=function() end}}, {__index=_G})
    for _,name in ipairs({"_normalize_exact_progress_snapshot","_prepare_progress_snapshot",
        "_progress_snapshot_current","_save_pending_progress","_save_progress_state",
        "_commit_progress_verified","_remote_matches","_verify_progress_submission",
        "_submit_progress_snapshot","_progress_write_fence","_clear_progress_write_fence"}) do
        install(main,"Plugin",name,env)
    end
    install(sync_source,"Sync","upload_progress",env)
    local store={}
    function store:preferences() return {sync={threshold=2}} end
    function store:auth() return copy(f.auth) end
    function store:session(id) return copy(f.sessions[id] or {}) end
    function store:save_session(id,patch)
        f.sessions[id]=f.sessions[id] or {}
        for key,value in pairs(patch) do f.sessions[id][key]=copy(value) end
        if f.on_save then f.on_save(id,patch) end
        return true
    end
    local catalog={{uid="27",index=3,word_count=3000}}
    local record={book={book_id="book"},path="/fixture.epub",record={chapter_map=catalog}}
    local host=setmetatable({store=store,_persisted_sessions=function() return f.sessions end,
        _invalidate_home_sync_status=function() end}, {__index=env.Plugin})
    local sync=setmetatable({host=host,store=store,record=function() return record end,
        _progress_catalog=function() return catalog,"fixture" end,
        set_cloud_anchor=function(_,_,p) f.anchor=copy(p) end,mark_verified=function() end,
        begin_progress_write=function(_,_,done) done(true);return true end,
        end_progress_write=function() end}, {__index=env.Sync})
    host.sync=sync
    function sync:upload(seconds,done,options)
        assert(seconds==0 and options.progress_only and options.transactional_context)
        local position=copy(options.position_override)
        f.posts=f.posts+1
        ui:scheduleIn(.2,function()
            if not f.no_commit then
                f.cloud={chapter_uid=position.chapter_uid,offset=position.canonical_offset,
                    percent=position.progress,source="web_cookie",updated_at=os.time()}
            end
            if f.unknown_response then done(false,"transport_unknown",position,{request_dispatched=true})
            else done(true,{succ=1},position,{accepted=true,request_dispatched=true}) end
        end)
        return true
    end
    function sync:remote(_,done,options)
        assert(options.web_only and options.verify_only and options.update_cloud_anchor==false)
        f.reads=f.reads+1
        ui:scheduleIn(.2,function() done(copy(f.cloud)) end)
        return true
    end
    function f:submit(position,options)
        options=options or {verify_delays={.2}}
        return host:_submit_progress_snapshot("book",position or target(800),options,function(ok,remote,why)
            self.callbacks=self.callbacks+1;self.ok=ok;self.why=why;self.remote=remote
        end)
    end
    f.host,f.store,f.ui=host,store,ui
    return f
end

local passed,failed=0,{}
local function test(name,run)
    local ok,err=pcall(run)
    if ok then passed=passed+1
    else failed[#failed+1]=name..": "..tostring(err) end
end
test("successful POST and Web confirmation return success",function()
    local f=fixture();f:submit();f:tick()
    assert(f.ok==true,tostring(f.why))
    assert(f.posts==1 and f.reads==1 and f.callbacks==1)
    assert(f.sessions.book.progress_upload_state=="verified" and f.sessions.book.pending_progress==false)
end)
test("verify-first confirms without a POST",function()
    local f=fixture();f.cloud.offset=800
    f:submit(nil,{verify_first=true,verify_delays={.2}});f:tick()
    assert(f.ok==true,tostring(f.why))
    assert(f.posts==0 and f.reads==1 and f.callbacks==1)
end)
test("verified snapshot cannot be sent again",function()
    local f=fixture();local p=target(800);f:submit(p);f:tick()
    f:submit(p);f:tick()
    assert(f.ok==false and f.why=="superseded" and f.posts==1)
end)
test("newer sequence rejects late verification",function()
    local f=fixture();f:submit(nil,{verify_delays={1}})
    f.ui:scheduleIn(.5,function() f.host:_prepare_progress_snapshot("book",target(900)) end)
    f:tick()
    assert(f.ok==false and f.why=="superseded" and f.posts==1)
    assert(f.sessions.book.progress_latest_sequence==2 and not f.sessions.book.progress_verified_sequence)
end)
test("newer epoch rejects late verification",function()
    local f=fixture();f:submit(nil,{verify_delays={1}})
    f.ui:scheduleIn(.5,function() f.store:save_session("book",{progress_epoch=2}) end)
    f:tick()
    assert(f.ok==false and f.why=="superseded" and not f.sessions.book.progress_verified_sequence)
end)
test("newer snapshot after verification is not accepted as current",function()
    local f=fixture()
    f.on_save=function(id,patch)
        if patch.progress_verified_sequence then
            f.sessions[id].progress_latest_sequence=patch.progress_verified_sequence+1
        end
    end
    f:submit();f:tick()
    assert(f.ok==false and f.why=="superseded" and f.posts==1)
end)
for _,verify_first in ipairs({false,true}) do
    for _,field in ipairs({"session","account"}) do
        test("changed "..field.." stops "..(verify_first and "verify-first" or "POST verification"),function()
            local f=fixture();f.cloud.offset=800
            f:submit(nil,{verify_first=verify_first,verify_delays={1}})
            local late_writes=0
            f.ui:scheduleIn(.5,function()
                if field=="session" then f.auth.login_session_id="login-b"
                else f.auth.account.vid="account-b" end
                f.on_save=function() late_writes=late_writes+1 end
            end)
            f:tick()
            assert(f.ok==false and f.why=="account_changed",tostring(f.why))
            assert(late_writes==0,"old verification wrote into changed account/session")
            assert(not f.sessions.book.progress_verified_sequence)
        end)
    end
end
test("unknown POST response is verified without replay",function()
    local f=fixture();f.unknown_response=true;f:submit();f:tick()
    assert(f.ok==true and f.posts==1 and f.reads==1 and f.callbacks==1,tostring(f.why))
end)
test("real mismatch stays pending without replay",function()
    local f=fixture();f.no_commit=true;f:submit();f:tick()
    assert(f.ok==false and f.posts==1 and f.reads==1)
    assert(f.sessions.book.progress_upload_state=="submitted" and type(f.sessions.book.pending_progress)=="table")
end)
test("native Web offset 76 is an equivalent confirmed position",function()
    local f=fixture();f.cloud.offset=724 -- submitted=800, delta=76
    f.no_commit=true;f:submit(target(800));f:tick()
    assert(f.ok==true and f.posts==1 and f.reads==1,tostring(f.why))
end)
test("native Web offset 101 must remain unconfirmed",function()
    local f=fixture();f.cloud.offset=699 -- submitted=800, delta=101
    f.no_commit=true;f:submit(target(800));f:tick()
    assert(f.ok==false and f.posts==1 and f.reads==1)
end)
test("different chapter must never pass tolerance",function()
    local f=fixture();f.cloud.chapter_uid="28";f.cloud.offset=800
    f.no_commit=true;f:submit(target(800));f:tick()
    assert(f.ok==false and f.posts==1)
end)
test("unresolved zero offset is not an accepted chapter start",function()
    local f=fixture();f.cloud.offset=0;f.cloud.position_basis="wr_data_co_unresolved"
    f.no_commit=true;f:submit(target(30));f:tick()
    assert(f.ok==false)
end)
test("stale server timestamp cannot confirm otherwise matching co",function()
    local f=fixture();f.cloud.offset=800;f.cloud.updated_at=os.time()-600
    f.no_commit=true;f:submit(target(800));f:tick()
    assert(f.ok==false and f.posts==1)
end)
test("pending-saved final position uses the same real page event for fence",function()
    local f=fixture()
    f.store:save_session("book",{local_position_event_seq=30,
        progress_write_guard={reason="remote_exact_unresolved",blocked_event_seq=29,progress_epoch=1}})
    local position=target(800)
    f.host:_save_pending_progress("book",position,"final_position_captured","finalizing")
    assert(position.local_position_event_seq==30,"save_pending did not propagate event to final snapshot")
    f:submit(position,{pending_already_saved=true,verify_delays={.2}})
    f:tick()
    assert(f.posts==1 and f.ok==true,tostring(f.why))
end)
test("trusted resolved chapter-start zero can be confirmed",function()
    local f=fixture();f.cloud.offset=0;f.cloud.position_basis="wr_data_co"
    f.no_commit=true;f:submit(target(0));f:tick()
    assert(f.ok==true and f.posts==1 and f.reads==1,tostring(f.why))
end)
test("non-Web coordinates do not inherit the 100-unit allowance",function()
    local f=fixture()
    local bad={source="eink",chapter_uid="27",offset=724,percent=2,position_basis="eink"}
    local ok=f.host:_remote_matches(bad,target(800),false)
    assert(ok==false,"100-unit tolerance incorrectly applied to native EInk coordinate")
end)
test("old pending retry cannot borrow a later reading event",function()
    local f=fixture()
    f.store:save_session("book",{local_position_event_seq=30,
        progress_write_guard={reason="remote_exact_unresolved",blocked_event_seq=29,progress_epoch=1}})
    local older=target(800);older.local_position_event_seq=nil
    f.host:_save_pending_progress("book",older,"retry_upload_queued","deferred")
    -- It can retain its old event ID only if one was attached to its original
    -- snapshot; never grant it event=30 solely from the current session.
    assert(older.local_position_event_seq==nil,"replay borrowed a newer event")
end)
test("no fresh reading event must still respect a remote fence",function()
    local f=fixture()
    f.store:save_session("book",{local_position_event_seq=29,
        progress_write_guard={reason="remote_exact_unresolved",blocked_event_seq=29,progress_epoch=1}})
    local position=target(800);position.local_position_event_seq=29
    f:submit(position,{verify_delays={.2}})
    f:tick()
    assert(f.posts==0 and f.ok==false,"remote fence incorrectly bypassed")
end)
for _,message in ipairs(failed) do io.stderr:write("FAIL: ",message,"\n") end
assert(#failed==0,tostring(#failed).." progress confirmation regression(s) failed")
print("progress confirmation transactions: PASS ("..passed.." scenarios)")
