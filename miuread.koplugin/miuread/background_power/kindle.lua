local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local M = {}

-- Kindle screen-off background work deliberately stays inside Amazon powerd's
-- native screenSaver state. We never synthesize power-button or wake events.
-- When powerd reaches readyToSuspend, we abort that one deep-suspend attempt
-- only while a power-critical MiuRead task is still active.
local KEY = "__MIUREAD_KINDLE_SCREEN_SAVER_HOLD_V1"
local POWER_SOURCES = {
    [1] = "BUTTON_WAKEUP",
    [2] = "BUTTON_SUSPEND",
    [4] = "HALL_SUSPEND",
    [6] = "HALL_WAKEUP",
}

local function state()
    local s = rawget(_G, KEY)
    if type(s) ~= "table" then
        s = {
            active = false,
            session = 0,
            reason = nil,
            entered_at = 0,
            tasks = {},
            capability = "unknown", -- unknown | supported | broken
            abort_count = 0,
            last_abort_at = 0,
            last_abort_backend = nil,
            last_abort_result = nil,
            last_power_kind = nil,
            last_power_source = nil,
            last_power_name = nil,
            last_power_at = 0,
            pending_user_sleep_origin = nil,
            pending_user_sleep_at = 0,
        }
        rawset(_G, KEY, s)
    end
    s.tasks = type(s.tasks) == "table" and s.tasks or {}
    return s
end

local function is_kindle()
    local fn = Device and Device.isKindle
    if type(fn) ~= "function" then return false end
    local ok, yes = pcall(fn, Device)
    return ok and yes == true
end

local function source_name(source, kind)
    local n = tonumber(source)
    return POWER_SOURCES[n]
        or string.format("UNKNOWN_%s(%s)", tostring(kind or "power"):upper(), tostring(source))
end

local function record_power(kind, source)
    local s = state()
    s.last_power_kind = tostring(kind or "unknown")
    s.last_power_source = tonumber(source)
    s.last_power_name = source_name(source, kind)
    s.last_power_at = os.time()
    logger.info("[MiuRead][KindleHold][RawPower]",
        "kind=", s.last_power_kind,
        "source=", tostring(s.last_power_name),
        "active=", tostring(s.active == true),
        "session=", tostring(s.session or 0))
    return true
end

local function has_tasks()
    for _, enabled in pairs(state().tasks or {}) do
        if enabled == true then return true end
    end
    return false
end

