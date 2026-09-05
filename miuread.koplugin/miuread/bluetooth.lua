local Device = require("device")
local logger = require("logger")

local M = {}

local SHARED_KEY = "__MIUREAD_BLUETOOTH_CACHE"
local cache = rawget(_G, SHARED_KEY)
if type(cache) ~= "table" then
    cache = {
        probed = false,
        supported = false,
        enabled = false,
        backend = "none",
        can_list = false,
        can_scan = false,
        can_pair = false,
        checked_at = 0,
    }
    rawset(_G, SHARED_KEY, cache)
end

local KINDLE_SERVICE = "com.lab126.btfd"

local function shell_quote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function raw_command_output(command)
    local handle = io.popen(command .. " 2>/dev/null", "r")
    if not handle then return nil end
    local output = handle:read("*a") or ""
    handle:close()
    return output
end

local function command_exists(name)
    -- `command -v` is a shell-local lookup and does not contact a system
    -- service. Keep it outside the timeout wrapper so we can discover the
    -- wrapper itself without recursion.
    local output = raw_command_output("command -v " .. tostring(name))
    return output ~= nil and output:match("%S") ~= nil
end

local TIMEOUT_RUNNER = false -- false=unresolved, nil=unavailable, string=runner
local timeout_warning_logged = false

local function timeout_runner()
    if TIMEOUT_RUNNER~=false then return TIMEOUT_RUNNER end
    if command_exists("timeout") then TIMEOUT_RUNNER="timeout"
    elseif command_exists("busybox") then TIMEOUT_RUNNER="busybox timeout"
    else TIMEOUT_RUNNER=nil end
    return TIMEOUT_RUNNER
end

local function timeout_command(command, seconds)
    local runner=timeout_runner()
    if not runner then
        if not timeout_warning_logged then
            timeout_warning_logged = true
            logger.warn("[MiuRead][Bluetooth] bounded shell runner unavailable; external Bluetooth commands disabled")
        end
        return nil
    end
    seconds = math.max(1, math.floor(tonumber(seconds) or 3))
    return runner .. " " .. tostring(seconds) .. " sh -c " .. shell_quote(command)
end

local function command_output(command, seconds)
    local wrapped = timeout_command(command, seconds)
    if not wrapped then return nil end
    local handle = io.popen(wrapped .. " 2>/dev/null", "r")
    if not handle then return nil end
    local output = handle:read("*a") or ""
    local a, _, c = handle:close()
    local ok = a == true or a == 0 or c == 0
    if not ok then
        logger.warn("[MiuRead][Bluetooth] command timed out or failed", tostring(command))
        return nil
    end
    return output
end

local function shell_success(command, seconds)
    local wrapped = timeout_command(command, seconds)
    if not wrapped then return false end
    local a, _, c = os.execute(wrapped .. " >/dev/null 2>&1")
    local ok = a == true or a == 0 or c == 0
    if not ok then logger.warn("[MiuRead][Bluetooth] command timed out or failed", tostring(command)) end
    return ok
end

local function kindle_with_lipc(callback)
    local ok, lipc = pcall(require, "liblipclua")
    if not ok or not lipc then return nil end
    local handle = lipc.init("com.github.koreader.miuread.bluetooth")
    if not handle then return nil end
    local ok_call, result = pcall(callback, handle)
    pcall(handle.close, handle)
    if not ok_call then return nil end
    return result
end

local function kindle_state()
    local state = kindle_with_lipc(function(handle)
        return handle:get_int_property(KINDLE_SERVICE, "BTstate")
    end)
    if type(state) ~= "number" and command_exists("lipc-get-prop") then
        local output = command_output("lipc-get-prop -i " .. KINDLE_SERVICE .. " BTstate")
        state = output and tonumber(output:match("[-+]?%d+")) or nil
    end
    if type(state) ~= "number" then return nil end
    return state ~= 0
end

