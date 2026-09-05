local UIManager = require("ui/uimanager")
local Device = require("device")
local logger = require("logger")

local M = {}

local KEY = "__MIUREAD_SUSPEND_WORK_LEASE_V1"

local function special_suspend_supported()
    local function flag(name)
        local fn = Device and Device[name]
        if type(fn) ~= "function" then return false end
        local ok, yes = pcall(fn, Device)
        return ok and yes == true
    end
    local kindle, kobo = flag("isKindle"), flag("isKobo")
    return kindle ~= kobo and (kindle or kobo)
end

local function is_kindle()
    local fn = Device and Device.isKindle
    if type(fn) ~= "function" then return false end
    local ok, yes = pcall(fn, Device)
    return ok and yes == true
end

function M.supported()
    return special_suspend_supported()
end

local function shared()
    local value = rawget(_G, KEY)
    if type(value) ~= "table" then
        value = {
            held = false,
            reasons = {},
            generation = 0,
            changed_at = os.time(),
        }
        rawset(_G, KEY, value)
    end
    value.reasons = type(value.reasons) == "table" and value.reasons or {}
    value.generation = tonumber(value.generation or 0) or 0
    return value
end

local function reason_count(value)
    local count = 0
    for _, enabled in pairs(value.reasons or {}) do
        if enabled == true then count = count + 1 end
    end
    return count
end

local function copy_reasons(value)
    local out = {}
    for reason, enabled in pairs(value.reasons or {}) do
        if enabled == true then out[tostring(reason)] = true end
    end
    return out
end

function M.acquire_download()
    if not is_kindle() then return M.acquire("download") end
    local value = shared()
    value.download_count = math.max(0, tonumber(value.download_count) or 0)
    value.download_count = value.download_count + 1
    logger.info("[MiuRead][SuspendLease] Kindle download wake acquired",
        "count=", tostring(value.download_count))
    return true, M.snapshot()
end

function M.release_download()
    if not is_kindle() then return M.release("download") end
    local value = shared()
    value.download_count = math.max(0, tonumber(value.download_count) or 0)
    if value.download_count == 0 then return true, M.snapshot() end
    value.download_count = value.download_count - 1
    logger.info("[MiuRead][SuspendLease] Kindle download wake released",
        "count=", tostring(value.download_count))
    return true, M.snapshot()
end

function M.download_active()
    if not is_kindle() then return M.has("download") end
    return math.max(0, tonumber(shared().download_count) or 0) > 0
end

function M.acquire(reason)
    reason = tostring(reason or "background")
    local value = shared()
    if not special_suspend_supported() then
        logger.info("[MiuRead][SuspendLease] unsupported platform; acquire skipped",
            "reason=", reason)
        return false, M.snapshot(), "unsupported_platform"
    end
    if value.reasons[reason] == true then return true, M.snapshot() end
    value.reasons[reason] = true
    value.generation = value.generation + 1
    value.changed_at = os.time()
    if not value.held then
        if is_kindle() then
            -- On Kindle, task leases are registry-only. Deep-suspend control
            -- belongs to the screen-saver hold backend, never to a worker.
            -- A download/finalizer can die without owning device power.
            value.held = true
        else
            local ok, result = pcall(UIManager.preventStandby, UIManager)
            if not ok or result == false then
                value.reasons[reason] = nil
                value.generation = value.generation + 1
                value.changed_at = os.time()
                logger.warn("[MiuRead][SuspendLease] standby acquire failed",
                    "reason=", reason, "error=", tostring(ok and result or "call_failed"))
                return false, M.snapshot()
            end
            value.held = true
        end
    end
    logger.info("[MiuRead][SuspendLease] acquired",
        "reason=", reason, "count=", tostring(reason_count(value)))
    return true, M.snapshot()
end

function M.release(reason)
    reason = tostring(reason or "background")
    local value = shared()
    local existed = value.reasons[reason] == true
    value.reasons[reason] = nil
    if existed then
        value.generation = value.generation + 1
        value.changed_at = os.time()
    end
    if reason_count(value) == 0 and value.held then
        value.held = false
        if not is_kindle() then pcall(UIManager.allowStandby, UIManager) end
    end
    if existed then
        logger.info("[MiuRead][SuspendLease] released",
            "reason=", reason, "count=", tostring(reason_count(value)))
    end
    return true, M.snapshot()
end

function M.has(reason)
    return shared().reasons[tostring(reason or "background")] == true
end

function M.active()
    local value = shared()
    return value.held == true and reason_count(value) > 0
end

function M.snapshot()
    local value = shared()
    return {
        held = value.held == true,
        reasons = copy_reasons(value),
        count = reason_count(value),
        generation = tonumber(value.generation or 0) or 0,
        changed_at = tonumber(value.changed_at or 0) or 0,
    }
end

function M.clear(reason)
    local value = shared()
    local count = reason_count(value)
    value.reasons = {}
    value.download_count = 0
    value.generation = value.generation + 1
    value.changed_at = os.time()
    if value.held then
        value.held = false
        if not is_kindle() then pcall(UIManager.allowStandby, UIManager) end
    end
    logger.info("[MiuRead][SuspendLease] cleared",
        "reason=", tostring(reason or "clear"), "count=", tostring(count))
    return true, M.snapshot()
end

return M
