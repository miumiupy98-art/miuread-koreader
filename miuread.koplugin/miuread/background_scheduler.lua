local Config=require("miuread.config")
local RuntimePressure=require("miuread.runtime_pressure")
local UIManager=require("ui/uimanager")
local logger=require("logger")
local ok_socket,socket=pcall(require,"socket")

local Scheduler={}
Scheduler.__index=Scheduler

local function monotonic()
    if ok_socket and socket and type(socket.gettime)=="function" then return socket.gettime() end
    return os.time()
end

function Scheduler:new()
    return setmetatable({
        active=nil,
        token=0,
        pending={},
        parked={},
        pump_task=nil,
        last_defer_log={},
        foreground_barrier_until=0,
        foreground_barrier_reason=nil,
        last_barrier_log=0,
    },self)
end

function Scheduler:snapshot()
    local active=self.active
    local pending=0
    for _ in pairs(self.pending or {}) do pending=pending+1 end
    local parked=0
    for _ in pairs(self.parked or {}) do parked=parked+1 end
    local barrier_ms=math.max(0,math.floor(((tonumber(self.foreground_barrier_until) or 0)-monotonic())*1000+.5))
    return {
        active=active and active.key or nil,
        active_user=active and active.user_requested==true or false,
        active_ms=active and math.floor((monotonic()-(active.started or monotonic()))*1000+.5) or 0,
        pending=pending,
        parked=parked,
        foreground_barrier_ms=barrier_ms,
        foreground_barrier_reason=barrier_ms>0 and self.foreground_barrier_reason or nil,
    }
end

function Scheduler:foreground_barrier_active()
    local until_at=tonumber(self.foreground_barrier_until) or 0
    if until_at<=monotonic() then
        self.foreground_barrier_until=0
        self.foreground_barrier_reason=nil
        return false
    end
    return true
end

function Scheduler:set_foreground_barrier(seconds,reason)
    local duration=math.max(.15,tonumber(seconds) or 0)
    local until_at=monotonic()+duration
    if until_at>(tonumber(self.foreground_barrier_until) or 0) then
        self.foreground_barrier_until=until_at
        self.foreground_barrier_reason=tostring(reason or "foreground interaction")
        local now=monotonic()
        if now-(tonumber(self.last_barrier_log) or 0)>=1.0 then
            self.last_barrier_log=now
            logger.info("[MiuRead][Background] foreground barrier",
                "seconds=",tostring(duration),"reason=",self.foreground_barrier_reason)
        end
    end
    self:_schedule_pump(duration+.05)
    return true
end

function Scheduler:clear_foreground_barrier(reason)
    local active=self:foreground_barrier_active()
    self.foreground_barrier_until=0
    self.foreground_barrier_reason=nil
    if active then logger.info("[MiuRead][Background] foreground barrier cleared",tostring(reason or "manual")) end
    self:_schedule_pump(.05)
    return active
end

function Scheduler:_clear_stale_active()
    local active=self.active
    if not active then return end
    local timeout=math.max(30,tonumber(Config.BACKGROUND_LEASE_TIMEOUT_SECONDS) or 300)
    if monotonic()-(tonumber(active.started) or monotonic())>timeout then
        logger.warn("[MiuRead][Background] stale lease released",
            "key=",tostring(active.key),"seconds=",tostring(timeout))
        self.active=nil
    end
end

function Scheduler:claim(key,options)
    options=options or {}
    key=tostring(key or "background")
    self:_clear_stale_active()
    local blocked=tostring(options.blocked_reason or "")
    if blocked~="" then return nil,blocked end
    if options.user_requested~=true and self:foreground_barrier_active() then
        return nil,"foreground_barrier"
    end

    local memory=RuntimePressure.memory_snapshot(false)
    if options.user_requested~=true then
        if memory and memory.level=="critical" then
            return nil,"memory_critical"
        end
        if options.heavy==true and memory and memory.level=="low" then
            return nil,"memory_low"
        end
        if options.heavy==true and RuntimePressure.active() then
            return nil,"runtime_pressure"
        end
    end

    if self.active then
        return nil,"busy:"..tostring(self.active.key)
    end
    if self.parked then self.parked[key]=nil end
    self.token=(tonumber(self.token) or 0)+1
    local token=self.token
    self.active={
        key=key,token=token,started=monotonic(),
        user_requested=options.user_requested==true,
    }
    logger.info("[MiuRead][Background] start",
        "key=",key,
        "user=",tostring(options.user_requested==true),
        "memory_kb=",tostring(memory and memory.available_kb or "unknown"),
        "pressure=",tostring(RuntimePressure.active()))
    return token
end

function Scheduler:release(key,token,reason)
    local active=self.active
    if not active then return false end
    if token~=nil and tonumber(token)~=tonumber(active.token) then return false end
    if key~=nil and tostring(key)~=tostring(active.key) then return false end
    local elapsed=math.floor((monotonic()-(active.started or monotonic()))*1000+.5)
    self.active=nil
    logger.info("[MiuRead][Background] done",
        "key=",tostring(active.key),"elapsed_ms=",tostring(elapsed),
        "reason=",tostring(reason or "completed"))
    self:_schedule_pump(tonumber(Config.BACKGROUND_SERIAL_GAP_SECONDS) or .35)
    return true
end

