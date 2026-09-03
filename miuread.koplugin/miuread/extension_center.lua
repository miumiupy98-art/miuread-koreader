local DataStorage=require("datastorage")
local lfs=require("libs/libkoreader-lfs")
local ffiUtil=require("ffi/util")
local UIManager=require("ui/uimanager")
local InputDialog=require("ui/widget/inputdialog")
local ConfirmBox=require("ui/widget/confirmbox")
local Menu=require("ui/widget/menu")
local Config=require("miuread.config")
local U=require("miuread.util")
local logger=require("logger")

local M={}

local RECORD_KEY="extension_center_installed"
local SEARCH_CACHE_KEY="extension_center_search_cache"
local MAX_RESULTS=24
local MAX_ARCHIVE_ENTRIES=6000
local MAX_PLUGIN_FILES=5000
local MAX_PLUGIN_BYTES=96*1024*1024

local FEATURED={
    {repo="hesan1232/fanqie.koplugin",name="番茄小说",description="在 KOReader 中浏览、阅读和管理番茄小说。"},
    {repo="ZlibraryKO/zlibrary.koplugin",name="Z-Library",description="在 KOReader 中搜索和下载 Z-Library 书籍。"},
    {repo="doctorhetfield-cmd/simpleui.koplugin",name="SimpleUI",description="为 KOReader 提供更简洁的主页与导航界面。"},
    {repo="AnthonyGress/zen_ui.koplugin",name="Zen UI",description="KOReader 的极简界面扩展。"},
    {repo="omer-faruq/appstore.koplugin",name="App Store",description="KOReader 社区插件市场，可作为觅阅扩展中心的兼容参考。"},
}

local CATEGORIES={
    {name="界面与主题",query="ui topic:koreader-plugin"},
    {name="阅读工具",query="reader topic:koreader-plugin"},
    {name="翻译与词典",query="translate topic:koreader-plugin"},
    {name="同步与网络",query="sync topic:koreader-plugin"},
    {name="游戏与其他",query="game topic:koreader-plugin"},
}

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

local function scan_installed()
    local out,seen={},{}
    for _,root in ipairs(plugin_lookup_paths()) do
        local ok,iter,state=pcall(lfs.dir,root)
        if ok and type(iter)=="function" then
            for entry in iter,state do
                if entry~="." and entry~=".." and entry:match("%.koplugin$") then
                    local path=root.."/"..entry
                    local real=type(ffiUtil.realpath)=="function" and ffiUtil.realpath(path) or nil
                    local key=real or path
                    if not seen[key]
                        and lfs.attributes(path,"mode")=="directory"
                        and U.file_exists(path.."/main.lua")
                        and U.file_exists(path.."/_meta.lua") then
                        seen[key]=true
                        local meta=read_meta(path)
                        out[#out+1]={
                            dir=entry,path=path,root=root,
                            name=meta.fullname~="" and meta.fullname or entry,
                            version=meta.version,
                            protected=entry=="miuread.koplugin",
                        }
                    end
                end
            end
        end
    end
    table.sort(out,function(a,b) return tostring(a.name):lower()<tostring(b.name):lower() end)
    return out
end

local function find_installed_by_dir(dir)
    if not dir or dir=="" then return nil end
    for _,item in ipairs(scan_installed()) do
        if item.dir==dir then return item end
    end
end

local function records(plugin)
    local value=plugin.store:get(RECORD_KEY,{})
    return type(value)=="table" and value or {}
end

local function save_records(plugin,value)
    return plugin.store:set(RECORD_KEY,type(value)=="table" and value or {})
end

local function remember_install(plugin,repo,dir,version,source_url)
    local value=records(plugin)
    value[dir]={
        repo=repo,dir=dir,version=tostring(version or ""),
        source_url=tostring(source_url or ""),installed_at=os.time(),
    }
    save_records(plugin,value)
end

local function forget_install(plugin,dir)
    local value=records(plugin)
    value[dir]=nil
    save_records(plugin,value)
end

local function repo_for_installed(plugin,dir)
    local value=records(plugin)[dir]
    return type(value)=="table" and value.repo or nil
end

local function github_json(plugin,url)
    local ok,result=pcall(function()
        return plugin.http:get_json(url,{
            auth=false,retries=1,redirects=6,
            timeout={6,18},
        })
    end)
    if not ok then return nil,tostring(result) end
    if type(result)~="table" then return nil,"GitHub 返回了无法识别的数据" end
    return result
