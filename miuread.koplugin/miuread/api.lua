local Protocol = require("miuread.protocol")
local U = require("miuread.util")
local Http = require("miuread.http")
local Codec = require("miuread.codec")
local logger = require("logger")

local Api = {}
Api.__index = Api

local function scalar(value, depth, seen)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then return value end
    if kind ~= "table" or (depth or 0) > 4 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    for _, key in ipairs({"chapterUid", "chapterId", "uid", "id", "value", "node"}) do
        local candidate = scalar(value[key], (depth or 0) + 1, seen)
        if candidate ~= nil then return candidate end
    end
end

local function sanitize(value, path, seen)
    local kind = type(value)
    path = path or "$"
    if kind == "nil" or kind == "string" or kind == "number" or kind == "boolean" then return value end
    if kind ~= "table" then error("unsupported parameter at " .. path .. ": " .. kind) end
    seen = seen or {}
    if seen[value] then error("cyclic parameter at " .. path) end
    seen[value] = true
    local out, max, count, array = {}, 0, 0, true
    for key in pairs(value) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then array = false else max = math.max(max, key) end
    end
    if array and max ~= count then array = false end
    if array then
        for i = 1, max do out[i] = sanitize(value[i], path .. "[" .. i .. "]", seen) end
    else
        for key, item in pairs(value) do
            if type(key) ~= "string" then error("non-string object key at " .. path) end
            local clean = sanitize(item, path .. "." .. key, seen)
            if clean ~= nil then out[key] = clean end
        end
    end
    seen[value] = nil
    return out
end

local function unwrap(data)
    local current = data
    for _ = 1, 4 do
        if type(current) ~= "table" then break end
        local candidate
        for _, key in ipairs({"data", "result", "payload"}) do
            if type(current[key]) == "table" then
                local only = true
                for k in pairs(current) do
                    if k ~= key and k ~= "errCode" and k ~= "errMsg" and k ~= "code" and k ~= "message" then only = false; break end
                end
                if only then candidate = current[key]; break end
            end
        end
        if not candidate then break end
        current = candidate
    end
    return current
end

