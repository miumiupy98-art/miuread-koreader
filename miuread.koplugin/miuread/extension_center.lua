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
local Catalog=require("miuread.extension_catalog")
local Compat=require("miuread.extension_compat")
local ExtensionInstaller=require("miuread.extension_installer")

local M={}

local RECORD_KEY="extension_center_installed_v2"
local LEGACY_RECORD_KEY="extension_center_installed"
local SEARCH_CACHE_KEY="extension_center_search_cache_v2"
local META_CACHE_KEY="extension_center_repo_cache_v2"
local UPDATE_STATE_KEY="extension_center_update_state_v2"
local PENDING_KEY="extension_center_pending_restart_v1"
local NETWORK_KEY="extension_center_network_v2"
local TEMP_CLEANUP_KEY="extension_center_temp_cleanup_v1"
local MAX_RESULTS=24
local SEARCH_TTL=30*60
local META_TTL=30*60
local UPDATE_VISIBLE_TTL=24*60*60
local MAX_ARCHIVE_ENTRIES=6000
local MAX_PLUGIN_FILES=5000
local MAX_PLUGIN_BYTES=96*1024*1024
local EXTENSION_STALL_SECONDS=60
local EXTENSION_CONNECT_SECONDS=18
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

local function alias_matches(query)
    return Catalog.alias_matches(query)
end

local function command_ok(rc)
    return rc==true or rc==0
end

local function trim(value)
    return U.trim(tostring(value or ""))
end

local function extension_network(plugin)
    local value=plugin.store:get(NETWORK_KEY,{mode="auto",custom_prefix="",health={}})
    value=type(value)=="table" and value or {mode="auto",custom_prefix="",health={}}
    value.mode=tostring(value.mode or "auto")
    value.custom_prefix=trim(value.custom_prefix)
    value.health=type(value.health)=="table" and value.health or {}
    return value
end

local function save_extension_network(plugin,value)
    value=type(value)=="table" and value or {}
    value.health=type(value.health)=="table" and value.health or {}
    plugin.store:set_deferred(NETWORK_KEY,value)
    plugin.store:flush()
end

local function route_label(key)
    if key=="direct" then return "GitHub 直连" end
    if key:sub(1,7)=="mirror:" then return "镜像 "..key:sub(8) end
    if key=="custom" then return "自定义镜像" end
    return key
end

local function update_route_health(plugin,key,ok,detail)
    local value=extension_network(plugin)
    local health=type(value.health[key])=="table" and value.health[key] or {}
    if ok then
        health.success_at=os.time(); health.fail_count=0; health.last_error=nil
    else
        health.fail_at=os.time(); health.fail_count=math.min(8,(tonumber(health.fail_count) or 0)+1)
        health.last_error=U.first_line(tostring(detail or "下载失败"),120)
    end
    value.health[key]=health
    save_extension_network(plugin,value)
end

local function route_score(value,key,index)
    local h=type(value.health[key])=="table" and value.health[key] or {}
    local now=os.time()
    local score=100-(tonumber(index) or 0)
    local success_age=now-(tonumber(h.success_at) or 0)
    local fail_age=now-(tonumber(h.fail_at) or 0)
    if tonumber(h.success_at) and tonumber(h.success_at)>0 and success_age>=0 and success_age<7*24*60*60 then score=score+80 end
    if tonumber(h.fail_at) and tonumber(h.fail_at)>0 and fail_age>=0 and fail_age<10*60 then
        score=score-120*math.max(1,tonumber(h.fail_count) or 1)
    end
    return score
end

local function valid_mirror_prefix(value)
    value=trim(value)
    return value:match("^https://")~=nil
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

local function remember_install(plugin,repo,dir,path,version,source_url,remote_ref,install_channel,source_kind)
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

local function command_available(name)
    return command_ok(os.execute("command -v "..tostring(name).." >/dev/null 2>&1"))
end

local function zip_magic_valid(path)
    local file=io.open(path,"rb")
    if not file then return nil,"无法读取下载文件" end
    local head=file:read(4) or ""
    file:close()
    if head=="PK\003\004" or head=="PK\005\006" or head=="PK\007\008" then return true end
    local preview=U.read_file(path,true) or ""
    preview=U.first_line(preview,100)
    return nil,"下载内容不是 ZIP"..(preview~="" and ("（返回："..preview.."）") or "")
end

local function zip_quick_valid(path)
    local magic,why=zip_magic_valid(path)
    if not magic then return nil,why end
    -- When unzip is present, validate the complete central directory before a
    -- route is considered successful. A proxy can return a truncated file that
    -- still starts with PK; that must fail over to the next route rather than
    -- being misreported later as a plugin-structure error.
    if command_available("unzip") then
        local ok=command_ok(os.execute("unzip -tqq "..U.shell_quote(path).." >/dev/null 2>&1"))
        if not ok then return nil,"ZIP 下载不完整或已经损坏" end
    end
    return true
end

