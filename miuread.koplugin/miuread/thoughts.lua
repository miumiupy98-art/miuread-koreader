local ThoughtDatabase = require("miuread.thought_database")
local Json = require("miuread.json")
local U = require("miuread.util")
local lfs = require("libs/libkoreader-lfs")

local Thoughts = {}

local POPUP_CACHE_LIMIT = 16
local POPUP_CACHE_VERSION = "4"
local GROUP_CACHE_LIMIT = 24
local popup_cache = {}
local popup_cache_order = {}
local group_cache = {}
local group_cache_order = {}

local function cache_touch(order, key)
    for i = #order, 1, -1 do
        if order[i] == key then table.remove(order, i); break end
    end
    order[#order + 1] = key
end

local function cache_trim(cache, order, limit)
    while #order > limit do
        local expired = table.remove(order, 1)
        cache[expired] = nil
    end
end


local function group_content_signature(group)
    if type(group) ~= "table" then return "empty" end
    -- Keep the cache identity local to this exact comment group. A whole-book
    -- SQLite mtime changes whenever any chapter is updated, which used to
    -- invalidate unrelated visible comments. Lua hashes this immutable string
    -- internally, avoiding an extra pure-Lua cryptographic digest on a tap.
    local parts = {}
    for _, item in ipairs(group.texts or {}) do
        parts[#parts + 1] = table.concat({
            tostring(item.review_id or item.reviewId or ""),
            tostring(item.author or ""),
            tostring(item.abstract or ""),
            tostring(item.content or ""),
            tostring(tonumber(item.likes or 0) or 0),
        }, "\31")
    end
    return table.concat(parts, "\30")
end

local function file_signature(path)
    local attr = lfs.attributes(tostring(path or ""))
    if type(attr) ~= "table" then return nil end
    return tostring(attr.modification or 0) .. ":" .. tostring(attr.size or 0)
end

local function invalidate_path(path)
    local prefix = tostring(path or "") .. "|"
    for key in pairs(popup_cache) do
        if key:find(prefix, 1, true) == 1 or key:find("native|" .. prefix, 1, true) == 1 then
            popup_cache[key] = nil
        end
    end
    for i = #popup_cache_order, 1, -1 do
        local key = popup_cache_order[i]
        if key:find(prefix, 1, true) == 1 or key:find("native|" .. prefix, 1, true) == 1 then
            table.remove(popup_cache_order, i)
        end
    end
end

local function hex_encode(value)
    return (tostring(value or ""):gsub(".", function(ch)
        return string.format("%02x", ch:byte())
    end))
end