function Scheduler:force_release(reason)
    local active=self.active
    if not active then return false end
    self.active=nil
    logger.info("[MiuRead][Background] cancelled",
        "key=",tostring(active.key),"reason=",tostring(reason or "cancelled"))
    self:_schedule_pump(tonumber(Config.BACKGROUND_SERIAL_GAP_SECONDS) or .35)
    return true
end

function Scheduler:park(key,callback,options)
    if type(callback)~="function" then return false end
    options=options or {}
    key=tostring(key or "background")
    self.parked=type(self.parked)=="table" and self.parked or {}
    local current=self.parked[key]
    local priority=tonumber(options.priority) or 10
    self.parked[key]={key=key,callback=callback,priority=priority,reason=tostring(options.reason or "blocked"),parked_at=monotonic()}
    -- A parked task deliberately owns no timer. Log only on state/reason change.
    if not current or tostring(current.reason or "")~=tostring(options.reason or "") then
        logger.info("[MiuRead][Background] parked","key=",key,"reason=",tostring(options.reason or "blocked"))
    end
    return true
end

function Scheduler:wake_parked(reason,key)
    self.parked=type(self.parked)=="table" and self.parked or {}
    local moved=0
    for id,item in pairs(self.parked) do
        if key==nil or tostring(key)==tostring(id) then
            self.parked[id]=nil
            self.pending[id]={key=id,callback=item.callback,priority=tonumber(item.priority) or 10,due=monotonic()}
            moved=moved+1
        end
    end
    if moved>0 then
        logger.info("[MiuRead][Background] parked tasks woken","count=",tostring(moved),"reason=",tostring(reason or "event"))
        self:_schedule_pump(.05)
    end
    return moved
end

function Scheduler:defer(key,callback,options)
    if type(callback)~="function" then return false end
    options=options or {}
    key=tostring(key or "background")
    if self.parked then self.parked[key]=nil end
    local due=monotonic()+math.max(.15,tonumber(options.delay) or tonumber(Config.BACKGROUND_RETRY_SECONDS) or .9)
    local current=self.pending[key]
    local priority=tonumber(options.priority) or 10
    if options.force_timer~=true and priority<80 and RuntimePressure.active() then
        return self:park(key,callback,{priority=priority,reason="runtime_pressure:"..tostring(options.reason or "deferred")})
    end
    if not current or priority>=tonumber(current.priority or 0) then
        self.pending[key]={key=key,callback=callback,priority=priority,due=due}
    elseif due<(tonumber(current.due) or due) then
        current.due=due
    end
    local now=monotonic()
    local log_key=key..":"..tostring(options.reason or "busy")
    if now-(tonumber(self.last_defer_log[log_key]) or 0)>4 then
        self.last_defer_log[log_key]=now
        logger.info("[MiuRead][Background] deferred",
            "key=",key,"reason=",tostring(options.reason or "busy"))
    end
    self:_schedule_pump(.2)
    return true
end

function Scheduler:_next_pending()
    local now=monotonic()
    local best
    for key,item in pairs(self.pending or {}) do
        if (tonumber(item.due) or 0)<=now then
            if not best or tonumber(item.priority or 0)>tonumber(best.priority or 0)
                or (tonumber(item.priority or 0)==tonumber(best.priority or 0)
                    and tostring(key)<tostring(best.key)) then
                best=item
            end
        end
    end
    return best
end

function Scheduler:_schedule_pump(delay)
    if self.pump_task then return end
    local task
    task=function()
        if self.pump_task~=task then return end
        self.pump_task=nil
        self:_clear_stale_active()
        if self.active then
            -- release()/force_release() owns the next wake. Polling every 500ms
            -- while a worker is alive only burns wakeups and never changes state.
            return
        end
        if self:foreground_barrier_active() then
            local remain=math.max(.15,(tonumber(self.foreground_barrier_until) or monotonic())-monotonic()+.05)
            self:_schedule_pump(remain)
            return
        end
        local item=self:_next_pending()
        if not item then
            local soonest
            local now=monotonic()
            for _,pending in pairs(self.pending or {}) do
                local due=tonumber(pending.due) or now+.5
                if not soonest or due<soonest then soonest=due end
            end
            if soonest then self:_schedule_pump(math.max(.15,soonest-now)) end
            return
        end
        self.pending[item.key]=nil
        local ok,err=pcall(item.callback)
        if not ok then
            logger.warn("[MiuRead][Background] deferred callback failed",
                "key=",tostring(item.key),"error=",tostring(err))
        end
    end
    self.pump_task=task
    UIManager:scheduleIn(math.max(.05,tonumber(delay) or .2),task)
end

function Scheduler:cancel_key(key,reason,include_active)
    key=tostring(key or "")
    if key=="" then return false end
    local changed=false
    if self.pending and self.pending[key] then self.pending[key]=nil; changed=true end
    if self.parked and self.parked[key] then self.parked[key]=nil; changed=true end
    if include_active==true and self.active and tostring(self.active.key)==key then
        self:force_release(reason or (key.." cancelled"))
        changed=true
    elseif changed then
        self:_schedule_pump(.05)
    end
    if changed and reason then
        logger.info("[MiuRead][Background] key cancelled","key=",key,"reason=",tostring(reason))
    end
    return changed
end

function Scheduler:cancel_pending(reason)
    self.pending={}
    self.parked={}
    if self.pump_task then UIManager:unschedule(self.pump_task); self.pump_task=nil end
    if reason then logger.info("[MiuRead][Background] pending cleared",tostring(reason)) end
    return true
end

return Scheduler
