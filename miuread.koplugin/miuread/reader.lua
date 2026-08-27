local Json = require("miuread.json")
local Protocol = require("miuread.protocol")
local Cookies = require("miuread.cookies")
local Http = require("miuread.http")
local Codec = require("miuread.codec")
local AnnotationCoord = require("miuread.annotation_coord")
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
        return {psvts=psvts, pclts=pclts, token=token, book=value.bookInfo or value.book or {}, source=value}
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

local function positive_number(value)
    local n = tonumber(value)
    if n and n > 0 then return n end
end

-- Locate the version belonging to the requested book, not an unrelated
-- `version` field elsewhere in the reader bootstrap payload.
local function find_book_version(value, book_id, depth, seen)
    if type(value) ~= "table" or (depth or 0) > 8 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true

    local id = tostring(value.bookId or value.book_id or "")
    if id ~= "" and id == tostring(book_id or "") then
        local version = positive_number(value.bookVersion or value.book_version or value.version)
        if version then return version end
    end

    for _, key in ipairs({"bookInfo", "book"}) do
        local child = value[key]
        if type(child) == "table" then
            local child_id = tostring(child.bookId or child.book_id or book_id or "")
            if child_id == tostring(book_id or "") then
                local version = positive_number(child.bookVersion or child.book_version or child.version)
                if version then return version end
            end
        end
    end

    for _, child in pairs(value) do
        if type(child) == "table" then
            local version = find_book_version(child, book_id, (depth or 0) + 1, seen)
            if version then return version end
        end
    end
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
    return kind:find("part", 1, true) ~= nil
        or kind:find("volume", 1, true) ~= nil
        or kind:find("divider", 1, true) ~= nil
        or kind:find("section_title", 1, true) ~= nil
        or kind:find("season", 1, true) ~= nil
end

local function is_cover_chapter(chapter)
    chapter = type(chapter) == "table" and chapter or {}
    if truthy(chapter.isCover) or truthy(chapter.cover) then return true end
    local kind = tostring(chapter.chapterType or chapter.chapter_type or chapter.typeName or chapter.nodeType or ""):lower()
    if kind == "cover" or kind:find("cover_page", 1, true) then return true end
    return tostring(chapter.title or ""):gsub("%s+", "") == "封面"
end

local function is_unavailable_chapter(chapter)
    chapter = type(chapter) == "table" and chapter or {}
    if truthy(chapter.isDeleted) or truthy(chapter.deleted) or truthy(chapter.isRemoved)
        or truthy(chapter.isHidden) or truthy(chapter.unavailable) then
        return true
    end
    local status = tostring(chapter.status or chapter.chapterStatus or chapter.state or ""):lower()
    return status == "deleted" or status == "removed" or status == "hidden" or status == "unavailable"
end

local function has_content_markup(html)
    local value = tostring(html or ""):lower()
    return value:find("<img", 1, true) ~= nil
        or value:find("<svg", 1, true) ~= nil
        or value:find("<image", 1, true) ~= nil
        or value:find("<math", 1, true) ~= nil
        or value:find("<table", 1, true) ~= nil
        or value:find("<audio", 1, true) ~= nil
        or value:find("<video", 1, true) ~= nil
end

local function has_readable_content(html, allow_markup)
    if #visible_text(html) > 0 then return true end
    return allow_markup == true and has_content_markup(html)
end

local CONFIRMED_EMPTY = "__MIUREAD_CONFIRMED_EMPTY__"

local function structure_xhtml(title)
    return '<div class="miu-part-page" data-miuread-structure="1"><h1 class="miu-part-title">'
        .. Util.xml(title or "分部") .. "</h1></div>"
end

