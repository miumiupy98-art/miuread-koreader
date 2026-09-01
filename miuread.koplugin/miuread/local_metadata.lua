local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local U = require("miuread.util")

local LocalMetadata = {}
local METADATA_EXTRACTOR_VERSION = 4

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function file_exists(path)
    return type(path) == "string" and path ~= "" and lfs.attributes(path, "mode") == "file"
end


local function normalize_isbn(value)
    value = tostring(value or ""):upper():gsub("[^0-9X]", "")
    if #value == 10 or #value == 13 then return value end
    return nil
end

local function find_isbn(value)
    value = tostring(value or "")
    for token in value:gmatch("[%dXx][%dXx%-%s]+") do
        local isbn = normalize_isbn(token)
        if isbn then return isbn end
    end
    return normalize_isbn(value)
end

local function normalize_progress(value)
    value = tonumber(value)
    if not value then return nil end
    if value >= 0 and value <= 1 then value = value * 100 end
    if value < 0 then value = 0 end
    if value > 100 then value = 100 end
    return value
end

local function plain_text(value)
    value = trim(value)
    if value == "" then return nil end
    local ok, util = pcall(require, "util")
    if ok and util and type(util.htmlToPlainTextIfHtml) == "function" then
        local converted_ok, converted = pcall(util.htmlToPlainTextIfHtml, value)
        if converted_ok and converted then value = converted end
    end
    value = tostring(value):gsub("%s+", " ")
    return trim(value) ~= "" and trim(value) or nil
end

local function authors_text(value)
    if type(value) == "table" then value = table.concat(value, "、") end
    value = trim(value)
    if value == "" then return nil end
    return value:gsub("%s*\n%s*", "、")
end


local function shell_read(command, limit)
    local pipe = io.popen(command, "r")
    if not pipe then return nil end
    local data = pipe:read(limit and tonumber(limit) or "*a")
    pipe:close()
    return data
end

local function xml_unescape(value)
    value = tostring(value or "")
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

local function read_epub_package(filepath, out)
    if tostring(filepath):lower():sub(-5) ~= ".epub" then return false end
    local quoted = U.shell_quote(filepath)
    local container = shell_read("unzip -p " .. quoted .. " META-INF/container.xml 2>/dev/null") or ""
    local opf_path = container:match('full%-path=["\']([^"\']+)["\']') or "OEBPS/package.opf"
    local opf = shell_read("unzip -p " .. quoted .. " " .. U.shell_quote(opf_path) .. " 2>/dev/null")
    if not opf or opf == "" then return false end
    local title = plain_text(xml_value(opf, {"title"}))
    local author = authors_text(plain_text(xml_value(opf, {"creator", "author"})))
    local description = plain_text(xml_value(opf, {"description", "summary"}))
    local subject = plain_text(xml_value(opf, {"subject"}))
    local publisher = plain_text(xml_value(opf, {"publisher"}))
    local language = plain_text(xml_value(opf, {"language"}))
    local isbn = find_isbn(xml_value(opf, {"identifier", "isbn"}))
    if not isbn then
        for value in opf:gmatch("<[%w_%-:]*identifier[^>]*>(.-)</[%w_%-:]*identifier>") do
            isbn = find_isbn(xml_unescape(value))
            if isbn then break end
        end
    end
    if title then out.title = out.title or title end
    if author then out.author = out.author or author end
    if description then out.description = out.description or U.utf8_truncate(description, 360, "…") end
    if subject then out.category = out.category or U.utf8_truncate(subject, 80, "…") end
    if publisher then out.publisher = out.publisher or publisher end
    if language then out.language = out.language or language end
    if isbn then out.isbn = out.isbn or isbn end

    if not out.description then
        local names = shell_read("unzip -Z1 " .. quoted .. " 2>/dev/null") or ""
        local candidates = {}
        for name in names:gmatch("[^\r\n]+") do
            local lower = name:lower()
            if lower:match("%.x?html?$") then
                local priority = lower:match("intro") or lower:match("description") or lower:match("summary")
                    or lower:match("preface") or lower:match("bookinfo") or lower:match("metadata")
                if priority then table.insert(candidates, 1, name)
                elseif #candidates < 5 then candidates[#candidates + 1] = name end
            end
            if #candidates >= 8 then break end
        end
        for _, name in ipairs(candidates) do
            local html = shell_read("unzip -p " .. quoted .. " " .. U.shell_quote(name) .. " 2>/dev/null")
            if html and html ~= "" then
                html = html:gsub("<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]>", " ")
                    :gsub("<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]>", " ")
                local text = plain_text(html:gsub("<[^>]+>", " "))
                if text and #text >= 40 then
                    local start = text:find("内容简介", 1, true) or text:find("图书简介", 1, true)
                        or text:find("作品简介", 1, true) or text:find("编辑推荐", 1, true)
                    if start then text = text:sub(start) end
                    out.description = U.utf8_truncate(text, 360, "…")
                    break
                end
            end
        end
    end
    if out.title or out.author or out.description or out.publisher or out.category then
        out.metadata_source = out.metadata_source or "epub_package"
        return true
    end
    return false
