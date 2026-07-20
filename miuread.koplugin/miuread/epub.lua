local bit = require("bit")
local Json = require("miuread.json")
local U = require("miuread.util")

local E = {}
local CHUNK_SIZE = 64 * 1024
local UINT32 = 4294967296

local crc_table = {}
for n = 0, 255 do
    local c = n
    for _ = 1, 8 do
        if bit.band(c, 1) == 1 then
            c = bit.bxor(0xedb88320, bit.rshift(c, 1))
        else
            c = bit.rshift(c, 1)
        end
    end
    crc_table[n] = c
end

local function unsigned32(value)
    value = tonumber(value) or 0
    if value < 0 then value = value + UINT32 end
    return value
end

local function crc32_update(crc, data)
    for index = 1, #data do
        local key = bit.band(bit.bxor(crc, data:byte(index)), 255)
        crc = bit.bxor(bit.rshift(crc, 8), crc_table[key])
    end
    return crc
end

local function u16(value)
    value = tonumber(value) or 0
    return string.char(value % 256, math.floor(value / 256) % 256)
end

local function u32(value)
    value = unsigned32(value)
    return string.char(
        value % 256,
        math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 16777216) % 256
    )
end

local function source_parts(source)
    if type(source) == "string" then return {source} end
    if type(source) ~= "table" then return {""} end
    if source.parts then return source.parts end
    if source.path then return {{path = source.path}} end
    if source.data ~= nil then return {source.data} end
    return source
end

local function visit_source(source, callback)
    for _, part in ipairs(source_parts(source)) do
        if type(part) == "string" then
            local ok, err = callback(part)
            if ok == false then return nil, err end
        elseif type(part) == "table" and part.path then
            local file, open_error = io.open(part.path, "rb")
            if not file then return nil, open_error or ("无法打开文件：" .. tostring(part.path)) end
            while true do
                local chunk = file:read(CHUNK_SIZE)
                if not chunk or #chunk == 0 then break end
                local ok, err = callback(chunk)
                if ok == false then
                    file:close()
                    return nil, err
                end
            end
            file:close()
        else
            local data = tostring(part and part.data or "")
            local ok, err = callback(data)
            if ok == false then return nil, err end
        end
    end
    return true
end

local function source_stats(source)
    local size = 0
    local crc = 0xffffffff
    local ok, err = visit_source(source, function(chunk)
        size = size + #chunk
        if size >= UINT32 then return false, "EPUB 单个文件超过 ZIP32 限制" end
        crc = crc32_update(crc, chunk)
        return true
    end)
    if not ok then return nil, nil, err end
    return unsigned32(bit.bxor(crc, 0xffffffff)), size
end

local function checked_write(file, data)
    local ok, err = file:write(data)
    if not ok then return nil, err or "写入失败" end
    return true
end