local function image_only_xhtml(assets)
    local rows = {'<div class="miu-image-only-page" data-miuread-image-only="1">'}
    for _, asset in ipairs(assets or {}) do
        local href = tostring(asset.href or "")
        if href ~= "" then
            rows[#rows + 1] = '<p class="miu-image-only-item"><img src="../' .. Util.xml(href) .. '" alt="" /></p>'
        end
    end
    rows[#rows + 1] = "</div>"
    return table.concat(rows, "\n")
end

local function readable_text_length(html)
    return #visible_text(html)
end

local function is_empty_error(value)
    local text = tostring(value or ""):lower()
    return text:find("decoded epub chapter is empty", 1, true)
        or text:find("decoded txt chapter is empty", 1, true)
        or text:find("returned empty content", 1, true)
        or text:find("chapter content is empty", 1, true)
end

local function is_confirmed_empty_error(value)
    return tostring(value or ""):find(CONFIRMED_EMPTY, 1, true) ~= nil
end

local function is_auth_error(value)
    return Http.is_auth_error(value)
end

-- Only explicit service-side permission messages are treated as preview or
-- entitlement limits. Network, login and decoding failures must never be
-- downgraded into a preview book.
local function is_access_denied_error(value)
    if is_auth_error(value) then return false end
    local text=tostring(value or "")
    local lower=text:lower()
    local markers={
        "permission denied", "access denied", "not authorized", "not authorised",
        "not entitled", "purchase required", "preview only", "trial only",
        "subscription required", "membership required", "not available for reading",
    }
    for _,marker in ipairs(markers) do
        if lower:find(marker,1,true) then return true end
    end
    local zh={
        "无阅读权限", "没有阅读权限", "暂无阅读权限", "无权阅读",
        "仅支持试读", "仅可试读", "只能试读", "试读结束",
        "需要购买", "请购买后阅读", "购买后可读",
        "会员已过期", "会员到期", "需要会员", "开通会员后阅读",
        "不在可读范围", "本章暂不可读", "该章节暂不可读",
    }
    for _,marker in ipairs(zh) do
        if text:find(marker,1,true) then return true end
    end
    return false
end

local function login_page_error(html, final_url)
    local url = tostring(final_url or ""):lower()
    if url:find("/web/login", 1, true) or url:find("/web/confirm", 1, true)
        or url:find("/r/weread%-skills") then
        return Http.auth_error_message("reader_redirect", "reader page redirected to login")
    end
    local head = tostring(html or ""):sub(1, 8192)
    local lower = head:lower()
    if lower:find('"errcode":-2012', 1, true)
        or lower:find('"errcode": -2012', 1, true)
        or lower:find('"err_code":-2012', 1, true)
        or lower:find("login_timeout", 1, true)
        or lower:find("login timeout", 1, true)
        or lower:find("getloginuid", 1, true)
        or head:find("扫码登录", 1, true)
        or head:find("登录微信读书", 1, true) then
        return Http.auth_error_message(-2012, "reader page session expired")
    end
end

local function raw_service_auth_error(raw)
    local text = tostring(raw or ""):gsub("^%s+", "")
    if text:sub(1, 1) ~= "{" then return nil end
    local ok, data = pcall(Json.decode, text)
    if not ok or type(data) ~= "table" then return nil end
    local code = data.errCode or data.errcode or data.code
    local message = tostring(data.errMsg or data.errmsg or data.message or data.msg or "")
    if tonumber(code) == -2012 or message:lower():find("login timeout", 1, true)
        or message:find("登录超时", 1, true) then
        return Http.auth_error_message(code or -2012, message)
    end
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
    if value ~= nil then return value end
    value = attrs:match("%s" .. name_pattern .. "%s*=%s*([^%s>]+)")
        or attrs:match("^" .. name_pattern .. "%s*=%s*([^%s>]+)")
    return value
end

local function image_remove_attr(attrs, name_pattern)
    attrs = tostring(attrs or "")
    attrs = attrs:gsub("%s" .. name_pattern .. "%s*=%s*([\"'])(.-)%1", "")
    attrs = attrs:gsub("^" .. name_pattern .. "%s*=%s*([\"'])(.-)%1%s*", "")
    attrs = attrs:gsub("%s" .. name_pattern .. "%s*=%s*[^%s>]+", "")
    attrs = attrs:gsub("^" .. name_pattern .. "%s*=%s*[^%s>]+%s*", "")
    return attrs
end

local function image_set_local_src(attrs, href)
    attrs = image_remove_attr(attrs, "src")
    for _, name in ipairs({"data%-src", "data%-original", "data%-lazy%-src", "data%-actualsrc", "srcset"}) do
        attrs = image_remove_attr(attrs, name)
    end
    return ' src="' .. tostring(href or "") .. '"' .. attrs
end

local function image_set_local_href(attrs, href)
    for _, name in ipairs({"href", "xlink:href", "data%-src", "data%-original", "srcset"}) do
        attrs = image_remove_attr(attrs, name)
    end
    return ' href="' .. tostring(href or "") .. '"' .. attrs
end

local OPTIONAL_IMAGE_PLACEHOLDER = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="

local function image_is_optional_reference(attrs, source)
    local clean = image_trim(source)
    local path = clean:match("^[^%?#]+") or clean
    local basename = image_basename(image_url_decode(path)):lower()
    if basename == "note.png" then return true end

    local class = tostring(image_attr(attrs, "class") or ""):lower()
    for _, token in ipairs({"qqreader-footnote", "footnote-icon", "footnote-ref", "note-ref"}) do
        if class:find(token, 1, true) then return true end
    end
    return false
end

local function image_remote_url(value)
    local url = image_trim(value)
    if url:sub(1, 2) == "//" then url = "https:" .. url end
    if url:match("^https?://") then return url end
end

local function image_is_font_reference(value)
    local clean=image_trim(value):lower():gsub("[?#].*$", "")
    return clean:match("%.woff2?$") ~= nil
        or clean:match("%.ttf$") ~= nil
        or clean:match("%.otf$") ~= nil
        or clean:match("%.eot$") ~= nil
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

local function image_work_root(reader,book_id,chapter_uid)
    local base=tostring(reader and reader.store and reader.store.temp_dir or "")
    if base=="" then base="/tmp" end
    local root=base.."/chapter-images-"..Util.id_name(book_id).."-"..Util.id_name(chapter_uid)
        .."-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))
    Util.remove_tree(root)
    if not Util.mkdir(root) then error("无法建立章节图片临时目录") end
    reader._transient_image_roots=reader._transient_image_roots or {}
    reader._transient_image_roots[root]=true
    return root
end

local function image_tar_assets_file(archive_path,work_root,opt)
    local extract_dir=work_root.."/tar"
    local entries,extract_error,extract_status=Codec.tar_file(archive_path,extract_dir,function(bytes,count)
        if opt and type(opt.activity)=="function" then
            pcall(opt.activity,"image_extract",{bytes=bytes,count=count})
        end
    end)
    if not entries then return nil,nil,extract_error,extract_status end
    local names={}
    for name in pairs(entries) do names[#names+1]=name end
    table.sort(names)

    local assets,source_map,used={},{},{}
    local index=0
    for _,name in ipairs(names) do
        local item=entries[name]
        local path=item and item.path
        local size=item and tonumber(item.size) or 0
        local ext,mime=Codec.media_file(path,name)
        if tostring(mime):match("^image/") and path and size>0 then
            index=index+1
            local href
            href,index=image_unique_href(used,"tar",index,ext)
            assets[#assets+1]={href=href,data_path=path,mime=mime,source=name,_temporary_root=work_root}
            local local_src="../"..href
            image_map_add(source_map,name,local_src)
            image_map_add(source_map,image_basename(name),local_src)
        elseif path then
            os.remove(path)
        end
    end
    return assets,source_map,extract_error,extract_status
end

local function localize_epub_images(reader, xhtml, assets, source_map, state, css, opt)
    assets = assets or {}
    source_map = source_map or {}
    local used = image_used_hrefs(assets)
    local remote_cache, remote_failed = {}, {}
    local remote_index = #assets
    local summary = {
        tar=#assets,remote=0,discovered=0,localized=0,optional=0,recovered=0,stale=0,missing=0,
        required_discovered=0,required_localized=0,required_missing=0,
        optional_dropped=0,stale_dropped=0,embedded=0,fonts_skipped=0,
    }
    local text_length = readable_text_length(xhtml)

    -- WeRead chapter CSS may reference remote web fonts. Fonts are presentation
    -- resources, not正文 images: a dead font CDN must never make a chapter
    -- incomplete. Remove @font-face blocks so the EPUB cleanly falls back to
    -- KOReader's local fonts and never depends on the network while reading.
    local function strip_font_faces(value)
        return tostring(value or ""):gsub("@[fF][oO][nN][tT]%-[fF][aA][cC][eE]%s*%b{}",function(block)
            local _,count=tostring(block):gsub("[uU][rR][lL]%s*%(","")
            summary.fonts_skipped=summary.fonts_skipped+math.max(1,count)
            return ""
        end)
    end
    xhtml=strip_font_faces(xhtml)
    css=strip_font_faces(css)
    local used_local_src, pending = {}, {}

    local function normalize_asset_href(value)
        local href=tostring(value or ""):gsub("\\", "/")
        while href:sub(1,3)=="../" do href=href:sub(4) end
        while href:sub(1,2)=="./" do href=href:sub(3) end
        href=href:gsub("^OEBPS/",""):gsub("^/+","")
        return href
    end

    local function download_remote(url)
        if remote_cache[url] then return remote_cache[url] end
        if remote_failed[url] then return nil end
        local root=tostring(state and state.image_work_root or "")
        if root=="" then
            remote_failed[url]=true
            logger.warn("[MiuRead][Reader] remote image work directory missing","url=",Util.redact_url(url))
            return nil
        end
        local target=root.."/remote-"..string.format("%05d",remote_index+1)..".bin"
        local ok, path_or_error = pcall(reader.http.download_to_file, reader.http, url, target, {
            headers={
                Referer=(state and state.url) or BASE .. "/",
                Origin=BASE,
                Accept="image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
                ["Cache-Control"]="no-cache",
            },
            retries=1,
            timeout={12, 25},
            on_chunk=function(bytes)
                if opt and type(opt.activity)=="function" then
                    pcall(opt.activity,"remote_image_download",{bytes=bytes})
                end
            end,
        })
        if not ok or not path_or_error or not Util.file_exists(path_or_error) then
            if not ok and is_auth_error(path_or_error) then
                -- Preserve the original 401/session error so Reader:chapter can
                -- renew the Web session and rebuild the chapter with fresh
                -- signed image addresses instead of retrying a stale URL.
                error(path_or_error)
            end
            os.remove(target)
            remote_failed[url] = true
            logger.warn("[MiuRead][Reader] remote image failed", "url=", Util.redact_url(url),
                "error=", ok and "empty" or tostring(path_or_error))
            return nil
        end
        local ext, mime = Codec.media_file(path_or_error, url)
        if not tostring(mime):match("^image/") then
            os.remove(path_or_error)
            remote_failed[url] = true
            logger.warn("[MiuRead][Reader] remote asset is not an image", "url=", Util.redact_url(url), "mime=", tostring(mime))
            return nil
        end
        remote_index = remote_index + 1
        local href
        href, remote_index = image_unique_href(used, "remote", remote_index, ext)
        assets[#assets + 1] = {href=href, data_path=path_or_error, mime=mime, source=url, _temporary_root=root}
        remote_cache[url] = href
        image_map_add(source_map, url, "../" .. href)
        summary.remote = summary.remote + 1
        return href
    end

    local function resolve_source(source, prefix)
        local clean=image_trim(source)
        if clean=="" or clean:sub(1,1)=="#" or clean:lower():match("^data:image/") then return nil,nil end
        local mapped=image_map_get(source_map,clean)
        local href=mapped and normalize_asset_href(mapped) or nil
        local remote_url=image_remote_url(clean)
        if not href and remote_url then href=download_remote(remote_url) end
        if href and href~="" then return tostring(prefix or "")..href,href end
        return nil,nil,remote_url~=nil
    end

    -- EPUBs often use <picture><source srcset=...><img ...></picture>.
    -- KOReader only needs the final img, so fold the first source candidate into
    -- the img before normal localization.
    xhtml=tostring(xhtml or ""):gsub("<[pP][iI][cC][tT][uU][rR][eE][^>]*>(.-)</[pP][iI][cC][tT][uU][rR][eE]%s*>",function(inner)
        local attrs=inner:match("<[iI][mM][gG]([^>]*)>")
        if not attrs then return inner end
        local existing=image_attr(attrs,"data%-src") or image_attr(attrs,"data%-original")
            or image_attr(attrs,"data%-lazy%-src") or image_attr(attrs,"data%-actualsrc")
            or image_attr(attrs,"src") or image_attr(attrs,"srcset")
        if image_trim(existing)=="" then
            local source_attrs=inner:match("<[sS][oO][uU][rR][cC][eE]([^>]*)>")
            local candidate=source_attrs and (image_attr(source_attrs,"srcset") or image_attr(source_attrs,"src")) or nil
            if candidate then
                candidate=candidate:match("^%s*([^,%s]+)") or candidate
                attrs=' data-src="'..Util.xml(candidate)..'"'..attrs
            end
        end
        return "<img"..attrs..">"
    end)

    xhtml = xhtml:gsub("<[iI][mM][gG]([^>]*)>", function(attrs)
        local srcset = image_attr(attrs, "srcset")
        local source = image_attr(attrs, "data%-src")
            or image_attr(attrs, "data%-original")
            or image_attr(attrs, "data%-lazy%-src")
            or image_attr(attrs, "data%-actualsrc")
            or image_attr(attrs, "src")
            or (srcset and srcset:match("^%s*([^,%s]+)"))
        local clean_source = image_trim(source)
        if clean_source == "" then return "<img" .. attrs .. ">" end
        if clean_source:lower():match("^data:image/") then
            summary.embedded=summary.embedded+1
            return "<img" .. attrs .. ">"
        end
        if image_is_optional_reference(attrs, clean_source) then
            summary.optional = summary.optional + 1
            summary.optional_dropped = summary.optional_dropped + 1
            logger.dbg("[MiuRead][Reader] optional image reference replaced", "src=", tostring(clean_source))
            return "<img" .. image_set_local_src(attrs, OPTIONAL_IMAGE_PLACEHOLDER) .. ">"
        end
        summary.discovered=summary.discovered+1
        summary.required_discovered=summary.required_discovered+1

        local local_src,href,was_remote = resolve_source(clean_source,"../")
        if local_src then
            used_local_src[href] = true
            summary.localized = summary.localized + 1
            summary.required_localized = summary.required_localized + 1
            return "<img" .. image_set_local_src(attrs, local_src) .. ">"
        end

        local marker = "__MIUREAD_PENDING_IMAGE_" .. tostring(#pending + 1) .. "__"
        pending[#pending + 1] = {
            marker=marker,
            attrs=attrs,
            source=clean_source,
            remote=was_remote==true,
        }
        return marker
    end)

    -- Localize SVG <image href=...> references without flattening the SVG.
    xhtml=xhtml:gsub("<[iI][mM][aA][gG][eE]([^>]*)>",function(attrs)
        local source=image_attr(attrs,"xlink:href") or image_attr(attrs,"href")
            or image_attr(attrs,"data%-src") or image_attr(attrs,"srcset")
        local clean=image_trim(source)
        if clean=="" then return "<image"..attrs..">" end
        if clean:lower():match("^data:image/") then
            summary.embedded=summary.embedded+1
            return "<image"..attrs..">"
        end
        summary.discovered=summary.discovered+1
        summary.required_discovered=summary.required_discovered+1
        local local_src,href,was_remote=resolve_source(clean,"../")
        if local_src then
            used_local_src[href]=true
            summary.localized=summary.localized+1
            summary.required_localized=summary.required_localized+1
            return "<image"..image_set_local_href(attrs,local_src)..">"
        end
        if was_remote then
            summary.missing=summary.missing+1
            summary.required_missing=summary.required_missing+1
        else
            summary.stale=summary.stale+1
            summary.stale_dropped=summary.stale_dropped+1
        end
        logger.warn("[MiuRead][Reader] SVG image reference unresolved","src=",tostring(clean))
        return "<image"..attrs..">"
    end)

    -- Some illustrated books place images in inline or chapter CSS rather than
    -- img tags. Resolve url(...) against the same TAR/remote asset map.
    local function localize_css_urls(value,prefix)
        return tostring(value or ""):gsub("url%s*%(%s*([\\\"']?)(.-)%1%s*%)",function(_,source)
            local clean=image_trim(source)
            if clean=="" or clean:sub(1,1)=="#" then
                return "url("..tostring(source or "")..")"
            end
            if clean:lower():match("^data:") then
                summary.embedded=summary.embedded+1
                return "url("..tostring(source or "")..")"
            end
            if image_is_font_reference(clean) then
                summary.fonts_skipped=summary.fonts_skipped+1
                logger.dbg("[MiuRead][Reader] CSS font reference ignored for chapter completeness",
                    "src=",Util.redact_url(clean))
                return "url("..tostring(source or "")..")"
            end
            summary.discovered=summary.discovered+1
            local local_src,href,was_remote=resolve_source(clean,prefix)
            if local_src then
                used_local_src[href]=true
                summary.localized=summary.localized+1
                summary.required_discovered=summary.required_discovered+1
                summary.required_localized=summary.required_localized+1
                return "url('"..local_src.."')"
            end
            if was_remote then
                summary.missing=summary.missing+1
                summary.required_discovered=summary.required_discovered+1
                summary.required_missing=summary.required_missing+1
                logger.warn("[MiuRead][Reader] CSS image reference unresolved","src=",tostring(clean))
                return "url('"..clean.."')"
            end
            summary.stale=summary.stale+1
            summary.stale_dropped=summary.stale_dropped+1
            return "url('"..OPTIONAL_IMAGE_PLACEHOLDER.."')"
        end)
    end
    xhtml=xhtml:gsub("([sS][tT][yY][lL][eE]%s*=%s*)([\\\"'])(.-)%2",function(prefix,quote,value)
        return prefix..quote..localize_css_urls(value,"../")..quote
    end)
    local localized_css=localize_css_urls(css or "","")

    -- Some books contain valid TAR assets whose internal names no longer match
    -- the HTML paths. When the remaining counts match exactly, map them by order
    -- instead of treating the chapter as incomplete.
    local unused = {}
    for _, asset in ipairs(assets) do
        local href=normalize_asset_href(asset.href)
        if href~="" and not used_local_src[href] then unused[#unused + 1] = href end
    end
    local local_pending = {}
    for _, item in ipairs(pending) do
        if not item.remote then local_pending[#local_pending + 1] = item end
    end
    if #local_pending > 0 and #local_pending == #unused then
        for index, item in ipairs(local_pending) do
            local href = unused[index]
            local local_src="../"..href
            xhtml = xhtml:gsub(item.marker, "<img" .. image_set_local_src(item.attrs, local_src) .. ">")
            used_local_src[href] = true
            item.resolved = true
            summary.localized = summary.localized + 1
            summary.required_localized = summary.required_localized + 1
            summary.recovered = summary.recovered + 1
            logger.info("[MiuRead][Reader] unmatched image reference recovered from TAR order",
                "src=", tostring(item.source), "local=", tostring(local_src))
        end
    end

    for _, item in ipairs(pending) do
        if not item.resolved then
            local replacement
            local archive_failed = state and state.image_archive_expected == true and state.image_archive_ok ~= true
            if not item.remote and not archive_failed then
                local alt = tostring(image_attr(item.attrs, "alt") or ""):gsub("^%s+", ""):gsub("%s+$", "")
                replacement = alt ~= "" and ('<span class="miu-image-alt">' .. Util.xml(alt) .. "</span>") or ""
                summary.stale = summary.stale + 1
                summary.stale_dropped = summary.stale_dropped + 1
                logger.warn("[MiuRead][Reader] orphan image reference ignored", "src=", tostring(item.source),
                    "text_length=", tostring(text_length))
            else
                replacement = "<img" .. item.attrs .. ">"
                summary.missing = summary.missing + 1
                summary.required_missing = summary.required_missing + 1
                logger.warn("[MiuRead][Reader] image reference unresolved", "src=", tostring(item.source))
            end
            xhtml = xhtml:gsub(item.marker, replacement)
        end
    end

    return xhtml, assets, summary, localized_css
end

local function response_header(headers, name)
    local target = tostring(name or ""):lower()
    for key, value in pairs(headers or {}) do
        if tostring(key):lower() == target then return value end
    end
end

function Reader:new(http, store)
    return setmetatable({http=http, store=store, _renewing_session=false, _transient_image_roots={}}, self)
end

function Reader:cleanup_transient_images()
    for root in pairs(self._transient_image_roots or {}) do Util.remove_tree(root) end
    self._transient_image_roots={}
end

function Reader:renew()
    local data, headers, meta = self.http:post_json(BASE .. "/web/login/renewal", {rq="%2Fweb%2Fbook%2Fread", ql=false},
        {headers={Origin=BASE, Referer=BASE .. "/", Accept="application/json, text/plain, */*"},
            retries=2,defer_auth_persist=true})
    return data, headers, meta
end

function Reader:_recover_login_session()
    if self._renewing_session then return false, "登录状态正在续期" end
    self._renewing_session = true

    local before = self.store:auth()
    local before_login_session_id=tostring(before.login_session_id or "")
    local before_auth_revision=math.max(0,tonumber(before.auth_revision or 0) or 0)
    local before_vid = tostring((before.account or {}).vid or (before.cookies or {}).wr_vid or "")
    local ok, result = pcall(function()
        local renewed, renewal_headers, meta = self:renew()
        if type(renewed) ~= "table" then error("续期接口返回无效数据") end
        if renewed.succ == false or tostring(renewed.succ or "") == "0" then
            error("微信读书未接受本次登录续期")
        end

        -- A failed/ambiguous renewal response must never mutate the durable
        -- login. Only now, after succ has been accepted, merge its Set-Cookie
        -- and public-account headers into the exact credential revision that
        -- started this renewal.
        local candidate=Util.copy(before)
        candidate.cookies=Cookies.absorb(candidate.cookies or {},response_header(renewal_headers,"set-cookie"),{protect_core=true})
        candidate.cookies=Cookies.sanitize(candidate.cookies)
        local renewed_ticket=response_header(renewal_headers,"x-wr-ticket")
        local renewed_wrpa=response_header(renewal_headers,"x-wrpa-0")
        if renewed_ticket~=nil and tostring(renewed_ticket)~="" then candidate.wr_ticket=tostring(renewed_ticket) end
        if renewed_wrpa~=nil and tostring(renewed_wrpa)~="" then candidate.wr_wrpa=tostring(renewed_wrpa) end
        if (renewed_ticket~=nil and tostring(renewed_ticket)~="") or (renewed_wrpa~=nil and tostring(renewed_wrpa)~="") then
            candidate.ticket_updated_at=os.time()
        end
        local candidate_vid=tostring(((candidate.account or {}).vid) or (candidate.cookies or {}).wr_vid or "")
        if before_vid~="" and candidate_vid~="" and before_vid~=candidate_vid then
            error("续期返回了不同账户，已保留原账户凭据")
        end
        local committed,commit_error=self.store:save_auth(candidate,{expected_revision=before_auth_revision})
        if committed~=true then error(commit_error or "登录续期结果已过期") end

        -- Ordinary book reading and downloads only need the renewed Web
        -- session. Refreshing the Skills API key is useful for other features,
        -- but a failure there must not invalidate an otherwise usable book
        -- session or stop a long background download.
        local skills_ok, skills_result = pcall(self.repair_login_session, self)
        if not skills_ok then
            logger.warn("[MiuRead][Reader] optional Skills credential refresh failed",
                tostring(skills_result))
        end

        local after = self.store:auth()
        if before_login_session_id=="" or tostring(after.login_session_id or "")~=before_login_session_id then
            error("登录状态已变化，已忽略旧续期结果")
        end
        local after_vid = tostring((after.account or {}).vid or (after.cookies or {}).wr_vid or "")
        local after_skey = tostring((after.cookies or {}).wr_skey or "")
        if after_vid == "" or after_skey == "" then
            error("续期后仍缺少正文下载所需的登录凭据")
        end
        if before_vid ~= "" and after_vid ~= "" and before_vid ~= after_vid then
            error("续期后的账户身份异常")
        end
        return {meta=meta, verified=true, skills_verified=skills_ok, vid=after_vid,
            auth_revision=tonumber(after.auth_revision or 0) or 0}
    end)

    self._renewing_session = false
    if ok then
        logger.info("[MiuRead][Reader] login renewal completed; web credentials present",
            "skills=", tostring(result.skills_verified == true),
            "vid_unchanged=", tostring(before_vid == "" or before_vid == tostring(result.vid or "")))
        return true, result
    end
    logger.warn("[MiuRead][Reader] login session recovery failed", tostring(result))
    return false, result
end

function Reader:check_login_session()
    local ok, result = self:_recover_login_session()
    if not ok then error(result) end
    return result
end

local function load_reader_context(self,book_id,chapter_uid,require_psvts)
    local url=Protocol.is_mp(book_id) and Protocol.mp_reader_url(book_id) or Protocol.reader_url(book_id,chapter_uid)
    local html,_,final_url=self.http:download(url,{headers={Accept="text/html,application/xhtml+xml"},retries=2})
    local page_error=login_page_error(html,final_url)
    if page_error then error(page_error) end
    local context=regex_context(html)
    local raw=Util.extract_balanced_json(html,"window.__INITIAL_STATE__")
        or Util.extract_balanced_json(html,"__INITIAL_STATE__")
    if raw then
        local decoded,data=pcall(Json.decode,raw)
        if decoded then
            local parsed=find_context(data)
            if parsed then
                context.psvts=optional_value(context.psvts) or parsed.psvts
                context.pclts=optional_value(context.pclts) or parsed.pclts
                context.token=optional_value(context.token) or parsed.token
                context.book=parsed.book or context.book or {}
                context.source=data
            end
        end
    end
    context.book_version = positive_number(context.book and
        (context.book.bookVersion or context.book.book_version or context.book.version))
        or find_book_version(context.source, book_id)
    if html:find("可永久阅读",1,true) then context.ownership_hint="可永久阅读" end
    if html:find("书币购买或活动领取",1,true) then context.ownership_hint="书币购买或活动领取" end
    if html:find("个人上传",1,true) or html:find("用户上传",1,true) then context.ownership_hint="个人上传" end
    context.url=url
    if require_psvts and not optional_value(context.psvts) then error("reader.psvts not found") end
    return context
end

function Reader:state(book_id,chapter_uid)
    return load_reader_context(self,book_id,chapter_uid,true)
end

function Reader:catalog(book_id, request_options)
    request_options=type(request_options)=="table" and request_options or {}
    local function load_catalog()
        -- Catalog is a small control request. beta.24 avoids multiplying a
        -- transient socket stall into minutes of foreground 0% waiting: one
        -- transport retry is enough, and auth recovery still gets its own clean
        -- retry below. The download-task watchdog remains the final fallback.
        local http_options={
            headers={Origin=BASE, Referer=Protocol.reader_url(book_id)},
            retries=1, timeout={10,22},
        }
        if type(request_options.on_retry)=="function" then http_options.on_retry=request_options.on_retry end
        local data = self.http:post_json(BASE .. "/web/book/chapterInfos", {bookIds={tostring(book_id)}},http_options)
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
    local auth_error = raw_service_auth_error(raw)
    if auth_error then error(auth_error) end
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
    if not has_readable_content(xhtml, false) then error("decoded TXT chapter is empty") end
    -- Keep the complete decrypted chapter before any coordinate/body trimming.
    -- beta.10 exports this only for local coordinate diagnostics.
    state.raw_xhtml = xhtml
    state.coord_html = AnnotationCoord.fromDownloadedXhtml(xhtml)
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
    -- Keep the exact decrypted XHTML before image localization, body extraction
    -- or any MiuRead rewrite. This is the missing reference required to compare
    -- local coordinates with real WeRead ranges.
    state.raw_xhtml = xhtml
    -- Preserve the current MiuRead coordinate candidate separately so raw.xhtml
    -- and coord.xhtml can be compared byte-for-byte.
    state.coord_html = AnnotationCoord.fromDownloadedXhtml(xhtml)

    local css = "body{line-height:1.7;margin:5%;}img{max-width:100%;height:auto;}"
    local ok_style, style_raw = pcall(self.shard, self, "/web/book/chapter/e_2", id, uid, state.psvts, true)
    if ok_style and not style_raw:match("^%s*{") then
        local ok, value = pcall(Codec.decode_parts, {style_raw})
        if ok and value ~= "" then css = value end
    end

    local assets, source_map = {}, {}
    if opt.images ~= false then
        local work_root=image_work_root(self,id,uid)
        state.image_work_root=work_root
        local tar_url = chapter.tar
        state.image_archive_expected = tar_url ~= nil and tostring(tar_url) ~= ""
        state.image_archive_ok = not state.image_archive_expected
        if tar_url and tar_url ~= "" then
            tar_url = tostring(tar_url)
            if tar_url:sub(1, 2) == "//" then
                tar_url = "https:" .. tar_url
            elseif tar_url:sub(1, 1) == "/" then
                tar_url = BASE .. tar_url
            end
            local archive_path=work_root.."/chapter-images.tar"
            local ok_tar, path_or_error = pcall(self.http.download_to_file, self.http, tar_url, archive_path, {
                headers={Referer=state.url, Origin=BASE, Accept="application/octet-stream,*/*"},
                retries=3,
                on_chunk=function(bytes)
                    if type(opt.activity)=="function" then
                        pcall(opt.activity,"image_archive_download",{bytes=bytes})
                    end
                end,
            })
            if ok_tar and path_or_error and Util.file_exists(path_or_error) then
                if type(opt.yield)=="function" then opt.yield("images") end
                local tar_assets, tar_map, extract_error, extract_status = image_tar_assets_file(path_or_error,work_root,opt)
                os.remove(archive_path)
                if tar_assets then
                    local partial=type(extract_status)=="table" and extract_status.partial==true
                    state.image_archive_partial=partial
                    state.image_archive_error=partial and tostring(extract_status.error or extract_error or "") or nil
                    state.image_archive_ok = not partial
                    for _, asset in ipairs(tar_assets) do assets[#assets + 1] = asset end
                    for key, href in pairs(tar_map) do source_map[key] = href end
                    if partial then
                        logger.warn("[MiuRead][Reader] chapter image archive partially recovered",
                            "chapter=",tostring(uid),"url=",Util.redact_url(tar_url),
                            "images=",tostring(#tar_assets),"error=",tostring(state.image_archive_error))
                    end
                    collectgarbage("collect")
                else
                    logger.warn("[MiuRead][Reader] chapter image archive extract failed", "chapter=", tostring(uid),
                        "url=", Util.redact_url(tar_url), "error=", tostring(extract_error))
                end
            else
                os.remove(archive_path)
                logger.warn("[MiuRead][Reader] chapter image archive failed", "chapter=", tostring(uid),
                    "url=", Util.redact_url(tar_url), "error=", ok_tar and "empty" or tostring(path_or_error))
            end
        end
    end

    if not has_readable_content(xhtml, true) then
        if opt.images ~= false and #assets > 0 then
            xhtml = image_only_xhtml(assets)
            css = tostring(css or "") .. [[
.miu-image-only-page { text-align: center; }
.miu-image-only-item { margin: 0 0 1.2em 0; }
.miu-image-only-item img { display: inline-block; max-width: 100%; height: auto; }
]]
            state.image_only = true
            state.image_summary = {
                tar=#assets,remote=0,discovered=#assets,localized=#assets,optional=0,recovered=0,stale=0,missing=0,
                required_discovered=#assets,required_localized=#assets,required_missing=0,
                optional_dropped=0,stale_dropped=0,embedded=0,fonts_skipped=0,
            }
            logger.info("[MiuRead][Reader] empty text chapter preserved as image-only page",
                "chapter=", tostring(uid), "title=", tostring(chapter.title or ""), "images=", tostring(#assets))
        else
            error("decoded EPUB chapter is empty")
        end
    elseif opt.images ~= false then
        xhtml, assets, state.image_summary, css = localize_epub_images(self, xhtml, assets, source_map, state, css, opt)
        logger.info("[MiuRead][Reader] chapter images", "chapter=", tostring(uid),
            "tar=", tostring(state.image_summary.tar), "remote=", tostring(state.image_summary.remote),
            "localized=", tostring(state.image_summary.localized), "optional=", tostring(state.image_summary.optional or 0),
            "fonts_skipped=",tostring(state.image_summary.fonts_skipped or 0),
            "recovered=", tostring(state.image_summary.recovered or 0), "stale=", tostring(state.image_summary.stale or 0),
            "required_missing=", tostring(state.image_summary.required_missing or 0),
            "archive_partial=",tostring(state.image_archive_partial==true))
        if tonumber(state.image_summary.required_missing or 0) > 0 then
            error("正文图片未完整获取：" .. tostring(state.image_summary.required_missing) .. " 个真实资源仍缺失")
        end
        if not has_readable_content(xhtml, true) then
            xhtml = structure_xhtml(chapter.title or "")
            css = tostring(css or "") .. "\n" .. PART_CSS
            state.structural = true
            state.content_format = "structure"
            logger.info("[MiuRead][Reader] orphan-only chapter converted to structure page",
                "chapter=", tostring(uid), "title=", tostring(chapter.title or ""))
        end
    end
    state.content_format = state.content_format or "epub"
    if state.image_work_root and #assets==0 then
        Util.remove_tree(state.image_work_root)
        if self._transient_image_roots then self._transient_image_roots[state.image_work_root]=nil end
        state.image_work_root=nil
    end
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
        if is_empty_error(a) and not is_auth_error(a) then
            error(CONFIRMED_EMPTY .. ": " .. tostring(a))
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
    if is_empty_error(ta) and not is_auth_error(ta) then
        error(CONFIRMED_EMPTY .. ": EPUB=" .. tostring(epub_error) .. "; TXT=" .. tostring(ta))
    end
    error(tostring(epub_error) .. "; TXT fallback: " .. tostring(ta))
end

function Reader:chapter(book, chapter, format, opt)
    local last, renewed, empty_count = nil, false, 0
    local uid = chapter.chapterUid or chapter.uid
    for attempt = 1, 3 do
        self:cleanup_transient_images()
        local ok, a, b, c, d = pcall(self._chapter_once, self, book, chapter, format, opt)
        if ok then return a, b, c, d end
        last = a
        local control_error=tostring(a or "")
        if control_error:find("__MIUREAD_HIBERNATE__",1,true)
            or control_error:lower():find("download cancelled",1,true) then
            self:cleanup_transient_images()
            error(a)
        end

        if is_confirmed_empty_error(a) then
            empty_count = empty_count + 1
            local metadata_structure = is_structure_chapter(chapter)
            local words = tonumber(chapter.wordCount or chapter.word_count or 0) or 0
            -- Parent/title nodes are accepted immediately. Any other catalog
            -- item is accepted only after three independent EPUB+TXT empty
            -- confirmations. Catalog word counts are advisory and are often
            -- non-zero for illustration, divider and legacy placeholder pages.
            local required = metadata_structure and 1 or 3
            if empty_count >= required then
                local state = {content_format="structure", structural=true, catalog_word_count=words}
                logger.info("[MiuRead][Reader] confirmed empty catalog item converted to structure page",
                    "chapter=", tostring(uid), "title=", tostring(chapter.title or ""),
                    "confirmations=", tostring(empty_count), "metadata=", tostring(metadata_structure),
                    "word_count=", tostring(words), "catalog_mismatch=", tostring(words > 0))
                return structure_xhtml(chapter.title or ""), PART_CSS, {}, state
            end
        end

        logger.warn("[MiuRead][Reader] chapter retry", "chapter=", tostring(uid),
            "attempt=", tostring(attempt), "error=", tostring(a))
        if Http.is_rate_limit_error(a) then break end
        if is_auth_error(a) and not renewed then
            renewed = true
            local renew_ok, renew_error = self:_recover_login_session()
            logger.warn("[MiuRead][Reader] authentication renewal", "ok=", tostring(renew_ok),
                "error=", renew_ok and "" or tostring(renew_error))
            if not renew_ok then
                last=tostring(a).."; 自动续期失败："..tostring(renew_error)
                break
            end
        end
        if attempt < 3 then
            -- Kindle may report Wi-Fi as enabled before the network route and
            -- DNS are usable after resume/restart. Give network failures a
            -- longer recovery window instead of rapidly exhausting retries.
            if Http.is_network_error(a) then
                pause(attempt == 1 and 4.0 or 8.0)
            else
                pause(attempt == 1 and 0.8 or 1.8)
            end
        end
    end
    self:cleanup_transient_images()
    error(last or "chapter download failed")
end

function Reader:mp_content(review_id, book_id, options)
    options = options or {}
    local auth = self.store:auth()
    local headers = {
        Referer = book_id and Protocol.mp_reader_url(book_id) or BASE .. "/",
        Accept = "text/html,application/xhtml+xml,*/*",
    }
    if options.skip_mp_auth_headers ~= true then
        if tostring(auth.wr_ticket or "") ~= "" then headers["x-wr-ticket"] = tostring(auth.wr_ticket) end
        if tostring(auth.wr_wrpa or "") ~= "" then headers["x-wrpa-0"] = tostring(auth.wr_wrpa) end
    end
    local html, _, final_url = self.http:download(BASE .. "/web/mp/content?reviewId=" .. Protocol.escape(review_id), {
        auth=true, headers=headers, retries=3,
    })
    local page_error = login_page_error(html, final_url)
    if page_error then error(page_error) end
    local service_error = raw_service_auth_error(html)
    if service_error then error(service_error) end
    return html
end

-- Repair QR-login web cookies using the authenticated follow-up flow from
-- the compatibility reporting path. Only stable wr_ / ptcz / RK / pgv_pvid cookies
-- are retained; browser-session cookies are deliberately discarded.
function Reader:repair_login_session()
    local auth = self.store:auth()
    local login_session_id=tostring(auth.login_session_id or "")
    local auth_revision=math.max(0,tonumber(auth.auth_revision or 0) or 0)
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
        {auth=false, headers=headers(), retries=2}
    )
    jar = Cookies.absorb(jar, response_header(user_headers, "set-cookie"))
    vid = tostring(jar.wr_vid or vid)
    skey = tostring(jar.wr_skey or skey)

    local skill, skill_headers = self.http:get_json(
        BASE .. "/api/skills/apikeyGet?only_show=1",
        {auth=false, headers=headers(), retries=2}
    )
    jar = Cookies.absorb(jar, response_header(skill_headers, "set-cookie"))
    vid = tostring(jar.wr_vid or vid)
    skey = tostring(jar.wr_skey or skey)
    if type(skill) ~= "table" or tostring(skill.apikey or "") == "" then
        skill, skill_headers = self.http:get_json(
            BASE .. "/api/skills/apikeyGet",
            {auth=false, headers=headers(), retries=2}
        )
        jar = Cookies.absorb(jar, response_header(skill_headers, "set-cookie"))
        vid = tostring(jar.wr_vid or vid)
        skey = tostring(jar.wr_skey or skey)
    end

    auth.cookies = jar
    if type(skill) == "table" and tostring(skill.apikey or "") ~= "" then
        auth.api_key = tostring(skill.apikey)
    elseif tostring(auth.api_key or "") == "" then
        error("续期后未能取得 API key")
    end
    auth.account = Util.merge(account, {
        name = tostring(type(user) == "table" and user.name or account.name or ""),
        vid = vid,
    })
    local current=self.store:auth()
    if login_session_id=="" or tostring(current.login_session_id or "")~=login_session_id then
        error("登录状态已变化，已忽略旧修复结果")
    end
    local saved,save_error=self.store:save_auth(auth,{expected_revision=auth_revision})
    if saved~=true then error(save_error or "登录凭据已变化，已忽略旧修复结果") end
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
Reader._is_cover_chapter = is_cover_chapter
Reader._is_unavailable_chapter = is_unavailable_chapter
Reader._has_readable_content = has_readable_content
Reader.is_access_denied_error = is_access_denied_error
Reader._is_empty_error = is_empty_error
Reader._is_auth_error = is_auth_error
Reader._image_source_keys = image_source_keys
Reader._image_is_optional_reference = image_is_optional_reference
Reader._image_tar_assets = image_tar_assets
Reader._localize_epub_images = localize_epub_images
Reader.PART_CSS = PART_CSS

return Reader
