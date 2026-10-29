local UI=require("ui/uimanager")
local Async=require("miuread.async")
local Queue=require("miuread.readtime_outbox")
local Stats=require("miuread.readtime_stats")
local Log=require("miuread.diagnostic_log")
local Clock=require("miuread.readtime_clock")
local Metadata=require("miuread.readtime_metadata")
local M={}; M.__index=M
local owners={}
local function auth_account(auth)
    local vid=tostring((auth.account or {}).vid or "")
    return vid~="" and vid or tostring((auth.cookies or {}).wr_vid or "")
end
local function account(store)
    local auth=store:auth() or {}
    return auth_account(auth)
end
function M.new(store)
    local key=store.data_dir
    if owners[key] then return owners[key] end
    local object=setmetatable({store=store,queue=Queue.new(store),recovered={},sequence=0},M)
    object.worker=Async:new(store,{poll_interval=.35,allow_android=true,disable_fallback=true})
    owners[key]=object
    local vid=account(store)
    if vid~="" then object:_recover(vid) end
    return object
end
function M:enabled()
    local prefs=self.store:preferences().sync or {}
    return prefs.time_enabled==true
end
local verbose={capture=true,close=true,start=true,recover=true,preflight=true,signature_parameters=true,server_clock=true,
    position_before=true,position_after=true,dispatch=true,receipt=true}
function M:log(phase,outcome,values)
    values=values or {}
    local detailed=(self.store:preferences().sync or {}).time_diagnostics==true
    if not detailed and verbose[phase] and outcome~="error" and outcome~="rate_limited" then return end
    local signature=phase..":"..outcome..":"..tostring(values.reason)
    if not detailed and signature==self.last_log and os.time()-(self.last_log_at or 0)<300 then return end
    self.last_log,self.last_log_at=signature,os.time()
    values.operation,values.phase,values.channel,values.outcome="reading_time",phase,self.channel or "eink",outcome
    Log.record(self.store,values)
end
function M:_recover(vid)
    if self.recovered[vid] then return true end
    local count=self.queue:recover(vid)
    if count==nil then self:log("recover","error",{reason="ledger_failed"}); return false end
    self.recovered[vid]=true
    self:log("recover","success",{rows=count})
    return true
end
function M:schedule(delay)
    if self.task or self.suspended or not self:enabled() then return end
    local task
    task=function()
        if self.task~=task then return end
        self.task=nil
        self:collect(false)
        self:send()
        local summary=self:summary()
        local online=self.host and type(self.host.is_online)=="function" and self.host:is_online()
        if self.active then self:schedule(30)
        elseif summary.pending>0 and online and not summary.blocked and not summary.error
            and not self.awaiting_authorization and not self.worker_unavailable then
            self:schedule(math.max(10,(tonumber((summary.control or {}).next_send) or 0)-os.time()))
        end
    end
    self.task=task
    UI:scheduleIn(delay or 30,task)