end

local function safe_hash(value)
    value = tostring(value or "")
    local hash = 5381
    for i = 1, #value do
        hash = (hash * 33 + value:byte(i)) % 4294967296
    end
    return string.format("%08x", hash)
end

local function cover_cache_path(cache_dir, filepath)
    local ext = (filepath:match("%.([%w]+)$") or "book"):lower()
    return tostring(cache_dir) .. "/local_" .. safe_hash(filepath) .. "_" .. ext .. ".png"
end

local function write_cover(bb, cache_dir, filepath)
    if not bb or type(bb.writePNG) ~= "function" then return nil end
    U.mkdir(cache_dir)
    local destination = cover_cache_path(cache_dir, filepath)
    -- A stable local book must keep a stable cover file. Rewriting an identical
    -- PNG changes its mtime, which used to invalidate MiuRead's thumbnail cache
    -- and made an idle e-ink shelf repaint itself.
    if file_exists(destination) then
        local source_mtime=tonumber(lfs.attributes(filepath,"modification") or 0) or 0
        local cover_mtime=tonumber(lfs.attributes(destination,"modification") or 0) or 0
        if source_mtime>0 and cover_mtime>=source_mtime then return destination end
    end
    local tmp=destination..".tmp"
    os.remove(tmp)
    local ok, err = pcall(bb.writePNG, bb, tmp)
    if not ok or not file_exists(tmp) then
        logger.warn("[MiuRead][LocalMetadata] cover write failed", tostring(filepath), tostring(err))
        os.remove(tmp)
        return nil
    end
    local renamed,rename_err=os.rename(tmp,destination)
    if not renamed then
        os.remove(destination)
        renamed,rename_err=os.rename(tmp,destination)
    end
    if not renamed or not file_exists(destination) then
        logger.warn("[MiuRead][LocalMetadata] cover replace failed", tostring(filepath), tostring(rename_err))
        os.remove(tmp)
        return nil
    end
    return destination
end

local function sidecar_settings(filepath)
    local ok_booklist, BookList = pcall(require, "ui/widget/booklist")
    if ok_booklist and BookList and type(BookList.hasBookBeenOpened) == "function"
        and type(BookList.getDocSettings) == "function" then
        local opened_ok, opened = pcall(BookList.hasBookBeenOpened, filepath)
        if opened_ok and opened then
            local settings_ok, settings = pcall(BookList.getDocSettings, filepath)
            if settings_ok and settings then return settings end
        end
    end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds and DocSettings and type(DocSettings.hasSidecarFile) == "function" then
        local has_ok, has = pcall(DocSettings.hasSidecarFile, DocSettings, filepath)
        if has_ok and has and type(DocSettings.open) == "function" then
            local open_ok, settings = pcall(DocSettings.open, DocSettings, filepath)
            if open_ok and settings then return settings end
        end
    end
    return nil
end

local function custom_cover(filepath)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or not DocSettings or type(DocSettings.findCustomCoverFile) ~= "function" then return nil end
    local found_ok, path = pcall(DocSettings.findCustomCoverFile, DocSettings, filepath)
    if found_ok and file_exists(path) then return path end
    return nil
end

local function apply_props(out, props)
    if type(props) ~= "table" then return end
    local title = trim(props.title or props.Title)
    if title ~= "" then out.title = title end
    local authors = authors_text(props.authors or props.author or props.Author)
    if authors then out.author = authors end
    local series = trim(props.series or props.Series)
    if series ~= "" then out.series = series end
    local language = trim(props.language or props.Language)
    if language ~= "" then out.language = language end
    local description = plain_text(props.description or props.Description or props.summary)
    if description then out.description = description end
    local category = plain_text(props.subject or props.category or props.categories)
    if category then out.category = category end
    local publisher = plain_text(props.publisher or props.Publisher)
    if publisher then out.publisher = publisher end
    local isbn = find_isbn(props.isbn or props.ISBN or props.identifier or props.identifiers)
    if isbn then out.isbn = isbn end
    local pages = tonumber(props.pages or props.page_count)
    if pages and pages > 0 then out.pages = math.floor(pages) end
end

