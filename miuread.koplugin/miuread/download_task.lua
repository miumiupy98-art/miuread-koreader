local FFIUtil = require("ffi/util")
local Json = require("miuread.json")
local U = require("miuread.util")
local UIManager = require("ui/uimanager")
local Device = require("device")
local logger = require("logger")
local Config = require("miuread.config")
local RuntimePressure = require("miuread.runtime_pressure")
local SuspendWorkLease = require("miuread.suspend_work_lease")
local PseudoLockscreen = require("miuread.pseudo_lockscreen")
local lfs = require("libs/libkoreader-lfs")
local SubprocessHygiene = require("miuread.subprocess_hygiene")

local DownloadTask = {}
DownloadTask.__index = DownloadTask

local function background_lock_mode(mode)
    return mode == "DOWNLOAD_LOCKED" or mode == "PSEUDO_LOCKED"
        or mode == "SCREEN_SAVER_HOLD" or mode == "SUSPEND_PENDING"
end

local function is_android()
    if type(FFIUtil.isAndroid) ~= "function" then return false end
    local ok, value = pcall(FFIUtil.isAndroid)
    return ok and value == true
end

local function lower_worker_priority()
    -- KOReader already lowers subprocess priority. Android workers are more
    -- vulnerable to background scheduling, so do not lower them a second time.
    if is_android() then return false end
    local ok,ffi=pcall(require,"ffi")
    if not ok or not ffi then return false end
    pcall(ffi.cdef,"int setpriority(int which, int who, int prio);")
    local called = pcall(function() ffi.C.setpriority(0,0,10) end)
    return called
end

local function signal_worker(pid,signal)
    pid=tonumber(pid)
    signal=tonumber(signal) or 15
    if not pid or pid<=1 then return false,"invalid_pid" end
    local ok,ffi=pcall(require,"ffi")
    if not ok or not ffi then return false,"ffi_unavailable" end
    pcall(ffi.cdef,"int kill(int pid, int sig);")
    local called,result=pcall(function() return ffi.C.kill(pid,signal) end)
    if not called then return false,tostring(result) end
    return tonumber(result)==0,tonumber(result)==0 and "signaled" or "kill_failed"
end

local function serializable_copy(value, seen)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" or kind == "nil" then return value end
    if kind ~= "table" then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local out = {}
    for k, v in pairs(value) do
        if type(k) == "string" or type(k) == "number" then
            local x = serializable_copy(v, seen)
            if x ~= nil then out[k] = x end
        end
    end
    return out
end

function DownloadTask:new(store)
    local object=setmetatable({
        store = store,
        job = nil,
        hibernated = nil,
        poll_task = nil,
        standby_held = false,
        keep_awake_enabled = true,
        backgrounded = false,
        pause_reasons = {},
        deferred_resume_tasks = {},
        foreground_poll_interval = 0.40,
        background_poll_interval = 1.50,
        paused_poll_interval = 2.00,
        owner_path = store.temp_dir .. "/download-task-owner.json",
        heavy_watch_path = store.temp_dir .. "/download-heavy-watch.json",
        owner_token = tostring(os.time()) .. "-" .. tostring(math.random(100000,999999)),
        last_heavy_watch_at = 0,
        lockscreen_network_ssid = nil,
        lockscreen_network_required = false,
        last_link_guard_at = 0,
        last_connection_assert_at = 0,
        last_connection_assert_reason = nil,
    }, self)
    local raw=U.read_file(object.heavy_watch_path,true)
    if raw then
        local ok,previous=pcall(Json.decode,raw)
        if ok and type(previous)=="table" and tonumber(previous.updated_at or 0)>0 then
            local pid=tonumber(previous.pid)
            local alive=pid and lfs.attributes("/proc/"..tostring(pid),"mode")=="directory"
            if previous.hibernated==true then
                logger.info("[MiuRead][HeavyWatch] previous hibernated snapshot",
                    "stage=",tostring(previous.stage or "unknown"),
                    "reason=",tostring(previous.reason or "unknown"))
            elseif not alive then
                logger.warn("[MiuRead][CrashRecovery] previous heavy worker disappeared",
                    "owner=",tostring(previous.owner or "unknown"),
                    "stage=",tostring(previous.stage or "unknown"),
                    "memory_kb=",tostring(previous.memory_kb or "unknown"),
                    "pid=",tostring(previous.pid or ""))
            end
        end
    end
    return object
end

function DownloadTask:set_backgrounded(value)
    self.backgrounded = value == true
    if self.hibernated then self.hibernated.backgrounded=self.backgrounded end
    -- beta.9 never keeps the normal Home surface awake just because a download
    -- exists. The lock is acquired only after the physical Suspend lifecycle
    -- has entered DOWNLOAD_LOCKED; this lets Home auto-sleep normally and then
    -- continue the same worker behind the lock screen.
    if background_lock_mode(self.power_mode) and not self:is_paused() then
        self:_hold_awake()
    else
        self:_release_awake()
    end
end

function DownloadTask:_control_descriptor()
    if self.job then return self.job end
    if self.hibernated then return self:descriptor() end
    -- FileManager and ReaderUI own different plugin instances. Read the active
    -- task descriptor from the persisted download state so either instance can
    -- pause or stop the same child process during a foreground recovery.
    local ok,state=pcall(self.store.download_state,self.store)
    local task=ok and type(state)=="table" and state.task or nil
    return type(task)=="table" and task or nil
end

function DownloadTask:_control_pause_path()
    local task=self:_control_descriptor()
    local path=type(task)=="table" and tostring(task.pause_path or "") or ""
    return path~="" and path or nil
end

function DownloadTask:_control_network_path()
    local task=self:_control_descriptor()
    local path=type(task)=="table" and tostring(task.network_path or "") or ""
    return path~="" and path or nil
end

function DownloadTask:set_network_mode(mode)
    mode=tostring(mode or "auto")=="ipv4" and "ipv4" or "auto"
    local path=self:_control_network_path()
    if not path then return false,"当前下载任务不支持网络模式切换" end
    local wrote,err=U.atomic_write(path,mode,true)
    if not wrote then return false,tostring(err or "无法写入网络模式") end
    if self.job then
        self.job.network_mode=mode
        self.job.restart_options=self.job.restart_options or {}
        self.job.restart_options.network_mode=mode
        self.job.restart_options.network_suggestion_silent=nil
    end
    logger.info("[MiuRead][DownloadTask] network mode updated",
        "mode=",mode,"shared=",tostring(self.job==nil))
    return true
end

function DownloadTask:dismiss_network_suggestion()
    local path=self:_control_network_path()
    if not path then return false end
    local wrote=U.atomic_write(path,"auto_silent",true)==true
    if wrote and self.job then
        self.job.restart_options=self.job.restart_options or {}
        self.job.restart_options.network_mode="auto"
        self.job.restart_options.network_suggestion_silent=true
    end
    if wrote then logger.info("[MiuRead][DownloadTask] IPv4 suggestion dismissed for current task") end
    return wrote
end

function DownloadTask:_marker_reasons(path)
    local reasons={}
    path=path or self:_control_pause_path()
    if not path then return reasons end
    local raw=U.read_file(path,true)
    if not raw then return reasons end
    local ok,value=pcall(Json.decode,raw)
    if not ok or type(value)~="table" then return reasons end
    for _,reason in ipairs(type(value.reasons)=="table" and value.reasons or {}) do
        reason=tostring(reason or "")
        if reason~="" then reasons[reason]=true end
    end
    return reasons
end

function DownloadTask:_merged_pause_reasons(path)
    path=path or self:_control_pause_path()
    -- While a task descriptor exists, the marker is the single source of
    -- truth shared by FileManager and ReaderUI. Never merge stale per-instance
    -- reasons back into it after another instance has resumed the worker.
    if path then return self:_marker_reasons(path) end
    local reasons={}
    for reason,value in pairs(self.pause_reasons or {}) do
        if value==true then reasons[reason]=true end
    end
    return reasons
end

function DownloadTask:is_paused()
    return next(self:_merged_pause_reasons())~=nil
end

