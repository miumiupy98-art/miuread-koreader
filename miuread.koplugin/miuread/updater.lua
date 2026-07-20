local Config=require("miuread.config")
local Digests=require("miuread.digests")
local U=require("miuread.util")
local logger=require("logger")
local Updater={}; Updater.__index=Updater

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

function Updater:manifest_urls()
    local out,seen={},{}
    local configured=Config.UPDATE_MANIFESTS
    if type(configured)=="table" then
        for _,url in ipairs(configured) do with_github_mirrors(url,out,seen) end
    else
        with_github_mirrors(Config.UPDATE_MANIFEST,out,seen)
    end
    return out
end

function Updater:manifest_url()
    return self:manifest_urls()[1]
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

local function validate_manifest(m)
    if type(m)~="table" or type(m.version)~="string" or m.version=="" then
        return nil,"更新清单缺少版本号"
    end
    if m.package_type~=nil and tostring(m.package_type)~="full" then
        return nil,"更新清单不是全量包"
    end
    if #package_urls(m)==0 then return nil,"更新清单缺少安装包地址" end
    local expected=tostring(m.sha256 or ""):lower():gsub("%s+","")
    if expected=="" then return nil,"更新清单缺少 SHA-256" end
    return true
end

function Updater:check()
    local urls=self:manifest_urls()
    if #urls==0 then return nil,"更新地址未配置" end
    local errors={}
    for _,url in ipairs(urls) do
        local ok,m=pcall(function()
            return self.http:get_json(url,{auth=false,retries=1,redirects=8,timeout={15,45}})
        end)
        if ok then
            local valid,reason=validate_manifest(m)
            if valid then
                logger.info("[MiuRead][Updater] manifest loaded",url,"version=",tostring(m.version))
                if not U.semver_newer(m.version,self.version) then
                    return {current=true,version=m.version,name=m.name,notes=m.notes}
                end
                return m
            end
            errors[#errors+1]=reason
        else
            errors[#errors+1]=tostring(m)
            logger.warn("[MiuRead][Updater] manifest failed",url,tostring(m))
        end
    end
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
    local stamp=tostring(os.time()).."-"..tostring(math.random(1000,9999))
    local stage=self.store.updates_dir.."/stage-"..stamp
    local unpacked=stage.."/unpacked"
    local backup=self.store.updates_dir.."/backup-"..stamp
    U.remove_tree(stage); U.remove_tree(backup); U.mkdir(unpacked)

    -- 全量包必须只包含一个 miuread.koplugin 根目录。
    local rc=os.execute("unzip -q "..U.shell_quote(path).." -d "..U.shell_quote(unpacked).." 2>/dev/null")
    if not command_ok(rc) then U.remove_tree(stage); return nil,"解压更新包失败" end

    local incoming=unpacked.."/miuread.koplugin"
    if not U.file_exists(incoming.."/main.lua") or not U.file_exists(incoming.."/_meta.lua") then
        U.remove_tree(stage); return nil,"更新包缺少 miuread.koplugin 或插件文件不完整"
    end
    local roots=U.list(unpacked)
    if #roots~=1 or roots[1]~=incoming then
        U.remove_tree(stage); return nil,"更新包根目录必须只包含 miuread.koplugin"
    end

    local ok,e=U.copy_tree(self.plugin_root,backup)
    if not ok then U.remove_tree(stage); return nil,"备份当前插件失败："..tostring(e) end

    local function rollback(message)
        U.remove_tree(self.plugin_root)
        local restored,re=U.copy_tree(backup,self.plugin_root)
        U.remove_tree(stage)
        if not restored then return nil,tostring(message).."；回滚也失败："..tostring(re) end
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
    self.store:save_update_state({pending=true,expected=manifest.version,backup=backup,installed_at=os.time()})
    logger.info("[MiuRead][Updater] update installed","version=",tostring(manifest.version),"backup=",tostring(backup))
    return true
end

function Updater:startup()
    local s=self.store:update_state()
    if not s.pending then return nil end
    if tostring(s.expected)==tostring(self.version) then
        if s.backup then U.remove_tree(s.backup) end
        self.store:save_update_state({})
        return "updated"
    end
    return "mismatch"
end

return Updater
