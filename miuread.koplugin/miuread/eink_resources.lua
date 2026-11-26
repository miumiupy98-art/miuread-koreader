-- Independent E-Ink image archives are separate from chapter response ZIPs.
local Http=require("miuread.http")
local Util=require("miuread.util")
local Codec=require("miuread.codec")
local M={}

local RESOURCE_URL_LIMIT=8192
local ARCHIVE_LIMIT=8*1024*1024
local EXPANDED_LIMIT=16*1024*1024
local ENTRY_LIMIT=256
local ORIGIN="https://i.weread.qq.com"

local function normalize_url(value,current)
    if type(value)~="string" or value=="" or #value>RESOURCE_URL_LIMIT
        or value:find('[%c%s\\"]') then return end
    value=value:match("^[^#]*")
    if value=="" then return end
    if value:sub(1,2)=="//" then
        value="https:"..value
    elseif value:sub(1,1)=="/" then
        value=(current and current:match("^https://[^/]+") or ORIGIN)..value
    elseif current and not value:match("^[%w+.-]+:") then
        local base=current:match("^[^?]+")
        if value:sub(1,1)~="?" then base=base:match("^https://[^/]+/.*/") or base:match("^https://[^/]+").."/" end
        value=base..value
    end
    if #value>RESOURCE_URL_LIMIT then return end
    local scheme,host,port,path=value:match("^(https?)://([%w.%-]+):?(%d*)(/.*)$")
    if not host or host:find("..",1,true) or value:match("^https?://[^/]+:/") then return end
    if port~="" and port~=(scheme=="http" and "80" or "443") then return end
    host=host:lower()
    local official=host=="i.weread.qq.com" or host=="res.weread.qq.com"
    if not (official or host=="rescdn.qqmail.com" or host:match("%.qq%.com$")
        or host:match("%.myqcloud%.com$") or host:match("%.qcloud%.com$")
        or host:match("%.qpic%.cn$") or host:match("%.qlogo%.cn$")) then return end
    return "https://"..host..path,official
end

