-- The Z-Library service is used directly with its own account.
-- Request shapes cross-checked against the AGPL ZlibraryKO client,
-- e3c07c1014e2a50b0cfae757c476c16cb38efec1.
local U=require("miuread.util")
local M={}
local PAGE_SIZE=20
local LIMIT=120*1024*1024
local formats={epub=true,pdf=true,mobi=true,azw=true,azw3=true,fb2=true,djvu=true,txt=true,cbz=true}

function M.origin(value)
    local host=tostring(value or ""):lower():match("^https://([a-z0-9][a-z0-9.%-]+)/?$")
    if host and not host:find("..",1,true) and not host:match("[.%-]$")
        and host:find(".",1,true) then return "https://"..host end
end

function M.directory()
    return require("datastorage"):getDataDir().."/books/Z-Library"
end

local function credentials(session)
    local id=tostring(session and session.id or "")
    local key=tostring(session and session.key or "")
    if not id:match("^%d+$") or not key:match("^[%w_.%-]+$") then return nil end
    return "remix_userid="..id.."; remix_userkey="..key
end

local function request(http,base,path,fields,session)
    local origin=M.origin(base)
    if not origin then error("请输入 HTTPS 的 Z-Library 服务地址",0) end
    local headers={Accept="application/json",["X-Requested-With"]="XMLHttpRequest",
        Origin=origin,Referer=origin.."/"}
    headers.Cookie=credentials(session)
    if fields then headers["Content-Type"]="application/x-www-form-urlencoded; charset=UTF-8" end
    local body,status=http:request{url=origin..path,method=fields and "POST" or "GET",
        body=fields and require("miuread.protocol").query(fields) or nil,headers=headers,auth=false,require_verified_tls=true,redirects=0,retries=0,
        rate_limit_scope="miuread-zlibrary",rate_limit_fail_fast=true,timeout={8,20},
        max_response_bytes=2*1024*1024}
    if status~=200 then error("Z-Library 请求失败（HTTP "..tostring(status or "连接中断").."）",0) end
    local ok,value=pcall(require("miuread.json").decode,body or "")
    if not ok or type(value)~="table" then error("Z-Library 返回了无法读取的响应",0) end
    return value
end

function M.login(http,base,email,password)
    local origin=M.origin(base)
    if not origin or U.trim(email)=="" or password=="" then error("请输入服务地址、邮箱和密码",0) end
    local value=request(http,origin,"/rpc.php",{isModal="true",email=email,password=password,
        site_mode="books",action="login",gg_json_mode=1,redirectUrl=origin.."/"})
    local account=value.response or value.user
    if type(account)~="table" then error("Z-Library 登录失败，请核对地址和账号",0) end
    local session={origin=origin,id=account.id or account.user_id,key=account.remix_userkey or account.user_key}
    if not credentials(session) then error("Z-Library 未返回有效的登录会话",0) end
    return session
end