local function kindle_set(enabled)
    local request = enabled and "1:2" or "0:2"
    local result = kindle_with_lipc(function(handle)
        handle:set_string_property(KINDLE_SERVICE, "BTenable", request)
        return true
    end)
    if result == true then return true end
    if command_exists("lipc-set-prop") then
        return shell_success("lipc-set-prop -s " .. KINDLE_SERVICE .. " BTenable " .. shell_quote(request))
    end
    return false
end

local function kindle_set_string(prop, value)
    local result = kindle_with_lipc(function(handle)
        handle:set_string_property(KINDLE_SERVICE, prop, tostring(value or ""))
        return true
    end)
    if result == true then return true end
    if command_exists("lipc-set-prop") then
        return shell_success("lipc-set-prop -s " .. KINDLE_SERVICE .. " " .. tostring(prop) .. " " .. shell_quote(value))
    end
    return false
end

local function kindle_set_int(prop, value)
    local result = kindle_with_lipc(function(handle)
        handle:set_int_property(KINDLE_SERVICE, prop, tonumber(value) or 0)
        return true
    end)
    if result == true then return true end
    if command_exists("lipc-set-prop") then
        return shell_success("lipc-set-prop -i " .. KINDLE_SERVICE .. " " .. tostring(prop) .. " " .. tostring(tonumber(value) or 0))
    end
    return false
end

local ADDRESS_KEYS = { "address", "bdaddr", "bdAddr", "mac", "deviceAddress", "addr", "id" }
local NAME_KEYS = { "name", "deviceName", "friendlyName", "displayName", "BTconnectedDevName" }

local function normalize_address(value)
    if type(value) ~= "string" then return nil end
    value = value:gsub("-", ":"):upper()
    if value:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return value end
end

local function first_field(row, keys)
    for _, key in ipairs(keys) do
        if row[key] ~= nil and tostring(row[key]) ~= "" then return tostring(row[key]) end
    end
end

local function normalize_device(row, source)
    row = type(row) == "table" and row or {}
    local address = normalize_address(first_field(row, ADDRESS_KEYS))
    if not address then
        for _, value in pairs(row) do
            address = normalize_address(tostring(value))
            if address then break end
        end
    end
    local name = first_field(row, NAME_KEYS) or address or "未知设备"
    return { name = name, address = address, source = source }
end

