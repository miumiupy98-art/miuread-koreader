--[[--
书籍脚注处理：
- 微信读书 qqreader-footnote 图片注脚
- EPUB3 epub:type="noteref" / role="doc-noteref"
- <sup><a href="#note">…</a></sup> 与跨章节尾注链接
- 单/双引号、多 class、同章与跨章锚点

所有已解析注释转换为章节内 EPUB3 footnote aside；解析失败时保留原链接，
避免把正常链接误改成无效脚注。

@module miuread.footnotes
--]]--

local ok_json, JSON = pcall(require, "json")
if not ok_json then ok_json, JSON = pcall(require, "rapidjson") end

local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local ok_logger, logger = pcall(require, "logger")
if not ok_logger then logger = nil end
local ok_util, util = pcall(require, "util")

local LOG_MODULE = "[MiuRead][Footnotes]"
local Footnotes = {}

Footnotes.FOOTNOTES_CSS = [[
.fn-ref{font-size:0.75em;vertical-align:super;line-height:0;white-space:nowrap;}
.fn-ref a{position:relative;text-decoration:none;color:#0366d6;}
.fn-ref a::after{content:"";position:absolute;top:-0.5em;right:-0.3em;bottom:-0.5em;left:-0.3em;}
aside.footnote{margin:0.5em 0;font-size:0.85em;text-indent:0!important;text-align:left!important;}
div.footnotes{margin-top:2em;padding-top:0.5em;border-top:1px solid #ccc;}
.fn-num{font-weight:bold;margin-right:0.3em;text-decoration:none;color:inherit;}
]]

local function log_info(...)
    if logger then logger.info(LOG_MODULE, ...) end
end

local function join_path(a, b)
    if ok_ffiutil then return ffiutil.joinPath(a, b) end
    return tostring(a or "") .. "/" .. tostring(b or "")
end

local function ensure_dir(path)
    if ok_util and util.makePath then util.makePath(path); return end
    os.execute("mkdir -p " .. string.format("%q", path))
end

local function sort_chapters(chapters)
    if type(chapters) ~= "table" then return {} end
    local sorted = {}
    for index, chapter in ipairs(chapters) do sorted[index] = chapter end
    table.sort(sorted, function(a, b)
        return (a.chapterIdx or a.chapterUid or 0) < (b.chapterIdx or b.chapterUid or 0)
    end)
    return sorted
end

local function xml_escape(text)
    return (tostring(text or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

local function decode_entities(text)
    text = tostring(text or "")
    text = text:gsub("&nbsp;", " "):gsub("&#160;", " "):gsub("&#x[Aa]0;", " ")
    text = text:gsub("&amp;", "&"):gsub("&#38;", "&")
    text = text:gsub("&lt;", "<"):gsub("&gt;", ">")
    text = text:gsub("&quot;", '"'):gsub("&#34;", '"')
    text = text:gsub("&apos;", "'"):gsub("&#39;", "'")
    return text
end

local function strip_tags(html)
    html = tostring(html or "")
    html = html:gsub("<[bB][rR]%s*/?>", " ")
    html = html:gsub("</[pP]%s*>", " "):gsub("</[dD][iI][vV]%s*>", " ")
    html = html:gsub("<[^>]+>", " ")
    html = decode_entities(html)
    html = html:gsub("\226\128\139", ""):gsub("\226\128\140", ""):gsub("\226\128\141", "")
    return html:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
end

local function cleanup_footnote_text(text)
    text = strip_tags(text)
    text = text:gsub("^%[%s*[%d一二三四五六七八九十]+%s*%]%s*", "")
    text = text:gsub("^[%*†‡※]%s*", "")
    return text:match("^%s*(.-)%s*$") or ""
end

local function is_trivial_footnote_text(text)
    text = strip_tags(text)
    if text == "" then return true end
    return text:match("^%[%s*%d+%s*%]$") ~= nil or text:match("^%d+$") ~= nil
end

local function attr_pattern_name(name)
    return tostring(name or ""):gsub("([^%w])", "%%%1")
end

local function get_attr(attrs, name)
    attrs = tostring(attrs or "")
    name = attr_pattern_name(name)
    local value = attrs:match('^%s*' .. name .. '%s*=%s*"([^"]*)"')
        or attrs:match('%s+' .. name .. '%s*=%s*"([^"]*)"')
    if value ~= nil then return value end
    value = attrs:match("^%s*" .. name .. "%s*=%s*'([^']*)'")
        or attrs:match("%s+" .. name .. "%s*=%s*'([^']*)'")
    if value ~= nil then return value end
    local lower = attrs:lower()
    local ls, le = lower:find(name:lower() .. "%s*=%s*")
    if not ls then return nil end
    local tail = attrs:sub(le + 1)
    local quote = tail:sub(1, 1)
    if quote == '"' then return tail:match('^"([^"]*)"') end
    if quote == "'" then return tail:match("^'([^']*)'") end
end

local function has_token(value, token)
    value = " " .. tostring(value or ""):lower():gsub("%s+", " ") .. " "
    return value:find(" " .. token:lower() .. " ", 1, true) ~= nil
end

local function escape_pattern(value)
    return tostring(value or ""):gsub("([^%w])", "%%%1")
end

local function basename(path)
    return tostring(path or ""):gsub("\\", "/"):match("([^/]+)$") or tostring(path or "")
end

local function split_href(href)
    href = decode_entities(href):gsub("^%s+", ""):gsub("%s+$", "")
    local file, anchor = href:match("^(.-)#(.+)$")
    if not anchor then return nil, nil end
    anchor = anchor:gsub("%%([%x][%x])", function(hex) return string.char(tonumber(hex, 16)) end)
    return file or "", anchor
end

local function extract_anchor_text(html, anchor)
    if type(html) ~= "string" or anchor == nil or anchor == "" then return nil end
    local tags = { "aside", "li", "p", "div", "section", "blockquote", "dd", "td" }
    for _, tag in ipairs(tags) do
        local pattern = "<" .. tag .. "([^>]*)>(.-)</" .. tag .. "%s*>"
        for attrs, inner in html:gmatch(pattern) do
            if get_attr(attrs, "id") == anchor or get_attr(attrs, "name") == anchor then
                local text = cleanup_footnote_text(inner)
                if text ~= "" and not is_trivial_footnote_text(text) then return text end
            end
        end
        local upper = tag:upper()
        if upper ~= tag then
            local upattern = "<" .. upper .. "([^>]*)>(.-)</" .. upper .. "%s*>"
            for attrs, inner in html:gmatch(upattern) do
                if get_attr(attrs, "id") == anchor or get_attr(attrs, "name") == anchor then
                    local text = cleanup_footnote_text(inner)
                    if text ~= "" and not is_trivial_footnote_text(text) then return text end
                end
            end
        end
    end

    -- Some books place an empty named anchor immediately before the note paragraph.
    local escaped = escape_pattern(anchor)
    local patterns = {
        '<[aA][^>]-id="' .. escaped .. '"[^>]*>%s*</[aA]>%s*<[pP][^>]*>(.-)</[pP]>',
        "<[aA][^>]-id='" .. escaped .. "'[^>]*>%s*</[aA]>%s*<[pP][^>]*>(.-)</[pP]>",
        '<[aA][^>]-name="' .. escaped .. '"[^>]*>%s*</[aA]>%s*<[pP][^>]*>(.-)</[pP]>',
        "<[aA][^>]-name='" .. escaped .. "'[^>]*>%s*</[aA]>%s*<[pP][^>]*>(.-)</[pP]>",
    }
    for _, pattern in ipairs(patterns) do
        local block = html:match(pattern)
        if block then
            local text = cleanup_footnote_text(block)
            if text ~= "" and not is_trivial_footnote_text(text) then return text end
        end
    end
end

local function anchor_cache_path(book_dir)
    return join_path(book_dir, "footnotes/anchors.json")
end

function Footnotes.load_anchor_cache(book_dir)
    if type(book_dir) ~= "string" or book_dir == "" then return {} end
    local file = io.open(anchor_cache_path(book_dir), "r")
    if not file then return {} end
    local data = file:read("*a"); file:close()
    if not ok_json then return {} end
    local ok, parsed = pcall(JSON.decode, data or "")
    return ok and type(parsed) == "table" and parsed or {}
end

function Footnotes.save_anchor_cache(book_dir, cache)
    if type(book_dir) ~= "string" or book_dir == "" or type(cache) ~= "table" or not ok_json then return end
    ensure_dir(join_path(book_dir, "footnotes"))
    local ok, encoded = pcall(JSON.encode, cache)
    if not ok then return end
    local file = io.open(anchor_cache_path(book_dir), "w")
    if not file then return end
    file:write(encoded); file:close()
end

function Footnotes.index_anchors(html)
    local map, seen = {}, {}
    if type(html) ~= "string" or html == "" then return map end
    for tag in html:gmatch("<[%a][^>]*>") do
        local anchor = get_attr(tag, "id") or get_attr(tag, "name")
        if anchor and anchor ~= "" and not seen[anchor] then
            seen[anchor] = true
            local text = extract_anchor_text(html, anchor)
            if text and text ~= "" then map[anchor] = text end
        end
    end
    return map
end

local function img_is_footnote(attrs)
    local class = get_attr(attrs, "class") or ""
    local lower = class:lower()
    return has_token(class, "qqreader-footnote")
        or has_token(class, "footnote-icon")
        or has_token(class, "footnote-ref")
        or has_token(class, "note-ref")
        or lower == "footnote"
end

function Footnotes.convert_img_footnotes(html)
    if type(html) ~= "string" or html == "" then return html, {} end
    local notes, fn_idx = {}, 0
    local result = html:gsub("<[iI][mM][gG]([^>]*)>", function(attrs)
        attrs = attrs:gsub("%s*/%s*$", "")
        if not img_is_footnote(attrs) then return "<img" .. attrs .. "/>" end
        local text = get_attr(attrs, "alt") or get_attr(attrs, "title")
            or get_attr(attrs, "data-content") or get_attr(attrs, "data-note") or ""
        text = cleanup_footnote_text(text)
        if text == "" then return "<img" .. attrs .. "/>" end
        fn_idx = fn_idx + 1
        notes[#notes + 1] = { display = tostring(fn_idx), text = text, fn_idx = fn_idx }
        return string.format(
            '<span class="fn-ref"><a epub:type="noteref" role="doc-noteref" href="#wt_%d" id="wtref_%d">[%d]</a></span>',
            fn_idx, fn_idx, fn_idx
        )
    end)
    return result, notes
end

local function ref_display(inner)
    local display = strip_tags(inner)
    if display == "" then return "*" end
    if #display > 24 then return display:sub(1, 24) end
    return display
end

local function looks_like_footnote_ref(attrs, href, inner)
    local file, anchor = split_href(href)
    if not anchor or anchor == "" then return false end
    local lower_anchor = anchor:lower()
    if lower_anchor:find("wrthought-", 1, true) == 1
        or lower_anchor:find("miuthought-", 1, true) == 1
        or lower_anchor:find("wt_", 1, true) == 1 then return false end
    local epub_type = (get_attr(attrs, "epub:type") or ""):lower()
    local role = (get_attr(attrs, "role") or ""):lower()
    local class = (get_attr(attrs, "class") or ""):lower()
    if epub_type:find("noteref", 1, true) or role:find("doc-noteref", 1, true)
        or class:find("noteref", 1, true) or class:find("footnote", 1, true)
        or class:find("fn-ref", 1, true) then
        return true
    end
    local display = strip_tags(inner)
    local compact = display:gsub("%s+", "")
    local marker = compact:match("^%[?[%d一二三四五六七八九十]+%]?$")
        or compact:match("^[%*†‡※]+$")
    local anchor_hint = lower_anchor:find("note", 1, true) or lower_anchor:find("foot", 1, true)
        or lower_anchor:find("fn", 1, true) or lower_anchor:match("^n%d+")
    local file_hint = tostring(file or ""):lower():find("note", 1, true)
    return marker and (anchor_hint or file_hint or file == "") and true or false
end

function Footnotes.collect_footnote_refs(html)
    local refs = {}
    if type(html) ~= "string" then return refs end
    for attrs, inner in html:gmatch("<[aA]([^>]*)>(.-)</[aA]%s*>") do
        local href = get_attr(attrs, "href")
        if href and looks_like_footnote_ref(attrs, href, inner) then
            local file, anchor = split_href(href)
            refs[#refs + 1] = {
                href = href,
                file = basename(file),
                anchor = anchor,
                display = ref_display(inner),
            }
        end
    end
    return refs
end

-- Backward-compatible name used by older callers/tests.
function Footnotes.collect_cross_file_refs(html)
    return Footnotes.collect_footnote_refs(html)
end

function Footnotes.fetch_missing_anchors(meta, missing, ref_files)
    if type(missing) ~= "table" or #missing == 0 or type(meta) ~= "table" then return {} end
    local file_set = {}
    for _, file_name in ipairs(ref_files or {}) do
        if type(file_name) == "string" and file_name ~= "" then file_set[file_name] = true end
    end
    local book_dir = meta.book_dir
    local cache = Footnotes.load_anchor_cache(book_dir)
    local found, still_missing = {}, {}
    for _, anchor in ipairs(missing) do
        local cached = cache[anchor]
        if cached and cached ~= "" and not is_trivial_footnote_text(cached) then
            found[anchor] = cached
        else
            cache[anchor] = nil
            still_missing[#still_missing + 1] = anchor
        end
    end
    if #still_missing == 0 then return found end

    local chapters = meta.chapters
    if type(chapters) ~= "table" or #chapters == 0 then
        if type(meta.fetch_catalog) == "function" then
            local ok, toc = pcall(meta.fetch_catalog)
            if ok and type(toc) == "table" then chapters = toc end
        end
    end
    if type(chapters) ~= "table" or #chapters == 0 or type(meta.fetch_chapter_html) ~= "function" then return found end

    local sorted = sort_chapters(chapters)
    local scanned_uids = {}
    local function try_chapter(chapter, preloaded_html)
        if not chapter or not chapter.chapterUid or scanned_uids[chapter.chapterUid] then return end
        scanned_uids[chapter.chapterUid] = true
        local html = preloaded_html
        if not html then
            local ok, fetched = pcall(meta.fetch_chapter_html, chapter)
            if not ok or type(fetched) ~= "string" or fetched == "" then return end
            html = fetched
        end
        for _, anchor in ipairs(still_missing) do
            if not found[anchor] then
                local text = extract_anchor_text(html, anchor)
                if text and text ~= "" then found[anchor] = text; cache[anchor] = text end
            end
        end
        for i = #still_missing, 1, -1 do
            if found[still_missing[i]] then table.remove(still_missing, i) end
        end
    end

    -- First scan likely note chapters and chapters mentioning target filenames.
    for _, chapter in ipairs(sorted) do
        if #still_missing == 0 then break end
        local title = tostring(chapter.title or ""):lower()
        if title:find("注释", 1, true) or title:find("脚注", 1, true)
            or title:find("尾注", 1, true) or title:find("note", 1, true) then
            try_chapter(chapter)
        end
    end
    if next(file_set) and #still_missing > 0 then
        for _, chapter in ipairs(sorted) do
            if #still_missing == 0 then break end
            local ok, html = pcall(meta.fetch_chapter_html, chapter)
            if ok and type(html) == "string" and html ~= "" then
                for file_name in pairs(file_set) do
                    if html:find(file_name, 1, true) then try_chapter(chapter, html); break end
                end
            end
        end
    end
    -- Then scan from the end (endnotes are commonly near the back), finally all chapters.
    local scanned, max_scan = 0, math.min(40, #sorted)
    for i = #sorted, 1, -1 do
        if #still_missing == 0 or scanned >= max_scan then break end
        try_chapter(sorted[i]); scanned = scanned + 1
    end
    for _, chapter in ipairs(sorted) do
        if #still_missing == 0 then break end
        try_chapter(chapter)
    end
    if next(cache) then Footnotes.save_anchor_cache(book_dir, cache) end
    return found
end

local function convert_anchor_refs(html, anchor_texts, fn_offset)
    local notes, fn_idx = {}, fn_offset or 0
    local result = html:gsub("<[aA]([^>]*)>(.-)</[aA]%s*>", function(attrs, inner)
        local href = get_attr(attrs, "href")
        if not href or not looks_like_footnote_ref(attrs, href, inner) then
            return "<a" .. attrs .. ">" .. inner .. "</a>"
        end
        local _, anchor = split_href(href)
        local text = anchor and anchor_texts[anchor]
        if not text or text == "" or is_trivial_footnote_text(text) then
            return "<a" .. attrs .. ">" .. inner .. "</a>"
        end
        fn_idx = fn_idx + 1
        local display = ref_display(inner)
        notes[#notes + 1] = { display = display, text = text, anchor = anchor, fn_idx = fn_idx }
        return string.format(
            '<span class="fn-ref"><a epub:type="noteref" role="doc-noteref" href="#wt_%d" id="wtref_%d">%s</a></span>',
            fn_idx, fn_idx, xml_escape(display)
        )
    end)
    return result, notes
end

function Footnotes.convert_cross_file_footnotes(html, anchor_texts, fn_offset)
    return convert_anchor_refs(html, anchor_texts or {}, fn_offset or 0)
end

local function build_footnote_section(img_notes, anchor_notes)
    local total = #(img_notes or {}) + #(anchor_notes or {})
    if total == 0 then return "" end
    local parts = { '\n<div class="footnotes" role="doc-endnotes">\n<hr/>\n' }
    for _, note in ipairs(img_notes or {}) do
        parts[#parts + 1] = string.format(
            '<aside epub:type="footnote" role="doc-footnote" id="wt_%d" class="footnote weread-book-footnote"><p><a href="#wtref_%d" class="fn-num">[%s]</a> %s</p></aside>\n',
            note.fn_idx, note.fn_idx, xml_escape(note.display), xml_escape(note.text)
        )
    end
    for _, note in ipairs(anchor_notes or {}) do
        parts[#parts + 1] = string.format(
            '<aside epub:type="footnote" role="doc-footnote" id="wt_%d" class="footnote weread-book-footnote"><p><a href="#wtref_%d" class="fn-num">%s</a> %s</p></aside>\n',
            note.fn_idx, note.fn_idx, xml_escape(note.display), xml_escape(note.text)
        )
    end
    parts[#parts + 1] = "</div>\n"
    return table.concat(parts)
end

function Footnotes.process(html, meta)
    if type(html) ~= "string" or html == "" or (meta and meta.is_txt) then return html, "" end
    local local_index = Footnotes.index_anchors(html)
    local refs = Footnotes.collect_footnote_refs(html)
    local missing, ref_files, missing_seen, file_seen = {}, {}, {}, {}
    for _, ref in ipairs(refs) do
        if not local_index[ref.anchor] and not missing_seen[ref.anchor] then
            missing_seen[ref.anchor] = true; missing[#missing + 1] = ref.anchor
        end
        if ref.file and ref.file ~= "" and not file_seen[ref.file] then
            file_seen[ref.file] = true; ref_files[#ref_files + 1] = ref.file
        end
    end
    local remote = Footnotes.fetch_missing_anchors(meta, missing, ref_files)
    local anchor_texts = {}
    for _, ref in ipairs(refs) do anchor_texts[ref.anchor] = local_index[ref.anchor] or remote[ref.anchor] end

    local html1, img_notes = Footnotes.convert_img_footnotes(html)
    local html2, anchor_notes = convert_anchor_refs(html1, anchor_texts, #img_notes)
    local section = build_footnote_section(img_notes, anchor_notes)
    if section ~= "" then
        log_info("footnotes converted:", #img_notes + #anchor_notes, "notes")
    elseif #refs > 0 then
        log_info("footnotes refs found but content missing:", #refs)
    end
    return html2, section
end

return Footnotes