function M.search(http,session,query,page)
    local value=request(http,session.origin,"/eapi/book/search",
        {message=query,page=page,limit=PAGE_SIZE},session)
    if tonumber(value.success)~=1 then error("Z-Library 搜索失败",0) end
    local raw=value.books or (type(value.exactMatch)=="table" and value.exactMatch.books) or {}
    if type(raw)~="table" then error("Z-Library 书目响应不完整",0) end
    local books={}
    for _,row in ipairs(raw) do
        if type(row)=="table" then
            local id=tostring(row.id or "")
            local hash=tostring(row.hash or "")
            if id:match("^%d+$") and hash:match("^[%w%-]+$") and type(row.title)=="string" then
                books[#books+1]={id=id,hash=hash,title=row.title,author=tostring(row.author or ""),
                    extension=tostring(row.extension or ""):lower()}
            end
        end
    end
    local total=tonumber((type(value.pagination)=="table" and value.pagination.total_items) or value.exactBooksCount)
    return {books=books,more=total and page*PAGE_SIZE<total or not total and #raw>=PAGE_SIZE}
end

local function location(value,origin)
    if type(value)~="string" or value:find("[%z\1-\32\127]") then return nil end
    if value:sub(1,2)=="//" then value="https:"..value
    elseif value:sub(1,1)=="/" then value=origin..value end
    local target=value:match("^(https://[a-zA-Z0-9.%-]+)[/?#]")
    if target and M.origin(target) and not value:find("\\",1,true) then return value,M.origin(target) end
end

local function readable(path,extension)
    local handle=io.open(path,"rb")
    if not handle then return false end
    local head=handle:read(512) or ""
    handle:close()
    if head=="" or head:match("^%s*[<{]%s*[!hH]") then return false end
    if extension=="pdf" then return head:sub(1,5)=="%PDF-" end
    if extension=="epub" or extension=="cbz" then return head:sub(1,4)=="PK\003\004" end
    if extension=="mobi" or extension=="azw" or extension=="azw3" then return head:sub(61,68)=="BOOKMOBI" end
    if extension=="djvu" then return head:sub(1,8)=="AT&TFORM" end
    if extension=="fb2" then return head:find("<FictionBook",1,true)~=nil end
    return extension=="txt" and not head:find("\000",1,true)
end

function M.download(http,session,book)
    if not credentials(session) then error("请先登录 Z-Library",0) end
    if not tostring(book.id or ""):match("^%d+$") or not tostring(book.hash or ""):match("^[%w%-]+$") then
        error("书籍信息不完整",0)
    end
    local response=request(http,session.origin,"/eapi/book/"..book.id.."/"..book.hash.."/file",nil,session)
    local file=response.file
    if tonumber(response.success)~=1 or type(file)~="table" or file.allowDownload==false then
        error("Z-Library 暂未提供此书的下载，请检查账号权限或额度",0)
    end
    local extension=tostring(file.extension or book.extension or ""):lower()
    if not formats[extension] then error("当前书籍格式暂不支持直接下载",0) end
    local url,origin=location(file.downloadLink,session.origin)
    if not url then error("Z-Library 没有返回有效的 HTTPS 下载地址",0) end
    local dir=M.directory()
    if not U.mkdir(dir) then error("无法建立 Z-Library 下载目录",0) end
    local path=dir.."/"..U.safe_name(U.utf8_truncate(book.title,45,""),"book").." ["..book.id.."]."..extension
    if U.file_exists(path) then
        if readable(path,extension) then return path end
        error("同名文件已存在，请先处理本机副本",0)
    end
    local staged=path.."."..tostring(math.random(100000,999999))..".part"
    local ok,err=pcall(function()
        for _=1,4 do
            local headers={Accept="*/*"}
            -- A download host never receives the account cookie of another host.
            if origin==session.origin then headers.Cookie=credentials(session) end
            os.remove(staged)
            local _,status,response_headers=http:request{url=url,method="GET",headers=headers,
                sink_path=staged,auth=false,require_verified_tls=true,redirects=0,retries=0,timeout={8,45},
                rate_limit_scope="miuread-zlibrary",max_response_bytes=LIMIT}
            response_headers=response_headers or {}
            if status==200 then
                local declared=tonumber(response_headers["content-length"] or response_headers["Content-Length"])
                local size=U.file_size(staged) or 0
                if size<=0 or (declared and declared~=size) or not readable(staged,extension) then
                    error("下载文件不完整或格式不符",0)
                end
                if U.file_exists(path) or not os.rename(staged,path) then error("无法保存下载的书",0) end
                return
            end
            if status~=301 and status~=302 and status~=303 and status~=307 and status~=308 then
                error("Z-Library 下载失败（HTTP "..tostring(status or "连接中断").."）",0)
            end
            url,origin=location(response_headers.location or response_headers.Location,origin)
            if not url then error("Z-Library 返回了无效的下载跳转",0) end
        end
        error("Z-Library 下载跳转次数过多",0)
    end)
    os.remove(staged)
    if not ok then error(err,0) end
    return path
end

return M
