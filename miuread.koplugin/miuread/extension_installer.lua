--[[--
Generic KOReader extension package planner (installer v2).

The planner intentionally knows about package *shape* (release asset, source
archive, CPU token, update channel) instead of plugin names. Curated catalogue
fields are only optional hints/tie-breakers; every repository uses the same
selection rules.
--]]--

local Compat = require("miuread.extension_compat")

local M = {}

local function lower(value) return tostring(value or ""):lower() end
local function starts_with(value, prefix)
    value, prefix = tostring(value or ""), tostring(prefix or "")
    return value:sub(1, #prefix) == prefix
end

local function repo_basename(repo)
    local name = lower(tostring(repo or ""):match("/([^/]+)$") or "")
    return name:gsub("%.koplugin$", "")
end

local ARCH_TOKENS = {
    arm64 = { "aarch64", "arm64", "arm%-64" },
    armv7 = { "armv7", "armhf", "arm%-32", "linux%-armv7" },
    arm_legacy = { "armv6", "armv5", "arm%-legacy", "arm_legacy" },
    x86_64 = { "x86_64", "x86%-64", "amd64" },
    x86 = { "i386", "i486", "i586", "i686", "x86%-32" },
    mips = { "mips" },
}

local function contains_token(name, token)
    name = lower(name)
    if token:find("%%", 1, true) then return name:find(token) ~= nil end
    return name:find(token, 1, true) ~= nil
end

local function arch_from_name(name)
    name = lower(name)
    for arch, tokens in pairs(ARCH_TOKENS) do
        for _, token in ipairs(tokens) do
            if contains_token(name, token) then return arch end
        end
    end
    return nil
end

local function arch_matches(expected, actual)
    if not actual or actual == "" then return true end
    if expected == actual then return true end
    if expected == "armv7" and actual == "arm_legacy" then return false end
    return false
end

local function hint_matches(name, patterns)
    name = lower(name)
    for _, pattern in ipairs(type(patterns) == "table" and patterns or {}) do
        if name:find(lower(pattern), 1, true) then return true end
    end
    return false
end

local function asset_score(asset, repo, arch, entry)
    local name = lower(asset and asset.name or "")
    local url = tostring(asset and asset.browser_download_url or "")
    if not name:match("%.zip$") or not starts_with(url, "https://") then return nil end
    if name:find("checksum", 1, true) or name:find("sha256", 1, true)
        or name:find("symbols", 1, true) or name:find("debug", 1, true) then
        return nil
    end

    local detected_arch = arch_from_name(name)
    if detected_arch and not arch_matches(arch, detected_arch) then return nil end

    local score = 10
    if name:find("%.koplugin", 1, true) then score = score + 55
    elseif name:find("koplugin", 1, true) then score = score + 45
    elseif name:find("plugin", 1, true) then score = score + 28 end

    local base = repo_basename(repo)
    if base ~= "" and name:find(base, 1, true) then score = score + 22 end
    if detected_arch then score = score + 70 end
    if name:find("source", 1, true) or name:find("src", 1, true) then score = score - 35 end

    -- Optional catalogue hints only adjust ranking. They never select a bespoke
    -- code path and never make an otherwise valid generic package mandatory.
    local patterns = type(entry.asset_patterns) == "table" and entry.asset_patterns[arch] or nil
    if hint_matches(name, patterns) then score = score + 15 end
    return score, detected_arch
end

local function inferred_channel(record)
    record = type(record) == "table" and record or {}
    local channel = tostring(record.install_channel or "")
    if channel == "release" or channel == "branch" then return channel end
    local remote = tostring(record.remote_ref or "")
    if remote:sub(1, 8) == "release:" then return "release" end
    if remote:sub(1, 7) == "branch:" then return "branch" end
    return ""
end

local function add(out, seen, source)
    if type(source) ~= "table" or not starts_with(source.url, "https://") or seen[source.url] then return end
    seen[source.url] = true
    out[#out + 1] = source
end

local function sort_sources(list)
    table.sort(list, function(a, b)
        local sa, sb = tonumber(a.score) or 0, tonumber(b.score) or 0
        if sa ~= sb then return sa > sb end
        local aa, ab = tostring(a.asset_name or ""), tostring(b.asset_name or "")
        if aa ~= ab then return aa < ab end
        return tostring(a.url or "") < tostring(b.url or "")
    end)
end

function M.plan(entry, plugin, repo, repo_info, release, installed_record)
    entry = type(entry) == "table" and entry or {}
    repo_info = type(repo_info) == "table" and repo_info or {}
    local compatibility = Compat.evaluate(entry, plugin)
    if compatibility.installable ~= true then
        return nil, compatibility.block_reason or "当前设备不支持自动安装此扩展", compatibility
    end
    if tostring(entry.install_strategy or "") == "external_manual" or entry.auto_install == false then
        return nil, "此扩展需要从作者发布渠道手动安装", compatibility
    end

    local preferred_channel = inferred_channel(installed_record)
    local out, seen = {}, {}
    local tag = tostring(type(release) == "table" and (release.tag_name or release.name) or "")

    if preferred_channel ~= "branch" and type(release) == "table" then
        local assets = {}
        for _, asset in ipairs(type(release.assets) == "table" and release.assets or {}) do
            local score, asset_arch = asset_score(asset, repo, compatibility.arch, entry)
            if score then
                assets[#assets + 1] = {
                    url = tostring(asset.browser_download_url or ""),
                    version = tag,
                    source = "release-asset",
                    channel = "release",
                    size = tonumber(asset.size) or 0,
                    remote_ref = "release:" .. tag,
                    asset_name = tostring(asset.name or ""),
                    architecture = asset_arch,
                    score = score + 100,
                }
            end
        end
        sort_sources(assets)
        for _, source in ipairs(assets) do add(out, seen, source) end
    end

    local probe = type(repo_info.source_probe) == "table" and repo_info.source_probe or {}
    local source_installable = probe.installable
    local branch = tostring(repo_info.default_branch or "main")
    if branch == "" then branch = "main" end

    -- Source archives are a generic fallback only when the repository has been
    -- confirmed to contain an installable main.lua + _meta.lua pair. If the API
    -- probe is unavailable and no Release package exists, keep one conservative
    -- branch fallback so ordinary repositories still work offline/from stale
    -- metadata. A confirmed negative probe never falls back to
    -- a known-uninstallable source tree.
    local allow_branch = preferred_channel ~= "release"
        and (source_installable == true or (source_installable == nil and #out == 0))
    if allow_branch then
        add(out, seen, {
            url = "https://github.com/" .. tostring(repo) .. "/archive/refs/heads/" .. tostring(branch) .. ".zip",
            version = "",
            source = "branch-source",
            channel = "branch",
            remote_ref = "branch:" .. tostring(repo_info.pushed_at or repo_info.updated_at or branch),
            score = source_installable == true
                and ((preferred_channel=="" and entry.architecture_sensitive~=true) and 260 or 80) or 20,
        })
    end

    -- A tag source archive is useful for repositories whose source tree itself
    -- is the plugin. It is deliberately omitted for a confirmed non-installable
    -- source repository, preventing a failed Release from being misreported as a
    -- main.lua/_meta.lua problem.
    if preferred_channel ~= "branch" and source_installable == true and tag ~= "" then
        add(out, seen, {
            url = "https://github.com/" .. tostring(repo) .. "/archive/refs/tags/" .. tostring(tag) .. ".zip",
            version = tag,
            source = "release-source",
            channel = "release",
            remote_ref = "release:" .. tag,
            score = 65,
        })
    end

    sort_sources(out)
    if #out == 0 then
        if source_installable == false and (not release or #(release.assets or {}) == 0) then
            return nil, "仓库源码不是可直接安装的 KOReader 插件，且当前 Release 没有可用 ZIP。", compatibility
        end
        if preferred_channel == "release" then
            return nil, "此插件原先从 Release 安装，但当前没有可用的同渠道安装包。", compatibility
        elseif preferred_channel == "branch" then
            return nil, "此插件原先从仓库分支安装，但当前分支无法确认可安装。", compatibility
        end
        return nil, "当前没有找到可安全自动安装的插件包。", compatibility
    end
    return out, nil, compatibility
end

M.arch_from_name = arch_from_name
M.inferred_channel = inferred_channel

return M