function DownloadTask:_write_pause_marker(path,reasons)
    path=path or self:_control_pause_path()
    if not path then return false end
    reasons=reasons or self:_merged_pause_reasons(path)
    self.pause_reasons=reasons
    if next(reasons)==nil then
        os.remove(path)
        return true
    end
    local ordered={}
    for reason in pairs(reasons) do ordered[#ordered+1]=reason end
    table.sort(ordered)
    return U.atomic_write(path,Json.encode({
        paused=true,reasons=ordered,updated_at=os.time(),
    }),true)==true
end


local TRANSIENT_PAUSE_REASONS = {
    home_interaction=true, reader_interaction=true, page_transition=true,
    thought_popup=true, transient_ui=true, heavy_resource=true,
    progress_precision=true,
    -- beta.12 no longer pauses downloads for reader finalization. Treat any
    -- marker left by beta.9-11 as transient migration debt and clear it at the
    -- next lifecycle normalization instead of stranding the download.
    reader_finalizer=true,
}

local AUTO_EXPIRE_PAUSE_REASONS = {
    home_interaction=true, reader_interaction=true, page_transition=true,
}

function DownloadTask:_recover_stale_transient_pauses()
    local path=self:_control_pause_path()
    if not path then return false end
    local raw=U.read_file(path,true)
    if not raw then return false end
    local ok,value=pcall(Json.decode,raw)
    if not ok or type(value)~="table" then return false end
    local updated=tonumber(value.updated_at) or 0
    if updated<=0 then return false end
    local age=math.max(0,os.time()-updated)
    local interaction_timeout=math.max(10,tonumber(Config.DOWNLOAD_INTERACTION_STALE_SECONDS) or 12)
    local transition_timeout=math.max(30,tonumber(Config.DOWNLOAD_TRANSITION_STALE_SECONDS) or 60)

    local remaining={}
    local recovered={}
    for _,reason in ipairs(type(value.reasons)=="table" and value.reasons or {}) do
        reason=tostring(reason or "")
        if reason~="" then
            local timeout=reason=="page_transition" and transition_timeout or interaction_timeout
            if AUTO_EXPIRE_PAUSE_REASONS[reason]==true and age>=timeout then
                recovered[#recovered+1]=reason
            else
                remaining[reason]=true
            end
        end
    end
    if #recovered==0 then return false end

    if next(remaining)==nil then
        os.remove(path)
    else
        local ordered={}
        for reason in pairs(remaining) do ordered[#ordered+1]=reason end
        table.sort(ordered)
        U.atomic_write(path,Json.encode({paused=true,reasons=ordered,updated_at=os.time()}),true)
    end
    self.pause_reasons=remaining
    logger.warn("[MiuRead][DownloadTask] stale transient pause recovered",
        "reasons=",table.concat(recovered,","),"age=",tostring(age),
        "still_paused=",tostring(next(remaining)~=nil))
    if next(remaining)==nil and background_lock_mode(self.power_mode) then self:_hold_awake() end
    return true
end

function DownloadTask:_cancel_deferred_resume(reason)
    reason=tostring(reason or "")
    local task=self.deferred_resume_tasks and self.deferred_resume_tasks[reason]
    if task then
        UIManager:unschedule(task)
        self.deferred_resume_tasks[reason]=nil
    end
end

function DownloadTask:pause(reason)
    reason=tostring(reason or "manual")
    self:_cancel_deferred_resume(reason)
    local path=self:_control_pause_path()
    local reasons=self:_merged_pause_reasons(path)
    reasons[reason]=true
    local wrote=self:_write_pause_marker(path,reasons)
    self:_release_awake()
    logger.info("[MiuRead][DownloadTask] paused","reason=",reason,
        "marker=",tostring(wrote),"shared=",tostring(self.job==nil))
    if self.job then self:_schedule() end
    return wrote
end

function DownloadTask:_resume_now(reason)
    local path=self:_control_pause_path()
    local reasons=self:_merged_pause_reasons(path)
    if reason==nil then
        reasons={}
    else
        reasons[tostring(reason)]=nil
    end
    local still_paused=next(reasons)~=nil
    self:_write_pause_marker(path,reasons)
    if not still_paused and background_lock_mode(self.power_mode) then self:_hold_awake() end
    logger.info("[MiuRead][DownloadTask] resume requested",
        "reason=",tostring(reason or "all"),"still_paused=",tostring(still_paused),
        "shared=",tostring(self.job==nil))
    if self.job then self:_schedule() end
    return not still_paused
end

function DownloadTask:resume(reason)
    local key=reason and tostring(reason) or nil
    if key and TRANSIENT_PAUSE_REASONS and TRANSIENT_PAUSE_REASONS[key] then
        self:_cancel_deferred_resume(key)
        local delay=math.max(.5,tonumber(Config.DOWNLOAD_INTERACTION_RESUME_DELAY) or 2.5)
        local task
        task=function()
            if self.deferred_resume_tasks[key]~=task then return end
            self.deferred_resume_tasks[key]=nil
            self:_resume_now(key)
        end
        self.deferred_resume_tasks[key]=task
        UIManager:scheduleIn(delay,task)
        logger.info("[MiuRead][DownloadTask] resume debounced",
            "reason=",key,"delay=",tostring(delay))
        return false
    end
    return self:_resume_now(reason)
end

function DownloadTask:_replace_transient_pause_reasons(add_suspend)
    local path=self:_control_pause_path()
    local reasons=self:_merged_pause_reasons(path)
    for reason in pairs(TRANSIENT_PAUSE_REASONS) do reasons[reason]=nil end
    if add_suspend==true then reasons.suspend=true else reasons.suspend=nil end
    local still_paused=next(reasons)~=nil
    self:_write_pause_marker(path,reasons)
    if still_paused then self:_release_awake()
    elseif background_lock_mode(self.power_mode) then self:_hold_awake() end
    logger.info("[MiuRead][DownloadTask] lifecycle pause reasons normalized",
        "suspend=",tostring(add_suspend==true),"still_paused=",tostring(still_paused))
    if self.job then self:_schedule() end
    return not still_paused
end

function DownloadTask:on_suspend(mode, generation)
    self.power_mode = tostring(mode or "REAL_SUSPEND")
    self.power_generation = tonumber(generation or 0) or 0
    if background_lock_mode(self.power_mode) and PseudoLockscreen.background_supported() ~= true then
        logger.warn("[MiuRead][DownloadTask] unsupported suspend platform downgraded",
            "requested=", self.power_mode, "to=REAL_SUSPEND")
        self.power_mode = "REAL_SUSPEND"
    end
    if background_lock_mode(self.power_mode) then
        -- Power-state ownership is not proof that a download exists. Reader
        -- finalization may hold the same Kindle screen-saver session, so gate
        -- the download lane with the persisted/shared task descriptor first.
        local can_continue,continue_reason=self:can_continue_locked()
        if can_continue~=true then
            local requested=self.power_mode
            self.power_mode="REAL_SUSPEND"
            self:_clear_lockscreen_network("no_download:"..tostring(continue_reason or "unknown"))
            self:_release_awake()
            self:_replace_transient_pause_reasons(true)
            logger.info("[MiuRead][DownloadTask] background suspend denied",
                "requested=",requested,"generation=",tostring(self.power_generation),
                "reason=",tostring(continue_reason or "unknown"))
            return false
        end

        -- The lease may already have been armed at the beginning of onSuspend.
        -- Keep it across the lock-screen transition and immediately assert the
        -- platform network policy before the transfer continues.
        local resumed = self:_replace_transient_pause_reasons(false)
        if resumed then
            self:_hold_awake()
            self:_capture_lockscreen_network("download_locked")
            self:_guard_lockscreen_network(self:_control_descriptor(),os.time(),
                (tonumber(self.last_connection_assert_at) or 0)<=0)
        end
        logger.info("[MiuRead][DownloadTask] power suspend mode",
            "mode=", self.power_mode, "generation=", tostring(self.power_generation),
            "continue=", tostring(resumed))
        return resumed
    end
    if self.power_mode == "BACKGROUND_LOCKED" then
        -- Reader finalization temporarily owns the shared suspend lease. Keep
        -- the download checkpoint parked; Plugin:onSuspend hands it over to
        -- DOWNLOAD_LOCKED only after reading-time/progress writes are finished.
        self:_clear_lockscreen_network("reader_finalizer")
        self:_release_awake()
        logger.info("[MiuRead][DownloadTask] power suspend mode",
            "mode=", self.power_mode, "generation=", tostring(self.power_generation),
            "continue=false reader_finalizer=true")
        return false
    end

    -- A real suspend is a hard pause boundary for downloads. The child process
    -- and chapter checkpoints remain intact and resume after wake.
    self:_clear_lockscreen_network("real_suspend")
    local paused = self:_replace_transient_pause_reasons(true)
    logger.info("[MiuRead][DownloadTask] power suspend mode",
        "mode=", self.power_mode, "generation=", tostring(self.power_generation),
        "continue=false")
    return paused
end

function DownloadTask:on_resume(generation)
    self.power_mode = "RESUMING"
    self.power_generation = tonumber(generation or 0) or 0
    -- Wake is also a cleanup boundary: clear stale interaction/transition
    -- reasons together with suspend, but never override an explicit manual or
    -- recovery pause.
    return self:_replace_transient_pause_reasons(false)
end

function DownloadTask:on_user_resume_begin(generation)
    -- The user's power-key wake always wins over a lock-screen download. Drop
    -- MiuRead's preventStandby claim before any resume bookkeeping or network
    -- recovery runs. A healthy worker may reacquire it later, after the visible
    -- surface has already returned.
    self.power_mode = "RESUMING"
    self.power_generation = tonumber(generation or 0) or 0
    if self.job then self.job.last_keepalive=nil end
    local held=self.standby_held==true
    self:_clear_lockscreen_network("user_resume")
    self:_release_awake()
    logger.info("[MiuRead][DownloadTask] user resume priority",
        "wake_lock_released=",tostring(held),"pid=",tostring(self.job and self.job.pid or ""))
    return true
end

function DownloadTask:stop_for_foreground(reason)
    reason=tostring(reason or "foreground_recovery")
    local task=self:_control_descriptor()
    if type(task)~="table" then return false end
    self:pause(reason)
    local cancel_path=tostring(task.cancel_path or "")
    if cancel_path=="" then return false end
    local wrote=U.atomic_write(cancel_path,"1",true)==true
    if self.job then self.job.cancel_requested_at=os.time() end
    logger.warn("[MiuRead][DownloadTask] stopped for foreground recovery",
        "reason=",reason,"pid=",tostring(task.pid or ""),"marker=",tostring(wrote))
    if self.job then self:_schedule() end
    return wrote
end

function DownloadTask:last_state()
    return (self.job and self.job.last_progress_state) or (self.hibernated and self.hibernated.last_state) or nil
end

local function read_json(path)
    local raw=U.read_file(path,true)
    if not raw then return nil end
    local ok,value=pcall(Json.decode,raw)
    if ok and type(value)=="table" then return value end
end

local function file_exists(path)
    return tostring(path or "")~="" and lfs.attributes(path)~=nil
end

local function file_mtime(path)
    local attr=lfs.attributes(path)
    return attr and tonumber(attr.modification or attr.change) or nil
end

local function process_exists(pid)
    pid=tonumber(pid)
    if not pid or pid<=1 then return false end
    local proc="/proc/"..tostring(pid)
    if lfs.attributes("/proc","mode")~="directory" then return nil end
    if lfs.attributes(proc,"mode")~="directory" then return false end
    local status,status_error=U.read_file(proc.."/status",true)
    if not status then
        logger.warn("[MiuRead][DownloadTask] process status unavailable",
            "pid=",tostring(pid),"error=",tostring(status_error))
        return nil
    end
    local state=status:match("[\r\n]State:%s*([A-Z])") or status:match("^State:%s*([A-Z])")
    if state=="Z" or state=="X" then return false end
    return true
end

function DownloadTask:can_continue_locked()
    if PseudoLockscreen.background_supported() ~= true then
        return false, "unsupported_suspend_platform"
    end
    if self.hibernated then return false,"hibernated" end
    if self.job and self.job.fail_open_done==true then return false,"fail_open" end
    if self.store:preferences().download_keep_awake == false then return false, "disabled" end
    local task = self:_control_descriptor()
    if type(task) ~= "table" then return false, "no_task" end
    local pid = tonumber(task.pid)
    if pid and process_exists(pid) == false then return false, "worker_stopped" end

    -- UI-only pauses are intentionally ignored here: entering the lock screen
    -- is the boundary that clears them. Explicit/manual/auth/recovery pauses
    -- remain authoritative and must never be bypassed just to keep downloading.
    local reasons = self:_merged_pause_reasons(task.pause_path)
    for reason in pairs(reasons) do
        if reason ~= "suspend" and TRANSIENT_PAUSE_REASONS[reason] ~= true then
            return false, "paused:" .. tostring(reason)
        end
    end

    local battery_ok,battery=self:_battery_allows_locked()
    if not battery_ok then return false,"low_battery:"..tostring(battery or "unknown") end

    local progress = self.job and self.job.last_progress_state or nil
    if type(progress) ~= "table" then
        local path = tostring(task.progress_path or "")
        if path ~= "" then progress = read_json(path) end
    end
    progress = type(progress) == "table" and progress or {}
    local stage = tostring(progress.stage or "")
    if stage == "done" or stage == "error" or stage == "cancelled" then
        return false, stage
    end

    local now = os.time()
    local network_waiting=stage=="waiting_network" or progress.waiting_network==true
    local network_wait_started=tonumber(progress.network_wait_started_at)
        or tonumber(self.job and self.job.waiting_started_at)
    local network_lock_max=math.max(45,tonumber(Config.DOWNLOAD_NETWORK_LOCK_MAX_SECONDS) or 90)
    if network_waiting and network_wait_started and now-network_wait_started>=network_lock_max then
        return false,"network_wait_timeout"
    end
    local stall = math.max(120, tonumber(Config.DOWNLOAD_BACKGROUND_STALL_SLEEP_SECONDS) or 300)
    local updated = tonumber(progress.updated_at)
        or tonumber(self.job and self.job.last_effective_progress_at)
        or tonumber(task.started_at) or now
    if now - updated >= stall then return false, "stalled" end
    return true, "active"
end

local function usable_recovery_result(result)
    if type(result)~="table" or result.ok~=true or type(result.value)~="table" then return false end
    local record=result.value
    local path=record.pending_install==true and record.pending_file or record.file
    if not path or not file_exists(path) then return false end
    local size=U.file_size(path)
    return size==nil or size>0
end

local function diagnostic_append(path, lines)
    if not path or path=="" then return false end
    local parent=path:match("^(.*)/[^/]+$")
    if parent then U.mkdir(parent) end
    local file=io.open(path,"ab")
    if not file then return false end
    local text=type(lines)=="table" and table.concat(lines,"\n") or tostring(lines or "")
    local written=file:write(text,"\n")
    file:flush()
    file:close()
    return written~=nil
end

local function prune_diagnostics(directory, keep)
    keep=math.max(1,tonumber(keep) or 5)
    local rows={}
    if lfs.attributes(directory,"mode")~="directory" then return end
    for name in lfs.dir(directory) do
        if name:match("^download%-diagnostic%-.+%.txt$") then
            local path=directory.."/"..name
            rows[#rows+1]={path=path,mtime=file_mtime(path) or 0}
        end
    end
    table.sort(rows,function(a,b) return a.mtime>b.mtime end)
    for index=keep+1,#rows do os.remove(rows[index].path) end
end

function DownloadTask:_claim(pid)
    return U.atomic_write(self.owner_path,Json.encode({
        token=self.owner_token,pid=tonumber(pid),updated_at=os.time(),
    }),true)
end

function DownloadTask:_owns_job()
    local owner=read_json(self.owner_path)
    return owner and tostring(owner.token or "")==tostring(self.owner_token)
        and tonumber(owner.pid or 0)==tonumber(self.job and self.job.pid or 0)
end

function DownloadTask:descriptor()
    local job=self.job
    if not job then
        local h=self.hibernated
        if not h then return nil end
        return {hibernated=true,hibernate_reason=h.reason,stage=h.stage,started_at=h.started_at,
            restart_count=tonumber(h.restart_count) or 0,stall_restart_count=tonumber(h.stall_restart_count) or 0}
    end
    return {
        pid=job.pid,progress_path=job.progress_path,result_path=job.result_path,
        recovery_path=job.recovery_path,diagnostic_path=job.diagnostic_path,
        cancel_path=job.cancel_path,pause_path=job.pause_path,pause_ack_path=job.pause_ack_path,
        hibernate_path=job.hibernate_path,network_path=job.network_path,
        worker_settings_path=job.worker_settings_path,
        started_at=job.started_at,owner_token=self.owner_token,task_token=job.task_token,
        restart_count=tonumber(job.restart_count) or 0,stall_restart_count=tonumber(job.stall_restart_count) or 0,
    }
end


local function device_is(kind)
    local fn=Device and Device["is"..kind]
    if type(fn)~="function" then return false end
    local ok,value=pcall(fn,Device)
    return ok and value==true
end

function DownloadTask:_current_network_ssid(manager)
    if not manager or type(manager.getCurrentNetwork)~="function" then return nil end
    local ok,current=pcall(manager.getCurrentNetwork,manager)
    if not ok or type(current)~="table" then return nil end
    local ssid=tostring(current.ssid or current.name or ""):match("^%s*(.-)%s*$")
    return ssid~="" and ssid or nil
end

function DownloadTask:_capture_lockscreen_network(reason)
    local link=self:_network_link_state()
    if not link or not link.manager then return false,"manager_unavailable" end
    local ssid=self:_current_network_ssid(link.manager)
    if ssid then self.lockscreen_network_ssid=ssid end
    self.lockscreen_network_required=(link.connected==true or self.lockscreen_network_ssid~=nil)
    logger.info("[MiuRead][DownloadNetworkLease] captured",
        "platform=",device_is("Kindle") and "kindle" or (device_is("Kobo") and "kobo" or "generic"),
        "reason=",tostring(reason or "unknown"),
        "wifi_on=",tostring(link.wifi_on),"connected=",tostring(link.connected),
        "ssid=",tostring(self.lockscreen_network_ssid or ""))
    return self.lockscreen_network_required,link
end

function DownloadTask:_assert_kindle_connection(link,reason,force)
    if not device_is("Kindle") then return false,"not_kindle" end
    if not link or not link.manager then return false,"manager_unavailable" end
    local ssid=self.lockscreen_network_ssid or self:_current_network_ssid(link.manager)
    if ssid then self.lockscreen_network_ssid=ssid end
    if not ssid then return false,"ssid_unavailable" end

    local now=os.time()
    local connected=link.connected==true
    local interval=connected
        and math.max(15,tonumber(Config.DOWNLOAD_KINDLE_ENSURE_REFRESH_SECONDS) or 30)
        or math.max(3,tonumber(Config.DOWNLOAD_KINDLE_ENSURE_RETRY_SECONDS) or 5)
    if force~=true and now-(tonumber(self.last_connection_assert_at) or 0)<interval then
        return false,"cooldown"
    end

    -- KOReader's Kindle NetworkMgr maps authenticateNetwork() directly to
    -- com.lab126.cmd ensureConnection. Keep that platform detail in KOReader
    -- instead of embedding LIPC calls in MiuRead.
    if type(link.manager.authenticateNetwork)~="function" then
        return false,"authenticate_unavailable"
    end
    local ok,value,err=pcall(link.manager.authenticateNetwork,link.manager,{ssid=ssid})
    local requested=ok and value~=false
    if requested then
        self.last_connection_assert_at=now
        self.last_connection_assert_reason=tostring(reason or "guard")
    end
    logger.info("[MiuRead][DownloadNetworkLease] kindle ensureConnection",
        "reason=",tostring(reason or "guard"),"ssid=",ssid,
        "connected=",tostring(link.connected),"requested=",tostring(requested),
        "error=",tostring((not ok and value) or err or ""))
    return requested,requested and "ensureConnection" or "ensure_failed"
end

function DownloadTask:_guard_lockscreen_network(job,now,force)
    if not background_lock_mode(self.power_mode) then
        return false,"not_locked"
    end
    -- Final hard boundary before touching KOReader's network manager. A stale
    -- SCREEN_SAVER_HOLD must never be able to restore Wi-Fi by itself.
    local can_continue,continue_reason=self:can_continue_locked()
    if can_continue~=true then
        self.power_mode="REAL_SUSPEND"
        self:_clear_lockscreen_network("guard_no_download:"..tostring(continue_reason or "unknown"))
        self:_release_awake()
        return false,"no_download:"..tostring(continue_reason or "unknown")
    end
    job=job or self:_control_descriptor()
    if type(job)~="table" then
        self:_clear_lockscreen_network("guard_no_descriptor")
        return false,"no_download:descriptor"
    end
    now=tonumber(now) or os.time()
    local gap=math.max(3,tonumber(Config.DOWNLOAD_LOCKSCREEN_LINK_GUARD_SECONDS) or 5)
    if force~=true and now-(tonumber(self.last_link_guard_at) or 0)<gap then
        return false,"guard_cooldown"
    end
    self.last_link_guard_at=now

    local link=self:_network_link_state()
    if not link or not link.manager then return false,"manager_unavailable" end
    if not self.lockscreen_network_required then
        local ssid=self:_current_network_ssid(link.manager)
        if ssid then self.lockscreen_network_ssid=ssid end
        self.lockscreen_network_required=(link.connected==true or self.lockscreen_network_ssid~=nil)
    end

    if device_is("Kindle") then
        if link.wifi_on==false and type(link.manager.restoreWifiAsync)=="function" then
            pcall(link.manager.restoreWifiAsync,link.manager)
        end
        -- Assert once on lock entry, then refresh the same connection intent at
        -- a low cadence while healthy. If the address disappears, retry faster
        -- without waiting for chapter HTTP failures.
        return self:_assert_kindle_connection(link,
            force==true and "lock_entry" or (link.connected==true and "lease_refresh" or "link_lost"),
            force)
    end

    -- Kobo has no Kindle-style ensureConnection. While preventStandby keeps the
    -- device out of deep sleep, leave a healthy association untouched. Only
    -- invoke KOReader's own restore path after a real link loss.
    if device_is("Kobo") then
        if self.lockscreen_network_required and link.connected~=true
            and type(link.manager.restoreWifiAsync)=="function" then
            local ok=pcall(link.manager.restoreWifiAsync,link.manager)
            logger.warn("[MiuRead][DownloadNetworkLease] kobo restore requested",
                "wifi_on=",tostring(link.wifi_on),"connected=",tostring(link.connected),
                "requested=",tostring(ok))
            return ok,ok and "restoreWifiAsync" or "restore_failed"
        end
        return false,"link_up"
    end

    return false,link.connected==true and "link_up" or "generic"
end

function DownloadTask:_clear_lockscreen_network(reason)
    if self.lockscreen_network_ssid or self.lockscreen_network_required then
        logger.info("[MiuRead][DownloadNetworkLease] cleared",
            "reason=",tostring(reason or "unknown"),
            "ssid=",tostring(self.lockscreen_network_ssid or ""))
    end
    self.lockscreen_network_ssid=nil
    self.lockscreen_network_required=false
    self.last_link_guard_at=0
    self.last_connection_assert_at=0
    self.last_connection_assert_reason=nil
end

function DownloadTask:prepare_suspend_lock()
    if PseudoLockscreen.background_supported() ~= true then
        return false, "unsupported_suspend_platform"
    end
    if not self.keep_awake_enabled then return false,"disabled" end
    local can_continue,continue_reason=self:can_continue_locked()
    if can_continue~=true then
        self.power_mode="REAL_SUSPEND"
        self:_clear_lockscreen_network("prepare_no_download:"..tostring(continue_reason or "unknown"))
        self:_release_awake()
        return false,tostring(continue_reason or "no_download")
    end
    self.power_mode="SUSPEND_PENDING"

    local pseudo_owned=PseudoLockscreen.active()==true
    local ok=false
    if pseudo_owned then
        self:_release_awake()
        ok=true
    elseif device_is("Kindle") then
        -- Kindle workers are never allowed to create a power owner. The
        -- screen-saver hold controller must already exist before a locked
        -- download can continue.
        self:_release_awake()
        ok=false
    else
        -- Kobo keeps its existing lease behavior.
        ok=SuspendWorkLease.acquire("download")==true
        self.standby_held=ok
    end
    self:_capture_lockscreen_network("suspend_pending")
    self:_guard_lockscreen_network(self.job,os.time(),true)
    logger.info("[MiuRead][DownloadTask] suspend lock prepared",
        "owner=",pseudo_owned and "background_controller" or (device_is("Kindle") and "none" or "download"),
        "lease=",tostring(ok),"ssid=",tostring(self.lockscreen_network_ssid or ""))
    return ok,ok and "prepared" or "lease_failed"
end

function DownloadTask:_lockscreen_keepalive_allowed()
    return self.keep_awake_enabled == true
        and background_lock_mode(self.power_mode)
end

function DownloadTask:_reset_device_timeout()
    if not self:_lockscreen_keepalive_allowed() then return false end
    if device_is("Kindle") then
        -- Kindle workers do not touch T1 or powerd. A true result only
        -- means the screen-saver hold session is still owned by the controller.
        return PseudoLockscreen.active() == true
    end
    local powerd = Device and Device.powerd
    if powerd and type(powerd.resetT1Timeout) == "function" then
        local ok, err = pcall(powerd.resetT1Timeout, powerd)
        if not ok then logger.warn("[MiuRead][DownloadTask] device timeout reset failed", tostring(err)) end
        return ok
    end
    return false
end

function DownloadTask:_battery_allows_locked()
    local powerd = Device and Device.powerd
    if not powerd then return true, nil end
    if type(powerd.isCharging) == "function" then
        local ok, charging = pcall(powerd.isCharging, powerd)
        if ok and charging == true then return true, nil end
    end
    if type(powerd.getCapacity) ~= "function" then return true, nil end
    local ok, capacity = pcall(powerd.getCapacity, powerd)
    capacity = ok and tonumber(capacity) or nil
    if not capacity then return true, nil end
    local minimum = math.max(1, tonumber(Config.DOWNLOAD_LOCKSCREEN_MIN_BATTERY_PERCENT) or 10)
    return capacity > minimum, capacity
end

function DownloadTask:_hold_awake()
    if PseudoLockscreen.background_supported() ~= true then
        self:_release_awake()
        return false
    end
    if not self:_lockscreen_keepalive_allowed() then
        self:_release_awake()
        return false
    end
    if device_is("Kindle") and PseudoLockscreen.active()~=true then
        self:_release_awake()
        return false
    end
    if PseudoLockscreen.active()==true then
        local stale=self.standby_held or SuspendWorkLease.has("download")
        self.standby_held=false
        SuspendWorkLease.release("download")
        local alive=self:_reset_device_timeout()
        if stale then
            logger.info("[MiuRead][DownloadTask] worker power claim released; controller owns background")
        end
        return alive==true or (not device_is("Kindle") and SuspendWorkLease.has("pseudo_lockscreen"))
    end
    if self.standby_held and SuspendWorkLease.has("download") then return true end
    local ok = SuspendWorkLease.acquire("download")
    if ok then
        self.standby_held = true
        local reset = self:_reset_device_timeout()
        logger.info("[MiuRead][DownloadTask] standby lease acquired", "t1_reset=", tostring(reset))
        return true
    end
    self.standby_held = false
    logger.warn("[MiuRead][DownloadTask] standby lease failed")
    return false
end

function DownloadTask:_release_awake()
    local held = self.standby_held or SuspendWorkLease.has("download")
    self.standby_held = false
    SuspendWorkLease.release("download")
    if held then logger.info("[MiuRead][DownloadTask] standby lease released") end
end

function DownloadTask:_fail_open_locked_download(job,reason)
    if not job or self.job~=job or job.fail_open_done==true then return false end
    if not background_lock_mode(self.power_mode) and not PseudoLockscreen.active() then return false end
    reason=tostring(reason or "unhealthy_worker")
    job.fail_open_done=true
    job.fail_open_at=os.time()
    -- Never reacquire preventStandby after this boundary. The worker may still
    -- need a moment to die, but the device is no longer allowed to depend on it
    -- for power-state correctness.
    self.power_mode="FAIL_OPEN"
    self:_clear_lockscreen_network("fail_open:"..reason)
    self:_release_awake()
    -- Mark only the download task inactive. The background-power controller
    -- decides whether any other task still requires keepalive and performs the
    -- eventual native suspend through KOReader, never through this worker.
    PseudoLockscreen.set_download_active(false)
    diagnostic_append(job.diagnostic_path,{
        "time="..tostring(os.date("%Y-%m-%d %H:%M:%S")),
        "event=lockscreen_fail_open",
        "pid="..tostring(job.pid or ""),
        "stage="..tostring((job.last_progress_state or {}).stage or "unknown"),
        "reason="..reason,
    })
    logger.warn("[MiuRead][DownloadTask][FailOpen] lock-screen download released",
        "pid=",tostring(job.pid or ""),"stage=",tostring((job.last_progress_state or {}).stage or "unknown"),
        "reason=",reason)
    return true
end

function DownloadTask:_network_link_state()
    local ok,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok or not NetworkMgr then return nil end
    if type(NetworkMgr.queryNetworkState)=="function" then
        pcall(NetworkMgr.queryNetworkState,NetworkMgr)
    end
    local wifi_on,connected=nil,nil
    if type(NetworkMgr.isWifiOn)=="function" then
        local good,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
        if good then wifi_on=value==true end
    end
    if type(NetworkMgr.isConnected)=="function" then
        local good,value=pcall(NetworkMgr.isConnected,NetworkMgr)
        if good then connected=value==true end
    end
    return {manager=NetworkMgr,wifi_on=wifi_on,connected=connected}
end

function DownloadTask:_maybe_restore_network(job,now,wait_age)
    if self.power_mode == "REAL_SUSPEND" then return false,"real_suspend" end
    if not job or wait_age<=0 then return false,"not_waiting" end
    local initial=math.max(5,tonumber(Config.DOWNLOAD_NETWORK_GUARD_POLL_SECONDS) or 10)
    if wait_age<initial then return false,"grace" end
    local cooldown=math.max(10,tonumber(Config.DOWNLOAD_NETWORK_RESTORE_COOLDOWN_SECONDS) or 25)
    local last=tonumber(job.last_network_restore_at) or 0
    if now-last<cooldown then return false,"cooldown" end
    local maximum=math.max(0,tonumber(Config.DOWNLOAD_NETWORK_RESTORE_MAX_ATTEMPTS) or 0)
    local attempts=tonumber(job.network_restore_attempts) or 0
    if maximum>0 and attempts>=maximum then return false,"attempt_limit" end

    local link=self:_network_link_state()
    if not link or not link.manager then return false,"manager_unavailable" end
    -- If the Kindle still has an address, this is a WAN/server failure rather
    -- than a local Wi-Fi drop. Do not churn a healthy association.
    if link.wifi_on==true and link.connected==true then return false,"link_up" end
    if link.manager.pending_connection==true then return false,"connection_pending" end

    job.last_network_restore_at=now
    job.network_restore_attempts=attempts+1
    local restored=false
    local method="none"
    if type(link.manager.restoreWifiAsync)=="function" then
        local called=pcall(link.manager.restoreWifiAsync,link.manager)
        restored=called==true
        method="restoreWifiAsync"
    elseif type(link.manager.enableWifi)=="function" then
        local called,value=pcall(link.manager.enableWifi,link.manager,nil,false)
        restored=called==true and value~=false
        method="enableWifi"
    elseif type(link.manager.turnOnWifi)=="function" then
        local called,value=pcall(link.manager.turnOnWifi,link.manager,nil,false)
        restored=called==true and value~=false
        method="turnOnWifi"
    end
    logger.warn("[MiuRead][DownloadTask] network link recovery requested",
        "attempt=",tostring(job.network_restore_attempts),
        "method=",method,"wifi_on=",tostring(link.wifi_on),
        "connected=",tostring(link.connected),"wait=",tostring(wait_age),
        "requested=",tostring(restored))
    return restored,method
end

function DownloadTask:available()
    return type(FFIUtil.runInSubProcess) == "function"
        and type(FFIUtil.isSubProcessDone) == "function"
end

function DownloadTask:busy()
    return self.job ~= nil or self.hibernated ~= nil
end

function DownloadTask:is_hibernated()
    return self.hibernated ~= nil
end

function DownloadTask:hibernated_reason()
    return self.hibernated and tostring(self.hibernated.reason or "") or nil
end

function DownloadTask:stage()
    local state=self.job and self.job.last_progress_state or nil
    return tostring((state and state.stage) or (self.hibernated and self.hibernated.stage) or "unknown")
end

local HEAVY_STAGES={
    content=true,underlines=true,thoughts=true,footnotes=true,images=true,package=true,
    annotation_batch=true,annotation_apply=true,transform=true,
}
local STALL_RECOVERABLE_STAGES={
    prepare=true,catalog=true,resume=true,content=true,images=true,
    underlines=true,thoughts=true,footnotes=true,annotation_batch=true,
    annotation_apply=true,transform=true,package=true,
}

local function stall_recovery_seconds(backgrounded,stage)
    stage=tostring(stage or "")
    local configured
    if backgrounded==true and type(Config.DOWNLOAD_BACKGROUND_STALL_SECONDS)=="table" then
        configured=tonumber(Config.DOWNLOAD_BACKGROUND_STALL_SECONDS[stage])
    elseif backgrounded~=true and type(Config.DOWNLOAD_FOREGROUND_STALL_SECONDS)=="table" then
        configured=tonumber(Config.DOWNLOAD_FOREGROUND_STALL_SECONDS[stage])
    end
    if configured then return math.max(30,configured) end
    return math.max(60,tonumber(Config.DOWNLOAD_STALL_RECOVERY_SECONDS) or 120)
end
function DownloadTask:is_heavy_stage()
    return HEAVY_STAGES[self:stage()]==true
end

function DownloadTask:worker_pause_acknowledged()
    local job=self.job
    if not job or not job.pause_ack_path then return self.hibernated~=nil end
    return file_exists(job.pause_ack_path)
end

function DownloadTask:_heavy_watch(force)
    local job=self.job
    if not job then return false end
    local now=os.time()
    local gap=math.max(5,tonumber(Config.HEAVY_WATCH_SECONDS) or 10)
    if force~=true and now-(tonumber(self.last_heavy_watch_at) or 0)<gap then return false end
    local memory=RuntimePressure.memory_snapshot(force==true)
    local stage=self:stage()
    if not self:is_heavy_stage() and not (memory and memory.available_kb<(tonumber(Config.HEAVY_NATIVE_HIBERNATE_KB) or 96*1024)) then
        return false
    end
    self.last_heavy_watch_at=now
    local progress_at=tonumber(job.last_effective_progress_at or job.last_progress_at or job.started_at) or now
    local snapshot={updated_at=now,owner="download",stage=stage,pid=job.pid,
        memory_kb=memory and memory.available_kb or nil,paused=self:is_paused(),
        pause_ack=self:worker_pause_acknowledged(),
        wake_lock=(self.standby_held==true or SuspendWorkLease.has("pseudo_lockscreen")),
        last_progress_age=math.max(0,now-progress_at)}
    U.atomic_write(self.heavy_watch_path,Json.encode(snapshot),true)
    logger.info("[MiuRead][HeavyWatch]",
        "owner=download","stage=",stage,"memory_kb=",tostring(snapshot.memory_kb or "unknown"),
        "pid=",tostring(job.pid or ""),"paused=",tostring(snapshot.paused),
        "pause_ack=",tostring(snapshot.pause_ack),"wake_lock=",tostring(snapshot.wake_lock),
        "last_progress_age=",tostring(snapshot.last_progress_age))
    return true
end

function DownloadTask:_schedule()
    if self.poll_task then return end
    local task
    task = function()
        if self.poll_task ~= task then return end
        self.poll_task = nil
        self:_poll()
    end
    self.poll_task = task
    local interval = self:is_paused() and self.paused_poll_interval
        or (self.backgrounded and self.background_poll_interval or self.foreground_poll_interval)
    UIManager:scheduleIn(interval, task)
end

function DownloadTask:_read_progress(job)
    local raw = U.read_file(job.progress_path, true)
    if not raw or raw == job.last_progress_raw then return false end
    local ok, state = pcall(Json.decode, raw)
    if ok and type(state) == "table" then
        if job.task_token and tostring(state.task_token or "")~=tostring(job.task_token) then
            job.token_mismatch=true
            logger.warn("[MiuRead][DownloadTask] progress task identity mismatch")
            return false
        end
        job.last_progress_raw = raw
        job.last_progress_state = state
        job.last_progress_at = tonumber(state.updated_at) or file_mtime(job.progress_path) or os.time()
        if state.stage=="waiting_network" or state.waiting_network==true then
            job.waiting_started_at=tonumber(state.network_wait_started_at)
                or job.waiting_started_at or job.last_progress_at
        else
            job.waiting_started_at=nil
            job.network_restore_attempts=0
            job.last_network_restore_at=nil
            job.network_sleep_notified=nil
            job.network_hibernate_requested_at=nil
            job.last_effective_progress_at=job.last_progress_at
        end
        job.waiting_notified = false
        job.stall_suspect_notified = false
        if self.keep_awake_enabled and not self.backgrounded and not self:is_paused()
            and not self.standby_held then self:_hold_awake() end
        if job.on_progress then job.on_progress(state) end
        return true
    end
    return false
end

function DownloadTask:_finish(job, forced_error)
    self:_read_progress(job)
    local raw = U.read_file(job.result_path, true)
    local result
    local result_source="none"

    if forced_error then
        result = {ok = false, error = forced_error}
        result_source="forced"
    else
        if raw then
            local decoded_ok,decoded=pcall(Json.decode,raw)
            if decoded_ok and type(decoded)=="table" then
                result=decoded
                result_source="result"
            else
                result_source="invalid_result"
            end
        end
        if not result then
            local recovery_raw=job.recovery_path and U.read_file(job.recovery_path,true) or nil
            if recovery_raw then
                local recovery_ok,recovered=pcall(Json.decode,recovery_raw)
                if recovery_ok and usable_recovery_result(recovered) then
                    result=recovered
                    result.recovered=true
                    result_source="recovery_file"
                end
            end
        end
        if not result then
            local state=job.last_progress_state
            local recovered=state and state.recovery_result
            if usable_recovery_result(recovered) then
                result=U.copy(recovered)
                result.recovered=true
                result_source="progress_recovery"
            end
        end
        if not result then
            local stage = job.last_progress_state and job.last_progress_state.stage
            local diagnostic=job.diagnostic_path and U.read_file(job.diagnostic_path,true) or ""
            if diagnostic:find("result_write_failed",1,true) then
                result = {ok = false, error = "无法保存下载结果，请检查设备剩余空间和存储权限。已完成的章节断点仍会保留。"}
            elseif diagnostic:find("child_fatal",1,true) then
                result = {ok = false, error = "下载进程发生内部异常，诊断信息已保留。已完成的章节断点不会丢失。"}
            elseif stage == "package" then
                result = {ok = false, error = "EPUB 生成进程被中断；原有完整书未被覆盖，已下载章节仍保存在断点缓存。请再次下载继续。"}
            elseif stage == "done" then
                result = {ok = false, error = "EPUB 已完成生成，但下载记录未能恢复。请检查存储空间后重新打开书架；断点与已生成文件不会主动删除。"}
            elseif result_source=="invalid_result" then
                result = {ok = false, error = "下载结果写入不完整，诊断信息已保留；已完成的章节断点不会丢失。"}
            else
                result = {ok = false, error = "下载进程被系统中断；已完成的下载进度会继续保留。"}
            end
        end
    end

    local succeeded=type(result)=="table" and result.ok==true
    local cancelled=forced_error=="下载已取消"
    if succeeded or cancelled then
        os.remove(job.progress_path)
        if job.diagnostic_path then os.remove(job.diagnostic_path) end
    else
        local state=job.last_progress_state or {}
        diagnostic_append(job.diagnostic_path,{
            "time="..tostring(os.date("%Y-%m-%d %H:%M:%S")),
            "event=parent_finish",
            "pid="..tostring(job.pid or ""),
            "result_source="..tostring(result_source),
            "stage="..tostring(state.stage or "unknown"),
            "message="..tostring(state.message or ""),
            "started_at="..tostring(job.started_at or ""),
            "last_progress_at="..tostring(job.last_progress_at or ""),
            "process_alive="..tostring(process_exists(job.pid)),
            "result_exists="..tostring(file_exists(job.result_path)),
            "recovery_exists="..tostring(job.recovery_path and file_exists(job.recovery_path) or false),
            "error="..tostring(type(result)=="table" and result.error or result or "unknown"),
        })
        prune_diagnostics(self.store.temp_dir,tonumber(Config.DOWNLOAD_DIAGNOSTIC_KEEP) or 5)
        os.remove(job.progress_path)
    end

    -- Result/recovery/settings files may contain account state. Always remove
    -- them after the parent has consumed the result; only the sanitized text
    -- diagnostic is kept for failed jobs.
    os.remove(job.result_path)
    if job.recovery_path then os.remove(job.recovery_path) end
    os.remove(job.cancel_path)
    if job.pause_path then os.remove(job.pause_path) end
    if job.pause_ack_path then os.remove(job.pause_ack_path) end
    if job.hibernate_path then os.remove(job.hibernate_path) end
    if job.network_path then os.remove(job.network_path) end
    if job.worker_settings_path then os.remove(job.worker_settings_path) end
    if self:_owns_job() then os.remove(self.owner_path) end
    self.job = nil
    PseudoLockscreen.set_download_active(false)
    os.remove(self.heavy_watch_path)
    self:_clear_lockscreen_network("download_finished")
    self:_release_awake()
    if job.on_done then
        local callback_ok,callback_error=xpcall(function() job.on_done(result) end,debug.traceback)
        if not callback_ok then logger.warn("[MiuRead][DownloadTask] completion callback failed",tostring(callback_error)) end
    end
    -- The pseudo lock owns the visible sleep screen until the last background
    -- task is finished. A failed/cancelled download is also a completed task,
    -- so it must not strand the device awake behind the cover forever.
    pcall(PseudoLockscreen.background_task_done, "download")
end

function DownloadTask:_handle_hibernated(job,result)
    if not job or self.job~=job then return false end
    local network_control=job.network_path and U.read_file(job.network_path,true) or nil
    network_control=tostring(network_control or ""):match("^%s*([%w_%-]+)")
    local options=serializable_copy(job.restart_options or {}) or {}
    options._stall_restart_count=tonumber(job.stall_restart_count) or tonumber(options._stall_restart_count) or 0
    if network_control=="ipv4" then options.network_mode="ipv4"; options.network_suggestion_silent=nil
    elseif network_control=="auto_silent" then options.network_mode="auto"; options.network_suggestion_silent=true end
    local state=U.copy(job.last_progress_state or {})
    state.stage="hibernated"
    state.hibernated=true
    state.hibernate_reason=tostring(result and result.reason or "heavy_resource")
    state.message=state.hibernate_reason=="network_offline"
        and "网络长时间不可用，下载断点已保存；联网后继续"
        or (state.hibernate_reason=="low_battery"
            and "设备电量较低，下载断点已保存；唤醒后可继续"
            or "为前台释放资源，下载已安全休眠")
    state.updated_at=os.time()
    local h={book=serializable_copy(job.restart_book),options=options,on_progress=job.on_progress,on_done=job.on_done,
        restart_count=tonumber(job.restart_count) or 0,stall_restart_count=tonumber(job.stall_restart_count) or 0,
        backgrounded=self.backgrounded==true,reason=state.hibernate_reason,stage=tostring(result and result.stage or self:stage()),
        started_at=job.started_at,last_state=U.copy(state)}
    os.remove(job.progress_path); os.remove(job.result_path); if job.recovery_path then os.remove(job.recovery_path) end
    os.remove(job.cancel_path); if job.pause_path then os.remove(job.pause_path) end
    if job.pause_ack_path then os.remove(job.pause_ack_path) end
    if job.hibernate_path then os.remove(job.hibernate_path) end
    if job.network_path then os.remove(job.network_path) end
    if job.worker_settings_path then os.remove(job.worker_settings_path) end
    if self:_owns_job() then os.remove(self.owner_path) end
    self.job=nil
    PseudoLockscreen.set_download_active(false)
    self.hibernated=h
    self:_clear_lockscreen_network("download_hibernated")
    self:_release_awake()
    U.atomic_write(self.heavy_watch_path,Json.encode({updated_at=os.time(),owner="download",stage=h.stage,
        hibernated=true,reason=h.reason}),true)
    if h.on_progress then pcall(h.on_progress,state) end
    logger.warn("[MiuRead][HeavyGuard] action=hibernate_download",
        "reason=",h.reason,"stage=",h.stage)
    pcall(PseudoLockscreen.background_task_done, "download_hibernated")
    return true
end

function DownloadTask:request_hibernate(reason)
    if self.hibernated then return true,"already_hibernated" end
    local job=self.job
    if not job or not job.hibernate_path then
        if self:busy() then self:pause("heavy_resource") end
        return false,"unsupported"
    end
    reason=tostring(reason or "heavy_resource")
    local wrote=U.atomic_write(job.hibernate_path,Json.encode({reason=reason,requested_at=os.time()}),true)==true
    if wrote then
        self:pause("heavy_resource")
        job.hibernate_requested_at=os.time()
        logger.warn("[MiuRead][HeavyGuard] hibernate requested",
            "reason=",reason,"stage=",self:stage(),"pid=",tostring(job.pid or ""))
        self:_schedule()
        return true
    end
    return false,"write_failed"
end

function DownloadTask:resume_hibernated(reason)
    local h=self.hibernated
    if not h then return false,"not_hibernated" end
    local memory=RuntimePressure.memory_snapshot(true)
    local minimum=math.max(1,tonumber(Config.HEAVY_DOWNLOAD_RESUME_MIN_KB) or 72*1024)
    if memory and memory.available_kb<minimum then
        logger.info("[MiuRead][HeavyGuard] hibernated download remains parked",
            "reason=low_memory","memory_kb=",tostring(memory.available_kb),"minimum_kb=",tostring(minimum))
        return false,"low_memory"
    end
    self.hibernated=nil
    local options=serializable_copy(h.options or {}) or {}
    options._stall_restart_count=tonumber(h.stall_restart_count) or tonumber(options._stall_restart_count) or 0
    local ok,err=self:start(h.book,options,h.on_progress,h.on_done,h.restart_count)
    if not ok then self.hibernated=h; return false,err end
    self.backgrounded=h.backgrounded==true
    if self.backgrounded then self:set_backgrounded(true) end
    os.remove(self.heavy_watch_path)
    logger.info("[MiuRead][HeavyGuard] hibernated download resumed",
        "reason=",tostring(reason or "foreground stable"),"book=",tostring(h.book and h.book.bookId or ""))
    return true
end

function DownloadTask:_restart_interrupted(job,stall_recovery)
    if not job or job.cancel_requested_at then return false end
    local count=tonumber(job.restart_count) or 0
    local maximum=math.max(0,tonumber(Config.DOWNLOAD_AUTO_RESTARTS) or 2)
    if count>=maximum or type(job.restart_book)~="table" or tostring(job.restart_book.bookId or "")=="" then
        return false
    end
    local book=serializable_copy(job.restart_book)
    local options=serializable_copy(job.restart_options or {}) or {}
    local stall_count=tonumber(job.stall_restart_count) or tonumber(options._stall_restart_count) or 0
    if stall_recovery==true then stall_count=stall_count+1 end
    options._stall_restart_count=stall_count
    local network_control=job.network_path and U.read_file(job.network_path,true) or nil
    network_control=tostring(network_control or ""):match("^%s*([%w_%-]+)")
    if network_control=="ipv4" then
        options.network_mode="ipv4"
        options.network_suggestion_silent=nil
    elseif network_control=="auto_silent" then
        options.network_mode="auto"
        options.network_suggestion_silent=true
    end
    local on_progress,on_done=job.on_progress,job.on_done
    local state=U.copy(job.last_progress_state or {})
    state.stage="restart"
    state.message="后台下载进程被系统中断，正在从断点自动恢复（"..tostring(count+1).."/"..tostring(maximum).."）"
    state.updated_at=os.time()
    state.restart_count=count+1
    if on_progress then pcall(on_progress,state) end

    diagnostic_append(job.diagnostic_path,{
        "time="..tostring(os.date("%Y-%m-%d %H:%M:%S")),
        "event=automatic_restart",
        "pid="..tostring(job.pid or ""),
        "stage="..tostring((job.last_progress_state or {}).stage or "unknown"),
        "restart_count="..tostring(count+1),
    })
    os.remove(job.progress_path)
    os.remove(job.result_path)
    if job.recovery_path then os.remove(job.recovery_path) end
    os.remove(job.cancel_path)
    if job.pause_path then os.remove(job.pause_path) end
    if job.pause_ack_path then os.remove(job.pause_ack_path) end
    if job.hibernate_path then os.remove(job.hibernate_path) end
    if job.network_path then os.remove(job.network_path) end
    if job.worker_settings_path then os.remove(job.worker_settings_path) end
    if self:_owns_job() then os.remove(self.owner_path) end
    self.job=nil
    self:_release_awake()
    local ok,err=self:start(book,options,on_progress,on_done,count+1)
    if not ok then
        PseudoLockscreen.set_download_active(false)
        logger.warn("[MiuRead][DownloadTask] automatic restart failed",tostring(err))
        if on_done then
            on_done({ok=false,error="后台下载进程被系统中断，自动恢复失败："..tostring(err).."。断点仍已保留。"})
        end
        pcall(PseudoLockscreen.background_task_done, "download_restart_failed")
        return true
    end
    if on_progress then pcall(on_progress,state) end
    logger.warn("[MiuRead][DownloadTask] worker restarted from checkpoint",
        "attempt=",tostring(count+1),"book=",tostring(book.bookId or ""))
    return true
end

function DownloadTask:_poll()
    local job = self.job
    if not job then return end
    if not self:_owns_job() then
        logger.info("[MiuRead][DownloadTask] controller ownership transferred","pid=",tostring(job.pid))
        self.job=nil
        self:_release_awake()
        return
    end

    self:_read_progress(job)
    -- A UI pause is allowed to protect a transition, never to become a
    -- permanent task state. Recover old transient markers independently of UI
    -- callbacks before evaluating worker liveness. Explicit/manual/recovery
    -- pauses are untouched.
    self:_recover_stale_transient_pauses()
    self:_heavy_watch(false)
    if job.token_mismatch then
        self:_finish(job,"后台下载任务身份不匹配；断点已保留，请重新开始下载。")
        return
    end
    local ready_result=read_json(job.result_path)
    if ready_result then
        if ready_result.hibernated==true then
            -- The child writes the hibernation result immediately before it
            -- exits. Do not advertise HIBERNATED until the process has really
            -- left /proc (or waitpid confirms completion), otherwise Native may
            -- start while the download Lua heap is still resident.
            local done_ok,done=pcall(FFIUtil.isSubProcessDone,job.pid,false)
            local alive=process_exists(job.pid)
            if (done_ok and done==true) or alive==false then
                self:_handle_hibernated(job,ready_result)
            else
                self:_release_awake()
                self:_schedule()
            end
            return
        end
        self:_finish(job); return
    end

    local now=os.time()
    local progress_state=job.last_progress_state or {}
    local network_waiting=progress_state.stage=="waiting_network" or progress_state.waiting_network==true
    local network_wait_started=tonumber(progress_state.network_wait_started_at)
        or tonumber(job.waiting_started_at)
    local network_wait_age=network_waiting and network_wait_started
        and math.max(0,now-network_wait_started) or 0
    if background_lock_mode(self.power_mode) then
        local battery_ok,battery=self:_battery_allows_locked()
        if not battery_ok and not job.low_battery_hibernate_requested_at then
            job.low_battery_hibernate_requested_at=now
            local state=U.copy(progress_state)
            state.message="设备电量较低，正在保存下载断点并进入休眠"
            state.battery=tonumber(battery)
            state.updated_at=now
            if job.on_progress then pcall(job.on_progress,state) end
            local requested,reason=self:request_hibernate("low_battery")
            logger.warn("[MiuRead][DownloadTask] low-battery download hibernate",
                "pid=",tostring(job.pid),"battery=",tostring(battery or "unknown"),
                "requested=",tostring(requested),"reason=",tostring(reason or ""))
            if requested then return end
        end
    end
    if background_lock_mode(self.power_mode) then
        self:_guard_lockscreen_network(job,now,false)
    end
    if network_waiting then
        self:_maybe_restore_network(job,now,network_wait_age)
        local lock_max=math.max(45,tonumber(Config.DOWNLOAD_NETWORK_LOCK_MAX_SECONDS) or 90)
        if network_wait_age>=lock_max then
            if self.standby_held then self:_release_awake() end
            if job.network_sleep_notified~=true then
                job.network_sleep_notified=true
                local state=U.copy(progress_state)
                state.message="网络暂未恢复，已允许设备正常休眠；下载断点不会丢失"
                state.network_wait_seconds=network_wait_age
                state.updated_at=now
                if job.on_progress then pcall(job.on_progress,state) end
                logger.warn("[MiuRead][DownloadTask] offline download released standby",
                    "pid=",tostring(job.pid),"wait=",tostring(network_wait_age))
            end
        end
        local hibernate_after=math.max(lock_max+15,tonumber(Config.DOWNLOAD_NETWORK_HIBERNATE_SECONDS) or 120)
        if network_wait_age>=hibernate_after and not job.network_hibernate_requested_at then
            job.network_hibernate_requested_at=now
            local state=U.copy(progress_state)
            state.message="网络长时间不可用，正在保存断点并暂停后台下载"
            state.network_wait_seconds=network_wait_age
            state.updated_at=now
            if job.on_progress then pcall(job.on_progress,state) end
            local requested,reason=self:request_hibernate("network_offline")
            logger.warn("[MiuRead][DownloadTask] offline download hibernate",
                "pid=",tostring(job.pid),"wait=",tostring(network_wait_age),
                "requested=",tostring(requested),"reason=",tostring(reason or ""))
            if requested then return end
        end
    end

    local stall_sleep=math.max(120,tonumber(Config.DOWNLOAD_BACKGROUND_STALL_SLEEP_SECONDS) or 300)
    local effective_activity=tonumber(job.last_effective_progress_at or job.started_at) or now
    local effective_idle=math.max(0,now-effective_activity)
    local waiting_since=tonumber(job.waiting_started_at)
    local lock_max=math.max(45,tonumber(Config.DOWNLOAD_NETWORK_LOCK_MAX_SECONDS) or 600)
    local lockscreen_network_hold=network_waiting and background_lock_mode(self.power_mode)
        and network_wait_age<lock_max
    local waiting_too_long=waiting_since and now-waiting_since>=stall_sleep
        and not lockscreen_network_hold
    local stalled_too_long=effective_idle>=stall_sleep and not network_waiting
    if job.fail_open_done~=true and not self:is_paused() and not waiting_too_long and not stalled_too_long then
        local keepalive_gap=self.backgrounded
            and math.max(8,tonumber(Config.DOWNLOAD_BACKGROUND_KEEPALIVE_SECONDS) or 12) or 5
        if not job.last_keepalive or now-job.last_keepalive>=keepalive_gap then
            job.last_keepalive=now
            if not self.standby_held then self:_hold_awake() end
            local reset=self:_reset_device_timeout()
            if reset then logger.dbg("[MiuRead][DownloadTask] Kindle T1 timer reset") end
        end
    elseif (waiting_too_long or stalled_too_long) and self.standby_held then
        self:_release_awake()
        logger.info("[MiuRead][DownloadTask] stalled download may sleep",
            "pid=",tostring(job.pid),"idle=",tostring(effective_idle),
            "waiting=",tostring(waiting_since and now-waiting_since or 0))
    end

    local alive=process_exists(job.pid)
    local done_ok,done=pcall(FFIUtil.isSubProcessDone,job.pid,false)
    if not done_ok then
        logger.warn("[MiuRead][DownloadTask] poll failed",tostring(done))
    end

    local activity=tonumber(job.last_progress_at or file_mtime(job.progress_path) or job.started_at) or now
    local idle=math.max(0,now-activity)
    local final_state=job.last_progress_state
    local recovery_ready=job.recovery_path and read_json(job.recovery_path) or nil
    local snapshot_ready=final_state and usable_recovery_result(final_state.recovery_result)
    if final_state and final_state.stage=="done" and idle>=3
        and (usable_recovery_result(recovery_ready) or snapshot_ready) then
        self:_finish(job)
        return
    end
    local running=alive==true or (alive==nil and done_ok and done==false)

    if running then
        job.dead_seen_at=nil
        if self:is_paused() then
            job.waiting_notified=false
            self:_release_awake()
            self:_schedule()
            return
        end
        job.unknown_seen_at=nil
        job.rechecking_notified=false
        local cancel_force=math.max(2,tonumber(Config.DOWNLOAD_CANCEL_FORCE_SECONDS) or 4)
        if job.cancel_requested_at and now-job.cancel_requested_at>=cancel_force then
            pcall(FFIUtil.terminateSubProcess,job.pid)
            self:_finish(job,"下载已取消")
            return
        end

        -- beta.23: a healthy streamed image transfer/extraction refreshes the
        -- progress heartbeat. If a stage that should be making progress stays
        -- completely silent, stop the old child instead of leaving the whole
        -- device in a pseudo-hung state for many minutes. Network/rate-limit
        -- wait stages are deliberately excluded.
        local current_stage=tostring(job.last_progress_state and job.last_progress_state.stage or "unknown")
        local stall_recovery=stall_recovery_seconds(self.backgrounded,current_stage)
        local foreground_notice=math.max(10,tonumber(Config.DOWNLOAD_FOREGROUND_STALL_NOTICE_SECONDS) or 25)
        if not self.backgrounded and not self:is_paused()
            and STALL_RECOVERABLE_STAGES[current_stage]==true
            and effective_idle>=foreground_notice and effective_idle<stall_recovery
            and job.stall_suspect_notified~=true then
            job.stall_suspect_notified=true
            local state=U.copy(job.last_progress_state or {})
            state.message="下载任务暂时没有新的进展，正在检查任务状态"
            state.updated_at=now
            if job.on_progress then pcall(job.on_progress,state) end
            logger.info("[MiuRead][DownloadTask] foreground stall suspected",
                "stage=",current_stage,"idle=",tostring(effective_idle),
                "recover_at=",tostring(stall_recovery))
        end
        if not self:is_paused() and effective_idle>=stall_recovery
            and STALL_RECOVERABLE_STAGES[current_stage]==true then
            if not job.stall_recovery_requested_at then
                job.stall_recovery_requested_at=now
                local maximum=math.max(0,tonumber(Config.DOWNLOAD_STALL_AUTO_RESTARTS) or 1)
                job.stall_terminal=(tonumber(job.stall_restart_count) or 0)>=maximum
                local state=U.copy(job.last_progress_state or {})
                state.stage="restart"
                state.message=job.stall_terminal
                    and "下载任务没有响应，已停止当前任务；断点已保留，可点击继续"
                    or "下载任务没有响应，正在释放旧任务并从断点恢复"
                state.updated_at=now
                if job.on_progress then pcall(job.on_progress,state) end
                diagnostic_append(job.diagnostic_path,{
                    "time="..tostring(os.date("%Y-%m-%d %H:%M:%S")),
                    "event=stall_recovery",
                    "pid="..tostring(job.pid or ""),
                    "stage="..current_stage,
                    "effective_idle="..tostring(effective_idle),
                    "terminal="..tostring(job.stall_terminal==true),
                })
                local locked=background_lock_mode(self.power_mode) or PseudoLockscreen.active()==true
                if locked then
                    -- Power safety is resolved BEFORE touching a sick worker.
                    -- User wake/cover-open must never depend on process exit.
                    self:_fail_open_locked_download(job,job.stall_terminal==true
                        and "terminal_stall" or "stall_detected")
                else
                    self:_release_awake()
                    job.fail_open_deadline=now+math.max(4,tonumber(Config.DOWNLOAD_STALL_FAIL_OPEN_SECONDS) or 12)
                end
                local signaled,signal_reason=signal_worker(job.pid,15)
                if not signaled and not locked then
                    pcall(FFIUtil.terminateSubProcess,job.pid)
                end
                logger.warn("[MiuRead][WorkerRecovery]",
                    "pid=",tostring(job.pid),"stage=",current_stage,
                    "signal=SIGTERM","nonblocking=",tostring(signaled),
                    "reason=",tostring(signal_reason or ""),
                    "idle=",tostring(effective_idle),"terminal=",tostring(job.stall_terminal==true))
                self:_schedule()
                return
            elseif now-job.stall_recovery_requested_at>=8 then
                local locked=job.fail_open_done==true or PseudoLockscreen.active()==true
                    or background_lock_mode(self.power_mode)
                local signaled,signal_reason=signal_worker(job.pid,9)
                if not signaled and not locked then
                    pcall(FFIUtil.terminateSubProcess,job.pid)
                end
                if job.stall_force_signal_logged~=true then
                    job.stall_force_signal_logged=true
                    logger.warn("[MiuRead][WorkerRecovery]",
                        "pid=",tostring(job.pid),"signal=SIGKILL",
                        "nonblocking=",tostring(signaled),
                        "reason=",tostring(signal_reason or ""))
                end
            end
            if job.fail_open_done~=true and tonumber(job.fail_open_deadline)
                and now>=tonumber(job.fail_open_deadline) then
                self:_fail_open_locked_download(job,job.stall_terminal==true
                    and "terminal_stall" or "stall_termination_timeout")
            end
        end
        if idle>=120 and not job.waiting_notified then
            job.waiting_notified=true
            local state=U.copy(job.last_progress_state or {})
            state.message="下载任务仍在处理中，正在继续检查状态"
            state.updated_at=now
            if job.on_progress then job.on_progress(state) end
        end
        if effective_idle>=stall_sleep and self.standby_held
            and not (network_waiting and background_lock_mode(self.power_mode) and network_wait_age<lock_max) then
            self:_release_awake()
            logger.info("[MiuRead][DownloadTask] standby lease released while stalled",
                "pid=",tostring(job.pid),"idle=",tostring(effective_idle),
                "stage=",tostring(job.last_progress_state and job.last_progress_state.stage or "unknown"))
        end
        self:_schedule()
        return
    end

    if job.cancel_requested_at then
        pcall(FFIUtil.terminateSubProcess,job.pid)
        self:_finish(job,"下载已取消")
        return
    end

    -- A completed recovery file or a completed progress snapshot is accepted
    -- only after the worker is no longer confirmed alive. This prevents a
    -- transient result-file failure from turning a completed EPUB into an
    -- error while avoiding premature cleanup of a still-running worker.
    if usable_recovery_result(recovery_ready) then
        self:_finish(job)
        return
    end
    if job.last_progress_state and job.last_progress_state.stage=="done" and idle>=3 then
        self:_finish(job)
        return
    end

    if alive==nil then
        job.unknown_seen_at=job.unknown_seen_at or now
        if not job.rechecking_notified then
            job.rechecking_notified=true
            local state=U.copy(job.last_progress_state or {})
            state.message="正在重新确认下载任务状态"
            state.updated_at=now
            if job.on_progress then job.on_progress(state) end
        end
        -- Unknown means unknown: Android may temporarily deny /proc status,
        -- and a recreated UI may no longer own waitpid(). Give both the last
        -- progress heartbeat and the process-state check enough time.
        if idle<60 or now-job.unknown_seen_at<120 then self:_schedule(); return end
        if done_ok and done==true and self:_restart_interrupted(job) then return end
        -- When /proc is unavailable and waitpid ownership was lost, wait longer
        -- before deciding the worker vanished. This avoids duplicate workers on
        -- Android while still recovering a truly dead task from its checkpoint.
        if idle<180 or now-job.unknown_seen_at<180 then self:_schedule(); return end
        if self:_restart_interrupted(job) then return end
        self:_finish(job)
        return
    end

    job.dead_seen_at=job.dead_seen_at or now
    if job.stall_recovery_requested_at then
        local grace=math.max(1,tonumber(Config.DOWNLOAD_STALL_RESTART_GRACE_SECONDS) or 3)
        if now-job.dead_seen_at<grace then self:_schedule(); return end
        if job.stall_terminal==true then
            self:_finish(job,"下载任务没有响应，已停止当前任务；已完成章节和断点均已保留，可点击继续。")
            return
        end
        if self:_restart_interrupted(job,true) then return end
        self:_finish(job,"下载任务没有响应，自动恢复未能启动；断点已保留，可点击继续。")
        return
    end
    if not job.rechecking_notified then
        job.rechecking_notified=true
        local state=U.copy(job.last_progress_state or {})
        state.message="下载进程已停止，正在检查已完成内容"
        state.updated_at=now
        if job.on_progress then job.on_progress(state) end
    end
    -- Do not turn a short /proc race into a duplicate worker. A real dead
    -- process must remain absent for 30 seconds and make no progress for 20.
    if now-job.dead_seen_at<30 or idle<20 then self:_schedule(); return end
    if self:_restart_interrupted(job) then return end
    self:_finish(job)
end

function DownloadTask:cancel()
    if self.hibernated then
        local h=self.hibernated
        self.hibernated=nil
        os.remove(self.heavy_watch_path)
        if h.on_done then pcall(h.on_done,{ok=false,error="下载已取消"}) end
        return true
    end
    local job = self.job
    if not job or job.cancel_requested_at or not self:_owns_job() then return end
    job.cancel_requested_at = os.time()
    self.pause_reasons={}
    if job.pause_path then os.remove(job.pause_path) end
    U.atomic_write(job.cancel_path, "1", true)
end

function DownloadTask:attach(descriptor,on_progress,on_done,restart_book,restart_options)
    if self.job or self.hibernated then return false,"已有下载任务正在运行" end
    if not self:available() then return false,"当前 KOReader 不支持下载子进程" end
    descriptor=type(descriptor)=="table" and descriptor or nil
    if descriptor and descriptor.hibernated==true then
        self.hibernated={book=serializable_copy(restart_book),options=serializable_copy(restart_options or {}) or {},
            on_progress=on_progress,on_done=on_done,restart_count=tonumber(descriptor.restart_count) or 0,
            stall_restart_count=tonumber(descriptor.stall_restart_count) or 0,
            backgrounded=true,reason=tostring(descriptor.hibernate_reason or "recovered"),
            stage=tostring(descriptor.stage or "hibernated"),started_at=descriptor.started_at}
        self.backgrounded=true
        PseudoLockscreen.set_download_active(false)
        logger.warn("[MiuRead][DownloadTask] recovered hibernated task",
            "book=",tostring(restart_book and restart_book.bookId or ""),"reason=",self.hibernated.reason)
        return true,"hibernated"
    end
    local pid=descriptor and tonumber(descriptor.pid)
    if not pid or not descriptor.progress_path or not descriptor.result_path
        or not descriptor.cancel_path then return false,"下载任务记录不完整" end
    if not descriptor.pause_path or tostring(descriptor.pause_path)=="" then
        -- A pre-beta.10 worker cannot obey suspend barriers. Stop it cleanly
        -- instead of reattaching an unsafe process; its chapter checkpoint is
        -- retained and the user can continue the same download afterwards.
        U.atomic_write(descriptor.cancel_path,"1",true)
        return false,"旧版后台任务已安全停止；断点已保留，请继续下载"
    end
    self.keep_awake_enabled=self.store:preferences().download_keep_awake~=false
    local recovery_path=descriptor.recovery_path
        or tostring(descriptor.result_path):gsub("download%-result%-","download-recovery-")
    local diagnostic_path=descriptor.diagnostic_path
        or tostring(descriptor.result_path):gsub("download%-result%-","download-diagnostic-"):gsub("%.json$",".txt")
    self.job={
        pid=pid,progress_path=descriptor.progress_path,result_path=descriptor.result_path,
        recovery_path=recovery_path,diagnostic_path=diagnostic_path,
        cancel_path=descriptor.cancel_path,pause_path=descriptor.pause_path,pause_ack_path=descriptor.pause_ack_path,
        hibernate_path=descriptor.hibernate_path,network_path=descriptor.network_path,
        worker_settings_path=descriptor.worker_settings_path,
        on_progress=on_progress,on_done=on_done,last_progress_raw=nil,last_progress_state=nil,
        last_progress_at=nil,last_effective_progress_at=nil,waiting_started_at=nil,last_keepalive=0,started_at=descriptor.started_at,dead_seen_at=nil,stall_recovery_requested_at=nil,stall_suspect_notified=false,stall_terminal=false,
        unknown_seen_at=nil,waiting_notified=false,rechecking_notified=false,
        task_token=descriptor.task_token,
        restart_count=tonumber(descriptor.restart_count) or 0,
        stall_restart_count=tonumber(descriptor.stall_restart_count) or tonumber(restart_options and restart_options._stall_restart_count) or 0,
        restart_book=serializable_copy(restart_book),
        restart_options=serializable_copy(restart_options),
    }
    self.backgrounded=true
    self.pause_reasons=self:_marker_reasons(self.job.pause_path)
    self:_read_progress(self.job)
    if self.job.token_mismatch then
        self.job=nil
        return false,"后台下载任务身份不匹配"
    end
    local done_ok,done=pcall(FFIUtil.isSubProcessDone,pid,false)
    local alive=process_exists(pid)
    local result_ready=read_json(self.job.result_path)
    local recovery_ready=self.job.recovery_path and read_json(self.job.recovery_path) or nil
    local progress_ready=self.job.last_progress_state
    local completed_snapshot=progress_ready and progress_ready.stage=="done"
        and usable_recovery_result(progress_ready.recovery_result)
    -- A finished child without a consumable result is a stale task record, not
    -- a running task.  Do not attach it and automatically spawn a duplicate
    -- worker after KOReader starts (especially while the user is reading).
    if done_ok and done==true and alive~=true
        and not result_ready and not usable_recovery_result(recovery_ready)
        and not completed_snapshot then
        self.job=nil
        return false,"上次后台下载进程已经结束；断点已保留，请手动继续下载"
    end
    if not done_ok and alive==nil then
        logger.warn("[MiuRead][DownloadTask] attached with unknown process state",
            "pid=",tostring(pid),"error=",tostring(done))
    end
    self:_claim(pid)
    PseudoLockscreen.set_download_active(self.keep_awake_enabled == true)
    self:_release_awake()
    logger.info("[MiuRead][DownloadTask] attached","pid=",tostring(pid),
        "done=",tostring(done_ok and done or "unknown"),"alive=",tostring(alive))
    if result_ready or usable_recovery_result(recovery_ready) or completed_snapshot then
        local attached_job=self.job
        UIManager:scheduleIn(0,function()
            if self.job==attached_job and self:_owns_job() then self:_finish(attached_job) end
        end)
    else
        if alive==false then self.job.dead_seen_at=os.time() end
        self:_schedule()
    end
    return true
end

function DownloadTask:start(book, options, on_progress, on_done, restart_count)
    if self.job or self.hibernated then return false, "已有下载任务正在运行" end
    if not self:available() then return false, "当前 KOReader 不支持下载子进程" end

    local stamp = tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))
    local progress_path = self.store.temp_dir .. "/download-progress-" .. stamp .. ".json"
    local result_path = self.store.temp_dir .. "/download-result-" .. stamp .. ".json"
    local recovery_path = self.store.temp_dir .. "/download-recovery-" .. stamp .. ".json"
    local diagnostic_path = self.store.temp_dir .. "/download-diagnostic-" .. stamp .. ".txt"
    local cancel_path = self.store.temp_dir .. "/download-cancel-" .. stamp
    local pause_path = self.store.temp_dir .. "/download-pause-" .. stamp .. ".json"
    local pause_ack_path = self.store.temp_dir .. "/download-pause-ack-" .. stamp .. ".json"
    local hibernate_path = self.store.temp_dir .. "/download-hibernate-" .. stamp .. ".json"
    local network_path = self.store.temp_dir .. "/download-network-" .. stamp
    local worker_settings_path = self.store.temp_dir .. "/download-settings-" .. stamp .. ".lua"
    local flushed, flush_error = self.store:flush()
    if flushed~=true then
        return false, "设备状态暂时无法保存，下载未启动。请稍后重试；无需重新扫码。\n"
            .. tostring(U.first_line(flush_error or "未知错误",120))
    end
    local start_auth=self.store:auth()
    local start_account=type(start_auth.account)=="table" and start_auth.account or {}
    local start_cookies=type(start_auth.cookies)=="table" and start_auth.cookies or {}
    local copied, copy_error = U.copy_file(self.store.settings_path, worker_settings_path)
    if not copied then return false, "无法建立安全下载状态副本：" .. tostring(copy_error or "未知错误") end
    local worker_loader,worker_load_error=loadfile(worker_settings_path)
    local worker_ok,worker_data=false,nil
    if worker_loader then worker_ok,worker_data=pcall(worker_loader) end
    local worker_auth=worker_ok and type(worker_data)=="table" and worker_data.auth or nil
    local worker_account=type(worker_auth)=="table" and type(worker_auth.account)=="table" and worker_auth.account or {}
    local worker_cookies=type(worker_auth)=="table" and type(worker_auth.cookies)=="table" and worker_auth.cookies or {}
    local auth_matches=type(worker_auth)=="table"
        and tostring(worker_auth.login_session_id or "")==tostring(start_auth.login_session_id or "")
        and tostring(worker_account.vid or "")==tostring(start_account.vid or "")
        and tostring(worker_cookies.wr_vid or "")==tostring(start_cookies.wr_vid or "")
        and tostring(worker_cookies.wr_skey or "")==tostring(start_cookies.wr_skey or "")
    if not auth_matches then
        os.remove(worker_settings_path)
        logger.warn("[MiuRead][DownloadTask] worker auth snapshot verification failed",
            "load_ok=",tostring(worker_ok),"error=",tostring(worker_load_error or (worker_ok and "value mismatch" or worker_data)))
        return false,"登录状态没有同步到下载任务，下载未启动。请稍后重试；无需重新扫码。"
    end
    local worker_data_dir = self.store.data_dir
    local task_token = stamp .. "-" .. tostring(math.random(100000,999999))
    local clean_book = serializable_copy(book)
    local clean_options = serializable_copy(options or {})
    clean_options._stall_restart_count=math.max(0,tonumber(clean_options._stall_restart_count) or 0)
    clean_options.download_run_id=tostring(clean_options.download_run_id or task_token)
    clean_options.reader_active_path="/tmp/miuread-reader-active.flag"
    clean_options.reader_busy_path="/tmp/miuread-reader-busy.until"
    clean_options.foreground_yield_path="/tmp/miuread-download-ui-yield.until"
    clean_options.pause_path=pause_path
    clean_options.pause_ack_path=pause_ack_path
    clean_options.hibernate_path=hibernate_path
    clean_options.network_mode=tostring(clean_options.network_mode or "auto")=="ipv4" and "ipv4" or "auto"
    clean_options.network_mode_path=network_path
    clean_options.performance_mode_path=Config.LIGHTWEIGHT_MODE_FLAG
    local initial_network_control=clean_options.network_suggestion_silent==true and "auto_silent" or clean_options.network_mode
    local network_written,network_error=U.atomic_write(network_path,initial_network_control,true)
    if not network_written then
        os.remove(worker_settings_path)
        return false,"无法建立下载网络控制状态："..tostring(network_error or "未知错误")
    end
    local auth_snapshot={
        login_session_id=tostring(start_auth.login_session_id or ""),
        vid=tostring(start_account.vid or ""),
        logged_at=tonumber(start_account.logged_at or 0) or 0,
        ticket_updated_at=tonumber(start_auth.ticket_updated_at or 0) or 0,
        auth_revision=math.max(0,tonumber(start_auth.auth_revision or 0) or 0),
    }
    self.keep_awake_enabled = self.store:preferences().download_keep_awake ~= false
    clean_options.cancelled = nil

    local child = function()
        -- Close parent-owned KOReader sockets before the download worker opens
        -- any connection of its own.
        SubprocessHygiene.close_inherited_sockets()
        lower_worker_priority()
        local Store = require("miuread.store")
        local Http = require("miuread.http")
        local Api = require("miuread.api")
        local Reader = require("miuread.reader")
        local Library = require("miuread.library")
        local Annotations = require("miuread.annotations")
        local Downloader = require("miuread.downloader")
        local JsonChild = require("miuread.json")
        local UChild = require("miuread.util")
        local LoggerChild = require("logger")
        local current_stage="bootstrap"
        local last_emitted_state={}
        local heartbeat_seq=0
        local network_suggestion_detail

        local function write_direct(path,data)
            local file,open_error=io.open(path,"wb")
            if not file then return nil,open_error end
            local written,write_error=file:write(data or "")
            local flushed,flush_error=file:flush()
            file:close()
            if not written then return nil,write_error end
            if flushed==nil then return nil,flush_error end
            local size=UChild.file_size(path)
            if size and size~=#(data or "") then return nil,"written file size mismatch" end
            return true
        end

        local function write_safely(path,data)
            local errors={}
            for attempt=1,2 do
                local ok,err=UChild.atomic_write(path,data,true)
                if ok and UChild.file_exists(path) then return true,"atomic" end
                errors[#errors+1]="atomic"..tostring(attempt)..":"..tostring(err or "missing after write")
            end
            local ok,err=write_direct(path,data)
            if ok then return true,"direct" end
            errors[#errors+1]="direct:"..tostring(err)
            return nil,table.concat(errors,"; ")
        end

        local function append_diagnostic(event,message)
            local file=io.open(diagnostic_path,"ab")
            if not file then return false end
            file:write("time=",tostring(os.date("%Y-%m-%d %H:%M:%S")),"\n")
            file:write("event=",tostring(event or "unknown"),"\n")
            file:write("stage=",tostring(current_stage or "unknown"),"\n")
            local pid_value=""
            if type(FFIUtil.getpid)=="function" then
                local pid_ok,pid_or_error=pcall(FFIUtil.getpid)
                if pid_ok then pid_value=pid_or_error end
            end
            file:write("pid=",tostring(pid_value or ""),"\n")
            file:write("message=",tostring(message or ""):gsub("[\r\n]+"," | "),"\n---\n")
            file:flush()
            file:close()
            return true
        end

        local function write_json(path,value,label)
            local encoded_ok,encoded=pcall(JsonChild.encode,value)
            if not encoded_ok then
                append_diagnostic(tostring(label).."_encode_failed",encoded)
                return nil,"JSON encode failed: "..tostring(encoded)
            end
            local wrote,mode_or_error=write_safely(path,encoded)
            if not wrote then
                append_diagnostic(tostring(label).."_write_failed",mode_or_error)
                return nil,mode_or_error
            end
            return true,mode_or_error
        end

        local function emit(state)
            state = state or {}
            current_stage=tostring(state.stage or current_stage)
            if network_suggestion_detail then
                local control=UChild.read_file(network_path,true)
                control=tostring(control or ""):match("^%s*([%w_%-]+)") or "auto"
                if control=="ipv4" or control=="auto_silent" then
                    network_suggestion_detail=nil
                else
                    state.network_ipv4_suggested=true
                    state.network_ipv4_recovery=network_suggestion_detail.recovery_ipv4==true or nil
                    state.network_auto_unavailable=network_suggestion_detail.auto_unavailable==true or nil
                    state.network_auto_seconds=tonumber(network_suggestion_detail.auto_seconds)
                    state.network_ipv4_seconds=tonumber(network_suggestion_detail.ipv4_seconds)
                    state.network_gain_seconds=tonumber(network_suggestion_detail.gain_seconds)
                    state.network_trigger_baseline=tonumber(network_suggestion_detail.trigger_baseline)
                end
            end
            heartbeat_seq=heartbeat_seq+1
            state.task_token = task_token
            state.heartbeat_seq = heartbeat_seq
            state.updated_at = os.time()
            last_emitted_state=serializable_copy(state) or {}
            local wrote,write_error=write_json(progress_path,state,"progress")
            if not wrote then LoggerChild.warn("[MiuRead][DownloadTask] progress write failed",tostring(write_error)) end
            return wrote
        end

        local function display_error(raw)
            raw=tostring(raw or "未知下载错误")
            local display=raw:match("^(.-)\nstack traceback:") or raw
            display=display:gsub("^.-%.lua:%d+:%s*", "")
            if raw:lower():find("download cancelled",1,true) then
                return "下载已暂停，可稍后继续"
            end
            if raw:lower():find("not enough memory", 1, true) then
                return "设备内存不足，未生成新的 EPUB。原有完整书未被覆盖，已完成章节仍保存在断点缓存；再次下载时会继续。"
            end
            if raw:find("[MiuReadRateLimit]", 1, true)
                or raw:lower():find("hit api rate limit", 1, true) then
                return "微信读书暂时限制了请求频率。插件已停止继续请求；已完成章节和断点都已保留，请稍后继续下载。"
            end
            return display
        end

        local last_progress_percent = 0
        local function run_download()
            local ok, value = xpcall(function()
                local store = Store:new{
                    settings_path = worker_settings_path,
                    data_dir = worker_data_dir,
                    isolated = true,
                }
                local http = Http:new(store)
                http:set_download_network_policy{
                    mode=clean_options.network_mode,
                    mode_path=network_path,
                }
                local reader = Reader:new(http, store)
                local api = Api:new(http, store, reader)
                local library = Library:new(api, http, store)
                local annotations = Annotations:new(api)
                local downloader = Downloader:new(reader, api, annotations, store, http)
                clean_options.cancelled = function()
                    return UChild.file_exists(cancel_path)
                end
                -- The parent and ReaderUI instances coordinate through a shared
                -- pause marker. Read it in the child itself; otherwise only the
                -- parent poller pauses while the download process keeps working.
                clean_options.paused = function()
                    return UChild.file_exists(pause_path)
                end
                clean_options.hibernating = function()
                    return UChild.file_exists(hibernate_path)
                end
                clean_options.pause_ack = function(stage,paused)
                    if paused then
                        write_json(pause_ack_path,{paused=true,stage=tostring(stage or "work"),updated_at=os.time()},"pause_ack")
                    else
                        os.remove(pause_ack_path)
                    end
                end
                http.cancelled = clean_options.cancelled
                http.rate_limit_retries = 3
                http.min_weread_interval = 0.45
                http.on_rate_limit = function(remaining, attempt, maximum, code)
                    emit{
                        stage = "rate_limit",
                        current = 0,
                        total = 0,
                        percent = last_progress_percent,
                        chapter = clean_book.title or "",
                        message = "微信读书请求过快，等待 " .. tostring(remaining)
                            .. " 秒后自动继续（" .. tostring(attempt) .. "/" .. tostring(maximum) .. "）",
                        rate_limit_code = tostring(code or ""),
                        wait_seconds = tonumber(remaining),
                    }
                end
                http.on_network_suggestion = function(detail)
                    network_suggestion_detail=serializable_copy(detail or {}) or {}
                    emit(serializable_copy(last_emitted_state) or {})
                end
                emit{stage = "prepare", current = 0, total = 1, chapter = clean_book.title or "",
                    message = "正在准备下载"}
                local record = downloader:book(clean_book, clean_options, function(stage, current, total, chapter, detail)
                    detail = detail or {}
                    local percent
                    if stage == "package" then
                        local package_fraction=math.max(0,math.min(1,tonumber(detail.package_fraction) or 0))
                        percent = 0.96 + 0.03 * package_fraction
                    elseif total and total > 0 then
                        local base = (math.max(1, current) - 1) / total
                        local step = 0
                        if stage == "resume" then step = 0.90
                        elseif stage == "content" then step = 0.08
                        elseif stage == "underlines" then step = 0.35
                        elseif stage == "thoughts" then step = 0.55
                        elseif stage == "footnotes" then step = 0.75
                        elseif stage == "images" then step = 0.88 end
                        percent = math.min(0.94, base * 0.94 + step / total)
                    end
                    if stage == "package" then
                        detail.message = detail.message or "正在低内存生成并验证 EPUB"
                    end
                    if percent ~= nil then
                        percent = math.max(last_progress_percent or 0, percent)
                        last_progress_percent = percent
                    end
                    emit{
                        stage = stage,
                        current = current,
                        total = total,
                        chapter = chapter,
                        batch = detail.batch,
                        batch_total = detail.batches,
                        underlines = detail.underlines,
                        thoughts = detail.thoughts,
                        percent = percent,
                        message = detail.message,
                        waiting_network = detail.waiting_network==true or stage=="waiting_network" or nil,
                        network_wait_started_at = detail.network_wait_started_at,
                        network_wait_seconds = detail.network_wait_seconds,
                        activity = detail.activity,
                        transfer_bytes = detail.transfer_bytes,
                        processed = detail.processed,
                        process_total = detail.process_total,
                        package_fraction = detail.package_fraction,
                        package_entry = detail.package_entry,
                        package_entry_bytes = detail.package_entry_bytes,
                        package_entry_size = detail.package_entry_size,
                    }
                end)
                return {
                    record = record,
                    auth = store:auth(),
                    session = store:session(clean_book.bookId),
                }
            end, debug.traceback)

            local payload
            if ok then
                payload = {
                    ok = true,
                    value = serializable_copy(value and value.record),
                    auth = serializable_copy(value and value.auth),
                    auth_snapshot = serializable_copy(auth_snapshot),
                    session = serializable_copy(value and value.session),
                }
                -- Save the same completed payload independently before the
                -- normal result file. The parent can recover from either file
                -- or from the final progress snapshot.
                local recovery_ok,recovery_error=write_json(recovery_path,payload,"recovery")
                emit{stage = "done", current = 1, total = 1, percent = 1,
                    chapter = clean_book.title or "",
                    recovery_result = {ok=true,value=payload.value},
                    recovery_saved = recovery_ok==true, recovery_error = recovery_ok and nil or tostring(recovery_error)}
            else
                local raw_error = tostring(value)
                if raw_error:find("__MIUREAD_HIBERNATE__",1,true) then
                    local request_raw=UChild.read_file(hibernate_path,true)
                    local request_reason="heavy_resource"
                    if request_raw then
                        local decoded_ok,decoded=pcall(JsonChild.decode,request_raw)
                        if decoded_ok and type(decoded)=="table" then request_reason=tostring(decoded.reason or request_reason) end
                    end
                    LoggerChild.info("[MiuRead][DownloadTask] child hibernating",
                        "stage=",tostring(current_stage),"reason=",request_reason)
                    os.remove(pause_ack_path)
                    emit{stage="hibernated",percent=last_progress_percent,chapter=clean_book.title or "",
                        message="为前台释放资源，下载已安全休眠",hibernated=true,hibernate_reason=request_reason}
                    payload={ok=false,hibernated=true,reason=request_reason,stage=current_stage,percent=last_progress_percent}
                else
                    LoggerChild.warn("[MiuRead][DownloadTask] child failed", raw_error)
                    local friendly=display_error(raw_error)
                    emit{stage = UChild.file_exists(cancel_path) and "cancelled" or "error",
                        percent = last_progress_percent, chapter = clean_book.title or "", message = friendly}
                    payload = {ok = false, error = friendly}
                    append_diagnostic("download_failed",raw_error)
                end
            end

            local result_ok,result_error=write_json(result_path,payload,"result")
            if not result_ok then
                append_diagnostic("result_write_failed",result_error)
                if payload.ok==true then
                    emit{stage = "done", current = 1, total = 1, percent = 1,
                        chapter = clean_book.title or "",
                        recovery_result = {ok=true,value=payload.value},
                        result_write_failed = true, message = "正在恢复已完成的下载结果"}
                else
                    emit{stage = "error", percent = last_progress_percent,
                        chapter = clean_book.title or "", message = payload.error, result_write_failed = true}
                end
            end
        end

        local child_ok,child_error=xpcall(run_download,debug.traceback)
        if not child_ok then
            local friendly=display_error(child_error)
            LoggerChild.warn("[MiuRead][DownloadTask] child fatal",tostring(child_error))
            append_diagnostic("child_fatal",child_error)
            write_json(result_path,{ok=false,error=friendly},"emergency_result")
            emit{stage="error",percent=last_progress_percent,chapter=clean_book.title or "",
                message=friendly,fatal=true}
        end
    end

    os.remove(pause_path)
    os.remove(pause_ack_path)
    os.remove(hibernate_path)
    local ok, pid, err = pcall(FFIUtil.runInSubProcess, child, false, false)
    if not ok or not pid then
        os.remove(worker_settings_path)
        os.remove(pause_path)
        os.remove(pause_ack_path)
        os.remove(hibernate_path)
        os.remove(network_path)
        return false, tostring(err or pid or "无法启动下载子进程")
    end

    self.job = {
        pid = pid,
        progress_path = progress_path,
        result_path = result_path,
        recovery_path = recovery_path,
        diagnostic_path = diagnostic_path,
        cancel_path = cancel_path,
        pause_path = pause_path,
        pause_ack_path = pause_ack_path,
        hibernate_path = hibernate_path,
        network_path = network_path,
        network_mode = clean_options.network_mode,
        worker_settings_path = worker_settings_path,
        on_progress = on_progress,
        on_done = on_done,
        last_progress_raw = nil,
        last_progress_state = nil,
        last_progress_at = nil,
        last_effective_progress_at = nil,
        waiting_started_at = nil,
        last_keepalive = 0,
        fail_open_deadline = nil,
        fail_open_done = false,
        dead_seen_at = nil,
        stall_recovery_requested_at = nil,
        stall_suspect_notified = false,
        stall_terminal = false,
        unknown_seen_at = nil,
        waiting_notified = false,
        rechecking_notified = false,
        task_token = task_token,
        restart_count = tonumber(restart_count) or 0,
        stall_restart_count = tonumber(clean_options._stall_restart_count) or 0,
        restart_book = serializable_copy(book),
        restart_options = serializable_copy(clean_options),
        started_at = os.time(),
    }
    self:_claim(pid)
    PseudoLockscreen.set_download_active(self.keep_awake_enabled == true)
    self.pause_reasons={}
    self.backgrounded = false
    self:_hold_awake()
    logger.info("[MiuRead][DownloadTask] started", "pid=", tostring(pid))
    self:_schedule()
    return true
end

return DownloadTask
