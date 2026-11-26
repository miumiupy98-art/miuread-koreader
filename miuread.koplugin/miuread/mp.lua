local Json = require("miuread.json")
local Codec = require("miuread.codec")
local Digests = require("miuread.digests")
local Protocol = require("miuread.protocol")
local U = require("miuread.util")
local Http = require("miuread.http")
local Library = require("miuread.library")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local MP = {}
MP.__index = MP

local BASE = "https://weread.qq.com"
local CACHE_SCHEMA = 3
local LIST_TTL = 6 * 60 * 60
local ARTICLE_LIMIT = 100
local FEED_LIMIT = 250
local FEED_TITLES = {[0]="文章收藏", [1]="微信浮窗文章"}
local FEED_PREFIX = "MP_WXS_EINK_"

local function account_vid(auth)
    local vid=tostring((auth.account or {}).vid or "")
    return vid~="" and vid or tostring((auth.cookies or {}).wr_vid or "")
end

local ARTICLE_CSS = [[
html, body {
  color: #000 !important;
  font-size: 1em !important;
  line-height: 1.7;
  margin: 0;
  padding: 0;
  -webkit-text-size-adjust: 100%;
  text-size-adjust: 100%;
}
body { margin: 0 !important; padding: 0 !important; }
body * {
  color: inherit !important;
  font-family: inherit !important;
  line-height: inherit !important;
}
img {
  display: inline !important;
  max-width: 100%;
  height: auto;
  margin: .2em 0 !important;
  vertical-align: middle;
  page-break-before: auto !important;
  page-break-after: auto !important;
  break-before: auto !important;
  break-after: auto !important;
}
h1 { font-size: 1.35em !important; line-height: 1.35 !important; margin: 0 0 1em; }
p { margin: .25em 0 !important; }
]]

local function scalar(value)
    if type(value) == "string" or type(value) == "number" then return tostring(value) end
    return ""
end

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function safe_filename(value)
    local name = U.id_name(value)
    return name ~= "" and name or "article"
end

local function plain(value)
    return tostring(value or "")
        :gsub("<script[%s%S]-</script>", " ")
        :gsub("<style[%s%S]-</style>", " ")
        :gsub("<[^>]+>", " ")
        :gsub("&[%#%w]+;", " ")
        :gsub("%s+", " ")
end

local function has_readable_body(body)
    body = tostring(body or "")
    return #trim(plain(body)) >= 8 or body:lower():find("<img", 1, true) ~= nil
end

