-- Shared E-Ink/Web policy. A scoped operation can pin its route; independent
-- API calls start fresh. Mutations never cross routes after an uncertain send.
local Http=require("miuread.http")
local Log=require("miuread.diagnostic_log")
local M={}; M.__index=M

function M.control_error(value)
    local text=tostring(value or "")
    return text:find("[MiuReadRateLimit]",1,true)
        or (type(Http.is_rate_limit_error)=="function" and Http.is_rate_limit_error(value))
        or text:find("__MIUREAD_HIBERNATE__",1,true)
        or text:lower():find("download cancelled",1,true)
end
function M.preference(store)
    local prefs=store and type(store.preferences)=="function" and store:preferences() or {}
    return prefs.api_transport=="web" and "web" or "auto"
end
function M.new(store,options)
    options=options or {}
    local mode=options.channel or M.preference(store)
    mode=mode=="web" and "web" or "auto"
    local authorized=store and type(store.auth)=="function"
        and require("miuread.shelf_client").credentials(store:auth() or {})
    local reason=mode=="web" and "manual_web" or options.fresh_context and "coordinate_source"
        or not authorized and "authorization_required" or "eink_preferred"
    return setmetatable({store=store,mode=mode,selected=reason=="eink_preferred" and "eink" or "web",reason=reason,
        api_counts={eink={},web={}}},M)
end
function M:use_web(_,operation)
    self.selected,self.reason="web","eink_failed"
    Log.record(self.store,{operation=operation or "unknown",channel="web",outcome="fallback",reason=self.reason})
end
function M:invoke(name,native,web,options)
    if self.control_failure then error(self.control_failure,0) end
    options=options or {}
    local channel=options.web_only and "web" or self.selected
    if options.native_only and (channel~="eink" or not native) then
        if options.coordinates then error("[MiuReadCoordinateSource] E-Ink 批注坐标需要同源接口，未发送写入",0) end
        error("E-Ink 来源暂不可用，请重新打开列表后重试",0)
    end
    local phase=options.phase or name
    local function call(fn,selected)
        self.active_channel,self.active_phase=selected,phase
        local counts=self.api_counts[selected]
        counts[phase]=(counts[phase] or 0)+1
        local started=Log.now()
        local ok,a,b,c,d=pcall(fn)
        self.last_channel=selected
        if not ok and M.control_error(a) then self.control_failure=a end
        if not ok and type(self.note_rate_limit)=="function" then self:note_rate_limit(a) end
        local text=not ok and tostring(a) or ""
        local limited=not ok and (text:find("[MiuReadRateLimit]",1,true)
            or (type(Http.is_rate_limit_error)=="function" and Http.is_rate_limit_error(a)))
        local outcome=ok and "success" or (limited and "rate_limited"
            or (text:find("__MIUREAD_HIBERNATE__",1,true) and "hibernated"
            or (text:lower():find("download cancelled",1,true) and "cancelled" or "error")))
        local reason=not ok and (limited and "rate_limit" or (outcome~="error" and outcome)
            or ((type(Http.is_auth_error)=="function" and Http.is_auth_error(a)) and "authorization")
            or ((type(Http.is_network_error)=="function" and Http.is_network_error(a)) and "network") or "request_failed") or nil
        Log.record(self.store,{operation=name,phase=phase,channel=selected,
            outcome=outcome,reason=reason,
            elapsed_ms=math.floor(math.max(0,Log.now()-started)*1000),
            code=not ok and tonumber(tostring(a):match("error_code=(%-?%d+)")) or nil,
            status=not ok and tonumber(tostring(a):match("HTTP (%d%d%d)")) or nil,
            native_stage=text:match("native_stage=([%w_]+)"),
            local_cooldown=not ok and text:find("[MiuReadLocalCooldown]",1,true)~=nil or nil,
            wait_seconds=not ok and tonumber(tostring(a):match("wait_seconds=(%d+)")) or nil})
        self.active_channel,self.active_phase=nil,nil
        return ok,a,b,c,d
    end
    if channel=="eink" and not native then self:use_web("unsupported API operation",name) end
    if channel=="eink" and native then
        local ok,a,b,c,d=call(native,"eink")
        if ok then return a,b,c,d end
        if M.control_error(a) then error(a,0) end
        if options.native_only then error(a,0) end
        -- Only a failure before sending a mutation can safely fall back.
        if options.write and not tostring(a):find("[MiuReadBeforeWrite]",1,true) then error(a,0) end
        self:use_web(a,name)
        if options.restart_on_fallback then error("[MiuReadTransportChanged]",0) end
    end
    local ok,a,b,c,d=call(web,"web")
    if not ok then error(a,0) end
    return a,b,c,d
end
return M
