--[[--
Install strategy planner used by extension_center.lua.
It separates ordinary source archives from architecture-specific release
assets. The actual transactional write/rollback remains in extension_center so
there is only one trusted path that mutates the plugins directory.
--]]--

local Compat = require("miuread.extension_compat")

local M = {}

local function starts_with(value, prefix)
    value, prefix = tostring(value or ""), tostring(prefix or "")
    return value:sub(1, #prefix) == prefix
end

local function lower(value) return tostring(value or ""):lower() end

local function matches_patterns(name, patterns)
    name = lower(name)
    for _, pattern in ipairs(type(patterns) == "table" and patterns or {}) do
        if name:find(lower(pattern), 1, true) then return true end
    end
    return false
end

local function architecture_sources(entry, release, compatibility)
    if type(release) ~= "table" then return nil, "这个扩展需要按 CPU 架构选择 Release，但当前仓库没有可用 Release。" end
    local arch = compatibility.arch
    local patterns = type(entry.asset_patterns) == "table" and entry.asset_patterns[arch] or nil
    if type(patterns) ~= "table" or #patterns == 0 then
        return nil, "没有为当前 CPU 架构配置可验证的安装包。"
    end
    local out = {}
    for _, asset in ipairs(type(release.assets) == "table" and release.assets or {}) do
        local name = tostring(asset.name or "")
        local url = tostring(asset.browser_download_url or "")
        if lower(name):match("%.zip$") and starts_with(url, "https://") and matches_patterns(name, patterns) then
            out[#out + 1] = {
                url = url,
                version = tostring(release.tag_name or release.name or ""),
                source = "architecture-release-asset",
                size = tonumber(asset.size) or 0,
                remote_ref = "release:" .. tostring(release.tag_name or release.name or ""),
                asset_name = name,
                architecture = arch,
            }
        end
    end
    if #out == 0 then
        return nil, "最新 Release 没有找到与当前 CPU 架构（" .. tostring(compatibility.arch_raw or arch) .. "）匹配的 ZIP。"
    end
    table.sort(out, function(a, b) return lower(a.asset_name) < lower(b.asset_name) end)
    return out
end

function M.plan(entry, plugin, release, generic_sources)
    entry = type(entry) == "table" and entry or {}
    local compatibility = Compat.evaluate(entry, plugin)
    if compatibility.installable ~= true then
        return nil, compatibility.block_reason or "当前设备不支持自动安装此扩展", compatibility
    end
    local strategy = tostring(entry.install_strategy or "standard")
    if strategy == "architecture_assets" or strategy == "architecture_binary" then
        local sources, err = architecture_sources(entry, release, compatibility)
        if not sources then return nil, err, compatibility end
        return sources, nil, compatibility
    end
    if strategy == "external_manual" then
        return nil, "此扩展需要从作者发布渠道手动安装", compatibility
    end
    return type(generic_sources) == "table" and generic_sources or {}, nil, compatibility
end

return M