-- Official wrepub image URLs are keys within the current book's archives.
function M.archive_image_name(value)
    local lower=value:lower()
    local prefix=lower:match("^https?://res%.weread%.qq%.com/wrepub/")
        or lower:match("^//res%.weread%.qq%.com/wrepub/")
    if not prefix then return nil,false end
    local name=value:sub(#prefix+1):match("^[^?#]*")
    if name:gsub("%%[%x][%x]",""):find("%",1,true) then return nil,true end
    name=name:gsub("%%(%x%x)",function(hex) return string.char(tonumber(hex,16)) end)
    if name=="" or #name>255 or name=="." or name==".." or name:find("[%c/\\]") then
        return nil,true
    end
    return name,true
end

function M.asset_name(value,literal)
    local name=tostring(value or ""):gsub("\\", "/"):match("^[^?#]*")
    name=name:match("([^/]+)$")
    if not name then return end
    if not literal then name=name:gsub("%%(%x%x)",function(hex) return string.char(tonumber(hex,16)) end) end
    if #name<=255 and name~="." and name~=".." and not name:find("[%c/\\]") then return name end
end

local function index_name(index,name,value)
    if not name then return end
    if index[name]==nil then index[name]=value
    elseif index[name]~=value then index[name]=false end
end

function M.index_asset(index,source,value)
    index_name(index,M.asset_name(source,true),value)
    index_name(index,M.asset_name(source),value)
end

local function header(headers,name)
    for key,value in pairs(headers or {}) do
        if tostring(key):lower()==name then return value end
    end
end

function M.image_url(value)
    local url=normalize_url(value)
    if url and not url:match("^https://weread%.qq%.com/")
        and not url:match("^https://[^/]+/web/") then return url end
end

function M.download(client,source,path,opt)
    local url,official=normalize_url(source)
    for _=1,6 do
        if not url then error("E-Ink 插图归档地址无效",0) end
        local function request(credentials)
            local remaining=opt.image_deadline and opt.image_deadline-os.time()
            if remaining and remaining<=0 then error("在线插图等待超时",0) end
            local options=credentials and client:options(credentials,{5,22})
                or {auth=false,timeout={5,22},retries=0,rate_limit_retries=0,rate_limit_fail_fast=true}
            options.url=url
            options.sink_path=path
            options.redirects=0
            options.max_response_bytes=ARCHIVE_LIMIT
            if remaining then
                options.retries=0
                options.rate_limit_retries=0
                options.timeout={math.min(3,remaining),math.min(6,remaining)}
            end
            options.on_chunk=function(bytes)
                if opt.image_deadline and os.time()>=opt.image_deadline then error("在线插图等待超时",0) end
                if opt.yield then opt.yield("images") end
                if opt.activity then opt.activity("image_archive_download",{bytes=bytes}) end
            end
            local _,status,headers=client.http:request(options)
            if credentials and status==401 then error(Http.auth_error_message(401),0) end
            return status,headers
        end
        local status,headers
        if official and not opt.anonymous then
            status,headers=client:authorized(request,"images")
        else
            status,headers=request()
        end
        if status==200 then
            local size=Util.file_size(path)
            local length=tonumber(header(headers,"content-length"))
            if not size or size<1 or size>ARCHIVE_LIMIT or (length and length~=size) then
                error("E-Ink 插图归档下载不完整",0)
            end
            return path
        end
        if status~=301 and status~=302 and status~=303 and status~=307 and status~=308 then
            error("E-Ink 插图归档下载失败 HTTP "..tostring(status),0)
        end
        local next_url,next_official=normalize_url(header(headers,"location"),url)
        if not next_url or next_url==url then error("E-Ink 插图归档重定向无效",0) end
        url,official=next_url,next_official
    end
    error("E-Ink 插图归档重定向次数超限",0)
end

function M.read(path,root,opt)
    local archive=require("ffi/archiver").Reader:new()
    local ok,result=pcall(function()
        if not archive:open(path) then error("E-Ink 插图归档无法打开",0) end
        local assets,seen,total={},{},0
        for entry in archive:iterate(true) do
            if opt.image_deadline and os.time()>=opt.image_deadline then error("在线插图等待超时",0) end
            if entry.index>ENTRY_LIMIT then error("E-Ink 插图归档条目超限",0) end
            if entry.mode=="file" then
                local size=tonumber(entry.size)
                local name=entry.path
                if not size or size<0 or size>ARCHIVE_LIMIT or size>EXPANDED_LIMIT-total
                    or type(name)~="string" or #name>RESOURCE_URL_LIMIT or seen[name] then
                    error("E-Ink 插图归档条目无效",0)
                end
                seen[name]=true
                total=total+size
                if size>0 and (not opt.image_names or opt.image_names[M.asset_name(name,true)]
                    or opt.image_names[M.asset_name(name)]) then
                    if opt.yield then opt.yield("images") end
                    local data=archive:extractToMemory(entry.index)
                    if type(data)~="string" or #data~=size then error("E-Ink 插图归档内容不完整",0) end
                    -- Archive names are lookup keys only. Generated paths stay in root.
                    local target=root.."/eink-resource-"..entry.index..".bin"
                    local file=assert(io.open(target,"wb"))
                    local wrote=file:write(data)
                    local closed=file:close()
                    if not wrote or not closed then error("无法保存 E-Ink 章内插图",0) end
                    local ext,mime=Codec.media_file(target,name)
                    if tostring(mime):match("^image/") then
                        assets[#assets+1]={href="images/eink-resource-"..entry.index..ext,
                            data_path=target,mime=mime,source=name,_temporary_root=root}
                    else
                        os.remove(target)
                    end
                end
            elseif entry.mode~="directory" then
                error("E-Ink 插图归档含有非普通文件",0)
            end
        end
        if archive.err then error("E-Ink 插图归档读取失败",0) end
        return assets
    end)
    archive:close()
    if not ok then error(result,0) end
    return result
end

return M