end
function M:start(sync,record,capture_floor)
    self.host,self.sync=sync.host,sync
    self.suspended=false
    self.worker_unavailable=nil
    local stats=Stats.instance(sync.host)
    if not stats then
        self:collect(true)
        self:log("capture","waiting",{reason="statistics_unavailable"})
        self.capture_error="statistics_unavailable"
        self.summary_cache=nil
        self:schedule(2)
        return false,"请开启 KOReader 阅读统计后重新打开书籍"
    end
    local vid=account(self.store)
    if vid=="" or not self:_recover(vid) then return false,"阅读时间记录暂不可用" end
    if self.active and self.active.sync==sync and self.active.stats==stats
        and self.active.book_id==tostring(record.book.book_id) and self.active.vid==vid then
        self:schedule(15)
        return true
    end
    if not self:collect(true) then return false,"阅读时长记录无法保存，请查看同步状态" end
    local sample=Clock.sample()
    if not sample.zone then return false,"当前系统时区不可用" end
    local observation,clock_error=self.queue:observe(vid,sample)
    if not observation then self.capture_error=clock_error; return false,"阅读时间记录无法保存" end
    local now,zone=sample.wall,observation.zone
    if not zone then return false,"当前系统时区不可用" end
    local version,version_source=Metadata.resolve(self.store,record)
    self.sequence=self.sequence+1
    local window={id=tostring(sync.controller_token)..":"..tostring(now)..":"..tostring(math.random(100000,999999))..":"..tostring(self.sequence),
        book_id=tostring(record.book.book_id),start_time=now,time_zone=zone,
        capture_not_before=math.max(now,tonumber(capture_floor) or 0,tonumber(observation.capture_floor) or 0),
        book_version=version,book_version_source=version_source,risk=observation.risk}
    local saved,err=self.queue:begin(vid,window,true)
    if not saved then self.capture_error=err; self.summary_cache=nil; return false,"阅读时间记录无法保存" end
    window=saved
    self.active={sync=sync,record=record,stats=stats,stats_book=stats.id_curr_book,vid=vid,window=window,book_id=window.book_id,last_scan=now,
        sources=setmetatable({},{__mode="k"})}
    Stats.snapshot(stats,now,self.active.sources)
    self.capture_error=nil
    self:log("start","success",{book_id=window.book_id,source="koreader",start_time=now,
        book_version=version,book_version_source=version_source,risk=observation.risk})
    self:schedule(15)
    return true
