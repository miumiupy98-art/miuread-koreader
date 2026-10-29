local DataStorage=require("datastorage")
local lfs=require("libs/libkoreader-lfs")
local ffiUtil=require("ffi/util")
local UIManager=require("ui/uimanager")
local InputDialog=require("ui/widget/inputdialog")
local ConfirmBox=require("ui/widget/confirmbox")
local Menu=require("ui/widget/menu")
local Config=require("miuread.config")
local U=require("miuread.util")
local Json=require("miuread.json")
local logger=require("logger")

local NativePlugins=require("miuread.native_plugins")
local InfoMessage=require("ui/widget/infomessage")
local ButtonDialog=require("ui/widget/buttondialog")
local Async=require("miuread.async")
local Catalog=require("miuread.extension_catalog")
local Compat=require("miuread.extension_compat")
local ExtensionInstall=require("miuread.extension_install")
local DownloadProgress=require("miuread.download_progress")
local SuspendWorkLease=require("miuread.suspend_work_lease")
local PseudoLockscreen=require("miuread.pseudo_lockscreen")

local M={}

local RECORD_KEY="extension_center_installed_v2"
local LEGACY_RECORD_KEY="extension_center_installed"
local SEARCH_CACHE_KEY="extension_center_search_cache_v2"
local META_CACHE_KEY="extension_center_repo_cache_v3"
local UPDATE_STATE_KEY="extension_center_update_state_v3"
local UPDATE_CHECK_META_KEY="extension_center_update_check_v1"
local PENDING_KEY="extension_center_pending_restart_v1"
local NETWORK_KEY="extension_center_network_v2"
local TEMP_CLEANUP_KEY="extension_center_temp_cleanup_v1"
local MAX_RESULTS=24
local SEARCH_TTL=30*60
local META_TTL=30*60
local UPDATE_VISIBLE_TTL=24*60*60
local UPDATE_AUTO_INTERVAL=12*60*60
local UPDATE_RETRY_INTERVAL=30*60
local MAX_PLUGIN_BYTES=96*1024*1024
local EXTENSION_TEMP_TTL=24*60*60
local EXTENSION_STAGE_TTL=6*60*60
local SELF_REPO="miumiupy98-art/miuread-koreader"
local SESSION_TOKEN=tostring(os.time()).."-"..tostring(math.random(100000,999999))

-- Curated recommendation policy and compatibility metadata live in the
-- catalogue. Entries with recommended=false remain searchable; the catalogue
-- does not act as a GitHub search allow-list.
local KNOWN_REPOS=Catalog.ENTRIES

local function normalized_alias(value)
    return tostring(value or ""):lower():gsub("[%s%p_]+","")
end

local function known_repo(repo)
    return Catalog.known_repo(repo)
end

local function canonical_repo(repo)
    return Catalog.canonical_repo(repo)
end

local function install_entry(repo,repo_info)
    repo=canonical_repo(repo)
    local known=known_repo(repo)
    if known then return known,true end
    local repo_name=tostring(repo):match("([^/]+)$") or ""
    return {
        id="community:"..repo,repo=repo,name=U.trim(tostring(type(repo_info)=="table" and repo_info.name or repo_name)),
        install_dirname=repo_name:match("%.koplugin$") and repo_name or "",
        install_strategy="standard",recommended=false,community=true,
    },false
end

local function alias_matches(query)
    return Catalog.alias_matches(query)
end

local function trim(value)
    return U.trim(tostring(value or ""))
end

local function extension_network(plugin)
    local value=plugin.store:get(NETWORK_KEY,{mode="auto",custom_prefix=""})
    value=type(value)=="table" and value or {mode="auto",custom_prefix=""}
    return {mode=tostring(value.mode or "auto"),custom_prefix=trim(value.custom_prefix)}
end

local function save_extension_network(plugin,value)
    value=type(value)=="table" and value or {}
    plugin.store:set_deferred(NETWORK_KEY,{mode=tostring(value.mode or "auto"),custom_prefix=trim(value.custom_prefix)})
    plugin.store:flush()
end

local function valid_mirror_prefix(value)
    value=trim(value)
    return value:match("^https://")~=nil
end

local function basename(path)
    return tostring(path or ""):gsub("/+$",""):match("([^/]+)$") or ""
end

local function dirname(path)
    local out=tostring(path or ""):gsub("/+$",""):match("^(.*)/[^/]+$")
    return out and out~="" and out or "."
end

local function valid_repo(repo)
    return type(repo)=="string" and repo:match("^[%w%._%-]+/[%w%._%-]+$")~=nil
end

local function url_encode(value)
    return (tostring(value or ""):gsub("[^%w%-_%.~]",function(c)
        return string.format("%%%02X",string.byte(c))
    end))
end

