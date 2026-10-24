local Client = require("miuread.shelf_client")
local Http = require("miuread.http")
local Protocol = require("miuread.protocol")
local M = {}
M.__index = M
local BASE = "https://i.weread.qq.com"

function M.new(http,store,reader)
    return setmetatable({http=http,store=store,reader=reader,catalogs={},resources={},translation_modes={}},M)
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
    local ok,a,b,c = pcall(fn,credentials)
    if ok then return a,b,c end
    if allow_recovery==false or Http.is_rate_limit_error(a) or not Http.is_auth_error(a) then raise_request_error(a,stage) end
    if self.before_request then self.before_request("refresh") end
    local renewed,value=pcall(Client.refresh,self.http,self.store)
    if not renewed then raise_request_error(value,"refresh") end
    if self.before_request then self.before_request(stage) end
    local retried,x,y,z=pcall(fn,value)
    if not retried then raise_request_error(x,stage) end
    return x,y,z
end
function M:request(method,path,parameters,stage,request_options)
    local value=self:authorized(function(credentials)
        local options=self:options(credentials,{5,20})
        if request_options and request_options.timeout then options.timeout=request_options.timeout end
        if method=="GET" then
            local query=next(parameters or {}) and ("?"..Protocol.query(parameters)) or ""
            return self.http:get_json(BASE..path..query,options)
        end
        return self.http:post_json(BASE..path,parameters,options)
    end,stage,not (request_options and request_options.no_auth_recovery==true))
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
function M:download(book,chapter,path,opt)
    opt=opt or {}
    local id,uid = tostring(book.bookId or book.book_id), tostring(chapter.chapterUid or chapter.uid)
    local catalog = self:catalog(id)
    if opt.web_catalog_version~=nil and tostring(opt.web_catalog_version)~=tostring(catalog.synckey) then
        error("E-Ink 与 Web 目录版本不同")
    end
    local selected
    for _,row in ipairs(catalog.updated) do if tostring(row.chapterUid)==uid then selected=row; break end end
    if not selected then error("E-Ink 目录中不存在当前章节") end
    -- Avoid native auto-purchase semantics: only request chapters whose catalog
    -- explicitly says free or already paid. Other entitlements stay with Web.
    if not ((tonumber(selected.price)~=nil and tonumber(selected.price)<=0) or (tonumber(selected.paid) or 0)>0) then
        error("E-Ink 目录未确认章节免费或已购买")
    end
    local format = tostring((catalog.book or {}).format or catalog.format or ""):lower()
    if format ~= "epub" and format ~= "txt" then error("E-Ink 书籍格式暂不支持") end
    local version = format=="txt" and "0" or tostring((catalog.book or {}).version or book.version or catalog.synckey or "")
    if version == "" then error("E-Ink 书籍版本缺失") end
    local resource_key=self:cache_key(id)..":"..version
    local chapters=format=="epub" and not self.resources[resource_key] and uid~="0" and ("0,"..uid) or uid
    local url = BASE.."/book/chapterdownload?bookId="..Protocol.escape(id).."&chapters="..Protocol.escape(chapters)
        .."&bookType="..format.."&bookVersion="..Protocol.escape(version)
        .."&pf=wechat_wx-2001-android-100-weread&pfkey=pfKey&zoneId=1"
        .."&quote=&release=1&stopAutoPayWhenBNE=1&preload=2&preview=0&offline=1"
    return self:authorized(function(credentials)
        local options = self:options(credentials,{5,22})
        options.keepalive=options.keepalive or opt.keepalive==true
        options.integrity_attempts = 1
        options.on_chunk = function(bytes)
            if type(opt.yield)=="function" then opt.yield("content") end
            if type(opt.activity)=="function" then opt.activity("native_archive_download",{bytes=bytes}) end
        end
        local downloaded,headers,_,meta = self.http:download_to_file(url,path,options)
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
            error("E-Ink 未返回章节下载密钥")
        end
        self.resources[resource_key]=true
        return downloaded,envelope,credentials.vid
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
function M:book(id)
    id=book_id(id)
    local value=self:request("GET","/book/info",{bookId=id},"book")
    if tostring(value.bookId or "")~=id or type(value.title)~="string" then error("E-Ink 书籍信息不完整",0) end
    return value
end
function M:chapters(id) return self:catalog(book_id(id)) end
function M:shelf(options)
    return array(self:request("GET","/shelf/sync",{},"shelf",options),"books","shelf")
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
function M:bookmark_list(id)
    return array(self:request("GET","/book/bookmarklist",{bookId=book_id(id),synckey=0},"annotations"),"updated","annotations")
end
function M:review_list_mine(id,synckey,count)
    return array(self:request("GET","/review/list",{bookId=book_id(id),listType=1,listMode=0,mine=1,
        synckey=synckey or 0,count=count or 100},"annotations"),"reviews","annotations")
end
function M:review_single(id)
    id=tostring(id or ""); if id=="" then error("reviewId missing",0) end
    local value=self:request("GET","/review/single",{reviewId=id,synckey=0,commentsCount=10,commentsDirection=0,
        likesCount=10,likesDirection=0},"annotations")
    if type(value.review)~="table" and type(value.data)~="table" then error("E-Ink 想法详情不完整",0) end
    return value
end
function M:progress(id,options)
    local value=self:request("GET","/book/getProgress",{bookId=book_id(id)},"progress",options)
    if not require("miuread.shelf_progress").parse(value,id) then error("E-Ink 阅读进度不完整",0) end
    value._progress_source="eink"; value._progress_fetched_at=os.time()
    return value
end
function M:book_read_info(id)
    local value=self:request("GET","/book/readinfo",{bookId=book_id(id),finishedBookCount=1,finishedBookIndex=1,finishedDate=1},"progress")
    if value.finishedBookIndex==nil and value.finishedDate==nil and value.finished==nil then error("E-Ink 阅读状态不完整",0) end
    return value
end
function M:write(path,payload,stage,preflight_marker)
    -- Renew credentials before sending. Never replay a possibly committed POST.
    local ok,credentials=pcall(self.authorized,self,function(value)
        local snapshot=self.http:get_json(BASE.."/shelf/sync",self:options(value,{5,10}))
        array(snapshot,"books","shelf")
        return value
    end,stage)
    if not ok then
        if require("miuread.api_transport").control_error(credentials) then error(credentials,0) end
        error((preflight_marker or "[MiuReadBeforeWrite] ")..tostring(credentials),0)
    end
    if self.before_request then self.before_request(stage) end
    local value=self.http:post_json(BASE..path,payload,self:options(credentials,{5,15}))
    if type(value)~="table" then error("E-Ink 写入结果无法确认",0) end
    return value
end
function M:add_to_shelf(id)
    return self:write("/shelf/add",{bookIds={writable_book_id(id)}},"shelf")
end
function M:mark_book_finished(id,finished)
    if type(finished)~="boolean" then error("invalid reading status",0) end
    return self:write("/book/markstatus",{bookId=writable_book_id(id),auto=0,finishInfo=0,isCancel=finished and 0 or 1,status=4},"progress")
end
function M:add_bookmark(payload) return self:write("/book/addBookmark",payload,"annotations") end
function M:add_review(payload) return self:write("/review/add",payload,"annotations") end
function M:remove_bookmark(id)
    id=tostring(id or ""); if id=="" then error("bookmarkId missing",0) end
    return self:write("/book/removeBookmark",{bookmarkIds={id}},"annotations")
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