local function read_sidecar(filepath, out)
    local settings = sidecar_settings(filepath)
    if not settings then return false end
    local read = function(key, default)
        local ok, value = pcall(settings.readSetting, settings, key, default)
        return ok and value or default
    end
    apply_props(out, read("doc_props"))
    local pages = tonumber(read("doc_pages"))
    if pages and pages > 0 then out.pages = math.floor(pages) end
    local progress = normalize_progress(read("percent_finished"))
    if not progress then
        local current_page = tonumber(read("page"))
        if current_page and pages and pages > 0 then progress = normalize_progress(current_page / pages) end
    end
    if progress then out.progress = progress end
    local summary = read("summary")
    if type(summary) == "table" and summary.status == "complete" then out.progress = 100 end
    local sidecar_file = settings.sidecar_file
    if not sidecar_file then
        local ok_ds, DocSettings = pcall(require, "docsettings")
        if ok_ds and DocSettings and type(DocSettings.findSidecarFile) == "function" then
            local found_ok, found = pcall(DocSettings.findSidecarFile, DocSettings, filepath)
            if found_ok then sidecar_file = found end
        end
    end
    local sidecar_mtime = sidecar_file and lfs.attributes(sidecar_file, "modification")
    if sidecar_mtime then out.last_read_at = tonumber(sidecar_mtime) end
    out.metadata_source = "sidecar"
    return true
end

local function read_custom_metadata(filepath, out)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or not DocSettings or type(DocSettings.findCustomMetadataFile) ~= "function" then return end
    local found_ok, metadata_file = pcall(DocSettings.findCustomMetadataFile, DocSettings, filepath)
    if not found_ok or not metadata_file or not file_exists(metadata_file) then return end
    local open_ok, settings = pcall(DocSettings.openSettingsFile, metadata_file)
    if not open_ok or not settings then return end
    local props_ok, props = pcall(settings.readSetting, settings, "doc_props")
    if props_ok then apply_props(out, props) end
    local custom_ok, custom = pcall(settings.readSetting, settings, "custom_props")
    if custom_ok and type(custom) == "table" then apply_props(out, custom) end
end

local function read_bim(filepath, cache_dir, out)
    local ok, BIM = pcall(require, "bookinfomanager")
    if not ok or not BIM or type(BIM.getBookInfo) ~= "function" then return false end
    local info_ok, info = pcall(BIM.getBookInfo, BIM, filepath, true)
    if not info_ok or type(info) ~= "table" then return false end
    apply_props(out, {
        title = info.title,
        authors = info.authors,
        series = info.series,
        language = info.language,
        description = info.description,
        subject = info.subject or info.category,
        publisher = info.publisher,
        pages = info.page_count or info.pages,
        isbn = info.isbn or info.ISBN or info.identifier,
    })
    if info.cover_bb then
        out.cover_path = write_cover(info.cover_bb, cache_dir, filepath) or out.cover_path
        if info.cover_bb.free then pcall(info.cover_bb.free, info.cover_bb) end
    end
    if info.has_meta or info.has_cover or out.title or out.author or out.cover_path then
        out.metadata_source = "bookinfomanager"
        return true
    end
    return false
end

local function read_document(filepath, cache_dir, out)
    local ok_registry, DocumentRegistry = pcall(require, "document/documentregistry")
    if not ok_registry or not DocumentRegistry or type(DocumentRegistry.hasProvider) ~= "function" then
        return false, "registry_unavailable"
    end
    local provider_ok, has_provider = pcall(DocumentRegistry.hasProvider, DocumentRegistry, filepath)
    if not provider_ok then return false, "provider_check_failed" end
    if not has_provider then return false, "unsupported" end
    local document
    local opened, loaded_ok = false, true
    local ok, err = xpcall(function()
        local provider
        if type(DocumentRegistry.getProvider) == "function" then
            local get_ok, value = pcall(DocumentRegistry.getProvider, DocumentRegistry, filepath)
            if get_ok then provider = value end
        end
        local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
        if ok_reader and ReaderUI and type(ReaderUI.extendProvider) == "function" then
            local extend_ok, value = pcall(ReaderUI.extendProvider, ReaderUI, filepath, provider)
            if extend_ok and value then provider = value end
        end
        document = DocumentRegistry:openDocument(filepath, provider)
        if not document then return end
        opened = true
        if document.loadDocument then
            local loaded = document:loadDocument(false)
            if loaded == false then loaded_ok = false; return end
        end
        if type(document.getProps) == "function" then apply_props(out, document:getProps()) end
        if not out.pages and not document.loadDocument and type(document.getPageCount) == "function" then
            local pages = tonumber(document:getPageCount())
            if pages and pages > 0 then out.pages = math.floor(pages) end
        end
        if not out.cover_path and type(document.getCoverPageImage) == "function" then
            local cover = document:getCoverPageImage()
            if cover then
                out.cover_path = write_cover(cover, cache_dir, filepath) or out.cover_path
                if cover.free then pcall(cover.free, cover) end
            end
        end
    end, debug.traceback)
    if document then pcall(document.close, document) end
    if not ok then
        logger.warn("[MiuRead][LocalMetadata] document extraction failed", tostring(filepath), tostring(err))
        return false, "open_error"
    end
    if not opened then return false, "open_failed" end
    if not loaded_ok then return false, "load_failed" end
    if out.title or out.author or out.cover_path or out.description then
        out.metadata_source = "document"
        return true, "found"
    end
    return true, "none"
