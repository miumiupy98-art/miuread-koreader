--[[--
Compatibility helpers for the MiuRead extension centre.
All probes are best-effort and fail closed only for architecture-sensitive
binary packages. Unknown generic plugin compatibility remains a warning, not a
reason to hide a plugin from search.
--]]--

local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local U = require("miuread.util")
local Device = require("device")
local ffiUtil = require("ffi/util")

local M = {}

local function call_bool(object, name)
    local fn = object and object[name]
    if type(fn) ~= "function" then return false end
    local ok, value = pcall(fn, object)
    return ok and value == true
end

function M.platform()
    if call_bool(Device, "isKindle") then return "kindle", "Kindle" end
    if call_bool(Device, "isKobo") then return "kobo", "Kobo" end
    if type(ffiUtil.isAndroid) == "function" then
        local ok, value = pcall(ffiUtil.isAndroid)
        if ok and value == true then return "android", "Android" end
    end
    if call_bool(Device, "isPocketBook") then return "pocketbook", "PocketBook" end
    if call_bool(Device, "isRemarkable") then return "remarkable", "reMarkable" end
    return "other", "其他 / 桌面"
end

local function uname_machine()
    local pipe = io.popen("uname -m 2>/dev/null", "r")
    if not pipe then return "" end
    local raw = U.trim(pipe:read("*l") or ""):lower()
    pipe:close()
    return raw
end

function M.normalize_arch(raw)
    raw = tostring(raw or ""):lower()
    if raw == "" then return "unknown" end
    if raw:find("aarch64", 1, true) or raw:find("arm64", 1, true) then return "arm64" end
    if raw:find("armv7", 1, true) or raw:find("armv8l", 1, true) then return "armv7" end
    if raw:find("armv6", 1, true) or raw:find("armv5", 1, true) then return "arm_legacy" end
    if raw:find("x86_64", 1, true) or raw:find("amd64", 1, true) then return "x86_64" end
    if raw:match("i[3-6]86") or raw == "x86" then return "x86" end
    if raw:find("mips", 1, true) then return "mips" end
    return "unknown"
end

function M.architecture()
    local raw = uname_machine()
    return M.normalize_arch(raw), raw ~= "" and raw or "unknown"
end

local function read_first_line(path)
    local file = io.open(path, "rb")
    if not file then return "" end
    local value = U.trim(file:read("*l") or "")
    file:close()
    return value
end

local function version_candidate(value)
    value = tostring(value or "")
    local y, m = value:match("[vV]?(20%d%d)%.(%d%d)")
    if y and m then return y .. "." .. m end
    return ""
end

function M.koreader_version()
    local globals = {
        rawget(_G, "KOREADER_VERSION"),
        rawget(_G, "KOReader_VERSION"),
        rawget(_G, "VERSION"),
    }
    for _, value in ipairs(globals) do
        local candidate = version_candidate(value)
        if candidate ~= "" then return candidate, tostring(value) end
    end

    local ok, version_mod = pcall(require, "version")
    if ok then
        if type(version_mod) == "string" then
            local candidate = version_candidate(version_mod)
            if candidate ~= "" then return candidate, version_mod end
        elseif type(version_mod) == "table" then
            for _, key in ipairs({ "version", "VERSION", "revision", "getCurrentRevision" }) do
                local value = version_mod[key]
                if type(value) == "function" then
                    local call_ok, result = pcall(value, version_mod)
                    if call_ok then
                        local candidate = version_candidate(result)
                        if candidate ~= "" then return candidate, tostring(result) end
                    end
                else
                    local candidate = version_candidate(value)
                    if candidate ~= "" then return candidate, tostring(value) end
                end
            end
        end
    end

    local base = DataStorage:getDataDir()
    for _, path in ipairs({
        tostring(base or "") .. "/git-rev",
        "git-rev",
        "./git-rev",
    }) do
        if path ~= "/git-rev" and lfs.attributes(path, "mode") == "file" then
            local raw = read_first_line(path)
            local candidate = version_candidate(raw)
            if candidate ~= "" then return candidate, raw end
        end
    end
    return "", ""
end

local function ym_number(value)
    local y, m = tostring(value or ""):match("(20%d%d)%.(%d%d)")
    if not y then return nil end
    return tonumber(y) * 100 + tonumber(m)
end

function M.version_at_least(current, minimum)
    local a, b = ym_number(current), ym_number(minimum)
    if not a or not b then return nil end
    return a >= b
end

local function list_contains(list, value)
    for _, item in ipairs(type(list) == "table" and list or {}) do
        if tostring(item) == tostring(value) then return true end
    end
    return false
end

function M.info(plugin)
    local platform, platform_label = M.platform()
    local arch, arch_raw = M.architecture()
    local version, version_raw = M.koreader_version()
    local desktop = type(plugin) == "table" and type(plugin._home_enabled) == "function" and plugin:_home_enabled() == true or false
    return {
        platform = platform,
        platform_label = platform_label,
        arch = arch,
        arch_raw = arch_raw,
        koreader_version = version,
        koreader_version_raw = version_raw,
        miuread_desktop = desktop,
    }