end
function M:collect(close)
    local active=self.active
    if not active then return true end
    local sample=Clock.sample()
    if not sample.zone then
        self.capture_error="time_zone_unavailable"; self.summary_cache=nil
        self:log("capture","error",{reason="time_zone_unavailable"}); return false
    end
    local now=sample.wall
    local observed,clock_error=self.queue:observe(active.vid,sample,active.window.id)
    if not observed then
        self.capture_error=clock_error; self.summary_cache=nil
        self:log("capture","error",{reason=clock_error}); return false
    end
    local discontinuity=active.boundary_discontinuity or observed.discontinuity or now<active.last_scan
    local zone_changed=active.boundary_reason~=nil or (observed.zone and observed.zone~=active.window.time_zone)
    if discontinuity or zone_changed then
        local reason=active.boundary_reason or (now<active.last_scan and "clock_moved_backwards" or discontinuity and "clock_changed" or "time_zone_changed")
        active.boundary_reason,active.boundary_discontinuity=reason,discontinuity
        self:log("clock",discontinuity and "error" or "success",{reason=reason,risk=observed.risk,
            start_time=active.last_scan,end_time=now})
        self.capture_error=reason
        self.summary_cache=nil
        -- Neither a clock jump nor an unobserved timezone boundary can be
        -- assigned reliable elapsed seconds. Preserve the trusted prefix and
        -- immediately establish a fresh baseline for the still-open document.
        local sealed,err=self.queue:collect(active.vid,active.window.id,{},active.last_scan,true)
        if not sealed then self.capture_error=err; return false end
        self.active=nil
        if not close and self:enabled() and account(self.store)==active.vid then
            self:start(active.sync,active.record,math.max(now,active.last_scan))
        end
        return not discontinuity
    end
    local spans={}
    local enabled=type(active.stats.isEnabledAndNotFrozen)=="function" and active.stats:isEnabledAndNotFrozen()
    if not enabled then close=true end
    if enabled and account(self.store)==active.vid and active.stats.id_curr_book==active.stats_book then
        spans=Stats.snapshot(active.stats,now,active.sources)
        local ok,persisted=pcall(Stats.persisted,active.stats,active.last_scan,now)
        if ok then for _,row in ipairs(persisted) do spans[#spans+1]=row end
        else self:log("statistics_db","error",{reason="snapshot_failed"}) end
    end
    local result,err=self.queue:collect(active.vid,active.window.id,spans,now,close)
    if not result then self.capture_error=err; self:log("capture","error",{reason=err}); return false end
    self.capture_error=not enabled and "statistics_unavailable" or nil
    active.last_scan=now
    self.summary_cache=nil
    self:log(close and "close" or "capture","success",{book_id=active.book_id,
        seconds=result.seconds,rows=result.rows,source_rows=#spans,start_time=active.window.start_time,end_time=now})
    if close then self.active=nil end
    return true
end
function M:stop(sync,reason,cancel)
    if self.active and (self.active.sync==sync or cancel or not self:enabled()) then
        self:collect(true)
    end
    if cancel or not self:enabled() then
        self.suspended=true
        if self.task then UI:unschedule(self.task); self.task=nil end
        self.worker:cancel(reason)
        local attempt=self.attempt
        if attempt then
            self.queue:finish(attempt.vid,attempt.batch,attempt.id,"unknown",os.time(),"interrupted")
            self:log("cancel","cancelled",{reason="interrupted",batch_id=attempt.id,seconds=attempt.batch.seconds})
        end
        self.attempt=nil
    elseif self:enabled() then self:schedule(3) end
end
function M:wake(host)
    self.host=host or self.host
    self.suspended=false
    self.awaiting_authorization=false
    self.worker_unavailable=nil
    self:schedule(2)
end
function M:yield_to_progress(sync,callback)
    if self.progress_owner then callback(false); return false end
    self.progress_owner=sync
    local ticket={}
    self.progress_ticket=ticket
    local deadline=Log.now()+8
    local function poll()
        if self.progress_ticket~=ticket or self.progress_owner~=sync then callback(false); return end
        if not self.worker:busy() then callback(true); return end
        if Log.now()>=deadline then
            if self.progress_owner==sync then self.progress_owner=nil; self.progress_ticket=nil end
            self:log("progress_fence","waiting",{reason="writer_busy"})
            callback(false)
            return
        end
        UI:scheduleIn(.2,poll)
    end
    poll()
    return true
end
function M:release_progress(sync)
    if self.progress_owner==sync then self.progress_owner=nil; self.progress_ticket=nil; self:schedule(3) end
end
function M:adopt_auth(vid)
    if type(self.store.read_persisted)~="function" or type(self.store.set_deferred)~="function" then return end
    local current=self.store:auth()
    local ok,saved=pcall(self.store.read_persisted,self.store,"auth")
    if ok and type(saved)=="table" and auth_account(saved)==vid and auth_account(current)==vid
        and tostring(saved.login_session_id or "")==tostring(current.login_session_id or "")
        and (tonumber(saved.auth_revision) or 0)>=(tonumber(current.auth_revision) or 0) then
        -- Adopt a worker's successful Native renewal without reloading or
        -- overwriting unrelated deferred preferences/navigation in the parent.
        self.store:set_deferred("auth",saved)
    end
end
function M:send()
    if not self:enabled() or self.suspended or self.progress_owner or self.worker:busy() or self.worker_unavailable
        or not self.host then return false end
    local host=self.host
    local live_sync=host.sync or self.sync
    local daemon=live_sync and live_sync.daemon
    if daemon and (daemon.active or daemon.final_flush_pending) then return false end
    if live_sync and live_sync.reading_time_backend=="web" and live_sync.current then return false end
    if host._reading_end_sync_active or host._reading_end_finalizer_active
        or (self.sync and (self.sync.busy or self.sync.progress_write_fence)) then return false end
    if type(host.is_online)~="function" or not host:is_online() then
        self:log("dispatch","waiting",{reason="offline"})
        return false
    end
    local vid=account(self.store)
    local login_session=tostring((self.store:auth() or {}).login_session_id or "")
    if vid=="" or not self:_recover(vid) then return false end
    local summary=self:summary()
    if summary.pending==0 then return false end
    if summary.blocked then
        self:log("dispatch","waiting",{reason=summary.blocked}); return false
    end
    if os.time()<(tonumber((summary.control or {}).next_send) or 0) then return false end
    if require("miuread.api_transport").new(self.store).selected~="eink" then
        self.awaiting_authorization=true
        return false
    end
    self.channel="eink"
    local now=os.time()
    local batch,err=self.queue:pending(vid,now,function(row)
        return row.start_time+row.duration<=now
    end)
    if not batch then self.capture_error=err; return false end
    if #batch.rows==0 then
        self:schedule(60) -- e.g. timestamps still ahead after a clock correction
        return false
    end
    local id=tostring(os.time()).."-"..tostring(math.random(100000,999999))
    local attempt={id=id,vid=vid,batch=batch}
    self.attempt=attempt
    local started=Log.now()
    self:log("preflight","start",{book_id=batch.book_id,batch_id=id,seconds=batch.seconds,rows=#batch.rows})
    local launched=self.worker:run("offline-reading-time",function()
        local function claim()
            -- Recheck the persisted login immediately before either transport
            -- enters its write. Switching accounts never redirects a batch.
            if account(self.store)~=vid then return false end
            for _,row in ipairs(batch.rows) do
                if row.start_time+row.duration>os.time() then return false end
            end
            if type(self.store.read_persisted)=="function" then
                local saved=self.store:read_persisted("auth")
                if not saved or auth_account(saved)~=vid
                    or tostring(saved.login_session_id or "")~=login_session then return false end
            end
            local claimed=self.queue:claim(vid,batch,id)
            if claimed then self:log("dispatch","start",{batch_id=id,book_id=batch.book_id,
                seconds=batch.seconds,rows=#batch.rows}) end
            return claimed
        end
        local Native=require("miuread.eink_client").new(host.http,self.store)
        local Transport=require("miuread.eink_readtime")
        local phase="reading_time_config"
        Native.before_request=function(stage)
            phase=stage
            self:log("preflight","start",{native_stage=stage,batch_id=id})
        end
        Native.on_readtime_parameters=function(parameters)
            parameters.batch_id=id
            self:log("signature_parameters",parameters.token_source and "success" or "start",parameters)
        end
        Native.on_readtime_server_clock=function(stamp,limit)
            local result,err=self.queue:server_clock(vid,stamp,limit,os.time())
            if not result then error(err,0) end
            if result.observed then
                self:log("server_clock",result.different and "error" or "success",{reason=result.different and "server_time_diff" or nil})
            end
        end
        local ok,prepared=pcall(Transport.prepare,Native,batch.book_id,batch.rows)
        if not ok then
            local Http=require("miuread.http")
            local limited=Http.rate_limit_details(prepared)
            local reason="prepare_failed"
            local message=tostring(prepared)
            if message:find("signature token unavailable",1,true) then reason="signature_token_missing"
            elseif message:find("signature token invalid",1,true)
                or message:find("signature feature invalid",1,true) then reason="signature_token_invalid"
            elseif message:find("config token unavailable",1,true) then reason="config_token_missing"
            elseif message:find("reading_time_position_unavailable",1,true) then reason="position_unavailable"
            elseif Http.is_auth_error(prepared) then reason="authentication"
            elseif Http.is_network_error and Http.is_network_error(prepared) then reason="network" end
            if limited then reason="rate_limited" end
            self:log("preflight",limited and "rate_limited" or "error",{reason=reason,native_stage=phase,
                book_id=batch.book_id,batch_id=id,status=tonumber(tostring(prepared):match("HTTP (%d+)")),
                code=limited and limited.code or tonumber(tostring(prepared):match("error_code=(%-?%d+)")),
                wait_seconds=limited and limited.wait_seconds,elapsed_ms=math.floor((Log.now()-started)*1000)})
            return {state="pending",error=reason,dispatched=false,retry_after=limited and limited.wait_seconds}
        end
        self:log("position_before","success",{book_id=batch.book_id,batch_id=id,
            chapter_uid=prepared.before.chapter_uid,chapter_offset=prepared.before.chapter_offset,
            cloud_seconds=prepared.before.reading_seconds,hours=#prepared.body.books[1].hours,
            risk=prepared.body.books[1].risk,book_version=prepared.body.books[1].bookVersion,
            book_version_source=batch.rows[1].book_version_source or "legacy_unknown"})
        -- Auth may rotate during read-only preflight. Refuse an account switch.
        if account(self.store)~=vid then return {state="pending",error="account_changed",dispatched=false} end
        if type(self.store.read_persisted)=="function" then
            local auth=self.store:read_persisted("auth")
            local fresh=auth and require("miuread.shelf_client").credentials(auth)
            if not fresh or auth_account(auth)~=vid
                or tostring(auth.login_session_id or "")~=login_session
                or fresh.accessToken~=prepared.credentials.accessToken or fresh.deviceId~=prepared.credentials.deviceId then
                return {state="pending",error="credentials_changed",dispatched=false}
            end
        end
        local result=Transport.send(host.http,prepared,claim)
        -- Commit an explicit receipt before the optional diagnostic readback.
        -- A slow verification must not turn accepted seconds into retry debt.
        local saved=self.queue:finish(vid,batch,id,result.state,os.time(),result.error)
        result.saved=saved==true
        if not result.saved then result.state="unknown"; result.error="receipt_persist_failed" end
        if result.state=="confirmed" then
            local checked,value=pcall(Native.request,Native,"GET","/book/getProgress",{bookId=batch.book_id},"reading_time_position_after")
            local after=checked and Transport.position(value)
            if after then
                local unchanged=after.chapter_uid==prepared.before.chapter_uid and after.chapter_offset==prepared.before.chapter_offset
                local delta=after.reading_seconds and prepared.before.reading_seconds
                    and after.reading_seconds-prepared.before.reading_seconds or nil
                self:log("position_after",unchanged and "success" or "error",{book_id=batch.book_id,batch_id=id,
                    chapter_uid=after.chapter_uid,chapter_offset=after.chapter_offset,cloud_seconds=after.reading_seconds,
                    position_unchanged=unchanged,cloud_delta=delta,seconds=batch.seconds})
                if not unchanged then
                    self.queue:block(vid,"cloud_position_changed",batch.book_id)
                    result.blocked="cloud_position_changed"
                end
            else self:log("position_after","waiting",{batch_id=id,reason="verification_unavailable"}) end
        end
        self:log("receipt",result.state,{book_id=batch.book_id,batch_id=id,seconds=batch.seconds,
            rows=#batch.rows,reason=result.error,code=result.code,status=result.status,
            elapsed_ms=math.floor((Log.now()-started)*1000)})
        return result
    end,function(result)
        if self.attempt~=attempt then return end
        self.attempt=nil
        self.summary_cache=nil
        self:adopt_auth(vid)
        local value=result.ok and type(result.value)=="table" and result.value or {state="unknown",error="worker_failed"}
        if not result.ok then self.queue:finish(vid,batch,id,"unknown",os.time(),"worker_failed") end
        if value.error=="receipt_persist_failed" then
            self.queue:finish(vid,batch,id,"unknown",os.time(),"receipt_persist_failed")
        end
        local wait=tonumber(value.retry_after) or 0
        if value.state=="confirmed" and self.active then
            local interval=tonumber((self.store:preferences().sync or {}).interval) or 60
            wait=math.max(wait,math.max(15,math.min(600,interval)))
        end
        local saved=self.queue:defer(vid,os.time(),value.error,wait,value.state)
        if not saved then self.capture_error="ledger_failed" end
        if saved and (self.capture_error=="ledger_full" or self.capture_error=="ledger_failed") then self.capture_error=nil end
        self.summary_cache=nil
        self.awaiting_authorization=value.error=="authentication"
        if value.state=="confirmed" and type(host.on_auth_channel_ok)=="function" then host:on_auth_channel_ok("read_report") end
        if value.state=="confirmed" and self.active and self.active.vid==vid and self.active.book_id==batch.book_id
            and type(host.on_read_report_interval_success)=="function" then
            host:on_read_report_interval_success({elapsed_seconds=batch.seconds})
        end
        self:log("complete",value.state,{batch_id=id,seconds=batch.seconds,
            reason=value.error,elapsed_ms=math.floor((Log.now()-started)*1000)})
        if self.active or (not self.awaiting_authorization and not value.blocked) then
            self:schedule(saved and math.max(10,saved.next_send-os.time()) or 60)
        end
    end,55)
    if not launched then
        self.attempt=nil
        self.worker_unavailable=true
        self.queue:defer(vid,os.time(),"worker_unavailable",60,"pending")
        self.summary_cache=nil
        self:log("worker","waiting",{reason="worker_unavailable"})
    end
    return launched==true
end
function M:summary()
    local vid=account(self.store)
    if vid=="" then return {pending=0,unknown=0,in_flight=0,rows=0} end
    local now=Log.now()
    if self.summary_cache and self.summary_account==vid and now-(self.summary_at or 0)<1 then return self.summary_cache end
    local value=self.queue:summary(vid) or {pending=0,unknown=0,in_flight=0,rows=0,error="ledger_failed"}
    value.capture_error=self.capture_error
    if self.capture_error=="ledger_failed" or self.capture_error=="ledger_full" then value.error=self.capture_error end
    self.summary_cache,self.summary_account,self.summary_at=value,vid,now
    return value
end
function M:unknown()
    local vid=account(self.store)
    local groups,err=self.queue:unknown(vid)
    if groups then for _,group in ipairs(groups) do group.account=vid end end
    return groups,err
end
function M:ignore(group)
    if self.worker:busy() then return nil,"同步任务忙，请稍后再试" end
    if group.account and group.account~=account(self.store) then return nil,"账号已切换，请重新打开记录" end
    local seconds=self.queue:ignore(account(self.store),group)
    self.summary_cache=nil
    if seconds==nil then return nil,"本地记录无法保存" end
    self:log("ignore","success",{seconds=seconds,batch_id=group.id})
    return seconds
end
function M:check_and_resume(host,callback)
    self.host=host or self.host
    local vid=account(self.store)
    local summary=self:summary()
    if self.worker:busy() or self.progress_owner then callback(false,"同步任务忙，请稍后再试"); return false end
    if not self.host or not self.host:is_online() then callback(false,"请先连接网络"); return false end
    if not summary.blocked then callback(true,"阅读时长补传未暂停"); return true end
    local book=summary.blocked_book
    -- v1 stored only the reason. Use its oldest pending book when upgrading.
    if not book then local batch=self.queue:pending(vid,math.huge); book=batch and batch.book_id end
    if not book and self.sync and type(self.sync.record)=="function" then
        local record=self.sync:record()
        book=record and record.book and tostring(record.book.book_id)
    end
    if not book then callback(false,"请先打开需要核对的书籍，再返回这里恢复补传"); return false end
    local session=tostring((self.store:auth() or {}).login_session_id or "")
    local launched=self.worker:run("reading-time-resume",function()
        local Native=require("miuread.eink_client").new(self.host.http,self.store)
        local value=Native:request("GET","/book/getProgress",{bookId=book},"reading_time_resume_check")
        local position=require("miuread.eink_readtime").position(value)
        if not position then return false end
        local auth=type(self.store.read_persisted)=="function" and self.store:read_persisted("auth") or self.store:auth()
        if not auth or auth_account(auth)~=vid or tostring(auth.login_session_id or "")~=session then return false end
        return self.queue:resume(vid,book)==true
    end,function(result)
        self.summary_cache=nil
        local ok=result.ok and result.value==true and account(self.store)==vid
        self:log("resume_check",ok and "success" or "error",{reason=not ok and "verification_failed" or nil,book_id=book})
        if ok then self:wake(self.host) end
        callback(ok,ok and "已核对当前云端位置，恢复后续补传。待确认记录仍保留。" or "核对失败，仍保持暂停。请检查网络和 E-Ink 授权后重试。")
    end,30)
    if not launched then callback(false,"后台任务暂不可用") end
    return launched
end
return M
