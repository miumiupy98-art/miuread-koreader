local Config=require("miuread.config")
local Digests=require("miuread.digests")
local U=require("miuread.util")
local logger=require("logger")
local Updater={}; Updater.__index=Updater
local BOOT_SESSION_KEY="__MIUREAD_UPDATE_BOOT_SESSION"

function Updater:new(http,store,version,plugin_root)
    return setmetatable({http=http,store=store,version=version,plugin_root=plugin_root},self)
end

local function valid_https(url)
    return type(url)=="string" and url:match("^https://")~=nil
end

local function append_unique(out,seen,value)
    if valid_https(value) and not seen[value] then
        seen[value]=true
        out[#out+1]=value
    end
end

local function is_github_resource(url)
    if type(url)~="string" then return false end
    return url:match("^https://github%.com/")
        or url:match("^https://raw%.githubusercontent%.com/")
end

local function with_github_mirrors(url,out,seen)
    append_unique(out,seen,url)
    if not is_github_resource(url) then return end
    for _,prefix in ipairs(Config.GITHUB_MIRRORS or {}) do
        if valid_https(prefix) then
            if prefix:sub(-1)~="/" then prefix=prefix.."/" end
            append_unique(out,seen,prefix..url)
        end
    end
end

function Updater:selected_channel()
    local selected=""
    if self.store and type(self.store.preferences)=="function" then
        local ok,prefs=pcall(self.store.preferences,self.store)
        if ok and type(prefs)=="table" and type(prefs.update)=="table" then
            selected=tostring(prefs.update.channel or "")
        end
    end
    if selected~="stable" and selected~="beta" then
        selected=tostring(Config.UPDATE_CHANNEL or "stable")
    end
    if selected~="stable" and selected~="beta" then selected="stable" end
    return selected
end

function Updater:channel_config(channel)
    channel=tostring(channel or self:selected_channel())
    local channels=Config.UPDATE_CHANNELS
    local cfg=type(channels)=="table" and channels[channel] or nil
    if type(cfg)=="table" then return cfg end
    return {
        label=Config.UPDATE_CHANNEL_LABEL,
        manifest=Config.UPDATE_MANIFEST,
        manifests=Config.UPDATE_MANIFESTS,
    }
end

function Updater:channel_label(channel)
    channel=tostring(channel or self:selected_channel())
    local cfg=self:channel_config(channel)
    return tostring(cfg.label or (channel=="beta" and "内测通道" or "正式通道"))
end

function Updater:manifest_urls(channel)
    channel=tostring(channel or self:selected_channel())
    local cfg=self:channel_config(channel)
    local out,seen={},{}
    -- The manifest carries both the package URLs and their SHA-256, so it is
    -- the trust root of an update. Fetch it only from the configured official
    -- URLs; mirrors stay limited to package downloads, which the official
    -- manifest's digest still verifies. A previously remembered mirror route
    -- is not in this set and is therefore ignored below (#127).
    local configured=cfg.manifests
    if type(configured)=="table" then
        for _,url in ipairs(configured) do append_unique(out,seen,url) end
    else
        append_unique(out,seen,cfg.manifest)
    end
    local preferred=tostring(self.store and self.store:get("update_last_good_manifest_url_"..channel,"") or "")
    if preferred=="" then
        preferred=tostring(self.store and self.store:get("update_last_good_manifest_url","") or "")
    end
    if preferred~="" and seen[preferred] then
        for index,url in ipairs(out) do
            if url==preferred then
                table.remove(out,index)
                table.insert(out,1,preferred)
                break
            end
        end
    end
    return out
end

function Updater:remember_manifest_route(url,channel)
    url=tostring(url or "")
    if not valid_https(url) or not self.store then return false end
    channel=tostring(channel or self:selected_channel())
    local official=false
    for _,candidate in ipairs(self:manifest_urls(channel)) do
        if candidate==url then official=true; break end
    end
    if not official then
        logger.warn("[MiuRead][Updater] refused to remember non-official manifest route",channel,url)
        return false
    end
    self.store:set("update_last_good_manifest_url_"..channel,url)
    logger.info("[MiuRead][Updater] remembered manifest route",channel,url)
    return true
end

function Updater:manifest_url(channel)
    return self:manifest_urls(channel)[1]
end

local function collect_table_urls(value,out,seen)
    if type(value)~="table" then return end
    for _,url in ipairs(value) do with_github_mirrors(url,out,seen) end
end

local function package_urls(manifest)
    local out,seen={},{}
    if type(manifest)~="table" then return out end
    with_github_mirrors(manifest.package_url or manifest.url,out,seen)
    collect_table_urls(manifest.package_urls,out,seen)
    collect_table_urls(manifest.mirror_urls,out,seen)
    collect_table_urls(manifest.mirrors,out,seen)
    return out
end

local function command_ok(rc)
    return rc==true or rc==0
end

local function file_bytes(path)
    local data=U.read_file(path,true)
    if type(data)~="string" then return nil end
    return data
end

local function update_artifact_kind(path)
    local name=tostring(path or ""):match("([^/]+)$") or ""
    if name:match("^stage%-") then return "stage" end
    if name:match("^backup%-") then return "backup" end
    if name:match("^miuread%-.+%.zip$") then return "package" end
    return nil
end

local function path_inside(root,path)
    root=tostring(root or ""):gsub("/+$","")
    path=tostring(path or "")
    return root~="" and path:sub(1,#root+1)==root.."/"
end

function Updater:_remove_download(path)
    if not path_inside(self.store.updates_dir,path) or update_artifact_kind(path)~="package" then return false end
    local removed,err=U.remove_tree(path)
    if not removed then
        logger.warn("[MiuRead][Updater] unable to remove update package",tostring(path),tostring(err))
        return false
    end
    return true
end

function Updater:_cleanup_update_artifacts(protected)
    protected=type(protected)=="table" and protected or {}
    local removed={stage=0,backup=0,package=0}
    for _,path in ipairs(U.list(self.store.updates_dir)) do
        local kind=update_artifact_kind(path)
        if kind and not protected[path] then
            local ok,err=U.remove_tree(path)
            if ok then
                removed[kind]=removed[kind]+1
            else
                logger.warn("[MiuRead][Updater] artifact cleanup failed",tostring(path),tostring(err))
            end
        end
    end
    if removed.stage+removed.backup+removed.package>0 then
        logger.info("[MiuRead][Updater] artifacts cleaned",
            "stage=",tostring(removed.stage),
            "backup=",tostring(removed.backup),
            "package=",tostring(removed.package))
    end
    return removed
end

local function clean_notes(value)
    local text=tostring(value or "")
    if not U.is_valid_utf8(text) or U.contains_replacement_char(text) then return nil end
    text=text:gsub("\r\n","\n"):gsub("\r","\n")
    -- Lua patterns operate on bytes, so a UTF-8 character class such as
    -- [•●▪◦] can corrupt unrelated multibyte text. Replace each symbol as a
    -- complete string instead.
    text=text:gsub("•","-"):gsub("●","-"):gsub("▪","-"):gsub("◦","-")
    text=text:gsub("：",":"):gsub("，",","):gsub("。","."):gsub("、",",")
    text=text:gsub("“",""):gsub("”",""):gsub("‘",""):gsub("’","")
    text=text:gsub("—","-"):gsub("–","-"):gsub("·","-")
    text=text:gsub("[%z\1-\8\11\12\14-\31]","")
    if not U.is_valid_utf8(text) or U.contains_replacement_char(text) then return nil end
    local lines={}
    for line in text:gmatch("[^\n]+") do
        line=line:gsub("^%s+",""):gsub("%s+$","")
        if line~="" then
            lines[#lines+1]=line
            if #lines>=4 then break end
        end
    end
    return table.concat(lines,"\n")
end

local function clean_manifest_text(m)
    local notes=m and m.notes~=nil and clean_notes(m.notes) or nil
    local summary=m and m.summary~=nil and clean_notes(m.summary) or nil
    local name=m and m.name~=nil and clean_notes(m.name) or nil
    if m and m.notes~=nil and notes==nil then return nil,"更新说明包含损坏的 UTF-8 文本" end
    if m and m.summary~=nil and summary==nil then return nil,"更新摘要包含损坏的 UTF-8 文本" end
    if m and m.name~=nil and name==nil then return nil,"更新名称包含损坏的 UTF-8 文本" end
    if summary=="" then summary=nil end
    return {notes=notes or "",summary=summary or notes or "",name=name}
end

local function validate_manifest(m,expected_channel)
    if type(m)~="table" or type(m.version)~="string" or m.version=="" then
        return nil,"更新清单缺少版本号"
    end
    expected_channel=tostring(expected_channel or "stable")
    local manifest_channel=tostring(m.channel or "")
    if manifest_channel=="" and expected_channel=="stable" then manifest_channel="stable" end
    if manifest_channel~=expected_channel then
        return nil,"更新清单通道不匹配：目标为"..expected_channel.."，清单为"..(manifest_channel~="" and manifest_channel or "未标记")
    end
    m.channel=manifest_channel
    if m.package_type~=nil and tostring(m.package_type)~="full" then
        return nil,"更新清单不是全量包"
    end
    if #package_urls(m)==0 then return nil,"更新清单缺少安装包地址" end
    local expected=tostring(m.sha256 or ""):lower():gsub("%s+","")
    if expected=="" then return nil,"更新清单缺少 SHA-256" end
    return true
end

function Updater:check()
    local target_channel=self:selected_channel()
    local channel_cfg=self:channel_config(target_channel)
    local urls=self:manifest_urls(target_channel)
    if #urls==0 then return nil,"更新地址未配置" end
    local errors={}
    local fallback
    local current_fallback
    local canonical=tostring(channel_cfg.manifest or "")
    for _,url in ipairs(urls) do
        local ok,m=pcall(function()
            return self.http:get_json(url,{
                auth=false,
                retries=tonumber(Config.UPDATE_MANIFEST_RETRIES) or 0,
                redirects=8,
                timeout={
                    tonumber(Config.UPDATE_MANIFEST_CONNECT_TIMEOUT) or 4,
                    tonumber(Config.UPDATE_MANIFEST_TOTAL_TIMEOUT) or 8,
                },
            })
        end)
        if ok then
            local valid,reason=validate_manifest(m,target_channel)
            if valid then
                local cleaned,text_error=clean_manifest_text(m)
                if not cleaned then
                    if not fallback or U.semver_newer(m.version,fallback.version) then
                        fallback=U.copy(m)
                        fallback._manifest_source_url=url
                        fallback.notes="更新说明显示异常 可继续下载安装"
                        fallback.summary=fallback.notes
                        fallback.name=tostring(m.name or "")
                    end
                    errors[#errors+1]=text_error
                    logger.warn("[MiuRead][Updater] manifest text rejected",url,
                        "replacement_chars=",tostring(U.replacement_char_count(m.notes or "")),
                        "reason=",tostring(text_error))
                else
                    m.notes=cleaned.notes
                    m.summary=cleaned.summary
                    if cleaned.name~=nil then m.name=cleaned.name end
                    logger.info("[MiuRead][Updater] manifest loaded",url,"version=",tostring(m.version),
                        "notes_utf8_valid=true")
                    if U.semver_newer(m.version,self.version) then
                        m._manifest_source_url=url
                        m._target_channel=target_channel
                        return m
                    end
                    local current={current=true,ahead=U.semver_compare(self.version,m.version)>0,
                        version=m.version,name=m.name,notes=m.notes,_manifest_source_url=url,
                        _target_channel=target_channel}
                    if url==canonical then
                        return current
                    end
                    if not current_fallback or U.semver_newer(m.version,current_fallback.version) then
                        current_fallback=current
                    end
                    logger.warn("[MiuRead][Updater] non-authoritative manifest is not newer; checking canonical route",
                        url,"version=",tostring(m.version))
                end
            else
                errors[#errors+1]=reason
            end
        else
            errors[#errors+1]=tostring(m)
            logger.warn("[MiuRead][Updater] manifest failed",url,tostring(m))
        end
    end
    if fallback then
        if U.semver_newer(fallback.version,self.version) then
            fallback._target_channel=target_channel
            return fallback
        end
        if not current_fallback or U.semver_newer(fallback.version,current_fallback.version) then
            current_fallback={current=true,ahead=U.semver_compare(self.version,fallback.version)>0,
                version=fallback.version,name=fallback.name,notes=fallback.notes,
                _manifest_source_url=fallback._manifest_source_url,_target_channel=target_channel}
        end
    end
    if current_fallback then return current_fallback end
    return nil,errors[#errors] or "无法读取更新清单"
end

local function curl_download(url,path)
    local cmd="curl -L --fail --silent --show-error --connect-timeout 20 --max-time 180 -o "
        ..U.shell_quote(path).." "..U.shell_quote(url).." 2>/dev/null"
    logger.info("[MiuRead][Updater] curl fallback download",url)
    return command_ok(os.execute(cmd))
end

local function download_one(self,url,path)
    os.remove(path)
    local ok,data=pcall(function()
        return self.http:download(url,{auth=false,retries=2,redirects=10,timeout={20,150}})
    end)
    if ok and type(data)=="string" and #data>0 then
        local wrote,err=U.atomic_write(path,data,true)
        if not wrote then return nil,err or "无法保存更新包" end
        return true
    end
    logger.warn("[MiuRead][Updater] Lua download unavailable or empty; using curl",url,tostring(data))
    if curl_download(url,path) then return true end
    return nil,tostring(data or "下载失败")
end

function Updater:download(m)
    local pending=self.store:update_state()
    if pending.pending then error("上次更新尚未确认，请完整重启 KOReader 后再更新") end
    self:_cleanup_update_artifacts()
    local urls=package_urls(m)
    if #urls==0 then error("更新包地址无效") end
    local p=self.store.updates_dir.."/miuread-"..U.id_name(m.version)..".zip"
    local expected=tostring(m.sha256 or ""):lower():gsub("%s+","")
    if expected=="" then error("更新清单缺少 SHA-256") end
    local expected_size=tonumber(m.size or m.bytes or m.package_size)
    local last_error="下载失败"

    for index,url in ipairs(urls) do
        local downloaded,err=download_one(self,url,p)
        local raw=downloaded and file_bytes(p) or nil
        if type(raw)=="string" and #raw>0 then
            if expected_size and expected_size>0 and #raw~=expected_size then
                last_error="更新包大小不符"
                logger.warn("[MiuRead][Updater] size mismatch",url,"expected=",tostring(expected_size),"actual=",tostring(#raw))
            else
                local actual=Digests.sha256(raw):lower()
                if actual==expected then
                    logger.info("[MiuRead][Updater] package downloaded",
                        "source=",tostring(index),"bytes=",tostring(#raw),"version=",tostring(m.version))
                    return p
                end
                last_error="更新包校验失败"
                logger.warn("[MiuRead][Updater] sha256 mismatch",url)
            end
        else
            last_error=err or "更新包下载失败或文件为空"
        end
        os.remove(p)
    end
    error(last_error)
end

local function safe_relative(rel)
    if type(rel)~="string" or rel=="" or rel:sub(1,1)=="/" or rel:find("\\",1,true) then return nil end
    for part in rel:gmatch("[^/]+") do if part==".." or part=="." or part=="" then return nil end end
    return rel
end

function Updater:install(path,manifest)
    local pending=self.store:update_state()
    if pending.pending then
        self:_remove_download(path)
        return nil,"上次更新尚未确认，请完整重启 KOReader 后再更新"
    end
    self:_cleanup_update_artifacts({[path]=true})

    local stamp=tostring(os.time()).."-"..tostring(math.random(1000,9999))
    local stage=self.store.updates_dir.."/stage-"..stamp
    local unpacked=stage.."/unpacked"
    local backup=self.store.updates_dir.."/backup-"..stamp
    U.remove_tree(stage); U.remove_tree(backup); U.mkdir(unpacked)

    local function fail(message)
        U.remove_tree(stage)
        U.remove_tree(backup)
        self:_remove_download(path)
        return nil,message
    end

    -- 全量包必须只包含一个 miuread.koplugin 根目录。
    local rc=os.execute("unzip -q "..U.shell_quote(path).." -d "..U.shell_quote(unpacked).." 2>/dev/null")
    if not command_ok(rc) then return fail("解压更新包失败") end

    local incoming=unpacked.."/miuread.koplugin"
    if not U.file_exists(incoming.."/main.lua") or not U.file_exists(incoming.."/_meta.lua") then
        return fail("更新包缺少 miuread.koplugin 或插件文件不完整")
    end
    local incoming_config=U.read_file(incoming.."/miuread/config.lua",true) or ""
    local incoming_version=incoming_config:match('VERSION%s*=%s*["\']([^"\']+)["\']')
    local incoming_channel=incoming_config:match('UPDATE_CHANNEL%s*=%s*["\']([^"\']+)["\']') or "stable"
    if tostring(incoming_version or "")~=tostring(manifest.version or "") then
        return fail("更新包版本与清单不一致")
    end
    local target_channel=tostring(manifest.channel or "stable")
    if tostring(incoming_channel)~=target_channel then
        return fail("更新包通道与目标通道不匹配，已拒绝安装")
    end
    local roots=U.list(unpacked)
    if #roots~=1 or roots[1]~=incoming then
        return fail("更新包根目录必须只包含 miuread.koplugin")
    end

    local ok,e=U.copy_tree(self.plugin_root,backup)
    if not ok then return fail("备份当前插件失败："..tostring(e)) end

    local function rollback(message)
        U.remove_tree(self.plugin_root)
        local restored,re=U.copy_tree(backup,self.plugin_root)
        U.remove_tree(stage)
        self:_remove_download(path)
        if not restored then
            return nil,tostring(message).."；回滚也失败："..tostring(re).."；备份已保留在 "..tostring(backup)
        end
        U.remove_tree(backup)
        return nil,tostring(message).."；已恢复旧版本"
    end

    U.remove_tree(self.plugin_root)
    local moved=os.rename(incoming,self.plugin_root)
    if not moved then
        local copied,ce=U.copy_tree(incoming,self.plugin_root)
        if not copied then return rollback("安装新文件失败："..tostring(ce)) end
    end
    if not U.file_exists(self.plugin_root.."/main.lua") or not U.file_exists(self.plugin_root.."/_meta.lua") then
        return rollback("安装后的插件文件不完整")
    end

    -- 兼容旧清单；全量替换通常不再需要 delete_list。
    if type(manifest.delete_list)=="table" then
        for _,rel in ipairs(manifest.delete_list) do
            rel=safe_relative(rel)
            if not rel then return rollback("delete_list 包含不安全路径") end
            local target=self.plugin_root.."/"..rel
            local removed=U.remove_tree(target)
            if removed==false then return rollback("无法删除旧文件："..rel) end
        end
    end

    U.remove_tree(stage)
    self.store:save_update_state({
        pending=true,
        expected=manifest.version,
        backup=backup,
        package=path,
        installed_at=os.time(),
        startup_attempts=0,
        startup_confirmed=false,
    })
    logger.info("[MiuRead][Updater] update installed",
        "version=",tostring(manifest.version),
        "backup=",tostring(backup),
        "package=",tostring(path))
    return true
end

local function valid_plugin_tree(root)
    root=tostring(root or "")
    if root=="" then return false end
    return U.file_exists(root.."/main.lua")
        and U.file_exists(root.."/_meta.lua")
        and U.file_exists(root.."/miuread/config.lua")
end

function Updater:_restore_backup(state,reason)
    state=type(state)=="table" and state or {}
    local backup=tostring(state.backup or "")
    if backup=="" or not path_inside(self.store.updates_dir,backup) or not valid_plugin_tree(backup) then
        logger.err("[MiuRead][Updater] rollback unavailable",
            "reason=",tostring(reason or "startup failure"),
            "backup=",backup~="" and backup or "missing")
        return nil,"rollback unavailable"
    end

    local failed=self.plugin_root..".failed-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))
    U.remove_tree(failed)
    local live_exists=valid_plugin_tree(self.plugin_root)
    if live_exists then
        local parked,park_error=os.rename(self.plugin_root,failed)
        if not parked then
            local copied,copy_error=U.copy_tree(self.plugin_root,failed)
            if not copied then
                return nil,"unable to preserve failed plugin: "..tostring(copy_error or park_error)
            end
            local removed,remove_error=U.remove_tree(self.plugin_root)
            if not removed then
                U.remove_tree(failed)
                return nil,"unable to replace failed plugin: "..tostring(remove_error)
            end
        end
    else
        U.remove_tree(self.plugin_root)
    end

    local restored,restore_error=os.rename(backup,self.plugin_root)
    if not restored then
        restored,restore_error=U.copy_tree(backup,self.plugin_root)
    end
    if not restored or not valid_plugin_tree(self.plugin_root) then
        U.remove_tree(self.plugin_root)
        if live_exists and valid_plugin_tree(failed) then os.rename(failed,self.plugin_root) end
        return nil,"rollback restore failed: "..tostring(restore_error or "invalid backup")
    end

    U.remove_tree(backup)
    U.remove_tree(failed)
    if state.package then self:_remove_download(state.package) end
    self.store:save_update_state({})
    self:_cleanup_update_artifacts()
    logger.warn("[MiuRead][Updater] previous version restored after unconfirmed startup",
        "expected=",tostring(state.expected),
        "reason=",tostring(reason or "startup failure"))
    return true
end

-- Called immediately after Store:new(), before optional device probes or UI
-- setup. A freshly installed version gets exactly one trial startup. If KOReader
-- had to be force-restarted before that trial was confirmed, the next launch
-- restores the saved plugin tree before any non-essential startup work runs.
function Updater:begin_startup()
    local s=self.store:update_state()
    if not s.pending then return nil end

    local expected=tostring(s.expected or "")
    local running=tostring(self.version or "")
    -- FileManager and ReaderUI may instantiate the plugin more than once in the
    -- same KOReader process. Count a trial only once per process; otherwise a
    -- fast context switch could look like a failed reboot and trigger rollback.
    local boot_session=rawget(_G,BOOT_SESSION_KEY)
    if type(boot_session)=="table"
        and tostring(boot_session.expected or "")==expected
        and tostring(boot_session.running or "")==running then
        return boot_session.state
    end
    if expected~=running then
        -- The user has already put an older plugin tree back in place. Do not
        -- leave the stale pending marker blocking all future updates. Only the
        -- updater artifacts are removed; account/library data are untouched.
        if s.backup then U.remove_tree(s.backup) end
        if s.package then self:_remove_download(s.package) end
        self.store:save_update_state({})
        self:_cleanup_update_artifacts()
        logger.warn("[MiuRead][Updater] stale pending state cleared after external rollback",
            "expected=",expected,"running=",running)
        rawset(_G,BOOT_SESSION_KEY,{expected=expected,running=running,state="recovered"})
        return "recovered"
    end

    local attempts=tonumber(s.startup_attempts or 0) or 0
    if s.startup_confirmed~=true and attempts>=1 then
        local ok,err=self:_restore_backup(s,"previous startup was not confirmed")
        if ok then
            rawset(_G,BOOT_SESSION_KEY,{expected=expected,running=running,state="rolled_back"})
            return "rolled_back"
        end
        logger.err("[MiuRead][Updater] automatic rollback failed",tostring(err))
        return "rollback_failed"
    end

    s.startup_attempts=attempts+1
    s.startup_confirmed=false
    s.startup_started_at=os.time()
    self.store:save_update_state(s)
    logger.info("[MiuRead][Updater] trial startup armed",
        "version=",running,"attempt=",tostring(s.startup_attempts))
    rawset(_G,BOOT_SESSION_KEY,{expected=expected,running=running,state="trial"})
    return "trial"
end

-- Confirmation is deliberately separate from begin_startup(). main.lua calls
-- this only after KOReader has returned to its event loop, so a plugin that
-- hangs during init never loses its rollback copy.
function Updater:confirm_startup()
    local s=self.store:update_state()
    if not s.pending or tostring(s.expected or "")~=tostring(self.version or "") then return nil end
    s.startup_confirmed=true
    s.startup_confirmed_at=os.time()
    self.store:save_update_state(s)
    if s.backup then U.remove_tree(s.backup) end
    if s.package then self:_remove_download(s.package) end
    self.store:save_update_state({})
    self:_cleanup_update_artifacts()
    logger.info("[MiuRead][Updater] update confirmed after responsive startup",
        "version=",tostring(self.version))
    rawset(_G,BOOT_SESSION_KEY,{expected=tostring(s.expected or ""),running=tostring(self.version or ""),state="updated"})
    return "updated"
end

function Updater:cleanup_idle()
    local s=self.store:update_state()
    if s.pending then return false end
    self:_cleanup_update_artifacts()
    return true
end

-- Compatibility entry point for callers outside main.lua. It no longer
-- confirms an update synchronously during Plugin:init().
function Updater:startup()
    return self:begin_startup()
end

return Updater
