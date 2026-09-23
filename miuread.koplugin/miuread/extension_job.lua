local FFIUtil=require("ffi/util")
local Json=require("miuread.json")
local lfs=require("libs/libkoreader-lfs")
local U=require("miuread.util")
local UIManager=require("ui/uimanager")
local logger=require("logger")
local SubprocessHygiene=require("miuread.subprocess_hygiene")
local Power=require("miuread.pseudo_lockscreen")

local ExtensionJob={}
ExtensionJob.__index=ExtensionJob

local NETWORK_KEY="extension_center_network_v2"
local ROUTE_HEALTH_KEY="extension_route_health_v1"
local ROUTE_HEALTH_TTL=6*60*60
local ACTIVE_STATES={
    downloading=true,waiting_network=true,paused_user=true,paused_power=true,paused_priority=true,
    interrupted=true,verifying=true,extracting=true,installing=true,downloaded=true,
}
local RESUMABLE_STATES={
    waiting_network=true,paused_user=true,paused_power=true,paused_priority=true,interrupted=true,
    cancelled=true,failed=true,downloaded=true,
}

local function trim(value) return U.trim(tostring(value or "")) end
local function command_ok(rc) return rc==true or rc==0 end
local function read_json(path)
    local raw=U.read_file(path,true)
    if not raw or raw=="" then return nil end
    local ok,value=pcall(Json.decode,raw)
    return ok and type(value)=="table" and value or nil
end
local function write_json(path,value)
    return U.atomic_write(path,Json.encode(type(value)=="table" and value or {}),true)
end
local function process_alive(pid)
    pid=tonumber(pid)
    return pid and pid>1 and command_ok(os.execute("kill -0 "..tostring(math.floor(pid)).." >/dev/null 2>&1")) or false
end

local function process_start_ticks(pid)
    pid=tonumber(pid)
    if not pid or pid<=1 then return nil end
    local raw=U.read_file("/proc/"..tostring(math.floor(pid)).."/stat",true) or ""
    local rest=raw:match("^%d+ %b() (.+)$")
    if not rest then return nil end
    local index=0
    for token in rest:gmatch("%S+") do
        index=index+1
        -- /proc/<pid>/stat field 22 (starttime); rest begins at field 3.
        if index==20 then return tostring(token) end
    end
    return nil
end

local function safe_kill_owned_worker(owner)
    owner=type(owner)=="table" and owner or {}
    local pid=tonumber(owner.worker_pid)
    local expected=tostring(owner.worker_start_ticks or "")
    if not pid or pid<=1 or expected=="" or not process_alive(pid) then return false end
    local actual=process_start_ticks(pid)
    if actual~=expected then
        logger.warn("[MiuRead][ExtensionJob] stale worker pid reused; not killed","pid=",tostring(pid))
        return false
    end
    os.execute("kill "..tostring(math.floor(pid)).." >/dev/null 2>&1")
    return true
end
local function safe_kill_transport(task_dir)
    local pid=tonumber(trim(U.read_file(task_dir.."/transport.pid",true) or ""))
    if not pid or pid<=1 or not process_alive(pid) then return false end
    local cmdline=U.read_file("/proc/"..tostring(math.floor(pid)).."/cmdline",true) or ""
    cmdline=cmdline:gsub("%z"," ")
    -- Never kill an unrelated reused PID. A MiuRead curl worker command line
    -- contains the task directory because -o points inside it.
    if not cmdline:find(task_dir,1,true) then
        logger.warn("[MiuRead][ExtensionJob] stale transport pid not owned","pid=",tostring(pid))
        return false
    end
    os.execute("kill "..tostring(math.floor(pid)).." >/dev/null 2>&1")
    return true
end
local function valid_dir(path)
    return path and path~="" and U.mkdir(path) and true or false
end
local function path_exists(path)
    return path and path~="" and lfs.attributes(path,"mode")~=nil
end

