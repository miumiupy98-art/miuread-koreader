-- Issue #107: OPF title entity/CDATA handling and identity-merge policy.
local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function codepoint_to_utf8(code)
    code = tonumber(code)
    if not code or code < 0 or code > 0x10FFFF then return "" end
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40,
            0x80 + code % 0x40)
    end
    return string.char(
        0xF0 + math.floor(code / 0x40000),
        0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40,
        0x80 + code % 0x40)
end

local function decode_numeric_entities(value)
    value = tostring(value or "")
    value = value:gsub("&#(%d+);", function(dec)
        return codepoint_to_utf8(tonumber(dec))
    end)
    value = value:gsub("&#[xX](%x+);", function(hex)
        return codepoint_to_utf8(tonumber(hex, 16))
    end)
    return value
end

local function xml_text(value)
    value = trim(value)
    if value == "" then return nil end
    value = tostring(value):gsub("%s+", " ")
    return trim(value) ~= "" and trim(value) or nil
end

local function strip_cdata(value)
    value = tostring(value or "")
    value = value:gsub("^%s*<!%[CDATA%[", ""):gsub("%]%]>%s*$", "")
    return value
end

local function xml_unescape(value)
    value = strip_cdata(value)
    value = decode_numeric_entities(value)
    return value:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
        :gsub("&apos;", "'"):gsub("&amp;", "&")
end

local function xml_value(source, names)
    source = tostring(source or "")
    for _, name in ipairs(names or {}) do
        local value = source:match("<" .. name .. "[^>]*>(.-)</" .. name .. ">")
            or source:match("<[%w_%-]+:" .. name .. "[^>]*>(.-)</[%w_%-]+:" .. name .. ">")
        if value and value ~= "" then return xml_unescape(value) end
    end
    return nil
end

-- numeric entities must decode even without HTML tags
assert(xml_unescape('&#x7279;&#x6B8A;&#x4E66;&#x540D;')=='特殊书名','hex entities')
assert(xml_unescape('&#29378;&#23475;')=='狂害','decimal entities')
assert(xml_unescape('A&amp;B &lt;x&gt;')=='A&B <x>','named entities')

-- CDATA wrappers must be stripped
assert(xml_unescape('<![CDATA[书名：特别篇]]>')=='书名：特别篇','cdata')
assert(xml_unescape('  <![CDATA[&#x4E2D;]]>  ')=='中','cdata + entity')

-- title keeps angle brackets (xml_text must NOT strip tags)
assert(xml_text(xml_unescape('人生&lt;哲学&gt;'))=='人生<哲学>','angle brackets survive')
assert(xml_text(xml_unescape('C++ Primer'))=='C++ Primer','plain title')

-- xml_value extraction
local opf='<dc:title id="t">&#x7279;&#x6B8A;&#x4E66;&#x540D;</dc:title>'
assert(xml_value(opf,{'title'})=='特殊书名','dc:title hex')
local opf2='<dc:title><![CDATA[人生&lt;哲学&gt;]]></dc:title>'
assert(xml_value(opf2,{'title'})=='人生<哲学>','dc:title cdata+named')

-- identity merge: never overwrite non-empty title/author
local function fill_identity(book, key, value)
    if value == nil or value == "" then return false end
    local current = book[key]
    if current == nil or current == "" then
        book[key] = value
        return true
    end
    return false
end
local book={title='微信读书正确标题',author='原作者'}
assert(fill_identity(book,'title','乱码标题')==false,'keep existing title')
assert(book.title=='微信读书正确标题','title unchanged')
assert(fill_identity(book,'author','OPF作者')==false,'keep existing author')
local empty = {}
assert(fill_identity(empty,'title','从OPF补全')==true,'fill empty title')
assert(empty.title=='从OPF补全','title filled')

print('title garble metadata: PASS')