local function task_names()
    local names = {}
    for name, enabled in pairs(state().tasks or {}) do
        if enabled == true then names[#names + 1] = tostring(name) end
    end
    table.sort(names)
    return #names > 0 and table.concat(names, ",") or "none"
end

local function powerd_state()
    local powerd = Device and Device.powerd
    if powerd and type(powerd.getPowerdState) == "function" then
        local ok, value = pcall(powerd.getPowerdState, powerd)
        if ok and value ~= nil then return tostring(value) end
    end
    local ok_lipc, lipc = pcall(require, "liblipclua")
    if ok_lipc and lipc and type(lipc.init) == "function" then
        local ok_handle, handle = pcall(lipc.init, "com.github.koreader.miuread.hold.state")
        if ok_handle and handle then
            local ok, value = pcall(handle.get_string_property, handle, "com.lab126.powerd", "state")
            pcall(handle.close, handle)
            if ok and value ~= nil then return tostring(value) end
        end
    end
    return nil
end

local function abort_suspend()
    local s = state()
    local before = powerd_state()
    local issued = false
    local backend = "none"
    local error_detail = nil

    -- readyToSuspend is the only state where this property is meaningful. If
    -- powerd has already reached suspended, fail closed and do not try to wake.
    if before == "suspended" then
        return false, "already_suspended", before, backend
    end

    local ok_lipc, lipc = pcall(require, "liblipclua")
    if ok_lipc and lipc and type(lipc.init) == "function" then
        local ok_handle, handle = pcall(lipc.init, "com.github.koreader.miuread.hold")
        if ok_handle and handle then
            local ok_set, result = pcall(handle.set_int_property, handle,
                "com.lab126.powerd", "abortSuspend", 1)
            pcall(handle.close, handle)
            issued = ok_set == true
            if not ok_set then error_detail = tostring(result) end
            backend = "lipc"
        else
            error_detail = tostring(handle or "lipc_init_failed")
        end
    end

    -- Older firmware may have a working CLI even when the Lua binding is not
    -- available. This is still a single abort request, never a wake fallback.
    if not issued then
        local ok = os.execute("lipc-set-prop -i com.lab126.powerd abortSuspend 1 >/dev/null 2>&1")
        issued = ok == true or ok == 0
        backend = "lipc-cli"
        if not issued and not error_detail then error_detail = tostring(ok) end
    end

    s.abort_count = (tonumber(s.abort_count) or 0) + 1
    s.last_abort_at = os.time()
    s.last_abort_backend = backend
    s.last_abort_result = issued and "issued" or tostring(error_detail or "failed")
    if issued then s.capability = "supported" else s.capability = "broken" end

    -- Verification is diagnostic-only. If the write is accepted we do not
    -- manufacture another power transition even when firmware reports slowly.
    if issued then
        local session = s.session
        UIManager:scheduleIn(.35, function()
            local current = state()
            if current.session ~= session then return end
            local after = powerd_state()
            logger.info("[MiuRead][KindleHold] abort verification",
                "session=", tostring(session),
                "before=", tostring(before or "unknown"),
                "after=", tostring(after or "unknown"),
                "tasks=", task_names())
        end)
    end

    return issued, issued and "abort_issued" or tostring(error_detail or "abort_failed"), before, backend
end

local function leave_hold(reason, keep_tasks)
    local s = state()
    if not s.active then return false end
    local old_session = s.session
    s.active = false
    s.reason = nil
    s.entered_at = 0
    s.session = (tonumber(s.session) or 0) + 1
    if keep_tasks ~= true then s.tasks = {} end
    logger.info("[MiuRead][KindleHold] leave",
        "reason=", tostring(reason or "unknown"),
        "session=", tostring(old_session),
        "tasks=", task_names(),
        "powerd=", tostring(powerd_state() or "unknown"))
    return true
end

local function fail_closed(reason)
    local s = state()
    s.capability = "broken"
    logger.warn("[MiuRead][KindleHold][FailClosed]",
        "reason=", tostring(reason or "unknown"),
        "action=native_suspend",
        "tasks=", task_names(),
        "powerd=", tostring(powerd_state() or "unknown"))
    leave_hold("fail_closed:" .. tostring(reason or "unknown"), true)
    return false
end

local function install_guards()
    if not is_kindle() then return false end

    if type(Device.intoScreenSaver) == "function" and Device.__miuread_hold_into_guard ~= true then
        local original = Device.intoScreenSaver
        Device.intoScreenSaver = function(self, source, ...)
            record_power("suspend", source)
            return original(self, source, ...)
        end
        Device.__miuread_hold_into_guard = true
    end

    if type(Device.outofScreenSaver) == "function" and Device.__miuread_hold_out_guard ~= true then
        local original = Device.outofScreenSaver
        Device.outofScreenSaver = function(self, source, ...)
            record_power("wake", source)
            local s = state()
            local had_finalizer = s.tasks.reader_finalizer == true
            if s.active then
                -- A real user wake is a hard lifecycle boundary. Keep a genuine
                -- download marker, but never carry a reader finalizer into the
                -- next awake/suspend generation.
                leave_hold("native_wake:" .. source_name(source, "wake"), true)
            end
            if had_finalizer then
                s.tasks.reader_finalizer = nil
                logger.info("[MiuRead][KindleHold] reader finalizer cleared on native wake",
                    "source=", tostring(source_name(source, "wake")),
                    "download=", tostring(s.tasks.download == true))
            end
            return original(self, source, ...)
        end
        Device.__miuread_hold_out_guard = true
    end

    if type(Device.readyToSuspend) == "function" and Device.__miuread_hold_ready_guard ~= true then
        local original = Device.readyToSuspend
        Device.readyToSuspend = function(self, delay, ...)
            local s = state()
            if not s.active then return original(self, delay, ...) end

            if not has_tasks() then
                logger.info("[MiuRead][KindleHold] ready_to_suspend",
                    "background=false", "action=pass",
                    "session=", tostring(s.session),
                    "powerd=", tostring(powerd_state() or "unknown"))
                leave_hold("ready_to_suspend_pass", true)
                return original(self, delay, ...)
            end

            local ok, detail, before, backend = abort_suspend()
            logger.info("[MiuRead][KindleHold] ready_to_suspend",
                "background=true", "action=abort",
                "result=", tostring(ok == true),
                "detail=", tostring(detail),
                "backend=", tostring(backend),
                "powerd=", tostring(before or "unknown"),
                "tasks=", task_names(),
                "session=", tostring(s.session))
            if ok then
                -- Intentionally skip Kindle:readyToSuspend(). No kernel suspend
                -- will happen in this cycle, so there is no suspend_time/RTC
                -- bookkeeping to commit. powerd returns to screenSaver itself.
                return false
            end

            fail_closed(detail)
            return original(self, delay, ...)
        end
        Device.__miuread_hold_ready_guard = true
    end

    return true
end

install_guards()

function M.platform() return "kindle" end
function M.supported() return is_kindle() end
function M.active() return state().active == true end
function M.system_active() return false end
function M.commit_pending() return false end

function M.set_task(name, active)
    name = tostring(name or "background")
    local s = state()
    s.tasks[name] = active == true or nil
    logger.info("[MiuRead][KindleHold] task",
        "name=", name,
        "active=", tostring(active == true),
        "hold=", tostring(s.active == true),
        "session=", tostring(s.session),
        "tasks=", task_names())
    if s.active and not has_tasks() then
        logger.info("[MiuRead][KindleHold] background complete; waiting for native readyToSuspend",
            "session=", tostring(s.session))
    end
    return true
end

function M.task_active(name)
    return state().tasks[tostring(name or "background")] == true
end

function M.needs_background()
    return has_tasks()
end

function M.begin(reason)
    if not is_kindle() then return false, "unsupported_platform" end
    local s = state()
    if s.capability == "broken" then
        return false, "abort_suspend_unavailable"
    end
    if s.active then return true, "already_holding" end
    if not has_tasks() then return false, "no_background_task" end

    s.active = true
    s.session = (tonumber(s.session) or 0) + 1
    s.reason = tostring(reason or "background")
    s.entered_at = os.time()
    logger.info("[MiuRead][KindleHold] enter",
        "reason=", s.reason,
        "session=", tostring(s.session),
        "tasks=", task_names(),
        "capability=", tostring(s.capability),
        "powerd=", tostring(powerd_state() or "unknown"))
    return true, "screen_saver_hold"
end

-- Kept for the controller compatibility interface. Kindle no longer wakes
-- powerd after Suspend; the native screenSaver state is the hold state.
function M.after_suspend()
    return state().active == true
end

function M.on_resume_event()
    local s=state()
    if s.active then
        -- Defensive cleanup for Resume variants that do not pass through
        -- outofScreenSaver. Never suppress a real Resume.
        leave_hold("resume_event", true)
    end
    if s.tasks.reader_finalizer==true then
        s.tasks.reader_finalizer=nil
        logger.info("[MiuRead][KindleHold] reader finalizer cleared on resume event",
            "download=",tostring(s.tasks.download==true))
    end
    return "normal"
end

function M.on_suspend_while_active()
    local s = state()
    if not s.active then return "none" end
    if has_tasks() then
        -- A duplicate Suspend while already in screenSaver must not restart the
        -- whole MiuRead suspend lifecycle. Deep-suspend control belongs only to
        -- readyToSuspend/abortSuspend.
        return "hold"
    end
    return "none"
end

function M.finish(reason)
    local s = state()
    if not s.active or has_tasks() then return false end
    logger.info("[MiuRead][KindleHold] finish deferred to native powerd",
        "reason=", tostring(reason or "done"),
        "session=", tostring(s.session))
    return true
end

function M.background_task_done(reason)
    if state().active and not has_tasks() then return M.finish(reason) end
    return true
end

function M.force_clear(reason)
    if not state().active then return false end
    return leave_hold(reason or "force_clear", false)
end

function M.mark_user_sleep(origin)
    local s = state()
    s.pending_user_sleep_origin = tostring(origin or "unknown")
    s.pending_user_sleep_at = os.time()
    return true
end

function M.consume_user_sleep_origin()
    local s = state()
    local origin = s.pending_user_sleep_origin
    local age = os.time() - (tonumber(s.pending_user_sleep_at) or 0)
    s.pending_user_sleep_origin = nil
    s.pending_user_sleep_at = 0
    if origin and age >= 0 and age <= 5 then return origin end
    return nil
end

function M.snapshot()
    local s = state()
    local tasks = {}
    for name, enabled in pairs(s.tasks or {}) do
        if enabled == true then tasks[name] = true end
    end
    return {
        active = s.active == true,
        platform = "kindle",
        mode = s.active and "SCREEN_SAVER_HOLD" or "NORMAL",
        system_active = false,
        commit_pending = false,
        session = tonumber(s.session or 0) or 0,
        reason = s.reason,
        download_active = s.tasks.download == true,
        tasks = tasks,
        capability = tostring(s.capability or "unknown"),
        abort_count = tonumber(s.abort_count or 0) or 0,
        last_abort_backend = s.last_abort_backend,
        last_abort_result = s.last_abort_result,
        last_power_source_name = s.last_power_name,
        last_power_self_injected = false,
        powerd_state = powerd_state(),
    }
end

return M