local function hex_decode(value)
    if type(value) ~= "string" or value == "" or value:find("[^0-9a-fA-F]") or #value % 2 ~= 0 then
        return nil
    end
    return (value:gsub("(%x%x)", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

local function codepoint_len(value)
    local text = tostring(value or "")
    local count, i = 0, 1
    while i <= #text do
        local b = text:byte(i)
        if b < 0x80 then i = i + 1
        elseif b < 0xE0 then i = i + 2
        elseif b < 0xF0 then i = i + 3
        else i = i + 4 end
        count = count + 1
    end
    return count
end

-- Approximate the rendered width in CJK em units. This is used only to size
-- the fixed source area before MuPDF lays it out: CJK characters occupy about
-- one em, while Latin letters, digits, spaces and punctuation are narrower.
local function display_units(value)
    local text = tostring(value or "")
    local units, i = 0, 1
    while i <= #text do
        local b = text:byte(i)
        if b < 0x80 then
            local ch = text:sub(i, i)
            if ch:match("%s") then
                units = units + 0.32
            elseif ch:match("[%w]") then
                units = units + 0.56
            else
                units = units + 0.48
            end
            i = i + 1
        elseif b < 0xE0 then
            units = units + 0.78
            i = i + 2
        elseif b < 0xF0 then
            units = units + 1.00
            i = i + 3
        else
            units = units + 1.12
            i = i + 4
        end
    end
    return units
end

local function utf8_slice(value, first, last)
    local text = tostring(value or "")
    local out, index, i = {}, 0, 1
    while i <= #text do
        local b = text:byte(i)
        local n = b < 0x80 and 1 or (b < 0xE0 and 2 or (b < 0xF0 and 3 or 4))
        index = index + 1
        if index >= first and (not last or index <= last) then out[#out + 1] = text:sub(i, i + n - 1) end
        if last and index >= last then break end
        i = i + n
    end
    return table.concat(out)
end

function Thoughts.anchor(book_id, chapter_uid, range)
    return "miuthought-" .. hex_encode(book_id) .. "." .. hex_encode(chapter_uid) .. "." .. hex_encode(range)
end

function Thoughts.href(book_id, chapter_uid, range)
    return "#" .. Thoughts.anchor(book_id, chapter_uid, range)
end

function Thoughts.mark_class(range)
    return "miu-mark-" .. hex_encode(range)
end

function Thoughts.parse_href(href)
    local anchor = tostring(href or ""):match("#?(miuthought%-[%x%.]+)")
    if not anchor then return nil end
    local b, c, r = anchor:match("^miuthought%-([%x]+)%.([%x]+)%.([%x]+)$")
    if not b then return nil end
    local book_id, chapter_uid, range = hex_decode(b), hex_decode(c), hex_decode(r)
    if not book_id or not chapter_uid or not range then return nil end
    return {book_id = book_id, chapter_uid = chapter_uid, range = range, anchor = anchor}
end

local function legacy_cache_path(store, book_id, chapter_uid)
    return store:book_dir(book_id) .. "/thoughts/" .. U.id_name(chapter_uid) .. ".json"
end

local function load_legacy(store, book_id, chapter_uid)
    local path=legacy_cache_path(store,book_id,chapter_uid)
    local raw=U.read_file(path,true)
    if not raw then return nil,"想法缓存不存在" end
    local ok,rows=pcall(Json.decode,raw)
    if not ok or type(rows)~="table" then return nil,"想法缓存损坏" end
    local index={}
    for _,row in ipairs(rows) do
        local key=tostring(type(row)=="table" and row.range or "")
        if key~="" and index[key]==nil then index[key]=row end
    end
    return rows,nil,{rows=rows,index=index,path=path,signature=file_signature(path),legacy=true}
end

function Thoughts.cache_dir(store, book_id)
    return store:book_dir(book_id)
end

function Thoughts.cache_path(store, book_id, chapter_uid)
    return ThoughtDatabase.path(store, book_id)
end

function Thoughts.save(store, book_id, chapter_uid, groups)
    local saved, err = ThoughtDatabase.save_chapter(store, book_id, chapter_uid, groups)
    if not saved then return nil, tostring(err or "想法数据库写入失败") end
    local path = ThoughtDatabase.path(store, book_id)
    invalidate_path(path)
    Thoughts.clear_memory_cache()
    return tonumber(saved.groups or 0) or 0, path
end

function Thoughts.load(store, book_id, chapter_uid)
    local rows, err = ThoughtDatabase.load_chapter(store, book_id, chapter_uid)
    if not rows then return load_legacy(store,book_id,chapter_uid) end
    local index = {}
    for _, row in ipairs(rows) do
        local key = tostring(type(row) == "table" and row.range or "")
        if key ~= "" and index[key] == nil then index[key] = row end
    end
    local path = ThoughtDatabase.path(store, book_id)
    local token = {rows=rows, index=index, path=path, signature=file_signature(path)}
    return rows, nil, token, false
end

function Thoughts.find(store, book_id, chapter_uid, range)
    local path=ThoughtDatabase.path(store,book_id)
    local signature=file_signature(path) or "missing"
    local range_key=tostring(range or "")
    local cache_key=table.concat({tostring(book_id or ""),tostring(chapter_uid or ""),range_key,signature},"|")
    local cached=group_cache[cache_key]
    if cached then
        cache_touch(group_cache_order,cache_key)
        return cached,nil,{path=path,database=path,signature=signature,index_hit=true,authoritative=true,cache_hit=true}
    end
    local group, err, token = ThoughtDatabase.find(store, book_id, chapter_uid, range)
    if group then
        token = type(token) == "table" and token or {}
        token.path = token.database or path
        token.signature = signature
        group_cache[cache_key]=group
        cache_touch(group_cache_order,cache_key)
        cache_trim(group_cache,group_cache_order,GROUP_CACHE_LIMIT)
        return group, nil, token
    end
    if type(token)=="table" and token.authoritative==true then return nil,err end
    local _,legacy_error,cached=load_legacy(store,book_id,chapter_uid)
    if cached and cached.index[tostring(range or "")] then
        return cached.index[tostring(range or "")],nil,cached
    end
    return nil, legacy_error or err or "没有找到该划线对应的想法"
end

local function is_edge_blank_at(text, index, length)
    local byte = text:byte(index)
    if not byte then return false, 0 end
    if byte == 0x09 or byte == 0x0A or byte == 0x0B or byte == 0x0C
        or byte == 0x0D or byte == 0x20 then
        return true, 1
    end
    if byte == 0xC2 and index + 1 <= length and text:byte(index + 1) == 0xA0 then
        return true, 2 -- no-break space
    end
    if byte == 0xE2 and index + 2 <= length and text:byte(index + 1) == 0x80 then
        local third = text:byte(index + 2)
        if third == 0x8B or third == 0x8C then
            return true, 3 -- zero-width space / non-joiner
        end
    end
    if byte == 0xE3 and index + 2 <= length
        and text:byte(index + 1) == 0x80 and text:byte(index + 2) == 0x80 then
        return true, 3 -- ideographic space
    end
    if byte == 0xEF and index + 2 <= length
        and text:byte(index + 1) == 0xBB and text:byte(index + 2) == 0xBF then
        return true, 3 -- byte-order mark
    end
    return false, 0
end

local function trim_edge_blanks(text)
    text = tostring(text or "")
    local length = #text
    if length == 0 then return text end
    local first = 1
    while first <= length do
        local blank, bytes = is_edge_blank_at(text, first, length)
        if not blank then break end
        first = first + bytes
    end
    local last = length
    while last >= first do
        local start = last
        while start > first do
            local byte = text:byte(start)
            if not byte or byte < 0x80 or byte >= 0xC0 then break end
            start = start - 1
        end
        local blank, bytes = is_edge_blank_at(text, start, length)
        if not blank or start + bytes - 1 ~= last then break end
        last = start - 1
    end
    if first > last then return "" end
    if first == 1 and last == length then return text end
    return text:sub(first, last)
end

local function clean_body(value)
    local text = U.clean_utf8 and U.clean_utf8(value) or tostring(value or "")
    text = tostring(text or "")
        :gsub("\239\191\189", "")
        :gsub("\r\n", "\n")
        :gsub("\r", "\n")
        :gsub("[%z\1-\8\11\12\14-\31]", " ")
        :gsub("[ \t]+\n", "\n")
        :gsub("\n[ \t]+", "\n")
    return trim_edge_blanks(text)
end

local function clean_inline(value)
    return trim_edge_blanks(clean_body(value)
        :gsub("\194\160", " ")
        :gsub("\226\128[\139\140]", " ")
        :gsub("\227\128\128", " ")
        :gsub("[%c]+", " ")
        :gsub("%s+", " "))
end

local clean = clean_inline

local function preview(value, max_chars)
    local text = clean(value)
    max_chars = tonumber(max_chars) or 84
    if codepoint_len(text) <= max_chars then return text end
    return utf8_slice(text, 1, max_chars) .. "……"
end

local function split_entry(item, chunk_chars)
    local author = clean(item.author)
    if author == "" then author = "微信读书用户" end
    local content = clean_body(item.content)
    local abstract = clean(item.abstract)
    local base = {
        author = author,
        likes = tonumber(item.likes or 0) or 0,
        abstract = abstract,
        review_id = tostring(item.review_id or ""),
    }
    local total = math.max(1, math.ceil(codepoint_len(content) / chunk_chars))
    local rows = {}
    if content == "" then
        local row = U.copy(base); row.content = "（无正文）"; row.part = 1; row.parts = 1; rows[1] = row
        return rows
    end
    for part = 1, total do
        local row = U.copy(base)
        row.content = utf8_slice(content, (part - 1) * chunk_chars + 1, part * chunk_chars)
        row.part, row.parts = part, total
        if part > 1 then row.abstract = "" end
        rows[#rows + 1] = row
    end
    return rows
end

local FONT_PROFILE = {
    standard = {font_size = 19, page_budget = 600, chunk_chars = 170},
    large = {font_size = 22, page_budget = 520, chunk_chars = 150},
    xlarge = {font_size = 25, page_budget = 430, chunk_chars = 125},
}

function Thoughts.font_profile(level)
    return FONT_PROFILE[tostring(level or "standard")] or FONT_PROFILE.standard
end

function Thoughts.paginate(group, level)
    if type(group) ~= "table" then return {} end
    local profile = Thoughts.font_profile(level)
    local entries = {}
    for _, item in ipairs(group.texts or {}) do
        for _, part in ipairs(split_entry(item, profile.chunk_chars)) do entries[#entries + 1] = part end
    end
    local pages, page, weight = {}, {}, 0
    local function flush()
        if #page > 0 then pages[#pages + 1] = page; page = {}; weight = 0 end
    end
    for _, item in ipairs(entries) do
        local item_weight = codepoint_len(item.content) + math.floor(codepoint_len(item.abstract) * 0.45) + 32
        local max_entries = 4
        local minimum_before_wrap = 3
        if #page >= max_entries or (#page >= minimum_before_wrap and weight + item_weight > profile.page_budget) then flush() end
        page[#page + 1] = item
        weight = weight + item_weight
        if weight > profile.page_budget and #page >= 3 then flush() end
    end
    flush()
    if #pages >= 2 and #pages[#pages] < 3 and #pages[#pages - 1] > 3 then
        while #pages[#pages] < 3 and #pages[#pages - 1] > 3 do
            table.insert(pages[#pages], 1, table.remove(pages[#pages - 1]))
        end
    end
    return pages
end

local function panel_head_html(title)
    return '<div class="miu-panel-head">' .. U.xml(title or "评论") .. '</div>'
end

local function source_box_html(text)
    return '<div class="miu-source"><div class="miu-source-box">' .. U.xml(text or "") .. '</div></div>'
end

local function entry_html(item)
    local author = U.xml(item.author or "微信读书用户")
    local likes = tonumber(item.likes or 0) or 0
    local likes_text = likes > 0 and ("赞 " .. tostring(likes)) or ""
    local html = {
        '<div class="miu-comment">',
        '<div class="miu-meta">',
        '<span class="miu-author">', author, '</span>',
    }
    if likes_text ~= "" then
        -- Use non-breaking spaces plus a middle dot so the like count can
        -- never be mistaken for part of the author's name, even when MuPDF
        -- ignores margins between adjacent inline spans.
        html[#html + 1] = '<span class="miu-likes">&#160;·&#160;'
        html[#html + 1] = U.xml(likes_text)
        html[#html + 1] = '</span>'
    end
    html[#html + 1] = '</div>'
    html[#html + 1] = '<div class="miu-content">'
    html[#html + 1] = U.xml(item.content or "")
    html[#html + 1] = '</div>'
    html[#html + 1] = '</div>'
    return table.concat(html)
end

function Thoughts.group_abstract(group)
    for _, item in ipairs((group and group.texts) or {}) do
        local abstract = clean(item.abstract)
        if abstract ~= "" then return abstract end
    end
    return ""
end

function Thoughts.page_html(page, page_index, page_count, abstract)
    local rows = {}
    local has_source = tostring(abstract or "") ~= ""
    rows[#rows + 1] = panel_head_html(has_source and "正文" or "评论")
    if has_source then
        rows[#rows + 1] = source_box_html(preview(abstract, 72))
    end
    for _, item in ipairs(page or {}) do
        if clean_body(item.content) ~= "" then rows[#rows + 1] = entry_html(item) end
    end
    return table.concat(rows)
end

function Thoughts.popup_parts(group)
    if type(group) ~= "table" then
        return "", "", {source_chars=0, source_units=0, comment_count=0, comment_chars={}, comment_units={}}
    end

    local fixed, body = {}, {}
    local metrics = {source_chars=0, source_units=0, comment_count=0, comment_chars={}, comment_units={}}
    local abstract = Thoughts.group_abstract(group)
    if abstract ~= "" then
        local source = preview(abstract, 240)
        metrics.source_chars = codepoint_len(source)
        metrics.source_units = display_units(source)
        fixed[#fixed + 1] = panel_head_html("正文")
        fixed[#fixed + 1] = source_box_html(source)
    else
        body[#body + 1] = panel_head_html("评论")
    end

    local seen = {}
    for _, item in ipairs(group.texts or {}) do
        local content = clean_body(item.content)
        if content ~= "" then
            local author = clean(item.author)
            if author == "" then author = "微信读书用户" end
            local review_id = tostring(item.review_id or "")
            local key = review_id ~= "" and ("id:" .. review_id) or (author .. "\0" .. content)
            if not seen[key] then
                seen[key] = true
                metrics.comment_count = metrics.comment_count + 1
                metrics.comment_chars[#metrics.comment_chars + 1] = codepoint_len(content)
                metrics.comment_units[#metrics.comment_units + 1] = display_units(content)
                body[#body + 1] = entry_html{
                    author = author,
                    content = content,
                    likes = tonumber(item.likes or 0) or 0,
                }
            end
        end
    end
    return table.concat(fixed), table.concat(body), metrics
end

function Thoughts.popup_parts_cached(store, book_id, chapter_uid, range, group, token)
    token = type(token) == "table" and token or {}
    local path = tostring(token.path or Thoughts.cache_path(store, book_id, chapter_uid))
    local signature = group_content_signature(group)
    local key = table.concat({POPUP_CACHE_VERSION, "html", tostring(book_id or ""), tostring(chapter_uid or ""), tostring(range or ""), signature}, "|")
    local cached = popup_cache[key]
    if cached then
        cache_touch(popup_cache_order, key)
        return cached.source_html, cached.html, cached.metrics, true
    end
    local source_html, html, metrics = Thoughts.popup_parts(group)
    popup_cache[key] = {source_html=source_html, html=html, metrics=metrics}
    cache_touch(popup_cache_order, key)
    cache_trim(popup_cache, popup_cache_order, POPUP_CACHE_LIMIT)
    return source_html, html, metrics, false
end




function Thoughts.native_parts(group)
    if type(group) ~= "table" then return "", {}, 0 end
    local source = clean_body(Thoughts.group_abstract(group))
    local comments, seen = {}, {}
    for _, item in ipairs(group.texts or {}) do
        local content = clean_body(item.content)
        if content ~= "" then
            local author = clean(item.author)
            if author == "" then author = "微信读书用户" end
            local review_id = tostring(item.review_id or "")
            local key = review_id ~= "" and ("id:" .. review_id) or (author .. "\0" .. content)
            if not seen[key] then
                seen[key] = true
                comments[#comments + 1] = {
                    author = author,
                    content = content,
                    likes = tonumber(item.likes or 0) or 0,
                    review_id = review_id,
                    created = tonumber(item.created or 0) or 0,
                }
            end
        end
    end
    return source, comments, #comments
end

function Thoughts.native_parts_cached(store, book_id, chapter_uid, range, group, token)
    token = type(token) == "table" and token or {}
    local path = tostring(token.path or Thoughts.cache_path(store, book_id, chapter_uid))
    local signature = group_content_signature(group)
    local key = table.concat({POPUP_CACHE_VERSION, "native", tostring(book_id or ""), tostring(chapter_uid or ""), tostring(range or ""), signature}, "|")
    local cached = popup_cache[key]
    if cached and cached.native == true then
        cache_touch(popup_cache_order, key)
        return cached.source, cached.comments, cached.count, true, signature
    end
    local source, comments, count = Thoughts.native_parts(group)
    popup_cache[key] = {native=true, source=source, comments=comments, count=count}
    cache_touch(popup_cache_order, key)
    cache_trim(popup_cache, popup_cache_order, POPUP_CACHE_LIMIT)
    return source, comments, count, false, signature
end

function Thoughts.plain_text(group)
    if type(group) ~= "table" then return "没有想法内容" end
    local lines = {}
    local abstract = Thoughts.group_abstract(group)
    if abstract ~= "" then
        lines[#lines + 1] = "正文"
        lines[#lines + 1] = abstract
        lines[#lines + 1] = ""
    end

    local seen = {}
    local count = 0
    for _, item in ipairs(group.texts or {}) do
        local content = clean_body(item.content)
        if content ~= "" then
            local author = clean(item.author)
            if author == "" then author = "微信读书用户" end
            local review_id = tostring(item.review_id or "")
            local key = review_id ~= "" and ("id:" .. review_id) or (author .. "\0" .. content)
            if not seen[key] then
                seen[key] = true
                count = count + 1
                local likes = tonumber(item.likes or 0) or 0
                local heading = author
                if likes > 0 then heading = heading .. " · 赞 " .. tostring(likes) end
                lines[#lines + 1] = heading
                lines[#lines + 1] = content
                lines[#lines + 1] = ""
            end
        end
    end
    if count == 0 then lines[#lines + 1] = "没有想法内容" end
    return table.concat(lines, "\n"):gsub("\n+$", "")
end


function Thoughts.comment_count(group)
    local seen, count = {}, 0
    for _, item in ipairs((group and group.texts) or {}) do
        local content = clean_body(item.content)
        if content ~= "" then
            local author = clean(item.author)
            local review_id = tostring(item.review_id or "")
            local key = review_id ~= "" and ("id:" .. review_id) or (author .. "\0" .. content)
            if not seen[key] then seen[key] = true; count = count + 1 end
        end
    end
    return count
end



function Thoughts.prewarm_groups(store, book_id, chapter_uid, groups)
    local path=ThoughtDatabase.path(store,book_id)
    local signature=file_signature(path) or "missing"
    local warmed,comments=0,0
    for _,group in ipairs(type(groups)=="table" and groups or {}) do
        local range=tostring(type(group)=="table" and group.range or "")
        if range~="" and type(group.texts)=="table" and #group.texts>0 then
            local cache_key=table.concat({tostring(book_id or ""),tostring(chapter_uid or ""),range,signature},"|")
            group_cache[cache_key]=group
            cache_touch(group_cache_order,cache_key)
            cache_trim(group_cache,group_cache_order,GROUP_CACHE_LIMIT)
            local _,_,count=Thoughts.native_parts_cached(store,book_id,chapter_uid,range,group,{
                path=path,database=path,signature=signature,index_hit=true,authoritative=true,cache_hit=true,
            })
            warmed=warmed+1
            comments=comments+(tonumber(count) or 0)
        end
    end
    return warmed,comments
end

function Thoughts.clear_memory_cache()
    popup_cache = {}
    popup_cache_order = {}
    group_cache = {}
    group_cache_order = {}
end

function Thoughts.full_html(group)
    local fixed, body, metrics = Thoughts.popup_parts(group)
    return fixed .. body, metrics
end

function Thoughts.popup_css()
    return [[
@page{margin:0}
html{margin:0!important;padding:0!important}
body{margin:0!important;padding:.18em .26em .20em .26em!important;line-height:1.18;color:#000;background:#fff}
.miu-panel-head{font-size:.52em;font-weight:normal;line-height:1.02;color:#555;margin:0 1.9em .16em 0;padding:0}
.miu-source{margin:0;padding:0}
.miu-source-box{font-size:.68em;line-height:1.15;color:#444;margin:0;padding:.17em .23em;border:1px solid #aaa}
.miu-comment{margin:0;padding:.10em 0 .09em 0;border:0;page-break-inside:avoid;break-inside:avoid-page}
.miu-comment+.miu-comment{margin-top:.09em;padding-top:.13em;border-top:1px solid #c8c8c8}
.miu-meta{margin:0;padding:0;line-height:1.02;page-break-after:avoid}
.miu-author{font-size:.47em;font-weight:normal;color:#666;line-height:1.02}
.miu-likes{font-size:.45em;font-weight:normal;color:#777;line-height:1.02;white-space:nowrap}
.miu-content{font-size:.80em;line-height:1.20;margin:.07em 0 0 0;padding:0 0 .08em 0;page-break-before:avoid;orphans:2;widows:2;white-space:pre-wrap}
.miu-empty{font-size:.70em;color:#666;margin:.45em 0;text-align:center}
]]
end
return Thoughts
