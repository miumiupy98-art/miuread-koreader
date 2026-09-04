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
local archiver_ok,Archiver=pcall(require,"ffi/archiver")

local NativePlugins=require("miuread.native_plugins")
local InfoMessage=require("ui/widget/infomessage")
local ButtonDialog=require("ui/widget/buttondialog")
local Async=require("miuread.async")

local M={}

local RECORD_KEY="extension_center_installed_v2"
local LEGACY_RECORD_KEY="extension_center_installed"
local SEARCH_CACHE_KEY="extension_center_search_cache_v2"
local META_CACHE_KEY="extension_center_repo_cache_v2"
local UPDATE_STATE_KEY="extension_center_update_state_v2"
local PENDING_KEY="extension_center_pending_restart_v1"
local MAX_RESULTS=24
local SEARCH_TTL=30*60
local META_TTL=30*60
local UPDATE_VISIBLE_TTL=24*60*60
local MAX_ARCHIVE_ENTRIES=6000
local MAX_PLUGIN_FILES=5000
local MAX_PLUGIN_BYTES=96*1024*1024
local SELF_REPO="miumiupy98-art/miuread-koreader"
local SESSION_TOKEN=tostring(os.time()).."-"..tostring(math.random(100000,999999))

-- These entries are aliases/compatibility hints only. They are not a separate
-- MiuRead plugin source and never replace the real GitHub repository identity.
local KNOWN_REPOS={
    {repo="hesan1232/fanqie.koplugin",name="番茄小说",aliases={"番茄","番茄小说","fanqie"},description="在 KOReader 中浏览、阅读和管理番茄小说。",recommended=true,recommendation="适合中文网络小说阅读"},
    {repo="ZlibraryKO/zlibrary.koplugin",name="Z-Library",aliases={"zlibrary","z-library","z lib"},description="在 KOReader 中搜索和下载 Z-Library 书籍。",recommended=true,recommendation="图书搜索与下载"},
    {repo="doctorhetfield-cmd/simpleui.koplugin",name="SimpleUI",aliases={"simpleui","simple ui"},description="KOReader 界面扩展。",ui_conflict=true,recommended=true,recommendation="简化 KOReader 界面"},
    {repo="AnthonyGress/zen_ui.koplugin",name="Zen UI",aliases={"zen ui","zenui"},description="KOReader 极简界面扩展。",ui_conflict=true,recommended=true,recommendation="极简 KOReader 界面"},
    {repo="omer-faruq/appstore.koplugin",name="App Store",aliases={"app store","appstore"},description="KOReader 社区插件市场。"},
}

local function normalized_alias(value)
    return tostring(value or ""):lower():gsub("[%s%p_]+","")
end

local function known_repo(repo)
    repo=tostring(repo or "")
    for _,item in ipairs(KNOWN_REPOS) do if item.repo==repo then return item end end
end