end

local function github_repo(plugin,repo)
    if not valid_repo(repo) then return nil,"仓库地址无效" end
    return github_json(plugin,"https://api.github.com/repos/"..repo)
end

local function latest_release(plugin,repo)
    if not valid_repo(repo) then return nil,"仓库地址无效" end
    local release,err=github_json(plugin,"https://api.github.com/repos/"..repo.."/releases/latest")
    if release then return release end
    logger.warn("[MiuRead][Extensions] latest release unavailable",repo,tostring(err))
    return nil,err
end

local function release_source(repo,repo_info,release)
    if type(release)=="table" then
        local assets=type(release.assets)=="table" and release.assets or {}
        local best
        for _,asset in ipairs(assets) do
            local name=tostring(asset.name or ""):lower()
            local url=tostring(asset.browser_download_url or "")
            if name:match("%.zip$") and starts_with(url,"https://") then
                if not best then best=asset end
                if name:find("koplugin",1,true) then best=asset; break end
            end
        end
        if best then
            return {
                url=best.browser_download_url,
                version=tostring(release.tag_name or release.name or ""),
                source="release",
            }
        end
        local tag=tostring(release.tag_name or "")
        if tag~="" then
            return {
                url="https://github.com/"..repo.."/archive/refs/tags/"..url_encode(tag)..".zip",
                version=tag,source="release-source",
            }
        end
    end
    local branch=tostring(type(repo_info)=="table" and repo_info.default_branch or "main")
    if branch=="" then branch="main" end
    return {
        url="https://github.com/"..repo.."/archive/refs/heads/"..url_encode(branch)..".zip",
        version="",source="branch-source",
    }
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

