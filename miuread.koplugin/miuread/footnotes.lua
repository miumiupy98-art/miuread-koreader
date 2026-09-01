--[[--
书籍脚注处理：
- 微信读书 qqreader-footnote 图片注脚
- EPUB3 epub:type="noteref" / role="doc-noteref"
- <sup><a href="#note">…</a></sup>、返回正文链接与跨章节尾注链接
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
local MiuUtil = require("miuread.util")

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
        local av=tonumber(a.chapterIdx or a.index or a.chapterUid or a.uid or 0) or 0
        local bv=tonumber(b.chapterIdx or b.index or b.chapterUid or b.uid or 0) or 0
        return av < bv
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

local function safe_attr(attrs,name)
    attrs=tostring(attrs or "")
    local escaped=tostring(name or ""):gsub("([^%w])","%%%1")
    return attrs:match('^%s*'..escaped..'%s*=%s*"([^"]*)"')
        or attrs:match('%s+'..escaped..'%s*=%s*"([^"]*)"')
        or attrs:match("^%s*"..escaped.."%s*=%s*'([^']*)'")
        or attrs:match("%s+"..escaped.."%s*=%s*'([^']*)'")
end

local function safe_href(value)
    value=decode_entities(value):match("^%s*(.-)%s*$") or ""
    local lower=value:lower()
    if lower=="" or lower:find("javascript:",1,true)==1 or lower:find("data:",1,true)==1
        or lower:find("vbscript:",1,true)==1 or lower:find("file:",1,true)==1 then return nil end
    return value
end

local NOTE_TAGS={
    p=true,div=true,span=true,strong=true,b=true,em=true,i=true,u=true,s=true,
    sub=true,sup=true,br=true,hr=true,a=true,blockquote=true,code=true,pre=true,
    ul=true,ol=true,li=true,dl=true,dt=true,dd=true,table=true,thead=true,
    tbody=true,tfoot=true,tr=true,th=true,td=true,ruby=true,rt=true,rp=true,
    img=true,figure=true,figcaption=true,h1=true,h2=true,h3=true,h4=true,h5=true,h6=true,
}

local function neutralize_thought_links(html)
    return tostring(html or ""):gsub("<[aA]([^>]*)>(.-)</[aA]%s*>", function(attrs, inner)
        local class=safe_attr(attrs,"class") or ""
        local href=safe_attr(attrs,"href") or ""
        local hint=(class.." "..href):lower()
        if hint:find("thought",1,true) or hint:find("miuread",1,true)
            or hint:find("miuthought",1,true) or hint:find("wrthought",1,true) then
            local kept=class~="" and class or "miu-footnote-mark"
            return '<span class="'..xml_escape(kept)..'">'..inner..'</span>'
        end
        return "<a"..attrs..">"..inner.."</a>"
    end)
end

local function sanitize_note_html(html)
    html=neutralize_thought_links(html)
    html=html:gsub("<!%-%-.-%-%->","")
    html=html:gsub("<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]%s*>","")
    html=html:gsub("<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]%s*>","")
    html=html:gsub("<([^>]+)>",function(raw)
        local closing=raw:match("^%s*/%s*([%w]+)")
        local name=(closing or raw:match("^%s*([%w]+)") or ""):lower()
        if not NOTE_TAGS[name] then return "" end
        if closing then return "</"..name..">" end
        if name=="br" or name=="hr" then return "<"..name.."/>" end
        if name=="a" then
            local href=safe_href(safe_attr(raw,"href") or "")
            if not href then return "<a>" end
            local class=safe_attr(raw,"class")
            local class_attr=""
            if class and (class:lower():find("thought",1,true) or class:lower():find("miuread",1,true)) then
                class_attr=' class="'..xml_escape(class)..'"'
            end
            return '<a href="'..xml_escape(href)..'"'..class_attr..'>'
        end
        if name=="img" then
            local src=safe_href(safe_attr(raw,"src") or "")
            if not src then return "" end
            local alt=safe_attr(raw,"alt") or ""
            local title=safe_attr(raw,"title")
            return '<img src="'..xml_escape(src)..'" alt="'..xml_escape(alt)..'"'
                ..(title and (' title="'..xml_escape(title)..'"') or '')..'/>'
        end
        if name=="span" then
            local class=safe_attr(raw,"class")
            if class and (class:lower():find("thought",1,true) or class:lower():find("miuread",1,true)) then
                return '<span class="'..xml_escape(class)..'">'
            end
        end
        return "<"..name..">"
    end)
    html=html:gsub("\226\128\139",""):gsub("\226\128\140",""):gsub("\226\128\141","")
    return html:match("^%s*(.-)%s*$") or ""
end

local function note_content(value)
    if type(value)=="table" then
        local html=sanitize_note_html(value.html or value.content or "")
        local text=strip_tags(value.text or html)
        return {html=html,text=text}
    end
    local html=sanitize_note_html(value)
    return {html=html,text=strip_tags(html)}
end

local function cleanup_footnote_text(text)
    text = strip_tags(text)
    text = text:gsub("^%[%s*[%d一二三四五六七八九十]+%s*%]%s*", "")
    text = text:gsub("^[%*†‡※]%s*", "")
    return text:match("^%s*(.-)%s*$") or ""
end

local function is_trivial_footnote_text(value)
    local text=type(value)=="table" and tostring(value.text or strip_tags(value.html or "")) or strip_tags(value)
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

local function normalize_ref_path(path)
    path=tostring(path or ""):gsub("\\","/"):gsub("^%s+",""):gsub("%s+$","")
    path=path:gsub("^/+","")
    local parts={}
    for part in path:gmatch("[^/]+") do
        if part==".." then
            if #parts>0 then table.remove(parts) end
        elseif part~="." and part~="" then
            parts[#parts+1]=part
        end
    end
    return table.concat(parts,"/"):lower()
end

local function ref_key(file,anchor)
    local normalized=normalize_ref_path(file)
    if normalized=="" then return tostring(anchor or "") end
    return normalized.."#"..tostring(anchor or "")
end

local function split_href(href)
    href = decode_entities(href):gsub("^%s+", ""):gsub("%s+$", "")
    local file, anchor = href:match("^(.-)#(.+)$")
    if not anchor then return nil, nil end
    anchor = anchor:gsub("%%([%x][%x])", function(hex) return string.char(tonumber(hex, 16)) end)
    return file or "", anchor
end

--- 从 id/name 锚点提取脚注正文（优先取 enclosing block 全文）。
-- @string html 全文章节 XHTML
-- @string anchor 锚点 id
-- @string|nil enclosing_block 锚点所在注块原文；由 index_anchors 一次性收集，
--   传入时直接取块内文本，避免对整篇文档逐标签 gmatch 重复扫描。
local function extract_anchor_text(html, anchor, enclosing_block)
    if type(html) ~= "string" or anchor == nil or anchor == "" then return nil end

    if type(enclosing_block) == "string" and enclosing_block ~= "" then
        local content=note_content(enclosing_block)
        content.text=cleanup_footnote_text(content.text)
        if content.text~="" and not is_trivial_footnote_text(content) then return content end
    end

    -- Some books place an empty named anchor immediately before the note paragraph.
    -- 注块总是紧邻锚点（同元素内，或紧随其后的兄弟块），故只在锚点周围的
    -- 窗口子串内做模式匹配：window:match 把 .- 回溯与模式搜索都限制在窗口内，
    -- 避免锚点不在注块时 .- 一路回溯到文档尾（脚注密集章节放大到每章数十秒）。
    -- 窗口足够覆盖紧邻兄弟块；命中结果与全文档匹配一致。
    local escaped = escape_pattern(anchor)
    local id_pos = html:find('id="' .. anchor .. '"', 1, true)
        or html:find('name="' .. anchor .. '"', 1, true)
        or html:find("id='" .. anchor .. "'", 1, true)
        or html:find("name='" .. anchor .. "'", 1, true)
    local from = id_pos and math.max(1, id_pos - 4096) or 1
    local to = id_pos and math.min(#html, id_pos + 4096) or #html
    local window = html:sub(from, to)
    local patterns = {
        '<[aA][^>]-id="' .. escaped .. '"[^>]*>%s*</[aA]>%s*<[pP][^>]*>(.-)</[pP]>',
        "<[aA][^>]-id='" .. escaped .. "'[^>]*>%s*</[aA]>%s*<[pP][^>]*>(.-)</[pP]>",
        '<[aA][^>]-name="' .. escaped .. '"[^>]*>%s*</[aA]>%s*<[pP][^>]*>(.-)</[pP]>',
        "<[aA][^>]-name='" .. escaped .. "'[^>]*>%s*</[aA]>%s*<[pP][^>]*>(.-)</[pP]>",
        '<[pP][^>]*>%s*<[aA][^>]-id="' .. escaped .. '"[^>]*>%s*</[aA]>%s*(.-)</[pP]>',
        "<[pP][^>]*>%s*<[aA][^>]-id='" .. escaped .. "'[^>]*>%s*</[aA]>%s*(.-)</[pP]>",
        '<[pP][^>]*>%s*<[aA][^>]-name="' .. escaped .. '"[^>]*>%s*</[aA]>%s*(.-)</[pP]>',
        "<[pP][^>]*>%s*<[aA][^>]-name='" .. escaped .. "'[^>]*>%s*</[aA]>%s*(.-)</[pP]>",
        '<[aA][^>]-id="' .. escaped .. '"[^>]*>(.-)</[aA]>',
        "<[aA][^>]-id='" .. escaped .. "'[^>]*>(.-)</[aA]>",
        '<[aA][^>]-name="' .. escaped .. '"[^>]*>(.-)</[aA]>',
        "<[aA][^>]-name='" .. escaped .. "'[^>]*>(.-)</[aA]>",
    }
    for _, pattern in ipairs(patterns) do
        local block = window:match(pattern)
        if block then
            local content=note_content(block)
            content.text=cleanup_footnote_text(content.text)
            if content.text~="" and not is_trivial_footnote_text(content) then return content end
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

    -- 一次性 O(n) 收集注块 id -> 块原文（aside/li/p/div/.../td 任一容器标签）。
    -- 原实现逐 anchor 对整篇文档重复 gmatch：脚注锚点数 × 文档长度，在脚注
    -- 密集章节会放大到每章数秒~数十秒。预收集后每个锚点 O(1) 命中所属注块。
    local block_of_id = {}
    local tags = { "aside", "li", "p", "div", "section", "blockquote", "dd", "td" }
    for _, tag in ipairs(tags) do
        local pattern = "<" .. tag .. "([^>]*)>(.-)</" .. tag .. "%s*>"
        for attrs, inner in html:gmatch(pattern) do
            local id = get_attr(attrs, "id") or get_attr(attrs, "name")
            if id and id ~= "" and not block_of_id[id] then block_of_id[id] = inner end
        end
        local upper = tag:upper()
        if upper ~= tag then
            local upattern = "<" .. upper .. "([^>]*)>(.-)</" .. upper .. "%s*>"
            for attrs, inner in html:gmatch(upattern) do
                local id = get_attr(attrs, "id") or get_attr(attrs, "name")
                if id and id ~= "" and not block_of_id[id] then block_of_id[id] = inner end
            end
        end
    end

    for tag in html:gmatch("<[%a][^>]*>") do
        local anchor = get_attr(tag, "id") or get_attr(tag, "name")
        if anchor and anchor ~= "" and not seen[anchor] then
            seen[anchor] = true
            local text = extract_anchor_text(html, anchor, block_of_id[anchor])
            if text and text ~= "" then map[anchor] = text end
        end
    end
    return map
end

local function collect_anchor_presence(html)
    local present = {}
    if type(html) ~= "string" or html == "" then return present end
    for tag in html:gmatch("<[%a][^>]*>") do
        local anchor = get_attr(tag, "id") or get_attr(tag, "name")
        if anchor and anchor ~= "" then present[anchor] = true end
    end
    return present
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
    return MiuUtil.utf8_truncate(display, 24, "")
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

    -- EPUB return links are navigation helpers, not new footnote references.
    -- A number of books reuse the generic "footnote" class on both directions,
    -- so explicit backlink signals must win before the broad class check below.
    if epub_type:find("backlink", 1, true) or role:find("doc-backlink", 1, true)
        or class:find("backlink", 1, true) or class:find("backref", 1, true)
        or class:find("footnote-back", 1, true) or class:find("note-back", 1, true) then
        return false
    end

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
        or lower_anchor:find("fn", 1, true) or lower_anchor:match("^n[_%-]?%d+")
        or lower_anchor:match("^[wr][_%-%d]*%d+")
        or lower_anchor:match("^ref[_%-]?%d+")
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
            local normalized_file=normalize_ref_path(file)
            refs[#refs + 1] = {
                href = href,
                file = normalized_file,
                basename = basename(normalized_file),
                anchor = anchor,
                key = ref_key(normalized_file,anchor),
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

function Footnotes.fetch_missing_anchors(meta, missing_refs, ref_files)
    if type(missing_refs) ~= "table" or #missing_refs == 0 or type(meta) ~= "table" then return {} end
    local refs={}
    for _,item in ipairs(missing_refs) do
        if type(item)=="table" then
            local file=normalize_ref_path(item.file or "")
            local anchor=tostring(item.anchor or "")
            refs[#refs+1]={file=file,basename=basename(file),anchor=anchor,key=item.key or ref_key(file,anchor)}
        else
            local anchor=tostring(item or "")
            refs[#refs+1]={file="",basename="",anchor=anchor,key=anchor}
        end
    end
    local file_set = {}
    for _, ref in ipairs(refs) do
        if ref.basename~="" then file_set[ref.basename]=true end
    end
    for _, file_name in ipairs(ref_files or {}) do
        local base=basename(normalize_ref_path(file_name))
        if base~="" then file_set[base]=true end
    end

    local book_dir = meta.book_dir
    local cache = Footnotes.load_anchor_cache(book_dir)
    local found, still_missing = {}, {}
    for _, ref in ipairs(refs) do
        local cached = cache[ref.key]
        if cached and not is_trivial_footnote_text(cached) then
            found[ref.key]=note_content(cached)
        else
            cache[ref.key]=nil
            still_missing[#still_missing+1]=ref
        end
    end
    if #still_missing==0 then return found end

    local chapters=meta.chapters
    if type(chapters)~="table" or #chapters==0 then
        if type(meta.fetch_catalog)=="function" then
            local ok,toc=pcall(meta.fetch_catalog)
            if ok and type(toc)=="table" then chapters=toc end
        end
    end
    if type(chapters)~="table" or #chapters==0 or type(meta.fetch_chapter_html)~="function" then return found end

    local sorted=sort_chapters(chapters)
    local scanned_uids={}
    if meta.current_chapter_uid~=nil then scanned_uids[tostring(meta.current_chapter_uid)]=true end
    local max_scan=math.max(1,tonumber(meta.max_remote_chapters) or 8)
    local scanned=0

    local function remember_from_html(chapter,html)
        local matched={}
        for _,ref in ipairs(still_missing) do
            if not found[ref.key] then
                local content=extract_anchor_text(html,ref.anchor)
                if content and not is_trivial_footnote_text(content) then
                    content=note_content(content)
                    found[ref.key]=content
                    cache[ref.key]=content
                    matched[#matched+1]=ref
                end
            end
        end
        if #matched>0 and type(meta.decorate_chapter_html)=="function" then
            local ok,decorated=pcall(meta.decorate_chapter_html,chapter,html)
            if ok and type(decorated)=="string" and decorated~="" then
                for _,ref in ipairs(matched) do
                    local content=extract_anchor_text(decorated,ref.anchor)
                    if content and not is_trivial_footnote_text(content) then
                        content=note_content(content)
                        found[ref.key]=content
                        cache[ref.key]=content
                    end
                end
            end
        end
        for i=#still_missing,1,-1 do
            if found[still_missing[i].key] then table.remove(still_missing,i) end
        end
    end

    local function try_chapter(chapter)
        if scanned>=max_scan or #still_missing==0 then return end
        local uid=chapter and (chapter.chapterUid or chapter.uid)
        if not chapter or uid==nil or scanned_uids[tostring(uid)] then return end
        scanned_uids[tostring(uid)]=true
        scanned=scanned+1
        local ok,html=pcall(meta.fetch_chapter_html,chapter)
        if ok and type(html)=="string" and html~="" then remember_from_html(chapter,html) end
    end

    local function chapter_file_matches(chapter)
        if not next(file_set) or type(chapter)~="table" then return false end
        for _,key in ipairs({"href","file","filename","fileName","path","url","chapterPath","chapterUrl"}) do
            local value=chapter[key]
            if type(value)=="string" and value~="" and file_set[basename(normalize_ref_path(value))] then return true end
        end
        return false
    end

    -- Only exact catalog filename matches and explicitly named note chapters are
    -- allowed. Never fall back to scanning the tail or the entire book while a
    -- chapter is being processed.
    for _,chapter in ipairs(sorted) do
        if scanned>=max_scan or #still_missing==0 then break end
        if chapter_file_matches(chapter) then try_chapter(chapter) end
    end
    for _,chapter in ipairs(sorted) do
        if scanned>=max_scan or #still_missing==0 then break end
        local title=tostring(chapter.title or ""):lower()
        if title:find("注释",1,true) or title:find("脚注",1,true)
            or title:find("尾注",1,true) or title:find("附注",1,true)
            or title:find("note",1,true) then
            try_chapter(chapter)
        end
    end
    if next(cache) then Footnotes.save_anchor_cache(book_dir,cache) end
    return found
end

local function convert_anchor_refs(html, anchor_texts, fn_offset)
    local notes, fn_idx = {}, fn_offset or 0
    local result = html:gsub("<[aA]([^>]*)>(.-)</[aA]%s*>", function(attrs, inner)
        local href = get_attr(attrs, "href")
        if not href or not looks_like_footnote_ref(attrs, href, inner) then
            return "<a" .. attrs .. ">" .. inner .. "</a>"
        end
        local file, anchor = split_href(href)
        local content=anchor and (anchor_texts[ref_key(file,anchor)] or anchor_texts[anchor])
        if not content or is_trivial_footnote_text(content) then
            return "<a" .. attrs .. ">" .. inner .. "</a>"
        end
        content=note_content(content)
        fn_idx = fn_idx + 1
        local display = ref_display(inner)
        notes[#notes + 1] = { display=display, text=content.text, html=content.html, anchor=anchor, fn_idx=fn_idx }
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
        local body=sanitize_note_html(note.html or "")
        if body=="" then body=xml_escape(note.text) end
        parts[#parts + 1] = string.format(
            '<aside epub:type="footnote" role="doc-footnote" id="wt_%d" class="footnote weread-book-footnote"><p><a href="#wtref_%d" class="fn-num">%s</a> %s</p></aside>\n',
            note.fn_idx,note.fn_idx,xml_escape(note.display),body
        )
    end
    parts[#parts + 1] = "</div>\n"
    return table.concat(parts)
end


-- A converted EPUB3 footnote replaces the publisher's original endnote
-- container. Keep unresolved source notes, but remove only source containers
-- whose id/name was actually converted so the same note is not rendered twice.
local function strip_converted_footnote_sources(html, notes)
    local converted = {}
    for _, note in ipairs(notes or {}) do
        local anchor = tostring(note and note.anchor or "")
        if anchor ~= "" then converted[anchor] = true end
    end
    if not next(converted) then return html, 0 end

    local removed = 0
    local tags = { "p", "li", "aside", "dd", "div" }
    for _, tag in ipairs(tags) do
        html = html:gsub("<" .. tag .. "(%s+[^>]*)>(.-)</" .. tag .. "%s*>", function(attrs, inner)
            local cls = (get_attr(attrs, "class") or ""):lower()
            if not (has_token(cls, "footnote") or has_token(cls, "endnote") or has_token(cls, "note")) then
                return nil
            end
            local id = get_attr(attrs, "id") or get_attr(attrs, "name") or ""
            if converted[id] then
                removed = removed + 1
                return ""
            end
            return nil
        end)
    end

    if removed > 0 then
        html = html:gsub('<[hH][rR][^>]*%sclass="[^"]*footnote%-separator[^"]*"[^>]*%s*/?>', "")
            :gsub("<[hH][rR][^>]*%sclass='[^']*footnote%-separator[^']*'[^>]*%s*/?>", "")
    end
    return html, removed
end

function Footnotes.process(html, meta)
    local empty_stats={
        candidates=0,refs=0,converted=0,backlinks=0,image_notes=0,
        unresolved=0,deferred=0,missing_anchors={},missing_targets={},fallback=false,
    }
    if type(html) ~= "string" or html == "" or (meta and meta.is_txt) then return html, "", empty_stats end
    meta=type(meta)=="table" and meta or {}
    local local_index = Footnotes.index_anchors(html)
    local local_presence = collect_anchor_presence(html)
    local refs = Footnotes.collect_footnote_refs(html)
    local missing_refs, ref_files, missing_seen, file_seen = {}, {}, {}, {}
    for _, ref in ipairs(refs) do
        -- A present target with only a marker is normally the source reference
        -- reached by a footnote return link. It must never be fetched as note
        -- content or counted as a missing footnote.
        local is_local_backlink=local_presence[ref.anchor] and not local_index[ref.anchor]
        if not local_index[ref.anchor] and not is_local_backlink and not missing_seen[ref.key] then
            missing_seen[ref.key]=true
            missing_refs[#missing_refs+1]=ref
        end
        if not is_local_backlink and ref.file and ref.file~="" and not file_seen[ref.file] then
            file_seen[ref.file]=true
            ref_files[#ref_files+1]=ref.file
        end
    end

    local remote={}
    if not meta.defer_cross_file then
        remote=Footnotes.fetch_missing_anchors(meta,missing_refs,ref_files)
    end
    local anchor_texts, unresolved, deferred, backlinks = {}, {}, {}, {}
    local unresolved_seen, backlink_seen = {}, {}
    for _,ref in ipairs(refs) do
        local local_content=local_index[ref.anchor]
        local content=local_content or remote[ref.key] or remote[ref.anchor]
        local target_present=local_presence[ref.anchor] == true

        -- Cross-file links whose target is already present in the final chapter
        -- are deliberately kept as page links. The post-download link repairer
        -- will rewrite the stale filename while preserving comments and return
        -- links in the original tail-note page.
        if not (local_content and ref.file and ref.file~="") then
            anchor_texts[ref.key]=content
            if ref.file=="" then anchor_texts[ref.anchor]=content end
        end

        if not content then
            if target_present then
                if not backlink_seen[ref.key] then
                    backlink_seen[ref.key]=true
                    backlinks[#backlinks+1]=ref.key
                end
            elseif not unresolved_seen[ref.key] then
                unresolved_seen[ref.key]=true
                if meta.defer_cross_file and ref.file~="" then
                    deferred[#deferred+1]=ref.key
                else
                    unresolved[#unresolved+1]=ref.key
                end
            end
        end
    end

    local html1,img_notes=Footnotes.convert_img_footnotes(html)
    local html2,anchor_notes=convert_anchor_refs(html1,anchor_texts,#img_notes)
    local stripped_sources=0
    html2,stripped_sources=strip_converted_footnote_sources(html2,anchor_notes)

    -- Some WeRead books omit the source-reference id while still emitting one
    -- reverse link for every note. The resulting signature is exact pairing:
    -- N resolved note targets plus N marker-only reverse targets. Treat only
    -- that strict one-to-one pattern as backlinks; unknown unmatched targets
    -- remain unresolved and will be preserved by the downloader fallback.
    local inferred_backlinks=0
    if #unresolved>0 and #deferred==0 and #anchor_notes>0
        and #unresolved==#anchor_notes
        and #refs==(#anchor_notes+#unresolved+#backlinks) then
        for _,key in ipairs(unresolved) do backlinks[#backlinks+1]=key end
        inferred_backlinks=#unresolved
        unresolved={}
    end

    local section=build_footnote_section(img_notes,anchor_notes)
    local stats={
        candidates=#refs,
        refs=math.max(0,#refs-#backlinks),
        converted=#anchor_notes,backlinks=#backlinks,inferred_backlinks=inferred_backlinks,
        image_notes=#img_notes,stripped=stripped_sources,
        unresolved=#unresolved,deferred=#deferred,
        missing_anchors=unresolved,missing_targets=deferred,backlink_targets=backlinks,
        fallback=false,
    }
    log_info("candidates=",tostring(stats.candidates),"refs=",tostring(stats.refs),
        "converted=",tostring(stats.converted),"backlinks=",tostring(stats.backlinks),
        "inferred_backlinks=",tostring(stats.inferred_backlinks),
        "images=",tostring(stats.image_notes),"stripped=",tostring(stats.stripped),
        "missing=",tostring(stats.unresolved),
        "deferred=",tostring(stats.deferred))
    if stats.unresolved>0 then
        local sample={}
        for index,key in ipairs(unresolved) do if index>20 then break end; sample[#sample+1]=tostring(key) end
        log_info("missing targets:",table.concat(sample,","))
    end
    return html2,section,stats
end


--- Remove only generated reverse links whose source marker no longer exists.
-- A missing wtref_N affects "back to text" navigation, not the footnote body.
-- Forward links to a missing wt_N are intentionally not repaired here.
function Footnotes.repair_missing_generated_backlinks(html)
    if type(html)~="string" then return html,0 end
    local ids={}
    for raw in html:gmatch("<[^>]+>") do
        if not raw:match("^<%s*/") then
            local id=get_attr(raw,"id")
            if id and id~="" then ids[id]=true end
        end
    end
    local repaired=0
    local out=html:gsub("<[aA]([%s][^>]*)>(.-)</[aA]%s*>",function(attrs,inner)
        local href=get_attr(attrs,"href")
        local target=href and href:match("^#(wtref_[%w_%-%.]+)$")
        if target and not ids[target] then
            repaired=repaired+1
            return '<span class="fn-num">'..inner..'</span>'
        end
        return "<a"..attrs..">"..inner.."</a>"
    end)
    return out,repaired
end

function Footnotes.validate(html)
    if type(html)~="string" then return nil,"章节正文无效" end
    local ids={}
    for raw in html:gmatch("<[^>]+>") do
        local closing=raw:match("^<%s*/")~=nil
        if not closing then
            local id=get_attr(raw,"id")
            if id and id~="" then
                local generated=id:match("^wt_") or id:match("^wtref_")
                if generated and ids[id] then return nil,"检测到重复脚注目标："..tostring(id) end
                if generated then ids[id]=true end
            end
        end
    end
    for attrs in html:gmatch("<[aA]([^>]*)>") do
        local href=get_attr(attrs,"href")
        local target=href and (href:match("^#(wt_[%w_%-%.]+)$") or href:match("^#(wtref_[%w_%-%.]+)$"))
        if target and not ids[target] then return nil,"脚注目标不存在："..tostring(target) end
    end
    return true
end

Footnotes._sanitize_note_html=sanitize_note_html
Footnotes._note_content=note_content
Footnotes._normalize_ref_path=normalize_ref_path
Footnotes._ref_key=ref_key
Footnotes._collect_anchor_presence=collect_anchor_presence
return Footnotes