end

function LocalMetadata.read(filepath, cache_dir, options)
    options = options or {}
    filepath = tostring(filepath or "")
    if not file_exists(filepath) then return nil, "file missing" end
    cache_dir = tostring(cache_dir or "")
    if cache_dir == "" then return nil, "cache dir missing" end

    local attr = lfs.attributes(filepath) or {}
    local out = {
        file = filepath,
        metadata_mtime = tonumber(attr.modification) or 0,
        metadata_checked_at = os.time(),
    }
    out.cover_path = custom_cover(filepath)
    read_sidecar(filepath, out)
    read_custom_metadata(filepath, out)
    read_epub_package(filepath, out)

    if options.use_bim ~= false then read_bim(filepath, cache_dir, out) end
    local document_state
    if options.open_document == true and (not out.cover_path or not out.title or not out.author or not out.description) then
        local document_ok, state = read_document(filepath, cache_dir, out)
        document_state = state
        if document_ok then
            out.metadata_complete = true
            out.metadata_state = out.cover_path and "found" or "confirmed_none"
            out.metadata_retry_after = 0
            out.metadata_error = ""
        else
            out.metadata_complete = false
            out.metadata_state = "failed"
            out.metadata_retry_after = os.time() + 10 * 60
            out.metadata_error = tostring(state or "document_failed")
        end
    elseif options.open_document == true then
        out.metadata_complete = true
        out.metadata_state = out.cover_path and "found" or "confirmed_none"
        out.metadata_retry_after = 0
        out.metadata_error = ""
    else
        out.metadata_complete = false
        out.metadata_state = "unknown"
    end
    if document_state == "unsupported" then
        out.metadata_complete = true
        out.metadata_state = out.cover_path and "found" or "confirmed_none"
        out.metadata_retry_after = 0
        out.metadata_error = ""
    end
    out.metadata_extractor_version = METADATA_EXTRACTOR_VERSION
    return out
end

function LocalMetadata.merge(book, metadata)
    if type(book) ~= "table" or type(metadata) ~= "table" then return false end
    local changed = false
    local function set(key, value)
        if value ~= nil and value ~= "" and book[key] ~= value then
            book[key] = value
            changed = true
        end
    end
    set("title", metadata.title)
    set("author", metadata.author)
    set("series", metadata.series)
    set("language", metadata.language)
    set("description", metadata.description)
    set("category", metadata.category)
    set("publisher", metadata.publisher)
    set("published_date", metadata.published_date)
    set("isbn", metadata.isbn)
    set("pages", metadata.pages)
    set("cover_path", metadata.cover_path)
    set("last_read_at", metadata.last_read_at)
    if metadata.progress ~= nil and tonumber(book.progress or 0) ~= tonumber(metadata.progress) then
        book.progress = metadata.progress
        changed = true
    end
    for _, key in ipairs({"metadata_source", "metadata_mtime", "metadata_checked_at", "metadata_complete", "metadata_extractor_version", "metadata_state", "metadata_retry_after", "metadata_error"}) do
        if metadata[key] ~= nil and book[key] ~= metadata[key] then
            book[key] = metadata[key]
            changed = true
        end
    end
    return changed
end

function LocalMetadata.needs_refresh(book, full)
    if type(book) ~= "table" or not file_exists(book.file) then return false end
    local mtime = tonumber(lfs.attributes(book.file, "modification")) or 0
    if tonumber(book.metadata_mtime or -1) ~= mtime then return true end
    if full then
        if tonumber(book.metadata_extractor_version or 0) < METADATA_EXTRACTOR_VERSION then return true end
        if tostring(book.metadata_state or "") == "failed" then
            return os.time() >= (tonumber(book.metadata_retry_after) or 0)
        end
        if book.metadata_complete ~= true then return true end
        -- A confirmed no-cover result is stable. A failed extraction is kept
        -- separately above and retried after backoff instead of becoming a
        -- permanent blank cover.
        if book.cover_path and not file_exists(book.cover_path) then return true end
        return false
    end
    if book.cover_path and not file_exists(book.cover_path) then return true end
    return tonumber(book.metadata_checked_at or 0) <= 0
end

return LocalMetadata
