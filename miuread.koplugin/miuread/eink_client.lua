local Client = require("miuread.shelf_client")
local Http = require("miuread.http")
local Protocol = require("miuread.protocol")
local U = require("miuread.util")
local Json = require("miuread.json")
local bit = require("bit")
local M = {}
M.__index = M
local BASE = "https://i.weread.qq.com"

function M.new(http,store,reader)
    return setmetatable({http=http,store=store,reader=reader,catalogs={},resources={},book_access={},online_grants={},translation_modes={}},M)
end
function M:cache_key(id)
    local auth=self.store:auth()
    return tostring(auth.login_session_id)..":"..tostring((auth.account or {}).vid)..":"..tostring(id)
end
function M:options(credentials,timeout)
    local options=Client.request_options(credentials,timeout)
    options.keepalive=self.keepalive==true
    return options
end
local function raise_request_error(value,stage)
    local limited=Http.rate_limit_details(value)
    if limited then
        -- Keep only safe diagnostics; response bodies, URLs and tokens must not
        -- be copied into the saved route result or its failure dialog.
        error("E-Ink 请求受限 [MiuReadRateLimit]"
            ..(limited.local_cooldown and " [MiuReadLocalCooldown]" or "")
            .." native_stage="..tostring(limited.native_stage or stage or "unknown")
            ..(limited.code and (" error_code="..tostring(limited.code)) or "")
            ..(limited.wait_seconds and (" wait_seconds="..tostring(limited.wait_seconds)) or ""),0)
    end
    error(tostring(value).." native_stage="..tostring(stage or "client_download"),0)
end
function M:authorized(fn,stage,allow_recovery)
    if self.before_request then self.before_request(stage) end
    local credentials = Client.credentials(self.store:auth())
    if not credentials then error("E-Ink 接口需要客户端授权") end
    local ok,a,b,c,d = pcall(fn,credentials)
    if ok then return a,b,c,d end
    if allow_recovery==false or Http.is_rate_limit_error(a) or not Http.is_auth_error(a) then raise_request_error(a,stage) end
    if self.before_request then self.before_request("refresh") end
    local renewed,value=pcall(Client.refresh,self.http,self.store)
    if not renewed then raise_request_error(value,"refresh") end
    if self.before_request then self.before_request(stage) end
    local retried,x,y,z,extra=pcall(fn,value)
    if not retried then raise_request_error(x,stage) end
    return x,y,z,extra
end
function M:request(method,path,parameters,stage,request_options)
    local single=request_options and request_options.single_dispatch
    local session=single and (self.store:auth() or {}).login_session_id
    local value=self:authorized(function(credentials)
        local options=self:options(credentials,{5,20})
        if request_options and request_options.timeout then options.timeout=request_options.timeout end
        if single then
            options.retries,options.rate_limit_retries,options.rate_limit_fail_fast=0,0,true
            options.before_dispatch=function()
                local saved=self.store:read_persisted("auth")
                local current=Client.credentials(saved or {})
                return session~=nil and saved and saved.login_session_id==session and current~=nil
                    and current.vid==credentials.vid and current.accessToken==credentials.accessToken
            end
        end
        if method=="GET" then
            local query=next(parameters or {}) and ("?"..Protocol.query(parameters)) or ""
            return self.http:get_json(BASE..path..query,options)
        end
        return self.http:post_json(BASE..path,parameters,options)
    end,stage,not single and not (request_options and request_options.no_auth_recovery==true))
    if type(value)~="table" then error("E-Ink 客户端响应无效 native_stage="..stage,0) end
    return value
end
function M:underlines(id,uid)
    local value=self:request("GET","/book/underlines",{bookId=tostring(id),chapterUid=tonumber(uid) or uid,synckey=0},"annotations")
    if type(value.underlines)~="table" then error("E-Ink 划线响应不完整",0) end
    return value
end
function M:readreviews(id,uid,batch)
    local value=self:request("POST","/book/readreviews",{bookId=tostring(id),chapterUid=tonumber(uid) or uid,
        cht2sMode="",reviews=batch},"annotations")
    if type(value.reviews)~="table" then error("E-Ink 想法响应不完整",0) end
    return value
end
function M:translation_member_summary()
    local value=self:request("GET","/pay/memberCardSummary",{pf="wechat_wx-2001-android-100-weread"},"translation")
    if value.isPaying==nil then error("E-Ink 会员响应不完整",0) end
    return value
end
function M:membership_summary()
    return self:request("GET","/pay/memberCardSummary",{pf="android",snapshot=0,source="reader"},"account")
end
function M:account_overview()
    local result={}
    local balance_ok,balance=pcall(self.request,self,"POST","/pay/balance",
        {pf="android",zoneid="1",release=1,onlyLimitFree=0,noSnapshot=0},"account")
    if balance_ok and tonumber(balance.balance) then
        result.balance=tonumber(balance.balance)
        result.gift_balance=tonumber(balance.giftBalance) or 0
    end
    local member_ok,member=pcall(self.membership_summary,self)
    if member_ok then
        local summary=require("miuread.eink_entitlements").summary(member,os.time())
        for key,value in pairs(summary) do result[key]=value end
        result.download_entitlement=require("miuread.download_entitlements").account_status(member,os.time())
    end
    if result.balance==nil and result.remaining==nil then error("E-Ink 未返回账户余额或会员资料",0) end
    return result
end
function M:toggle_translate(id,enabled)
    local key=self:cache_key(id)
    if self.translation_modes[key]==enabled then return {succ=true} end
    local value=self:request("GET","/trans/pdfepub",{cbid=tostring(id),
        transFormat=enabled and "epubTranslate" or "epub",transType="epubTranslate"},"translation")
    if value.succ~=true and tonumber(value.succ)~=1 then error("E-Ink 译文模式未能开启",0) end
    self.translation_modes[key]=enabled
    return value