local function alias_matches(query)
    local key=normalized_alias(query)
    if key=="" then return {} end
    local out={}
    for _,item in ipairs(KNOWN_REPOS) do
        local matched=normalized_alias(item.name):find(key,1,true)~=nil
            or normalized_alias(item.repo):find(key,1,true)~=nil
        if not matched then
            for _,alias in ipairs(item.aliases or {}) do
                if normalized_alias(alias):find(key,1,true)~=nil or key:find(normalized_alias(alias),1,true)~=nil then matched=true; break end
            end
        end
        if matched then out[#out+1]=item end
    end
    return out
end

local function command_ok(rc)
    return rc==true or rc==0
end

local function trim(value)
    return U.trim(tostring(value or ""))
end

local function starts_with(value,prefix)
    value=tostring(value or "")
    prefix=tostring(prefix or "")
    return value:sub(1,#prefix)==prefix
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

local function valid_plugin_dir_name(name)
    return type(name)=="string"
        and name:match("^[%w%._%-]+%.koplugin$")~=nil
        and name~="miuread.koplugin"
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

local function find_installed_by_dir(dir)
    local matches=installed_matches_by_dir(dir)
    if #matches==1 then return matches[1] end
    return nil,#matches>1 and matches or nil
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

local function remember_install(plugin,repo,dir,path,version,source_url,remote_ref)
    path=canonical_path(path)
    local value=records(plugin)
    local meta=read_meta(path)
    value[path]={
        repo=repo,dir=dir,path=path,version=tostring(version or meta.version or ""),
        source_url=tostring(source_url or ""),installed_at=os.time(),
        identity=meta.identity,fingerprint=plugin_fingerprint(path),
        remote_ref=tostring(remote_ref or ""),
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

local function repo_for_installed(plugin,item)
    local value=record_for_installed(plugin,item)
    return type(value)=="table" and value.repo or nil
end

local function log_url(url)
    if type(U.redact_url)=="function" then return U.redact_url(url) end
    return tostring(url or "")
end

local function curl_download_file(url,path,options)
    options=options or {}
    local connect_timeout=math.max(2,math.floor(tonumber(options.connect_timeout) or 15))
    local total_timeout=math.max(connect_timeout,math.floor(tonumber(options.total_timeout) or 180))
    os.remove(path)
    local cmd="curl -L --fail --silent --show-error --connect-timeout "..tostring(connect_timeout)
        .." --max-time "..tostring(total_timeout)
    for _,header in ipairs(options.headers or {}) do
        cmd=cmd.." -H "..U.shell_quote(tostring(header))
    end
    cmd=cmd.." -o "..U.shell_quote(path).." "..U.shell_quote(url).." 2>/dev/null"
    local ok=command_ok(os.execute(cmd))
    local size=U.file_size(path) or 0
    if not ok or size<=0 then os.remove(path); return false end
    return true,size
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

local function latest_release(plugin,repo)
    if not valid_repo(repo) then return nil,"invalid_repo" end
    local release,err=github_json(plugin,"https://api.github.com/repos/"..repo.."/releases/latest")
    if release then return release end
    if tostring(err):find("http:404",1,true) then return nil,"no_release" end
    logger.warn("[MiuRead][Extensions] latest release unavailable",repo,tostring(err))
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
        }
    end
    return {
        tag_name=tostring(release.tag_name or ""),name=tostring(release.name or ""),assets=assets,
    }
end

local function release_sources(repo,repo_info,release)
    local out,seen={},{}
    local function add(source)
        if type(source)~="table" or not starts_with(source.url,"https://") or seen[source.url] then return end
        seen[source.url]=true; out[#out+1]=source
    end
    if type(release)=="table" then
        local assets={}
        for _,asset in ipairs(type(release.assets)=="table" and release.assets or {}) do
            local name=tostring(asset.name or ""):lower()
            local url=tostring(asset.browser_download_url or "")
            if name:match("%.zip$") and starts_with(url,"https://") then
                local score=0
                if name:find("koplugin",1,true) then score=3
                elseif name:find("plugin",1,true) then score=2
                else score=1 end
                assets[#assets+1]={asset=asset,score=score,name=name}
            end
        end
        table.sort(assets,function(a,b)
            if a.score~=b.score then return a.score>b.score end
            return a.name<b.name
        end)
        for _,entry in ipairs(assets) do
            local asset=entry.asset
            add({
                url=asset.browser_download_url,
                version=tostring(release.tag_name or release.name or ""),source="release-asset",
                size=tonumber(asset.size) or 0,remote_ref="release:"..tostring(release.tag_name or release.name or ""),
            })
        end
        local tag=tostring(release.tag_name or "")
        if tag~="" then
            add({
                url="https://github.com/"..repo.."/archive/refs/tags/"..url_encode(tag)..".zip",
                version=tag,source="release-source",remote_ref="release:"..tag,
            })
        end
    end
    local branch=tostring(type(repo_info)=="table" and repo_info.default_branch or "main")
    if branch=="" then branch="main" end
    add({
        url="https://github.com/"..repo.."/archive/refs/heads/"..url_encode(branch)..".zip",
        version="",source="branch-source",
        remote_ref="branch:"..tostring(type(repo_info)=="table" and (repo_info.pushed_at or repo_info.updated_at) or branch),
    })
    return out
end

local function github_package_urls(url)
    local out,seen={},{}
    local function add(candidate)
        if type(candidate)=="string" and candidate:match("^https://") and not seen[candidate] then
            seen[candidate]=true
            out[#out+1]=candidate
        end
    end
    add(url)
    if starts_with(url,"https://github.com/") then
        for _,prefix in ipairs(Config.GITHUB_MIRRORS or {}) do
            prefix=tostring(prefix or "")
            if prefix:match("^https://") then
                if prefix:sub(-1)~="/" then prefix=prefix.."/" end
                add(prefix..url)
            end
        end
    end
    return out
end

local function download_package(plugin,url,label,target_override)
    local target=trim(target_override)
    if target=="" then
        target=plugin.store.temp_dir.."/extension-"..U.id_name(label or os.time()).."-"..tostring(math.random(1000,9999))..".zip"
    end
    local errors={}
    for _,candidate in ipairs(github_package_urls(url)) do
        os.remove(target)
        logger.info("[MiuRead][Extensions] package download start","route=lua","url=",log_url(candidate))
        local ok,result=pcall(function()
            return plugin.http:download_to_file(candidate,target,{
                auth=false,retries=1,redirects=10,timeout={15,150},integrity_attempts=2,
            })
        end)
        if ok and U.file_exists(target) and (U.file_size(target) or 0)>0 then
            logger.info("[MiuRead][Extensions] package download success","route=lua","bytes=",tostring(U.file_size(target) or 0),"url=",log_url(candidate))
            return target,candidate
        end
        local lua_error=tostring(result or "Lua 下载失败")
        errors[#errors+1]=lua_error
        logger.warn("[MiuRead][Extensions] package Lua route failed",log_url(candidate),lua_error)

        os.remove(target)
        logger.info("[MiuRead][Extensions] package curl fallback",log_url(candidate))
        local curl_ok,curl_size=curl_download_file(candidate,target,{connect_timeout=20,total_timeout=180})
        if curl_ok then
            logger.info("[MiuRead][Extensions] package download success","route=curl","bytes=",tostring(curl_size or 0),"url=",log_url(candidate))
            return target,candidate
        end
        errors[#errors+1]="curl download failed: "..log_url(candidate)
        logger.warn("[MiuRead][Extensions] package curl route failed",log_url(candidate))
    end
    os.remove(target)
    return nil,errors[#errors] or "下载失败"
end

local function open_archiver(path)
    if not archiver_ok or type(Archiver)~="table" or type(Archiver.Reader)~="table" then
        return nil,"KOReader Archiver 不可用"
    end
    local ok,reader=pcall(function() return Archiver.Reader:new() end)
    if not ok or not reader then return nil,"无法创建 KOReader Archiver" end
    local opened_ok,opened=pcall(function() return reader:open(path) end)
    if not opened_ok or not opened then
        pcall(function() reader:close() end)
        return nil,"KOReader Archiver 无法打开 ZIP"
    end
    return reader
end

local function close_archiver(reader)
    if reader then pcall(function() reader:close() end) end
end

local function validate_archive_path(name)
    name=tostring(name or "")
    if name=="" then return nil,"ZIP 包含空路径" end
    if name:sub(1,1)=="/" or name:find("\\",1,true) or name:find("%z") then
        return nil,"ZIP 包含不安全路径"
    end
    for part in name:gmatch("[^/]+") do
        if part==".." or part=="." then return nil,"ZIP 包含目录穿越路径" end
    end
    return true
end

local function inspect_archiver(reader)
    local entries,files=0,0
    local ok,err=pcall(function()
        for entry in reader:iterate() do
            entries=entries+1
            if entries>MAX_ARCHIVE_ENTRIES then error("ZIP 文件数量过多") end
            local safe,path_error=validate_archive_path(entry.path)
            if not safe then error(path_error) end
            local mode=tostring(entry.mode or "")
            if mode:lower():find("link",1,true) then error("插件包包含符号链接") end
            if mode=="file" then files=files+1 end
        end
    end)
    if not ok then return nil,tostring(err):gsub("^.-:%d+:%s*","") end
    if entries==0 or files==0 then return nil,"ZIP 中没有可安装文件" end
    return {entries=entries,files=files}
end

local function extract_with_archiver(reader,unpacked)
    local files,bytes=0,0
    local ok,err=pcall(function()
        for entry in reader:iterate() do
            if tostring(entry.mode or "")=="file" then
                local safe,path_error=validate_archive_path(entry.path)
                if not safe then error(path_error) end
                local dest=unpacked.."/"..entry.path
                local parent=dirname(dest)
                U.mkdir(parent)
                local extracted=reader:extractToPath(entry.path,dest)
                if not extracted then error("解压插件文件失败："..tostring(entry.path)) end
                files=files+1
                bytes=bytes+(tonumber(lfs.attributes(dest,"size")) or 0)
                if files>MAX_PLUGIN_FILES then error("插件文件数量过多") end
                if bytes>MAX_PLUGIN_BYTES then error("插件解压后体积过大") end
            end
        end
    end)
    if not ok then return nil,tostring(err):gsub("^.-:%d+:%s*","") end
    return {files=files,bytes=bytes}
end

local function zip_entries(path)
    local cmd="unzip -Z1 "..U.shell_quote(path).." 2>/dev/null"
    local pipe=io.popen(cmd,"r")
    if not pipe then return nil,"无法读取 ZIP 目录" end
    local entries={}
    for line in pipe:lines() do
        entries[#entries+1]=line
        if #entries>MAX_ARCHIVE_ENTRIES then break end
    end
    local ok=pipe:close()
    if #entries==0 then return nil,"ZIP 中没有文件" end
    if #entries>MAX_ARCHIVE_ENTRIES then return nil,"ZIP 文件数量过多" end
    if ok==nil then return nil,"ZIP 目录读取失败" end
    for _,name in ipairs(entries) do
        name=tostring(name or "")
        if name:sub(1,1)=="/" or name:find("\\",1,true) or name:find("%z") then
            return nil,"ZIP 包含不安全路径"
        end
        for part in name:gmatch("[^/]+") do
            if part==".." or part=="." then return nil,"ZIP 包含目录穿越路径" end
        end
    end
    return entries
end

local function zip_declared_size(path)
    local cmd="unzip -l "..U.shell_quote(path).." 2>/dev/null"
    local pipe=io.popen(cmd,"r")
    if not pipe then return nil end
    local total=0
    for line in pipe:lines() do
        local size=line:match("^%s*(%d+)%s+%d%d%d%d[-/]%d%d[-/]%d%d%s+%d%d:%d%d%s+.+$")
        if size then
            total=total+(tonumber(size) or 0)
            if total>MAX_PLUGIN_BYTES then break end
        end
    end
    pipe:close()
    return total
end

local function tree_stats(root)
    local files,bytes=0,0
    local function walk(path)
        local ok,iter,state=pcall(lfs.dir,path)
        if not ok or type(iter)~="function" then return nil,"无法读取解压目录" end
        for entry in iter,state do
            if entry~="." and entry~=".." then
                local child=path.."/"..entry
                local mode=type(lfs.symlinkattributes)=="function" and lfs.symlinkattributes(child,"mode") or lfs.attributes(child,"mode")
                if mode=="link" then return nil,"插件包包含符号链接" end
                if mode=="directory" then
                    local ok_walk,err=walk(child)
                    if not ok_walk then return nil,err end
                elseif mode=="file" then
                    files=files+1
                    bytes=bytes+(tonumber(lfs.attributes(child,"size")) or 0)
                    if files>MAX_PLUGIN_FILES then return nil,"插件文件数量过多" end
                    if bytes>MAX_PLUGIN_BYTES then return nil,"插件解压后体积过大" end
                end
            end
        end
        return true
    end
    local ok,err=walk(root)
    if not ok then return nil,err end
    return {files=files,bytes=bytes}
end

local function collect_plugin_roots(root,max_depth)
    local found={}
    local function walk(path,depth)
        if depth>max_depth then return end
        if U.file_exists(path.."/main.lua") and U.file_exists(path.."/_meta.lua") then
            found[#found+1]=path
            return
        end
        local ok,iter,state=pcall(lfs.dir,path)
        if not ok or type(iter)~="function" then return end
        for entry in iter,state do
            if entry~="." and entry~=".." then
                local child=path.."/"..entry
                if lfs.attributes(child,"mode")=="directory" then walk(child,depth+1) end
            end
        end
    end
    walk(root,0)
    return found
end

local function choose_plugin_root(unpacked,repo)
    local candidates=collect_plugin_roots(unpacked,4)
    if #candidates==0 then return nil,"没有找到完整 KOReader 插件（缺少 main.lua / _meta.lua）" end
    local repo_name=repo:match("/([^/]+)$") or ""
    local preferred
    for _,candidate in ipairs(candidates) do
        local name=basename(candidate)
        if name==repo_name or name:match("%.koplugin$") then
            if preferred then return nil,"ZIP 中包含多个插件目录，已拒绝自动安装" end
            preferred=candidate
        end
    end
    if not preferred then
        if #candidates~=1 then return nil,"ZIP 中包含多个可安装目录，无法确定目标插件" end
        preferred=candidates[1]
    end
    local target_name=basename(preferred)
    if not target_name:match("%.koplugin$") then target_name=repo_name end
    if not target_name:match("%.koplugin$") then target_name=target_name..".koplugin" end
    if not valid_plugin_dir_name(target_name) then return nil,"插件目录名称不符合 .koplugin 规范" end
    return preferred,target_name
end

local function install_archive(plugin,repo,zip_path,source_url,version_hint,remote_ref)
    logger.info("[MiuRead][Extensions] install stage","stage=archive_open","repo=",repo,"bytes=",tostring(U.file_size(zip_path) or 0))
    local reader,archiver_error=open_archiver(zip_path)
    local use_archiver=reader~=nil
    if use_archiver then
        local inspected,inspect_error=inspect_archiver(reader)
        if not inspected then
            close_archiver(reader)
            os.remove(zip_path)
            logger.warn("[MiuRead][Extensions] install failed","stage=archive_validate","repo=",repo,"error=",tostring(inspect_error))
            return nil,inspect_error,"archive_validate"
        end
        logger.info("[MiuRead][Extensions] archive validated","backend=archiver","entries=",tostring(inspected.entries),"files=",tostring(inspected.files))
    else
        logger.warn("[MiuRead][Extensions] KOReader Archiver unavailable; using unzip fallback",tostring(archiver_error))
        local entries,entry_error=zip_entries(zip_path)
        if not entries then os.remove(zip_path); return nil,entry_error,"archive_validate" end
        local declared_size=zip_declared_size(zip_path)
        if declared_size and declared_size>MAX_PLUGIN_BYTES then
            os.remove(zip_path)
            return nil,"插件解压体积超过安全上限","archive_validate"
        end
    end

    local stamp=tostring(os.time()).."-"..tostring(math.random(1000,9999))
    local stage=plugin.store.temp_dir.."/extension-stage-"..stamp
    local unpacked=stage.."/unpacked"
    U.remove_tree(stage)
    U.mkdir(unpacked)
    local function fail(message,failed_stage)
        close_archiver(reader); reader=nil
        U.remove_tree(stage)
        os.remove(zip_path)
        logger.warn("[MiuRead][Extensions] install failed","stage=",tostring(failed_stage or "unknown"),"repo=",repo,"error=",tostring(message))
        return nil,message,failed_stage
    end

    local stats,stats_error
    if use_archiver then
        logger.info("[MiuRead][Extensions] install stage","stage=extract","backend=archiver","repo=",repo)
        stats,stats_error=extract_with_archiver(reader,unpacked)
        close_archiver(reader); reader=nil
        if not stats then return fail(stats_error,"extract") end
    else
        logger.info("[MiuRead][Extensions] install stage","stage=extract","backend=unzip","repo=",repo)
        local rc=os.execute("unzip -q "..U.shell_quote(zip_path).." -d "..U.shell_quote(unpacked).." 2>/dev/null")
        if not command_ok(rc) then return fail("解压插件失败","extract") end
        stats,stats_error=tree_stats(unpacked)
        if not stats then return fail(stats_error,"extract_validate") end
    end
    logger.info("[MiuRead][Extensions] extract complete","repo=",repo,"files=",tostring(stats.files),"bytes=",tostring(stats.bytes),"backend=",use_archiver and "archiver" or "unzip")

    local incoming,target_name=choose_plugin_root(unpacked,repo)
    if not incoming then return fail(target_name,"plugin_detect") end
    if target_name=="miuread.koplugin" then return fail("扩展中心不能覆盖觅阅自身","plugin_detect") end
    logger.info("[MiuRead][Extensions] plugin detected","repo=",repo,"dir=",target_name)

    local existing,duplicates=find_installed_by_dir(target_name)
    if duplicates then
        return fail("检测到同名插件存在多个安装位置，请先只保留一份后再更新","duplicate_install")
    end
    local target_root=existing and existing.root or default_plugin_root()
    local target=target_root.."/"..target_name
    local backup=stage.."/backup"

    -- The update path temporarily needs the downloaded ZIP, extracted plugin,
    -- old-plugin backup and final copy at the same time. Abort before touching
    -- the old plugin when the filesystem cannot safely hold that working set.
    local existing_bytes=0
    if existing then
        local current_stats=tree_stats(existing.path)
        existing_bytes=type(current_stats)=="table" and (tonumber(current_stats.bytes) or 0) or 0
    end
    local needed=(tonumber(stats.bytes) or 0)*2+existing_bytes+(tonumber(U.file_size(zip_path)) or 0)+8*1024*1024
    local free=U.free_space(target_root)
    if free and free<needed then
        return fail("存储空间不足，无法安全完成本次安装或更新。请清理部分空间后重试。","space_check")
    end

    if lfs.attributes(target,"mode")=="directory" then
        if not U.file_exists(target.."/main.lua") or not U.file_exists(target.."/_meta.lua") then
            return fail("目标目录已存在，但不是完整 KOReader 插件；为避免覆盖其他文件，已停止安装","collision_check")
        end
        local installed_record=existing and record_for_installed(plugin,existing) or nil
        local installed_repo=type(installed_record)=="table" and tostring(installed_record.repo or "") or ""
        if installed_repo~="" and installed_repo~=repo then
            return fail("目标目录已由另一个 GitHub 仓库管理，已拒绝覆盖","collision_check")
        end
        if installed_repo=="" then
            local incoming_meta=read_meta(incoming)
            local current_meta=read_meta(target)
            local incoming_id=normalized_plugin_identity(incoming_meta.identity)
            local current_id=normalized_plugin_identity(current_meta.identity)
            if incoming_id~="" and current_id~="" and incoming_id~=current_id then
                return fail("目标目录中已存在名称不同的插件，已拒绝覆盖","collision_check")
            end
        end
        logger.info("[MiuRead][Extensions] install stage","stage=backup","repo=",repo,"dir=",target_name)
        local copied,copy_error=U.copy_tree(target,backup)
        if not copied then return fail("备份旧插件失败："..tostring(copy_error),"backup") end
    end

    local function rollback(message,failed_stage)
        logger.warn("[MiuRead][Extensions] rollback start","repo=",repo,"dir=",target_name,"stage=",tostring(failed_stage or "write"),"error=",tostring(message))
        U.remove_tree(target)
        if lfs.attributes(backup,"mode")=="directory" then
            local restored,restore_error=U.copy_tree(backup,target)
            if not restored then
                U.remove_tree(stage)
                os.remove(zip_path)
                logger.warn("[MiuRead][Extensions] rollback failed","repo=",repo,"error=",tostring(restore_error))
                return nil,tostring(message).."；旧版本恢复失败："..tostring(restore_error),failed_stage
            end
        end
        U.remove_tree(stage)
        os.remove(zip_path)
        logger.info("[MiuRead][Extensions] rollback complete","repo=",repo,"dir=",target_name)
        return nil,tostring(message).."；已恢复旧版本",failed_stage
    end

    logger.info("[MiuRead][Extensions] install stage","stage=write","repo=",repo,"dir=",target_name)
    if lfs.attributes(target,"mode")=="directory" then
        local removed,remove_error=U.remove_tree(target)
        if not removed then return rollback("无法替换旧插件："..tostring(remove_error),"write_prepare") end
    end
    local copied,copy_error=U.copy_tree(incoming,target)
    if not copied then return rollback("安装插件失败："..tostring(copy_error),"write") end
    if not U.file_exists(target.."/main.lua") or not U.file_exists(target.."/_meta.lua") then
        return rollback("安装后的插件结构不完整","post_validate")
    end
    local installed_stats,installed_stats_error=tree_stats(target)
    if not installed_stats then return rollback(installed_stats_error,"post_validate") end

    local meta=read_meta(target)
    remember_install(plugin,repo,target_name,target,meta.version~="" and meta.version or version_hint,source_url,remote_ref)
    U.remove_tree(stage)
    os.remove(zip_path)
    logger.info("[MiuRead][Extensions] installed",repo,target_name,
        "files=",tostring(installed_stats.files),"bytes=",tostring(installed_stats.bytes),"version=",tostring(meta.version),"backend=",use_archiver and "archiver" or "unzip")
    return {
        dir=target_name,path=target,version=meta.version,
        files=installed_stats.files,bytes=installed_stats.bytes,
        updated=existing~=nil,
    }
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

local function update_state(plugin)
    local value=plugin.store:get(UPDATE_STATE_KEY,{})
    return type(value)=="table" and value or {}
end

local function save_update_state(plugin,value)
    plugin.store:set(UPDATE_STATE_KEY,type(value)=="table" and value or {})
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
        out[#out+1]=item
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

    -- Preserve an uninstall result until this KOReader process is restarted.
    local present={}
    for _,item in ipairs(out) do present[item.dir]=true end
    for _,pending in pairs(pending_state(plugin)) do
        if pending.action=="removed" and not present[pending.dir] then
            out[#out+1]={
                dir=pending.dir,name=pending.name,path="",canonical_path="",ghost=true,pending=pending,
            }
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
        if item.ghost~=true and valid_repo(item.repo) then out[item.repo]=item end
    end
    -- A manually installed known plugin may not have an extension-center source
    -- record yet. For trusted aliases only, match its canonical install dirname
    -- so recommendation/search/popular still report the same installed state.
    for _,known in ipairs(KNOWN_REPOS) do
        if not out[known.repo] then
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
    local list=managed_plugins(plugin)
    for _,item in ipairs(list) do
        if item.ghost~=true and tostring(item.repo or "")==tostring(repo or "") then return item end
    end
    local known=known_repo(repo)
    if known then
        local expected=tostring(repo or ""):match("([^/]+)$")
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

local function preflight_package_space(plugin,source,item)
    local size=tonumber(type(source)=="table" and source.size or 0) or 0
    if size<=0 then return true end
    local existing_bytes=0
    if type(item)=="table" and item.path and item.path~="" then
        local stats=tree_stats(item.path)
        existing_bytes=type(stats)=="table" and (tonumber(stats.bytes) or 0) or 0
    end
    local needed=size*4+existing_bytes+8*1024*1024
    local free=U.free_space(default_plugin_root())
    if free and free<needed then return nil,"存储空间不足，无法安全开始本次安装或更新。请先清理部分空间。" end
    return true
end

local function install_repo(plugin,repo,repo_info,release)
    if type(repo_info)~="table" then
        plugin:info("无法读取 GitHub 仓库信息。")
        return
    end
    if repo_info.archived==true then
        plugin:info("这个仓库已经归档，觅阅不会自动安装。")
        return
    end
    local installed=find_managed_by_repo(plugin,repo)
    if installed and installed.duplicate then
        plugin:info("检测到这个插件存在多个安装位置。\n\n为避免更新错文件，请先只保留一份后再重试。")
        return
    end

    local sources=release_sources(repo,repo_info,release)
    local retryable={
        archive_validate=true,extract=true,extract_validate=true,
        plugin_detect=true,collision_check=true,
    }
    local display_name=display_repo_name(repo_info,known_repo(repo))

    local function complete(result)
        result.name=display_name
        mark_pending(plugin,result,result.updated and "updated" or "installed")
        local states=update_state(plugin)
        states[canonical_path(result.path)]=nil
        save_update_state(plugin,states)
        local action=result.updated and "更新完成" or "安装完成"
        local version=result.version~="" and ("\n版本："..result.version) or ""
        if type(plugin._refresh_miuread_menu)=="function" then plugin:_refresh_miuread_menu() end
        plugin:info(action.."："..result.dir..version.."\n\n请完整重启 KOReader 后使用。")
    end

    local function fail_all(last_error)
        plugin:info("扩展安装失败。\n\n已经尝试 Release 安装包和仓库源码，但都没有找到可安全安装的插件。\n\n"..U.first_line(tostring(last_error or "没有找到可安装的插件包"),220))
    end

    local attempt
    attempt=function(index,last_error)
        local source=sources[index]
        if not source then fail_all(last_error); return end

        local enough,space_error=preflight_package_space(plugin,source,installed)
        if not enough then plugin:info(space_error); return end

        local target=plugin.store.temp_dir.."/extension-"..U.id_name(repo.."-"..tostring(source.version or index))
            .."-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))..".zip"
        local download_text=(installed and "正在下载扩展更新……" or "正在下载扩展……")
        run_async_with_progress(plugin,download_text,"extension_download",function()
            local path,used_or_error=download_package(plugin,source.url,repo.."-"..tostring(source.version or index),target)
            if path then return {ok=true,path=path,used_url=used_or_error} end
            return {ok=false,error=tostring(used_or_error or "下载失败")}
        end,function(value,worker_error)
            if worker_error then
                os.remove(target)
                logger.warn("[MiuRead][Extensions] package worker failed",repo,tostring(worker_error))
                attempt(index+1,worker_error)
                return
            end
            if type(value)~="table" or value.ok~=true or not value.path then
                os.remove(target)
                local err=type(value)=="table" and value.error or "下载失败"
                logger.warn("[MiuRead][Extensions] package candidate download failed",repo,tostring(source.source),tostring(err))
                attempt(index+1,err)
                return
            end

            -- Cancellation is intentionally unavailable from this point onward:
            -- the downloaded package has finished and the next stage may replace
            -- an installed plugin. install_archive() owns backup/rollback safety.
            local dialog=InfoMessage:new{text="正在检查并安装扩展……"}
            UIManager:show(dialog)
            UIManager:nextTick(function()
                local ok,result,err,failed_stage=xpcall(function()
                    return install_archive(plugin,repo,value.path,value.used_url,source.version,source.remote_ref)
                end,debug.traceback)
                pcall(function() UIManager:close(dialog) end)
                if not ok then
                    os.remove(value.path)
                    plugin:info("扩展安装失败。\n\n"..U.first_line(tostring(result),240))
                    return
                end
                if result then
                    complete(result)
                    return
                end
                last_error=tostring(err or "安装失败")
                if retryable[tostring(failed_stage or "")] then
                    logger.warn("[MiuRead][Extensions] trying next package candidate",repo,tostring(failed_stage),last_error)
                    UIManager:nextTick(function() attempt(index+1,last_error) end)
                    return
                end
                plugin:info("扩展安装失败。\n\n"..last_error)
            end)
        end,240,{cancel_cleanup=function() os.remove(target) end})
    end

    attempt(1,"没有找到可安装的插件包")
end

local function uninstall(plugin,item)
    if not item or item.ghost then return end
    if item.duplicate then
        plugin:info("检测到同名插件存在多个安装位置。\n\n为避免删错文件，请先在 KOReader 文件管理中只保留一份，再回来卸载。")
        return
    end
    if not item.path or item.path=="" then
        plugin:info("当前无法确认这个插件的实际安装位置，因此不会自动卸载。")
        return
    end
    UIManager:show(ConfirmBox:new{
        text="卸载“"..tostring(item.name or item.dir).."”？\n\n只删除这个用户插件目录，不删除它可能保存在 KOReader settings 中的个人设置。",
        ok_text="卸载",cancel_text="取消",
        ok_callback=function()
            local removed,err=U.remove_tree(item.path)
            if not removed then plugin:info("卸载失败：\n"..tostring(err or "无法删除插件目录")); return end
            forget_install(plugin,item)
            mark_pending(plugin,item,"removed")
            if type(plugin._refresh_miuread_menu)=="function" then plugin:_refresh_miuread_menu() end
            plugin:info("已卸载 "..tostring(item.name or item.dir).."。\n\n请完整重启 KOReader 后完成卸载。")
        end,
    })
end

local function third_party_install_text(plugin,repo,name)
    local text="安装“"..tostring(name or repo).."”？\n\n来源：GitHub · "..repo
        .."\n这是第三方扩展，扩展本身由其作者维护；觅阅只负责下载和安装。"
    local known=known_repo(repo)
    if known and known.ui_conflict and plugin and type(plugin._home_enabled)=="function" and plugin:_home_enabled() then
        text=text.."\n\n这个扩展会修改 KOReader 界面，可能与觅阅桌面产生菜单、手势或显示冲突。建议在插件模式下使用。"
    else
        text=text.."\n\n兼容性未知；安装成功只代表插件包结构有效，不代表觅阅已经审核其功能。"
    end
    text=text.."\n\n安装完成后需要重启 KOReader。"
    return text
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

local function repo_detail_rows(plugin,repo,info,release,fallback,stale)
    local installed=find_managed_by_repo(plugin,repo)
    local description=trim((type(fallback)=="table" and fallback.description) or info.description or "")
    if description=="" then description="暂无简介" end
    local marker,remote_version=remote_marker(info,release)
    local rows={
        {text=repo,enabled=false},
        {text=description,enabled=false},
    }
    if type(fallback)=="table" and trim(fallback.recommendation_reason)~="" then
        rows[#rows+1]={text="觅阅推荐",post_text=trim(fallback.recommendation_reason),enabled=false}
    end
    local author=tostring(repo or ""):match("^([^/]+)/") or "未知"
    rows[#rows+1]={text="作者",post_text=author,enabled=false}
    rows[#rows+1]={text="来源",post_text="GitHub · 第三方扩展",enabled=false}
    rows[#rows+1]={text="仓库",post_text=repo,enabled=false}
    rows[#rows+1]={text="社区",post_text=tostring(info.stargazers_count or 0).." ★",enabled=false}
    if stale then rows[#rows+1]={text="网络状态",post_text="显示上次获取的信息",enabled=false} end
    local known=known_repo(repo)
    if known and known.ui_conflict then
        rows[#rows+1]={text="兼容性",post_text="可能与觅阅桌面冲突",enabled=false}
    else
        rows[#rows+1]={text="兼容性",post_text="未知",enabled=false}
    end
    if remote_version~="" then rows[#rows+1]={text="远端版本",post_text=remote_version,enabled=false} end
    if info.archived==true then rows[#rows+1]={text="仓库状态",post_text="已归档",enabled=false} end

    if installed then
        local open_row=native_open_row(plugin,installed)
        if open_row then rows[#rows+1]=open_row end
        local settings_row=installed.native and NativePlugins.settings_entry(plugin,installed.native) or nil
        if settings_row then rows[#rows+1]=settings_row end
        if installed.enabled==false then rows[#rows+1]={text="插件状态",post_text="未启用",enabled=false} end
        rows[#rows+1]={text="当前版本",post_text=installed.version~="" and installed.version or installed.dir,enabled=false}
        if installed.pending then
            rows[#rows+1]={text="当前更改",post_text=pending_label(installed.pending),enabled=false}
            if trim(installed.runtime_version)~="" and trim(installed.runtime_version)~=trim(installed.version) then
                rows[#rows+1]={text="当前运行版本",post_text=installed.runtime_version,enabled=false}
            end
        end
        if installed.duplicate then
            rows[#rows+1]={text="重复安装",post_text=tostring(#(installed.duplicate_paths or {})).." 个位置",enabled=false}
            for _,path in ipairs(installed.duplicate_paths or {}) do rows[#rows+1]={text=path,enabled=false} end
            rows[#rows+1]={text="自动更新与卸载已停用",enabled=false}
        else
            local status=update_status_for(plugin,installed,info,release)
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
            rows[#rows+1]={text="卸载插件",callback=function() uninstall(plugin,installed) end}
        end
    elseif info.archived~=true then
        rows[#rows+1]={text="安装扩展",callback=function()
            UIManager:show(ConfirmBox:new{
                text=third_party_install_text(plugin,repo,display_repo_name(info,fallback)),
                ok_text="安装",cancel_text="取消",
                ok_callback=function() install_repo(plugin,repo,info,release) end,
            })
        end}
    end
    return rows
end

local function repo_detail(plugin,repo,fallback,force)
    if not valid_repo(repo) then plugin:info("GitHub 仓库地址无效") return end
    local cached=not force and meta_cache_get(plugin,repo,false) or nil
    if cached then
        return show_menu(plugin,"扩展 · "..display_repo_name(cached.repo_info,fallback),repo_detail_rows(plugin,repo,cached.repo_info,cached.release,fallback,false))
    end
    run_async_with_progress(plugin,"正在读取扩展信息……","extension_repo_detail",function()
        local info,repo_error=github_repo(plugin,repo)
        info=compact_repo_info(info)
        if not info then return {info=nil,error=repo_error} end
        local release,release_error=latest_release(plugin,repo)
        release=compact_release(release)
        return {
            info=info,release=release,release_error=release_error,
            release_missing=release_error=="no_release",
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
        local local_item=installed[full]
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
        .."扩展来自 GitHub KOReader 社区。觅阅负责搜索、下载安装、更新和卸载，不把第三方扩展包装成觅阅自己的插件源。\n\n"
        .."安装包会先检查 ZIP 路径、插件结构、体积和剩余空间；更新现有插件前会备份，写入失败自动恢复。\n\n"
        .."第三方扩展由其作者维护。安装、更新或卸载后请完整重启 KOReader。"
    )
end

local function recommendation_menu(plugin)
    local rows={
        {text="第三方 GitHub 扩展 · 觅阅人工整理",enabled=false},
    }
    local installed=managed_repo_map(plugin)
    local states=update_state(plugin)
    local desktop=type(plugin._home_enabled)=="function" and plugin:_home_enabled()==true
    for _,known in ipairs(KNOWN_REPOS) do
        if known.recommended==true and not (desktop and known.ui_conflict==true) then
            local item=installed[known.repo]
            local status=item and installed_status_label(plugin,item,states) or ""
            local reason=trim(known.recommendation)
            local post=reason
            if status~="" then post=post~="" and (post.." · "..status) or status end
            local target=known
            rows[#rows+1]={
                text=tostring(target.name or target.repo),post_text=post,keep_menu_open=true,
                callback=function()
                    repo_detail(plugin,target.repo,{
                        name=target.name,description=target.description,
                        recommendation_reason=target.recommendation,
                    })
                end,
            }
        end
    end
    if desktop then
        rows[#rows+1]={text="界面类扩展未作为桌面模式重点推荐",post_text="避免与觅阅桌面冲突",enabled=false}
    end
    if #rows==1 then rows[#rows+1]={text="暂无适合当前运行模式的推荐扩展",enabled=false} end
    return rows
end

local function discovery_menu(plugin)
    return {
        {text="觅阅推荐",post_text="第三方 GitHub 扩展",sub_item_table_func=function() return recommendation_menu(plugin) end},
        {text="搜索扩展",keep_menu_open=true,callback=function() show_search_dialog(plugin) end},
        {text="社区热门",post_text="GitHub",keep_menu_open=true,callback=function() github_search(plugin,"topic:koreader-plugin","社区热门",1,"popular",false) end},
        {text="关于扩展中心",callback=function() center_about(plugin) end},
    }
end

local function check_updates(plugin)
    local targets={}
    for _,item in ipairs(managed_plugins(plugin)) do
        if item.ghost~=true and item.duplicate~=true and valid_repo(item.repo) then
            local rec=item.record or record_for_installed(plugin,item) or {}
            targets[#targets+1]={
                key=update_key(item),repo=item.repo,version=tostring(item.version or ""),
                record={remote_ref=tostring(rec.remote_ref or "")},
            }
        end
    end
    if #targets==0 then plugin:info("暂无可自动检查更新的扩展。") return end

    run_async_with_progress(plugin,"正在检查扩展更新……","extension_check_updates",function()
        local rows={}
        for _,item in ipairs(targets) do
            local info,repo_error=github_repo(plugin,item.repo)
            info=compact_repo_info(info)
            if info then
                local release,release_error=latest_release(plugin,item.repo)
                release=compact_release(release)
                rows[#rows+1]={
                    key=item.key,repo=item.repo,info=info,release=release,
                    release_missing=release_error=="no_release",
                    status=update_status_for(plugin,item,info,release),
                }
            else
                rows[#rows+1]={key=item.key,repo=item.repo,error=repo_error}
            end
        end
        return rows
    end,function(rows,worker_error)
        if not rows then
            local _,message=classify_github_error(worker_error)
            plugin:info(message.."。")
            return
        end
        local states=update_state(plugin)
        local checked,updates,unknown=0,0,0
        for _,row in ipairs(type(rows)=="table" and rows or {}) do
            if type(row.info)=="table" and type(row.status)=="table" then
                local status=row.status
                status.checked_at=os.time(); states[row.key]=status
                meta_cache_put(plugin,row.repo,row.info,row.release,row.release_missing==true)
                checked=checked+1
                if status.status=="update" then updates=updates+1 elseif status.status=="unknown" then unknown=unknown+1 end
            else
                local _,message=classify_github_error(row.error)
                states[row.key]={status="error",label=message,checked_at=os.time()}
            end
        end
        save_update_state(plugin,states)
        if type(plugin._refresh_miuread_menu)=="function" then plugin:_refresh_miuread_menu() end
        local msg="检查完成："..tostring(checked).." 个可跟踪扩展"
        if updates>0 then msg=msg.."\n发现更新："..tostring(updates) end
        if unknown>0 then msg=msg.."\n无法自动判断："..tostring(unknown) end
        plugin:info(msg)
    end,120)
end

local function fetch_repo_snapshot(plugin,repo,force,done)
    if not valid_repo(repo) then
        plugin:info("GitHub 仓库地址无效")
        return
    end
    if force~=true then
        local cached=meta_cache_get(plugin,repo,false)
        if cached then
            done(cached.repo_info,cached.release,cached.release_missing==true)
            return
        end
    end
    run_async_with_progress(plugin,"正在读取扩展信息……","extension_repo_snapshot",function()
        local info,repo_error=github_repo(plugin,repo)
        info=compact_repo_info(info)
        if not info then return {info=nil,error=repo_error} end
        local release,release_error=latest_release(plugin,repo)
        release=compact_release(release)
        return {info=info,release=release,release_missing=release_error=="no_release"}
    end,function(value,worker_error)
        local info=type(value)=="table" and value.info or nil
        if not info then
            local _,message=classify_github_error(worker_error or (type(value)=="table" and value.error or nil))
            plugin:info(message.."。")
            return
        end
        local release=type(value)=="table" and value.release or nil
        local release_missing=type(value)=="table" and value.release_missing==true
        meta_cache_put(plugin,repo,info,release,release_missing)
        done(info,release,release_missing)
    end,45)
end

local function check_single_update(plugin,item)
    if not item or not valid_repo(item.repo) then return end
    fetch_repo_snapshot(plugin,item.repo,true,function(info,release)
        local status=update_status_for(plugin,item,info,release)
        status.checked_at=os.time()
        local states=update_state(plugin)
        states[update_key(item)]=status
        save_update_state(plugin,states)
        if type(plugin._refresh_miuread_menu)=="function" then plugin:_refresh_miuread_menu() end
        if status.status=="update" then
            plugin:info("发现更新："..tostring(item.name or item.dir)
                ..(trim(status.remote_version)~="" and ("\n最新版本："..trim(status.remote_version)) or ""))
        elseif status.status=="same" then
            plugin:info("当前已是最新："..tostring(item.name or item.dir))
        else
            plugin:info("无法可靠判断这个插件是否有更新。\n\n你仍可以选择重新安装当前 GitHub 版本。")
        end
    end)
end

local function install_managed_repo(plugin,item,mode)
    if not item or not valid_repo(item.repo) or item.duplicate then return end
    fetch_repo_snapshot(plugin,item.repo,false,function(info,release)
        local is_update=mode=="update"
        local verb=is_update and "更新" or "重新安装"
        local note=is_update and "安装前会备份当前插件，写入失败会自动恢复。"
            or "当前版本会先备份，安装失败会自动恢复。"
        UIManager:show(ConfirmBox:new{
            text=verb.."“"..tostring(item.name or item.dir).."”？\n\n"..note,
            ok_text=verb,cancel_text="取消",
            ok_callback=function() install_repo(plugin,item.repo,info,release) end,
        })
    end)
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
        rows[#rows+1]={text="自动更新与卸载已停用",enabled=false}
        return rows
    end
    if valid_repo(item.repo) then
        local state=recent_update_state(update_state(plugin),item)
        if state and state.status=="update" then
            rows[#rows+1]={text="更新扩展",post_text=trim(state.remote_version)~="" and trim(state.remote_version) or "有更新",keep_menu_open=true,
                callback=function() install_managed_repo(plugin,item,"update") end}
        end
        rows[#rows+1]={text="检查更新",keep_menu_open=true,callback=function() check_single_update(plugin,item) end}
        rows[#rows+1]={text="重新安装",keep_menu_open=true,callback=function() install_managed_repo(plugin,item,"reinstall") end}
    end
    rows[#rows+1]={text="卸载插件",keep_menu_open=true,callback=function() uninstall(plugin,item) end}
    return rows
end

local function installed_detail(plugin,item)
    return show_menu(plugin,"插件 · "..tostring(item.name or item.dir),installed_detail_rows(plugin,item))
end

local function installed_menu(plugin)
    local rows={}
    local pending=pending_state(plugin)
    if next(pending)~=nil then
        rows[#rows+1]={text="部分插件更改需要重启",post_text="重启 KOReader",callback=function()
            if type(plugin._restart_koreader)=="function" then plugin:_restart_koreader("extension_center")
            else plugin:info("请完整重启 KOReader 后继续使用。") end
        end}
    end
    local list=managed_plugins(plugin)
    local trackable=0
    for _,item in ipairs(list) do if item.ghost~=true and valid_repo(item.repo) and not item.duplicate then trackable=trackable+1 end end
    rows[#rows+1]={text="检查更新",post_text=trackable>0 and (tostring(trackable).." 个可跟踪") or "暂无可跟踪扩展",enabled=trackable>0,keep_menu_open=true,callback=trackable>0 and function() check_updates(plugin) end or nil}
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

function M.menu(plugin)
    local rows={
        {text="觅阅推荐",post_text="第三方 GitHub 扩展",sub_item_table_func=function() return recommendation_menu(plugin) end},
        {text="搜索扩展",keep_menu_open=true,callback=function() show_search_dialog(plugin) end},
        {text="社区热门",post_text="GitHub",keep_menu_open=true,callback=function() github_search(plugin,"topic:koreader-plugin","社区热门",1,"popular",false) end},
        {text="已安装插件",separator=true,enabled=false},
    }
    local pending=pending_state(plugin)
    if next(pending)~=nil then
        rows[#rows+1]={text="部分插件更改需要重启",post_text="重启 KOReader",callback=function()
            if type(plugin._restart_koreader)=="function" then plugin:_restart_koreader("extension_center")
            else plugin:info("请完整重启 KOReader 后继续使用。") end
        end}
    end
    local list=managed_plugins(plugin)
    local trackable=0
    for _,item in ipairs(list) do
        if item.ghost~=true and valid_repo(item.repo) and not item.duplicate then trackable=trackable+1 end
    end
    rows[#rows+1]={
        text="检查全部更新",
        post_text=trackable>0 and (tostring(trackable).." 个可跟踪") or "暂无可跟踪扩展",
        enabled=trackable>0,
        keep_menu_open=true,
        callback=trackable>0 and function() check_updates(plugin) end or nil,
    }
    local states=update_state(plugin)
    for _,item in ipairs(list) do
        local target=item
        rows[#rows+1]={
            text=tostring(target.name or target.dir),
            post_text=installed_status_label(plugin,target,states),
            sub_item_table_func=function() return installed_detail_rows(plugin,target) end,
        }
    end
    if #list==0 then
        rows[#rows+1]={text="暂无用户插件",post_text="可从“觅阅推荐”或“搜索扩展”安装",enabled=false}
    end
    return rows
end

return M