local function parse_articles(data)
    local articles = {}
    local seen = {}
    for _, group in ipairs(type(data) == "table" and data.reviews or {}) do
        for _, sub in ipairs(type(group.subReviews) == "table" and group.subReviews or {}) do
            local review = type(sub.review) == "table" and sub.review or sub
            local info = type(review.mpInfo) == "table" and review.mpInfo or {}
            local review_ids, id_seen = {}, {}
            local function add_id(value)
                value = scalar(value)
                if value ~= "" and not id_seen[value] then
                    id_seen[value] = true
                    review_ids[#review_ids + 1] = value
                end
            end
            add_id(sub.reviewId)
            add_id(review.reviewId)
            add_id(info.originalId)
            local primary = scalar(review.reviewId or sub.reviewId or info.originalId)
            if primary ~= "" and not seen[primary] then
                seen[primary] = true
                articles[#articles + 1] = {
                    reviewId = primary,
                    reviewIds = review_ids,
                    originalId = scalar(info.originalId),
                    bookId = scalar(review.belongBookId or sub.belongBookId or info.bookId),
                    sourceUrl = scalar(info.content_url or info.contentUrl or info.source_url or info.sourceUrl
                        or info.url or review.content_url or review.contentUrl or review.source_url
                        or review.sourceUrl or review.url),
                    title = scalar(info.title) ~= "" and scalar(info.title) or "文章",
                    cover = info.pic_url or info.picUrl,
                    accountName = scalar(info.accountName or info.author or info.mpName or info.nickName
                        or review.accountName or review.author or group.accountName),
                    createTime = tonumber(review.createTime or group.createTime or 0) or 0,
                }
            end
        end
    end
    table.sort(articles, function(a, b)
        local at = tonumber(a.createTime or 0) or 0
        local bt = tonumber(b.createTime or 0) or 0
        if at ~= bt then return at > bt end
        return tostring(a.title or "") < tostring(b.title or "")
    end)
    return articles
end

-- Public originals must contain the WeChat article container. Paid responses
-- already contain a body fragment supplied by the E-Ink API.
local function extract_mp_body(html, public_original)
    if type(html)~="string" or #html>8*1024*1024 then return nil end
    local body
    if public_original then
        local normalized=html:gsub("<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]%s*>","")
            :gsub("<!%-%-.-%-%->","")
        for tag,last in normalized:gmatch('(<[dD][iI][vV]%s[^>]*>)()') do
            local _,id=tag:match('%s+id%s*=%s*(["\'])(.-)%1')
            local _,class=tag:match('%s+class%s*=%s*(["\'])(.-)%1')
            if id=="js_content" or (class and (" "..class.." "):find(" rich_media_content ",1,true)) then
                local depth=1
                for sub_start,closing in normalized:sub(last):gmatch('()<(/?)[dD][iI][vV]%f[%s>][^>]*>') do
                    depth=depth+(closing=="/" and -1 or 1)
                    if depth==0 then
                        body=normalized:sub(last,last+sub_start-2)
                        break
                    end
                end
                if body then break end
            end
        end
    else
        body=Codec.body(html)
    end
    if not body or body=="" then return nil end
    for _,tag in ipairs({"script","style","iframe","object","form"}) do
        body=body:gsub("<"..tag.."%f[%s>][^>]*>.-</"..tag.."%s*>","")
    end
    return body:gsub("<[iI][mM][gG]%s[^>]*>",function(tag)
        local _,lazy=tag:match('%sdata%-src%s*=%s*(["\'])(.-)%1')
        local _,src=tag:match('%ssrc%s*=%s*(["\'])(.-)%1')
        src=lazy and lazy~="" and lazy or src
        if not src or src=="" then return "" end
        return '<img src="'..src:gsub('"','&quot;')..'"/>'
    end)
end

local function strip_mp_reader_font_styles(html)
    local blocked = {
        ["font"] = true, ["font-family"] = true, ["line-height"] = true,
        ["color"] = true, ["-webkit-text-fill-color"] = true, ["opacity"] = true,
        ["page-break-before"] = true, ["page-break-after"] = true,
        ["page-break-inside"] = true, ["break-before"] = true,
        ["break-after"] = true, ["break-inside"] = true,
        ["text-size-adjust"] = true, ["-webkit-text-size-adjust"] = true,
    }

    local function relative_heading_size(value)
        local lower = tostring(value or ""):lower():gsub("%s*!important%s*$", "")
        local px = tonumber(lower:match("^%s*([%d%.]+)%s*px%s*$"))
        if px then return px >= 18 and string.format("%.2fem", px / 16) or nil end
        local pt = tonumber(lower:match("^%s*([%d%.]+)%s*pt%s*$"))
        if pt then return pt >= 13.5 and string.format("%.2fem", pt / 12) or nil end
        local rem = tonumber(lower:match("^%s*([%d%.]+)%s*rem%s*$"))
        if rem then return rem > 1.05 and string.format("%.2fem", rem) or nil end
        local em = tonumber(lower:match("^%s*([%d%.]+)%s*em%s*$"))
        if em then return em > 1.05 and string.format("%.2fem", em) or nil end
        local percent = tonumber(lower:match("^%s*([%d%.]+)%s*%%%s*$"))
        if percent then return percent > 105 and string.format("%.0f%%", percent) or nil end
        local keyword = lower:match("^%s*(.-)%s*$")
        if keyword == "large" or keyword == "larger" or keyword == "x-large" or keyword == "xx-large" then
            return keyword
        end
    end

    return tostring(html or ""):gsub('style=(["\'])(.-)%1', function(quote, style)
        local kept = {}
        for decl in style:gmatch("[^;]+") do
            local name, value = decl:match("^%s*([^:]+)%s*:%s*(.-)%s*$")
            if name and value then
                local property = name:lower()
                if property == "font-size" then
                    local heading_size = relative_heading_size(value)
                    if heading_size then kept[#kept + 1] = "font-size: " .. heading_size end
                elseif not blocked[property] then
                    kept[#kept + 1] = name .. ": " .. value
                end
            end
        end
        if #kept == 0 then return "" end
        return "style=" .. quote .. table.concat(kept, "; ") .. quote
    end)
end

local function strip_mp_images(html)
    html = tostring(html or "")
    html = html:gsub("<[pP][iI][cC][tT][uU][rR][eE][^>]*>.-</[pP][iI][cC][tT][uU][rR][eE]%s*>", "")
    html = html:gsub("<[iI][mM][gG][^>]*>", "")
    html = html:gsub("</[iI][mM][gG]%s*>", "")
    html = html:gsub("<[sS][oO][uU][rR][cC][eE][^>]*>", "")
    return html
end

local function strip_blank_mp_blocks(html)
    html = tostring(html or "")
    html = html:gsub("<mp%-common%-profile[^>]->.-</mp%-common%-profile>", "")
    html = html:gsub("<mp%-style%-type[^>]->.-</mp%-style%-type>", "")
    html = html:gsub("<[bB][rR]%s*/?%s*>", "<br/>")
    html = html:gsub("&nbsp;", " "):gsub("&#160;", " "):gsub("&#x[aA]0;", " "):gsub("\194\160", " ")
    for _ = 1, 12 do
        local previous = html
        for _, tag in ipairs({"a", "span", "p", "section", "div", "figure", "picture"}) do
            html = html:gsub("<" .. tag .. "[^>]->%s*<br/>%s*</" .. tag .. ">", "")
            html = html:gsub("<" .. tag .. "[^>]->%s*</" .. tag .. ">", "")
        end
        if html == previous then break end
    end
    for _ = 1, 4 do
        local updated = html:gsub("(%s*<br/>%s*)%s*<br/>%s*", "<br/>")
        if updated == html then break end
        html = updated
    end
    return html:gsub("\n%s*\n%s*\n+", "\n\n")
end

function MP:new(reader, http, store, api)
    return setmetatable({reader=reader, http=http, store=store, api=api}, self)
end

function MP:_accounts_path()
    return self.store:mp_root() .. "/accounts.json"
end

function MP:_account_dir(book_id)
    return self.store:mp_account_dir(book_id)
end

function MP:_list_path(book_id)
    return self:_account_dir(book_id) .. "/articles.json"
end

function MP:_article_dir(book_id, article_id)
    local root = self:_account_dir(book_id) .. "/articles"
    U.mkdir(root)
    local id = self:is_native_feed(book_id)
        and Digests.sha256(tostring(article_id or "")) or safe_filename(article_id)
    return root .. "/" .. id
end

function MP:cached_accounts()
    local raw = U.read_file(self:_accounts_path(), true)
    if not raw then return {}, 0 end
    local ok, value = pcall(Json.decode, raw)
    if not ok or type(value) ~= "table" then return {}, 0 end
    return type(value.accounts) == "table" and value.accounts or {}, tonumber(value.updated_at or 0) or 0
end

function MP:accounts_stale(ttl)
    local accounts, updated = self:cached_accounts()
    return #accounts == 0 or os.time() - updated > (tonumber(ttl) or LIST_TTL)
end

function MP:_save_accounts(accounts)
    local payload = {schema=CACHE_SCHEMA, updated_at=os.time(), accounts=accounts or {}}
    local ok, err = U.atomic_write(self:_accounts_path(), Json.encode(payload), true)
    if not ok then error("公众号列表无法保存：" .. tostring(err or "")) end
    return accounts or {}
end

function MP:_fetch_accounts()
    local data = self.api:shelf({retries=1, timeout={10,18}})
    local parser = Library:new(self.api, self.http, self.store)
    local _, mp_rows = parser:normalize(data)
    local accounts = {}
    for _, row in ipairs(mp_rows or {}) do
        local id = tostring(row.bookId or row.book_id or "")
        if Protocol.is_mp_account(id) then
            local copy = U.copy(row)
            copy.bookId = id
            copy.title = trim(copy.title) ~= "" and trim(copy.title) or "公众号"
            copy.author = trim(copy.author) ~= "" and trim(copy.author) or "公众号"
            copy.content_type = "mp_account"
            copy.is_mp_account = true
            accounts[#accounts + 1] = copy
        end
    end
    return accounts
end

function MP:accounts(options)
    options = options or {}
    local cached = self:cached_accounts()
    if options.force ~= true and #cached > 0 then return cached end
    local ok, accounts = pcall(self._fetch_accounts, self)
    if not ok and Http.is_auth_error(accounts) then
        local recovered, recover_error = pcall(self.reader._recover_login_session, self.reader)
        logger.warn("[MiuRead][MP] shelf authentication recovery",
            "ok=", tostring(recovered), "error=", recovered and "" or tostring(recover_error))
        if recovered then ok, accounts = pcall(self._fetch_accounts, self) end
    end
    if not ok then
        if #cached > 0 then return cached end
        error(accounts)
    end
    return self:_save_accounts(accounts)
end

function MP:is_native_feed(book_id)
    return tostring(book_id or ""):sub(1,#FEED_PREFIX)==FEED_PREFIX
end

function MP:native_feed_book(kind)
    local vid=account_vid(self.store:auth())
    if not FEED_TITLES[kind] or vid=="" then return nil end
    return {bookId=FEED_PREFIX..Digests.sha256(vid).."_"..kind,title=FEED_TITLES[kind]}
end

function MP:native_feed(kind,more)
    local bucket=self:native_feed_book(kind)
    if not bucket then error("请先登录微信读书",0) end
    local vid=account_vid(self.store:auth())
    local old_rows,_,old=self:cached_articles(bucket.bookId)
    old=old or {}
    local cursor=more and tonumber(old.cursor) or nil
    if more and (old.more~=true or not cursor or cursor<=0) then return old end
    local payload,show_wechat=self.api:mp_list(kind,cursor,cursor and old.show_wechat or nil)
    local rows,positions,removed={}, {}, {}
    local next_cursor,received,recognized=nil,0,false
    if type(payload.removedKeys)=="table" and not Json.is_null(payload.removedKeys) then
        recognized=true
        for _,key in ipairs(payload.removedKeys) do removed[tostring(key)]=true end
    end
    if cursor then
        for _,item in ipairs(old_rows) do
            if not removed[item.key] then
                rows[#rows+1]=item
                positions[item.reviewId]=#rows
            end
        end
    end
    for _,field in ipairs({"lists","data","updated"}) do
        local list=payload[field]
        if list~=nil then
            recognized=true
            if Json.is_null(list) then list={} end
            if type(list)~="table" then error("公众号文章列表格式无效",0) end
            for _,item in ipairs(list) do
                local id=type(item)=="table" and scalar(item.reviewId) or ""
                if id=="" then error("公众号文章缺少编号",0) end
                local previous=rows[positions[id] or 0] or {}
                local idx=tonumber(item.idx or previous.idx or 0)
                if not idx or idx<0 or idx%1~=0 then error("公众号文章排序值无效",0) end
                received=received+1
                if idx>0 then next_cursor=math.min(next_cursor or idx,idx) end
                local row=U.merge(previous,{
                    idx=idx,reviewId=id,bookId=bucket.bookId,
                    title=item.title~=nil and scalar(item.title) or previous.title or "文章",
                    accountName=item.account~=nil and scalar(item.account) or previous.accountName,
                    key=item.key~=nil and scalar(item.key) or previous.key,
                })
                if not removed[row.key] then
                    if not positions[id] then positions[id]=#rows+1 end
                    rows[positions[id]]=row
                end
            end
        end
    end
    if not recognized then error("未取得公众号文章列表",0) end
    local order={}
    for index,item in ipairs(rows) do order[item.reviewId]=index end
    table.sort(rows,function(a,b)
        if a.idx~=b.idx then return a.idx>b.idx end
        return order[a.reviewId]<order[b.reviewId]
    end)
    local more_pages=payload.continueFlag==true or tonumber(payload.continueFlag)==1
        or (payload.continueFlag==nil and received>=50)
    while #rows>FEED_LIMIT do rows[#rows]=nil end
    local result={schema=CACHE_SCHEMA,bookId=bucket.bookId,title=bucket.title,articles=rows,updated_at=os.time(),
        show_wechat=show_wechat,cursor=next_cursor,more=more_pages and next_cursor~=nil
            and (not cursor or next_cursor<cursor) and #rows<FEED_LIMIT}
    local persisted=self.store:read_persisted("auth")
    if not persisted or account_vid(persisted)~=vid then error("账号已切换，请重新打开文章列表",0) end
    local saved=U.atomic_write(self:_list_path(bucket.bookId),Json.encode(result),true)
    if not saved then error("公众号文章列表无法保存",0) end
    return result
end

function MP:cached_articles(book_id)
    local raw = U.read_file(self:_list_path(book_id), true)
    if not raw then return {}, 0 end
    local ok, value = pcall(Json.decode, raw)
    if not ok or type(value) ~= "table" then return {}, 0 end
    return type(value.articles) == "table" and value.articles or {}, tonumber(value.updated_at or 0) or 0, value
end

function MP:list_stale(book_id, ttl)
    local articles, updated = self:cached_articles(book_id)
    return #articles == 0 or os.time() - updated > (tonumber(ttl) or LIST_TTL)
end

function MP:_save_articles(book_id, title, articles)
    local payload = {
        schema=CACHE_SCHEMA, updated_at=os.time(), bookId=tostring(book_id),
        title=tostring(title or "公众号"), articles=articles or {},
    }
    local ok, err = U.atomic_write(self:_list_path(book_id), Json.encode(payload), true)
    if not ok then error("公众号文章列表无法保存：" .. tostring(err or "")) end
    return articles or {}
end

function MP:_article_headers()
    local auth = self.store:auth()
    local headers = {Accept="application/json, text/plain, */*", Referer=BASE .. "/"}
    if tostring(auth.wr_ticket or "") ~= "" then headers["x-wr-ticket"] = tostring(auth.wr_ticket) end
    if tostring(auth.wr_wrpa or "") ~= "" then headers["x-wrpa-0"] = tostring(auth.wr_wrpa) end
    return headers
end

function MP:_request_articles(book_id)
    local url = BASE .. "/web/mp/articles?bookId=" .. Protocol.escape(book_id)
        .. "&maxIdx=0&count=" .. tostring(ARTICLE_LIMIT)
    return self.http:get_json(url, {
        auth=true, headers=self:_article_headers(), retries=2, timeout={10,25},
    })
end

function MP:_fetch_articles(book_id)
    local ok, data = pcall(self._request_articles, self, book_id)
    if not ok and Http.is_auth_error(data) then
        local renewed, renew_error = pcall(self.reader.renew, self.reader)
        logger.warn("[MiuRead][MP] article-list credential renewal",
            "ok=", tostring(renewed), "error=", renewed and "" or tostring(renew_error))
        if renewed then ok, data = pcall(self._request_articles, self, book_id) end
    end
    if not ok and Http.is_auth_error(data) then
        local recovered, recover_error = pcall(self.reader._recover_login_session, self.reader)
        logger.warn("[MiuRead][MP] article-list login recovery",
            "ok=", tostring(recovered), "error=", recovered and "" or tostring(recover_error))
        if recovered then
            pcall(self.reader.renew, self.reader)
            ok, data = pcall(self._request_articles, self, book_id)
        end
    end
    if not ok then error(data) end
    return parse_articles(data)
end

function MP:articles(book_id, options)
    options = options or {}
    book_id = tostring(book_id or "")
    if not Protocol.is_mp_account(book_id) then
        error("[MiuReadMPNoAccount] 微信读书书架没有返回可用的公众号")
    end
    local cached = self:cached_articles(book_id)
    if options.force ~= true and #cached > 0 then return cached end
    local ok, articles = pcall(self._fetch_articles, self, book_id)
    if not ok then
        if #cached > 0 then return cached end
        error(articles)
    end
    local account_title = tostring(options.title or "")
    for _, article in ipairs(articles) do
        if tostring(article.bookId or "") == "" then article.bookId = book_id end
        if tostring(article.accountName or "") == "" and account_title ~= "" then article.accountName = account_title end
    end
    return self:_save_articles(book_id, account_title, articles)
end

function MP:_load_article_record(book_id, article_id)
    local dir = self:_article_dir(book_id, article_id)
    local raw = U.read_file(dir .. "/metadata.json", true)
    if not raw then return nil end
    local ok, record = pcall(Json.decode, raw)
    if not ok or type(record) ~= "table" or record.complete ~= true then return nil end
    if record.account_scope then
        local vid=account_vid(self.store:auth())
        if vid=="" or record.account_scope~=Digests.sha256(vid) then return nil end
    end
    record.dir = dir
    record.file = dir .. "/article.html"
    record.body_path = dir .. "/body.xhtml"
    if not U.file_exists(record.file) then return nil end
    return record
end

function MP:article_record(book_id, article)
    local id = type(article) == "table" and (article.reviewId or article.originalId) or article
    return self:_load_article_record(book_id, id)
end

function MP:_content_candidates(article)
    local out, seen = {}, {}
    local function add(value)
        value = scalar(value)
        if value ~= "" and not seen[value] then seen[value] = true; out[#out + 1] = value end
    end
    add(article.reviewId)
    for _, value in ipairs(article.reviewIds or {}) do add(value) end
    add(article.originalId)
    add(tostring(article.reviewId or ""):match("^MP_WXS_%d+_(.+)$"))
    return out
end

function MP:_fetch_raw_content(book_id, article)
    local candidates=self:_content_candidates(article)
    if self:is_native_feed(book_id) then candidates={article.reviewId} end
    local last_error
    for _,id in ipairs(candidates) do
        local ok,html,public_original=pcall(self.api.mp_content,self.api,id)
        if ok and type(html)=="string" and trim(html)~="" then return html,id,public_original end
        last_error=not ok and html or "文章正文为空"
        if Http.is_auth_error(last_error) or Http.is_rate_limit_error(last_error)
            or tostring(last_error):find("付费文章",1,true) or tostring(last_error):find("下架",1,true) then break end
    end
    error(last_error or "文章正文为空",0)
end

local function mp_image_url(src)
    src=tostring(src or ""):gsub("&amp;","&")
    if src:sub(1,2)=="//" then src="https:"..src end
    src=src:gsub("^http://","https://")
    if not src:match("^https://mmbiz%.qpic%.cn/") and not src:match("^https://mmbiz%.qlogo%.cn/") then return nil end
    return src
end

function MP:_localize_images(body, enabled, stage, progress, previous)
    if not enabled then return strip_mp_images(body), 0, 0, {} end
    local total = 0
    tostring(body or ""):gsub('src=(["\'])(.-)%1', function(_, src)
        if mp_image_url(src) then total = total + 1 end
    end)
    if total == 0 then return strip_mp_images(body), 0, 0, {} end

    local image_dir = tostring(stage) .. "/images"
    U.mkdir(image_dir)
    local reusable={}
    if type(previous)=="table" and type(previous.image_sources)=="table" and previous.dir then
        for _,item in ipairs(previous.image_sources) do
            local source=tostring(type(item)=="table" and item.source or "")
            local file=tostring(type(item)=="table" and item.file or "")
            local full=file~="" and (tostring(previous.dir).."/"..file) or ""
            if source~="" and full~="" and U.file_exists(full) then reusable[source]={file=file,full=full,mime=item.mime} end
        end
    end
    local index, failed, requests = 0, 0, 0
    local started=os.time()
    local cache, sources = {}, {}
    local output = tostring(body or ""):gsub('src=(["\'])(.-)%1', function(quote, src)
        local url = mp_image_url(src)
        if not url then return 'src=""' end
        index = index + 1
        if progress then progress(index, total, src) end

        local cached = cache[url]
        if cached then
            sources[#sources + 1] = {source=url, file=cached}
            return "src=" .. quote .. cached .. quote
        end

        local old=reusable[url]
        if old then
            local ext=tostring(old.file or ""):match("(%.[%w]+)$") or ".bin"
            local relative_path="images/"..string.format("%04d",index)..ext
            local copied,copy_error=U.copy_file_stream(old.full,tostring(stage).."/"..relative_path)
            if copied then
                cache[url]=relative_path
                sources[#sources+1]={source=url,file=relative_path,mime=old.mime,reused=true}
                return "src="..quote..relative_path..quote
            end
            logger.warn("[MiuRead][MP] cached image reuse failed","index=",tostring(index),"error=",tostring(copy_error))
        end

        if requests>=32 or os.time()-started>=65 then
            failed=failed+1
            return 'src=""'
        end
        requests=requests+1
        local ok, data = pcall(self.http.download, self.http, url, {
            auth=false,
            headers={Referer=BASE .. "/", Accept="image/avif,image/webp,image/*,*/*"},
            redirects=0,retries=1,timeout={4,8},
        })
        if not ok or type(data) ~= "string" or #data == 0 then
            failed = failed + 1
            logger.warn("[MiuRead][MP] article image failed", "index=", tostring(index), "error=", ok and "empty" or tostring(data))
            return 'src=""'
        end

        local ext, mime = Codec.media(data, url)
        if not tostring(mime or ""):match("^image/") then
            failed = failed + 1
            logger.warn("[MiuRead][MP] article asset is not an image", "index=", tostring(index), "mime=", tostring(mime))
            data = nil
            collectgarbage("collect")
            return 'src=""'
        end
        local relative_path = "images/" .. string.format("%04d", index) .. tostring(ext or ".bin")
        local wrote, write_error = U.atomic_write(tostring(stage) .. "/" .. relative_path, data, true)
        data = nil
        if not wrote then error("公众号图片缓存写入失败：" .. tostring(write_error or relative_path)) end
        cache[url] = relative_path
        sources[#sources + 1] = {source=url, file=relative_path, mime=mime}
        collectgarbage("collect")
        return "src=" .. quote .. relative_path .. quote
    end)
    output=output:gsub('<img src=""%s*/?>',"")
    return output, total, failed, sources
end

function MP:fetch_article(book, article, options)
    options = options or {}
    book = type(book) == "table" and book or {bookId=book}
    article = type(article) == "table" and U.copy(article) or {reviewId=article, title="文章"}
    local book_id = tostring(book.bookId or book.book_id or article.bookId or "")
    local article_id = tostring(article.reviewId or article.originalId or "")
    if not Protocol.is_mp_account(book_id) or article_id == "" then error("公众号文章标识缺失") end

    local auth_vid=account_vid(self.store:auth())
    local is_feed=self:is_native_feed(book_id)
    if is_feed and (auth_vid=="" or not book_id:match("^"..FEED_PREFIX..Digests.sha256(auth_vid).."_[01]$")) then
        error("账号已切换，请重新打开文章列表",0)
    end
    local cached = self:_load_article_record(book_id, article_id)
    local cached_schema=tonumber(cached and cached.schema or 0) or 0
    local cache_matches=options.images==true
        and cached_schema>=CACHE_SCHEMA and cached and cached.images_enabled==true
        and cached.images_complete~=false and tonumber(cached.failed_images or 0)==0
        or (options.images~=true and cached and cached.images_enabled~=true)
    if cached and options.force~=true and cache_matches then return cached end

    local root = self:_account_dir(book_id) .. "/articles"
    U.mkdir(root)
    local stamp = tostring(os.time()) .. "-" .. tostring(math.random(10000,99999))
    local stage = root .. "/.stage-" .. safe_filename(article_id) .. "-" .. stamp
    U.remove_tree(stage)
    U.mkdir(stage)

    local ok, result = xpcall(function()
        local html, used_id, public_original = self:_fetch_raw_content(book_id, article)
        local body = extract_mp_body(html, public_original)
        if not body or not has_readable_body(body) then error("文章正文为空或无法识别") end
        body = strip_mp_reader_font_styles(body)
        body = strip_blank_mp_blocks(body)
        local image_count, failed_images, image_sources
        body, image_count, failed_images, image_sources = self:_localize_images(
            body, options.images == true, stage, options.progress, cached)
        body = strip_blank_mp_blocks(body)
        if not has_readable_body(body) then error("文章正文处理后为空") end

        local title = tostring(article.title or "文章")
        local wrapper = '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"/><title>'
            .. U.xml(title) .. '</title><style>' .. ARTICLE_CSS .. '</style></head><body><h1>'
            .. U.xml(title) .. '</h1>' .. body .. '</body></html>'
        local wrote_html, html_error = U.atomic_write(stage .. "/article.html", wrapper, true)
        if not wrote_html then error("文章文件写入失败：" .. tostring(html_error or "")) end
        -- Keep body.xhtml for cache readers and future migrations. Article
        -- images live beside the HTML and are loaded by relative file paths, so
        -- large illustrated articles do not expand into a huge Base64 string.
        local wrote_body, body_error = U.atomic_write(stage .. "/body.xhtml", body, true)
        if not wrote_body then error("文章正文缓存写入失败：" .. tostring(body_error or "")) end
        local metadata = {
            schema=CACHE_SCHEMA, complete=true, bookId=book_id,
            account_scope=(is_feed or public_original==false) and Digests.sha256(auth_vid) or nil,
            account_title=tostring(book.title or article.accountName or "公众号"),
            reviewId=article_id, usedReviewId=used_id, title=title,
            createTime=tonumber(article.createTime or 0) or 0,
            sourceUrl=article.sourceUrl, accountName=article.accountName,
            image_count=image_count, failed_images=failed_images,
            image_sources=image_sources, images_enabled=options.images == true,
            images_complete=options.images ~= true or failed_images == 0, updated_at=os.time(),
        }
        local wrote_meta, meta_error = U.atomic_write(stage .. "/metadata.json", Json.encode(metadata), true)
        if not wrote_meta then error("文章缓存记录写入失败：" .. tostring(meta_error or "")) end
        return metadata
    end, debug.traceback)

    if not ok then U.remove_tree(stage); error(result) end
    if result.account_scope then
        local persisted=self.store:read_persisted("auth")
        if auth_vid=="" or not persisted or account_vid(persisted)~=auth_vid then
            U.remove_tree(stage)
            error("账号已切换，请重新打开文章列表",0)
        end
    end
    local target = self:_article_dir(book_id, article_id)
    local backup = target .. ".backup-" .. stamp
    U.remove_tree(backup)
    if lfs.attributes(target, "mode") == "directory" then
        local moved = os.rename(target, backup)
        if not moved then U.remove_tree(stage); error("无法保护旧文章缓存") end
    end
    local installed = os.rename(stage, target)
    if not installed then
        if lfs.attributes(backup, "mode") == "directory" then os.rename(backup, target) end
        U.remove_tree(stage)
        error("文章缓存安装失败")
    end
    U.remove_tree(backup)
    return self:_load_article_record(book_id, article_id)
end

function MP:identify_path(path)
    path = tostring(path or "")
    if path == "" or path:sub(1, #self.store.mp_dir + 1) ~= self.store.mp_dir .. "/" then return nil end
    local dir = path:match("^(.*)/article%.html$")
    if not dir then return nil end
    local raw = U.read_file(dir .. "/metadata.json", true)
    if not raw then return nil end
    local ok, value = pcall(Json.decode, raw)
    if not ok or type(value) ~= "table" or value.complete ~= true then return nil end
    local book_id=tostring(value.bookId or "")
    if value.account_scope or self:is_native_feed(book_id) then
        local vid=account_vid(self.store:auth())
        if vid=="" then return nil end
        local scope=Digests.sha256(vid)
        if value.account_scope and value.account_scope~=scope then return nil end
        if self:is_native_feed(book_id) and not book_id:match("^"..FEED_PREFIX..scope.."_[01]$") then return nil end
    end
    value.file = path
    value.dir = dir
    return value
end

function MP:clear_article(book_id, article)
    local id = type(article) == "table" and (article.reviewId or article.originalId) or article
    return U.remove_tree(self:_article_dir(book_id, id))
end

function MP:clear_account(book_id)
    return U.remove_tree(self:_account_dir(book_id))
end

MP.ARTICLE_CSS = ARTICLE_CSS
MP.parse_articles = parse_articles
MP.extract_mp_body = extract_mp_body
MP.strip_mp_images = strip_mp_images
MP.strip_mp_reader_font_styles = strip_mp_reader_font_styles
MP.strip_blank_mp_blocks = strip_blank_mp_blocks

return MP