end
function M:en_read(id,uid,read)
    local entries={}
    for _,item in ipairs(read or {}) do
        entries[#entries+1]={uid=tonumber(item.uid) or item.uid,translateVersion=tonumber(item.translateVersion) or 0}
    end
    if #entries<1 or #entries>2 then error("E-Ink 译文请求章节数无效",0) end
    -- freeTrial=0 follows the Native request contract without activating a trial.
    local value=self:authorized(function(credentials)
        local Json=require("miuread.json")
        local options=self:options(credentials,{5,20})
        options.url=BASE.."/en/bookread"; options.method="POST"
        options.body='{"bookId":'..Json.encode(tostring(id))..',"read":'..Json.encode(entries)
            ..',"reference":{"uid":'..Json.encode(tonumber(uid) or uid)..',"texts":[]},"freeTrial":0}'
        return self.http:json(options)
    end,"translation")
    if type(value)~="table" or (value.curStatus==nil and value.stopPoll==nil and value.tips==nil
        and value.translationProgress==nil) then error("E-Ink 译文状态响应无效",0) end
    if value.stopPoll==nil and value.translationProgress~=nil then value.stopPoll=0 end
    return value
end
function M:catalog(id)
    id=tostring(id)
    local cache_key = self:cache_key(id)
    if self.catalogs[cache_key] then return self.catalogs[cache_key] end
    local data = self:authorized(function(credentials)
        -- Request a complete catalog, using parallel arrays for the one book.
        -- Zero versions prevent an incremental/unchanged response from being
        -- mistaken for an empty catalog on the first request of a run.
        return self.http:post_json(BASE.."/book/chapterInfos",
            {bookIds={id},synckeys={0},updateTimes={0},maxfreeIdx={0}},self:options(credentials,{5,12}))
    end,"catalog")
    for _,record in ipairs(type(data)=="table" and (data.data or {}) or {}) do
        if tostring(record.bookId or "") == id and type(record.updated)=="table" then
            if type(record.book)~="table" or not record.book.format then record.book=self:book(id) end
            record.format=record.book.format
            self.catalogs[cache_key] = record
            return record
        end
    end
    error("E-Ink 未返回对应书籍目录")
end
local function confirmed(value)
    return value==true or (tonumber(value) or 0)>0
end

local function durable_access(book,chapter)
    if type(book)~="table" then return false end
    if confirmed(book.paid) or (book.paid==nil and bit.band(tonumber(book.intergrateAttr) or 0,1)~=0) then
        return true
    end
    if bit.band(tonumber(book.payType) or 0,32)~=0 then return true end
    local last_free=tonumber(book.maxFreeChapter)
    local index=tonumber(chapter.chapterIdx)
    return index~=nil and index>=0 and index%1==0 and last_free~=nil and last_free>=index
end

function M:_durable_download_access(id,version,catalog,chapter)
    if confirmed(chapter.paid) or confirmed(chapter.free) or tonumber(chapter.price)==0 then return true end
    local details=catalog.book
    if type(details)=="table" and (details.bookId==nil or tostring(details.bookId)==id)
        and durable_access(details,chapter) then return true end

    local key=self:cache_key(id)..":"..version
    local cached=self.book_access[key]
    if not cached then
        local info=self:request("GET","/book/info",{bookId=id,myzy=1},"book")
        if tostring(info.bookId or "")~=id then return false end
        local observed_version=info.version or info.bookVersion
        if observed_version and version~="0" and tostring(observed_version)~=version then return false end
        cached=info
        self.book_access[key]=cached
    end
    return durable_access(cached,chapter)
end

function M:_online_member_expiry(id,version,catalog)
    local key=self:cache_key(id)..":"..version
    local now=os.time()
    local saved=self.online_grants[key]
    if saved and now<saved.expires and now>=saved.observed and now-saved.observed<=60 then
        return saved.expires,nil,saved.kind,saved.observed
    end
    local book=self.book_access[key] or catalog.book
    if type(book)~="table" or tostring(book.bookId or "")~=id then return nil end
    local member=self:request("GET","/pay/memberCardSummary",{pf="android",snapshot=0,source="reader"},"online_access")
    local expires,remaining=tonumber(member.expiredTime),tonumber(member.remainTime)
    if (member.expired~=false and tonumber(member.expired)~=0) or not remaining or remaining<=0
        or not expires or expires<=now then return nil end
    expires=math.floor(math.min(expires,now+remaining))
    local paid_remaining=tonumber(member.payingRemainTime) or 0
    local paid=paid_remaining>0 and (confirmed(member.isPaying) or confirmed(member.paying))
    local pay_type=tonumber(book.payType) or 0
    local eligible,kind
    if bit.band(pay_type,1048576)~=0 then
        eligible=paid
        kind="paid"
        if eligible then expires=math.floor(math.min(expires,now+paid_remaining)) end
    elseif bit.band(pay_type,4096)~=0 then
        eligible=true
        kind="member"
    else
        local ok,tips=pcall(self.request,self,"GET","/reader/tips",{bookId=id,from="reader"},"online_access")
        if not ok then
            if Http.is_auth_error(tips) or Http.is_rate_limit_error(tips) then error(tips,0) end
            return nil,expires
        end
        if tips.bookId~=nil and tostring(tips.bookId)~=id then return nil end
        if tonumber(tips.payingType)==1 then
            eligible=paid
            kind="paid"
            if eligible then expires=math.floor(math.min(expires,now+paid_remaining)) end
        elseif confirmed(tips.canFreeRead) then
            eligible=true
            kind="member"
        end
    end
    if expires<=os.time() then return nil end
    if not eligible then
        -- A valid membership bounds any cache after an authoritative chapter
        -- response. For paid-only books use the paid window when available.
        if bit.band(pay_type,1048576)~=0 then
            return nil,paid and math.min(expires,now+paid_remaining) or nil
        end
        return nil,expires
    end
    self.online_grants[key]={expires=expires,observed=now,kind=kind}
    return expires,nil,kind,now
end

function M:_offline_download_grant(id,version,catalog)
    local book=self.book_access[self:cache_key(id)..":"..version] or catalog.book
    local loan=type(book)=="table" and tostring(book.bookId or "")==id and book.shortTimeRead
    local now=os.time()
    local due=type(loan)=="table" and tonumber(loan.expireTime)
    if due and due>now and confirmed(loan.active) then
        return {kind="loan",expires_at=math.floor(due),checked_at=now}
    end
    local expires,_,kind,checked=self:_online_member_expiry(id,version,catalog)
    if expires and kind then return {kind=kind,expires_at=expires,checked_at=checked} end
end

function M:_chapter_request_scope(id,uid,book_version)
    local catalog=self:catalog(id)
    local selected
    for _,row in ipairs(catalog.updated) do
        if tostring(row.chapterUid)==uid then selected=row;break end
    end
    if not selected then error("E-Ink 目录中不存在当前章节") end
    local format=tostring((catalog.book or {}).format or catalog.format or ""):lower()
    if format~="epub" and format~="txt" then error("E-Ink 书籍格式暂不支持") end
    local version=tostring((catalog.book or {}).version or book_version or (format=="txt" and "0" or catalog.synckey) or "")
    if version=="" then error("E-Ink 书籍版本缺失") end
    return catalog,selected,format,version
end

function M:online_chapter_access(book,chapter_uid)
    local id,uid=tostring(book.bookId or book.book_id),tostring(chapter_uid)
    local catalog,selected,_,version=self:_chapter_request_scope(id,uid,book.version)
    if self:_durable_download_access(id,version,catalog,selected) then
        return {durable=true,version=version,archive=selected.tar}
    end
    local expires,confirmed_until=self:_online_member_expiry(id,version,catalog)
    if expires then return {expires=expires} end
    local details=catalog.book
    if type(details)~="table" or tostring(details.bookId or "")~=id then
        return nil,"微信读书未确认本章在线阅读权限"
    end
    -- As in the standalone client, the authenticated chapter response can
    -- decide access when the book is known and the metadata is inconclusive.
    return {server_confirmation=true,expires=confirmed_until,session_only=confirmed_until==nil}
end

function M:download(book,chapter,path,opt)
    opt=opt or {}
    local id,uid = tostring(book.bookId or book.book_id), tostring(chapter.chapterUid or chapter.uid)
    local catalog,selected,format,version=self:_chapter_request_scope(id,uid,book.version)
    if opt.web_catalog_version~=nil and tostring(opt.web_catalog_version)~=tostring(catalog.synckey) then
        error("E-Ink 与 Web 目录版本不同")
    end
    local offline=not (opt.read_online==true and not opt.translation)
    local chapter_access=confirmed(selected.paid) or tonumber(selected.price)==0
    if opt.translation==false and self.translation_modes[self:cache_key(id)]==true then self:toggle_translate(id,false) end
    local access=opt.translation and chapter_access
        or (not opt.translation and self:_durable_download_access(id,version,catalog,selected))
    local expires,session_only,download_grant
    if not access and not offline and opt.limited_online==true then
        local root=self.store.limited_online_dir
        if type(root)=="string" and type(path)=="string" and path:sub(1,#root+1)==root.."/"
            and not path:find("/../",1,true) and path:sub(-3)~="/.." then
            local grant=self:online_chapter_access(book,uid)
            expires=grant and grant.expires
            session_only=grant and grant.session_only==true and opt.online_server_only==true
            access=expires~=nil or session_only==true
        end
    end
    if offline and opt.record_download_entitlement==true and not opt.translation then
        download_grant=access and {kind="owned"} or self:_offline_download_grant(id,version,catalog)
        access=download_grant~=nil
    end
    if not access then
        if not offline then error("微信读书未确认本章在线阅读权限",0) end
        error("微信读书未确认本章离线下载权限",0)
    end
    local resource_key=self:cache_key(id)..":"..version..(opt.eink_only and ":eink-only" or "")
    local chapters=format=="epub" and not self.resources[resource_key] and uid~="0" and ("0,"..uid) or uid
    local url = BASE.."/book/chapterdownload?bookId="..Protocol.escape(id).."&chapters="..Protocol.escape(chapters)
        .."&bookType="..format.."&bookVersion="..Protocol.escape(version)
        .."&pf=wechat_wx-2001-android-100-weread&pfkey=pfKey&zoneId=1"
        .."&quote=&release=1&stopAutoPayWhenBNE=1"
        ..(offline and "&preload=2&preview=0&offline=1" or "&preload=0&preview=0&offline=0")
    return self:authorized(function(credentials)
        local options = self:options(credentials,{5,22})
        options.keepalive=options.keepalive or opt.keepalive==true
        options.integrity_attempts = 1
        if not offline then options.retries=0 end
        options.max_response_bytes = require("miuread.eink_archive").MAX_ARCHIVE_BYTES
        options.on_chunk = function(bytes)
            if type(opt.yield)=="function" then opt.yield("content") end
            if type(opt.activity)=="function" then opt.activity("native_archive_download",{bytes=bytes}) end
        end
        local ok,downloaded,headers,_,meta=pcall(self.http.download_to_file,self.http,url,path,options)
        if not ok then
            -- The APK distinguishes HTTP 402 from network and authentication errors.
            if tostring(downloaded):match("HTTP%s+402%f[^%d]") then
                error("[MiuReadChapterLocked] 微信读书确认当前章节需开通阅读权限",0)
            end
            error(downloaded,0)
        end
        local envelope
        for key,value in pairs(headers or {}) do if tostring(key):lower()=="encryptkey" then envelope=value end end
        if not envelope then
            -- Classify JSON auth/rate errors through the same HTTP JSON path,
            -- without logging or displaying the response body or envelope.
            local raw = type(meta)=="table" and tostring(meta.preview or "") or ""
            local code = tonumber(raw:match('"err[Cc]ode"%s*:%s*(%-?%d+)') or raw:match('"errcode"%s*:%s*(%-?%d+)'))
            if code==-2011 or code==-2012 or code==-2041 then error(Http.auth_error_message(code)) end
            if code==-10102 or code==-2014 then error("[MiuReadRateLimit] error_code="..tostring(code)) end
            if code and code~=0 then error("E-Ink 章节服务返回错误 error_code="..tostring(code),0) end
            if format~="txt" then error("E-Ink 未返回章节下载密钥") end
        end
        if not opt.eink_only then self.resources[resource_key]=true end
        return downloaded,envelope,credentials.vid,{tar=selected.tar,version=version,resource_key=resource_key,
            online_expires=expires,online_server_only=session_only or nil,
            download_grant=download_grant,
            includes_shared_resources=chapters~=uid,format=format}
    end,"chapter_download")
end
function M:remove_from_shelf(id)
    id=tostring(id or "")
    if id=="" or Protocol.is_mp(id) or Protocol.is_mp_account(id) then error("invalid book id") end
    if not Client.credentials(self.store:auth()) then
        error("[MiuReadShelfPreflight] [MiuReadShelfAuthorization] 请先授权书架管理",0)
    end
    return self:write("/shelf/delete",{bookIds={id}},"shelf","[MiuReadShelfPreflight] ")
end
local function array(value,key,stage)
    if type(value)~="table" or type(value[key])~="table" then
        error("E-Ink 响应缺少 "..key.." native_stage="..stage,0)
    end
    return value
end
local function book_id(id)
    id=tostring(id or "")
    if id=="" then error("invalid book id",0) end
    return id
end
local function writable_book_id(id)
    id=book_id(id)
    if Protocol.is_mp(id) or Protocol.is_mp_account(id) then error("invalid book id",0) end
    return id
end
function M:book(id,details)
    id=book_id(id)
    local value=self:request("GET","/book/info",{bookId=id,myzy=details and 1 or nil},"book")
    if tostring(value.bookId or "")~=id or type(value.title)~="string" then error("E-Ink 书籍信息不完整",0) end
    return value
end

function M:download_pdf(id,path,on_progress)
    id=book_id(id)
    if not id:match("^[%w_-]+$") then error("PDF 书籍标识无效",0) end
    local info=self:book(id,true)
    local Pdf=require("miuread.eink_pdf")
    if not Pdf.is_book(info) then error("微信读书未确认此书为 PDF 原件",0) end
    if not (confirmed(info.paid) or confirmed(info.free) or bit.band(tonumber(info.payType) or 0,32)~=0) then
        error("微信读书未确认此 PDF 的整书下载权限",0)
    end

    local ok,downloaded=pcall(self.authorized,self,function(credentials)
        local options=self:options(credentials,{8,30})
        options.integrity_attempts=1
        options.on_chunk=on_progress
        options.headers["Accept-Encoding"]="identity"
        local filename,_,_,meta=self.http:download_to_file("https://res.weread.qq.com/wrco/pdf_"..id,path,options)
        local preview=type(meta)=="table" and tostring(meta.preview or "") or ""
        local code=tonumber(preview:match('"err[Cc]ode"%s*:%s*(%-?%d+)') or preview:match('"errcode"%s*:%s*(%-?%d+)'))
        if code==-2011 or code==-2012 or code==-2041 then error(Http.auth_error_message(code),0) end
        if code==-10102 or code==-2014 then error("[MiuReadRateLimit] error_code="..tostring(code),0) end
        local valid,why=Pdf.validate(filename)
        if not valid then error(why,0) end
        return filename
    end,"pdf_download")
    if not ok then os.remove(path); error(downloaded,0) end
    return downloaded,tonumber(info.version or info.bookVersion) or 0
end
function M:book_reviews(id)
    id=writable_book_id(id)
    local value=self:request("GET","/book/podcasts",
        {bookId=id,synckey=0,count=120,listType=2,reviewListType=0},"book")
    if value.bookId~=nil and tostring(value.bookId)~=id then error("书评返回了其他书籍",0) end
    if type(value.reviews)~="table" or Json.is_null(value.reviews) then error("E-Ink 书评列表不完整",0) end
    local rows,seen={},{}
    local partial=confirmed(value.reviewsHasMore)
    for _,entry in ipairs(value.reviews) do
        local wrapper=type(entry)=="table" and (entry.review or entry) or {}
        if type(wrapper)~="table" then wrapper={} end
        local row=wrapper.review or (type(entry)=="table" and entry.reviewData) or wrapper
        if type(row)~="table" then row={} end
        if row.bookId~=nil and tostring(row.bookId)~=id then error("书评返回了其他书籍",0) end
        local review_id=type(row.reviewId)=="string" and row.reviewId or ""
        if review_id=="" or (row.content~=nil and type(row.content)~="string") then
            partial=true
        elseif not seen[review_id] then
            local author=type(wrapper.author)=="table" and wrapper.author or row.author
            local body=type(row.content)=="string" and row.content or ""
            rows[#rows+1]={id=review_id,author=type(author)=="table" and tostring(author.name or "") or "",
                content=U.utf8_truncate(body,4096,"…"),created=tonumber(row.createTime) or 0}
            seen[review_id]=true
        end
        if #rows>=120 then
            partial=partial or #value.reviews>120
            break
        end
    end
    return {rows=rows,partial=partial}
end

function M:dictionary(word)
    word=U.trim(word)
    if word=="" or #word>256 or word:find("[%z%c]") then error("请选择一个较短的词语",0) end
    local value=self:request("POST","/dict/query",{word=word},"dictionary",{timeout={3,7}})
    local status=tonumber(value.status)
    if status~=0 and status~=1 then error("E-Ink 词典响应不完整",0) end
    local lines={}
    local function append(text)
        if type(text)~="string" or text:find("%z") then return end
        text=U.trim(text)
        if text~="" then lines[#lines+1]=U.utf8_truncate(text,2048,"…") end
    end
    if status==1 and type(value.message)=="table" then
        local message=value.message
        append(message.spell_en)
        append(message.spell_am)
        for i,row in ipairs(type(message.result)=="table" and message.result or {}) do
            if i>32 then break end
            if type(row)=="table" then
                append(row.part)
                append(row.mean)
                for j,entry in ipairs(type(row.means)=="table" and row.means or {}) do
                    if j>32 then break end
                    if type(entry)=="table" then append(entry.mean) end
                end
            end
        end
    end
    local definition=U.utf8_truncate(table.concat(lines,"\n"),4096,"…")
    local encyclopedia=type(value.baike)=="string" and U.utf8_truncate(U.trim(value.baike),2048,"…") or ""
    return {definition=definition,encyclopedia=encyclopedia}
end

function M:mp_list(kind,cursor,show_wechat)
    if kind~=0 and kind~=1 then error("公众号列表类型无效",0) end
    if show_wechat==nil then
        local settings=self:request("GET","/config",{synckey=0},"articles")
        local grants=type(settings.accountsets)=="table" and settings.accountsets or {}
        local granted=grants.mpBookGranted
        if granted~=true and granted~=false and tonumber(granted)~=0 and tonumber(granted)~=1 then
            error("无法确认公众号阅读设置",0)
        end
        show_wechat=confirmed(granted) and 1 or 0
    end
    local query={count=50,listType=kind,showWx=show_wechat}
    if cursor then query.maxIdx=cursor else query.synckey=0 end
    local value=self:request("GET","/mp/list",query,"articles")
    if value.listType~=nil and not Json.is_null(value.listType) and tonumber(value.listType)~=kind then
        error("公众号返回了其他列表",0)
    end
    return value,show_wechat
end

function M:mp_content(id)
    id=tostring(id or "")
    if id=="" then error("缺少公众号文章编号",0) end
    local value=self:request("GET","/review/single",{reviewId=id},"articles")
    local review=type(value.review)=="table" and value.review or {}
    if tostring(value.reviewId or "")~=id or (review.reviewId~=nil and tostring(review.reviewId)~=id) then
        error("公众号返回了其他文章",0)
    end
    local info=review.mpInfo
    if tonumber(review.type)~=16 or type(info)~="table" or confirmed(info.inner) then
        error("当前文章类型暂不支持",0)
    end
    if confirmed(info.isSoldOut) then error("该文章已下架",0) end
    local url=type(info.doc_url)=="string" and info.doc_url or ""
    if url:sub(1,2)=="//" then url="https:"..url end
    url=url:gsub("^http://","https://")
    local pay_type=info.payType==nil and 0 or tonumber(info.payType)
    if url=="" or url:find("[%z%c]") or (pay_type~=0 and pay_type~=1 and pay_type~=2) then
        error("公众号文章信息不完整",0)
    end
    if pay_type==2 then
        local paid=self:request("POST","/mp/getpaidinfo",{urls={url},need_content=1},"articles")
        local rows=paid.pay_appmsg_infos
        local entry=type(rows)=="table" and #rows==1 and rows[1]
        if type(entry)~="table" then error("无法确认付费文章权限",0) end
        if entry.ispaid~=true and tonumber(entry.ispaid)~=1 and tostring(entry.ispaid):lower()~="true" then
            error("当前账号暂无此付费文章的阅读权限",0)
        end
        if type(entry.content)~="string" or entry.content=="" or entry.content:find("%z") then
            error("付费文章正文为空",0)
        end
        return entry.content,false
    end
    if not url:match("^https://mp%.weixin%.qq%.com/") then error("公众号原文地址无效",0) end
    local html=self.http:download(url,{auth=false,redirects=0,retries=1,timeout={5,15},
        headers={Accept="text/html,application/xhtml+xml,*/*"}})
    return html,true
end

function M:chapters(id) return self:catalog(book_id(id)) end
function M:shelf(options)
    return array(self:request("GET","/shelf/sync",{synckey=0,lectureSynckey=0},"shelf",options),"books","shelf")
end
function M:shelf_stream(options)
    if options and options.allow_full_fallback==false then error("E-Ink 暂不支持轻量书架索引",0) end
    local value=self:shelf(options)
    value._miuread_stream={enabled=false,source="eink_full"}
    return value
end
function M:book_on_shelf(id)
    local present=require("miuread.bookstore_data").shelf_state(self:shelf(),book_id(id),true)
    if type(present)~="boolean" then error("E-Ink 书架状态无法确认",0) end
    return present
end
function M:search(keyword,offset,count)
    return array(self:request("GET","/store/search",{keyword=tostring(keyword or ""),scope=10,
        maxIdx=offset or 0,count=count or 30},"search"),"books","search")
end
function M:recent_books()
    return require("miuread.bookstore_data").recent_books(
        self:request("GET","/storyfeed/getRecentBooks",{},"store",{timeout={5,12}}))
end

function M:recommend_books(offset,count)
    return array(self:request("GET","/book/recommend",{maxIdx=offset or 0,count=count or 20},"store"),"books","store")
end
function M:similar_books(id,offset,count,session_id)
    local value=self:request("GET","/book/detailinfo",{bookId=book_id(id),listtypes=2,synckey=0,
        maxIdx=offset or 0,count=count or 20,sessionId=session_id},"store")
    array(value.booksimilar,"books","store")
    return value
end
function M:store_categories()
    -- Native CategoryList carries `updated` on an initial sync; ranks use a
    -- separate selector on the same endpoint. Preserve the complete Web shape.
    local categories=self:request("GET","/market/categories",{recommend=0,synckey=0,subtype=0},"store")
    local ranks=self:request("GET","/market/categories",{ranklist=1,synckey=0,subtype=0},"store")
    local function rows(value)
        local list=value.updated or value.data
        if type(list)~="table" then error("E-Ink 分类列表不完整",0) end
        return list
    end
    local value={data={{categories=rows(categories)},{categories=rows(ranks)}}}
    local parsed=require("miuread.bookstore_data").categories(value)
    if #parsed.categories==0 or #parsed.ranks==0 then error("E-Ink 分类与排行未能完整映射",0) end
    return value
end
function M:category_books(id,offset,rank)
    id=tostring(id or "")
    if not id:match("^[%w_%-]+$") then error("invalid bookstore category",0) end
    local value=self:request("GET","/market/category",{categoryId=id,maxIdx=offset or 0,count=20,
        rank=rank and 1 or 0,synckey=0},"store")
    local rows=value.updated or value.data
    if type(rows)~="table" then error("E-Ink 分类书籍列表不完整",0) end
    local result={books=rows,hasMore=value.hasMore,totalCount=value.totalCount or (value.category or {}).totalCount}
    local page=require("miuread.bookstore_data").page("category",result,offset,20)
    if (result.hasMore==true or tonumber(result.hasMore)==1 or (result.hasMore==nil and #rows>=20))
        and page.next_cursor<=(tonumber(offset) or 0) then error("E-Ink 分类分页游标不完整",0) end
    return result
end
function M:reading_stats(mode,base_time,options)
    mode=tostring(mode or "monthly")
    if mode~="weekly" and mode~="monthly" and mode~="annually" and mode~="overall" then error("invalid reading statistics mode",0) end
    local value=self:request("GET","/readdata/detail",{mode=mode,baseTime=tonumber(base_time) or 0},"statistics",options)
    if value.totalReadingTime==nil and value.totalReadTime==nil and value.readingTime==nil
        and value.readStat==nil and value.readBookCount==nil then error("E-Ink 阅读统计不完整",0) end
    return value
end
function M:notebooks(count,last_sort)
    local value=array(self:request("GET","/user/notebooks",{count=count or 100,lastSort=last_sort},"annotations"),"books","annotations")
    local rows,limit={},math.max(1,math.floor(tonumber(count) or 100))
    for _,row in ipairs(value.books) do
        if not tonumber(last_sort) or tonumber(last_sort)==0 or (tonumber(row.sort) and tonumber(row.sort)<tonumber(last_sort)) then
            rows[#rows+1]=row
        end
    end
    value.hasMore=#rows>limit and 1 or (value.hasMore or 0)
    value.books={}; for i=1,math.min(limit,#rows) do value.books[i]=rows[i] end
    return value
end
function M:bookmark_list(id,synckey)
    local value=self:request("GET","/book/bookmarklist",{bookId=book_id(id),synckey=synckey or 0},"annotations")
    if type(value.updated)~="table" and type(value.data)~="table" then error("E-Ink 书签列表不完整",0) end
    return value
end
function M:review_list_mine(id,synckey,count)
    local value=self:request("GET","/review/list",{bookId=book_id(id),listType=11,listMode=0,mine=1,
        synckey=synckey or 0,count=count or 100},"annotations")
    if type(value.reviews)~="table" and type(value.updated)~="table" then error("E-Ink 想法列表不完整",0) end
    return value
end
function M:book_search(id,keyword,cursor)
    id=book_id(id)
    local value=self:request("GET","/book/search",{bookId=id,keyword=keyword,
        maxIdx=cursor or 0,count=10,fragmentSize=100},"search")
    if value.bookId~=nil and tostring(value.bookId)~=id then error("书内搜索响应与当前书籍不匹配",0) end
    local raw=value.result
    if require("miuread.json").is_null(raw) or (raw==nil and tonumber(value.totalCount)==0) then raw={} end
    if type(raw)~="table" or #raw>10 then error("E-Ink 书内搜索结果不完整",0) end
    local hits,next_cursor={},cursor or 0
    for _,row in ipairs(raw) do
        if type(row)=="table" then
            local uid,index=tonumber(row.chapterUid),tonumber(row.searchIdx)
            if uid and uid>=0 and uid%1==0 and index and index>=0 and index%1==0 then
                local excerpt=type(row.abstract)=="string" and row.abstract or ""
                hits[#hits+1]={chapter_uid=tostring(uid),chapter_index=tonumber(row.chapterIdx),
                    text=excerpt:gsub("</?em[^>]*>",""):gsub("</?b[^>]*>","")}
                next_cursor=math.max(next_cursor,index)
            end
        end
    end
    local more=value.hasMore==true or tonumber(value.hasMore)==1 or (value.hasMore==nil and #raw==10)
    return {rows=hits,total=tonumber(value.totalCount),
        cursor=more and next_cursor>(cursor or 0) and next_cursor or nil}
end

function M:best_bookmarks(id)
    id=book_id(id)
    local HotMarks=require("miuread.hot_marks")
    local payload=self:request("GET","/book/bestbookmarks",{bookId=id,synckey=0,maxIdx=0,count=HotMarks.LIMIT},"annotations")
    local result,err=HotMarks.normalize(payload,id)
    if not result then error(err,0) end
    return result
end
function M:review_single(id)
    id=tostring(id or ""); if id=="" then error("reviewId missing",0) end
    local value=self:request("GET","/review/single",{reviewId=id,synckey=0,commentsCount=10,commentsDirection=0,
        likesCount=10,likesDirection=0},"annotations")
    if type(value.review)~="table" and type(value.data)~="table" then error("E-Ink 想法详情不完整",0) end
    return value
end
-- Public thought replies use the E-Ink detail endpoint and its own comment cursor.
function M:review_comments(id,cursor)
    id=tostring(id or "")
    if id=="" then error("reviewId missing",0) end
    local query={reviewId=id,synckey=0,commentsCount=20,commentsDirection=1}
    if cursor then
        query.synckey,query.commentsMaxIdx=cursor.synckey,cursor.offset
    else
        query.bookReviewCount,query.likesCount,query.likesDirection=1,0,1
    end
    return self:request("GET","/review/single",query,"annotations")
end

function M.progress_position(value,id)
    local queue,best={value},nil
    for index=1,32 do
        local row=queue[index]
        if row==nil then break end
        if type(row)=="table" and (row.bookId==nil or tostring(row.bookId)==tostring(id)) then
            local uid=tonumber(row.chapterUid or row.chapter_uid)
            local offset=tonumber(row.chapterOffset or row.chapter_offset)
            if uid and uid>=0 and uid%1==0 and offset and offset>=0 and offset<2147483648 and offset%1==0 then
                local stamp=row.updateTime or row.updatedAt or row.readUpdateTime
                local updated=require("miuread.shelf_progress").timestamp(stamp)
                if updated==0 then updated=require("miuread.timezone").parse_iso_timestamp(stamp) or 0 end
                if not best or updated>best.updated_at then
                    best={chapter_uid=tostring(uid),offset=offset,chapter_offset=offset,
                        chapter_idx=tonumber(row.chapterIdx or row.chapterIndex),
                        percent=tonumber(row.progress or row.currentProgress),updated_at=updated,
                        version=tonumber(row.bookVersion),device_id=row.deviceId,app_id=row.appId,
                        install_id=row.installId,summary=row.summary}
                end
            end
            for _,key in ipairs({"book","tts","data","result","reader","progressInfo","bookProgress"}) do
                if type(row[key])=="table" then queue[#queue+1]=row[key] end
            end
        end
    end
    return best
end
function M.progress_is_empty(value,id)
    if M.progress_position(value,id) then return false end
    local book=type(value)=="table" and value.book
    if book~=nil and require("miuread.json").is_null(book) then return true end
    return type(book)=="table" and (book.bookId==nil or tostring(book.bookId)==tostring(id))
        and tonumber(book.chapterUid)==-1
end
function M:progress(id,options)
    local value=self:request("GET","/book/getProgress",{bookId=book_id(id)},"progress",options)
    if not M.progress_is_empty(value,id) and not M.progress_position(value,id)
        and not require("miuread.shelf_progress").parse(value,id) then
        error("E-Ink 阅读进度不完整",0)
    end
    value._progress_source="eink"; value._progress_fetched_at=os.time()
    return value
end
function M:book_read_info(id)
    local value=self:request("GET","/book/readinfo",{bookId=book_id(id),finishedBookCount=1,finishedBookIndex=1,finishedDate=1},"progress")
    if value.finishedBookIndex==nil and value.finishedDate==nil and value.finished==nil then error("E-Ink 阅读状态不完整",0) end
    return value
end

function M:pdf_progress(id)
    local value=self:request("GET","/book/getProgress",{bookId=book_id(id)},"progress")
    local position,err=require("miuread.eink_pdf").progress(value,id)
    if not position then error(err,0) end
    position.fetched_at=os.time()
    position.server_timestamp=value.timestamp
    return position
end

function M.other_progress_device(position,credentials)
    return (type(position.app_id)=="string" and position.app_id~="" and position.app_id~=credentials.deviceId)
        or (type(position.install_id)=="string" and position.install_id~="" and position.install_id~=credentials.installId)
end

function M:write_position(position,may_dispatch,rows)
    if type(position)~="table" or position.eink_coordinate~=true then
        return {error="E-Ink 位置尚未验证",error_kind="position",request_dispatched=false}
    end
    local book=self:book(position.book_id)
    local pdf=position.document_format=="pdf"
    if pdf and not require("miuread.eink_pdf").is_book(book) then
        return {error="云端书籍格式已经变化",error_kind="position",request_dispatched=false}
    end
    local version=tostring(book.format):lower()=="txt" and not pdf and 0 or tonumber(book.version or book.bookVersion)
    if pdf and version==nil then version=0 end
    if version==nil or version~=tonumber(position.book_version) then
        return {error="E-Ink 书籍版本已变更，需重新定位",error_kind="position",request_dispatched=false}
    end
    local remote=pdf and self:pdf_progress(position.book_id) or self:progress(position.book_id)
    local observed=pdf and (not remote.empty and remote or nil) or (not pdf and M.progress_position(remote,position.book_id) or nil)
    if not observed and not (pdf and remote.empty) and not (not pdf and M.progress_is_empty(remote,position.book_id)) then
        return {error="云端位置缺少可比较的坐标",error_kind="position",request_dispatched=false}
    end
    if observed and observed.version~=nil and observed.version~=version then
        return {error="云端位置对应另一版正文",error_kind="position",request_dispatched=false}
    end
    local same=observed and observed.chapter_uid==tostring(position.chapter_uid)
        and observed.offset==position.chapter_offset
    if observed then observed.source=observed.source or "eink" end
    local credentials=Client.credentials(self.store:auth())
    if not credentials then error("E-Ink 客户端需要重新登录",0) end
    local captured=tonumber(position.captured_at) or 0
    local conflict=observed and not same and (observed.updated_at==0 or captured==0
        or (observed.updated_at>captured and M.other_progress_device(observed,credentials)))
    local with_time=type(rows)=="table" and #rows>0
    if not with_time then
        if same then return {accepted=true,already=true,request_dispatched=false,remote=observed} end
        if conflict then
            return {error="云端位置已更新或时间无法确认",error_kind="position",request_dispatched=false,remote=observed,
                cloud_conflict=observed.updated_at>0 and captured>0}
        end
    end

    local Protocol=require("miuread.readtime_protocol")
    local config=self:request("GET","/config",{token=1},"progress")
    local feature=Protocol.guest_token(self:request("GET","/feature",{synckey=0},"progress"))
    if with_time and self.on_readtime_server_clock then
        self.on_readtime_server_clock(remote.server_timestamp or remote.timestamp,
            config.server_time_max_offset or (type(config.config)=="table" and config.config.server_time_max_offset))
    end
    local auth=self.store:auth()
    credentials=Client.credentials(auth)
    if not credentials then error("E-Ink 客户端需要重新登录",0) end
    local time_only=same or conflict
    local batch=time_only or position.eink_resend==true
    local now,nonce=os.time(),math.random(0,999)
    local body
    if time_only then
        body=Protocol.batch(credentials,position.book_id,rows,feature,config.token,now,nonce,
            {timestamp=now*1000,random=math.random(0,999)})
    elseif batch then
        body=Protocol.position_batch(credentials,position,feature,config.token,now,nonce,math.random(0,999),rows)
    else
        body=Protocol.position_body(credentials,position,feature,now,nonce,rows)
    end
    local encoded=require("miuread.json").encode(body):gsub('("hours"%s*:%s*){}','%1[]',1)
    local options=self:options(credentials,{5,15})
    options.url,options.method=BASE..(batch and "/book/batchUploadProgress" or "/book/read"),"POST"
    options.body=encoded
    local dispatched=false
    options.before_dispatch=function()
        local current
        if type(self.store.read_persisted)=="function" then current=self.store:read_persisted("auth")
        else current=self.store:auth() end
        local saved=Client.credentials(current or {})
        if not saved or saved.vid~=credentials.vid or saved.accessToken~=credentials.accessToken
            or current.login_session_id~=auth.login_session_id then return false end
        if may_dispatch and not may_dispatch(with_time) then return false end
        dispatched=true
        return true
    end
    local ok,value=pcall(self.http.json,self.http,options)
    local receipt=require("miuread.eink_readtime").receipt(dispatched,ok,value)
    local accepted=same or (not conflict and receipt.state=="confirmed")
    local message
    if conflict then message="云端位置已更新或时间无法确认"
    elseif not accepted then message=dispatched and "E-Ink 进度回执待确认" or "E-Ink 进度尚未发送" end
    return {accepted=accepted==true,already=same==true,remote=observed,
        progress_route=time_only and "time_only" or (batch and "batch" or "single"),
        request_dispatched=dispatched and receipt.state~="pending" and not time_only,error=message,
        error_kind=conflict and "position" or (receipt.error=="authentication" and "authentication" or nil),
        cloud_conflict=conflict and observed.updated_at>0 and captured>0 or false,
        time_receipt=with_time and receipt or nil}
end
function M.write_succeeded(value)
    return type(value)=="table" and (value.succ==true or tonumber(value.succ)==1)
end

function M:write(path,payload,stage,preflight_marker,empty_list)
    local auth=self.store:auth() or {}
    local credentials=Client.credentials(auth)
    local marker=preflight_marker or "[MiuReadBeforeWrite] "
    if not credentials then error(marker.."E-Ink 接口需要客户端授权",0) end
    local session=tostring(auth.login_session_id or "")
    local function send(current_credentials)
        if self.before_request then self.before_request(stage) end
        local options=self:options(current_credentials,{5,15})
        options.before_dispatch=function()
            local current
            if type(self.store.read_persisted)=="function" then current=self.store:read_persisted("auth")
            else current=self.store:auth() end
            local saved=Client.credentials(current or {})
            return saved~=nil and tostring(current.login_session_id or "")==session
                and saved.vid==current_credentials.vid and saved.accessToken==current_credentials.accessToken
        end
        if not empty_list then return self.http:post_json(BASE..path,payload,options) end
        local encoded=require("miuread.json").encode(payload)
        options.url,options.method=BASE..path,"POST"
        local fields=type(empty_list)=="table" and empty_list or {empty_list}
        local arrays={}
        for _,field in ipairs(fields) do arrays[#arrays+1]=',"'..field..'":[]' end
        options.body=encoded:sub(1,-2)..table.concat(arrays)..'}'
        return self.http:json(options)
    end
    local ok,value=pcall(send,credentials)
    if not ok then
        local failure=tostring(value)
        local status=tonumber(failure:match("HTTP (%d+)"))
        local code=tonumber(failure:match("error_code=(%-?%d+)"))
        if status==401 or code==-2011 or code==-2012 or code==-2041 then
            local renewed,fresh=pcall(Client.refresh,self.http,self.store)
            if not renewed then error(marker..tostring(fresh),0) end
            ok,value=pcall(send,fresh)
        end
    end
    if not ok then error(value,0) end
    if type(value)~="table" then error("E-Ink 写入结果无法确认",0) end
    return value
end
function M:write_shelf_group(action,id,name,book)
    if action=="delete" then
        return self:write("/shelf/deleteArchive",{archiveId=id,removeBooks=0},"shelf")
    end
    local payload={archiveId=id,name=name}
    local empty_list="lectureBookIds"
    if book then
        payload.bookIds={writable_book_id(book)}
    else
        -- The JSON encoder needs an explicit array for a rename with no members.
        return self:write("/shelf/archive",payload,"shelf",nil,{"bookIds",empty_list})
    end
    return self:write("/shelf/archive",payload,"shelf",nil,empty_list)
end

function M:add_to_shelf(id)
    return self:write("/shelf/add",{bookIds={writable_book_id(id)}},"shelf")
end
function M:mark_book_finished(id,finished)
    if type(finished)~="boolean" then error("invalid reading status",0) end
    return self:write("/book/markstatus",{bookId=writable_book_id(id),auto=0,finishInfo=0,isCancel=finished and 0 or 1,status=4},"progress")
end
function M:add_bookmark(payload) return self:write("/book/addBookmark",payload,"annotations") end
function M:add_review(payload) return self:write("/review/add",payload,"annotations",nil,"atUserVids") end
function M:edit_review(payload) return self:write("/review/useredit",payload,"annotations") end
function M:remove_bookmark(id)
    id=tostring(id or ""); if id=="" then error("bookmarkId missing",0) end
    return self:write("/book/removeBookmark",{bookmarkId=id},"annotations")
end
function M:remove_review(payload)
    local id=tostring((payload or {}).reviewId or (payload or {}).review_id or "")
    if id=="" then error("reviewId missing",0) end
    return self:write("/review/delete",{reviewId=id},"annotations")
end
function M:like_review(id,unlike)
    id=tostring(id or ""); if id=="" then error("reviewId missing",0) end
    return self:write("/review/like",{reviewId=id,isUnlike=unlike and 1 or 0},"annotations")
end
function M:chapter(book,chapter,format,options)
    assert(self.reader,"Native chapter reader missing")
    self.reader._eink_client=self
    return self.reader:eink_chapter(book,chapter,format,options)
end
return M
