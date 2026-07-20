local Json = require("miuread.json")
local Protocol = require("miuread.protocol")
local Cookies = require("miuread.cookies")
local Codec = require("miuread.codec")
local Util = require("miuread.util")
local logger = require("logger")
local ok_socket, socket = pcall(require, "socket")

local Reader = {}
Reader.__index = Reader
local BASE = "https://weread.qq.com"

local PART_CSS = [[
.miu-part-page {
    min-height: 78vh;
    display: block;
    text-align: center;
    page-break-before: always;
    break-before: page;
}
.miu-part-page .miu-part-title {
    margin: 34vh 0 0 0;
    font-size: 1.9em;
    font-weight: bold;
    line-height: 1.4;
    text-align: center;
}
]]

local function pause(seconds)
    if ok_socket and socket and type(socket.sleep) == "function" then
        socket.sleep(seconds)
    end
end

local function scalar(value)
    if type(value) == "string" or type(value) == "number" then return value end
end

local function optional_value(value)
    value = scalar(value)
    if value == nil then return nil end
    value = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    local lower = value:lower()
    if value == "" or lower == "null" or lower == "undefined" then return nil end
    return value
end

local function find_context(value, depth, seen)
    if type(value) ~= "table" or (depth or 0) > 7 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local psvts = optional_value(value.psvts)
    local pclts = optional_value(value.pclts)
    local token = optional_value(value.token)
    if psvts or pclts or token then
        return {psvts=psvts, pclts=pclts, token=token, book=value.bookInfo or value.book or {}}
    end
    for _, key in ipairs({"reader", "data", "result", "state", "readerState", "initialState", "payload", "book"}) do
        local found = find_context(value[key], (depth or 0) + 1, seen)
        if found then return found end
    end
    for _, item in pairs(value) do
        if type(item) == "table" then
            local found = find_context(item, (depth or 0) + 1, seen)
            if found then return found end
        end
    end
end

local function regex_context(html)
    return {
        psvts = optional_value(html:match('"psvts"%s*:%s*"([^"]+)"') or html:match('"psvts"%s*:%s*(%d+)')),
        pclts = optional_value(html:match('"pclts"%s*:%s*"([^"]+)"') or html:match('"pclts"%s*:%s*(%d+)')),
        token = optional_value(html:match('"token"%s*:%s*"([^"]+)"')),
        book = {},
    }
end

local function catalog_records(data)
    local current = data
    for _ = 1, 4 do
        if type(current) ~= "table" then break end
        if current.bookId or current.updated or current.chapterInfos or current.chapters then return {current} end
        if #current > 0 then return current end
        local next_value = current.data or current.result or current.payload
        if type(next_value) ~= "table" then break end
        current = next_value
    end
    return type(current) == "table" and current or {}
end

local function visible_text(html)
    return tostring(html or ""):gsub("<script.-</script>", " "):gsub("<style.-</style>", " ")
        :gsub("<[^>]+>", " "):gsub("&[%#%w]+;", " "):gsub("%s+", "")
end

local function compact_title(value)
    return tostring(value or ""):gsub("<[^>]+>", ""):gsub("[%s%p%c]", "")
end

local function truthy(value)
    return value == true or value == 1 or value == "1" or value == "true"
end