local function plugin_lookup_paths()
    local paths,seen={},{}
    local function add(path)
        path=trim(path)
        if path=="" or lfs.attributes(path,"mode")~="directory" then return end
        local real=type(ffiUtil.realpath)=="function" and ffiUtil.realpath(path) or nil
        local key=real or path
        if seen[key] then return end
        seen[key]=true
        paths[#paths+1]=path
    end
    add("plugins")
    local base=DataStorage:getDataDir()
    if base and base~="" then add(base.."/plugins") end
    local extra=G_reader_settings and G_reader_settings:readSetting("extra_plugin_paths") or nil
    if type(extra)=="string" then extra={extra} end
    if type(extra)=="table" then
        for _,path in ipairs(extra) do add(path) end
    end
    return paths
end

local function default_plugin_root()
    local root=DataStorage:getDataDir().."/plugins"
    U.mkdir(root)
    return root
end

local function read_meta(path)
    local raw=U.read_file(path.."/_meta.lua",true) or ""
    local version=raw:match('[%s,{]version%s*=%s*["\']([^"\']+)["\']')
        or raw:match('^version%s*=%s*["\']([^"\']+)["\']')
        or ""
    local identity=raw:match('[%s,{]fullname%s*=%s*["\']([^"\']+)["\']')
        or raw:match('[%s,{]name%s*=%s*["\']([^"\']+)["\']')
        or ""
    local fullname=identity~="" and identity or basename(path)
    return {version=version,fullname=fullname,identity=identity}
end

local function canonical_path(path)
    path=tostring(path or "")
    local real=path~="" and type(ffiUtil.realpath)=="function" and ffiUtil.realpath(path) or nil
    return real or path
end

local function sha256_file(path)
    if not U.file_exists(path) then return "" end
    local pipe=io.popen("sha256sum "..U.shell_quote(path).." 2>/dev/null","r")
    if not pipe then return "" end
    local raw=pipe:read("*l") or ""
    pipe:close()
    return raw:match("^([0-9a-fA-F]+)") or ""
end

local function plugin_fingerprint(path)
    local meta=sha256_file(path.."/_meta.lua")
    local main=sha256_file(path.."/main.lua")
    if meta=="" and main=="" then return "" end
    return meta..":"..main
end

local function scan_installed()
    local out,seen={},{}
    for _,root in ipairs(plugin_lookup_paths()) do
        local ok,iter,state=pcall(lfs.dir,root)
        if ok and type(iter)=="function" then
            for entry in iter,state do
                if entry~="." and entry~=".." and entry:match("%.koplugin$") and entry~="miuread.koplugin" then
                    local path=root.."/"..entry
                    local key=canonical_path(path)
                    if not seen[key]
                        and lfs.attributes(path,"mode")=="directory"
                        and U.file_exists(path.."/main.lua")
                        and U.file_exists(path.."/_meta.lua") then
                        seen[key]=true
                        local meta=read_meta(path)
                        out[#out+1]={
                            dir=entry,path=path,canonical_path=key,root=root,
                            name=meta.fullname~="" and meta.fullname or entry,
                            version=meta.version,identity=meta.identity,
                        }
                    end
                end
            end
        end
    end
    table.sort(out,function(a,b)
        local an,bn=tostring(a.name):lower(),tostring(b.name):lower()
        if an~=bn then return an<bn end
        return tostring(a.path)<tostring(b.path)
    end)
    return out
end

local function installed_matches_by_dir(dir)
    local out={}
    if not dir or dir=="" then return out end
    for _,item in ipairs(scan_installed()) do if item.dir==dir then out[#out+1]=item end end
    return out
end

local function normalized_plugin_identity(value)
    return tostring(value or ""):lower():gsub("[^%w]","")
end

local function raw_records(plugin)
    local value=plugin.store:get(RECORD_KEY,{})
    return type(value)=="table" and value or {}
end

local function save_records(plugin,value)
    return plugin.store:set(RECORD_KEY,type(value)=="table" and value or {})
end

local function migrate_legacy_records(plugin)
    local current=raw_records(plugin)
    if next(current)~=nil then return current end
    local legacy=plugin.store:get(LEGACY_RECORD_KEY,{})
    if type(legacy)~="table" or next(legacy)==nil then return current end
    local changed=false
    for dir,rec in pairs(legacy) do
        if type(rec)=="table" and valid_repo(rec.repo) then
            local matches=installed_matches_by_dir(tostring(rec.dir or dir or ""))
            if #matches==1 then
                local item=matches[1]
                local old_version=trim(rec.version)
                local repo_dir=tostring(rec.repo or ""):match("/([^/]+)$") or ""
                local repo_matches=normalized_plugin_identity(repo_dir)==normalized_plugin_identity(item.dir)
                local version_matches=old_version~="" and trim(item.version)~="" and old_version==trim(item.version)
                -- Old records were keyed only by directory name. Migrate them
                -- only when either the repository name or a concrete version
                -- still confirms that the on-disk plugin is the same install.
                if repo_matches or version_matches then
                    current[item.canonical_path]={
                        repo=rec.repo,dir=item.dir,path=item.canonical_path,
                        version=item.version~="" and item.version or old_version,
                        source_url=tostring(rec.source_url or ""),installed_at=tonumber(rec.installed_at) or os.time(),
                        identity=item.identity,fingerprint=plugin_fingerprint(item.path),
                        remote_ref=tostring(rec.remote_ref or ""),
                        install_channel=tostring(rec.install_channel or ""),
                        source_kind=tostring(rec.source_kind or ""),
                    }
                    changed=true
                end
            end
        end
    end
    if changed then save_records(plugin,current) end
    return current
end

local function records(plugin)
    local value=migrate_legacy_records(plugin)
    local scans=scan_installed()
    local by_path={}
    for _,item in ipairs(scans) do by_path[item.canonical_path]=item end
    local cleaned,changed={},false
    for key,rec in pairs(type(value)=="table" and value or {}) do
        if type(rec)=="table" then
            local path=canonical_path(rec.path or key)
            local item=by_path[path]
            local canonical=canonical_repo(rec.repo)
            if canonical~=tostring(rec.repo or "") then rec.repo=canonical; changed=true end
            local valid=item~=nil and valid_repo(rec.repo)
            local current_fingerprint=valid and plugin_fingerprint(item.path) or ""
            if valid and rec.dir and tostring(rec.dir)~=item.dir then valid=false end
            if valid and trim(rec.identity)~="" and normalized_plugin_identity(rec.identity)~=normalized_plugin_identity(item.identity) then valid=false end
            if valid and trim(rec.fingerprint)~="" and current_fingerprint~="" and trim(rec.fingerprint)~=current_fingerprint then valid=false end
            if valid and (trim(rec.fingerprint)=="" or current_fingerprint=="")
                and trim(rec.version)~="" and trim(item.version)~="" and trim(rec.version)~=trim(item.version) then valid=false end
            if valid then
                rec.path=path; rec.dir=item.dir; rec.identity=item.identity
                if trim(rec.fingerprint)=="" and current_fingerprint~="" then rec.fingerprint=current_fingerprint; changed=true end
                cleaned[path]=rec
                if key~=path then changed=true end
            else
                changed=true
            end
        else
            changed=true
        end
    end
    if changed then save_records(plugin,cleaned) end
    return cleaned
end

local function remember_install(plugin,repo,dir,path,version,source_url,remote_ref,install_channel,source_kind,package_meta)
    repo=canonical_repo(repo)
    path=canonical_path(path)
    local value=records(plugin)
    local meta=read_meta(path)
    value[path]={
        repo=repo,dir=dir,path=path,version=tostring(version or meta.version or ""),
        source_url=tostring(source_url or ""),installed_at=os.time(),
        identity=meta.identity,fingerprint=plugin_fingerprint(path),
        remote_ref=tostring(remote_ref or ""),
        install_channel=tostring(install_channel or ""),
        source_kind=tostring(source_kind or ""),
        package_sha256=tostring(type(package_meta)=="table" and package_meta.sha256 or ""),
        package_size=tonumber(type(package_meta)=="table" and package_meta.size or 0) or 0,
        package_asset=tostring(type(package_meta)=="table" and package_meta.asset_name or ""),
    }
    save_records(plugin,value)
end

local function forget_install(plugin,item_or_path)
    local path=type(item_or_path)=="table" and item_or_path.canonical_path or tostring(item_or_path or "")
    path=canonical_path(path)
    local value=records(plugin)
    value[path]=nil
    save_records(plugin,value)
end

local function record_for_installed(plugin,item)
    if type(item)~="table" then return nil end
    return records(plugin)[canonical_path(item.canonical_path or item.path)]
end

local function log_url(url)
    if type(U.redact_url)=="function" then return U.redact_url(url) end
    return tostring(url or "")
end

local function classify_github_error(err)
    err=tostring(err or "")
    if err:find("http:404",1,true) then return "not_found","仓库不存在或资源尚未发布" end
    if err:find("http:403",1,true) or err:find("http:429",1,true)
        or err:lower():find("rate limit",1,true) then
        return "rate_limited","GitHub 请求过于频繁，请稍后再试"
    end
    if err:lower():find("timeout",1,true) or err:find("timed out",1,true) then
        return "timeout","连接 GitHub 超时"
    end
    if err:find("Could not resolve",1,true) or err:find("Failed to connect",1,true) then
        return "network","无法连接 GitHub"
    end
    return "network","无法连接 GitHub"
end

local function curl_fetch_json(url,path)
    os.remove(path)
    local cmd="curl -L --silent --show-error --connect-timeout 8 --max-time 30"
        .." -H "..U.shell_quote("Accept: application/vnd.github+json")
        .." -H "..U.shell_quote("User-Agent: MiuRead-ExtensionCenter")
        .." -o "..U.shell_quote(path).." -w "..U.shell_quote("%{http_code}")
        .." "..U.shell_quote(url).." 2>/dev/null"
    local pipe=io.popen(cmd,"r")
    if not pipe then return nil,"curl unavailable" end
    local status=trim(pipe:read("*a"))
    local ok=pipe:close()
    if status~="200" then os.remove(path); return nil,"http:"..(status~="" and status or "000") end
    if ok==nil then os.remove(path); return nil,"curl failed" end
    local raw=U.read_file(path,true)
    os.remove(path)
    if not raw or raw=="" then return nil,"GitHub curl 返回空数据" end
    local decoded_ok,decoded=pcall(Json.decode,raw)
    if not decoded_ok or type(decoded)~="table" then return nil,"GitHub curl 返回了无法识别的数据" end
    return decoded
end

local function github_json(plugin,url)
    local ok,result=pcall(function()
        return plugin.http:get_json(url,{
            auth=false,retries=1,redirects=6,
            timeout={6,18},
        })
    end)
    if ok and type(result)=="table" then return result end

    local lua_error=tostring(result or "GitHub 返回了无法识别的数据")
    logger.warn("[MiuRead][Extensions] metadata Lua route failed",log_url(url),lua_error)
    local target=plugin.store.temp_dir.."/extension-json-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))..".json"
    local decoded,curl_error=curl_fetch_json(url,target)
    if decoded then
        logger.info("[MiuRead][Extensions] metadata curl success",log_url(url))
        return decoded
    end
    return nil,curl_error or lua_error
end

local function prune_cache_entries(entries,limit)
    if type(entries)~="table" then return end
    limit=math.max(1,tonumber(limit) or 40)
    local ranked={}
    for key,value in pairs(entries) do
        ranked[#ranked+1]={key=key,at=tonumber(type(value)=="table" and value.updated_at or 0) or 0}
    end
    if #ranked<=limit then return end
    table.sort(ranked,function(a,b) return a.at>b.at end)
    for index=limit+1,#ranked do entries[ranked[index].key]=nil end
end

local function meta_cache(plugin)
    local value=plugin.store:get(META_CACHE_KEY,{entries={}})
    value=type(value)=="table" and value or {entries={}}
    value.entries=type(value.entries)=="table" and value.entries or {}
    return value
end

local function meta_cache_get(plugin,repo,allow_stale)
    local value=meta_cache(plugin)
    local entry=value.entries[tostring(repo or "")]
    if type(entry)~="table" then return nil end
    local age=os.time()-(tonumber(entry.updated_at) or 0)
    if type(entry.repo_info)=="table" then
        entry.repo_info.release_missing=entry.release_missing==true
    end
    if allow_stale==true or age<=META_TTL then return entry,age>META_TTL end
end

local function meta_cache_put(plugin,repo,repo_info,release,release_missing)
    local value=meta_cache(plugin)
    value.entries[repo]={
        repo_info=repo_info,release=release,release_missing=release_missing==true,updated_at=os.time(),
    }
    prune_cache_entries(value.entries,80)
    plugin.store:set_deferred(META_CACHE_KEY,value)
    plugin.store:flush()
end

local function github_repo(plugin,repo)
    if not valid_repo(repo) then return nil,"invalid_repo" end
    return github_json(plugin,"https://api.github.com/repos/"..repo)
end

local function recent_releases(plugin,repo)
    if not valid_repo(repo) then return nil,"invalid_repo" end
    local releases,err=github_json(plugin,"https://api.github.com/repos/"..repo.."/releases?per_page=20")
    if type(releases)=="table" then
        if #releases==0 then return {},"no_release" end
        return releases,nil
    end
    if tostring(err):find("http:404",1,true) then return nil,"no_release" end
    logger.warn("[MiuRead][Extensions] releases unavailable",repo,tostring(err))
    return nil,err
end

local function compact_repo_info(info)
    if type(info)~="table" then return nil end
    return {
        name=tostring(info.name or ""),description=tostring(info.description or ""),
        stargazers_count=tonumber(info.stargazers_count) or 0,archived=info.archived==true,
        default_branch=tostring(info.default_branch or "main"),
        pushed_at=tostring(info.pushed_at or ""),updated_at=tostring(info.updated_at or ""),
    }
end

local function compact_release(release)
    if type(release)~="table" then return nil end
    local assets={}
    for _,asset in ipairs(type(release.assets)=="table" and release.assets or {}) do
        assets[#assets+1]={
            name=tostring(asset.name or ""),
            browser_download_url=tostring(asset.browser_download_url or ""),
            size=tonumber(asset.size) or 0,
            digest=tostring(asset.digest or ""),
            content_type=tostring(asset.content_type or ""),
        }
    end
    return {
        tag_name=tostring(release.tag_name or ""),name=tostring(release.name or ""),assets=assets,
        draft=release.draft==true,prerelease=release.prerelease==true,
        published_at=tostring(release.published_at or release.created_at or ""),
    }
end


local function resolve_release(entry,releases,arch)
    local compact={}
    for _,release in ipairs(type(releases)=="table" and releases or {}) do
        local value=compact_release(release)
        if value then compact[#compact+1]=value end
    end
    return Catalog.best_release_source(entry,compact,arch)
end

local function resolve_repo_remote(plugin,repo)
    repo=canonical_repo(repo)
    local info,repo_error=github_repo(plugin,repo)
    info=compact_repo_info(info)
    if not info then return nil,repo_error end
    local entry=install_entry(repo,info)
    local compatibility=Compat.evaluate(entry,plugin)
    local releases,releases_error=recent_releases(plugin,repo)
    if releases==nil and releases_error~="no_release" then return nil,releases_error end
    local selected,source,release_error,candidates=resolve_release(entry,releases or {},compatibility.arch)
    if releases_error=="no_release" then release_error="no_release" end
    info.release_missing=releases_error=="no_release"
    info.release_unusable=not selected and releases_error~="no_release"
    return {
        repo=repo,info=info,entry=entry,compatibility=compatibility,release=selected,source=source,
        source_error=release_error,candidates=candidates,release_missing=info.release_missing,
        release_unusable=info.release_unusable,
    },nil
end

local function contents_have_plugin_markers(items)
    if type(items)~="table" then return false end
    local main,meta=false,false
    for _,item in ipairs(items) do
        if type(item)=="table" and tostring(item.type or "")~="dir" then
            local name=tostring(item.name or "")
            if name=="main.lua" then main=true elseif name=="_meta.lua" then meta=true end
        end
    end
    return main and meta
end

-- Confirm source installability with GitHub itself. This replaces the old
-- per-plugin source allow-list: source ZIPs are considered only after Release
-- resolution proves there is no usable asset, and only when Contents API shows
-- a complete KOReader plugin payload.
local function probe_source_installability(plugin,repo,repo_info)
    repo_info=type(repo_info)=="table" and repo_info or {}
    local branch=trim(repo_info.default_branch or "main")
    if branch=="" then branch="main" end
    local root,root_error=github_json(plugin,"https://api.github.com/repos/"..repo.."/contents?ref="..url_encode(branch))
    if type(root)~="table" then
        return {installable=nil,branch=branch,error=tostring(root_error or "contents_unavailable")}
    end
    local repo_dir=tostring(repo):match("([^/]+)$") or ""
    if contents_have_plugin_markers(root) then
        if repo_dir:match("^[%w%._%-]+%.koplugin$") and repo_dir~="miuread.koplugin" then
            return {installable=true,branch=branch,path="",kind="root",expected_dir=repo_dir}
        end
        return {installable=false,branch=branch,path="",reason="源码位于仓库根目录，但仓库名不能安全确定 .koplugin 安装目录"}
    end

    local entry=known_repo(repo) or {}
    local expected=trim(Catalog.install_dirname(entry))
    local dirs={}
    for _,item in ipairs(root) do
        if type(item)=="table" and tostring(item.type or "")=="dir" then
            local name=tostring(item.name or "")
            if name:match("%.koplugin$") then dirs[#dirs+1]=name end
        end
    end
    table.sort(dirs)
    local candidates={}
    for _,name in ipairs(dirs) do if name==expected then candidates={name}; break end end
    if #candidates==0 and #dirs==1 then candidates={dirs[1]} end
    if #candidates==0 then
        return {installable=false,branch=branch,path="",reason=#dirs>1 and "源码包含多个 .koplugin 目录" or "源码缺少 main.lua / _meta.lua"}
    end

    local child_name=candidates[1]
    local child,child_error=github_json(plugin,"https://api.github.com/repos/"..repo.."/contents/"..url_encode(child_name).."?ref="..url_encode(branch))
    if type(child)~="table" then
        return {installable=nil,branch=branch,path=child_name,error=tostring(child_error or "contents_unavailable")}
    end
    if contents_have_plugin_markers(child) then
        return {installable=true,branch=branch,path=child_name,kind="nested",expected_dir=child_name}
    end
    return {installable=false,branch=branch,path=child_name,reason="源码目录缺少 main.lua / _meta.lua"}
end

local function maybe_probe_source(plugin,repo,repo_info,release,release_error)
    -- Only fall back to repository source after GitHub has positively shown
    -- there is no usable stable Release. Network/API failures never become a
    -- source install. Community repositories follow the same evidence rule.
    local should_probe=release_error=="no_release" or release_error=="no_installable_release"
        or release_error=="近期正式 Release 没有可识别的插件 ZIP"
    if not should_probe then return nil end
    return probe_source_installability(plugin,repo,repo_info)
end

local function resolve_repo_remote_complete(plugin,repo)
    local value,err=resolve_repo_remote(plugin,repo)
    if not value then return nil,err end
    value.info.source_probe=maybe_probe_source(plugin,value.repo,value.info,value.release,value.source_error)
    return value,nil
end

local function display_repo_name(repo_info,fallback)
    if type(fallback)=="table" and trim(fallback.name)~="" then return fallback.name end
    local name=trim(type(repo_info)=="table" and repo_info.name or "")
    return name~="" and name or "第三方扩展"
end

local function normalized_version(value)
    return trim(value):gsub("^[vV]","")
end

local function semver_like(value)
    return normalized_version(value):match("^%d+%.%d+%.%d+")~=nil
end

local function release_marker(release)
    local tag=trim(type(release)=="table" and (release.tag_name or release.name) or "")
    if tag=="" then return "","" end
    return "release:"..tag,tag
end

local function branch_marker(repo_info)
    local stamp=trim(type(repo_info)=="table" and (repo_info.pushed_at or repo_info.updated_at) or "")
    local branch=trim(type(repo_info)=="table" and repo_info.default_branch or "main")
    if stamp~="" then return "branch:"..stamp end
    return "branch:"..branch
end

local function remote_marker(repo_info,release)
    local marker,version=release_marker(release)
    if marker~="" then return marker,version end
    return branch_marker(repo_info),""
end

local function cleanup_stale_extension_temp(plugin,force)
    if not plugin or not plugin.store then return 0 end
    if plugin._extension_center_async and plugin._extension_center_async:busy() then return 0 end
    local last=tonumber(plugin.store:get(TEMP_CLEANUP_KEY,0)) or 0
    if force~=true and os.time()-last<6*60*60 then return 0 end
    local removed=0
    for _,path in ipairs(U.list(plugin.store.temp_dir)) do
        local name=basename(path)
        local attr=lfs.attributes(path)
        local age=os.time()-(tonumber(attr and attr.modification) or os.time())
        local remove=false
        if attr and attr.mode=="directory" and name:match("^extension%-stage%-.+") and age>EXTENSION_STAGE_TTL then
            remove=true
        elseif attr and attr.mode=="file" then
            if name:match("^extension%-json%-.+%.json$") and age>60*60 then remove=true end
            if (name:match("^extension%-download%-.+%.zip$") or name:match("^extension%-download%-.+%.zip%.part$")
                or name:match("^extension%-.+%.zip$")) and age>EXTENSION_TEMP_TTL then remove=true end
            if name:match("^extension%-download%-.+%.curl%.") and age>60*60 then remove=true end
        end
        if remove then
            local ok=attr.mode=="directory" and U.remove_tree(path) or os.remove(path)
            if ok then removed=removed+1 end
        end
    end
    plugin.store:set_deferred(TEMP_CLEANUP_KEY,os.time())
    plugin.store:flush()
    if removed>0 then logger.info("[MiuRead][Extensions] stale temp cleaned","count=",tostring(removed)) end
    return removed
end

local function show_menu(plugin,title,items)
    if plugin and type(plugin._push_miuread_menu)=="function" then
        local pushed=plugin:_push_miuread_menu(title,items,{page_size=7})
        if pushed then return pushed end
    end
    if plugin and type(plugin._show_miuread_menu)=="function" then
        return plugin:_show_miuread_menu(title,items,{page_size=7})
    end
    UIManager:show(Menu:new{title=title,item_table=items,items_per_page=8})
end

local function route_label(key)
    key=tostring(key or "")
    for _,route in ipairs(Config.EXTENSION_DOWNLOAD_ROUTES or {}) do
        if tostring(route.key or "")==key then return tostring(route.label or key) end
    end
    return key~="" and key or "下载通道"
end

local function network_mode_label(plugin)
    local value=extension_network(plugin)
    if value.mode=="direct" then return "GitHub 官方" end
    if value.mode=="custom" then return "自定义镜像" end
    local route=value.mode:match("^route:(.+)$")
    if route then return route_label(route) end
    local index=value.mode:match("^mirror:(%d+)$")
    if index then return "旧镜像 "..index end
    return "自动（推荐）"
end

local function set_network_mode(plugin,mode)
    local value=extension_network(plugin)
    value.mode=tostring(mode or "auto")
    save_extension_network(plugin,value)
    if type(plugin.toast)=="function" then plugin:toast("扩展下载源："..network_mode_label(plugin)) end
end

local function edit_custom_mirror(plugin)
    local value=extension_network(plugin)
    local dialog
    dialog=InputDialog:new{
        title="自定义扩展镜像",
        description="填写 HTTPS 前缀，例如 https://example.com/ 。镜像只用于插件 ZIP 等文件下载，不代理 GitHub API。",
        input=tostring(value.custom_prefix or ""),
        buttons={{
            {text="取消",id="close",callback=function() UIManager:close(dialog) end},
            {text="保存",is_enter_default=true,callback=function()
                local input=trim(dialog:getInputText())
                if input~="" and not valid_mirror_prefix(input) then
                    UIManager:close(dialog); plugin:info("镜像地址必须以 https:// 开头。") return
                end
                UIManager:close(dialog)
                local current=extension_network(plugin)
                current.custom_prefix=input
                if input~="" then current.mode="custom" elseif current.mode=="custom" then current.mode="auto" end
                save_extension_network(plugin,current)
                if type(plugin.toast)=="function" then plugin:toast(input~="" and "自定义镜像已保存" or "已清除自定义镜像") end
            end},
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function download_source_menu(plugin)
    local current=extension_network(plugin)
    local rows={
        {text="自动（推荐）",post_text=current.mode=="auto" and "当前 · 中文社区优先，大文件有界测速" or "中文社区优先，大文件有界测速",callback=function() set_network_mode(plugin,"auto") end},
    }
    for _,route in ipairs(Config.EXTENSION_DOWNLOAD_ROUTES or {}) do
        local key=tostring(route.key or "")
        if key~="" then
            local mode=key=="direct" and "direct" or ("route:"..key)
            local note=current.mode==mode and "当前" or ""
            if route.preferred==true and note=="" then note="默认首选" end
            rows[#rows+1]={text=tostring(route.label or key),post_text=note,callback=function() set_network_mode(plugin,mode) end}
        end
    end
    rows[#rows+1]={text="自定义镜像",post_text=current.mode=="custom" and "当前" or (current.custom_prefix~="" and "已配置 · 自动模式最后尝试" or "未配置"),keep_menu_open=true,callback=function() edit_custom_mirror(plugin) end}
    rows[#rows+1]={text="说明",separator=true,enabled=false}
    rows[#rows+1]={text="GitHub 官方决定版本与安装包",post_text="下载通道只传输同一个正式 Release ZIP",enabled=false}
    rows[#rows+1]={text="大文件自动探测线路",post_text="只探测前 3 条高价值线路；已有断点优先续传",enabled=false}
    rows[#rows+1]={text="源码包不会自动兜底",post_text="正式安装包未完成时保留断点并稍后继续",enabled=false}
    return rows
end

local function run_with_progress(plugin,text,fn,done)
    local dialog=InfoMessage:new{text=tostring(text or "正在处理……")}
    UIManager:show(dialog)
    UIManager:nextTick(function()
        local ok,a,b,c,d,e=xpcall(fn,debug.traceback)
        pcall(function() UIManager:close(dialog) end)
        if not ok then
            logger.warn("[MiuRead][Extensions] foreground task failed",tostring(a))
            plugin:info("操作失败。\n\n"..U.first_line(tostring(a),280))
            return
        end
        if type(done)=="function" then
            local done_ok,done_err=xpcall(function() done(a,b,c,d,e) end,debug.traceback)
            if not done_ok then
                logger.warn("[MiuRead][Extensions] task result handling failed",tostring(done_err))
                plugin:info("操作结果显示失败。\n\n"..U.first_line(tostring(done_err),260))
            end
        end
    end)
end

local function extension_worker(plugin)
    if not plugin._extension_center_async then
        plugin._extension_center_async=Async:new(plugin.store,{
            poll_interval=.25,allow_android=true,disable_fallback=true,
        })
    end
    return plugin._extension_center_async
end

local function run_async_with_progress(plugin,text,label,fn,done,timeout,options)
    options=type(options)=="table" and options or {}
    local worker=extension_worker(plugin)
    if worker:busy() then
        plugin:info("已有扩展中心任务正在进行。\n\n请等待当前任务完成，或返回正在进行的任务后取消。")
        return false
    end

    plugin._extension_center_generation=(tonumber(plugin._extension_center_generation) or 0)+1
    local generation=plugin._extension_center_generation
    local closing=false
    local dialog
    local function cleanup_cancel()
        if type(options.cancel_cleanup)=="function" then
            pcall(options.cancel_cleanup)
        end
    end
    local function cancel(reason)
        if closing then return end
        closing=true
        plugin._extension_center_generation=(tonumber(plugin._extension_center_generation) or 0)+1
        worker:cancel(reason or "user_cancelled")
        cleanup_cancel()
        if dialog then pcall(function() UIManager:close(dialog) end) end
    end
    dialog=ButtonDialog:new{
        title=tostring(text or "正在处理……").."\n\n可按返回键或点击取消。",
        title_align="center",
        close_callback=function() cancel("dialog_closed") end,
        buttons={{{text="取消",callback=function() cancel("user_cancelled") end}}},
    }
    UIManager:show(dialog)

    local function finish(result)
        if generation~=plugin._extension_center_generation then return end
        closing=true
        if dialog then pcall(function() UIManager:close(dialog) end) end
        if type(done)~="function" then return end
        local ok,err=xpcall(function()
            if type(result)=="table" and result.ok==true then
                done(result.value,nil)
            else
                done(nil,type(result)=="table" and result.error or "后台任务失败")
            end
        end,debug.traceback)
        if not ok then
            logger.warn("[MiuRead][Extensions] async result handling failed",tostring(err))
            plugin:info("操作结果显示失败。\n\n"..U.first_line(tostring(err),260))
        end
    end

    local started,err=worker:run(tostring(label or "extension_task"),function()
        -- Recreate the HTTP client after the subprocess closes inherited sockets.
        -- This avoids reusing a parent-process connection while keeping all GitHub
        -- requests outside the UI process.
        local HttpChild=require("miuread.http")
        plugin.http=HttpChild:new(plugin.store)
        return fn()
    end,finish,tonumber(timeout) or 45)
    if started then return true end

    -- Older KOReader builds without subprocess support keep a visible progress
    -- dialog and use the existing foreground path instead of losing the feature.
    closing=true
    pcall(function() UIManager:close(dialog) end)
    logger.warn("[MiuRead][Extensions] async worker unavailable; using foreground fallback",tostring(err or "unknown"))
    run_with_progress(plugin,text,function()
        local ok,value=xpcall(fn,debug.traceback)
        if not ok then return nil,tostring(value) end
        return value,nil
    end,function(value,fallback_err)
        if type(done)=="function" then done(value,fallback_err) end
    end)
    return true
end

-- Background extension discovery must never show a modal progress dialog. It
-- shares the same subprocess lane as foreground extension work, so an install
-- or an explicit search always wins and the silent check simply waits until the
-- next trigger instead of competing for network/CPU on low-memory devices.
local function run_async_silent(plugin,label,fn,done,timeout)
    local worker=extension_worker(plugin)
    if worker:busy() then return false,"busy" end
    local function finish(result)
        local ok,err=xpcall(function()
            if type(result)=="table" and result.ok==true then
                if type(done)=="function" then done(result.value,nil) end
            elseif type(done)=="function" then
                done(nil,type(result)=="table" and result.error or "后台任务失败")
            end
        end,debug.traceback)
        if not ok then logger.warn("[MiuRead][Extensions] silent result handling failed",tostring(err)) end
    end
    local started,err=worker:run(tostring(label or "extension_silent"),function()
        local HttpChild=require("miuread.http")
        plugin.http=HttpChild:new(plugin.store)
        return fn()
    end,finish,tonumber(timeout) or 45)
    return started==true,err
end

local function pending_state(plugin)
    local value=plugin.store:get(PENDING_KEY,{})
    value=type(value)=="table" and value or {}
    local out,changed={},false
    for key,item in pairs(value) do
        if type(item)=="table" and item.session==SESSION_TOKEN then out[key]=item else changed=true end
    end
    if changed then plugin.store:set(PENDING_KEY,out) end
    return out
end

local function mark_pending(plugin,item,action)
    item=type(item)=="table" and item or {}
    local dir=tostring(item.dir or "")
    if dir=="" then return end
    local value=pending_state(plugin)
    value[dir]={
        session=SESSION_TOKEN,dir=dir,name=tostring(item.name or dir),
        path=tostring(item.path or ""),action=tostring(action or "changed"),at=os.time(),
    }
    plugin.store:set(PENDING_KEY,value)
end

local function pending_for(plugin,dir)
    return pending_state(plugin)[tostring(dir or "")]
end

local function pending_label(pending)
    local action=type(pending)=="table" and tostring(pending.action or "") or ""
    if action=="installed" then return "已安装 · 重启后可用" end
    if action=="updated" then return "已更新 · 重启后生效" end
    if action=="removed" then return "已卸载 · 重启后完成" end
    return action~="" and "更改后需重启" or ""
end

local function pending_count(plugin)
    local count=0
    for _ in pairs(pending_state(plugin)) do count=count+1 end
    return count
end

local function pending_restart_rows(plugin)
    local rows={}
    local action_labels={installed="已安装",updated="已更新",removed="已卸载"}
    local pending=pending_state(plugin)
    local ordered={}
    for _,item in pairs(pending) do ordered[#ordered+1]=item end
    table.sort(ordered,function(a,b) return tostring(a.name or a.dir):lower()<tostring(b.name or b.dir):lower() end)
    for _,item in ipairs(ordered) do
        rows[#rows+1]={text=tostring(item.name or item.dir),post_text=action_labels[tostring(item.action or "")] or "已更改",enabled=false}
    end
    rows[#rows+1]={text="立即重启 KOReader",separator=#rows>0,callback=function()
        if type(plugin._restart_koreader)=="function" then plugin:_restart_koreader("extension_center")
        else plugin:info("请完整重启 KOReader 后继续使用。") end
    end}
    return rows
end

local function update_state(plugin)
    local value=plugin.store:get(UPDATE_STATE_KEY,{})
    return type(value)=="table" and value or {}
end

local function save_update_state(plugin,value)
    plugin.store:set(UPDATE_STATE_KEY,type(value)=="table" and value or {})
end

local function update_check_meta(plugin)
    local value=plugin.store:get(UPDATE_CHECK_META_KEY,{})
    return type(value)=="table" and value or {}
end

local function save_update_check_meta(plugin,value)
    plugin.store:set(UPDATE_CHECK_META_KEY,type(value)=="table" and value or {})
end

local function update_key(item)
    if type(item)~="table" then return "" end
    return tostring(item.canonical_path or item.path or item.dir or "")
end

local function copy_item(item)
    local out={}
    for k,v in pairs(type(item)=="table" and item or {}) do out[k]=v end
    return out
end

local function managed_plugins(plugin)
    local scans=scan_installed()
    local source_records=records(plugin)
    local by_dir={}
    for _,item in ipairs(scans) do
        by_dir[item.dir]=by_dir[item.dir] or {}
        by_dir[item.dir][#by_dir[item.dir]+1]=item
    end
    local native_records=NativePlugins.records()
    local out,used={},{}

    local function find_by_identity(record)
        local label=normalized_plugin_identity(NativePlugins.label(record))
        if label=="" then return {} end
        local matches={}
        for _,item in ipairs(scans) do
            if normalized_plugin_identity(item.identity)==label or normalized_plugin_identity(item.name)==label then
                matches[#matches+1]=item
            end
        end
        return matches
    end

    for _,native in ipairs(native_records) do
        local module_name=NativePlugins.module_name(native)
        local expected=module_name~="" and (module_name..".koplugin") or ""
        local matches=expected~="" and (by_dir[expected] or {}) or {}
        if #matches==0 then matches=find_by_identity(native) end
        local item
        if #matches>0 then
            item=copy_item(matches[1])
            for _,match in ipairs(matches) do used[match.canonical_path]=true end
            if #matches>1 then
                item.duplicate=true; item.duplicate_paths={}
                for _,match in ipairs(matches) do item.duplicate_paths[#item.duplicate_paths+1]=match.path end
            end
        else
            item={
                dir=expected,path="",canonical_path="",root="",
                name=NativePlugins.label(native),version=NativePlugins.version(native),identity=NativePlugins.label(native),
                missing_path=true,
            }
        end
        item.native=native
        item.enabled=native.enabled==true
        item.name=NativePlugins.label(native)~="" and NativePlugins.label(native) or item.name
        item.runtime_version=NativePlugins.version(native)
        if trim(item.version)=="" and trim(item.runtime_version)~="" then item.version=item.runtime_version end
        if item.path~="" then item.record=source_records[canonical_path(item.canonical_path or item.path)] end
        item.repo=type(item.record)=="table" and item.record.repo or nil
        item.pending=pending_for(plugin,item.dir)
        -- PluginLoader still remembers a plugin until KOReader restarts. Once
        -- its only on-disk copy has been removed, keep that runtime ghost out
        -- of the installed list and surface it only in "待重启生效".
        local pending_action=type(item.pending)=="table" and tostring(item.pending.action or "") or ""
        if not (item.missing_path==true and pending_action=="removed") then
            out[#out+1]=item
        end
    end

    -- A freshly installed plugin is on disk before KOReader reloads PluginLoader.
    -- Keep it visible if and only if MiuRead has a validated install record.
    for _,item in ipairs(scans) do
        if not used[item.canonical_path] then
            local rec=source_records[item.canonical_path]
            if rec then
                local extra=copy_item(item)
                extra.record=rec; extra.repo=rec.repo; extra.enabled=nil
                extra.pending=pending_for(plugin,extra.dir)
                out[#out+1]=extra
            end
        end
    end

    table.sort(out,function(a,b)
        local an,bn=tostring(a.name or a.dir):lower(),tostring(b.name or b.dir):lower()
        if an~=bn then return an<bn end
        return tostring(a.dir)<tostring(b.dir)
    end)
    return out
end

local function installed_count(plugin)
    local count=0
    for _,item in ipairs(managed_plugins(plugin)) do if item.ghost~=true then count=count+1 end end
    return count
end

local function managed_repo_map(plugin)
    local out={}
    local list=managed_plugins(plugin)
    for _,item in ipairs(list) do
        if item.ghost~=true and valid_repo(item.repo) then out[canonical_repo(item.repo)]=item end
    end
    -- A manually installed known plugin may not have an extension-center source
    -- record yet. For trusted aliases only, match its canonical install dirname
    -- so recommendation/search/popular still report the same installed state.
    for _,known in ipairs(KNOWN_REPOS) do
        if valid_repo(known.repo) and not out[known.repo] then
            local expected=tostring(known.repo):match("([^/]+)$")
            local match,count=nil,0
            for _,item in ipairs(list) do
                if item.ghost~=true and tostring(item.dir or "")==expected then
                    match=item; count=count+1
                end
            end
            if count==1 then out[known.repo]=match end
        end
    end
    return out
end

local function recent_update_state(states,item)
    if type(states)~="table" or type(item)~="table" then return nil end
    local state=states[update_key(item)]
    if type(state)~="table" then return nil end
    local checked_at=tonumber(state.checked_at) or 0
    if checked_at<=0 or os.time()-checked_at>UPDATE_VISIBLE_TTL then return nil end
    return state
end

local function installed_status_label(plugin,item,states)
    if type(item)~="table" then return "" end
    if item.pending then return pending_label(item.pending) end
    if item.duplicate then return "重复安装" end
    local state=recent_update_state(states,item)
    if state and state.status=="update" then return "有更新" end
    if item.enabled==false then
        return (trim(item.version)~="" and (trim(item.version).." · ") or "").."未启用"
    end
    if trim(item.version)~="" then return trim(item.version) end
    return "已安装"
end

local function find_managed_by_repo(plugin,repo)
    repo=canonical_repo(repo)
    local list=managed_plugins(plugin)
    for _,item in ipairs(list) do
        if item.ghost~=true and canonical_repo(item.repo)==repo then return item end
    end
    local known=known_repo(repo)
    if known then
        local expected=Catalog.install_dirname(known)
        local match,count=nil,0
        for _,item in ipairs(list) do
            if item.ghost~=true and tostring(item.dir or "")==expected then match=item; count=count+1 end
        end
        if count==1 then return match end
    end
end

local function update_status_for(plugin,item,repo_info,release)
    if type(item)~="table" then return {status="unknown",label="无法自动判断"} end
    local rec=item.record or record_for_installed(plugin,item)
    local release_ref,remote_version=release_marker(release)
    local branch_ref=branch_marker(repo_info)
    local recorded_ref=trim(type(rec)=="table" and rec.remote_ref or "")
    local local_version=trim(item.version)

    -- Compare against the same remote channel that produced the installed copy.
    -- A plugin installed from the default branch must not be reported as having
    -- an update forever just because the repository also has an older Release.
    if recorded_ref:sub(1,7)=="branch:" and branch_ref~="" then
        if recorded_ref==branch_ref then return {status="same",label="已是最新",remote_version="",remote_ref=branch_ref} end
        return {status="update",label="有更新",remote_version="",remote_ref=branch_ref}
    end
    if recorded_ref:sub(1,8)=="release:" and release_ref~="" then
        if recorded_ref==release_ref then return {status="same",label="已是最新",remote_version=remote_version,remote_ref=release_ref} end
        if remote_version~="" and local_version~="" and semver_like(remote_version) and semver_like(local_version) then
            local cmp=U.semver_compare(normalized_version(remote_version),normalized_version(local_version))
            if cmp<=0 then return {status="same",label="已是最新",remote_version=remote_version,remote_ref=release_ref} end
        end
        return {status="update",label="有更新",remote_version=remote_version,remote_ref=release_ref}
    end

    -- Legacy records without a remote marker can still use a trustworthy version
    -- comparison. Otherwise prefer an explicit “unknown” over a false “latest”.
    local marker,version=remote_marker(repo_info,release)
    if version~="" and local_version~="" and semver_like(version) and semver_like(local_version) then
        local cmp=U.semver_compare(normalized_version(version),normalized_version(local_version))
        if cmp>0 then return {status="update",label="有更新",remote_version=version,remote_ref=marker} end
        return {status="same",label="已是最新",remote_version=version,remote_ref=marker}
    end
    if version~="" and local_version~="" and normalized_version(version)==normalized_version(local_version) then
        return {status="same",label="已是最新",remote_version=version,remote_ref=marker}
    end
    return {status="unknown",label="无法自动判断",remote_version=version,remote_ref=marker}
end

local function preflight_package_space(plugin,source,item,entry)
    entry=type(entry)=="table" and entry or {}
    local max_plugin_bytes=tonumber(entry.max_plugin_bytes) or MAX_PLUGIN_BYTES
    local free=U.free_space(default_plugin_root())
    local minimum=tonumber(entry.required_free_bytes) or 0
    local size=tonumber(type(source)=="table" and source.size or 0) or 0
    if size<=0 then return true end
    -- Installation uses same-filesystem rename whenever possible, so updating an
    -- existing plugin does not require a second full copy of the old version.
    -- Reserve package + estimated unpacked data + a small transactional margin.
    local estimated_unpacked=tonumber(entry.estimated_unpacked_bytes) or math.min(max_plugin_bytes,math.max(size*3,8*1024*1024))
    local needed=math.max(minimum,size+estimated_unpacked+16*1024*1024)
    if free and free<needed then
        return nil,"可用存储空间不足；本次安全安装建议至少预留 "..Compat.format_bytes(needed).."。"
    end
    return true
end

local function extension_task(plugin)
    if plugin.extension_task then return plugin.extension_task end
    local ExtensionTask=require("miuread.extension_job")
    plugin.extension_task=ExtensionTask:new(plugin.store)
    return plugin.extension_task
end

local function close_extension_progress(plugin,reason)
    local dialog=plugin._extension_download_dialog
    plugin._extension_download_dialog=nil
    if dialog then pcall(function() dialog:close(reason or "finished") end) end
end

local function show_extension_progress(plugin,display_name)
    close_extension_progress(plugin,"replaced")
    local task=extension_task(plugin)
    local dialog
    dialog=DownloadProgress:new{
        title="正在下载插件 · "..tostring(display_name or "扩展"),
        cancel_text="取消下载",
        pause_text="暂停下载",
        background_text="后台下载",
        on_cancel=function()
            local snapshot=task:snapshot()
            local state=snapshot and tostring(snapshot.state or "") or ""
            if state=="verifying" or state=="extracting" or state=="installing" then
                if type(plugin.status_toast)=="function" then plugin:status_toast("插件安装","当前正在执行本地安装事务，暂不能取消",3) end
                return false
            end
            task:cancel()
            close_extension_progress(plugin,"cancelled")
            if type(plugin.status_toast)=="function" then plugin:status_toast("插件下载","已取消，后台不会自动恢复",3) end
            -- The dialog is already closed. Tell the shared DownloadProgress
            -- widget not to overwrite the final state with “正在取消……”.
            return false
        end,
        on_pause=function()
            local snapshot=task:snapshot()
            local state=snapshot and tostring(snapshot.state or "") or ""
            if state~="downloading" and state~="waiting_network" then
                if type(plugin.status_toast)=="function" then plugin:status_toast("插件安装","当前阶段不能暂停",3) end
                return false
            end
            task:pause("manual")
            if type(plugin.status_toast)=="function" then plugin:status_toast("插件下载","已暂停，断点已保留",3) end
        end,
        on_background=function()
            close_extension_progress(plugin,"background")
            if type(plugin.status_toast)=="function" then plugin:status_toast("插件下载",tostring(display_name or "扩展").."已转入下载中心",3) end
        end,
        on_close=function(widget)
            if plugin._extension_download_dialog==widget then plugin._extension_download_dialog=nil end
        end,
    }
    plugin._extension_download_dialog=dialog
    dialog:show()
    return dialog
end

local bulk_update_failed

local function notify_install_failed(plugin,repo,message)
    if type(bulk_update_failed)=="function" then pcall(bulk_update_failed,plugin,repo,message) end
    if type(plugin._on_extension_install_failed)=="function" then
        local ok,err=pcall(plugin._on_extension_install_failed,plugin,repo,message)
        if not ok then logger.warn("[MiuRead][Extension] install-failed hook failed",tostring(repo),tostring(err)) end
    end
end

local function install_repo(plugin,repo,repo_info,release,forced_source)
    repo=canonical_repo(repo)
    repo_info=type(repo_info)=="table" and repo_info or {}
    local entry,is_curated=install_entry(repo,repo_info)
    local compatibility=Compat.evaluate(entry,plugin)
    if compatibility.installable~=true then
        local message=compatibility.block_reason or "当前设备不支持自动安装此扩展。"
        notify_install_failed(plugin,repo,message)
        plugin:info(message)
        return
    end
    local source,source_error,release_candidates
    if type(release)=="table" then
        source,source_error,release_candidates=Catalog.release_package_source(entry,release,compatibility.arch)
    end
    local pinned_source
    if not source and is_curated and type(entry.package)=="table"
        and (repo_info.release_missing==true or repo_info.release_unusable==true) then
        pinned_source,source_error=Catalog.package_source(entry,compatibility.arch)
        source=pinned_source
    end
    if type(forced_source)=="table" and trim(forced_source.url)~="" then
        local expected=tostring(forced_source.expected_dir or "")
        local repo_dir=Catalog.install_dirname(entry)
        local url=tostring(forced_source.url or "")
        local source_kind=tostring(forced_source.source or "")
        local expected_valid=expected:match("^[%w%._%-]+%.koplugin$")~=nil and expected~="miuread.koplugin"
        local catalog_dir_valid=repo_dir:match("^[%w%._%-]+%.koplugin$")~=nil
        local trusted_dynamic=(source_kind=="github-release-asset" or source_kind=="github-source-verified")
            and url:find("github.com/"..repo.."/",1,true)~=nil and expected_valid
            and (not catalog_dir_valid or expected==repo_dir)
        local static_fallback=is_curated and select(1,Catalog.package_source(entry,compatibility.arch)) or nil
        local expected_static=(source_kind=="catalog-package" or source_kind=="catalog-fallback") and static_fallback or pinned_source
        if expected_static then
            local same=tostring(forced_source.url)==tostring(expected_static.url)
                and tostring(forced_source.sha256 or ""):lower()==tostring(expected_static.sha256 or ""):lower()
                and (tonumber(forced_source.size) or 0)==(tonumber(expected_static.size) or 0)
                and expected==tostring(expected_static.expected_dir or "")
            if not same then
                local message="旧下载任务与当前扩展目录不一致，已停止恢复。\n\n请删除旧下载数据后重新安装。"
                notify_install_failed(plugin,repo,message)
                plugin:info(message)
                return
            end
            source=expected_static
        elseif trusted_dynamic then
            source=U.copy(forced_source)
            source_error=nil
        else
            local message="旧下载任务缺少可验证的正式安装包身份，已停止恢复。\n\n请从插件详情重新安装。"
            notify_install_failed(plugin,repo,message)
            plugin:info(message)
            return
        end
    else
        if not source and type(release_candidates)=="table" and #release_candidates>1
            and source_error=="最新 Release 有多个同等候选安装包，需要选择" then
            local top_score=tonumber(release_candidates[1]._asset_score) or 0
            local rows={}
            for _,candidate in ipairs(release_candidates) do
                if (tonumber(candidate._asset_score) or 0)~=top_score then break end
                local chosen=U.copy(candidate); chosen._asset_score=nil
                rows[#rows+1]={
                    text=tostring(chosen.asset_name or "Release ZIP"),
                    post_text=Compat.format_bytes(tonumber(chosen.size) or 0),
                    callback=function() install_repo(plugin,repo,repo_info,release,chosen) end,
                }
            end
            show_menu(plugin,"选择官方 Release 安装包",rows)
            return
        end
        if not source then
            local release_proved_absent=type(release)~="table" and repo_info.release_missing==true
            local release_proved_unusable=repo_info.release_unusable==true or (type(release)=="table" and source_error=="最新 Release 没有可识别的插件 ZIP")
            if release_proved_absent or release_proved_unusable then
                source,source_error=Catalog.source_package_source(entry,repo_info,type(repo_info)=="table" and repo_info.source_probe or nil)
            end
        end
        if not source then
            local message=source_error or "没有找到可确认的正式 Release 安装包。"
            notify_install_failed(plugin,repo,message)
            plugin:info(message)
            return
        end
    end


    local installed=find_managed_by_repo(plugin,repo)
    if installed and installed.duplicate then
        local message="检测到这个插件存在多个安装位置。\n\n为避免更新错文件，请先只保留一份后再重试。"
        notify_install_failed(plugin,repo,message)
        plugin:info(message)
        return
    end
    local enough,space_error=preflight_package_space(plugin,source,installed,entry)
    if not enough then notify_install_failed(plugin,repo,space_error); plugin:info(space_error); return end

    local display_name=tostring(entry.name or repo_info.name or repo)
    local task=extension_task(plugin)
    local dialog=show_extension_progress(plugin,display_name)

    local function source_attempt_lines(result)
        local rows={}
        for _,attempt in ipairs(type(result)=="table" and result.attempts or {}) do
            if attempt.ok~=true then
                local label=tostring(attempt.label or attempt.key or "下载源")
                local transport=tostring(attempt.transport or "")
                local detail=U.first_line(tostring(attempt.error or attempt.kind or "失败"),160)
                rows[#rows+1]=label..(transport~="" and (" · "..transport) or "").."："..detail
            end
        end
        return rows
    end

    local spec={
        repo=repo,name=display_name,version=tostring(source.version or ""),url=tostring(source.url or ""),
        size=tonumber(source.size) or 0,sha256=tostring(source.sha256 or ""),deterministic=true,
        allow_missing_sha=source.allow_missing_sha==true,
        asset_name=tostring(source.asset_name or ""),expected_dir=tostring(source.expected_dir or ""),
        layout=tostring(source.layout or ""),source=tostring(source.source or "catalog-package"),
        channel=tostring(source.channel or "github-release"),remote_ref=tostring(source.remote_ref or ""),
    }

    local started,start_error=task:start(spec,function(state)
        if dialog and type(dialog.set_state)=="function" then dialog:set_state(state) end
    end,function(value,worker_error,task_snapshot,worker_result)
        if worker_error or type(value)~="table" or not value.path then
            close_extension_progress(plugin,"failed")
            local rows={"扩展下载失败。","","已尝试当前可用下载通道；正式安装包身份没有改变。"}
            local details=source_attempt_lines(worker_result)
            if #details>0 then
                rows[#rows+1]=""
                rows[#rows+1]="尝试记录："
                for _,line in ipairs(details) do rows[#rows+1]="• "..line end
            end
            local final_error=worker_error or (task_snapshot and task_snapshot.error) or "所有可用下载源均失败"
            if trim(final_error)~="" then rows[#rows+1]=""; rows[#rows+1]=U.first_line(final_error,220) end
            local failure_message=table.concat(rows,"\n")
            notify_install_failed(plugin,repo,failure_message)
            plugin:info(failure_message)
            return
        end

        task:set_phase("verifying","安装包大小与 SHA-256 已通过，正在由 KOReader 检查")
        local lease_ok=SuspendWorkLease.acquire("extension_install")
        pcall(PseudoLockscreen.set_task_active,"extension_install",true)
        UIManager:nextTick(function()
            task:set_phase("installing","正在安全安装插件")
            local ok,result,install_error,failed_stage=xpcall(function()
                return ExtensionInstall.install(plugin.store,tostring(task_snapshot and task_snapshot.task_dir or (task:snapshot() or {}).task_dir or ""),value.path,{
                    repo=repo,expected_dir=source.expected_dir,entry=entry,compatibility=compatibility,plugin=plugin,
                    existing_path=installed and installed.path or "",max_plugin_bytes=tonumber(entry.max_plugin_bytes) or MAX_PLUGIN_BYTES,
                    on_phase=function(state,message) task:set_phase(state,message) end,
                })
            end,debug.traceback)
            if lease_ok then SuspendWorkLease.release("extension_install") end
            pcall(PseudoLockscreen.set_task_active,"extension_install",false)
            pcall(PseudoLockscreen.background_task_done,"extension_install")

            if not ok then
                local message=U.first_line(tostring(result),300)
                task:fail_install(message,"install_exception")
                close_extension_progress(plugin,"failed")
                notify_install_failed(plugin,repo,message)
                plugin:info("扩展安装失败。\n\n"..message)
                return
            end
            if not result then
                local message=tostring(install_error or "安装失败")
                task:fail_install(message,tostring(failed_stage or "install"))
                close_extension_progress(plugin,"failed")
                notify_install_failed(plugin,repo,message)
                plugin:info("扩展安装失败。\n\n"..U.first_line(message,300))
                return
            end

            local package_meta=U.copy(source)
            if trim(value.sha256)~="" then package_meta.sha256=trim(value.sha256):lower() end
            if (tonumber(value.bytes) or 0)>0 then package_meta.size=tonumber(value.bytes) end
            local source_kind=tostring(source.source or (is_curated and "catalog-fallback" or "community"))
            remember_install(plugin,repo,result.dir,result.path,
                result.version~="" and result.version or source.version,
                value.used_url or source.url,source.remote_ref,is_curated and "curated" or "community",source_kind,package_meta)
            result.name=display_name
            mark_pending(plugin,result,result.updated and "updated" or "installed")
            local states=update_state(plugin)
            states[canonical_path(result.path)]=nil
            save_update_state(plugin,states)
            task:complete_install{
                install_dir=result.dir,installed_path=result.path,installed_version=result.version,
                source_kind=tostring(source.source or "github"),route_key=value.route_key,transport=value.transport,
            }
            close_extension_progress(plugin,"finished")
            if type(plugin._refresh_miuread_menu)=="function" then plugin:_refresh_miuread_menu() end
            local action=result.updated and "更新完成" or "安装完成"
            local version=result.version~="" and ("\n版本："..result.version) or ""
            local bulk_handled=false
            if type(plugin._extension_bulk_update_success)=="function" then
                local ok_bulk,value=pcall(plugin._extension_bulk_update_success,plugin,repo,result)
                bulk_handled=ok_bulk and value==true
            end
            local handled=false
            if type(plugin._on_extension_install_complete)=="function" then
                local ok_hook,value=pcall(plugin._on_extension_install_complete,plugin,repo,result)
                if not ok_hook then
                    logger.warn("[MiuRead][Extension] install-complete hook failed",tostring(repo),tostring(value))
                else
                    handled=value==true
                end
            end
            if not handled and not bulk_handled then
                plugin:info(action.."："..result.dir..version.."\n\n请完整重启 KOReader 后使用。")
            end
        end)
    end)
    if not started then
        close_extension_progress(plugin,"failed")
        local message="无法启动插件下载任务：\n"..tostring(start_error or "未知错误")
        notify_install_failed(plugin,repo,message)
        plugin:info(message)
        return
    end
    if dialog then dialog:set_state(task:snapshot() or {kind="extension",state="downloading",stage="download"}) end
end

local function start_bulk_update(plugin,entries)
    if type(entries)~="table" or #entries==0 then return false end
    if plugin._extension_bulk_update then plugin:info("已有批量扩展更新正在进行。") return false end
    local queue={}
    for _,entry in ipairs(entries) do
        local item=entry.item or entry
        if item and valid_repo(item.repo) then queue[#queue+1]={repo=canonical_repo(item.repo),name=tostring(item.name or item.dir or item.repo)} end
    end
    if #queue==0 then return false end
    plugin._extension_bulk_update={queue=queue,index=1,success=0,current_repo=""}

    local function finish(message)
        local state=plugin._extension_bulk_update
        plugin._extension_bulk_update=nil
        plugin._extension_bulk_update_success=nil
        plugin._extension_bulk_update_next=nil
        if type(plugin._refresh_miuread_menu)=="function" then plugin:_refresh_miuread_menu() end
        plugin:info(message or ("扩展批量更新完成："..tostring(state and state.success or 0).." 个。\n\n请完整重启 KOReader 后使用更新后的插件。"))
    end

    local function next_one()
        local state=plugin._extension_bulk_update
        if not state then return end
        local row=state.queue[state.index]
        if not row then finish(); return end
        state.current_repo=row.repo
        if type(plugin.status_toast)=="function" then
            plugin:status_toast("批量更新扩展",tostring(state.index).."/"..tostring(#state.queue).." · "..row.name,2.5)
        end
        local started=select(1,run_async_silent(plugin,"extension_bulk_resolve",function()
            local remote,err=resolve_repo_remote_complete(plugin,row.repo)
            return {remote=remote,error=err}
        end,function(value,worker_error)
            local current=plugin._extension_bulk_update
            if not current or current.current_repo~=row.repo then return end
            local remote=type(value)=="table" and value.remote or nil
            if not remote then
                local _,msg=classify_github_error(worker_error or (type(value)=="table" and value.error or nil))
                finish("批量更新在“"..row.name.."”停止："..msg.."。\n\n已经成功更新的插件不会回滚；其余扩展仍保留“有更新”状态，可稍后继续。")
                return
            end
            install_repo(plugin,remote.repo,remote.info,remote.release)
        end,45))
        if not started then
            finish("扩展中心当前有其他任务，批量更新已停止。\n\n没有清除任何剩余更新状态。")
        end
    end

    plugin._extension_bulk_update_success=function(_,repo,result)
        local state=plugin._extension_bulk_update
        if not state or canonical_repo(repo)~=state.current_repo then return false end
        state.success=state.success+1
        state.index=state.index+1
        state.current_repo=""
        UIManager:scheduleIn(.35,next_one)
        return true
    end
    plugin._extension_bulk_update_next=next_one
    UIManager:nextTick(next_one)
    return true
end

bulk_update_failed=function(plugin,repo,message)
    local state=plugin._extension_bulk_update
    if not state or canonical_repo(repo)~=state.current_repo then return false end
    local row=state.queue[state.index] or {}
    local success=tonumber(state.success) or 0
    plugin._extension_bulk_update=nil
    plugin._extension_bulk_update_success=nil
    plugin._extension_bulk_update_next=nil
    logger.warn("[MiuRead][Extensions] bulk update stopped","repo=",tostring(repo),"error=",tostring(message or ""))
    -- The original failure path still shows its precise error. The batch state
    -- is only cleared here; unprocessed plugins keep their update markers.
    if type(plugin.status_toast)=="function" then
        plugin:status_toast("批量更新已停止","已完成 "..tostring(success).." 个 · "..tostring(row.name or repo).." 更新失败",4)
    end
    return true
end

local function format_transfer_bytes(value)
    local n=math.max(0,tonumber(value) or 0)
    if n>=1024*1024*1024 then return string.format("%.1f GB",n/(1024*1024*1024)) end
    if n>=1024*1024 then return string.format("%.1f MB",n/(1024*1024)) end
    if n>=1024 then return string.format("%.0f KB",n/1024) end
    return tostring(math.floor(n+.5)).." B"
end

local function extension_task_label(task)
    task=type(task)=="table" and task or {}
    local state=tostring(task.state or "")
    local labels={
        downloading="正在下载",waiting_network="等待网络",paused_user="已暂停",paused_power="设备休眠",
        paused_priority="同步让路",
        interrupted="可继续",cancelled="已取消",downloaded="下载完成",verifying="正在校验",
        extracting="正在解压",installing="正在安装",completed="安装完成",failed="未完成",
    }
    local label=labels[state] or (state~="" and state or "插件任务")
    local total=tonumber(task.total_bytes or task.size) or 0
    local bytes=tonumber(task.downloaded_bytes) or 0
    local percent=tonumber(task.percent)
    if not percent and total>0 then percent=bytes/total end
    if percent and percent>1 then percent=percent/100 end
    if percent and percent>0 and state~="completed" then label=label.." · "..tostring(math.floor(percent*100+.5)).."%" end
    return label
end

local function show_extension_task_detail(plugin,target)
    local manager=extension_task(plugin)
    local current=manager:snapshot()
    local task=(current and target and current.task_id==target.task_id) and current or target
    if not task then plugin:info("插件下载任务已经不存在。") return end
    local is_current=current and current.task_id==task.task_id
    local state=tostring(task.state or "")

    if is_current and state=="downloading" then
        local dialog=show_extension_progress(plugin,task.name or task.repo)
        manager:set_callbacks(function(progress)
            if dialog then dialog:set_state(progress) end
        end,manager.on_done)
        dialog:set_state(task)
        return
    end

    local rows={extension_task_label(task),tostring(task.name or task.repo or "扩展")}
    local total=tonumber(task.total_bytes or task.size) or 0
    local bytes=tonumber(task.downloaded_bytes) or 0
    if total>0 or bytes>0 then rows[#rows+1]=format_transfer_bytes(bytes)..(total>0 and (" / "..format_transfer_bytes(total)) or "") end
    if tonumber(task.speed_bps or 0)>0 then rows[#rows+1]="速度 "..format_transfer_bytes(task.speed_bps).."/s" end
    if trim(task.message)~="" then rows[#rows+1]=trim(task.message) end
    if trim(task.error)~="" then rows[#rows+1]="\n"..U.first_line(task.error,220) end

    local buttons={}
    local dialog
    if state=="downloaded" then
        buttons[#buttons+1]={{text="继续安装",callback=function()
            UIManager:close(dialog)
            local activated,activate_error=manager:activate(task)
            if not activated then plugin:info(activate_error or "无法切换到此插件任务。") return end
            local spec=type(task.spec)=="table" and U.copy(task.spec) or nil
            if not spec or trim(spec.url)=="" then
                plugin:info("此任务缺少安装包来源信息，请从插件详情重新安装。")
                return
            end
            install_repo(plugin,tostring(task.repo or ""),{
                name=tostring(task.name or task.repo or "扩展"),archived=false,default_branch="main",
                source_probe={installable=nil},
            },nil,spec)
        end}}
    elseif (state=="paused_user" or state=="paused_power" or state=="paused_priority" or state=="waiting_network"
        or state=="interrupted" or state=="cancelled" or state=="failed") then
        buttons[#buttons+1]={{text="继续下载",callback=function()
            UIManager:close(dialog)
            local activated,activate_error=manager:activate(task)
            if not activated then plugin:info(activate_error or "无法切换到此插件任务。") return end
            local spec=type(task.spec)=="table" and U.copy(task.spec) or nil
            if not spec or trim(spec.url)=="" then
                plugin:info("此任务缺少下载来源信息，请从插件详情重新安装。")
                return
            end
            -- Re-enter the package pipeline rather than resuming a transport in
            -- isolation. This reconnects verification/install callbacks after a
            -- KOReader restart while reusing the preserved task/package.part.
            install_repo(plugin,tostring(task.repo or ""),{
                name=tostring(task.name or task.repo or "扩展"),archived=false,default_branch="main",
                source_probe={installable=nil},
            },nil,spec)
        end}}
    end
    if is_current and state=="downloading" then
        buttons[#buttons+1]={{text="暂停下载",callback=function() UIManager:close(dialog); manager:pause("manual") end}}
    end
    if is_current and state~="completed" then
        buttons[#buttons+1]={{text="取消下载",callback=function() UIManager:close(dialog); manager:cancel() end}}
    end
    buttons[#buttons+1]={{text="删除下载数据",callback=function()
        UIManager:close(dialog)
        UIManager:show(ConfirmBox:new{
            text="删除“"..tostring(task.name or task.repo or "插件").."”的插件下载任务和断点？\n\n已安装插件不会被删除。",
            ok_text="删除",cancel_text="取消",
            ok_callback=function() manager:delete_data(task) end,
        })
    end}}
    if state=="completed" and pending_count(plugin)>0 then
        buttons[#buttons+1]={{text="立即重启 KOReader",callback=function()
            UIManager:close(dialog)
            if type(plugin._restart_koreader)=="function" then plugin:_restart_koreader("extension_download_center") end
        end}}
    end
    buttons[#buttons+1]={{text="关闭",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title=table.concat(rows,"\n"),title_align="center",buttons=buttons}
    UIManager:show(dialog)
end

local function extension_download_rows(plugin)
    local manager=extension_task(plugin)
    local rows={}
    for _,task in ipairs(manager:list_tasks(true)) do
        local target=task
        rows[#rows+1]={
            text=tostring(target.name or target.repo or "插件"),
            post_text=extension_task_label(target),
            callback=function() show_extension_task_detail(plugin,target) end,
        }
    end
    return rows
end

local function active_extension_status(plugin,repo)
    local manager=extension_task(plugin)
    local task=manager:snapshot()
    if task and tostring(task.repo or "")==tostring(repo or "") then return extension_task_label(task) end
    return ""
end

local function removable_plugin_copy(path)
    local target=canonical_path(path)
    if target=="" then return nil end
    for _,scan in ipairs(scan_installed()) do
        if canonical_path(scan.canonical_path or scan.path)==target then return scan end
    end
    return nil
end

local function remove_plugin_copy(plugin,item,path)
    local scan=removable_plugin_copy(path)
    if not scan then return false,"插件目录已经不存在或不在 KOReader 插件路径中" end
    if tostring(scan.dir or "")=="miuread.koplugin" then return false,"不能从扩展中心卸载觅阅自身" end
    local removed,err=U.remove_tree(scan.path)
    if not removed then return false,tostring(err or "无法删除插件目录") end
    forget_install(plugin,scan)
    local states=update_state(plugin); states[canonical_path(scan.path)]=nil; save_update_state(plugin,states)
    local dir=tostring(item.dir or scan.dir)
    local remaining=#installed_matches_by_dir(dir)
    mark_pending(plugin,{dir=dir,name=tostring(item.name or scan.name or scan.dir),path=scan.path},remaining>0 and "changed" or "removed")
    return true,nil,remaining
end

local function finish_plugin_uninstall(plugin,name,count,remaining)
    if type(plugin._refresh_miuread_menu)=="function" then plugin:_refresh_miuread_menu() end
    count=tonumber(count) or 1
    remaining=tonumber(remaining) or 0
    if remaining>0 then
        plugin:toast("已删除 "..tostring(count).." 个“"..tostring(name or "插件").."”重复副本 · 仍保留 "..tostring(remaining).." 个，重启后生效",3)
    else
        plugin:toast(tostring(name or "插件").."已卸载"..(count>1 and (" · "..tostring(count).." 个副本") or "").."，重启后完全生效",3)
    end
end

local function uninstall(plugin,item)
    if not item or item.ghost then return end
    local name=tostring(item.name or item.dir or "插件")
    if item.duplicate then
        local paths={}
        for _,path in ipairs(item.duplicate_paths or {}) do if removable_plugin_copy(path) then paths[#paths+1]=path end end
        if #paths==0 then plugin:info("这些重复插件目录已经不存在。") return end
        local dialog
        dialog=ButtonDialog:new{title="检测到 "..tostring(#paths).." 个“"..name.."”副本",title_align="center",buttons={
            {{text="删除全部副本",callback=function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text="删除“"..name.."”的全部 "..tostring(#paths).." 个插件副本？\n\n只删除这些用户插件目录，不删除它们可能保存在 KOReader settings 中的个人设置。",
                    ok_text="全部卸载",cancel_text="取消",
                    ok_callback=function()
                        local removed_count,errors=0,{}
                        local remaining=0
                        for _,path in ipairs(paths) do
                            local ok,err,left=remove_plugin_copy(plugin,item,path)
                            if ok then removed_count=removed_count+1; remaining=tonumber(left) or remaining else errors[#errors+1]=tostring(path).."："..tostring(err) end
                        end
                        if removed_count>0 then finish_plugin_uninstall(plugin,name,removed_count,remaining) end
                        if #errors>0 then plugin:info("部分副本未能删除：\n"..table.concat(errors,"\n")) end
                    end,
                })
            end}},
            {{text="选择副本",callback=function()
                UIManager:close(dialog)
                local rows={}
                for _,path in ipairs(paths) do
                    local selected=path
                    rows[#rows+1]={text=selected,callback=function()
                        UIManager:show(ConfirmBox:new{
                            text="只删除这个插件副本？\n\n"..selected,
                            ok_text="卸载此副本",cancel_text="取消",
                            ok_callback=function()
                                local ok,err,remaining=remove_plugin_copy(plugin,item,selected)
                                if not ok then plugin:info("卸载失败：\n"..tostring(err)); return end
                                finish_plugin_uninstall(plugin,name,1,remaining)
                            end,
                        })
                    end}
                end
                show_menu(plugin,"选择要删除的副本",rows)
            end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        }}
        UIManager:show(dialog)
        return
    end
    if not item.path or item.path=="" or not removable_plugin_copy(item.path) then
        plugin:info("当前无法确认这个插件的实际安装位置，因此不会自动卸载。")
        return
    end
    UIManager:show(ConfirmBox:new{
        text="卸载“"..name.."”？\n\n只删除这个用户插件目录，不删除它可能保存在 KOReader settings 中的个人设置。",
        ok_text="卸载",cancel_text="取消",
        ok_callback=function()
            local removed,err,remaining=remove_plugin_copy(plugin,item,item.path)
            if not removed then plugin:info("卸载失败：\n"..tostring(err or "无法删除插件目录")); return end
            finish_plugin_uninstall(plugin,name,1,remaining)
        end,
    })
end

local function join_list(values,separator)
    local out={}
    for _,value in ipairs(type(values)=="table" and values or {}) do
        value=trim(value)
        if value~="" then out[#out+1]=value end
    end
    return table.concat(out,separator or " / ")
end

local function third_party_install_text(plugin,repo,name)
    local known=known_repo(repo)
    local text="安装“"..tostring(name or repo).."”？\n\n来源：GitHub · "..repo
        .."\n这是第三方扩展，扩展本身由其作者维护；觅阅只负责下载、校验和安装。"
    if known then
        local compatibility=Compat.evaluate(known,plugin)
        if known.dependencies and #known.dependencies>0 then
            text=text.."\n\n外部依赖："..join_list(known.dependencies,"；")
        end
        if compatibility.warnings and #compatibility.warnings>0 then
            text=text.."\n\n注意："..table.concat(compatibility.warnings,"；")
        end
        if compatibility.installable~=true then
            text=text.."\n\n自动安装已阻止："..tostring(compatibility.block_reason or "当前设备不兼容")
        end
    else
        text=text.."\n\n此项目不在觅阅人工推荐库中；安装成功只代表插件包结构通过安全校验，不代表觅阅审核了其功能。"
    end
    text=text.."\n\n安装完成后需要重启 KOReader。"
    return text
end

local function append_catalog_rows(rows,plugin,entry)
    if type(entry)~="table" then return nil end
    local compatibility=Compat.evaluate(entry,plugin)
    local category=Catalog.category_label(entry.category)
    if trim(category)~="" then rows[#rows+1]={text="类别",post_text=category,enabled=false} end
    local capabilities=Catalog.capability_text(entry)
    if capabilities~="" then rows[#rows+1]={text="能力",post_text=capabilities,enabled=false} end
    if trim(entry.author)~="" then rows[#rows+1]={text="作者",post_text=entry.author,enabled=false} end
    if type(entry.platforms)=="table" and #entry.platforms>0 then
        rows[#rows+1]={text="适用平台",post_text=join_list(entry.platforms," / "),enabled=false}
    end
    if type(entry.tested_platforms)=="table" and #entry.tested_platforms>0 then
        rows[#rows+1]={text="已验证",post_text=join_list(entry.tested_platforms," / "),enabled=false}
    end
    if trim(entry.min_koreader)~="" then
        rows[#rows+1]={text="最低 KOReader",post_text=">= "..tostring(entry.min_koreader),enabled=false}
    end
    if type(entry.dependencies)=="table" and #entry.dependencies>0 then
        rows[#rows+1]={text="外部依赖",post_text=join_list(entry.dependencies,"；"),enabled=false}
    else
        rows[#rows+1]={text="外部依赖",post_text="无额外服务依赖",enabled=false}
    end
    if entry.network_required==true then
        rows[#rows+1]={text="网络",post_text="使用功能时需要",enabled=false}
    elseif entry.network_required==false then
        rows[#rows+1]={text="网络",post_text="功能可离线（安装/更新仍需网络）",enabled=false}
    end
    if trim(entry.package_note)~="" then rows[#rows+1]={text="体积",post_text=entry.package_note,enabled=false} end
    if tonumber(entry.required_free_bytes) then
        rows[#rows+1]={text="建议可用空间",post_text=Compat.format_bytes(entry.required_free_bytes),enabled=false}
    end
    rows[#rows+1]={text="当前设备",post_text=tostring(compatibility.platform_label).." · "..tostring(compatibility.arch_raw),enabled=false}
    if entry.architecture_sensitive==true then
        rows[#rows+1]={text="架构要求",post_text=join_list(entry.supported_arches," / "),enabled=false}
    end
    if entry.ui_conflict==true then
        rows[#rows+1]={text="觅阅桌面",post_text=compatibility.miuread_desktop and "功能重叠 · 建议插件模式" or "当前未启用觅阅桌面",enabled=false}
    else
        rows[#rows+1]={text="觅阅桌面",post_text="未标记冲突",enabled=false}
    end
    if entry.experimental==true then rows[#rows+1]={text="实验状态",post_text="Beta / 实验性",enabled=false} end
    if trim(entry.recommendation)~="" and entry.recommended==true then
        rows[#rows+1]={text="推荐理由",post_text=entry.recommendation,enabled=false}
    end
    if compatibility.warnings and #compatibility.warnings>0 then
        for _,warning in ipairs(compatibility.warnings) do rows[#rows+1]={text="注意",post_text=warning,enabled=false} end
    end
    if compatibility and compatibility.installable~=true then
        rows[#rows+1]={text="自动安装",post_text=compatibility.block_reason or "当前设备不兼容",enabled=false}
    else
        rows[#rows+1]={text="自动安装",post_text="读取官方最新可安装稳定版",enabled=false}
    end
    return compatibility
end

local function external_entry_rows(plugin,entry)
    local rows={
        {text=tostring(entry.description or "暂无简介"),enabled=false},
    }
    append_catalog_rows(rows,plugin,entry)
    rows[#rows+1]={text="来源",post_text="作者发布渠道",enabled=false}
    rows[#rows+1]={text="安装方式",post_text="暂不由觅阅代为下载安装",enabled=false}
    rows[#rows+1]={text="说明",post_text="没有可持续验证的官方公开仓库时，觅阅不会猜测下载地址或代替作者分发安装包。",enabled=false}
    return rows
end

local function native_open_row(plugin,item)
    local entry=item.native and NativePlugins.entry(plugin,item.native) or nil
    if type(entry)~="table" then return nil end
    if entry.sub_item_table_func or entry.sub_item_table then
        return {text="打开插件",sub_item_table_func=entry.sub_item_table_func,sub_item_table=entry.sub_item_table}
    end
    if type(entry.callback)=="function" then
        return {text="打开插件",callback=entry.callback,keep_menu_open=entry.keep_menu_open==true}
    end
end

-- Menu presentation order only. Never remove compatibility or package facts.
local function prioritize_extension_rows(rows)
    local warnings, actions, details = {}, {}, {}
    for _,row in ipairs(rows or {}) do
        local label=tostring(row.text or "")
        if label=="注意" or label=="一键安装不可用" or label=="自动安装不可用"
            or label=="自动更新已停用" or label=="重复安装"
            or label:find("插件状态",1,true)==1
            or label:find("当前更改",1,true)==1
            or label:find("仓库状态",1,true)==1
            or label:find("网络状态",1,true)==1
            or label:find("自动更新/重装",1,true)==1 then
            warnings[#warnings+1]=row
        elseif row.enabled==false and not row.callback and not row.sub_item_table_func then
            details[#details+1]=row
        else
            actions[#actions+1]=row
        end
    end
    local ordered={}
    for _,row in ipairs(warnings) do ordered[#ordered+1]=row end
    for _,row in ipairs(actions) do ordered[#ordered+1]=row end
    if #details>0 then
        ordered[#ordered+1]={text="详细信息",sub_item_table_func=function() return details end}
    end
    return ordered
end

local function repo_detail_rows(plugin,repo,info,release,fallback,stale)
    repo=canonical_repo(repo)
    local catalog_entry=known_repo(repo)
    fallback=catalog_entry or (type(fallback)=="table" and fallback or {})
    info=type(info)=="table" and info or {}
    local installed=find_managed_by_repo(plugin,repo)
    local description=trim(fallback.description or info.description or "")
    if description=="" then description="暂无简介" end
    local marker,remote_version=remote_marker(info,release)
    local rows={
        {text=repo,enabled=false},
        {text=description,enabled=false},
    }
    local compatibility
    if catalog_entry then
        compatibility=append_catalog_rows(rows,plugin,catalog_entry)
        rows[#rows+1]={text="可信等级",post_text="觅阅推荐 · 自动跟随官方稳定版",enabled=false}
    else
        local author=tostring(repo or ""):match("^([^/]+)/") or "未知"
        rows[#rows+1]={text="作者",post_text=author,enabled=false}
        rows[#rows+1]={text="可信等级",post_text="社区扩展 · 自动结构检查",enabled=false}
    end
    rows[#rows+1]={text="来源",post_text="GitHub · 第三方扩展",enabled=false}
    rows[#rows+1]={text="仓库",post_text=repo,enabled=false}
    rows[#rows+1]={text="社区",post_text=tostring(info.stargazers_count or 0).." ★",enabled=false}
    if stale then rows[#rows+1]={text="网络状态",post_text="显示上次获取的信息",enabled=false} end
    if remote_version~="" then rows[#rows+1]={text="远端版本",post_text=remote_version,enabled=false} end
    if info.archived==true then
        rows[#rows+1]={text="仓库状态",post_text=fallback.allow_archived_install==true and "已归档 · 仅使用已发布 Release" or "已归档",enabled=false}
    end

    local resolver_entry=install_entry(repo,info)
    compatibility=compatibility or Compat.evaluate(resolver_entry,plugin)
    local catalog_source,catalog_source_error,catalog_candidates
    if compatibility.installable==true and type(release)=="table" then
        catalog_source,catalog_source_error,catalog_candidates=Catalog.release_package_source(resolver_entry,release,compatibility.arch)
    end
    if not catalog_source then
        local release_proved_absent=type(release)~="table" and info.release_missing==true
        local release_proved_unusable=info.release_unusable==true
        if release_proved_absent or release_proved_unusable then
            catalog_source,catalog_source_error=Catalog.source_package_source(resolver_entry,info,info.source_probe)
            if not catalog_source and catalog_entry and type(catalog_entry.package)=="table" then
                catalog_source,catalog_source_error=Catalog.package_source(catalog_entry,compatibility.arch)
            end
        end
    end
    local ambiguous_release=type(catalog_candidates)=="table" and #catalog_candidates>1
        and catalog_source_error=="最新 Release 有多个同等候选安装包，需要选择"
    local auto_allowed=(catalog_source~=nil or ambiguous_release)
        and (info.archived~=true or fallback.allow_archived_install==true)
        and (not compatibility or compatibility.installable==true)
    local block_reason=compatibility and compatibility.block_reason or catalog_source_error or "没有找到可安全自动安装的插件包"

    if installed then
        local open_row=native_open_row(plugin,installed)
        if open_row then rows[#rows+1]=open_row end
        local settings_row=installed.native and NativePlugins.settings_entry(plugin,installed.native) or nil
        if settings_row then rows[#rows+1]=settings_row end
        if installed.enabled==false then rows[#rows+1]={text="插件状态",post_text="未启用",enabled=false} end
        rows[#rows+1]={text="当前版本",post_text=installed.version~="" and installed.version or installed.dir,enabled=false}
        if catalog_entry and catalog_entry.lockscreen_provider and type(plugin._request_lockscreen_provider)=="function" then
            rows[#rows+1]={text="设为锁屏壁纸",post_text=catalog_entry.lockscreen_provider=="inkstain" and "墨痕壁纸" or "DashWallpaper",callback=function()
                plugin:_request_lockscreen_provider(catalog_entry.lockscreen_provider)
            end}
        end
        if installed.pending then
            rows[#rows+1]={text="当前更改",post_text=pending_label(installed.pending),enabled=false}
            if trim(installed.runtime_version)~="" and trim(installed.runtime_version)~=trim(installed.version) then
                rows[#rows+1]={text="当前运行版本",post_text=installed.runtime_version,enabled=false}
            end
        end
        if installed.duplicate then
            rows[#rows+1]={text="重复安装",post_text=tostring(#(installed.duplicate_paths or {})).." 个位置",enabled=false}
            for _,path in ipairs(installed.duplicate_paths or {}) do rows[#rows+1]={text=path,enabled=false} end
            rows[#rows+1]={text="自动更新已停用",post_text="请先处理重复副本",enabled=false}
            rows[#rows+1]={text="卸载插件副本",callback=function() uninstall(plugin,installed) end}
        else
            local status=update_status_for(plugin,installed,info,release)
            if auto_allowed then
                if status.status=="update" then
                    rows[#rows+1]={text="更新扩展",post_text=status.remote_version~="" and status.remote_version or "有更新",callback=function()
                        UIManager:show(ConfirmBox:new{
                            text="更新“"..tostring(installed.name).."”？\n\n安装前会备份当前插件，写入失败会自动恢复。",
                            ok_text="更新",cancel_text="取消",
                            ok_callback=function() install_repo(plugin,repo,info,release) end,
                        })
                    end}
                elseif status.status=="same" then
                    rows[#rows+1]={text="更新状态",post_text="已是最新",enabled=false}
                    rows[#rows+1]={text="重新安装",callback=function()
                        UIManager:show(ConfirmBox:new{
                            text="重新安装“"..tostring(installed.name).."”？\n\n当前版本会先备份，安装失败自动恢复。",
                            ok_text="重新安装",cancel_text="取消",
                            ok_callback=function() install_repo(plugin,repo,info,release) end,
                        })
                    end}
                else
                    rows[#rows+1]={text="更新状态",post_text="无法自动判断",enabled=false}
                    rows[#rows+1]={text="手动重新安装",callback=function()
                        UIManager:show(ConfirmBox:new{
                            text="无法可靠比较这个插件的版本。\n\n是否从当前 GitHub 仓库重新安装？旧版本会先备份。",
                            ok_text="重新安装",cancel_text="取消",
                            ok_callback=function() install_repo(plugin,repo,info,release) end,
                        })
                    end}
                end
            else
                rows[#rows+1]={text="自动更新/重装",post_text=block_reason or (info.archived==true and "仓库已归档" or "当前条件不支持"),enabled=false}
            end
            rows[#rows+1]={text="卸载插件",callback=function() uninstall(plugin,installed) end}
        end
    else
        if auto_allowed and catalog_entry and catalog_entry.lockscreen_provider and type(plugin._request_lockscreen_provider)=="function" then
            rows[#rows+1]={text="安装并设为锁屏",post_text=catalog_entry.lockscreen_provider=="inkstain" and "墨痕壁纸" or "DashWallpaper",callback=function()
                plugin:_request_lockscreen_provider(catalog_entry.lockscreen_provider)
            end}
        end
        if auto_allowed then
            rows[#rows+1]={text="安装扩展",callback=function()
                UIManager:show(ConfirmBox:new{
                    text=third_party_install_text(plugin,repo,display_repo_name(info,fallback)),
                    ok_text="安装",cancel_text="取消",
                    ok_callback=function() install_repo(plugin,repo,info,release) end,
                })
            end}
        else
            rows[#rows+1]={text="一键安装不可用",post_text=block_reason or (info.archived==true and "仓库已归档" or "当前条件不支持"),enabled=false}
        end
    end
    return prioritize_extension_rows(rows)
end

local function repo_detail(plugin,repo,fallback,force)
    repo=canonical_repo(repo)
    if not valid_repo(repo) then plugin:info("GitHub 仓库地址无效") return end
    fallback=known_repo(repo) or fallback
    local cached=not force and meta_cache_get(plugin,repo,false) or nil
    if cached then
        return show_menu(plugin,"扩展 · "..display_repo_name(cached.repo_info,fallback),repo_detail_rows(plugin,repo,cached.repo_info,cached.release,fallback,false))
    end
    run_async_with_progress(plugin,"正在读取扩展信息……","extension_repo_detail",function()
        local remote,remote_error=resolve_repo_remote_complete(plugin,repo)
        if not remote then return {info=nil,error=remote_error} end
        return {
            info=remote.info,release=remote.release,release_error=remote.source_error,
            release_missing=remote.release_missing,release_unusable=remote.release_unusable,
        }
    end,function(value,worker_error)
        local info=type(value)=="table" and value.info or nil
        local err=worker_error or (type(value)=="table" and value.error or nil)
        if not info then
            local stale=meta_cache_get(plugin,repo,true)
            if stale then
                show_menu(plugin,"扩展 · "..display_repo_name(stale.repo_info,fallback),repo_detail_rows(plugin,repo,stale.repo_info,stale.release,fallback,true))
                return
            end
            local _,message=classify_github_error(err)
            plugin:info(message.."。")
            return
        end
        info.release_missing=value.release_missing==true
        info.release_unusable=value.release_unusable==true
        meta_cache_put(plugin,repo,info,value.release,value.release_missing==true)
        show_menu(plugin,"扩展 · "..display_repo_name(info,fallback),repo_detail_rows(plugin,repo,info,value.release,fallback,false))
    end,45)
end

local function search_cache(plugin)
    local value=plugin.store:get(SEARCH_CACHE_KEY,{entries={}})
    value=type(value)=="table" and value or {entries={}}
    value.entries=type(value.entries)=="table" and value.entries or {}
    return value
end

local function search_cache_get(plugin,key,allow_stale)
    local value=search_cache(plugin)
    local entry=value.entries[key]
    if type(entry)~="table" then return nil end
    local age=os.time()-(tonumber(entry.updated_at) or 0)
    if allow_stale==true or age<=SEARCH_TTL then return entry,age>SEARCH_TTL end
end

local function search_cache_put(plugin,key,data)
    local value=search_cache(plugin)
    data=type(data)=="table" and data or {}
    data.updated_at=os.time()
    value.entries[key]=data
    prune_cache_entries(value.entries,50)
    plugin.store:set_deferred(SEARCH_CACHE_KEY,value)
    plugin.store:flush()
end

local function sanitize_repo(repo)
    if type(repo)~="table" then return nil end
    local full=tostring(repo.full_name or "")
    if not valid_repo(full) or full==SELF_REPO or repo.archived==true then return nil end
    return {
        full_name=full,name=tostring(repo.name or full),description=tostring(repo.description or ""),
        stargazers_count=tonumber(repo.stargazers_count) or 0,archived=repo.archived==true,fork=repo.fork==true,
        topics=type(repo.topics)=="table" and repo.topics or {},
    }
end

local function repo_is_probably_plugin(repo)
    if type(repo)~="table" then return false end
    local name=tostring(repo.name or ""):lower()
    local description=tostring(repo.description or ""):lower()
    if name:match("%.koplugin$") then return true end
    for _,topic in ipairs(repo.topics or {}) do if tostring(topic):lower()=="koreader-plugin" then return true end end
    return name:find("koreader",1,true)~=nil or description:find("koreader",1,true)~=nil
end

local function search_api(plugin,query,page,sort)
    local url="https://api.github.com/search/repositories?q="..url_encode(query)
    if sort=="stars" then url=url.."&sort=stars&order=desc" end
    url=url.."&per_page="..tostring(MAX_RESULTS).."&page="..tostring(math.max(1,tonumber(page) or 1))
    return github_json(plugin,url)
end

local function search_network(plugin,query,page,mode)
    page=math.max(1,tonumber(page) or 1)
    local out,seen={},{}
    local has_more=false
    local function add(repo,rank)
        repo=sanitize_repo(repo)
        if not repo or seen[repo.full_name] then return end
        seen[repo.full_name]=true; repo._rank=rank or (#out+1); out[#out+1]=repo
    end

    if mode=="popular" then
        local data,err=search_api(plugin,"topic:koreader-plugin",page,"stars")
        if not data then return nil,err end
        local raw=type(data.items)=="table" and data.items or {}
        for _,repo in ipairs(raw) do if not repo.fork then add(repo,#out+1) end end
        has_more=(tonumber(data.total_count) or 0)>page*MAX_RESULTS
        return {items=out,has_more=has_more,page=page,mode=mode,query="topic:koreader-plugin"}
    end

    if page==1 then
        for _,known in ipairs(alias_matches(query)) do
            add({full_name=known.repo,name=known.name,description=known.description,stargazers_count=0,topics={"koreader-plugin"}},-100+#out)
        end
    end
    local strict,strict_err=search_api(plugin,query.." topic:koreader-plugin",page,nil)
    if strict then
        local raw=type(strict.items)=="table" and strict.items or {}
        for _,repo in ipairs(raw) do add(repo,#out+1) end
        if (tonumber(strict.total_count) or 0)>page*MAX_RESULTS then has_more=true end
    elseif #out==0 then
        logger.warn("[MiuRead][Extensions] strict search failed",tostring(strict_err))
    end

    -- A full page of tagged repositories can still miss the exact plugin the
    -- user typed when that repository forgot to add the koreader-plugin topic.
    -- Expand not only for a short result list, but also when no exact/prefix
    -- repository name matched the query. This keeps named searches complete
    -- without turning every generic community browse into a broad GitHub query.
    local query_key=normalized_alias(query)
    local strong_match=false
    if query_key~="" then
        for _,repo in ipairs(out) do
            local name_key=normalized_alias(repo.name)
            if name_key==query_key or name_key:sub(1,#query_key)==query_key then strong_match=true; break end
        end
    end
    if #out<8 or not strong_match then
        local broad,broad_err=search_api(plugin,query.." in:name,description",page,nil)
        if broad then
            local raw=type(broad.items)=="table" and broad.items or {}
            for _,repo in ipairs(raw) do if repo_is_probably_plugin(repo) then add(repo,#out+100) end end
            if (tonumber(broad.total_count) or 0)>page*MAX_RESULTS then has_more=true end
        elseif #out==0 then
            return nil,broad_err or strict_err
        end
    end

    local key=normalized_alias(query)
    table.sort(out,function(a,b)
        local an=normalized_alias(a.name)
        local bn=normalized_alias(b.name)
        local function score(name,rank)
            if name==key then return -20 end
            if key~="" and name:sub(1,#key)==key then return -10 end
            return tonumber(rank) or 0
        end
        local as,bs=score(an,a._rank),score(bn,b._rank)
        if as~=bs then return as<bs end
        return tostring(a.name):lower()<tostring(b.name):lower()
    end)
    return {items=out,has_more=has_more,page=page,mode=mode,query=query}
end

local function show_search_results(plugin,data,title,stale)
    local rows={}
    local installed=managed_repo_map(plugin)
    local states=update_state(plugin)
    for _,repo in ipairs(type(data.items)=="table" and data.items or {}) do
        local full=repo.full_name
        local known=known_repo(full)
        local name=(known and known.name) or repo.name or full
        local local_item=installed[canonical_repo(full)]
        local post
        if local_item then
            post=installed_status_label(plugin,local_item,states)
        else
            post=(tonumber(repo.stargazers_count) or 0)>0 and (tostring(repo.stargazers_count).." ★") or full
        end
        rows[#rows+1]={
            text=name,post_text=post,keep_menu_open=true,
            callback=function() repo_detail(plugin,full,{name=name,description=repo.description}) end,
        }
    end
    if stale then rows[#rows+1]={text="GitHub 暂时无法连接，以上为上次结果",enabled=false} end
    if data.has_more==true then
        rows[#rows+1]={text="查看更多结果",keep_menu_open=true,callback=function()
            local mode=tostring(data.mode or "search")
            local query=tostring(data.query or "")
            local page=(tonumber(data.page) or 1)+1
            local next_title=(mode=="popular" and "社区热门" or ("搜索 · "..query)).." · 第"..tostring(page).."页"
            local key=mode.."|"..query.."|"..tostring(page)
            local cached=search_cache_get(plugin,key,false)
            if cached then show_search_results(plugin,cached,next_title,false) return end
            run_async_with_progress(plugin,"正在加载更多结果……","extension_search_more",function()
                local next_data,err=search_network(plugin,query,page,mode)
                return {data=next_data,error=err}
            end,function(value,worker_error)
                local next_data=type(value)=="table" and value.data or nil
                local err=worker_error or (type(value)=="table" and value.error or nil)
                if not next_data then
                    local stale_data=search_cache_get(plugin,key,true)
                    if stale_data then show_search_results(plugin,stale_data,next_title,true); return end
                    local _,message=classify_github_error(err); plugin:info(message.."。")
                    return
                end
                search_cache_put(plugin,key,next_data)
                show_search_results(plugin,next_data,next_title,false)
            end,45)
        end}
    end
    if #rows==0 then plugin:info("没有找到相关 KOReader 扩展。") return end
    show_menu(plugin,title,rows)
end

local function github_search(plugin,query,title,page,mode,force)
    query=trim(query)
    mode=tostring(mode or "search")
    page=math.max(1,tonumber(page) or 1)
    if mode=="popular" then query="topic:koreader-plugin" end
    if query=="" then return end
    local key=mode.."|"..query.."|"..tostring(page)
    if not force then
        local cached=search_cache_get(plugin,key,false)
        if cached then show_search_results(plugin,cached,title,false); return end
    end
    run_async_with_progress(plugin,mode=="popular" and "正在读取社区热门扩展……" or "正在搜索扩展……","extension_search",function()
        local data,err=search_network(plugin,query,page,mode)
        return {data=data,error=err}
    end,function(value,worker_error)
        local data=type(value)=="table" and value.data or nil
        local err=worker_error or (type(value)=="table" and value.error or nil)
        if not data then
            local stale=search_cache_get(plugin,key,true)
            if stale then show_search_results(plugin,stale,title,true); return end
            local _,message=classify_github_error(err)
            plugin:info(message.."。")
            return
        end
        search_cache_put(plugin,key,data)
        show_search_results(plugin,data,title,false)
    end,45)
end

local function show_search_dialog(plugin)
    local dialog
    dialog=InputDialog:new{
        title="搜索扩展",
        description="搜索 GitHub KOReader 社区扩展。中文名称会自动匹配已知仓库；结果按相关度显示。",
        input="",
        buttons={{
            {text="取消",id="close",callback=function() UIManager:close(dialog) end},
            {text="搜索",is_enter_default=true,callback=function()
                local query=trim(dialog:getInputText())
                UIManager:close(dialog)
                if query=="" then return end
                UIManager:nextTick(function() github_search(plugin,query,"搜索 · "..query,1,"search",false) end)
            end},
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function center_about(plugin)
    plugin:info(
        "觅阅扩展中心 · "..tostring(Config.VERSION).."\n\n"
        .."“觅阅推荐”是面向中文 KOReader 用户的人工精选；“社区热门”和“搜索扩展”仍直接使用 GitHub 社区结果，不会因为觅阅没有推荐某个项目而把它隐藏。\n\n"
        .."GitHub 官方近期正式 Release 决定版本和正式安装包；觅阅推荐只提供信任、兼容性和安装规则，不再把目录中曾验证过的版本当成最新版。GitHub 中文社区是自动模式的首选下载通道，GitHub 官方与现有代理作为后备；所有通道只传输同一个正式 ZIP。大文件会做有界线路探测，并优先继续已有断点。\n\n"
        .."下载慢不会因为短时间低速被判失败；大文件使用可恢复下载，网络中断后保留进度。文件完成后先核对官方大小与 SHA-256（可用时），再交给 KOReader Archiver 检查 ZIP、路径、插件结构、体积、剩余空间和 CPU/ELF 兼容性。社区扩展只要能从官方 Release 唯一确定插件 ZIP 与安装目录，也可以直接安装；源码 ZIP 只有在官方 Release 确认没有可用安装包且 GitHub Contents API 已证明源码本身是完整插件时才允许使用。\n\n"
        .."安装使用临时切换与恢复记录，失败或异常中断会优先保住旧插件；阅读进度、阅读结束和批注等关键云端写入会临时让后台书籍/插件下载让路，完成后继续断点。第三方扩展由其作者维护，安装、更新或卸载后请完整重启 KOReader。"
    )
end

local function curated_package_detail_rows(plugin,entry)
    -- Kept as a compatibility helper for older menu closures. beta.17 no longer
    -- renders a pinned catalogue version; recommendations resolve GitHub live.
    repo_detail(plugin,tostring(entry.repo or ""),entry)
    return {}
end

local function recommendation_entry_row(plugin,entry,installed,states)
    local post=trim(entry.recommendation)
    if entry.experimental==true then post=post~="" and (post.." · Beta") or "Beta" end
    if entry.install_strategy=="external_manual" or entry.auto_install==false then
        post=post~="" and (post.." · 手动安装") or "手动安装"
    end
    if valid_repo(entry.repo) then
        local item=installed[entry.repo]
        local status=""
        if item then
            local state=recent_update_state(states,item)
            if item.pending then status=pending_label(item.pending)
            elseif item.duplicate then status="重复安装"
            elseif state and state.status=="update" then status="有更新"
            else status="已安装" end
        end
        local transfer=active_extension_status(plugin,entry.repo)
        if transfer~="" and transfer~="安装完成" then status=transfer end
        -- Recommendation rows intentionally never show a catalogue or local
        -- version number. The detail page resolves GitHub live; the catalogue
        -- version is only a verified fallback artifact identity.
        if status~="" then post=post~="" and (post.." · "..status) or status end
    end
    local target=entry
    return {
        text=tostring(target.name or target.repo or target.id),post_text=post,keep_menu_open=true,
        callback=function()
            if valid_repo(target.repo) then
                repo_detail(plugin,target.repo,target)
            else
                show_menu(plugin,"扩展 · "..tostring(target.name or target.id),external_entry_rows(plugin,target))
            end
        end,
    }
end

local function recommendation_category_menu(plugin,key)
    local category=Catalog.category(key)
    local rows={}
    if category then rows[#rows+1]={text=tostring(category.detail or "觅阅人工整理"),enabled=false} end
    local installed=managed_repo_map(plugin)
    local states=update_state(plugin)
    for _,entry in ipairs(Catalog.category_entries(key)) do
        rows[#rows+1]=recommendation_entry_row(plugin,entry,installed,states)
    end
    if #rows==(category and 1 or 0) then rows[#rows+1]={text="当前分类暂无推荐扩展",enabled=false} end
    return rows
end

local function recommendation_menu(plugin)
    local rows={
        {text="第三方扩展 · 觅阅人工整理 · 版本自动跟随作者",enabled=false},
        {text="精选推荐",separator=true,enabled=false},
    }
    local installed=managed_repo_map(plugin)
    local states=update_state(plugin)
    for _,entry in ipairs(Catalog.featured_entries()) do
        rows[#rows+1]=recommendation_entry_row(plugin,entry,installed,states)
    end
    rows[#rows+1]={text="分类",separator=true,enabled=false}
    for _,category in ipairs(Catalog.CATEGORIES) do
        local entries=Catalog.category_entries(category.key)
        local target=category
        rows[#rows+1]={
            text=target.label,
            post_text=(#entries>0 and (tostring(#entries).." 个") or "")..(trim(target.detail)~="" and (" · "..target.detail) or ""),
            sub_item_table_func=function() return recommendation_category_menu(plugin,target.key) end,
        }
    end
    rows[#rows+1]={text="说明",separator=true,enabled=false}
    rows[#rows+1]={text="完整桌面/UI 替代插件不进入觅阅推荐",post_text="仍可在社区热门和搜索中找到",enabled=false}
    return rows
end

local function discovery_menu(plugin)
    return {
        {text="觅阅推荐",post_text="人工精选 · 自动跟随稳定版",sub_item_table_func=function() return recommendation_menu(plugin) end},
        {text="搜索扩展",keep_menu_open=true,callback=function() show_search_dialog(plugin) end},
        {text="社区热门",post_text="GitHub",keep_menu_open=true,callback=function() github_search(plugin,"topic:koreader-plugin","社区热门",1,"popular",false) end},
        {text="关于扩展中心",callback=function() center_about(plugin) end},
    }
end

local function remote_update_status(plugin,item,remote)
    if not remote then return {status="unknown",label="无法读取 GitHub"} end
    if remote.compatibility and remote.compatibility.installable~=true then
        return {status="blocked",label=remote.compatibility.block_reason or "当前设备不兼容"}
    end
    return update_status_for(plugin,item,remote.info,remote.release)
end

local function trackable_plugins(plugin)
    local items={}
    for _,item in ipairs(managed_plugins(plugin)) do
        if item.ghost~=true and item.duplicate~=true and valid_repo(item.repo) then items[#items+1]=item end
    end
    return items
end

local function update_summary(plugin)
    local items=trackable_plugins(plugin)
    local states=update_state(plugin)
    local updates=0
    for _,item in ipairs(items) do
        local state=recent_update_state(states,item)
        if state and state.status=="update" then updates=updates+1 end
    end
    local meta=update_check_meta(plugin)
    local successful_at=tonumber(meta.last_successful_check_at) or 0
    local fresh=successful_at>0 and os.time()-successful_at<=UPDATE_VISIBLE_TTL
    return {
        trackable=#items,updates=updates,checking=plugin._extension_update_checking==true,
        checked_fresh=fresh,last_successful_check_at=successful_at,
        last_attempt_at=tonumber(meta.last_attempt_at) or 0,
        last_error=tostring(meta.last_error or ""),
    }
end

local function apply_update_results(plugin,items,results,worker_error,options)
    options=type(options)=="table" and options or {}
    plugin._extension_update_checking=false
    local now=os.time()
    local meta=update_check_meta(plugin)
    meta.last_attempt_at=now
    if type(results)~="table" then
        local _,message=classify_github_error(worker_error)
        meta.last_error=message
        save_update_check_meta(plugin,meta)
        if not options.silent then plugin:info(message.."。") end
        return false
    end
    local states=update_state(plugin)
    local updates,unknown,blocked,known=0,0,0,0
    for _,status in ipairs(results) do
        local key=tostring(status.key or "")
        local previous=type(states[key])=="table" and states[key] or nil
        local previous_recent=previous and (os.time()-(tonumber(previous.checked_at) or 0)<=UPDATE_VISIBLE_TTL)
        -- A transient GitHub/network failure must not erase a recently known
        -- update. Keep the last trustworthy result until it expires or a later
        -- successful check supersedes it.
        if status.status=="unknown" and previous_recent
            and (previous.status=="update" or previous.status=="same" or previous.status=="blocked") then
            -- retain previous known state
        else
            states[key]=status
        end
        if status.status=="update" then updates=updates+1; known=known+1
        elseif status.status=="same" then known=known+1
        elseif status.status=="unknown" then unknown=unknown+1
        elseif status.status=="blocked" then blocked=blocked+1; known=known+1 end
    end
    save_update_state(plugin,states)
    if #results==0 or unknown==0 then
        meta.last_successful_check_at=now
        meta.last_error=""
    elseif known>0 then
        -- Partial checks are useful for per-plugin state but cannot certify
        -- “全部已是最新” for the whole list.
        meta.last_error="部分扩展暂时无法检查"
    else
        meta.last_error="暂时无法连接扩展来源"
    end
    save_update_check_meta(plugin,meta)
    if type(plugin._refresh_miuread_menu)=="function" then plugin:_refresh_miuread_menu() end
    if not options.silent then
        local msg="检查完成："..tostring(#results).." 个扩展"
        if updates>0 then msg=msg.."\n发现更新："..tostring(updates) end
        if unknown>0 then msg=msg.."\n无法判断："..tostring(unknown) end
        if blocked>0 then msg=msg.."\n当前设备不兼容："..tostring(blocked) end
        plugin:info(msg)
    elseif updates>0 and options.notify_updates==true and type(plugin.status_toast)=="function" then
        plugin:status_toast("扩展更新","发现 "..tostring(updates).." 个可更新扩展",3)
    end
    if type(options.done)=="function" then pcall(options.done,update_summary(plugin)) end
    return true
end

local function check_updates(plugin,options)
    options=type(options)=="table" and options or {}
    local items=trackable_plugins(plugin)
    if #items==0 then
        local meta=update_check_meta(plugin)
        meta.last_attempt_at=os.time(); meta.last_successful_check_at=os.time(); meta.last_error=""
        save_update_check_meta(plugin,meta)
        if not options.silent then plugin:info("暂无可检查更新的 GitHub 扩展。") end
        return false
    end
    if plugin._extension_update_checking==true then return false end
    plugin._extension_update_checking=true
    local meta=update_check_meta(plugin); meta.last_attempt_at=os.time(); save_update_check_meta(plugin,meta)
    local function work()
        local results={}
        for _,item in ipairs(items) do
            local remote,err=resolve_repo_remote_complete(plugin,item.repo)
            local status=remote_update_status(plugin,item,remote)
            if not remote then status.label=select(2,classify_github_error(err)) end
            status.key=update_key(item); status.repo=canonical_repo(item.repo); status.checked_at=os.time()
            results[#results+1]=status
        end
        return results
    end
    local function done(results,worker_error)
        apply_update_results(plugin,items,results,worker_error,options)
    end
    local started
    if options.silent then
        started=select(1,run_async_silent(plugin,"extension_check_updates_silent",work,done,math.max(45,#items*12)))
    else
        started=run_async_with_progress(plugin,"正在检查扩展更新……","extension_check_updates",work,done,math.max(45,#items*12))
    end
    if not started then
        plugin._extension_update_checking=false
        return false
    end
    return true
end

local function maybe_auto_check(plugin,reason)
    local summary=update_summary(plugin)
    if summary.trackable<=0 or summary.checking then return false end
    local now=os.time()
    if summary.last_successful_check_at>0 and now-summary.last_successful_check_at<UPDATE_AUTO_INTERVAL then return false end
    if summary.last_attempt_at>0 and now-summary.last_attempt_at<UPDATE_RETRY_INTERVAL then return false end
    logger.info("[MiuRead][Extensions] background update check scheduled","reason=",tostring(reason or "idle"),"count=",tostring(summary.trackable))
    return check_updates(plugin,{silent=true,notify_updates=false,reason=reason})
end

local function check_single_update(plugin,item)
    if not item or not valid_repo(item.repo) then return end
    run_async_with_progress(plugin,"正在检查官方稳定版……","extension_check_one",function()
        local remote,err=resolve_repo_remote_complete(plugin,item.repo)
        return {remote=remote,error=err,status=remote_update_status(plugin,item,remote)}
    end,function(value,worker_error)
        local status=type(value)=="table" and value.status or nil
        if not status then
            local _,message=classify_github_error(worker_error or (type(value)=="table" and value.error or nil)); plugin:info(message.."。"); return
        end
        status.checked_at=os.time()
        local states=update_state(plugin); states[update_key(item)]=status; save_update_state(plugin,states)
        if type(plugin._refresh_miuread_menu)=="function" then plugin:_refresh_miuread_menu() end
        if status.status=="update" then
            plugin:info("发现新版本："..tostring(item.name or item.dir)
                ..(trim(status.remote_version)~="" and ("\n最新稳定版："..trim(status.remote_version)) or ""))
        elseif status.status=="same" then
            plugin:info("当前已是最新稳定版："..tostring(item.name or item.dir))
        else
            plugin:info(tostring(status.label or "暂时无法判断更新状态。"))
        end
    end,45)
end

local function install_managed_repo(plugin,item,mode)
    if not item or not valid_repo(item.repo) or item.duplicate then return end
    local entry=known_repo(item.repo)
    if entry then
        local compatibility=Compat.evaluate(entry,plugin)
        if compatibility.installable~=true then plugin:info(compatibility.block_reason or "当前设备不兼容") return end
    end
    local is_update=mode=="update"
    local verb=is_update and "更新" or "重新安装"
    local note=is_update and "会重新读取作者最新可安装稳定版；新包准备完成后才切换旧插件。"
        or "会从当前官方仓库重新解析可安装版本；失败时保留当前可用版本。"
    UIManager:show(ConfirmBox:new{
        text=verb.."“"..tostring(item.name or item.dir).."”？\n\n"..note,
        ok_text=verb,cancel_text="取消",
        ok_callback=function()
            run_async_with_progress(plugin,"正在确认官方安装包……","extension_resolve_install",function()
                local remote,err=resolve_repo_remote_complete(plugin,item.repo)
                return {remote=remote,error=err}
            end,function(value,worker_error)
                local remote=type(value)=="table" and value.remote or nil
                if not remote then
                    local _,message=classify_github_error(worker_error or (type(value)=="table" and value.error or nil))
                    plugin:info(message.."。\n\n没有改用未经确认的安装包。")
                    return
                end
                install_repo(plugin,remote.repo,remote.info,remote.release)
            end,45)
        end,
    })
end

local function installed_detail_rows(plugin,item)
    if item.ghost then
        return {
            {text=pending_label(item.pending),enabled=false},
            {text="完整重启 KOReader 后，这条状态会自动消失。",enabled=false},
        }
    end
    local rows={}
    local open_row=native_open_row(plugin,item)
    if open_row then rows[#rows+1]=open_row end
    local settings_row=item.native and NativePlugins.settings_entry(plugin,item.native) or nil
    if settings_row then rows[#rows+1]=settings_row end
    rows[#rows+1]={text="当前版本",post_text=item.version~="" and item.version or "未知",enabled=false}
    local catalog_entry=valid_repo(item.repo) and known_repo(item.repo) or nil
    local catalog_compatibility
    if catalog_entry then catalog_compatibility=append_catalog_rows(rows,plugin,catalog_entry) end
    if catalog_entry and catalog_entry.lockscreen_provider and type(plugin._request_lockscreen_provider)=="function" then
        rows[#rows+1]={text="设为锁屏壁纸",post_text=catalog_entry.lockscreen_provider=="inkstain" and "墨痕壁纸" or "DashWallpaper",keep_menu_open=true,callback=function()
            plugin:_request_lockscreen_provider(catalog_entry.lockscreen_provider)
        end}
    end
    if valid_repo(item.repo) then
        rows[#rows+1]={text="来源",post_text="GitHub · 第三方扩展",enabled=false}
        rows[#rows+1]={text="仓库",post_text=item.repo,enabled=false}
    else
        rows[#rows+1]={text="来源",post_text="外部安装",enabled=false}
    end
    if item.enabled==false then rows[#rows+1]={text="插件状态",post_text="未启用",enabled=false} end
    if item.pending then
        rows[#rows+1]={text="当前更改",post_text=pending_label(item.pending),enabled=false}
        if trim(item.runtime_version)~="" and trim(item.runtime_version)~=trim(item.version) then
            rows[#rows+1]={text="当前运行版本",post_text=item.runtime_version,enabled=false}
        end
    end
    if item.duplicate then
        rows[#rows+1]={text="重复安装",post_text=tostring(#(item.duplicate_paths or {})).." 个位置",enabled=false}
        for _,path in ipairs(item.duplicate_paths or {}) do rows[#rows+1]={text=path,enabled=false} end
        rows[#rows+1]={text="自动更新已停用",post_text="请先处理重复副本",enabled=false}
        rows[#rows+1]={text="卸载插件副本",keep_menu_open=true,callback=function() uninstall(plugin,item) end}
        return prioritize_extension_rows(rows)
    end
    if valid_repo(item.repo) then
        local state=recent_update_state(update_state(plugin),item)
        local blocked=catalog_entry and catalog_compatibility and catalog_compatibility.installable~=true
        if state and state.status=="update" and not blocked then
            rows[#rows+1]={text="更新扩展",post_text=trim(state.remote_version)~="" and trim(state.remote_version) or "有更新",keep_menu_open=true,
                callback=function() install_managed_repo(plugin,item,"update") end}
        elseif state and state.status=="same" then
            rows[#rows+1]={text="更新状态",post_text="已是最新稳定版",enabled=false}
        end
        rows[#rows+1]={text="检查更新",post_text="GitHub 官方稳定版",keep_menu_open=true,callback=function() check_single_update(plugin,item) end}
        if not blocked then
            rows[#rows+1]={text="重新安装",keep_menu_open=true,callback=function() install_managed_repo(plugin,item,"reinstall") end}
        else
            rows[#rows+1]={text="自动安装不可用",post_text=catalog_compatibility.block_reason or "当前设备不兼容",enabled=false}
        end
    end
    rows[#rows+1]={text="卸载插件",keep_menu_open=true,callback=function() uninstall(plugin,item) end}
    return prioritize_extension_rows(rows)
end

local function update_menu(plugin)
    local rows={}
    local summary=update_summary(plugin)
    local states=update_state(plugin)
    local updates={}
    for _,item in ipairs(trackable_plugins(plugin)) do
        local state=recent_update_state(states,item)
        if state and state.status=="update" then updates[#updates+1]={item=item,state=state} end
    end
    if #updates>0 then
        rows[#rows+1]={text="可更新扩展",post_text=tostring(#updates).." 个",enabled=false}
        if #updates>1 then
            rows[#rows+1]={text="全部更新",post_text=tostring(#updates).." 个 · 逐个安全安装",keep_menu_open=true,callback=function()
                UIManager:show(ConfirmBox:new{text="更新全部 "..tostring(#updates).." 个扩展？\n\n将逐个使用官方稳定版和现有完整性验证；如果某一项失败，批量流程会停止，尚未处理的更新状态会保留。",ok_text="全部更新",cancel_text="取消",ok_callback=function() start_bulk_update(plugin,updates) end})
            end}
        end
        for _,entry in ipairs(updates) do
            local target=entry.item
            rows[#rows+1]={
                text=tostring(target.name or target.dir),post_text="有更新",
                sub_item_table_func=function() return installed_detail_rows(plugin,target) end,
            }
        end
        rows[#rows+1]={text="重新检查",separator=true,post_text="GitHub 官方稳定版",keep_menu_open=true,callback=function()
            check_updates(plugin,{silent=false})
        end}
    elseif summary.checking then
        rows[#rows+1]={text="正在检查更新…",post_text=tostring(summary.trackable).." 个扩展",enabled=false}
    elseif summary.checked_fresh then
        rows[#rows+1]={text="全部已是最新",post_text=tostring(summary.trackable).." 个 GitHub 扩展",enabled=false}
        rows[#rows+1]={text="重新检查",keep_menu_open=true,callback=function() check_updates(plugin,{silent=false}) end}
    else
        rows[#rows+1]={text="检查扩展更新",post_text=summary.trackable>0 and (tostring(summary.trackable).." 个 GitHub 扩展") or "暂无可检查扩展",
            enabled=summary.trackable>0,keep_menu_open=true,callback=summary.trackable>0 and function() check_updates(plugin,{silent=false}) end or nil}
        if summary.last_error~="" then rows[#rows+1]={text="上次检查",post_text=summary.last_error,enabled=false} end
    end
    return rows
end

local function installed_menu(plugin)
    local rows={}
    local pending_n=pending_count(plugin)
    if pending_n>0 then
        rows[#rows+1]={text="待重启生效",post_text=tostring(pending_n).." 项",sub_item_table_func=function() return pending_restart_rows(plugin) end}
    end
    local list=managed_plugins(plugin)
    local trackable=0
    for _,item in ipairs(list) do if item.ghost~=true and valid_repo(item.repo) and not item.duplicate then trackable=trackable+1 end end
    rows[#rows+1]={text="检查更新",post_text=trackable>0 and (tostring(trackable).." 个 GitHub 扩展") or "暂无可检查扩展",enabled=trackable>0,keep_menu_open=true,callback=trackable>0 and function() check_updates(plugin) end or nil}
    local states=update_state(plugin)
    for _,item in ipairs(list) do
        local label=tostring(item.name or item.dir)
        local post
        if item.pending then post=pending_label(item.pending)
        elseif item.duplicate then post="重复安装"
        else
            post=installed_status_label(plugin,item,states)
        end
        local target=item
        rows[#rows+1]={text=label,post_text=post,sub_item_table_func=function() return installed_detail_rows(plugin,target) end}
    end
    if #list==0 then rows[#rows+1]={text="暂无用户插件",post_text="可从“觅阅推荐”或“搜索扩展”安装",enabled=false} end
    return rows
end

function M.discovery_menu(plugin)
    return discovery_menu(plugin)
end

function M.recommendation_menu(plugin)
    return recommendation_menu(plugin)
end

function M.installed_menu(plugin)
    return installed_menu(plugin)
end

function M.installed_count(plugin)
    return installed_count(plugin)
end

function M.update_summary(plugin)
    return update_summary(plugin)
end

function M.update_count(plugin)
    return tonumber(update_summary(plugin).updates) or 0
end

function M.update_menu(plugin)
    return update_menu(plugin)
end

function M.maybe_auto_check(plugin,reason)
    return maybe_auto_check(plugin,reason)
end

function M.check_updates(plugin)
    return check_updates(plugin,{silent=false})
end

function M.download_rows(plugin)
    return extension_download_rows(plugin)
end

function M.show_download_task(plugin,task)
    return show_extension_task_detail(plugin,task)
end

function M.active_download_status(plugin,repo)
    return active_extension_status(plugin,repo)
end

-- beta.18: trusted feature integrations (currently lockscreen providers) may
-- start the exact same catalog resolver/transactional installer as the normal
-- Extension Center. This does not bypass compatibility, source verification,
-- archive validation or rollback; it only avoids making the user reopen the
-- extension detail page after choosing “安装并使用”.
function M.install_catalog_id(plugin,id)
    local entry=Catalog.by_id(id)
    if type(entry)~="table" or not valid_repo(entry.repo) then
        plugin:info("没有找到可安装的觅阅推荐扩展。")
        return false
    end
    local compatibility=Compat.evaluate(entry,plugin)
    if compatibility.installable~=true then
        plugin:info(compatibility.block_reason or "当前设备不支持自动安装此扩展。")
        return false
    end
    run_async_with_progress(plugin,"正在确认官方安装包……","extension_feature_install",function()
        local remote,err=resolve_repo_remote_complete(plugin,entry.repo)
        return {remote=remote,error=err}
    end,function(value,worker_error)
        local remote=type(value)=="table" and value.remote or nil
        if not remote then
            local _,message=classify_github_error(worker_error or (type(value)=="table" and value.error or nil))
            local failure=message.."。\n\n当前锁屏设置没有改变。"
            notify_install_failed(plugin,entry.repo,failure)
            plugin:info(failure)
            return
        end
        install_repo(plugin,remote.repo,remote.info,remote.release)
    end,45)
    return true
end

function M.menu(plugin)
    pcall(cleanup_stale_extension_temp,plugin,false)
    UIManager:nextTick(function() pcall(maybe_auto_check,plugin,"extension_center_open") end)
    local summary=update_summary(plugin)
    local pending_n=pending_count(plugin)
    local downloads=#extension_download_rows(plugin)
    local rows={}
    if summary.checking then
        rows[#rows+1]={text="正在检查更新…",post_text=tostring(summary.trackable).." 个扩展",enabled=false}
    elseif summary.updates>0 then
        rows[#rows+1]={text="可更新扩展",post_text=tostring(summary.updates).." 个",sub_item_table_func=function() return update_menu(plugin) end}
    elseif summary.checked_fresh then
        rows[#rows+1]={text="扩展更新",post_text="全部已是最新",sub_item_table_func=function() return update_menu(plugin) end}
    else
        rows[#rows+1]={text="检查扩展更新",post_text=summary.trackable>0 and (tostring(summary.trackable).." 个扩展") or "暂无可检查扩展",
            enabled=summary.trackable>0,keep_menu_open=true,callback=summary.trackable>0 and function() check_updates(plugin,{silent=false}) end or nil}
    end
    rows[#rows+1]={text="搜索扩展",keep_menu_open=true,callback=function() show_search_dialog(plugin) end}
    rows[#rows+1]={text="觅阅推荐",sub_item_table_func=function() return recommendation_menu(plugin) end}
    rows[#rows+1]={text="已安装扩展",post_text=tostring(installed_count(plugin)).." 个",sub_item_table_func=function() return installed_menu(plugin) end}
    if pending_n>0 then rows[#rows+1]={text="待重启生效",post_text=tostring(pending_n).." 项",sub_item_table_func=function() return pending_restart_rows(plugin) end} end
    rows[#rows+1]={text="社区热门",post_text="GitHub",keep_menu_open=true,callback=function() github_search(plugin,"topic:koreader-plugin","社区热门",1,"popular",false) end}
    if downloads>0 then rows[#rows+1]={text="插件下载任务",separator=true,post_text=tostring(downloads).." 项",sub_item_table_func=function() return extension_download_rows(plugin) end} end
    rows[#rows+1]={text="扩展下载源",separator=downloads==0,post_text=network_mode_label(plugin),sub_item_table_func=function() return download_source_menu(plugin) end}
    rows[#rows+1]={text="关于扩展中心",callback=function() center_about(plugin) end}
    local MenuIcons=require("miuread.menu_icons")
    for _,item in ipairs(rows) do
        if not item.icon_key and not item.separator then item.icon_key=MenuIcons.key(item.text) end
    end
    return rows
end

function M.cleanup_stale(plugin,force)
    return cleanup_stale_extension_temp(plugin,force==true)
end

return M