local function download_package(plugin,url,label)
    local target=plugin.store.temp_dir.."/extension-"..U.id_name(label or os.time()).."-"..tostring(math.random(1000,9999))..".zip"
    local errors={}
    for _,candidate in ipairs(github_package_urls(url)) do
        os.remove(target)
        local ok,result=pcall(function()
            return plugin.http:download_to_file(candidate,target,{
                auth=false,retries=1,redirects=10,timeout={15,150},integrity_attempts=2,
            })
        end)
        if ok and U.file_exists(target) and (U.file_size(target) or 0)>0 then
            return target,candidate
        end
        errors[#errors+1]=tostring(result)
        logger.warn("[MiuRead][Extensions] package route failed",candidate,tostring(result))
    end
    os.remove(target)
    return nil,errors[#errors] or "下载失败"
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

local function normalized_plugin_identity(value)
    return tostring(value or ""):lower():gsub("[^%w]","")
end

local function install_archive(plugin,repo,zip_path,source_url,version_hint)
    local entries,entry_error=zip_entries(zip_path)
    if not entries then os.remove(zip_path); return nil,entry_error end
    local declared_size=zip_declared_size(zip_path)
    if declared_size and declared_size>MAX_PLUGIN_BYTES then
        os.remove(zip_path)
        return nil,"插件解压体积超过安全上限"
    end

    local stamp=tostring(os.time()).."-"..tostring(math.random(1000,9999))
    local stage=plugin.store.temp_dir.."/extension-stage-"..stamp
    local unpacked=stage.."/unpacked"
    U.remove_tree(stage)
    U.mkdir(unpacked)
    local function fail(message)
        U.remove_tree(stage)
        os.remove(zip_path)
        return nil,message
    end

    local rc=os.execute("unzip -q "..U.shell_quote(zip_path).." -d "..U.shell_quote(unpacked).." 2>/dev/null")
    if not command_ok(rc) then return fail("解压插件失败") end
    local stats,stats_error=tree_stats(unpacked)
    if not stats then return fail(stats_error) end

    local incoming,target_name=choose_plugin_root(unpacked,repo)
    if not incoming then return fail(target_name) end
    if target_name=="miuread.koplugin" then return fail("扩展中心不能覆盖觅阅自身") end

    local existing=find_installed_by_dir(target_name)
    local target_root=existing and existing.root or default_plugin_root()
    local target=target_root.."/"..target_name
    local backup=stage.."/backup"

    if lfs.attributes(target,"mode")=="directory" then
        if not U.file_exists(target.."/main.lua") or not U.file_exists(target.."/_meta.lua") then
            return fail("目标目录已存在，但不是完整 KOReader 插件；为避免覆盖其他文件，已停止安装")
        end
        local installed_record=records(plugin)[target_name]
        local installed_repo=type(installed_record)=="table" and tostring(installed_record.repo or "") or ""
        if installed_repo~="" and installed_repo~=repo then
            return fail("目标目录已由另一个 GitHub 仓库管理，已拒绝覆盖")
        end
        if installed_repo=="" then
            local incoming_meta=read_meta(incoming)
            local current_meta=read_meta(target)
            local incoming_id=normalized_plugin_identity(incoming_meta.identity)
            local current_id=normalized_plugin_identity(current_meta.identity)
            if incoming_id~="" and current_id~="" and incoming_id~=current_id then
                return fail("目标目录中已存在名称不同的插件，已拒绝覆盖")
            end
        end
        local copied,copy_error=U.copy_tree(target,backup)
        if not copied then return fail("备份旧插件失败："..tostring(copy_error)) end
    end

    local function rollback(message)
        U.remove_tree(target)
        if lfs.attributes(backup,"mode")=="directory" then
            local restored,restore_error=U.copy_tree(backup,target)
            if not restored then
                U.remove_tree(stage)
                os.remove(zip_path)
                return nil,tostring(message).."；旧版本恢复失败："..tostring(restore_error)
            end
        end
        U.remove_tree(stage)
        os.remove(zip_path)
        return nil,tostring(message).."；已恢复旧版本"
    end

    if lfs.attributes(target,"mode")=="directory" then
        local removed,remove_error=U.remove_tree(target)
        if not removed then return fail("无法替换旧插件："..tostring(remove_error)) end
    end
    local copied,copy_error=U.copy_tree(incoming,target)
    if not copied then return rollback("安装插件失败："..tostring(copy_error)) end
    if not U.file_exists(target.."/main.lua") or not U.file_exists(target.."/_meta.lua") then
        return rollback("安装后的插件结构不完整")
    end
    local installed_stats,installed_stats_error=tree_stats(target)
    if not installed_stats then return rollback(installed_stats_error) end

    local meta=read_meta(target)
    remember_install(plugin,repo,target_name,meta.version~="" and meta.version or version_hint,source_url)
    U.remove_tree(stage)
    os.remove(zip_path)
    logger.info("[MiuRead][Extensions] installed",repo,target_name,
        "files=",tostring(stats.files),"bytes=",tostring(stats.bytes),"version=",tostring(meta.version))
    return {
        dir=target_name,path=target,version=meta.version,
        files=installed_stats.files,bytes=installed_stats.bytes,
        updated=existing~=nil,
    }
end

local function display_repo_name(repo_info,fallback)
    if type(fallback)=="table" and trim(fallback.name)~="" then return fallback.name end
    return trim(type(repo_info)=="table" and repo_info.name or "")
end

local function normalized_version(value)
    value=trim(value):gsub("^[vV]","")
    return value
end

local function version_is_newer(remote,local_version)
    remote=normalized_version(remote)
    local_version=normalized_version(local_version)
    if remote=="" or local_version=="" then return false end
    local ok,result=pcall(U.semver_newer,remote,local_version)
    return ok and result==true
end

local function show_menu(title,items)
    UIManager:show(Menu:new{title=title,item_table=items,items_per_page=8})
end

local function install_repo(plugin,repo,repo_info,release)
    repo_info=repo_info or github_repo(plugin,repo)
    if not repo_info then plugin:info("无法读取 GitHub 仓库信息。") return end
    if repo_info.archived==true then plugin:info("这个仓库已经归档，觅阅不会自动安装。") return end
    local source=release_source(repo,repo_info,release)
    local zip_path,used_url=download_package(plugin,source.url,repo.."-"..source.version)
    if not zip_path then
        plugin:info("扩展下载失败。\n\n"..tostring(used_url or "请检查网络后重试"))
        return
    end
    local result,err=install_archive(plugin,repo,zip_path,used_url,source.version)
    if not result then
        plugin:info("扩展安装失败。\n\n"..tostring(err or "未知错误"))
        return
    end
    local action=result.updated and "更新完成" or "安装完成"
    local version=result.version~="" and ("\n版本："..result.version) or ""
    plugin:info(action.."："..result.dir..version.."\n\n请完整重启 KOReader 后使用。")
end

local function uninstall(plugin,item)
    if not item or item.protected or item.dir=="miuread.koplugin" then
        plugin:info("觅阅自身不能从扩展中心卸载。")
        return
    end
    UIManager:show(ConfirmBox:new{
        text="卸载“"..tostring(item.name or item.dir).."”？\n\n只删除插件目录，不删除该插件可能保存在 KOReader settings 中的个人设置。",
        ok_text="卸载",cancel_text="取消",
        ok_callback=function()
            local removed,err=U.remove_tree(item.path)
            if not removed then plugin:info("卸载失败：\n"..tostring(err or "无法删除插件目录")); return end
            forget_install(plugin,item.dir)
            plugin:info("已卸载 "..item.dir.."。\n\n请完整重启 KOReader。")
        end,
    })
end

local function repo_detail(plugin,repo,fallback)
    if not valid_repo(repo) then plugin:info("GitHub 仓库地址无效") return end
    local info,repo_error=github_repo(plugin,repo)
    if not info then
        plugin:info("无法读取 GitHub 仓库。\n\n"..tostring(repo_error or "网络错误"))
        return
    end
    local release=latest_release(plugin,repo)
    local repo_name=info.name or repo:match("/([^/]+)$") or repo
    local expected_dir=repo_name:match("%.koplugin$") and repo_name or nil
    local installed=expected_dir and find_installed_by_dir(expected_dir) or nil
    if not installed then
        for _,item in ipairs(scan_installed()) do
            if repo_for_installed(plugin,item.dir)==repo then installed=item; break end
        end
    end
    local remote_version=type(release)=="table" and tostring(release.tag_name or release.name or "") or ""
    local description=trim((type(fallback)=="table" and fallback.description) or info.description or "")
    if description=="" then description="暂无简介" end
    local rows={
        {text=repo,enabled=false},
        {text=description,enabled=false},
        {text="GitHub",post_text=tostring(info.stargazers_count or 0).." ★",enabled=false},
    }
    if remote_version~="" then rows[#rows+1]={text="最新版本",post_text=remote_version,enabled=false} end
    if installed then
        rows[#rows+1]={text="已安装",post_text=installed.version~="" and installed.version or installed.dir,enabled=false}
        local newer=remote_version~="" and version_is_newer(remote_version,installed.version)
        rows[#rows+1]={text=newer and "更新扩展" or "重新安装 / 检查更新",post_text=newer and remote_version or "",callback=function()
            UIManager:show(ConfirmBox:new{
                text=(newer and "更新" or "重新安装").." “"..tostring(installed.name).."”？\n\n安装前会备份当前插件，写入失败会自动恢复。",
                ok_text=newer and "更新" or "安装",cancel_text="取消",
                ok_callback=function() install_repo(plugin,repo,info,release) end,
            })
        end}
        rows[#rows+1]={text="卸载扩展",callback=function() uninstall(plugin,installed) end}
    else
        rows[#rows+1]={text="安装扩展",callback=function()
            UIManager:show(ConfirmBox:new{
                text="安装 “"..display_repo_name(info,fallback).."”？\n\n来源："..repo.."\n安装完成后需要重启 KOReader。",
                ok_text="安装",cancel_text="取消",
                ok_callback=function() install_repo(plugin,repo,info,release) end,
            })
        end}
    end
    show_menu("觅阅扩展中心 · "..display_repo_name(info,fallback),rows)
end

local function repo_item(plugin,repo,fallback)
    local name=type(fallback)=="table" and fallback.name or nil
    if not name or name=="" then name=repo:match("/([^/]+)$") or repo end
    return {
        text=name,
        post_text=repo,
        callback=function() repo_detail(plugin,repo,fallback) end,
    }
end

local function github_search(plugin,query,title)
    query=trim(query)
    if query=="" then query="topic:koreader-plugin" end
    local url="https://api.github.com/search/repositories?q="..url_encode(query)
        .."&sort=stars&order=desc&per_page="..tostring(MAX_RESULTS)
    local data,err=github_json(plugin,url)
    if not data then
        plugin:info("无法读取 GitHub 社区扩展。\n\n"..tostring(err or "网络错误"))
        return
    end
    local items={}
    for _,repo in ipairs(type(data.items)=="table" and data.items or {}) do
        local full=tostring(repo.full_name or "")
        if valid_repo(full) and full~="miumiupy98-art/miuread-koreader" then
            items[#items+1]={
                text=tostring(repo.name or full),
                post_text=tostring(repo.stargazers_count or 0).." ★",
                callback=function()
                    repo_detail(plugin,full,{name=repo.name,description=repo.description})
                end,
            }
        end
    end
    if #items==0 then plugin:info("没有找到相关 KOReader 扩展。") return end
    plugin.store:set_deferred(SEARCH_CACHE_KEY,{query=query,updated_at=os.time()})
    plugin.store:flush()
    show_menu(title or "GitHub 社区",items)
end

local function show_search_dialog(plugin)
    local dialog
    dialog=InputDialog:new{
        title="搜索 GitHub 扩展",
        description="输入插件名或关键词。搜索范围优先限定为 KOReader 社区插件。",
        input="",
        buttons={{
            {text="取消",id="close",callback=function() UIManager:close(dialog) end},
            {text="搜索",is_enter_default=true,callback=function()
                local query=trim(dialog:getInputText())
                UIManager:close(dialog)
                if query=="" then return end
                UIManager:nextTick(function()
                    github_search(plugin,query.." topic:koreader-plugin","搜索 · "..query)
                end)
            end},
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function featured_menu(plugin)
    local rows={}
    for _,item in ipairs(FEATURED) do rows[#rows+1]=repo_item(plugin,item.repo,item) end
    rows[#rows+1]={text="说明",post_text="中文精选",enabled=false}
    return rows
end

local function categories_menu(plugin)
    local rows={}
    for _,category in ipairs(CATEGORIES) do
        local item=category
        rows[#rows+1]={text=item.name,callback=function()
            github_search(plugin,item.query,"分类 · "..item.name)
        end}
    end
    return rows
end

local function installed_menu(plugin)
    local rows={}
    for _,item in ipairs(scan_installed()) do
        local row=item
        local repo=repo_for_installed(plugin,row.dir)
        rows[#rows+1]={
            text=row.name,
            post_text=row.version~="" and row.version or row.dir,
            callback=function()
                if row.protected then
                    plugin:info("这是觅阅自身插件，不由扩展中心管理。")
                elseif repo and valid_repo(repo) then
                    repo_detail(plugin,repo,{name=row.name})
                else
                    show_menu("已安装 · "..row.name,{
                        {text=row.dir,post_text=row.version,enabled=false},
                        {text="来源",post_text="非扩展中心安装",enabled=false},
                        {text="卸载扩展",callback=function() uninstall(plugin,row) end},
                    })
                end
            end,
        }
    end
    if #rows==0 then rows[1]={text="未发现第三方扩展",enabled=false} end
    return rows
end

local function update_menu(plugin)
    local rows={}
    local installed=scan_installed()
    for _,item in ipairs(installed) do
        local row=item
        local repo=repo_for_installed(plugin,row.dir)
        if repo and valid_repo(repo) and not row.protected then
            rows[#rows+1]={
                text=row.name,post_text=row.version,
                callback=function() repo_detail(plugin,repo,{name=row.name}) end,
            }
        end
    end
    if #rows==0 then
        rows[1]={text="暂无可跟踪更新的扩展",post_text="通过扩展中心安装后会自动记录来源",enabled=false}
    end
    return rows
end

local function center_about(plugin)
    plugin:info(
        "觅阅扩展中心 · 5.7.0-beta.1\n\n"
        .."第一版直接使用 GitHub 的 KOReader 社区生态作为扩展来源，并提供中文精选入口。\n\n"
        .."安装包会先下载到临时目录，检查 ZIP 路径、插件结构和体积后才写入 plugins。更新现有插件时会先备份，写入失败自动恢复。\n\n"
        .."普通第三方插件仍由插件自己管理账号和设置。安装、更新或卸载后请完整重启 KOReader。"
    )
end

function M.menu(plugin)
    return {
        {text="中文精选",post_text="推荐",sub_item_table_func=function() return featured_menu(plugin) end},
        {text="分类浏览",sub_item_table_func=function() return categories_menu(plugin) end},
        {text="GitHub 社区",post_text="热门",callback=function() github_search(plugin,"topic:koreader-plugin","GitHub 社区 · 热门") end},
        {text="搜索扩展",callback=function() show_search_dialog(plugin) end},
        {text="已安装",post_text=tostring(#scan_installed()),sub_item_table_func=function() return installed_menu(plugin) end},
        {text="扩展更新",sub_item_table_func=function() return update_menu(plugin) end},
        {text="关于扩展中心",callback=function() center_about(plugin) end},
    }
end

return M
