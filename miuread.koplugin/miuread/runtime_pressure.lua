local Config=require("miuread.config")
local U=require("miuread.util")
local logger=require("logger")

local RuntimePressure={}
local KEY="__MIUREAD_RUNTIME_PRESSURE"
local state=rawget(_G,KEY)
if type(state)~="table" then
    state={until_at=0,reason=nil,global_until_at=0,global_reason=nil,last_memory=nil,last_memory_at=0,last_log_at=0,manual_enabled=false}
    rawset(_G,KEY,state)
else
    -- Runtime state survives plugin reloads inside one KOReader process. Older
    -- beta state has no global fields, so add them without promoting an old
    -- latency-only window into a downloader throttle.
    state.global_until_at=tonumber(state.global_until_at) or 0
    state.global_reason=state.global_reason
end

local function now()
    return os.time()
end

local function lightweight_flag()
    return tostring(Config.LIGHTWEIGHT_MODE_FLAG or "/tmp/miuread-lightweight-mode.flag")
end

local function cleanup_expired(current)
    current=current or now()
    if (tonumber(state.until_at) or 0)<=current then
        state.until_at=0
        state.reason=nil
    end
    if (tonumber(state.global_until_at) or 0)<=current then
        state.global_until_at=0
        state.global_reason=nil
    end
end

local function global_active(current)
    current=current or now()
    cleanup_expired(current)
    return (tonumber(state.global_until_at) or 0)>current
end

local function sync_flag(manual_enabled)
    state.manual_enabled=manual_enabled==true
    local active_global=global_active(now())
    if state.manual_enabled or active_global then
        U.atomic_write(lightweight_flag(),"1",true)
    else
        os.remove(lightweight_flag())
    end
    return state.manual_enabled or active_global
end

local function parse_meminfo(raw)
    if type(raw)~="string" or raw=="" then return nil end
    local values={}
    for key,value in raw:gmatch("([%w_]+):%s*(%d+)%s*kB") do
        values[key]=tonumber(value)
    end
    local available=values.MemAvailable
    if not available then
        available=(values.MemFree or 0)+(values.Buffers or 0)+(values.Cached or 0)
    end
    if not available or available<=0 then return nil end
    return {
        available_kb=available,
        free_kb=values.MemFree,
        cached_kb=values.Cached,
        total_kb=values.MemTotal,
    }
end

function RuntimePressure.active()
    local current=now()
    cleanup_expired(current)
    local active_local=(tonumber(state.until_at) or 0)>current
    local active_global=(tonumber(state.global_until_at) or 0)>current
    -- A UI-only protection window must never keep a stale global flag alive.
    -- This is what prevents a Home lag sample from slowing the download child.
    if not active_global then sync_flag(state.manual_enabled==true) end
    return active_local or active_global
end

function RuntimePressure.global_active()
    local active=global_active(now())
    if not active then sync_flag(state.manual_enabled==true) end
    return active
end

function RuntimePressure.status()
    local current=now()
    cleanup_expired(current)
    local local_until=tonumber(state.until_at) or 0
    local global_until=tonumber(state.global_until_at) or 0
    local is_global=global_until>current
    local until_at=math.max(local_until,global_until)
    local reason=is_global and state.global_reason or state.reason
    if global_until<=local_until and local_until>current then reason=state.reason end
    return {
        active=until_at>current,
        global=is_global,
        until_at=until_at,
        reason=reason,
        memory=state.last_memory,
    }
end

function RuntimePressure.activate(reason,seconds,scope)
    local duration=math.max(60,tonumber(seconds) or tonumber(Config.PERFORMANCE_AUTO_PROTECT_SECONDS) or 10*60)
    local current=now()
    local target=current+duration
    local text=tostring(reason or "")
    local global=scope=="global"
        or text=="memory_critical" or text=="memory_low"
        or text:find("worker_memory:",1,true)==1
    local was_active=RuntimePressure.active()
    if global then
        if target>(tonumber(state.global_until_at) or 0) then state.global_until_at=target end
        if text~="" then state.global_reason=text end
    else
        if target>(tonumber(state.until_at) or 0) then state.until_at=target end
        if text~="" then state.reason=text end
    end
    sync_flag(state.manual_enabled==true)
    if not was_active or current-(tonumber(state.last_log_at) or 0)>=30 then
        state.last_log_at=current
        local status=RuntimePressure.status()
        logger.warn("[MiuRead][RuntimePressure] temporary protection active",
            "reason=",tostring(text~="" and text or status.reason or "performance"),
            "scope=",global and "global" or "ui",
            "seconds=",tostring(math.max(0,target-current)))
    end
    return true