local function is_structure_chapter(chapter)
    chapter = type(chapter) == "table" and chapter or {}
    if truthy(chapter.isPart) or truthy(chapter.isVolume) or truthy(chapter.isTitle)
        or truthy(chapter.isSection) or truthy(chapter.isDivider)
        or truthy(chapter._miuread_has_children) or truthy(chapter.hasChildren) then
        return true
    end

    local child_count = tonumber(chapter.childCount or chapter.childrenCount or chapter.subChapterCount or 0) or 0
    if child_count > 0 then return true end

    local kind = tostring(chapter.chapterType or chapter.chapter_type or chapter.typeName or chapter.nodeType or ""):lower()
    if kind:find("part", 1, true) or kind:find("volume", 1, true)
        or kind:find("divider", 1, true) or kind:find("section_title", 1, true)
        or kind:find("season", 1, true) then
        return true
    end

    local title = compact_title(chapter.title)
    if title == "" then return false end

    -- These checks are used only after the server successfully returned an
    -- empty decoded body in both EPUB and TXT formats. They therefore identify
    -- intentional title pages rather than masking network or authentication
    -- failures.
    if title:sub(1, #"第") == "第" then
        for _, marker in ipairs({"部", "卷", "编", "篇", "辑", "册", "季"}) do
            local pos = title:find(marker, #"第" + 1, true)
            if pos and pos <= 30 then return true end
        end
    end
    if title:find("第[%d一二三四五六七八九十百零〇两]+季") then return true end

    local exact = {
        ["上部"]=true, ["中部"]=true, ["下部"]=true,
        ["上卷"]=true, ["中卷"]=true, ["下卷"]=true,
        ["上篇"]=true, ["中篇"]=true, ["下篇"]=true,
        ["上编"]=true, ["中编"]=true, ["下编"]=true,
        ["前篇"]=true, ["后篇"]=true,
        ["序"]=true, ["序言"]=true, ["前言"]=true, ["引言"]=true,
        ["楔子"]=true, ["尾声"]=true, ["后记"]=true, ["致谢"]=true,
        ["鸣谢"]=true, ["附录"]=true, ["参考文献"]=true,
        ["封底"]=true, ["扉页"]=true, ["版权页"]=true, ["版权信息"]=true, ["目录"]=true,
    }
    return exact[title] == true
end

local function structure_xhtml(title)
    return '<div class="miu-part-page" data-miuread-structure="1"><h1 class="miu-part-title">'
        .. Util.xml(title or "分部") .. "</h1></div>"
end

local function is_empty_error(value)
    local text = tostring(value or ""):lower()
    return text:find("decoded epub chapter is empty", 1, true)
        or text:find("decoded txt chapter is empty", 1, true)
        or text:find("returned empty content", 1, true)
        or text:find("chapter content is empty", 1, true)
end

local function is_auth_error(value)
    local text = tostring(value or ""):lower()
    return text:find("http 401", 1, true) or text:find("http 403", 1, true)
        or text:find("login expired", 1, true) or text:find("login timeout", 1, true)
        or text:find("session expired", 1, true) or text:find("not logged", 1, true)
        or text:find("未登录", 1, true) or text:find("登录过期", 1, true)
        or text:find("登录超时", 1, true) or text:find("登录失效", 1, true)
end

local function is_replaced_session_error(value)
    local text = tostring(value or ""):lower()
    return text:find("另一台设备", 1, true)
        or text:find("服务端未识别当前用户", 1, true)
        or text:find("error_code=-2012", 1, true)
end


local function image_trim(value)
    return tostring(value or ""):gsub("&amp;", "&"):gsub("^%s+", ""):gsub("%s+$", "")
end

local function image_url_decode(value)
    return tostring(value or ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

local function image_basename(value)
    local clean = tostring(value or ""):gsub("\\", "/"):gsub("/+$", "")
    return clean:match("([^/]+)$") or clean
end

local function image_source_keys(value)
    local clean = image_trim(value)
    local path = clean:match("^[^%?#]+") or clean
    local remote_path = path:match("^https?://[^/]+(/.*)$") or path:match("^//[^/]+(/.*)$")
    path = remote_path or path
    while path:sub(1, 3) == "../" do path = path:sub(4) end
    while path:sub(1, 2) == "./" do path = path:sub(3) end
    path = path:gsub("^/+", "")

    local decoded_path = image_url_decode(path)
    local base = image_basename(path)
    local decoded_base = image_basename(decoded_path)
    local candidates = {path, decoded_path, base, decoded_base}
    for _, candidate in ipairs({path, decoded_path}) do
        local parts = {}
        for part in tostring(candidate or ""):gmatch("[^/]+") do parts[#parts + 1] = part end
        for depth = 2, math.min(4, #parts) do
            local suffix = {}
            for index = #parts - depth + 1, #parts do suffix[#suffix + 1] = parts[index] end
            candidates[#candidates + 1] = table.concat(suffix, "/")
        end
    end
    local out, seen = {}, {}
    for _, key in ipairs(candidates) do
        key = tostring(key or ""):lower()
        if key ~= "" and not seen[key] then
            seen[key] = true
            out[#out + 1] = key
        end
    end
    return out
end

local function image_map_add(source_map, source, href)
    for _, key in ipairs(image_source_keys(source)) do
        if source_map[key] == nil then
            source_map[key] = href
        elseif source_map[key] ~= href then
            source_map[key] = false
        end
    end
end

local function image_map_get(source_map, source)
    for _, key in ipairs(image_source_keys(source)) do
        local href = source_map[key]
        if href then return href end
    end
end

local function image_attr(attrs, name_pattern)
    attrs = tostring(attrs or "")
    local _, value = attrs:match("%s" .. name_pattern .. "%s*=%s*([\"'])(.-)%1")
    if value ~= nil then return value end
    _, value = attrs:match("^" .. name_pattern .. "%s*=%s*([\"'])(.-)%1")
    return value
end

local function image_remove_attr(attrs, name_pattern)
    attrs = tostring(attrs or "")
    attrs = attrs:gsub("%s" .. name_pattern .. "%s*=%s*([\"'])(.-)%1", "")
    attrs = attrs:gsub("^" .. name_pattern .. "%s*=%s*([\"'])(.-)%1%s*", "")
    return attrs
end

local function image_set_local_src(attrs, href)
    attrs = image_remove_attr(attrs, "src")
    for _, name in ipairs({"data%-src", "data%-original", "data%-lazy%-src", "data%-actualsrc", "srcset"}) do
        attrs = image_remove_attr(attrs, name)
    end
    return ' src="' .. tostring(href or "") .. '"' .. attrs
end

local function image_remote_url(value)
    local url = image_trim(value)
    if url:sub(1, 2) == "//" then url = "https:" .. url end
    if url:match("^https?://") then return url end
end

local function image_used_hrefs(assets)
    local used = {}
    for _, asset in ipairs(assets or {}) do used[tostring(asset.href or "")] = true end
    return used
end

local function image_unique_href(used, prefix, index, ext)
    local candidate = string.format("images/%s-%04d%s", prefix, index, ext)
    while used[candidate] do
        index = index + 1
        candidate = string.format("images/%s-%04d%s", prefix, index, ext)
    end
    used[candidate] = true
    return candidate, index
end

local function image_tar_assets(blob)
    local entries = Codec.tar(blob)
    local names = {}
    for name in pairs(entries or {}) do names[#names + 1] = name end
    table.sort(names)

    local assets, source_map, used = {}, {}, {}
    local index = 0
    for _, name in ipairs(names) do
        local data = entries[name]
        local ext, mime = Codec.media(data, name)
        if tostring(mime):match("^image/") and data and #data > 0 then
            index = index + 1
            local href
            href, index = image_unique_href(used, "tar", index, ext)
            assets[#assets + 1] = {href=href, data=data, mime=mime, source=name}
            local local_src = "../" .. href
            image_map_add(source_map, name, local_src)
            image_map_add(source_map, image_basename(name), local_src)
        end
    end
    return assets, source_map
end

local function localize_epub_images(reader, xhtml, assets, source_map, state)
    assets = assets or {}
    source_map = source_map or {}
    local used = image_used_hrefs(assets)
    local remote_cache, remote_failed = {}, {}
    local remote_index = #assets
    local summary = {tar=#assets, remote=0, localized=0, missing=0}

    local function download_remote(url)
        if remote_cache[url] then return remote_cache[url] end
        if remote_failed[url] then return nil end
        local ok, data = pcall(reader.http.download, reader.http, url, {
            headers={
                Referer=(state and state.url) or BASE .. "/",
                Origin=BASE,
                Accept="image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
            },
            retries=2,
            timeout={12, 25},
        })
        if not ok or not data or #data == 0 then
            remote_failed[url] = true
            logger.warn("[MiuRead][Reader] remote image failed", "url=", tostring(url), "error=", ok and "empty" or tostring(data))
            return nil
        end
        local ext, mime = Codec.media(data, url)
        if not tostring(mime):match("^image/") then
            remote_failed[url] = true
            logger.warn("[MiuRead][Reader] remote asset is not an image", "url=", tostring(url), "mime=", tostring(mime))
            return nil
        end
        remote_index = remote_index + 1
        local href
        href, remote_index = image_unique_href(used, "remote", remote_index, ext)
        assets[#assets + 1] = {href=href, data=data, mime=mime, source=url}
        local local_src = "../" .. href
        remote_cache[url] = local_src
        image_map_add(source_map, url, local_src)
        summary.remote = summary.remote + 1
        return local_src
    end

    xhtml = tostring(xhtml or ""):gsub("<[iI][mM][gG]([^>]*)>", function(attrs)
        local srcset = image_attr(attrs, "srcset")
        local source = image_attr(attrs, "data%-src")
            or image_attr(attrs, "data%-original")
            or image_attr(attrs, "data%-lazy%-src")
            or image_attr(attrs, "data%-actualsrc")
            or image_attr(attrs, "src")
            or (srcset and srcset:match("^%s*([^,%s]+)"))
        local clean_source = image_trim(source)
        if clean_source == "" then return "<img" .. attrs .. ">" end
        if clean_source:lower():match("^data:image/") then return "<img" .. attrs .. ">" end

        local local_src = image_map_get(source_map, clean_source)
        if not local_src then
            local url = image_remote_url(clean_source)
            if url then local_src = download_remote(url) end
        end
        if local_src then
            summary.localized = summary.localized + 1
            return "<img" .. image_set_local_src(attrs, local_src) .. ">"
        end

        summary.missing = summary.missing + 1
        logger.warn("[MiuRead][Reader] image reference unresolved", "src=", tostring(clean_source))
        return "<img" .. attrs .. ">"
    end)

    return xhtml, assets, summary
end

function Reader:new(http, store)
    return setmetatable({http=http, store=store, _renewing_session=false}, self)
end

function Reader:renew()
    local data, _, meta = self.http:post_json(BASE .. "/web/login/renewal", {rq="%2Fweb%2Fbook%2Fread", ql=false},
        {headers={Origin=BASE, Referer=BASE .. "/", Accept="application/json, text/plain, */*"}, retries=2})
    return data, meta
end

function Reader:_recover_login_session()
    if self._renewing_session then return false, "登录状态正在续期" end
    self._renewing_session=true

    local renewed, renew_result=pcall(self.renew,self)
    if not renewed then
        logger.warn("[MiuRead][Reader] cookie renewal failed", tostring(renew_result))
        local repaired, repair_result=pcall(self.repair_login_session,self)
        if repaired then
            renewed, renew_result=pcall(self.renew,self)
        else
            renew_result=tostring(renew_result).."; repair="..tostring(repair_result)
        end
    end

    self._renewing_session=false
    if renewed then
        logger.info("[MiuRead][Reader] login session renewed")
        return true
    end
    return false, renew_result
end

function Reader:state(book_id, chapter_uid)
    local url = Protocol.is_mp(book_id) and Protocol.mp_reader_url(book_id) or Protocol.reader_url(book_id, chapter_uid)
    local html = self.http:download(url, {headers={Accept="text/html,application/xhtml+xml"}, retries=3})
    -- 0.3.6.7 used the top-level reader-page fields directly. Prefer that
    -- exact path before recursively searching nested JSON nodes, which may
    -- contain stale preview/session objects with different tokens.
    local context = regex_context(html)
    if not optional_value(context.psvts) then
        local raw = Util.extract_balanced_json(html, "window.__INITIAL_STATE__")
            or Util.extract_balanced_json(html, "__INITIAL_STATE__")
        if raw then
            local ok, data = pcall(Json.decode, raw)
            if ok then context = find_context(data) or context end
        end
    end
    context.url = url
    if not optional_value(context.psvts) then error("reader.psvts not found") end
    return context
end

function Reader:catalog(book_id)
    local function load_catalog()
        local data = self.http:post_json(BASE .. "/web/book/chapterInfos", {bookIds={tostring(book_id)}},
            {headers={Origin=BASE, Referer=Protocol.reader_url(book_id)}, retries=3})
        local records = catalog_records(data)
        for _, record in ipairs(records or {}) do
            if tostring(record.bookId or "") == tostring(book_id) then return record end
        end
        if #records == 1 and type(records[1]) == "table" then return records[1] end
        error("book catalog not returned")
    end

    local ok, result=pcall(load_catalog)
    if ok then return result end
    if is_auth_error(result) then
        local renewed, renew_error=self:_recover_login_session()
        logger.warn("[MiuRead][Reader] catalog authentication recovery", "ok=", tostring(renewed),
            "error=", renewed and "" or tostring(renew_error))
        if renewed then
            local retry_ok, retry_result=pcall(load_catalog)
            if retry_ok then return retry_result end
            error(retry_result)
        end
        error(tostring(result).."; 自动续期失败："..tostring(renew_error))
    end
    error(result)
end

function Reader:shard(path, book_id, chapter_uid, psvts, style)
    local body = Protocol.content_fields(book_id, chapter_uid, psvts, style)
    local raw, code = self.http:request{
        url=BASE .. path, method="POST", body=Json.encode(body), retries=3,
        headers={Origin=BASE, Referer=Protocol.reader_url(book_id, chapter_uid), ["Content-Type"]="application/json;charset=UTF-8"},
    }
    if code < 200 or code >= 300 then error(path .. " failed: HTTP " .. tostring(code)) end
    if not raw or raw == "{}" or #raw < 8 then error(path .. " returned empty content") end
    return raw
end

function Reader:_txt_once(book, chapter, opt, state)
    opt = opt or {}
    local id = tostring(book.bookId or book.book_id)
    local uid = chapter.chapterUid or chapter.uid
    state = state or self:state(id, uid)
    local a = self:shard("/web/book/chapter/t_0", id, uid, state.psvts, false)
    local ok_b, b = pcall(self.shard, self, "/web/book/chapter/t_1", id, uid, state.psvts, false)
    if not ok_b then b = "" end
    local xhtml = Codec.text_xhtml(Codec.decode_parts({a, b}))
    if #visible_text(xhtml) < 8 then error("decoded TXT chapter is empty") end
    state.content_format = "txt"
    return xhtml, "body{line-height:1.75;margin:5%;}", {}, state
end

function Reader:_epub_once(book, chapter, opt, state)
    opt = opt or {}
    local id = tostring(book.bookId or book.book_id)
    local uid = chapter.chapterUid or chapter.uid
    state = state or self:state(id, uid)

    local a = self:shard("/web/book/chapter/e_0", id, uid, state.psvts, false)
    if a:match("^%s*{") and a:find('"bookId"', 1, true) then
        return self:_txt_once(book, chapter, opt, state)
    end
    local b = self:shard("/web/book/chapter/e_1", id, uid, state.psvts, false)
    local c = self:shard("/web/book/chapter/e_3", id, uid, state.psvts, false)
    local xhtml = Codec.decode_parts({a, b, c})
    if #visible_text(xhtml) < 8 then error("decoded EPUB chapter is empty") end

    local css = "body{line-height:1.7;margin:5%;}img{max-width:100%;height:auto;}"
    local ok_style, style_raw = pcall(self.shard, self, "/web/book/chapter/e_2", id, uid, state.psvts, true)
    if ok_style and not style_raw:match("^%s*{") then
        local ok, value = pcall(Codec.decode_parts, {style_raw})
        if ok and value ~= "" then css = value end
    end

    local assets = {}
    if opt.images ~= false then
        local source_map = {}
        local tar_url = chapter.tar
        if tar_url and tar_url ~= "" then
            tar_url = tostring(tar_url)
            if tar_url:sub(1, 2) == "//" then
                tar_url = "https:" .. tar_url
            elseif tar_url:sub(1, 1) == "/" then
                tar_url = BASE .. tar_url
            end
            local ok_tar, blob = pcall(self.http.download, self.http, tar_url, {
                headers={Referer=state.url, Origin=BASE, Accept="application/octet-stream,*/*"},
                retries=3,
            })
            if ok_tar and blob and #blob > 0 then
                local tar_assets, tar_map = image_tar_assets(blob)
                for _, asset in ipairs(tar_assets) do assets[#assets + 1] = asset end
                for key, href in pairs(tar_map) do source_map[key] = href end
            else
                logger.warn("[MiuRead][Reader] chapter image archive failed", "chapter=", tostring(uid),
                    "url=", tostring(tar_url), "error=", ok_tar and "empty" or tostring(blob))
            end
        end
        xhtml, assets, state.image_summary = localize_epub_images(self, xhtml, assets, source_map, state)
        logger.info("[MiuRead][Reader] chapter images", "chapter=", tostring(uid),
            "tar=", tostring(state.image_summary.tar), "remote=", tostring(state.image_summary.remote),
            "localized=", tostring(state.image_summary.localized), "missing=", tostring(state.image_summary.missing))
    end
    state.content_format = "epub"
    return xhtml, css, assets, state
end

function Reader:_chapter_once(book, chapter, format, opt)
    opt = opt or {}
    local id = tostring(book.bookId or book.book_id)
    local uid = chapter.chapterUid or chapter.uid
    local state = self:state(id, uid)

    if format == "txt" then
        local ok, a, b, c, d = pcall(self._txt_once, self, book, chapter, opt, state)
        if ok then return a, b, c, d end
        if is_structure_chapter(chapter) and is_empty_error(a) then
            state.content_format = "structure"
            state.structural = true
            logger.info("[MiuRead][Reader] structure page generated", "chapter=", tostring(uid), "title=", tostring(chapter.title or ""))
            return structure_xhtml(chapter.title), PART_CSS, {}, state
        end
        error(a)
    end

    local ok, a, b, c, d = pcall(self._epub_once, self, book, chapter, opt, state)
    if ok then return a, b, c, d end
    local epub_error = a
    if not is_empty_error(epub_error) then error(epub_error) end

    logger.warn("[MiuRead][Reader] EPUB content empty; trying TXT fallback", "chapter=", tostring(uid), "title=", tostring(chapter.title or ""))
    local txt_ok, ta, tb, tc, td = pcall(self._txt_once, self, book, chapter, opt, state)
    if txt_ok then return ta, tb, tc, td end
    if is_structure_chapter(chapter) and is_empty_error(ta) and not is_auth_error(ta) then
        state.content_format = "structure"
        state.structural = true
        logger.info("[MiuRead][Reader] structure page generated", "chapter=", tostring(uid), "title=", tostring(chapter.title or ""), "txt_fallback=", tostring(ta))
        return structure_xhtml(chapter.title), PART_CSS, {}, state
    end
    error(tostring(epub_error) .. "; TXT fallback: " .. tostring(ta))
end

function Reader:chapter(book, chapter, format, opt)
    local last, renewed = nil, false
    for attempt = 1, 3 do
        local ok, a, b, c, d = pcall(self._chapter_once, self, book, chapter, format, opt)
        if ok then return a, b, c, d end
        last = a
        logger.warn("[MiuRead][Reader] chapter retry", "chapter=", tostring(chapter.chapterUid or chapter.uid),
            "attempt=", tostring(attempt), "error=", tostring(a))
        if is_replaced_session_error(a) then
            -- Do not rotate the account session automatically. On two devices
            -- that would make them repeatedly invalidate each other.
            break
        elseif is_auth_error(a) and not renewed then
            renewed = true
            local renew_ok, renew_error = self:_recover_login_session()
            logger.warn("[MiuRead][Reader] authentication renewal", "ok=", tostring(renew_ok),
                "error=", renew_ok and "" or tostring(renew_error))
            if not renew_ok then
                last=tostring(a).."; 自动续期失败："..tostring(renew_error)
                break
            end
        end
        if attempt < 3 then pause(attempt == 1 and 0.8 or 1.8) end
    end
    error(last or "chapter download failed")
end

function Reader:mp_articles(book_id)
    local all, offset = {}, 0
    for _ = 1, 30 do
        local data = self.http:get_json(BASE .. "/web/mp/articles?bookId=" .. Protocol.escape(book_id) .. "&offset=" .. tostring(offset), {headers={Referer=Protocol.mp_reader_url(book_id)}, retries=3})
        local groups = data.reviews or {}
        if #groups == 0 then break end
        for _, group in ipairs(groups) do
            for _, item in ipairs(group.subReviews or {}) do
                local review = item.review or item
                local mp = review.mpInfo or {}
                all[#all + 1] = {reviewId=review.reviewId, title=mp.title or "文章", cover=mp.pic_url, createTime=review.createTime}
            end
        end
        offset = offset + #groups
        if #groups < 10 then break end
    end
    return all
end

function Reader:mp_content(review_id)
    local html = self.http:download(BASE .. "/web/mp/content?reviewId=" .. Protocol.escape(review_id), {headers={Referer=BASE .. "/"}, retries=3})
    return Codec.mp_body(html)
end

local function response_header(headers, name)
    local target = tostring(name or ""):lower()
    for key, value in pairs(headers or {}) do
        if tostring(key):lower() == target then return value end
    end
end

-- Repair QR-login web cookies using the authenticated follow-up flow from
-- the working 0.3.6.7 build. Only stable wr_ / ptcz / RK / pgv_pvid cookies
-- are retained; browser-session cookies are deliberately discarded.
function Reader:repair_login_session()
    local auth = self.store:auth()
    local jar = Util.copy(auth.cookies or {})
    local account = auth.account or {}
    local vid = tostring(jar.wr_vid or account.vid or account.user_vid or "")
    local skey = tostring(jar.wr_skey or "")
    if vid == "" or skey == "" then error("QR login credentials are incomplete") end

    local function headers()
        return {
            Accept = "application/json, text/plain, */*",
            Referer = BASE .. "/r/weread-skills",
            Cookie = Cookies.header(jar),
            ["X-Vid"] = vid,
            ["X-Skey"] = skey,
        }
    end

    local user, user_headers = self.http:get_json(
        BASE .. "/api/userInfo?userVid=" .. Protocol.escape(vid),
        {auth=false, headers=headers(), retries=1}
    )
    jar = Cookies.absorb(jar, response_header(user_headers, "set-cookie"))

    local skill, skill_headers = self.http:get_json(
        BASE .. "/api/skills/apikeyGet?only_show=1",
        {auth=false, headers=headers(), retries=1}
    )
    jar = Cookies.absorb(jar, response_header(skill_headers, "set-cookie"))

    auth.cookies = jar
    if type(skill) == "table" and tostring(skill.apikey or "") ~= "" then
        auth.api_key = tostring(skill.apikey)
    end
    auth.account = Util.merge(account, {
        name = tostring(type(user) == "table" and user.name or account.name or ""),
        vid = vid,
    })
    self.store:save_auth(auth)
    return {repaired=true, cookie_count=(function()
        local n=0; for _ in pairs(jar) do n=n+1 end; return n
    end)()}
end

function Reader:report_payload(payload, referer, retries)
    local data, _, meta = self.http:post_json(BASE .. "/web/book/read", payload,
        {headers={Origin=BASE, Referer=referer or BASE .. "/",
            Accept="application/json, text/plain, */*"}, retries=tonumber(retries) or 0})
    return data, meta
end

function Reader:report(book_id, chapter_uid, opt)
    opt = opt or {}
    local session = opt.session or self.store:session(book_id) or {}
    local payload = Protocol.read_fields{
        book_id=book_id, chapter_uid=chapter_uid, chapter_index=opt.chapter_index,
        chapter_offset=opt.offset, progress=opt.progress, elapsed=opt.elapsed,
        summary=opt.summary, psvts=optional_value(session.psvts), pclts=optional_value(session.pclts), token=optional_value(session.token),
        app_id=session.app_id, user_agent=Protocol.USER_AGENT,
    }
    return self:report_payload(payload, session.reader_url or Protocol.reader_url(book_id), 0)
end

Reader._visible_text = visible_text
Reader._is_structure_chapter = is_structure_chapter
Reader._is_empty_error = is_empty_error
Reader._is_auth_error = is_auth_error
Reader._image_source_keys = image_source_keys
Reader._image_tar_assets = image_tar_assets
Reader._localize_epub_images = localize_epub_images
Reader.PART_CSS = PART_CSS

return Reader
