local FFIUtil=require("ffi/util")
local Json=require("miuread.json")
local U=require("miuread.util")
local RuntimePressure=require("miuread.runtime_pressure")
local SubprocessHygiene=require("miuread.subprocess_hygiene")
local UIManager=require("ui/uimanager")
local Async={}; Async.__index=Async
function Async:new(store, options)
    options = options or {}
    return setmetatable({
        store=store,job=nil,poll=nil,
        poll_interval=tonumber(options.poll_interval) or .25,
        allow_android=options.allow_android==true,
        defer_fallback=options.defer_fallback==true,
        disable_fallback=options.disable_fallback==true,
        fallback_delay=tonumber(options.fallback_delay) or .1,
    },self)
end
function Async:is_android()
    return type(FFIUtil.isAndroid)=="function" and FFIUtil.isAndroid()==true
end
function Async:available()
    local android=self:is_android()
    return type(FFIUtil.runInSubProcess)=="function"
        and type(FFIUtil.isSubProcessDone)=="function"
        and (self.allow_android or not android)
end
function Async:busy() return self.job~=nil end
function Async:_schedule()
    if self.poll then return end; local task; task=function() if self.poll~=task then return end; self.poll=nil; self:_check() end; self.poll=task; UIManager:scheduleIn(self.poll_interval,task)
end
function Async:_check()
    local j=self.job; if not j then return end
    -- timeout <= 0 means the caller intentionally has no absolute wall-clock
    -- deadline. Long extension downloads still have transport-level connect and
    -- stall detection, so a large but healthy package is not killed mid-transfer.
    if tonumber(j.timeout) and tonumber(j.timeout)>0 and os.time()-j.started>tonumber(j.timeout) then
        pcall(FFIUtil.terminateSubProcess,j.pid); j.timedout=true
    end
    local ok,done=pcall(FFIUtil.isSubProcessDone,j.pid,false); if ok and not done and not j.timedout then self:_schedule(); return end
    local raw=U.read_file(j.path,true); os.remove(j.path); os.remove(j.path..".tmp"); self.job=nil
    local result; if j.timedout then result={ok=false,error="worker timeout"} elseif not raw then result={ok=false,error="worker returned no result"} else local good,x=pcall(Json.decode,raw); result=good and x or {ok=false,error="worker result decode failed"} end
    if j.callback then j.callback(result) end
end
function Async:cancel(reason)
    if self.poll then UIManager:unschedule(self.poll); self.poll=nil end
    if not self.job then return end
    local job=self.job
    job.callback=nil
    if job.fallback_task then UIManager:unschedule(job.fallback_task) end
    if job.pid then pcall(FFIUtil.terminateSubProcess,job.pid) end
    if job.path then os.remove(job.path); os.remove(job.path..".tmp") end
    self.job=nil
end
function Async:run(label,fn,callback,timeout)
    if self.job then return false,"worker busy" end
    if not self:available() then
        if self.disable_fallback then return false,"worker unavailable" end
        if not self.defer_fallback then
            local ok,x=pcall(fn)
            callback(ok and {ok=true,value=x} or {ok=false,error=tostring(x)})
            return true
        end
        local job={label=label,callback=callback,started=os.time(),fallback=true}
        local task
        task=function()
            if self.job~=job then return end
            job.fallback_task=nil
            local ok,x=pcall(fn)
            self.job=nil
            if job.callback then job.callback(ok and {ok=true,value=x} or {ok=false,error=tostring(x)}) end
        end
        job.fallback_task=task
        self.job=job
        UIManager:scheduleIn(self.fallback_delay,task)
        return true
    end
    local path=self.store.temp_dir.."/worker-"..tostring(os.time()).."-"..tostring(math.random(10000,99999))..".json"
    local child=function()
        SubprocessHygiene.close_inherited_sockets()
        local ok,x=pcall(fn)
        local res=ok and {ok=true,value=x} or {ok=false,error=tostring(x)}
        local encoded=Json.encode(res)
        U.atomic_write(path,encoded,true)
    end
    local ok,pid,err=pcall(FFIUtil.runInSubProcess,child,false,false)
    if not ok or not pid then
        local failure=tostring(err or pid)
        RuntimePressure.note_worker_failure(label,failure)
        return false,failure
    end
    local resolved_timeout = timeout
    if resolved_timeout == nil then resolved_timeout = 45 end
    self.job={pid=pid,path=path,label=label,callback=callback,started=os.time(),timeout=resolved_timeout}
    self:_schedule()
    return true
end
return Async