local function unique_candidates(value)
    local raw = scalar(value)
    local out, seen = {}, {}
    local function add(v)
        if type(v) ~= "string" and type(v) ~= "number" then return end
        if type(v) == "string" and v == "" then return end
        local key = type(v) .. ":" .. tostring(v)
        if not seen[key] then seen[key] = true; out[#out + 1] = v end
    end
    add(raw)
    local number = tonumber(raw)
    if number then add(number) end
    if raw ~= nil then add(tostring(raw)) end
    return out
end

function Api:new(http, store, reader)
    return setmetatable({http = http, store = store, reader = reader, web_annotation_auth_dead=false}, self)
end

function Api:_note_web_annotation_failure(value)
    local code=tonumber(Http.auth_error_code(value))
    if code==-2012 then
        if self.web_annotation_auth_dead~=true then
            logger.warn("[MiuRead][API] web annotation circuit opened",
                "code=",tostring(code),"reason=session_timeout")
        end
        self.web_annotation_auth_dead=true
        return true
    end
    return false
end

local function recovery_detail(called,ok,value)
    if not called then return tostring(ok or "recovery call failed") end
    if ok==true then return "ok" end
    return tostring(value or "recovery failed")
end

function Api:_recover_web_once(channel,request_once,allow_recovery)
    local ok,a,b,c=pcall(request_once)
    if ok then return a,b,c end
    local first_error=a
    if allow_recovery==false or not Http.is_auth_error(first_error)
        or not self.reader or type(self.reader._recover_login_session)~="function" then
        error(first_error)
    end
    local called,recovered,detail=pcall(self.reader._recover_login_session,self.reader)
    logger.warn("[MiuRead][API] web authentication recovery",
        "channel=",tostring(channel or "web"),"ok=",tostring(called and recovered==true),
        "detail=",U.first_line(recovery_detail(called,recovered,detail),160))
    if called and recovered==true then
        local ok2,d,e,f=pcall(request_once)
        if ok2 then return d,e,f end
        error(d)
    end
    error(first_error)
end

function Api:_recover_agent_once(name)
    if not self.reader then return false,"automatic recovery unavailable" end
    local repair_error
    if type(self.reader.repair_login_session)=="function" then
        local called,value=pcall(self.reader.repair_login_session,self.reader)
        if called then
            logger.info("[MiuRead][API] Skills credential refresh succeeded","api=",tostring(name))
            return true,"skills_refreshed"
        end
        repair_error=value
        logger.warn("[MiuRead][API] Skills credential refresh failed",
            "api=",tostring(name),"error=",U.first_line(value,160))
    end
    if type(self.reader._recover_login_session)=="function" then
        local called,recovered,detail=pcall(self.reader._recover_login_session,self.reader)
        if called and recovered==true then
            logger.info("[MiuRead][API] full login recovery succeeded","api=",tostring(name))
            return true,"web_and_skills_refreshed"
        end
        return false,recovery_detail(called,recovered,detail or repair_error)
    end
    return false,tostring(repair_error or "automatic recovery unavailable")
end

function Api:call(name, params, request_options)
    local payload = sanitize(U.copy(params or {}))
    payload.api_name = tostring(name)
    payload.skill_version = Protocol.SKILL_VERSION

    local function request_once()
        local auth = self.store:auth()
        if tostring(auth.api_key or "") == "" then error("API key is not configured") end
        local options = U.copy(request_options or {})
        options.no_auth_recovery = nil
        options.auth = false
        options.headers = options.headers or {}
        options.headers.Authorization = "Bearer " .. tostring(auth.api_key)
        if options.retries == nil then options.retries = 2 end
        return self.http:post_json("https://i.weread.qq.com/api/agent/gateway", payload, options)
    end

    local ok, data = pcall(request_once)
    local annotation_endpoint=tostring(name)=="/book/underlines" or tostring(name)=="/book/readreviews"
    local allow_auth_recovery = not (type(request_options)=="table" and request_options.no_auth_recovery==true)
    if not ok and not annotation_endpoint and allow_auth_recovery and Http.is_auth_error(data) and self.reader then
        local recovered,recovery_mode=self:_recover_agent_once(name)
        logger.warn("[MiuRead][API] authentication recovery",
            "api=",tostring(name),"ok=",tostring(recovered),
            "detail=",recovered and tostring(recovery_mode or "ok") or U.first_line(recovery_mode,160))
        if recovered then ok,data=pcall(request_once) end
        if not ok and Http.is_auth_error(data) and recovery_mode=="skills_refreshed"
            and type(self.reader._recover_login_session)=="function" then
            local called,renewed,detail=pcall(self.reader._recover_login_session,self.reader)
            logger.warn("[MiuRead][API] authentication recovery second stage",
                "api=",tostring(name),"ok=",tostring(called and renewed==true),
                "detail=",U.first_line(recovery_detail(called,renewed,detail),160))
            if called and renewed==true then ok,data=pcall(request_once) end
        end
    end
    if not ok then error(tostring(name) .. ": " .. tostring(data)) end
    return unwrap(data)
end

function Api:reading_stats(mode, base_time, options)
    options=options or {}
    mode=tostring(mode or "monthly")
    if mode~="weekly" and mode~="monthly" and mode~="annually" and mode~="overall" then
        error("invalid reading statistics mode: "..mode)
    end
    return self:call("/readdata/detail", {
        mode=mode,
        baseTime=tonumber(base_time) or 0,
    }, {
        retries=options.retries==nil and 0 or options.retries,
        timeout=options.timeout or {6,12},
        no_auth_recovery=options.no_auth_recovery~=false,
    })
end

function Api:shelf(options)
    options=options or {}
    return self:call("/shelf/sync", {}, {
        retries=options.retries==nil and 1 or options.retries,
        timeout=options.timeout or {10,18},
    })
end

-- The official Agent shelf endpoint is intentionally full-shelf only.  For Home
-- we prefer the Web reader's two-stage shelf API: first request only ids, then
-- hydrate a small visible batch via /web/shelf/syncBook.  This genuinely keeps
-- bookInfo off the wire until a page is needed instead of slicing a full response
-- after download.  Any incompatibility falls back to Api:shelf().
local function shelf_index_ids(data)
    data=type(data)=="table" and data or {}
    local source=data.bookIds or data.bookids or data.books or data.updated or {}
    if type(source)~="table" then return {} end
    local out,seen={},{}
    local function add(value)
        if type(value)=="table" then
            value=value.bookId or value.book_id or value.id or value.book
            if type(value)=="table" then value=value.bookId or value.book_id or value.id end
        end
        value=tostring(value or "")
        if value~="" and not seen[value] then seen[value]=true; out[#out+1]=value end
    end
    if source[1]~=nil then
        for _,value in ipairs(source) do add(value) end
    else
        for key,value in pairs(source) do
            if type(value)=="boolean" or tonumber(value)~=nil then
                if value==true or tonumber(value)==1 then add(key) end
            else
                add(value)
            end
        end
    end
    return out
end

function Api:web_shelf_index(options)
    options=options or {}
    local auth=self.store:auth()
    local account=type(auth.account)=="table" and auth.account or {}
    local cookies=type(auth.cookies)=="table" and auth.cookies or {}
    local vid=tostring(account.vid or cookies.wr_vid or "")
    local url="https://weread.qq.com/web/shelf/sync?onlyBookid=1&cbcount=1"
    if vid~="" then url=url.."&userVid="..Protocol.escape(vid) end
    local request_options={
        auth=true,
        retries=options.retries==nil and 0 or options.retries,
        timeout=options.timeout or {7,12},
        headers={Accept="application/json, text/plain, */*",Referer="https://weread.qq.com/web/shelf"},
    }
    local data=self:_recover_web_once("shelf_index",function()
        return self.http:get_json(url,request_options)
    end,options.no_auth_recovery~=true)
    local ids=shelf_index_ids(data)
    if #ids==0 then error("web shelf index returned no book ids") end
    return data,ids
end

function Api:web_shelf_sync_books(book_ids,options)
    options=options or {}
    local ids={}
    local seen={}
    for _,value in ipairs(type(book_ids)=="table" and book_ids or {}) do
        local id=tostring(value or "")
        if id~="" and not seen[id] then seen[id]=true; ids[#ids+1]=id end
    end
    if #ids==0 then return {books={}} end
    local request_options={
        auth=true,
        retries=options.retries==nil and 0 or options.retries,
        timeout=options.timeout or {8,15},
        pacing_scope="shelf-stream",
        shared_pacing=true,
        min_interval=0.35,
        headers={
            Accept="application/json, text/plain, */*",
            Origin="https://weread.qq.com",
            Referer="https://weread.qq.com/web/shelf",
        },
    }
    return self:_recover_web_once("shelf_batch",function()
        return self.http:post_json("https://weread.qq.com/web/shelf/syncBook",{bookIds=ids},request_options)
    end,options.no_auth_recovery~=true)
end

function Api:shelf_stream(options)
    options=options or {}
    local first_count=math.max(8,math.min(32,tonumber(options.count) or 16))
    local ok_index,index,ids=pcall(self.web_shelf_index,self,{
        retries=0,timeout=options.index_timeout or {7,12},
    })
    if not ok_index then
        local auth_failure=Http.is_auth_error(index)
        if options.allow_full_fallback==false and not auth_failure then
            logger.info("[MiuRead][ShelfStream] index unavailable; cached shelf retained",
                U.first_line(index,160))
            return {_miuread_stream={enabled=false,keep_cache=true,reason="index_unavailable",error=tostring(index)}}
        end
        logger.warn("[MiuRead][ShelfStream] index unavailable; falling back to Agent shelf",
            "auth_failure=",tostring(auth_failure),"error=",U.first_line(index,160))
        local full=self:shelf(options)
        if type(full)=="table" then full._miuread_stream={enabled=false,fallback=true,reason="index_failed"} end
        return full
    end

    local batch_ids={}
    for i=1,math.min(first_count,#ids) do batch_ids[#batch_ids+1]=ids[i] end
    local ok_batch,batch=pcall(self.web_shelf_sync_books,self,batch_ids,{retries=0,timeout={8,15}})
    if not ok_batch or type(batch)~="table" then
        local auth_failure=not ok_batch and Http.is_auth_error(batch)
        if options.allow_full_fallback==false and not auth_failure then
            logger.info("[MiuRead][ShelfStream] first batch unavailable; cached shelf retained",
                U.first_line(batch or "first shelf batch unavailable",160))
            return {_miuread_stream={enabled=false,keep_cache=true,reason="batch_unavailable",error=tostring(batch or "")}}
        end
        logger.warn("[MiuRead][ShelfStream] first batch unavailable; falling back to Agent shelf",
            "auth_failure=",tostring(auth_failure),"error=",U.first_line(batch,160))
        local full=self:shelf(options)
        if type(full)=="table" then full._miuread_stream={enabled=false,fallback=true,reason="batch_failed"} end
        return full
    end

    -- Preserve lightweight grouping/MP metadata when the index happens to expose it.
    if batch.archive==nil and type(index.archive)=="table" then batch.archive=index.archive end
    if batch.mp==nil and type(index.mp)=="table" then batch.mp=index.mp end
    batch._miuread_stream={
        enabled=true,
        ids=ids,
        hydrated_ids=batch_ids,
        total=#ids,
        first_count=#batch_ids,
        has_more=#batch_ids<#ids,
        source="web_onlyBookid+syncBook",
        updated_at=os.time(),
    }
    return batch
end
function Api:notebooks(count, last_sort)
    local params={count=tonumber(count) or 100}
    if tonumber(last_sort or 0) and tonumber(last_sort or 0)~=0 then
        params.lastSort=tonumber(last_sort)
    end
    return self:call("/user/notebooks", params, {retries=1, timeout={10,18}})
end
function Api:bookmark_list(id)
    return self:call("/book/bookmarklist", {bookId=tostring(id or "")}, {retries=1, timeout={10,18}})
end
function Api:review_list_mine(id, synckey, count)
    return self:call("/review/list/mine", {
        bookid=tostring(id or ""), count=tonumber(count) or 100, synckey=tonumber(synckey) or 0,
    }, {retries=1, timeout={10,18}})
end
function Api:search(q, offset, count)
    return self:call("/store/search", {keyword=tostring(q or ""), scope=10, maxIdx=offset or 0, count=count or 30}, {retries=1, timeout={10, 18}})
end
function Api:book(id) return self:call("/book/info", {bookId=tostring(id)}) end
function Api:chapters(id) return self:call("/book/chapterinfo", {bookId=tostring(id)}) end
function Api:progress(id) return self:call("/book/getprogress", {bookId=tostring(id), _t=os.time()}) end
function Api:web_progress(id)
    id=tostring(id or "")
    if id=="" then error("invalid book id") end
    local url="https://weread.qq.com/web/book/getProgress?bookId="
        ..Protocol.escape(id).."&_="..tostring(os.time())..tostring(math.random(1000,9999))
    local request_options={
        auth=true,retries=0,timeout={8,15},
        headers={
            Accept="application/json, text/plain, */*",
            Referer=Protocol.reader_url(id),
            ["Cache-Control"]="no-cache, no-store, max-age=0",
            Pragma="no-cache",
        },
    }
    local data=self:_recover_web_once("progress",function()
        return self.http:get_json(url,request_options)
    end,true)
    if type(data)=="table" then
        data._progress_source="web_cookie"
        data._progress_fetched_at=os.time()
    end
    return data
end

function Api:_chapter_call(name, id, chapter_uid, extra, request_options)
    local last
    local candidates = unique_candidates(chapter_uid)
    if #candidates == 0 then error(name .. ": invalid chapterUid") end
    for _, uid in ipairs(candidates) do
        local payload = U.copy(extra or {})
        payload.bookId = tostring(id)
        payload.chapterUid = uid
        local ok, value = pcall(self.call, self, name, payload, request_options)
        if ok then return value end
        last = value
        if not tostring(value):lower():find("params error%(node%)") then error(value) end
    end
    error(last or (name .. ": params error(node)"))
end

local WEB_ANNOTATION_REQUEST_OPTIONS={
    auth=true,
    retries=1,
    rate_limit_retries=0,
    rate_limit_fail_fast=true,
    rate_limit_cooldown=300,
    rate_limit_scope="annotations-web",
    pacing_scope="annotations-web",
    shared_pacing=true,
    min_interval=0.45,
    pacing_jitter=0.10,
    timeout={10,18},
}

local AGENT_ANNOTATION_REQUEST_OPTIONS={
    retries=0,
    rate_limit_retries=0,
    rate_limit_fail_fast=true,
    rate_limit_cooldown=900,
    rate_limit_scope="annotations-agent",
    pacing_scope="annotations-agent",
    shared_pacing=true,
    -- The Skill Gateway has a much tighter request budget than the web API.
    -- Keeping a little over four seconds between shared requests leaves room
    -- below the observed 30 requests / 100 seconds ceiling.
    min_interval=4.25,
    pacing_jitter=0.35,
    timeout={10,18},
}

local function annotation_headers(id,chapter_uid)
    return {
        Accept="application/json, text/plain, */*",
        Origin="https://weread.qq.com",
        Referer=Protocol.reader_url(id,chapter_uid),
        ["Cache-Control"]="no-cache, no-store, max-age=0",
        Pragma="no-cache",
    }
end

local function annotation_batch_error(value)
    local text=tostring(value or ""):lower()
    return text:find("params error",1,true)~=nil
        or text:find("invalid range",1,true)~=nil
        or text:find("invalid parameter",1,true)~=nil
        or text:find("range error",1,true)~=nil
end

function Api:_web_underlines(id,chapter_uid)
    local last
    local candidates=unique_candidates(chapter_uid)
    if #candidates==0 then error("/web/book/underlines: invalid chapterUid") end
    for _,uid in ipairs(candidates) do
        local url="https://weread.qq.com/web/book/underlines?bookId="
            ..Protocol.escape(tostring(id or "")).."&chapterUid="..Protocol.escape(uid)
        local options=U.copy(WEB_ANNOTATION_REQUEST_OPTIONS)
        options.headers=annotation_headers(id,uid)
        local ok,value=pcall(self.http.get_json,self.http,url,options)
        if ok and type(value)=="table" then
            value._annotation_source="web"
            return value
        end
        last=ok and "web underlines returned invalid data" or value
    end
    error(last or "web underlines failed")
end

local function annotation_write_headers(id, chapter_uid)
    if tostring(id or "") ~= "" and tostring(chapter_uid or "") ~= "" then
        return annotation_headers(id, chapter_uid)
    end
    return {
        Accept="application/json, text/plain, */*",
        Origin="https://weread.qq.com",
        Referer="https://weread.qq.com/",
        ["Cache-Control"]="no-cache, no-store, max-age=0",
        Pragma="no-cache",
    }
end

function Api:_web_annotation_write(path, payload, book_id, chapter_uid)
    payload = sanitize(U.copy(payload or {}))
    path = tostring(path or "")
    if path == "" then error("annotation write path missing") end

    local function request_once()
        return self.http:post_json("https://weread.qq.com" .. path, payload, {
            headers=annotation_write_headers(book_id, chapter_uid),
            -- Write requests are never transport-retried blindly. A lost response
            -- may mean the server already committed the mutation.
            retries=0,
            rate_limit_retries=0,
            timeout={10,18},
            pacing_scope="annotation-write",
            shared_pacing=true,
            min_interval=0.65,
        })
    end

    local ok, data = pcall(request_once)
    local auth_code = not ok and tonumber(Http.auth_error_code(data)) or nil
    if not ok and (auth_code == -2011 or auth_code == -2012) and self.reader
        and type(self.reader._recover_login_session) == "function" then
        local recovered, recover_error = self.reader:_recover_login_session()
        logger.warn("[MiuRead][API] annotation write auth renewal",
            "path=", path, "code=", tostring(auth_code),
            "ok=", tostring(recovered),
            "error=", recovered and "" or tostring(recover_error))
        -- Only the confirmed web-session timeout codes are automatically retried,
        -- and even then only once. Other write failures are left unresolved so a
        -- caller can reconcile with the cloud before deciding to resend.
        if recovered then ok, data = pcall(request_once) end
    end
    if not ok then error(path .. ": " .. tostring(data)) end
    return unwrap(data)
end

function Api:add_bookmark(payload)
    payload = type(payload) == "table" and payload or {}
    -- ADD_BOOKMARK receives plain text inside the Web reader, but the
    -- /web/book/addBookmark wire contract encodes markText as Base64 UTF-8.
    -- Keep the synchronization layer and local database in plain text and
    -- perform the transport encoding only at this API boundary.
    local wire = U.copy(payload)
    local plain = tostring(wire.markText or "")
    wire.markText = Codec.b64encode(plain)
    logger.info("[MiuRead][API] addBookmark wire",
        "type=", tostring(wire.type),
        "chapterIdx=", tostring(wire.chapterIdx),
        "bookVersion=", tostring(wire.bookVersion),
        "markText=base64",
        "plain_chars=", tostring(U.utf8_len(plain)),
        "plain_bytes=", tostring(#plain),
        "wire_bytes=", tostring(#wire.markText))
    return self:_web_annotation_write("/web/book/addBookmark", wire,
        wire.bookId or wire.bookid, wire.chapterUid or wire.chapteruid)
end

function Api:remove_bookmark(bookmark_id, context)
    context = type(context) == "table" and context or {}
    local id = tostring(bookmark_id or "")
    if id == "" then error("bookmarkId missing") end
    return self:_web_annotation_write("/web/book/removeBookmark", {bookmarkId=id},
        context.bookId or context.bookid, context.chapterUid or context.chapteruid)
end

function Api:add_review(payload)
    payload = type(payload) == "table" and payload or {}
    return self:_web_annotation_write("/web/review/add", payload,
        payload.bookId or payload.bookid, payload.chapterUid or payload.chapteruid)
end

function Api:remove_review(payload)
    payload = type(payload) == "table" and payload or {}
    local review_id = tostring(payload.reviewId or payload.review_id or "")
    if review_id == "" then error("reviewId missing") end
    payload.reviewId = review_id
    -- The legacy web bundle exposes this mutation as FETCH_BOOK_REVIEW_DELETE.
    -- Its concrete path is not emitted in clear text in the obfuscated bundle;
    -- `/web/review/delete` follows the companion add/list/single endpoint family.
    -- Keep it on the no-transport-retry write path so a device-side rejection is
    -- harmless: the local tombstone stays pending and no blind second delete runs.
    return self:_web_annotation_write("/web/review/delete", payload,
        payload.bookId or payload.bookid, payload.chapterUid or payload.chapteruid)
end

function Api:_agent_underlines(id,chapter_uid)
    local value=self:_chapter_call("/book/underlines",id,chapter_uid,nil,AGENT_ANNOTATION_REQUEST_OPTIONS)
    if type(value)=="table" then value._annotation_source="agent" end
    return value
end

function Api:underlines(id, chapter_uid)
    if self.web_annotation_auth_dead==true then
        logger.dbg("[MiuRead][API] web underlines skipped; annotation circuit open",
            "book=",tostring(id),"chapter=",tostring(chapter_uid))
        return self:_agent_underlines(id,chapter_uid)
    end
    local ok,value=pcall(self._web_underlines,self,id,chapter_uid)
    if ok then self.web_annotation_auth_dead=false; return value end
    self:_note_web_annotation_failure(value)
    logger.warn("[MiuRead][API] web underlines unavailable; using Skill Gateway",
        "book=",tostring(id),"chapter=",tostring(chapter_uid),"error=",tostring(value))
    return self:_agent_underlines(id,chapter_uid)
end

function Api:review_batches(ranges, batch_size)
    local out = {}
    batch_size = tonumber(batch_size) or 30
    batch_size = math.max(1,math.min(30,math.floor(batch_size)))
    for first = 1, #(ranges or {}), batch_size do
        local batch = {}
        for i = first, math.min(first + batch_size - 1, #ranges) do
            local range = scalar(ranges[i]) or ranges[i]
            batch[#batch + 1] = {range=tostring(range or ""), maxIdx=0, count=30, synckey=0}
        end
        out[#out + 1] = batch
    end
    return out
end

function Api:_web_readreviews(id,chapter_uid,batch)
    local last
    local candidates=unique_candidates(chapter_uid)
    if #candidates==0 then error("/web/book/readReviews: invalid chapterUid") end
    for _,uid in ipairs(candidates) do
        local options=U.copy(WEB_ANNOTATION_REQUEST_OPTIONS)
        options.headers=annotation_headers(id,uid)
        local payload={
            bookId=tostring(id or ""),
            chapterUid=uid,
            reviews=sanitize(batch or {}),
        }
        local ok,value=pcall(self.http.post_json,self.http,
            "https://weread.qq.com/web/book/readReviews",payload,options)
        if ok and type(value)=="table" then
            local has_reviews=type(value.reviews)=="table" or type(value.updated)=="table" or #value>0
            if has_reviews then
                value._annotation_source="web"
                return value
            end
            last="web readReviews returned no review container"
        else
            last=ok and "web readReviews returned invalid data" or value
        end
    end
    error(last or "web readReviews failed")
end

function Api:_agent_readreviews(id,chapter_uid,batch)
    local value=self:_chapter_call("/book/readreviews",id,chapter_uid,
        {reviews=sanitize(batch or {})},AGENT_ANNOTATION_REQUEST_OPTIONS)
    if type(value)~="table" or not (type(value.reviews)=="table" or type(value.updated)=="table" or #value>0) then
        error("/book/readreviews: invalid response without review container")
    end
    value._annotation_source="agent"
    return value
end

local function review_range_key(row)
    if type(row)~="table" then return tostring(scalar(row) or row or "") end
    local value=rawget(row,"range") or rawget(row,"reviewRange") or rawget(row,"rangeKey")
        or rawget(row,"rangeValue")
    local resolved=scalar(value) or value
    return tostring(resolved or "")
end

local function review_container(value)
    if type(value)~="table" then return nil,nil end
    if type(value.reviews)=="table" then return value.reviews,"reviews" end
    if type(value.updated)=="table" then return value.updated,"updated" end
    if #value>0 then return value,false end
    return {},type(value.reviews)=="table" and "reviews" or (type(value.updated)=="table" and "updated" or false)
end

local function missing_review_requests(batch,rows)
    local returned={}
    for _,row in ipairs(type(rows)=="table" and rows or {}) do
        local key=review_range_key(row)
        if key~="" then returned[key]=true end
    end
    local missing={}
    for _,request in ipairs(type(batch)=="table" and batch or {}) do
        local key=review_range_key(request)
        if key~="" and not returned[key] then missing[#missing+1]=request end
    end
    return missing,returned
end

function Api:readreviews(id, chapter_uid, batch)
    if self.web_annotation_auth_dead==true then
        logger.dbg("[MiuRead][API] web readReviews skipped; annotation circuit open",
            "book=",tostring(id),"chapter=",tostring(chapter_uid),"ranges=",tostring(#(batch or {})))
        return self:_agent_readreviews(id,chapter_uid,batch)
    end
    local ok,value=pcall(self._web_readreviews,self,id,chapter_uid,batch)
    if ok then
        self.web_annotation_auth_dead=false
        local rows,container_key=review_container(value)
        local missing=missing_review_requests(batch,rows)
        if #missing>0 then
            -- beta.12: the server omitting a requested range is not equivalent to
            -- an explicit empty result. Verify only the missing ranges through
            -- the older gateway path and merge recovered groups into the web result.
            local agent_ok,agent_value=pcall(self._agent_readreviews,self,id,chapter_uid,missing)
            if agent_ok and type(agent_value)=="table" then
                local agent_rows=select(1,review_container(agent_value)) or {}
                if #agent_rows>0 then
                    if container_key=="reviews" then
                        value.reviews=value.reviews or {}
                        for _,row in ipairs(agent_rows) do value.reviews[#value.reviews+1]=row end
                    elseif container_key=="updated" then
                        value.updated=value.updated or {}
                        for _,row in ipairs(agent_rows) do value.updated[#value.updated+1]=row end
                    else
                        for _,row in ipairs(agent_rows) do value[#value+1]=row end
                    end
                    logger.info("[MiuRead][API] missing readReviews ranges recovered by Skill Gateway",
                        "book=",tostring(id),"chapter=",tostring(chapter_uid),
                        "requested=",tostring(#(batch or {})),"missing=",tostring(#missing),
                        "recovered_groups=",tostring(#agent_rows))
                end
                local merged_rows=select(1,review_container(value)) or {}
                local still_missing=missing_review_requests(batch,merged_rows)
                if #still_missing>0 then
                    value._annotation_missing_ranges={}
                    for _,request in ipairs(still_missing) do
                        value._annotation_missing_ranges[#value._annotation_missing_ranges+1]=review_range_key(request)
                    end
                    value._annotation_agent_empty=(#agent_rows==0) or nil
                    logger.warn("[MiuRead][API] readReviews still omitted requested ranges",
                        "book=",tostring(id),"chapter=",tostring(chapter_uid),
                        "missing=",tostring(#still_missing),"web_groups=",tostring(#rows),
                        "agent_groups=",tostring(#agent_rows))
                end
            else
                value._annotation_agent_error=tostring(agent_value)
                value._annotation_missing_ranges={}
                for _,request in ipairs(missing) do
                    value._annotation_missing_ranges[#value._annotation_missing_ranges+1]=review_range_key(request)
                end
                logger.warn("[MiuRead][API] readReviews missing-range verification failed",
                    "book=",tostring(id),"chapter=",tostring(chapter_uid),
                    "missing=",tostring(#missing),"error=",tostring(agent_value))
            end
        end
        return value
    end
    self:_note_web_annotation_failure(value)
    -- Batch-shape failures must go back to the adaptive splitter. Falling
    -- through to the Skill Gateway would repeat the same rejected payload and
    -- spend the tighter Agent request budget without improving the result.
    if annotation_batch_error(value) then error(value) end
    logger.warn("[MiuRead][API] web readReviews unavailable; using Skill Gateway",
        "book=",tostring(id),"chapter=",tostring(chapter_uid),
        "ranges=",tostring(#(batch or {})),"error=",tostring(value))
    return self:_agent_readreviews(id,chapter_uid,batch)
end

Api._scalar = scalar
Api._sanitize = sanitize
Api._unique_candidates = unique_candidates

return Api
