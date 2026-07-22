local Json = require("miuread.json")
local U = require("miuread.util")
local logger = require("logger")

local Thoughts = {}

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

function Thoughts.cache_dir(store, book_id)
    local dir = store:book_dir(book_id) .. "/thoughts"
    U.mkdir(dir)
    return dir
end

function Thoughts.cache_path(store, book_id, chapter_uid)
    return Thoughts.cache_dir(store, book_id) .. "/" .. U.id_name(chapter_uid) .. ".json"
end

local function compact_group(group)
    if type(group) ~= "table" then return nil end
    local range = tostring(group.range or "")
    local texts = {}
    for _, row in ipairs(group.texts or {}) do
        if type(row) == "table" and tostring(row.content or "") ~= "" then
            texts[#texts + 1] = {
                content = tostring(row.content or ""),
                abstract = tostring(row.abstract or ""),
                author = tostring(row.author or ""),
                likes = tonumber(row.likes or 0) or 0,
                created = tonumber(row.created or 0) or 0,
                review_id = tostring(row.review_id or ""),
            }
        end
    end
    if range == "" or #texts == 0 then return nil end
    return {range = range, texts = texts}
end

function Thoughts.save(store, book_id, chapter_uid, groups)
    local rows = {}
    for _, group in ipairs(groups or {}) do
        local item = compact_group(group)
        if item then rows[#rows + 1] = item end
    end
    local path = Thoughts.cache_path(store, book_id, chapter_uid)
    if #rows == 0 then
        os.remove(path)
        return 0, path
    end
    U.atomic_write(path, Json.encode(rows), true)
    logger.info("[MiuRead][Thoughts] cache saved", "book=", tostring(book_id),
        "chapter=", tostring(chapter_uid), "groups=", tostring(#rows))
    return #rows, path
end

function Thoughts.load(store, book_id, chapter_uid)
    local path = Thoughts.cache_path(store, book_id, chapter_uid)
    local raw = U.read_file(path, true)
    if not raw then return nil, "想法缓存不存在" end
    local ok, rows = pcall(Json.decode, raw)
    if not ok or type(rows) ~= "table" then return nil, "想法缓存损坏" end
    return rows
end

function Thoughts.find(store, book_id, chapter_uid, range)
    local rows, err = Thoughts.load(store, book_id, chapter_uid)
    if not rows then return nil, err end
    for _, row in ipairs(rows) do
        if tostring(row.range or "") == tostring(range or "") then return row end
    end
    return nil, "没有找到该划线对应的想法"
end

local function clean(value)
    return U.trim(tostring(value or ""):gsub("[%z\1-\8\11\12\14-\31]", " "):gsub("%s+", " "))
end

local function preview(value, max_chars)
    local text = clean(value)
    max_chars = tonumber(max_chars) or 84
    if codepoint_len(text) <= max_chars then return text end
    return utf8_slice(text, 1, max_chars) .. "……"
end

local function split_entry(item, chunk_chars)
    local author = clean(item.author)
    if author == "" then author = "微信读书用户" end
    local content = clean(item.content)
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
    return '<div class="miu-source"><div class="miu-source-box"><span class="miu-quote">&#8220;</span>'
        .. U.xml(text or "") .. '<span class="miu-quote">&#8221;</span></div></div>'
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
        if clean(item.content) ~= "" then rows[#rows + 1] = entry_html(item) end
    end
    return table.concat(rows)
end

function Thoughts.popup_parts(group)
    if type(group) ~= "table" then
        return "", "", {source_chars=0, source_units=0, comment_count=0, comment_chars={}}
    end

    local fixed, comments = {}, {}
    local metrics = {source_chars=0, source_units=0, comment_count=0, comment_chars={}}
    local abstract = Thoughts.group_abstract(group)
    if abstract ~= "" then
        local source = preview(abstract, 72)
        metrics.source_chars = codepoint_len(source)
        metrics.source_units = display_units(source)
        fixed[#fixed + 1] = panel_head_html("原文")
        fixed[#fixed + 1] = source_box_html(source)
    end

    local seen = {}
    for _, item in ipairs(group.texts or {}) do
        local content = clean(item.content)
        if content ~= "" then
            local author = clean(item.author)
            if author == "" then author = "微信读书用户" end
            local review_id = tostring(item.review_id or "")
            local key = review_id ~= "" and ("id:" .. review_id) or (author .. "\0" .. content)
            if not seen[key] then
                seen[key] = true
                metrics.comment_count = metrics.comment_count + 1
                metrics.comment_chars[#metrics.comment_chars + 1] = codepoint_len(content)
                comments[#comments + 1] = entry_html{
                    author = author,
                    content = content,
                    likes = tonumber(item.likes or 0) or 0,
                }
            end
        end
    end
    local body = {}
    if metrics.comment_count > 0 then
        body[1] = panel_head_html("想法 · " .. tostring(metrics.comment_count))
        for _, html in ipairs(comments) do body[#body + 1] = html end
    end
    return table.concat(fixed), table.concat(body), metrics
end

function Thoughts.full_html(group)
    local fixed, body, metrics = Thoughts.popup_parts(group)
    return fixed .. body, metrics
end

local function css_font_family(value)
    local face = clean(value)
    if face == "" then return "serif" end
    face = face:gsub("\\", "\\\\"):gsub('"', '\\"')
    return '"' .. face .. '", serif'
end

function Thoughts.popup_css(font_face, font_definitions)
    return tostring(font_definitions or "") .. [[
@page{margin:0}
html{margin:0!important;padding:0!important}
body{margin:0!important;padding:.18em .26em .20em .26em!important;font-family:]]
        .. css_font_family(font_face)
        .. [[;line-height:1.18;color:#000;background:#fff}
.miu-panel-head{font-size:.82em;font-weight:bold;line-height:1.10;color:#111;margin:0 2.4em .32em 0;padding:0 0 .26em 0;border-bottom:2px solid #222}
.miu-source{margin:0;padding:0}
.miu-source-box{font-size:.88em;line-height:1.42;color:#333;margin:0;padding:.40em .58em;background:#eee;border-left:3px solid #333}
.miu-quote{font-weight:bold;color:#555}
.miu-comment{margin:0;padding:.42em .08em .48em .08em;border:0;page-break-inside:avoid;break-inside:avoid-page}
.miu-comment+.miu-comment{padding-top:.52em;border-top:1px solid #aaa}
.miu-meta{margin:0;padding:0;line-height:1.12;page-break-after:avoid}
.miu-author{font-size:.72em;font-weight:bold;color:#333;line-height:1.12}
.miu-likes{font-size:.66em;font-weight:normal;color:#666;line-height:1.12;white-space:nowrap}
.miu-content{font-size:1em;line-height:1.48;margin:.22em 0 0 0;padding:0;page-break-before:avoid;orphans:2;widows:2}
]]
end
return Thoughts