local function curl_download_file(url,path,options)
    options=options or {}
    local connect_timeout=math.max(2,math.floor(tonumber(options.connect_timeout) or EXTENSION_CONNECT_SECONDS))
    local stall_seconds=math.max(15,math.floor(tonumber(options.stall_seconds) or EXTENSION_STALL_SECONDS))
    local speed_limit=math.max(1,math.floor(tonumber(options.speed_limit) or 1024))
    local partial=path..".part"
    local status_path=path..".curl.status"
    local error_path=path..".curl.error"
    os.remove(status_path); os.remove(error_path); os.remove(path)

    local function run(resume)
        local cmd="curl -L --fail --silent --show-error --connect-timeout "..tostring(connect_timeout)
            .." --speed-limit "..tostring(speed_limit).." --speed-time "..tostring(stall_seconds)
            .." --retry 1 --retry-delay 1"
        if resume and (U.file_size(partial) or 0)>0 then cmd=cmd.." -C -" end
        for _,header in ipairs(options.headers or {}) do
            cmd=cmd.." -H "..U.shell_quote(tostring(header))
        end
        cmd=cmd.." -o "..U.shell_quote(partial)
            .." -w "..U.shell_quote("%{http_code}")
            .." "..U.shell_quote(url)
            .." >"..U.shell_quote(status_path).." 2>"..U.shell_quote(error_path)
        local before=U.file_size(partial) or 0
        local ok=command_ok(os.execute(cmd))
        local after=U.file_size(partial) or 0
        local status=trim(U.read_file(status_path,true) or "")
        local err=trim(U.read_file(error_path,true) or "")
        os.remove(status_path); os.remove(error_path)
        return ok,status,err,before,after
    end

    local had_partial=(U.file_size(partial) or 0)>0
    local ok,status,err,before,after=run(had_partial)
    if not ok and had_partial then
        local low=err:lower()
        local range_rejected=status=="416" or low:find("range",1,true)~=nil
            or low:find("resume",1,true)~=nil or low:find("byte",1,true)~=nil
        if range_rejected then
            os.remove(partial)
            ok,status,err,before,after=run(false)
        end
    end
    if not ok or (U.file_size(partial) or 0)<=0 then
        return false,nil,{status=status,error=err~="" and err or "curl 下载失败",partial_bytes=U.file_size(partial) or after or before or 0}
    end
    local valid,why=zip_quick_valid(partial)
    if not valid then
        os.remove(partial)
        return false,nil,{status=status,error=why or "下载内容无效",partial_bytes=0}
    end
    os.remove(path)
    local moved,move_error=os.rename(partial,path)
    if not moved then
        return false,nil,{status=status,error="无法保存下载文件："..tostring(move_error or "rename failed"),partial_bytes=U.file_size(partial) or 0}
    end
    return true,U.file_size(path) or 0,{status=status,resumed=had_partial==true}
end

local function wget_download_file(url,path,options)
    options=options or {}
    local stall_seconds=math.max(15,math.floor(tonumber(options.stall_seconds) or EXTENSION_STALL_SECONDS))
    local partial=path..".part"
    local error_path=path..".wget.error"
    os.remove(error_path); os.remove(path)
    local before=U.file_size(partial) or 0
    local cmd="wget -c -T "..tostring(stall_seconds).." -t 2 -O "..U.shell_quote(partial)
        .." "..U.shell_quote(url).." 2>"..U.shell_quote(error_path)
    local ok=command_ok(os.execute(cmd))
    local err=trim(U.read_file(error_path,true) or "")
    os.remove(error_path)
    if not ok or (U.file_size(partial) or 0)<=0 then
        return false,nil,{error=err~="" and U.first_line(err,180) or "wget 下载失败",partial_bytes=U.file_size(partial) or before}
    end
    local valid,why=zip_quick_valid(partial)
    if not valid then
        os.remove(partial)
        return false,nil,{error=why or "下载内容无效",partial_bytes=0}
    end
    os.remove(path)
    local moved,move_error=os.rename(partial,path)
    if not moved then return false,nil,{error="无法保存下载文件："..tostring(move_error or "rename failed"),partial_bytes=U.file_size(partial) or 0} end
    return true,U.file_size(path) or 0,{resumed=before>0}
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