local function stream_zip(path, entries)
    local parent = path:match("^(.*)/[^/]+$")
    if parent then U.mkdir(parent) end

    local out, open_error = io.open(path, "wb")
    if not out then error(open_error or "无法创建 EPUB") end

    local central = {}
    local offset = 0
    local entry_count = 0

    local ok, err = xpcall(function()
        for _, entry in ipairs(entries) do
            local name = tostring(entry.name or "")
            if name == "" then error("EPUB ZIP 条目名称为空") end

            local crc, size, stat_error = source_stats(entry.source or entry.data or "")
            if not crc then error(stat_error or ("无法读取 ZIP 条目：" .. name)) end
            if offset >= UINT32 then error("EPUB 文件超过 ZIP32 限制") end

            local local_header = "PK\003\004"
                .. u16(20) .. u16(0) .. u16(0)
                .. u16(0) .. u16(0)
                .. u32(crc) .. u32(size) .. u32(size)
                .. u16(#name) .. u16(0) .. name
            local wrote, write_error = checked_write(out, local_header)
            if not wrote then error(write_error) end

            local streamed, stream_error = visit_source(entry.source or entry.data or "", function(chunk)
                return checked_write(out, chunk)
            end)
            if not streamed then error(stream_error or ("无法写入 ZIP 条目：" .. name)) end

            central[#central + 1] = "PK\001\002"
                .. u16(20) .. u16(20) .. u16(0) .. u16(0)
                .. u16(0) .. u16(0)
                .. u32(crc) .. u32(size) .. u32(size)
                .. u16(#name) .. u16(0) .. u16(0)
                .. u16(0) .. u16(0) .. u32(0)
                .. u32(offset) .. name
            offset = offset + #local_header + size
            entry_count = entry_count + 1
        end

        if entry_count > 65535 then error("EPUB 条目数量超过 ZIP32 限制") end
        local central_offset = offset
        local central_size = 0
        for _, item in ipairs(central) do
            local wrote, write_error = checked_write(out, item)
            if not wrote then error(write_error) end
            central_size = central_size + #item
        end
        if central_offset >= UINT32 or central_size >= UINT32 then
            error("EPUB 中央目录超过 ZIP32 限制")
        end
        local tail = "PK\005\006"
            .. u16(0) .. u16(0)
            .. u16(entry_count) .. u16(entry_count)
            .. u32(central_size) .. u32(central_offset)
            .. u16(0)
        local wrote, write_error = checked_write(out, tail)
        if not wrote then error(write_error) end
        out:flush()
    end, debug.traceback)

    out:close()
    if not ok then
        os.remove(path)
        error(err)
    end
end

local function chapter_source(book, chapter, index)
    local title = chapter.title or ("Chapter " .. tostring(index))
    local header = '<?xml version="1.0" encoding="utf-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>'
        .. U.xml(title)
        .. '</title><link rel="stylesheet" href="../style.css" type="text/css"/></head><body data-miuread-book="'
        .. U.xml(book.bookId or book.book_id)
        .. '" data-miuread-chapter="'
        .. U.xml(chapter.uid or index)
        .. '">'
    local body
    if chapter.body_path then
        body = {path = chapter.body_path}
    else
        body = tostring(chapter.body or "")
    end
    return {parts = {header, body, "</body></html>"}}
end

local function binary_source(item)
    if item and item.data_path then return {path = item.data_path} end
    if item and item.path then return {path = item.path} end
    return tostring(item and item.data or "")
end

function E.build(path, book, chapters, css, assets, cover, meta)
    chapters = chapters or {}
    assets = assets or {}

    local entries = {
        {name = "mimetype", source = "application/epub+zip"},
        {name = "META-INF/container.xml", source = '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'},
    }
    local manifest = {
        '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
        '<item id="css" href="style.css" media-type="text/css"/>',
        '<item id="miu-meta" href="miuread.json" media-type="application/json"/>',
    }
    local spine, nav, ncx = {}, {}, {}
    local cover_meta = ""

    if cover and (cover.data or cover.data_path or cover.path) then
        entries[#entries + 1] = {
            name = "OEBPS/images/cover" .. tostring(cover.ext or ".bin"),
            source = binary_source(cover),
        }
        manifest[#manifest + 1] = '<item id="cover-image" href="images/cover'
            .. U.xml(cover.ext or ".bin")
            .. '" media-type="' .. U.xml(cover.mime or "application/octet-stream")
            .. '" properties="cover-image"/>'
        cover_meta = '<meta name="cover" content="cover-image"/>'
    end

    local seen_assets = {}
    local asset_index = 0
    for _, asset in ipairs(assets) do
        local href = tostring(asset.href or "")
        if href ~= "" and not seen_assets[href] then
            seen_assets[href] = true
            asset_index = asset_index + 1
            entries[#entries + 1] = {name = "OEBPS/" .. href, source = binary_source(asset)}
            manifest[#manifest + 1] = '<item id="asset' .. tostring(asset_index)
                .. '" href="' .. U.xml(href)
                .. '" media-type="' .. U.xml(asset.mime or "application/octet-stream") .. '"/>'
        end
    end

    for index, chapter in ipairs(chapters) do
        local file = string.format("text/chapter-%04d.xhtml", index)
        local id = "c" .. tostring(index)
        local title = chapter.title or ("Chapter " .. tostring(index))
        entries[#entries + 1] = {
            name = "OEBPS/" .. file,
            source = chapter_source(book, chapter, index),
        }
        manifest[#manifest + 1] = '<item id="' .. id .. '" href="' .. file .. '" media-type="application/xhtml+xml"/>'
        spine[#spine + 1] = '<itemref idref="' .. id .. '"/>'
        nav[#nav + 1] = '<li><a href="' .. file .. '">' .. U.xml(title) .. '</a></li>'
        ncx[#ncx + 1] = '<navPoint id="n' .. tostring(index) .. '" playOrder="' .. tostring(index)
            .. '"><navLabel><text>' .. U.xml(title)
            .. '</text></navLabel><content src="' .. file .. '"/></navPoint>'
    end

    local ident = "miuread-" .. U.id_name(book.bookId or book.book_id)
    local opf = '<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" unique-identifier="id" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">'
        .. ident .. '</dc:identifier><dc:title>' .. U.xml(book.title or "MiuRead")
        .. '</dc:title><dc:creator>' .. U.xml(book.author or "")
        .. '</dc:creator><dc:language>zh-CN</dc:language><dc:source>miuread://book/'
        .. U.xml(book.bookId or book.book_id)
        .. '</dc:source><meta property="dcterms:modified" xmlns:dcterms="http://purl.org/dc/terms/">'
        .. os.date("!%Y-%m-%dT%H:%M:%SZ")
        .. '</meta>' .. cover_meta .. '</metadata><manifest>'
        .. table.concat(manifest)
        .. '<item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="toc">'
        .. table.concat(spine) .. '</spine></package>'

    entries[#entries + 1] = {name = "OEBPS/package.opf", source = opf}
    entries[#entries + 1] = {
        name = "OEBPS/nav.xhtml",
        source = '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol>'
            .. table.concat(nav) .. '</ol></nav></body></html>',
    }
    entries[#entries + 1] = {
        name = "OEBPS/toc.ncx",
        source = '<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="'
            .. ident .. '"/></head><docTitle><text>' .. U.xml(book.title or "MiuRead")
            .. '</text></docTitle><navMap>' .. table.concat(ncx) .. '</navMap></ncx>',
    }
    entries[#entries + 1] = {
        name = "OEBPS/style.css",
        source = css or "body{line-height:1.75;margin:5%;}img{max-width:100%;height:auto;}",
    }
    entries[#entries + 1] = {name = "OEBPS/miuread.json", source = Json.encode(meta or {})}

    stream_zip(path, entries)
    return path
end

E._stream_zip = stream_zip
E._source_stats = source_stats

return E