local function recover_install_journal(task_dir)
    local journal_path=tostring(task_dir or "").."/install-journal.json"
    local journal=read_json(journal_path)
    if type(journal)~="table" then return false end
    local target=tostring(journal.target or "")
    local old_path=tostring(journal.old_path or "")
    local new_path=tostring(journal.new_path or "")
    local phase=tostring(journal.phase or "")
    local recovered=false
    if target~="" and old_path~="" and path_exists(old_path) and not path_exists(target) then
        local ok=os.rename(old_path,target)
        if not ok then
            local copied=U.copy_tree(old_path,target)
            if copied then U.remove_tree(old_path); ok=true end
        end
        recovered=ok and true or false
    end
    if target~="" and path_exists(target) then
        if new_path~="" and new_path~=target then U.remove_tree(new_path) end
        if old_path~="" and old_path~=target then U.remove_tree(old_path) end
        recovered=true
    elseif target~="" and (old_path=="" or not path_exists(old_path)) and new_path~="" and path_exists(new_path) then
        -- Fresh install interrupted before the final rename: discard the staged
        -- copy. There is no old plugin to restore and no usable target yet.
        U.remove_tree(new_path)
        recovered=true
    end
    os.remove(journal_path)
    logger.warn("[MiuRead][ExtensionJob] install journal recovered",
        "phase=",phase,"target=",target,"recovered=",tostring(recovered))
    return recovered
end

local function network_connected()
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr then return true end
    if type(NetworkMgr.queryNetworkState)=="function" then pcall(NetworkMgr.queryNetworkState,NetworkMgr) end
    local connected=nil
    if type(NetworkMgr.isConnected)=="function" then
        local ok,value=pcall(NetworkMgr.isConnected,NetworkMgr)
        if ok then connected=value==true end
    end
    if connected==false then return false end
    -- This gate runs on UI timers; the worker checks Internet reachability.
    if connected~=nil then return connected==true end
    if type(NetworkMgr.isWifiOn)=="function" then
        local ok,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
        if ok then return value==true end
    end
    return true
end

function ExtensionJob:new(store)
    local root=tostring(store and store.data_dir or "").."/extensions/tasks"
    U.mkdir(tostring(store and store.data_dir or "").."/extensions")
    U.mkdir(root)
    local o=setmetatable({
        store=store,root=root,session=tostring(os.time()).."-"..tostring(math.random(100000,999999)),
        current=nil,worker_pid=nil,poll_task=nil,network_retry_task=nil,network_ready_since=nil,on_progress=nil,on_done=nil,
        resume_generation=0,last_progress_signature=nil,transient_retry_count=0,
    },self)
    o:_startup_reap()
    o:_adopt_latest_active()
    if o.current and (o.current.state=="waiting_network" or o.current.state=="paused_power") then o:_schedule_network_retry(2.5) end
    return o
end

function ExtensionJob:_task_path(task) return tostring(task and task.task_dir or "").."/task.json" end
function ExtensionJob:_save(task)
    if type(task)~="table" or trim(task.task_dir)=="" then return false end
    task.updated_at=os.time()
    U.mkdir(task.task_dir)
    return write_json(self:_task_path(task),task)
end

function ExtensionJob:_load_dir(path)
    local task=read_json(path.."/task.json")
    if type(task)=="table" then task.task_dir=path end
    return task
end