end

function M.evaluate(entry, plugin)
    entry = type(entry) == "table" and entry or {}
    local info = M.info(plugin)
    local warnings = {}
    local installable = entry.auto_install ~= false and entry.install_strategy ~= "external_manual"
    local block_reason

    if type(entry.platforms) == "table" and #entry.platforms > 0 and not list_contains(entry.platforms, info.platform) then
        warnings[#warnings + 1] = "作者未将当前平台列入适用范围"
        if entry.strict_platform == true then
            installable = false
            block_reason = "当前平台不在此扩展的支持范围内"
        end
    end

    if entry.min_koreader and info.koreader_version ~= "" then
        local compatible = M.version_at_least(info.koreader_version, entry.min_koreader)
        if compatible == false then
            installable = false
            block_reason = "需要 KOReader " .. tostring(entry.min_koreader) .. " 或更高版本"
        end
    elseif entry.min_koreader and info.koreader_version == "" then
        warnings[#warnings + 1] = "无法自动读取当前 KOReader 版本，请自行核对最低版本要求"
    end

    if entry.architecture_sensitive == true then
        if info.arch == "unknown" then
            installable = false
            block_reason = "无法可靠识别当前 CPU 架构，已停止自动安装"
        elseif not list_contains(entry.supported_arches, info.arch) then
            installable = false
            block_reason = "当前 CPU 架构（" .. tostring(info.arch_raw) .. "）没有可验证的安装包"
        end
    end

    if entry.ui_conflict == true and info.miuread_desktop then
        warnings[#warnings + 1] = "与觅阅桌面功能重叠，建议切换到插件模式后使用"
    end
    if entry.experimental == true then warnings[#warnings + 1] = "Beta / 实验性扩展" end
    if entry.warning and entry.warning ~= "" then warnings[#warnings + 1] = tostring(entry.warning) end

    if entry.required_free_bytes then
        local free = U.free_space(DataStorage:getDataDir() .. "/plugins") or U.free_space(DataStorage:getDataDir())
        if free and free < tonumber(entry.required_free_bytes) then
            installable = false
            block_reason = "可用存储空间不足；此扩展建议至少预留 " .. M.format_bytes(entry.required_free_bytes)
        end
    end

    return {
        installable = installable,
        block_reason = block_reason,
        warnings = warnings,
        platform = info.platform,
        platform_label = info.platform_label,
        arch = info.arch,
        arch_raw = info.arch_raw,
        koreader_version = info.koreader_version,
        miuread_desktop = info.miuread_desktop,
    }
end

function M.format_bytes(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1024 * 1024 * 1024 then return string.format("%.1f GiB", bytes / (1024 * 1024 * 1024)) end
    if bytes >= 1024 * 1024 then return string.format("%.0f MiB", bytes / (1024 * 1024)) end
    if bytes >= 1024 then return string.format("%.0f KiB", bytes / 1024) end
    return tostring(bytes) .. " B"
end

local ELF_MACHINE = {
    [3] = "x86",
    [8] = "mips",
    [40] = "arm",
    [62] = "x86_64",
    [183] = "arm64",
}

function M.binary_arch(path)
    local file = io.open(path, "rb")
    if not file then return nil, "binary_missing" end
    local head = file:read(20) or ""
    file:close()
    if #head < 20 or head:sub(1, 4) ~= "\127ELF" then return nil, "not_elf" end
    local data = head:byte(6)
    local b1, b2 = head:byte(19), head:byte(20)
    if not b1 or not b2 then return nil, "elf_header_short" end
    local machine = data == 2 and (b1 * 256 + b2) or (b1 + b2 * 256)
    return ELF_MACHINE[machine] or ("elf_machine_" .. tostring(machine))
end

function M.validate_candidate(entry, candidate_root, compatibility)
    entry = type(entry) == "table" and entry or {}
    if not entry.binary_relpath then return true end
    local path = tostring(candidate_root or "") .. "/" .. tostring(entry.binary_relpath)
    if lfs.attributes(path, "mode") ~= "file" then
        return nil, "插件包缺少架构相关二进制：" .. tostring(entry.binary_relpath)
    end
    local actual, err = M.binary_arch(path)
    if not actual then return nil, "无法验证插件二进制架构（" .. tostring(err) .. "）" end
    local expected = compatibility and compatibility.arch or "unknown"
    local matches = (expected == "armv7" or expected == "arm_legacy") and actual == "arm"
        or expected == actual
    if not matches then
        return nil, "插件二进制架构与当前设备不匹配（包=" .. tostring(actual) .. "，设备=" .. tostring(expected) .. "）"
    end
    return true
end

return M
