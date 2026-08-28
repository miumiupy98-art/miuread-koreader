local U = require("miuread.util")

local M = {}
local PATH = "/tmp/miuread-network-health.state"
local MAX_REASON = 96

local function clean_reason(value)
    value = tostring(value or ""):gsub("[%c\t\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #value > MAX_REASON then value = value:sub(1, MAX_REASON) end
    return value
end

local function write_state(state, reason)
    state = tostring(state or "unknown")
    local payload = table.concat({state, tostring(os.time()), clean_reason(reason)}, "\t")
    return U.atomic_write(PATH, payload, true) == true
end

function M.mark_recovering(reason)
    return write_state("recovering", reason or "resume")
end

function M.note_failure(reason)
    return write_state("down", reason or "transport")
end

function M.note_success(reason)
    return write_state("ok", reason or "transport")
end

function M.clear()
    os.remove(PATH)
end

function M.snapshot()
    local raw = U.read_file(PATH, true)
    if not raw or raw == "" then return {state="unknown", age=math.huge, at=0, reason=""} end
    local state, stamp, reason = raw:match("^([^\t]+)\t([^\t]+)\t?(.*)$")
    local at = tonumber(stamp) or 0
    return {
        state = tostring(state or "unknown"),
        at = at,
        age = at > 0 and math.max(0, os.time() - at) or math.huge,
        reason = tostring(reason or ""),
    }
end

return M