function ExtensionJob:list_tasks(include_completed)
    local out={}
    for _,path in ipairs(U.list(self.root)) do
        local task=self:_load_dir(path)
        if task and (include_completed==true or ACTIVE_STATES[tostring(task.state or "")]) then out[#out+1]=task end
    end
    table.sort(out,function(a,b) return (tonumber(a.updated_at) or 0)>(tonumber(b.updated_at) or 0) end)
    return out
end

function ExtensionJob:_startup_reap()
    local now=os.time()
    for _,path in ipairs(U.list(self.root)) do
        local task=self:_load_dir(path)
        if task then
            local state=tostring(task.state or "")
            local owner=read_json(path.."/owner.json") or {}
            if state=="downloading" or state=="verifying" or state=="extracting" then
                safe_kill_transport(path)
                safe_kill_owned_worker(owner)
                task.state="interrupted"
                task.message="KOReader 上次退出时任务被中断，下载数据已保留"
                task.interrupted_at=now
                task.worker_pid=nil
                self:_save(task)
                os.remove(path.."/owner.json")
                logger.warn("[MiuRead][ExtensionJob] stale task reaped","task=",tostring(task.task_id),"owner_session=",tostring(owner.session or "-"))
            elseif state=="paused_priority" then
                -- A cloud-sync priority pause cannot survive a KOReader restart:
                -- the sync owner is gone, so convert it into an automatically
                -- resumable network wait instead of stranding the plugin task.
                task.state="waiting_network"; task.stage="waiting_network"
                task.message="上次阅读数据同步已结束，准备继续插件下载"
                task.worker_pid=nil
                self:_save(task)
                os.remove(path.."/owner.json")
            elseif state=="installing" then
                safe_kill_transport(path)
                safe_kill_owned_worker(owner)
                local recovered=recover_install_journal(path)
                task.state="failed"; task.stage="error"
                task.error_kind="install_interrupted"
                task.error=recovered and "上次安装被中断，已恢复可用插件" or "上次安装被中断"
                task.message=task.error
                task.worker_pid=nil
                self:_save(task)
                os.remove(path.."/owner.json")
            elseif (state=="completed" or state=="failed" or state=="cancelled") and now-(tonumber(task.updated_at) or now)>7*24*60*60 then
                -- Keep a short recent history in the download centre, but not forever.
                U.remove_tree(path)
            end
        end
    end
end

function ExtensionJob:_adopt_latest_active()
    local list=self:list_tasks(false)
    if #list>0 then self.current=list[1] end
end

function ExtensionJob:snapshot()
    if self.current and trim(self.current.task_dir)~="" then
        local fresh=self:_load_dir(self.current.task_dir)
        if fresh then self.current=fresh end
    end
    return self.current and U.copy(self.current) or nil
end

function ExtensionJob:busy()
    return self.worker_pid~=nil or (self.current and ACTIVE_STATES[tostring(self.current.state or "")]==true) or false
end

function ExtensionJob:running()
    return self.worker_pid~=nil and self.current and self.current.state=="downloading" or false
end

function ExtensionJob:can_continue_locked()
    if self:running() then return true,"extension_download_active" end
    local state=self.current and tostring(self.current.state or "") or ""
    -- Verification/extraction/install are short local critical sections. On
    -- Kindle they may finish under the same screen-saver hold even though no
    -- network transport is running; Kobo/Android are still paused by main.lua's
    -- platform gate.
    if state=="verifying" or state=="extracting" or state=="installing" then
        return true,"extension_install_finish"
    end
    return false,state~="" and state or "no_extension_task"
end

function ExtensionJob:_power_active(value)
    pcall(Power.set_task_active,"extension_download",value==true)
    if value~=true then pcall(Power.background_task_done,"extension_download_done") end
end

function ExtensionJob:_cancel_network_retry()
    if self.network_retry_task then UIManager:unschedule(self.network_retry_task); self.network_retry_task=nil end
    self.network_ready_since=nil
end

function ExtensionJob:_schedule_network_retry(delay)
    if self.network_retry_task or self.worker_pid or not self.current then return end
    local state=tostring(self.current.state or "")
    if state~="waiting_network" and state~="paused_power" then return end
    local generation=self.resume_generation
    local callback
    callback=function()
        if self.network_retry_task~=callback then return end
        self.network_retry_task=nil
        if generation~=self.resume_generation or self.worker_pid or not self.current then return end
        local current_state=tostring(self.current.state or "")
        if current_state~="waiting_network" and current_state~="paused_power" then self.network_ready_since=nil; return end
        if network_connected() then
            local stamp=os.time()
            if not self.network_ready_since then
                self.network_ready_since=stamp
                self:_schedule_network_retry(2.2)
                return
            end
            if stamp-self.network_ready_since>=2 then
                self.network_ready_since=nil
                self:resume("network_ready")
                return
            end
            self:_schedule_network_retry(1.2)
            return
        end
        self.network_ready_since=nil
        self:_schedule_network_retry(5.0)
    end
    self.network_retry_task=callback
    UIManager:scheduleIn(tonumber(delay) or 4.0,callback)
end

function ExtensionJob:_kill_worker(reason)
    self:_cancel_network_retry()
    safe_kill_transport(self.current and self.current.task_dir or "")
    if self.worker_pid then pcall(FFIUtil.terminateSubProcess,self.worker_pid) end
    self.worker_pid=nil
    if self.poll_task then UIManager:unschedule(self.poll_task); self.poll_task=nil end
    self:_power_active(false)
    logger.info("[MiuRead][ExtensionJob] worker stopped","reason=",tostring(reason or "unknown"))
end

function ExtensionJob:_network_settings()
    local value=self.store:get(NETWORK_KEY,{mode="auto",custom_prefix=""})
    value=type(value)=="table" and value or {mode="auto",custom_prefix=""}
    local health=self.store:get(ROUTE_HEALTH_KEY,{})
    health=type(health)=="table" and health or {}
    local updated=tonumber(health.updated_at) or 0
    local preferred=(os.time()-updated)<=ROUTE_HEALTH_TTL and tostring(health.route_key or "") or ""
    return {
        mode=tostring(value.mode or "auto"),custom_prefix=tostring(value.custom_prefix or ""),
        preferred_route_key=preferred,
    }
end

function ExtensionJob:_remember_route_health(route_key)
    route_key=trim(route_key)
    if route_key=="" or route_key=="cached" then return false end
    self.store:set_deferred(ROUTE_HEALTH_KEY,{route_key=route_key,updated_at=os.time()})
    self.store:flush()
    return true
end

function ExtensionJob:_emit_progress(force)
    local task=self:snapshot()
    if not task then return end
    local progress=read_json(task.task_dir.."/progress.json") or {}
    for k,v in pairs(progress) do task[k]=v end
    task.kind="extension"
    task.repo=task.repo or (self.current and self.current.repo)
    task.name=task.name or (self.current and self.current.name)
    task.version=task.version or (self.current and self.current.version)
    if self.current then
        for _,key in ipairs({"task_id","task_dir","repo","name","version","source_url","size","sha256","used_url","route_key"}) do
            if self.current[key]~=nil and progress[key]==nil then task[key]=self.current[key] end
        end
        -- progress.json is transport telemetry; task.json is authoritative for
        -- lifecycle phases. Otherwise stale "downloading" telemetry would mask
        -- WAIT_NETWORK / VERIFY / EXTRACT / INSTALL states after the transfer.
        task.state=tostring(self.current.state or task.state or "")
        task.stage=tostring(self.current.stage or task.stage or task.state or "")
        task.message=tostring(self.current.message or task.message or "")
    end
    local sig=table.concat({tostring(task.state),tostring(task.stage),tostring(task.downloaded_bytes),tostring(task.speed_bps),tostring(task.message)},"|")
    if force or sig~=self.last_progress_signature then
        self.last_progress_signature=sig
        if type(self.on_progress)=="function" then pcall(self.on_progress,U.copy(task)) end
    end
end

function ExtensionJob:_schedule_poll()
    if self.poll_task or not self.worker_pid then return end
    local task
    task=function()
        if self.poll_task~=task then return end
        self.poll_task=nil
        self:_poll()
    end
    self.poll_task=task
    UIManager:scheduleIn(.55,task)
end

function ExtensionJob:_poll()
    if not self.worker_pid or not self.current then return end
    self:_emit_progress(false)
    local ok,done=pcall(FFIUtil.isSubProcessDone,self.worker_pid,false)
    if ok and done~=true then self:_schedule_poll(); return end
    if not ok then
        logger.warn("[MiuRead][ExtensionJob] worker status check failed",tostring(done))
        self:_schedule_poll(); return
    end

    local task=self.current
    local result=read_json(task.task_dir.."/result.json")
    self.worker_pid=nil
    os.remove(task.task_dir.."/owner.json")
    self:_power_active(false)
    if type(result)~="table" then result={ok=false,error="扩展下载进程没有返回结果",kind="interrupted"} end

    if result.ok==true and result.path then
        self.transient_retry_count=0
        task.transient_retry_count=0
        task.state="downloaded"; task.stage="downloaded"; task.package_path=result.path
        task.downloaded_bytes=tonumber(result.bytes) or U.file_size(result.path) or 0
        task.total_bytes=tonumber(task.size) or 0
        task.percent=task.total_bytes>0 and math.min(1,task.downloaded_bytes/task.total_bytes) or 1
        task.used_url=tostring(result.used_url or result.route_url or task.source_url or "")
        task.route_key=tostring(result.route_key or "")
        task.transport=tostring(result.transport or "")
        self:_remember_route_health(task.route_key)
        task.message="下载并校验完成，准备安装"
        self:_save(task); self.current=task; self:_emit_progress(true)
        local done_cb=self.on_done
        if type(done_cb)=="function" then
            local cb_ok,cb_err=pcall(done_cb,U.copy(result),nil,U.copy(task))
            if not cb_ok then
                logger.warn("[MiuRead][ExtensionJob] completion callback failed; package remains ready for retry",tostring(cb_err))
            end
        end
        return
    end

    task.error=tostring(result.error or "下载失败")
    task.error_kind=tostring(result.kind or "transport_error")
    local partial_bytes=tonumber(result.partial_bytes)
    if partial_bytes==nil then
        partial_bytes=0
        for _,path in ipairs(U.list(task.task_dir)) do
            if tostring(path):match("source%-.+%.part$") then
                partial_bytes=math.max(partial_bytes,U.file_size(path) or 0)
            end
        end
    end
    task.downloaded_bytes=partial_bytes
    if result.waiting_network==true then
        task.state="waiting_network"; task.stage="waiting_network"
        task.message=task.downloaded_bytes>0 and "下载暂时中断，断点已保留，稍后自动继续" or "等待可用下载线路"
        self.transient_retry_count=math.min(8,(tonumber(task.transient_retry_count) or tonumber(self.transient_retry_count) or 0)+1)
        task.transient_retry_count=self.transient_retry_count
        local Config=require("miuread.config")
        local base=math.max(4,tonumber(Config.EXTENSION_RETRY_BASE_SECONDS) or 10)
        local ceiling=math.max(base,tonumber(Config.EXTENSION_RETRY_MAX_SECONDS) or 60)
        local delay=math.min(ceiling,base*(2^math.max(0,self.transient_retry_count-1)))
        self:_save(task); self.current=task; self:_emit_progress(true)
        self:_schedule_network_retry(delay)
        return
    end
    task.state="failed"; task.stage="error"; task.message="下载未完成"
    self:_save(task); self.current=task; self:_emit_progress(true)
    local done_cb=self.on_done
    if type(done_cb)=="function" then
        local cb_ok,cb_err=pcall(done_cb,nil,task.error,U.copy(task),result)
        if not cb_ok then logger.warn("[MiuRead][ExtensionJob] failure callback failed",tostring(cb_err)) end
    end
end

function ExtensionJob:_find_resumable(spec)
    local repo=tostring(spec.repo or "")
    local version=tostring(spec.version or "")
    for _,task in ipairs(self:list_tasks(true)) do
        local same_identity=tostring(task.source_url or "")==tostring(spec.url or "")
            and tostring(task.sha256 or ""):lower()==tostring(spec.sha256 or ""):lower()
            and (tonumber(task.size) or 0)==(tonumber(spec.size) or 0)
        if tostring(task.repo or "")==repo and tostring(task.version or "")==version
            and same_identity and RESUMABLE_STATES[tostring(task.state or "")]==true then
            local package=U.file_size(task.task_dir.."/package.zip") or 0
            local partial=0
            for _,path in ipairs(U.list(task.task_dir)) do
                if tostring(path):match("source%-.+%.part$") then partial=math.max(partial,U.file_size(path) or 0) end
            end
            if partial>0 or package>0 or tostring(task.state or "")=="waiting_network"
                or tostring(task.state or "")=="paused_power" then return task end
        end
    end
end

function ExtensionJob:_spawn(task,spec)
    if self.worker_pid then return false,"已有插件下载进程正在运行" end
    if not valid_dir(task.task_dir) then return false,"无法创建插件下载目录" end
    -- A fully downloaded package can be revalidated and installed entirely
    -- offline. Do not gate that path on Wi-Fi after a restart or when the user
    -- explicitly chooses “继续安装”. The downloader will verify package.zip
    -- again before returning it to the installer.
    local has_local_package=U.file_exists(task.task_dir.."/package.zip")
    if not has_local_package and not network_connected() then
        task.state="waiting_network"; task.stage="waiting_network"
        task.message="等待网络连接"
        task.spec=U.copy(spec)
        self:_save(task); self.current=task; self:_emit_progress(true)
        self:_schedule_network_retry(3.0)
        return true
    end
    self:_cancel_network_retry()
    os.remove(task.task_dir.."/result.json")
    task.state="downloading"; task.stage="download"; task.message="正在下载"
    task.started_at=tonumber(task.started_at) or os.time(); task.updated_at=os.time()
    task.source_url=tostring(spec.url or task.source_url or "")
    task.size=tonumber(spec.size or task.size) or 0
    task.sha256=tostring(spec.sha256 or task.sha256 or "")
    task.spec=U.copy(spec)
    self:_save(task)
    self.current=task

    local store=self.store
    local task_dir=task.task_dir
    local child_spec=U.copy(spec)
    child_spec.network=self:_network_settings()
    local child_config=require("miuread.config")
    child_spec.mirrors=U.copy(child_config.GITHUB_MIRRORS or {})
    child_spec.routes=U.copy(child_config.EXTENSION_DOWNLOAD_ROUTES or {})
    local child=function()
        SubprocessHygiene.close_inherited_sockets()
        U.mkdir(task_dir)
        local Download=require("miuread.extension_download")
        local ok,value=pcall(Download.run,store,task_dir,child_spec)
        local result=ok and value or {ok=false,error=tostring(value),kind="worker_error"}
        write_json(task_dir.."/result.json",result)
    end
    local ok,pid,err=pcall(FFIUtil.runInSubProcess,child,false,false)
    if not ok or not pid then
        task.state="failed"; task.error=tostring(err or pid or "worker unavailable"); task.error_kind="worker"
        self:_save(task); self.current=task
        return false,task.error
    end
    self.worker_pid=pid
    task.worker_pid=pid
    self:_save(task)
    write_json(task.task_dir.."/owner.json",{
        task_id=task.task_id,session=self.session,worker_pid=pid,
        worker_start_ticks=process_start_ticks(pid),started_at=os.time(),
    })
    self:_power_active(true)
    logger.info("[MiuRead][ExtensionJob] started","task=",tostring(task.task_id),"pid=",tostring(pid),"repo=",tostring(task.repo))
    self:_emit_progress(true)
    self:_schedule_poll()
    return true
end

function ExtensionJob:start(spec,on_progress,on_done)
    spec=type(spec)=="table" and spec or {}
    if trim(spec.url)=="" then return false,"插件安装包地址为空" end
    if self:busy() and not (self.current and RESUMABLE_STATES[tostring(self.current.state or "")]) then
        return false,"已有插件下载任务正在进行"
    end
    if self.worker_pid then return false,"已有插件下载任务正在进行" end

    local task=self:_find_resumable(spec)
    if not task then
        local id="ext-"..U.id_name(spec.repo or spec.name or "plugin").."-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))
        local dir=self.root.."/"..id
        U.mkdir(dir)
        task={
            task_id=id,task_dir=dir,kind="extension",repo=tostring(spec.repo or ""),name=tostring(spec.name or spec.repo or "扩展"),
            version=tostring(spec.version or ""),state="queued",stage="prepare",source_url=tostring(spec.url),
            size=tonumber(spec.size) or 0,sha256=tostring(spec.sha256 or ""),created_at=os.time(),updated_at=os.time(),
            deterministic=true,allow_missing_sha=spec.allow_missing_sha==true,
            asset_name=tostring(spec.asset_name or ""),expected_dir=tostring(spec.expected_dir or ""),
            layout=tostring(spec.layout or ""),source=tostring(spec.source or ""),channel=tostring(spec.channel or ""),
            remote_ref=tostring(spec.remote_ref or ""),transient_retry_count=0,
        }
    else
        task.message="继续上次下载"; task.error=nil; task.error_kind=nil
    end
    self.on_progress=on_progress
    self.on_done=on_done
    self.current=task
    return self:_spawn(task,spec)
end

function ExtensionJob:set_callbacks(on_progress,on_done)
    self.on_progress=on_progress; self.on_done=on_done
end

function ExtensionJob:activate(task)
    if self.worker_pid then return false,"已有插件下载进程正在运行" end
    if type(task)~="table" or trim(task.task_dir)=="" then return false,"插件下载任务无效" end
    local fresh=self:_load_dir(task.task_dir)
    if not fresh then return false,"插件下载任务已经不存在" end
    self.current=fresh
    self.last_progress_signature=nil
    return true
end

function ExtensionJob:set_phase(state,message,extra)
    local task=self.current
    if not task then return false end
    task.state=tostring(state or task.state)
    task.stage=task.state
    task.message=tostring(message or task.message or "")
    for k,v in pairs(type(extra)=="table" and extra or {}) do task[k]=v end
    self:_save(task); self.current=task; self:_emit_progress(true)
    return true
end

function ExtensionJob:complete_install(extra)
    local task=self.current
    if not task then return false end
    task.state="completed"; task.stage="done"; task.message="安装完成"
    task.completed_at=os.time(); task.percent=1
    for k,v in pairs(type(extra)=="table" and extra or {}) do task[k]=v end
    self:_save(task); self.current=task; self:_emit_progress(true)
    self:_power_active(false)
    return true
end

function ExtensionJob:fail_install(message,kind)
    local task=self.current
    if not task then return false end
    task.state="failed"; task.stage="error"; task.error=tostring(message or "安装失败")
    task.error_kind=tostring(kind or "install"); task.message="安装失败"
    self:_save(task); self.current=task; self:_emit_progress(true)
    self:_power_active(false)
    return true
end

function ExtensionJob:pause(reason)
    local task=self.current
    if not task then return false,"没有插件下载任务" end
    reason=tostring(reason or "manual")
    self:_kill_worker(reason.."_pause")
    if reason=="power" then
        task.state="paused_power"
        task.message="设备休眠，唤醒联网后自动继续"
    elseif reason=="sync_priority" or reason=="cloud_sync_priority" then
        task.state="paused_priority"
        task.message="阅读数据正在同步，插件下载已保存断点并让路"
    else
        task.state="paused_user"
        task.message="下载已暂停，断点已保留"
    end
    task.stage=task.state
    task.worker_pid=nil
    self:_save(task); self.current=task; self:_emit_progress(true)
    if reason=="power" then self:_schedule_network_retry(3.0) end
    return true
end

function ExtensionJob:cancel()
    local task=self.current
    if not task then return false,"没有插件下载任务" end
    self:_kill_worker("user_cancel")
    task.state="cancelled"; task.stage="cancelled"; task.message="下载已取消，后台不会自动恢复"
    task.worker_pid=nil
    self:_save(task); self.current=task; self:_emit_progress(true)
    return true
end

function ExtensionJob:delete_data(task)
    task=type(task)=="table" and task or self.current
    if not task then return false,"没有插件下载任务" end
    if self.current and task.task_id==self.current.task_id then
        self.resume_generation=self.resume_generation+1
        self:_kill_worker("delete_data")
        self.current=nil
    end
    local removed,err=U.remove_tree(task.task_dir)
    logger.info("[MiuRead][ExtensionJob] data deleted","task=",tostring(task.task_id),"ok=",tostring(removed~=nil),"error=",tostring(err or ""))
    return removed~=nil,err
end

function ExtensionJob:resume(reason)
    local task=self.current
    if not task then return false,"没有插件下载任务" end
    if self.worker_pid then return true end
    if not RESUMABLE_STATES[tostring(task.state or "")] then return false,"当前任务状态不支持继续" end
    local spec=type(task.spec)=="table" and task.spec or {
        repo=task.repo,name=task.name,version=task.version,url=task.source_url,size=task.size,sha256=task.sha256,
        deterministic=task.deterministic,allow_missing_sha=task.allow_missing_sha==true,
        asset_name=task.asset_name,expected_dir=task.expected_dir,layout=task.layout,source=task.source,
        channel=task.channel,remote_ref=task.remote_ref,
    }
    task.message="正在继续下载"
    logger.info("[MiuRead][ExtensionJob] resume","reason=",tostring(reason or "manual"),"task=",tostring(task.task_id))
    return self:_spawn(task,spec)
end

function ExtensionJob:on_suspend(mode)
    mode=tostring(mode or "REAL_SUSPEND")
    if not self.current then return true end
    if mode=="SCREEN_SAVER_HOLD" or mode=="PSEUDO_LOCKED" or mode=="DOWNLOAD_LOCKED" then
        logger.info("[MiuRead][ExtensionJob] screen-off transfer retained","mode=",mode,"running=",tostring(self:running()))
        return true
    end
    if self:running() then self:pause("power") end
    return true
end

function ExtensionJob:on_resume()
    local task=self.current
    if not task or (task.state~="paused_power" and task.state~="waiting_network") then return false end
    self.resume_generation=self.resume_generation+1
    self:_cancel_network_retry()
    self:_schedule_network_retry(1.0)
    return true
end

function ExtensionJob:on_user_resume_begin()
    self:_power_active(false)
    return true
end

function ExtensionJob:quiesce_for_exit(reason)
    if not self.current then return true end
    if self.worker_pid then self:_kill_worker("exit:"..tostring(reason or "unknown")) end
    local state=tostring(self.current.state or "")
    if state=="downloading" or state=="paused_power" or state=="waiting_network" or state=="paused_user" then
        self.current.state="interrupted"; self.current.stage="interrupted"
        self.current.message="KOReader 已退出，断点已保留，可稍后继续"
        self.current.worker_pid=nil
        self:_save(self.current); self:_emit_progress(true)
    end
    return true
end

return ExtensionJob