local function source_installability(plugin,repo,repo_info)
    repo_info=type(repo_info)=="table" and repo_info or {}
    local branch=trim(repo_info.default_branch)
    if branch=="" then branch="main" end
    local tree,err=github_json(plugin,"https://api.github.com/repos/"..repo.."/git/trees/"..url_encode(branch).."?recursive=1")
    if type(tree)~="table" or type(tree.tree)~="table" then
        return {installable=nil,roots={},error=tostring(err or "source probe unavailable"),updated_at=os.time()}
    end
    local dirs={}
    for _,item in ipairs(tree.tree) do
        if tostring(item.type or "")=="blob" then
            local path=tostring(item.path or "")
            local dir,file=path:match("^(.*)/([^/]+)$")
            if not file then dir=""; file=path end
            if file=="main.lua" or file=="_meta.lua" then
                dirs[dir]=dirs[dir] or {}
                dirs[dir][file]=true
            end
        end
    end
    local roots={}
    for dir,files in pairs(dirs) do
        if files["main.lua"] and files["_meta.lua"] then roots[#roots+1]=dir end
    end
    table.sort(roots)
    return {installable=#roots>0,roots=roots,updated_at=os.time()}
end

local function github_package_routes(plugin,url)
    local direct={key="direct",label="GitHub 直连",url=url,index=0}
    if not starts_with(url,"https://github.com/") then return {direct} end

    local value=extension_network(plugin)
    local mirrors={}
    for index,prefix in ipairs(Config.GITHUB_MIRRORS or {}) do
        prefix=trim(prefix)
        if valid_mirror_prefix(prefix) then
            if prefix:sub(-1)~="/" then prefix=prefix.."/" end
            mirrors[#mirrors+1]={key="mirror:"..tostring(index),label="镜像 "..tostring(index),url=prefix..url,index=index}
        end
    end
    if valid_mirror_prefix(value.custom_prefix) then
        local prefix=value.custom_prefix
        if prefix:sub(-1)~="/" then prefix=prefix.."/" end
        mirrors[#mirrors+1]={key="custom",label="自定义镜像",url=prefix..url,index=#mirrors+1}
    end

    if value.mode=="direct" then return {direct} end
    if value.mode=="custom" then
        for _,route in ipairs(mirrors) do if route.key=="custom" then return {route} end end
        return {direct}
    end
    local selected=value.mode:match("^mirror:(%d+)$")
    if selected then
        selected=tonumber(selected)
        for _,route in ipairs(mirrors) do if route.index==selected then return {route} end end
        return {direct}
    end

    local routes={direct}
    for _,route in ipairs(mirrors) do if route.key~="custom" then routes[#routes+1]=route end end
    table.sort(routes,function(a,b)
        local sa=route_score(value,a.key,a.index)
        local sb=route_score(value,b.key,b.index)
        if sa~=sb then return sa>sb end
        return a.index<b.index
    end)
    return routes
end

local function format_download_attempts(attempts)
    local rows={}
    for _,attempt in ipairs(type(attempts)=="table" and attempts or {}) do
        local label=tostring(attempt.label or route_label(tostring(attempt.key or "")))
        if attempt.ok==true then
            rows[#rows+1]=label.."：成功"
        else
            local detail=trim(attempt.error)
            if detail=="" then detail="下载失败" end
            rows[#rows+1]=label.."："..U.first_line(detail,120)
        end
    end
    return table.concat(rows,"\n")
end

local function download_package(plugin,url,label,target_override)
    local target=trim(target_override)
    if target=="" then
        target=plugin.store.temp_dir.."/extension-download-"..U.id_name(label or os.time())..".zip"
    end
    local attempts={}
    local curl_ok=command_available("curl")
    local wget_ok=not curl_ok and command_available("wget")
    for _,route in ipairs(github_package_routes(plugin,url)) do
        logger.info("[MiuRead][Extensions] package download start","route=",route.key,"url=",log_url(route.url),"resume_bytes=",tostring(U.file_size(target..".part") or 0))
        if curl_ok then
            local ok,size,detail=curl_download_file(route.url,target,{connect_timeout=EXTENSION_CONNECT_SECONDS,stall_seconds=EXTENSION_STALL_SECONDS})
            if ok then
                attempts[#attempts+1]={key=route.key,label=route.label,ok=true,bytes=size,url=route.url}
                logger.info("[MiuRead][Extensions] package download success","route=",route.key,"bytes=",tostring(size or 0),"url=",log_url(route.url))
                return target,route.url,attempts,route.key
            end
            local err=type(detail)=="table" and tostring(detail.error or "curl 下载失败") or tostring(detail or "curl 下载失败")
            attempts[#attempts+1]={key=route.key,label=route.label,ok=false,error=err,partial_bytes=type(detail)=="table" and detail.partial_bytes or nil}
            logger.warn("[MiuRead][Extensions] package curl route failed",route.key,log_url(route.url),err)
        elseif wget_ok then
            local ok,size,detail=wget_download_file(route.url,target,{stall_seconds=EXTENSION_STALL_SECONDS})
            if ok then
                attempts[#attempts+1]={key=route.key,label=route.label,ok=true,bytes=size,url=route.url}
                logger.info("[MiuRead][Extensions] package wget success","route=",route.key,"bytes=",tostring(size or 0))
                return target,route.url,attempts,route.key
            end
            local err=type(detail)=="table" and tostring(detail.error or "wget 下载失败") or tostring(detail or "wget 下载失败")
            attempts[#attempts+1]={key=route.key,label=route.label,ok=false,error=err,partial_bytes=type(detail)=="table" and detail.partial_bytes or nil}
            logger.warn("[MiuRead][Extensions] package wget route failed",route.key,log_url(route.url),err)
        else
            -- Last-resort ports without curl/wget use KOReader's streaming HTTP
            -- sink. This path cannot persist Range resume, but it still keeps a
            -- long bounded socket deadline and performs the same full ZIP check.
            os.remove(target)
            local ok,result=pcall(function()
                return plugin.http:download_to_file(route.url,target,{
                    auth=false,retries=1,redirects=10,timeout={EXTENSION_CONNECT_SECONDS,6*60*60},integrity_attempts=2,
                })
            end)
            if ok and U.file_exists(target) and (U.file_size(target) or 0)>0 then
                local valid,why=zip_quick_valid(target)
                if valid then
                    attempts[#attempts+1]={key=route.key,label=route.label,ok=true,bytes=U.file_size(target) or 0,url=route.url}
                    return target,route.url,attempts,route.key
                end
                os.remove(target)
                attempts[#attempts+1]={key=route.key,label=route.label,ok=false,error=why or "下载内容不是 ZIP"}
            else
                local err=tostring(result or "Lua 下载失败")
                attempts[#attempts+1]={key=route.key,label=route.label,ok=false,error=err}
                logger.warn("[MiuRead][Extensions] package Lua route failed",route.key,log_url(route.url),err)
            end
        end
    end
    os.remove(target)
    return nil,format_download_attempts(attempts),attempts,nil
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

local function extract_with_archiver(reader,unpacked,max_plugin_bytes)
    local limit=tonumber(max_plugin_bytes) or MAX_PLUGIN_BYTES
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
                if bytes>limit then error("插件解压后体积过大") end
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

local function zip_declared_size(path,max_plugin_bytes)
    local limit=tonumber(max_plugin_bytes) or MAX_PLUGIN_BYTES
    local cmd="unzip -l "..U.shell_quote(path).." 2>/dev/null"
    local pipe=io.popen(cmd,"r")
    if not pipe then return nil end
    local total=0
    for line in pipe:lines() do
        local size=line:match("^%s*(%d+)%s+%d%d%d%d[-/]%d%d[-/]%d%d%s+%d%d:%d%d%s+.+$")
        if size then
            total=total+(tonumber(size) or 0)
            if total>limit then break end
        end
    end
    pipe:close()
    return total
end

local function tree_stats(root,max_plugin_bytes)
    local limit=tonumber(max_plugin_bytes) or MAX_PLUGIN_BYTES
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
                    if bytes>limit then return nil,"插件解压后体积过大" end
                end
            end
        end
        return true
    end
    local ok,err=walk(root)
    if not ok then return nil,err end
    return {files=files,bytes=bytes}
end

local function collect_plugin_roots(root)
    local found={}
    local visited=0
    local function walk(path)
        visited=visited+1
        if visited>MAX_ARCHIVE_ENTRIES then return end
        if U.file_exists(path.."/main.lua") and U.file_exists(path.."/_meta.lua") then
            found[#found+1]=path
            return
        end
        local ok,iter,state=pcall(lfs.dir,path)
        if not ok or type(iter)~="function" then return end
        for entry in iter,state do
            if entry~="." and entry~=".." then
                local child=path.."/"..entry
                if lfs.attributes(child,"mode")=="directory" then walk(child) end
            end
        end
    end
    walk(root)
    return found
end

local function relative_to(path,root)
    local prefix=tostring(root or ""):gsub("/+$","").."/"
    path=tostring(path or "")
    if path:sub(1,#prefix)==prefix then return path:sub(#prefix+1) end
    return path
end

local function candidate_target_name(path,repo)
    local name=basename(path)
    local repo_name=tostring(repo or ""):match("/([^/]+)$") or ""
    if name:match("%.koplugin$") then return name end
    if repo_name:match("%.koplugin$") then return repo_name end
    if repo_name~="" then return repo_name..".koplugin" end
    return name..".koplugin"
end

local function plugin_candidate_score(path,repo)
    local repo_name=tostring(repo or ""):match("/([^/]+)$") or ""
    local repo_key=normalized_plugin_identity(repo_name:gsub("%.koplugin$",""))
    local name=basename(path)
    local name_key=normalized_plugin_identity(name:gsub("%.koplugin$",""))
    local meta=read_meta(path)
    local identity_key=normalized_plugin_identity(meta.identity)
    local score=0
    if name==repo_name then score=score+140 end
    if repo_key~="" and name_key==repo_key then score=score+110 end
    if repo_key~="" and identity_key~="" and (identity_key==repo_key or identity_key:find(repo_key,1,true)) then score=score+90 end
    if name:match("%.koplugin$") then score=score+25 end
    return score,meta
end

local function choose_plugin_root(unpacked,repo,selected_relative)
    local roots=collect_plugin_roots(unpacked)
    if #roots==0 then return nil,"没有找到完整 KOReader 插件（缺少 main.lua / _meta.lua）" end
    local candidates={}
    for _,path in ipairs(roots) do
        local relative=relative_to(path,unpacked)
        local target_name=candidate_target_name(path,repo)
        if valid_plugin_dir_name(target_name) then
            local score,meta=plugin_candidate_score(path,repo)
            candidates[#candidates+1]={path=path,relative=relative,target_name=target_name,score=score,meta=meta}
        end
    end
    if #candidates==0 then return nil,"找到插件文件，但目录名称无法安全转换为 .koplugin" end

    if trim(selected_relative)~="" then
        for _,candidate in ipairs(candidates) do
            if candidate.relative==selected_relative or candidate.target_name==selected_relative then
                return candidate.path,candidate.target_name,candidate
            end
        end
        return nil,"所选插件目录已经不存在，请重新选择"
    end

    table.sort(candidates,function(a,b)
        if a.score~=b.score then return a.score>b.score end
        return a.relative<b.relative
    end)
    if #candidates==1 then return candidates[1].path,candidates[1].target_name,candidates[1] end
    if candidates[1].score>candidates[2].score then
        return candidates[1].path,candidates[1].target_name,candidates[1]
    end

    local choices={}
    for _,candidate in ipairs(candidates) do
        choices[#choices+1]={
            relative=candidate.relative,
            target_name=candidate.target_name,
            name=trim(candidate.meta and candidate.meta.fullname)~="" and candidate.meta.fullname or candidate.target_name,
        }
    end
    return nil,{kind="multiple_plugins",candidates=choices,message="ZIP 中包含多个可安装插件，需要选择目标。"}
end

local function install_archive(plugin,repo,zip_path,source_url,version_hint,remote_ref,entry,compatibility,source_kind,install_channel,selected_relative)
    entry=type(entry)=="table" and entry or {}
    local max_plugin_bytes=tonumber(entry.max_plugin_bytes) or MAX_PLUGIN_BYTES
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
        local declared_size=zip_declared_size(zip_path,max_plugin_bytes)
        if declared_size and declared_size>max_plugin_bytes then
            os.remove(zip_path)
            return nil,"插件解压体积超过安全上限","archive_validate"
        end
    end

    local stamp=tostring(os.time()).."-"..tostring(math.random(1000,9999))
    local stage=plugin.store.temp_dir.."/extension-stage-"..stamp
    local unpacked=stage.."/unpacked"
    U.remove_tree(stage)
    U.mkdir(unpacked)
    local function fail(message,failed_stage,keep_zip)
        close_archiver(reader); reader=nil
        U.remove_tree(stage)
        if keep_zip~=true then os.remove(zip_path) end
        logger.warn("[MiuRead][Extensions] install failed","stage=",tostring(failed_stage or "unknown"),"repo=",repo,"error=",tostring(type(message)=="table" and (message.message or message.kind) or message))
        return nil,message,failed_stage
    end

    local stats,stats_error
    if use_archiver then
        logger.info("[MiuRead][Extensions] install stage","stage=extract","backend=archiver","repo=",repo)
        stats,stats_error=extract_with_archiver(reader,unpacked,max_plugin_bytes)
        close_archiver(reader); reader=nil
        if not stats then return fail(stats_error,"extract") end
    else
        logger.info("[MiuRead][Extensions] install stage","stage=extract","backend=unzip","repo=",repo)
        local rc=os.execute("unzip -q "..U.shell_quote(zip_path).." -d "..U.shell_quote(unpacked).." 2>/dev/null")
        if not command_ok(rc) then return fail("解压插件失败","extract") end
        stats,stats_error=tree_stats(unpacked,max_plugin_bytes)
        if not stats then return fail(stats_error,"extract_validate") end
    end
    logger.info("[MiuRead][Extensions] extract complete","repo=",repo,"files=",tostring(stats.files),"bytes=",tostring(stats.bytes),"backend=",use_archiver and "archiver" or "unzip")

    local incoming,target_name=choose_plugin_root(unpacked,repo,selected_relative)
    if not incoming then
        local keep=type(target_name)=="table" and target_name.kind=="multiple_plugins"
        return fail(target_name,keep and "plugin_select" or "plugin_detect",keep)
    end
    if target_name=="miuread.koplugin" then return fail("扩展中心不能覆盖觅阅自身","plugin_detect") end
    local candidate_ok,candidate_error=Compat.validate_candidate(entry,incoming,compatibility)
    if not candidate_ok then return fail(candidate_error,"architecture_validate") end
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
        local current_stats=tree_stats(existing.path,max_plugin_bytes)
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
    local installed_stats,installed_stats_error=tree_stats(target,max_plugin_bytes)
    if not installed_stats then return rollback(installed_stats_error,"post_validate") end

    local meta=read_meta(target)
    remember_install(plugin,repo,target_name,target,meta.version~="" and meta.version or version_hint,source_url,remote_ref,install_channel,source_kind)
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

local function network_mode_label(plugin)
    local value=extension_network(plugin)
    if value.mode=="direct" then return "GitHub 直连" end
    if value.mode=="custom" then return "自定义镜像" end
    local index=value.mode:match("^mirror:(%d+)$")
    if index then return "镜像 "..index end
    return "自动"
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
        {text="自动",post_text=current.mode=="auto" and "当前" or "优先最近可用线路",callback=function() set_network_mode(plugin,"auto") end},
        {text="GitHub 直连",post_text=current.mode=="direct" and "当前" or "",callback=function() set_network_mode(plugin,"direct") end},
    }
    for index,prefix in ipairs(Config.GITHUB_MIRRORS or {}) do
        local key="mirror:"..tostring(index)
        local h=type(current.health[key])=="table" and current.health[key] or {}
        local post=current.mode==key and "当前" or ""
        if tonumber(h.success_at) and tonumber(h.success_at)>0 then post=post~="" and (post.." · 最近成功") or "最近成功" end
        if tonumber(h.fail_at) and os.time()-tonumber(h.fail_at)<10*60 then post=post~="" and (post.." · 暂时降级") or "暂时降级" end
        rows[#rows+1]={text="镜像 "..tostring(index),post_text=post,callback=function() set_network_mode(plugin,key) end}
    end
    rows[#rows+1]={text="自定义镜像",post_text=current.mode=="custom" and "当前" or (current.custom_prefix~="" and "已配置" or "未配置"),keep_menu_open=true,callback=function() edit_custom_mirror(plugin) end}
    rows[#rows+1]={text="说明",separator=true,enabled=false}
    rows[#rows+1]={text="GitHub API 始终直连",post_text="镜像只负责下载文件",enabled=false}
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
        if item.ghost~=true and valid_repo(item.repo) then out[item.repo]=item end
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

local function preflight_package_space(plugin,source,item,entry)
    entry=type(entry)=="table" and entry or {}
    local max_plugin_bytes=tonumber(entry.max_plugin_bytes) or MAX_PLUGIN_BYTES
    local free=U.free_space(default_plugin_root())
    local minimum=tonumber(entry.required_free_bytes) or 0
    if free and minimum>0 and free<minimum then
        return nil,"可用存储空间不足；此扩展建议至少预留 "..Compat.format_bytes(minimum).."。"
    end
    local size=tonumber(type(source)=="table" and source.size or 0) or 0
    if size<=0 then return true end
    local existing_bytes=0
    if type(item)=="table" and item.path and item.path~="" then
        local stats=tree_stats(item.path,max_plugin_bytes)
        existing_bytes=type(stats)=="table" and (tonumber(stats.bytes) or 0) or 0
    end
    local needed=size*4+existing_bytes+8*1024*1024
    if free and free<needed then return nil,"存储空间不足，无法安全开始本次安装或更新。请先清理部分空间。" end
    return true
end

local function install_repo(plugin,repo,repo_info,release)
    if type(repo_info)~="table" then
        plugin:info("无法读取 GitHub 仓库信息。")
        return
    end
    local entry=known_repo(repo) or {repo=repo,name=display_repo_name(repo_info,nil),install_strategy="standard"}
    if repo_info.archived==true and entry.allow_archived_install~=true then
        plugin:info("这个仓库已经归档，觅阅不会自动安装。")
        return
    end
    local installed=find_managed_by_repo(plugin,repo)
    if installed and installed.duplicate then
        plugin:info("检测到这个插件存在多个安装位置。\n\n为避免更新错文件，请先只保留一份后再重试。")
        return
    end
    local installed_record=installed and record_for_installed(plugin,installed) or nil
    local sources,plan_error,compatibility=ExtensionInstaller.plan(entry,plugin,repo,repo_info,release,installed_record)
    if not sources or #sources==0 then
        plugin:info(plan_error or "当前没有可安全自动安装的插件包。")
        return
    end
    local retryable={archive_validate=true,extract=true,extract_validate=true,plugin_detect=true,architecture_validate=true}
    local display_name=display_repo_name(repo_info,entry)
    local candidate_errors={}

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
        local rows={"扩展安装失败。",""}
        if #candidate_errors>0 then
            rows[#rows+1]="尝试记录："
            for _,item in ipairs(candidate_errors) do
                rows[#rows+1]="• "..tostring(item)
            end
        end
        if last_error and tostring(last_error)~="" then
            rows[#rows+1]=""
            rows[#rows+1]=U.first_line(tostring(last_error),260)
        end
        local probe=type(repo_info.source_probe)=="table" and repo_info.source_probe or {}
        if probe.installable==false then
            rows[#rows+1]=""
            rows[#rows+1]="仓库源码已确认不是可直接安装的 KOReader 插件，因此没有用源码包伪装成 Release 兜底。"
        end
        plugin:info(table.concat(rows,"\n"))
    end

    local attempt
    attempt=function(index,last_error)
        local source=sources[index]
        if not source then fail_all(last_error); return end
        local enough,space_error=preflight_package_space(plugin,source,installed,entry)
        if not enough then plugin:info(space_error); return end

        local stable_id=repo.."-"..tostring(source.source or index).."-"..tostring(source.asset_name or source.version or index)
        local target=plugin.store.temp_dir.."/extension-download-"..U.id_name(stable_id)..".zip"
        local download_text=(installed and "正在下载扩展更新……" or "正在下载扩展……")
        run_async_with_progress(plugin,download_text,"extension_download",function()
            local path,used_or_error,attempts,route_key=download_package(plugin,source.url,stable_id,target)
            if path then return {ok=true,path=path,used_url=used_or_error,attempts=attempts,route_key=route_key} end
            return {ok=false,error=tostring(used_or_error or "下载失败"),attempts=attempts}
        end,function(value,worker_error)
            local route_attempts=type(value)=="table" and value.attempts or nil
            for _,route in ipairs(type(route_attempts)=="table" and route_attempts or {}) do
                update_route_health(plugin,tostring(route.key or "direct"),route.ok==true,route.error)
            end
            if worker_error then
                os.remove(target)
                logger.warn("[MiuRead][Extensions] package worker failed",repo,tostring(worker_error))
                candidate_errors[#candidate_errors+1]=tostring(source.source or "package").."："..U.first_line(worker_error,140)
                attempt(index+1,worker_error)
                return
            end
            if type(value)~="table" or value.ok~=true or not value.path then
                os.remove(target)
                local err=type(value)=="table" and value.error or "下载失败"
                logger.warn("[MiuRead][Extensions] package candidate download failed",repo,tostring(source.source),tostring(err))
                candidate_errors[#candidate_errors+1]=tostring(source.asset_name or source.source or "package").."："..U.first_line(err,180)
                attempt(index+1,err)
                return
            end

            local function inspect_and_install(selected_relative)
                local dialog=InfoMessage:new{text=selected_relative and "正在安装所选扩展……" or "正在检查并安装扩展……"}
                UIManager:show(dialog)
                UIManager:nextTick(function()
                    local ok,result,err,failed_stage=xpcall(function()
                        return install_archive(plugin,repo,value.path,value.used_url,source.version,source.remote_ref,
                            entry,compatibility,source.source,source.channel,selected_relative)
                    end,debug.traceback)
                    pcall(function() UIManager:close(dialog) end)
                    if not ok then
                        os.remove(value.path)
                        plugin:info("扩展安装失败。\n\n"..U.first_line(tostring(result),300))
                        return
                    end
                    if result then complete(result); return end
                    if tostring(failed_stage or "")=="plugin_select" and type(err)=="table" and type(err.candidates)=="table" then
                        local rows={}
                        for _,choice in ipairs(err.candidates) do
                            local target_choice=choice
                            rows[#rows+1]={
                                text=tostring(target_choice.name or target_choice.target_name),
                                post_text=tostring(target_choice.relative or ""),
                                keep_menu_open=true,
                                callback=function()
                                    if plugin._extension_menu then pcall(function() UIManager:close(plugin._extension_menu) end) end
                                    UIManager:nextTick(function() inspect_and_install(target_choice.relative) end)
                                end,
                            }
                        end
                        rows[#rows+1]={text="取消安装",callback=function() os.remove(value.path) end}
                        show_menu(plugin,"选择要安装的插件",rows)
                        return
                    end
                    local last=tostring(err or "安装失败")
                    candidate_errors[#candidate_errors+1]=tostring(source.asset_name or source.source or "package").."："..U.first_line(last,180)
                    if retryable[tostring(failed_stage or "")] then
                        logger.warn("[MiuRead][Extensions] trying next package candidate",repo,tostring(failed_stage),last)
                        UIManager:nextTick(function() attempt(index+1,last) end)
                        return
                    end
                    plugin:info("扩展安装失败。\n\n"..last)
                end)
            end
            inspect_and_install(nil)
        end,0,{cancel_cleanup=function()
            -- Keep .part for a later resume; only remove a completed-but-not-yet-
            -- installed ZIP when the user explicitly cancels this attempt.
            os.remove(target)
        end})
    end

    attempt(1,"没有找到可安装的插件包")
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

local function compatibility_summary(entry,compatibility)
    if type(entry)~="table" then return "未收录兼容资料" end
    if compatibility and compatibility.installable~=true then
        return compatibility.block_reason or "当前设备不支持自动安装"
    end
    if entry.ui_conflict==true and compatibility and compatibility.miuread_desktop then
        return "可安装 · 与觅阅桌面功能重叠"
    end
    if entry.architecture_sensitive==true and compatibility then
        return "可安装 · 已匹配 "..tostring(compatibility.arch_raw or compatibility.arch)
    end
    return "可安装"
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
    rows[#rows+1]={text="自动安装",post_text=compatibility_summary(entry,compatibility),enabled=false}
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

local function repo_detail_rows(plugin,repo,info,release,fallback,stale)
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
    else
        local author=tostring(repo or ""):match("^([^/]+)/") or "未知"
        rows[#rows+1]={text="作者",post_text=author,enabled=false}
        rows[#rows+1]={text="兼容资料",post_text="未收录 · 安装前仅做通用插件包安全校验",enabled=false}
    end
    rows[#rows+1]={text="来源",post_text="GitHub · 第三方扩展",enabled=false}
    rows[#rows+1]={text="仓库",post_text=repo,enabled=false}
    rows[#rows+1]={text="社区",post_text=tostring(info.stargazers_count or 0).." ★",enabled=false}
    if stale then rows[#rows+1]={text="网络状态",post_text="显示上次获取的信息",enabled=false} end
    if remote_version~="" then rows[#rows+1]={text="远端版本",post_text=remote_version,enabled=false} end
    if info.archived==true then
        rows[#rows+1]={text="仓库状态",post_text=fallback.allow_archived_install==true and "已归档 · 仅使用已发布 Release" or "已归档",enabled=false}
    end

    local auto_allowed=(info.archived~=true or fallback.allow_archived_install==true)
        and (not compatibility or compatibility.installable==true)
    local block_reason=compatibility and compatibility.block_reason or nil

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
        if auto_allowed then
            rows[#rows+1]={text="安装扩展",callback=function()
                UIManager:show(ConfirmBox:new{
                    text=third_party_install_text(plugin,repo,display_repo_name(info,fallback)),
                    ok_text="安装",cancel_text="取消",
                    ok_callback=function() install_repo(plugin,repo,info,release) end,
                })
            end}
        else
            rows[#rows+1]={text="自动安装不可用",post_text=block_reason or (info.archived==true and "仓库已归档" or "当前条件不支持"),enabled=false}
        end
    end
    return rows
end

local function repo_detail(plugin,repo,fallback,force)
    if not valid_repo(repo) then plugin:info("GitHub 仓库地址无效") return end
    fallback=known_repo(repo) or fallback
    local cached=not force and meta_cache_get(plugin,repo,false) or nil
    if cached then
        return show_menu(plugin,"扩展 · "..display_repo_name(cached.repo_info,fallback),repo_detail_rows(plugin,repo,cached.repo_info,cached.release,fallback,false))
    end
    run_async_with_progress(plugin,"正在读取扩展信息……","extension_repo_detail",function()
        local info,repo_error=github_repo(plugin,repo)
        info=compact_repo_info(info)
        if not info then return {info=nil,error=repo_error} end
        info.source_probe=source_installability(plugin,repo,info)
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
        .."“觅阅推荐”是面向中文 KOReader 用户的人工精选；“社区热门”和“搜索扩展”仍直接使用 GitHub 社区结果，不会因为觅阅没有推荐某个项目而把它隐藏。\n\n"
        .."扩展安装包会检查 ZIP 路径、插件结构、体积、剩余空间和重复安装；架构相关扩展还会匹配 CPU/Release，带本机程序的扩展会额外验证包内 ELF 架构。更新现有插件前会备份，写入失败自动恢复。\n\n"
        .."卡欧市场等没有可持续验证公开官方仓库的项目只提供介绍，不猜测下载地址。第三方扩展由其作者维护，安装、更新或卸载后请完整重启 KOReader。"
    )
end

local function recommendation_entry_row(plugin,entry,installed,states)
    local post=trim(entry.recommendation)
    if entry.experimental==true then post=post~="" and (post.." · Beta") or "Beta" end
    if entry.install_strategy=="external_manual" or entry.auto_install==false then
        post=post~="" and (post.." · 手动安装") or "手动安装"
    end
    if valid_repo(entry.repo) then
        local item=installed[entry.repo]
        local status=item and installed_status_label(plugin,item,states) or ""
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
        {text="第三方扩展 · 觅阅人工整理",enabled=false},
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
        {text="觅阅推荐",post_text="人工精选",sub_item_table_func=function() return recommendation_menu(plugin) end},
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
                local cached,is_stale=meta_cache_get(plugin,item.repo,true)
                if cached and type(cached.repo_info)=="table" then
                    rows[#rows+1]={
                        key=item.key,repo=item.repo,info=cached.repo_info,release=cached.release,
                        release_missing=cached.release_missing==true,stale=true,
                        status=update_status_for(plugin,item,cached.repo_info,cached.release),
                    }
                else
                    rows[#rows+1]={key=item.key,repo=item.repo,error=repo_error}
                end
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
        local checked,updates,unknown,stale_used=0,0,0,0
        for _,row in ipairs(type(rows)=="table" and rows or {}) do
            if type(row.info)=="table" and type(row.status)=="table" then
                local status=row.status
                status.checked_at=os.time(); states[row.key]=status
                meta_cache_put(plugin,row.repo,row.info,row.release,row.release_missing==true)
                checked=checked+1
                if row.stale==true then stale_used=stale_used+1 end
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
        if stale_used>0 then msg=msg.."\n其中 "..tostring(stale_used).." 个使用了上次成功获取的信息" end
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
        info.source_probe=source_installability(plugin,repo,info)
        local release,release_error=latest_release(plugin,repo)
        release=compact_release(release)
        return {info=info,release=release,release_missing=release_error=="no_release"}
    end,function(value,worker_error)
        local info=type(value)=="table" and value.info or nil
        if not info then
            local cached,is_stale=meta_cache_get(plugin,repo,true)
            if cached and type(cached.repo_info)=="table" then
                local cached_info=U.copy(cached.repo_info)
                cached_info._miuread_stale=true
                if type(plugin.toast)=="function" then
                    plugin:toast("GitHub 暂时不可用，已使用上次成功获取的扩展信息",4)
                end
                done(cached_info,cached.release,cached.release_missing==true,true)
                return
            end
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
    local catalog_entry=valid_repo(item.repo) and known_repo(item.repo) or nil
    local catalog_compatibility
    if catalog_entry then catalog_compatibility=append_catalog_rows(rows,plugin,catalog_entry) end
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
        return rows
    end
    if valid_repo(item.repo) then
        local state=recent_update_state(update_state(plugin),item)
        local can_install=not catalog_compatibility or catalog_compatibility.installable==true
        if state and state.status=="update" and can_install then
            rows[#rows+1]={text="更新扩展",post_text=trim(state.remote_version)~="" and trim(state.remote_version) or "有更新",keep_menu_open=true,
                callback=function() install_managed_repo(plugin,item,"update") end}
        elseif state and state.status=="update" and not can_install then
            rows[#rows+1]={text="有更新",post_text=catalog_compatibility.block_reason or "当前条件不支持自动安装",enabled=false}
        end
        rows[#rows+1]={text="检查更新",keep_menu_open=true,callback=function() check_single_update(plugin,item) end}
        if can_install then
            rows[#rows+1]={text="重新安装",keep_menu_open=true,callback=function() install_managed_repo(plugin,item,"reinstall") end}
        else
            rows[#rows+1]={text="自动重装不可用",post_text=catalog_compatibility.block_reason or "当前条件不支持",enabled=false}
        end
    end
    rows[#rows+1]={text="卸载插件",keep_menu_open=true,callback=function() uninstall(plugin,item) end}
    return rows
end

local function installed_detail(plugin,item)
    return show_menu(plugin,"插件 · "..tostring(item.name or item.dir),installed_detail_rows(plugin,item))
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
    pcall(cleanup_stale_extension_temp,plugin,false)
    local rows={
        {text="觅阅推荐",post_text="人工精选",sub_item_table_func=function() return recommendation_menu(plugin) end},
        {text="搜索扩展",keep_menu_open=true,callback=function() show_search_dialog(plugin) end},
        {text="社区热门",post_text="GitHub",keep_menu_open=true,callback=function() github_search(plugin,"topic:koreader-plugin","社区热门",1,"popular",false) end},
        {text="扩展下载源",post_text=network_mode_label(plugin),sub_item_table_func=function() return download_source_menu(plugin) end},
        {text="已安装插件",separator=true,enabled=false},
    }
    local pending_n=pending_count(plugin)
    if pending_n>0 then
        rows[#rows+1]={text="待重启生效",post_text=tostring(pending_n).." 项",sub_item_table_func=function() return pending_restart_rows(plugin) end}
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

function M.cleanup_stale(plugin,force)
    return cleanup_stale_extension_temp(plugin,force==true)
end

return M
