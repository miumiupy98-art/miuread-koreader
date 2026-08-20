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
    return setmetatable({http = http, store = store, reader = reader}, self)
end

function Api:call(name, params, request_options)
    local payload = sanitize(U.copy(params or {}))
    payload.api_name = tostring(name)
    payload.skill_version = Protocol.SKILL_VERSION

    local function request_once()
        local auth = self.store:auth()
        if tostring(auth.api_key or "") == "" then error("API key is not configured") end
        local options = U.copy(request_options or {})
        options.auth = false
        options.headers = options.headers or {}
        options.headers.Authorization = "Bearer " .. tostring(auth.api_key)
        if options.retries == nil then options.retries = 2 end
        return self.http:post_json("https://i.weread.qq.com/api/agent/gateway", payload, options)
    end

    local ok, data = pcall(request_once)
    local annotation_endpoint=tostring(name)=="/book/underlines" or tostring(name)=="/book/readreviews"
    if not ok and not annotation_endpoint and Http.is_auth_error(data) and self.reader then
        local recovered, recover_error = self.reader:_recover_login_session()
        logger.warn("[MiuRead][API] authentication recovery",
            "api=", tostring(name), "ok=", tostring(recovered),
            "error=", recovered and "" or tostring(recover_error))
        if recovered then ok, data = pcall(request_once) end
    end
    if not ok then error(tostring(name) .. ": " .. tostring(data)) end
    return unwrap(data)
end

function Api:shelf(options)
    options=options or {}
    return self:call("/shelf/sync", {}, {
        retries=options.retries==nil and 1 or options.retries,
        timeout=options.timeout or {10,18},
    })
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
    local data=self.http:get_json(url,{
        auth=true,retries=0,timeout={8,15},
        headers={
            Accept="application/json, text/plain, */*",
            Referer=Protocol.reader_url(id),
            ["Cache-Control"]="no-cache, no-store, max-age=0",
            Pragma="no-cache",
        },
    })
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
    local ok,value=pcall(self._web_underlines,self,id,chapter_uid)
    if ok then return value end
    logger.warn("[MiuRead][API] web underlines unavailable; using Skill Gateway",
        "book=",tostring(id),"chapter=",tostring(chapter_uid),"error=",tostring(value))
    return self:_agent_underlines(id,chapter_uid)
end

function Api:review_batches(ranges, batch_size)
    local out = {}
    batch_size = tonumber(batch_size) or 5
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

local function normalize_annotation_payload(data)
    if type(data) ~= "table" then return data end
    if type(data.reviews) == "table" or type(data.updated) == "table" then
        return data
    end
    local current = data
    for _ = 1, 4 do
        if type(current.reviews) == "table" or type(current.updated) == "table" then
            return current
        end
        local nested = type(current.data) == "table" and current.data
            or type(current.result) == "table" and current.result
            or type(current.payload) == "table" and current.payload
        if not nested then break end
        current = nested
    end
    return unwrap(data)
end

local function review_payload_groups(data)
    if type(data) ~= "table" then return {} end
    local raw
    for _, name in ipairs({"reviews", "updated", "reviewList", "items"}) do
        if type(data[name]) == "table" then raw = data[name]; break end
    end
    if not raw and #data > 0 then raw = data end
    if type(raw) ~= "table" then return {} end

    local groups = {}
    if #raw > 0 then
        for _, item in ipairs(raw) do
            if type(item) == "table" then groups[#groups + 1] = item end
        end
        return groups
    end
    for key, item in pairs(raw) do
        if type(item) == "table" then
            local group = item
            local range = tostring(group.range or group.markRange or group.bookmarkRange or "")
            if range == "" and tostring(key):match("^%d+%-%d+$") then
                group = U.copy(item)
                group.range = tostring(key)
            end
            groups[#groups + 1] = group
        end
    end
    return groups
end

local function annotation_payload_rows_count(data)
    return #review_payload_groups(data)
end

local function review_entry_count_in_group(group)
    if type(group) ~= "table" then return 0 end
    local count = 0
    local pages = group.pageReviews or group.page_reviews
    if type(pages) == "table" then
        for _, page in ipairs(pages) do
            if type(page) == "table" then
                local review = type(page.review) == "table" and page.review or page
                local text = tostring(review.content or review.abstract or review.contextAbstract
                    or review.text or review.reviewContent or "")
                if text ~= "" then count = count + 1 end
            end
        end
    end
    if count > 0 then return count end
    local review = type(group.review) == "table" and group.review or group
    local text = tostring(review.content or review.abstract or review.contextAbstract
        or review.text or review.reviewContent or "")
    return text ~= "" and 1 or 0
end

local function annotation_payload_review_entries(data)
    local total = 0
    for _, group in ipairs(review_payload_groups(data)) do
        total = total + review_entry_count_in_group(group)
    end
    return total
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
            value=normalize_annotation_payload(value)
            value._annotation_source="web"
            return value
        end
        last=ok and "web readReviews returned invalid data" or value
    end
    error(last or "web readReviews failed")
end

function Api:_agent_readreviews(id,chapter_uid,batch)
    local value=self:_chapter_call("/book/readreviews",id,chapter_uid,
        {reviews=sanitize(batch or {})},AGENT_ANNOTATION_REQUEST_OPTIONS)
    if type(value)=="table" then value._annotation_source="agent" end
    return value
end

function Api:readreviews(id, chapter_uid, batch)
    local ok,value=pcall(self._web_readreviews,self,id,chapter_uid,batch)
    if ok then
        -- Some accounts occasionally get an empty-but-successful web payload
        -- while the Skill Gateway still returns the actual review groups.
        -- Prefer the richer source when web returns no usable rows.
        local web_rows = annotation_payload_rows_count(value)
        local web_entries = annotation_payload_review_entries(value)
        logger.warn("[MiuRead][API] readReviews web payload",
            "book=", tostring(id), "chapter=", tostring(chapter_uid),
            "ranges=", tostring(#(batch or {})),
            "rows=", tostring(web_rows), "entries=", tostring(web_entries))
        if web_entries > 0 then return value end
        local agent_ok, agent_value = pcall(self._agent_readreviews, self, id, chapter_uid, batch)
        local agent_rows = agent_ok and annotation_payload_rows_count(agent_value) or 0
        local agent_entries = agent_ok and annotation_payload_review_entries(agent_value) or 0
        logger.warn("[MiuRead][API] readReviews agent fallback",
            "book=", tostring(id), "chapter=", tostring(chapter_uid),
            "ranges=", tostring(#(batch or {})),
            "ok=", tostring(agent_ok),
            "rows=", tostring(agent_rows), "entries=", tostring(agent_entries))
        if agent_ok and agent_entries > 0 then
            logger.warn("[MiuRead][API] web readReviews empty; using Skill Gateway payload",
                "book=", tostring(id), "chapter=", tostring(chapter_uid),
                "ranges=", tostring(#(batch or {})))
            return agent_value
        end
        return value
    end
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