local function kindle_hash(prop, source)
    local ok, lipc = pcall(require, "libopenlipclua")
    if not ok or not lipc then return nil end
    local handle = lipc.open_no_name()
    if not handle then return nil end
    local input = handle:new_hasharray()
    local ok_call, result = pcall(handle.access_hash_property, handle, KINDLE_SERVICE, prop, input)
    input:destroy()
    if not ok_call or result == nil then
        pcall(handle.close, handle)
        return nil
    end
    local rows = result:to_table() or {}
    result:destroy()
    handle:close()
    local devices = {}
    for _, row in ipairs(rows) do devices[#devices + 1] = normalize_device(row, source) end
    return devices
end

local function merge_devices(groups)
    local merged, by_key = {}, {}
    local rank = { discovered = 1, paired = 2, connected = 3 }
    for _, group in ipairs(groups or {}) do
        for _, device in ipairs(group.devices or {}) do
            local key = device.address or ("name:" .. tostring(device.name or ""))
            local existing = by_key[key]
            if not existing then
                existing = { name = device.name, address = device.address, source = group.source }
                by_key[key] = existing
                merged[#merged + 1] = existing
            elseif (rank[group.source] or 0) > (rank[existing.source] or 0) then
                existing.source = group.source
            end
            if tostring(existing.name or "") == "" and tostring(device.name or "") ~= "" then existing.name = device.name end
        end
    end
    table.sort(merged, function(a, b)
        local ar, br = rank[a.source] or 0, rank[b.source] or 0
        if ar ~= br then return ar > br end
        return tostring(a.name or a.address or "") < tostring(b.name or b.address or "")
    end)
    return merged
end

local function kindle_devices()
    return merge_devices{
        { source = "connected", devices = kindle_hash("ListConnected", "connected") or {} },
        { source = "paired", devices = kindle_hash("ListPaired", "paired") or {} },
        { source = "discovered", devices = kindle_hash("ListDiscovered", "discovered") or {} },
    }
end

local function bluez_show()
    if not command_exists("bluetoothctl") then return nil end
    local output = command_output("bluetoothctl show", 2)
    if not output or not output:match("Controller%s+[%x:]+") then return nil end
    return output
end

local function bluez_state()
    local output = bluez_show()
    if not output then return nil end
    return output:match("Powered:%s*yes") ~= nil
end

local function bluez_set(enabled)
    if not command_exists("bluetoothctl") then return false end
    return shell_success("bluetoothctl power " .. (enabled and "on" or "off"), 4)
end

local function parse_bluetoothctl_devices(output, source, target)
    target = target or {}
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local address, name = line:match("^Device%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+(.+)$")
        if address then target[#target + 1] = { address = address:upper(), name = name, source = source } end
    end
    return target
end

local function bluez_devices()
    local all = parse_bluetoothctl_devices(command_output("bluetoothctl devices", 2), "discovered")
    local paired = parse_bluetoothctl_devices(command_output("bluetoothctl devices Paired", 2), "paired")
    local connected = parse_bluetoothctl_devices(command_output("bluetoothctl devices Connected", 2), "connected")
    return merge_devices{
        { source = "connected", devices = connected },
        { source = "paired", devices = paired },
        { source = "discovered", devices = all },
    }
end

local function set_cache(supported, enabled, backend, can_list, can_scan, can_pair)
    cache.probed = true
    cache.supported = supported == true
    cache.enabled = enabled == true
    cache.backend = tostring(backend or "none")
    cache.can_list = can_list == true
    cache.can_scan = can_scan == true
    cache.can_pair = can_pair == true
    cache.checked_at = os.time()
    logger.info("[MiuRead][Bluetooth] capability",
        "backend=", cache.backend, "supported=", tostring(cache.supported),
        "enabled=", tostring(cache.enabled), "list=", tostring(cache.can_list))
    return M.peek()
end

function M.peek()
    return {
        known = cache.probed == true,
        supported = cache.supported == true,
        enabled = cache.enabled == true,
        backend = cache.backend,
        can_list = cache.can_list == true,
        can_scan = cache.can_scan == true,
        can_pair = cache.can_pair == true,
        checked_at = cache.checked_at,
    }
end

-- Async probes run in a subprocess so they cannot stall KOReader's event loop.
-- Adopt only the small capability snapshot in the parent process.
function M.adopt(state)
    if type(state) ~= "table" then return M.peek() end
    cache.probed = state.known == true or state.probed == true
    cache.supported = state.supported == true
    cache.enabled = state.enabled == true
    cache.backend = tostring(state.backend or "none")
    cache.can_list = state.can_list == true
    cache.can_scan = state.can_scan == true
    cache.can_pair = state.can_pair == true
    cache.checked_at = tonumber(state.checked_at) or os.time()
    logger.info("[MiuRead][Bluetooth] async capability adopted",
        "backend=", cache.backend, "supported=", tostring(cache.supported),
        "enabled=", tostring(cache.enabled))
    return M.peek()
end

function M.probe(force)
    if cache.probed and force ~= true then return M.peek() end
    if type(Device.isKindle) == "function" and Device:isKindle() then
        local state = kindle_state()
        if state ~= nil then
            local can_list = pcall(require, "libopenlipclua")
            return set_cache(true, state, "kindle-lipc", can_list, true, can_list)
        end
        return set_cache(false, false, "kindle-unavailable", false, false, false)
    end

    -- Standard BlueZ is the portable backend for Kobo and other Linux readers.
    -- We only expose it when the running OS actually presents an adapter;
    -- hardware that KOReader intentionally powered down is not advertised as a
    -- fake working control.
    local state = bluez_state()
    if state ~= nil then
        local backend = type(Device.isKobo) == "function" and Device:isKobo() and "kobo-bluez" or "bluez"
        return set_cache(true, state, backend, true, true, true)
    end
    return set_cache(false, false, "none", false, false, false)
end

function M.refresh()
    if not cache.probed then return M.probe(true) end
    local state
    if cache.backend == "kindle-lipc" then state = kindle_state()
    elseif cache.backend == "kobo-bluez" or cache.backend == "bluez" then state = bluez_state() end
    if state ~= nil then
        cache.enabled = state == true
        cache.checked_at = os.time()
    end
    return M.peek()
end

function M.setEnabled(enabled)
    if not cache.probed then M.probe(true) end
    if not cache.supported then return false, "unsupported" end
    local ok = false
    if cache.backend == "kindle-lipc" then ok = kindle_set(enabled)
    elseif cache.backend == "kobo-bluez" or cache.backend == "bluez" then ok = bluez_set(enabled) end
    if ok then
        cache.enabled = enabled == true
        cache.checked_at = os.time()
        return true
    end
    return false, "toggle failed"
end

function M.toggle()
    local state = M.peek()
    if not state.supported then return false, "unsupported" end
    return M.setEnabled(not state.enabled)
end

function M.listDevices()
    local state = M.peek()
    if not state.supported or not state.can_list then return {}, "unsupported" end
    if state.backend == "kindle-lipc" then return kindle_devices() end
    if state.backend == "kobo-bluez" or state.backend == "bluez" then return bluez_devices() end
    return {}, "unsupported"
end

function M.scan()
    local state = M.peek()
    if not state.supported or not state.can_scan then return false, "unsupported" end
    if not state.enabled then
        local ok = M.setEnabled(true)
        if not ok then return false, "enable failed" end
    end
    if state.backend == "kindle-lipc" then
        local ok = kindle_set_int("triggerBTscan", 1)
        if not ok then ok = kindle_set_int("DiscoverA2DP", 1) end
        return ok == true
    end
    if state.backend == "kobo-bluez" or state.backend == "bluez" then
        -- Keep scanning off the UI path: bluetoothctl exits automatically after
        -- a short window while the list can be reopened immediately.
        return shell_success("(bluetoothctl --timeout 6 scan on >/tmp/miuread-bt-scan.log 2>&1 &) ")
    end
    return false, "unsupported"
end

function M.connect(device)
    local state = M.peek()
    local address = device and normalize_address(device.address)
    if not state.supported or not address then return false, "invalid device" end
    if state.backend == "kindle-lipc" then return kindle_set_string("Connect", address) end
    if state.backend == "kobo-bluez" or state.backend == "bluez" then
        return shell_success("bluetoothctl connect " .. shell_quote(address), 8)
    end
    return false, "unsupported"
end

function M.disconnect(device)
    local state = M.peek()
    local address = device and normalize_address(device.address)
    if not state.supported or not address then return false, "invalid device" end
    if state.backend == "kindle-lipc" then return kindle_set_string("Disconnect", address) end
    if state.backend == "kobo-bluez" or state.backend == "bluez" then
        return shell_success("bluetoothctl disconnect " .. shell_quote(address), 6)
    end
    return false, "unsupported"
end

function M.pair(device)
    local state = M.peek()
    local address = device and normalize_address(device.address)
    if not state.supported or not address then return false, "invalid device" end
    if state.backend == "kindle-lipc" then return kindle_set_string("Bond", address) end
    if state.backend == "kobo-bluez" or state.backend == "bluez" then
        return shell_success("bluetoothctl pair " .. shell_quote(address), 15)
    end
    return false, "unsupported"
end

return M