end

function RuntimePressure.clear(reason,manual_enabled)
    state.until_at=0
    state.reason=nil
    state.global_until_at=0
    state.global_reason=nil
    sync_flag(manual_enabled==true)
    logger.info("[MiuRead][RuntimePressure] temporary protection cleared",tostring(reason or "manual"))
    return true
end

function RuntimePressure.sync_flag(manual_enabled)
    return sync_flag(manual_enabled==true)
end

function RuntimePressure.memory_snapshot(force)
    local current=now()
    local interval=math.max(1,tonumber(Config.BACKGROUND_MEMORY_CHECK_SECONDS) or 3)
    if force~=true and type(state.last_memory)=="table"
        and current-(tonumber(state.last_memory_at) or 0)<interval then
        return state.last_memory
    end
    local raw=U.read_file("/proc/meminfo",true)
    local memory=parse_meminfo(raw)
    state.last_memory_at=current
    if not memory then
        state.last_memory=nil
        return nil
    end
    local fixed_soft=math.max(1,tonumber(Config.BACKGROUND_MEMORY_SOFT_KB) or 64*1024)
    local fixed_critical=math.max(1,tonumber(Config.BACKGROUND_MEMORY_CRITICAL_KB) or 40*1024)
    local total=math.max(0,tonumber(memory.total_kb) or 0)
    local soft_ratio=tonumber(Config.BACKGROUND_MEMORY_SOFT_RATIO) or 0.12
    local critical_ratio=tonumber(Config.BACKGROUND_MEMORY_CRITICAL_RATIO) or 0.08
    local soft_ratio_limit=math.max(fixed_soft,tonumber(Config.BACKGROUND_MEMORY_SOFT_MAX_KB) or 128*1024)
    local critical_ratio_limit=math.max(fixed_critical,tonumber(Config.BACKGROUND_MEMORY_CRITICAL_MAX_KB) or 80*1024)
    local ratio_soft=math.min(soft_ratio_limit,math.floor(total*soft_ratio+.5))
    local ratio_critical=math.min(critical_ratio_limit,math.floor(total*critical_ratio+.5))
    local soft=math.max(fixed_soft,ratio_soft)
    local critical=math.max(fixed_critical,ratio_critical)
    if critical>soft then critical=soft end
    memory.soft_kb=soft
    memory.critical_kb=critical
    memory.level=memory.available_kb<=critical and "critical"
        or (memory.available_kb<=soft and "low" or "normal")
    state.last_memory=memory
    if memory.level=="critical" then
        RuntimePressure.activate("memory_critical",tonumber(Config.PERFORMANCE_MEMORY_PROTECT_SECONDS) or 30*60,"global")
    elseif memory.level=="low" then
        RuntimePressure.activate("memory_low",tonumber(Config.PERFORMANCE_MEMORY_PROTECT_SECONDS) or 30*60,"global")
    end
    return memory
end

function RuntimePressure.note_worker_failure(label,err)
    local text=tostring(err or ""):lower()
    if text:find("cannot allocate memory",1,true)
        or text:find("not enough memory",1,true)
        or text:find("out of memory",1,true)
        or text:find("enomem",1,true) then
        RuntimePressure.activate("worker_memory:"..tostring(label or "unknown"),
            tonumber(Config.PERFORMANCE_MEMORY_PROTECT_SECONDS) or 30*60,"global")
        RuntimePressure.memory_snapshot(true)
        logger.warn("[MiuRead][RuntimePressure] worker allocation failed",
            "label=",tostring(label or "unknown"),"error=",tostring(err or "unknown"))
        return true
    end
    return false
end

return RuntimePressure
