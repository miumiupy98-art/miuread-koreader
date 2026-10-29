-- E-Ink 2.1.2 TimeChangeCheck rules, using KOReader clocks on this device.
-- Clock state is persisted by the outbox; old reading rows are never guessed.
local Protocol=require("miuread.readtime_protocol")
local ok_time,Time=pcall(require,"ui/time")
local M={}
local cached_boot_id
local function boot_id()
    if cached_boot_id==nil then
        local file=io.open("/proc/sys/kernel/random/boot_id","rb")
        cached_boot_id=file and file:read("*l") or ""
        if file then file:close() end
    end
    return cached_boot_id~="" and cached_boot_id or nil
end
function M.sample()
    local wall=os.time()
    local value={wall=wall,zone=Protocol.time_zone(wall),boot_id=boot_id()}
    if ok_time and type(Time.to_s)=="function" then
        local clock,kind
        if type(Time.boottime)=="function" and Time.boottime_or_monotonic==Time.boottime then
            clock,kind=Time.boottime,"boottime"
        elseif type(Time.monotonic)=="function" then clock,kind=Time.monotonic,"monotonic" end
        if clock then
            local ok,elapsed=pcall(function() return Time.to_s(clock()) end)
            if ok and type(elapsed)=="number" and elapsed>=0 and elapsed<math.huge then
                value.elapsed,value.kind=math.floor(elapsed),kind
            end
        end
    end
    return value
end
local function number(value)
    return type(value)=="number" and value==value and math.abs(value)<math.huge and value or nil
end
function M.observe(previous,sample)
    local state={}
    for k,v in pairs(previous or {}) do state[k]=v end
    local wall=assert(number(sample.wall),"reading-time clock unavailable")
    local elapsed=number(sample.elapsed)
    local same_boot=not (state.boot_id and sample.boot_id and state.boot_id~=sample.boot_id)
    local comparable=same_boot and sample.kind~=nil and sample.kind==state.kind and elapsed~=nil
    local reset=not comparable or not state.baseline_elapsed or not state.baseline_wall
    local discontinuity=state.last_wall~=nil and wall<state.last_wall or false
    if comparable and state.last_elapsed and state.last_wall then
        if elapsed>state.last_elapsed then
            discontinuity=discontinuity or math.abs((elapsed-state.last_elapsed)-(wall-state.last_wall))>=10
        end
    end
    if not reset then
        local drift=(elapsed-state.baseline_elapsed)-(wall-state.baseline_wall)
        if math.abs(drift)<10 then reset=true
        elseif elapsed<=state.baseline_elapsed then
            if wall<state.baseline_wall then state.time_changed=true else reset=true end
        elseif drift>0 then state.time_changed=true end
        -- Native logs a forward adjustment but does not set TIME_CHANGE for it.
        -- Retain the baseline until the wall/elapsed clocks agree again.
    elseif state.last_wall and state.last_wall-wall>=10 then
        state.time_changed=true
    end
    if reset then
        state.baseline_wall,state.baseline_elapsed=wall,elapsed
        -- A reboot whose wall clock moved backwards is still evidence of a
        -- time change. Do not clear it merely because elapsed time restarted.
        state.time_changed=(state.last_wall and state.last_wall-wall>=10) or state.server_time_diff==true
    end
    local zone=sample.zone
    local zone_changed=type(zone)=="string" and state.zone~=nil and state.zone~=zone
    if type(zone)=="string" and zone~=state.zone then
        state.zone_unusual=state.zone_changed_at~=nil and wall-state.zone_changed_at<3600 or false
        if state.zone and state.zone~="" then state.zone_changed_at=wall end
        state.zone=zone
    elseif state.zone_unusual and wall-(tonumber(state.zone_changed_at) or 0)>=259200 then
        state.zone_unusual=false
    end
    if discontinuity then
        state.capture_floor=math.max(tonumber(state.capture_floor) or 0,state.last_wall or wall,wall)
    end
    state.last_wall,state.last_elapsed,state.kind,state.boot_id=wall,elapsed,sample.kind,sample.boot_id
    return state,{risk=(state.time_changed and 1 or 0)+(state.zone_unusual and 4 or 0),
        discontinuity=discontinuity,zone_changed=zone_changed,zone=zone,capture_floor=state.capture_floor}
end
function M.server(previous,stamp,limit,wall)
    stamp=tonumber(stamp)
    if not stamp or stamp<=0 or stamp%1~=0 then return nil end
    limit=tonumber(limit)
    if not limit or limit<0 or limit%1~=0 or limit==math.huge then limit=600 end
    local state={}
    for k,v in pairs(previous or {}) do state[k]=v end
    state.server_time_diff=limit>0 and math.abs(wall-stamp)>limit
    -- ModuleInitializer's server-time callback clears a stale local flag when
    -- server time agrees. recordCurrentTime later adopts server_time_diff.
    state.time_changed=state.time_changed==true and state.server_time_diff
    return state,state.server_time_diff
end
return M
