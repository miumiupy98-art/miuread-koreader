local U = require("miuread.util")

local M = {}

local MAX_CHAPTER_BYTES = 512 * 1024
local MAX_CHAPTER_WORDS = 100000
local END_SCAN_WORDS = 1024
local ANCHOR_STEPS = {12, 24, 48}

local ok_socket, socket = pcall(require, "socket")
local function now_ms()
    if ok_socket and socket and type(socket.gettime) == "function" then
        return socket.gettime() * 1000
    end
    return os.clock() * 1000
end

local function scalar(value)
    if type(value) == "string" or type(value) == "number" then return tostring(value) end
    return ""
end

local function chapter_uid(chapter)
    return scalar(type(chapter) == "table" and
        (chapter.uid or chapter.chapterUid or chapter.chapter_uid) or nil)
end

local function chapter_index(chapter, fallback)
    return tonumber(type(chapter) == "table" and
        (chapter.chapterIdx or chapter.index or chapter.chapter_index or chapter.chapter_idx) or nil)
        or tonumber(fallback or 0) or 0
end

local function chapter_words(chapter)
    if type(chapter) ~= "table" or chapter.structural == true then return 0 end
    return math.max(0, tonumber(chapter.wordCount or chapter.word_count or 0) or 0)
end

local function doc_text(document, first_xp, last_xp)
    if not (document and type(document.getTextFromXPointers) == "function") then
        return nil, "text_api_missing"
    end
    if type(first_xp) ~= "string" or first_xp == ""
        or type(last_xp) ~= "string" or last_xp == "" then
        return nil, "xpointer_missing"
    end
    local ok, value = pcall(document.getTextFromXPointers, document, first_xp, last_xp, false)
    if not ok then return nil, "text_extract_failed" end
    if type(value) == "table" then value = value.text or value[1] end
    value = tostring(value or "")
    if value == "" then return nil, "text_empty" end
    return value
end

local function valid_xpointer(document, xp)
    if type(xp) ~= "string" or xp == "" then return false end
    if document and type(document.isXPointerInDocument) == "function" then
        local ok, valid = pcall(document.isXPointerInDocument, document, xp)
        if ok and valid == false then return false end
    end
    return true
end

local function current_xpointer(ui, document)
    local rolling = ui and ui.rolling or nil
    local xp = rolling and rolling.xpointer or nil
    if valid_xpointer(document, xp) then return xp end
    if rolling and type(rolling.getBookLocation) == "function" then
        local ok, value = pcall(rolling.getBookLocation, rolling)
        if ok and valid_xpointer(document, value) then return value end
    end
    if document and type(document.getXPointer) == "function" then
        local ok, value = pcall(document.getXPointer, document)
        if ok and valid_xpointer(document, value) then return value end
    end
    return nil, "current_xpointer_missing"
end

local function fill_toc(toc)
    if not toc then return false end
    if type(toc.fillToc) == "function" then pcall(toc.fillToc, toc) end
    return type(toc.toc) == "table" and #toc.toc > 0
end

local function toc_index_for_xpointer(toc, xp)
    if not fill_toc(toc) or type(toc.getTocIndexByPage) ~= "function" then
        return nil, "toc_unavailable"
    end
    local ok, value = pcall(toc.getTocIndexByPage, toc, xp)
    local index = ok and tonumber(value) or nil
    if not index then return nil, "toc_index_missing" end
    index = math.floor(index + 0.5)
    if index < 1 or index > #toc.toc then return nil, "toc_index_out_of_bounds" end
    return index
end

local function advance_words(document, xp, count)
    local current = xp
    local moved = 0
    if type(document.getNextVisibleWordEnd) == "function" then
        for _ = 1, count do
            local ok, next_xp = pcall(document.getNextVisibleWordEnd, document, current)
            if not ok or not valid_xpointer(document, next_xp) or next_xp == current then break end
            current = next_xp
            moved = moved + 1
        end
    elseif type(document.getNextVisibleChar) == "function" then
        for _ = 1, math.min(count * 6, 512) do
            local ok, next_xp = pcall(document.getNextVisibleChar, document, current)
            if not ok or not valid_xpointer(document, next_xp) or next_xp == current then break end
            current = next_xp
            moved = moved + 1
        end
    end
    return moved > 0 and current or nil
end

local function retreat_words(document, xp, count)
    local current = xp
    local moved = 0
    if type(document.getPrevVisibleWordStart) == "function" then
        for _ = 1, count do
            local ok, previous_xp = pcall(document.getPrevVisibleWordStart, document, current)
            if not ok or not valid_xpointer(document, previous_xp) or previous_xp == current then break end
            current = previous_xp
            moved = moved + 1
        end
    elseif type(document.getPrevVisibleChar) == "function" then
        for _ = 1, math.min(count * 6, 512) do
            local ok, previous_xp = pcall(document.getPrevVisibleChar, document, current)
            if not ok or not valid_xpointer(document, previous_xp) or previous_xp == current then break end
            current = previous_xp
            moved = moved + 1
        end
    end
    return moved > 0 and current or nil
end

local function last_document_xpointer(document)
    if not (document and type(document.getPageCount) == "function"
        and type(document.getPageXPointer) == "function") then
        return nil, "document_end_unavailable"
    end
    local ok_count, page_count = pcall(document.getPageCount, document)
    page_count = ok_count and tonumber(page_count) or nil
    if not page_count or page_count < 1 then return nil, "page_count_missing" end
    local ok_xp, xp = pcall(document.getPageXPointer, document, math.floor(page_count))
    if not ok_xp or not valid_xpointer(document, xp) then return nil, "last_page_xpointer_missing" end
    local ending = advance_words(document, xp, END_SCAN_WORDS)
    return ending or xp
end

local function toc_item_xpointer(document, item)
    if type(item) ~= "table" then return nil end
    local xp = item.xpointer or item.xp
    if valid_xpointer(document, xp) then return xp end
    local page = tonumber(item.page or item.pageno)
    if page and type(document.getPageXPointer) == "function" then
        local ok, value = pcall(document.getPageXPointer, document, math.floor(page + 0.5))
        if ok and valid_xpointer(document, value) then return value end
    end
end

local function chapter_bounds(document, toc, toc_index)
    local start_xp = toc_item_xpointer(document, toc.toc[toc_index])
    if not start_xp then return nil, nil, "chapter_start_missing" end
    local end_xp = toc_item_xpointer(document, toc.toc[toc_index + 1])
    if not end_xp then
        local ending, err = last_document_xpointer(document)
        if not ending then return nil, nil, err end
        end_xp = ending
    end
    if end_xp == start_xp then return nil, nil, "chapter_bounds_empty" end
    return start_xp, end_xp
end

local function chapter_source(record)
    local local_map = record and record.record and record.record.chapter_map
    return type(local_map) == "table" and local_map or {}
end

local function local_chapter(record, toc_index)
    local explicit_uid = scalar(record and record.record and record.record.chapter_uid)
    local local_map = chapter_source(record)
    local readable = 0
    for _, row in ipairs(local_map) do
        if type(row) == "table" and row.structural ~= true and chapter_uid(row) ~= "" then
            readable = readable + 1
        end
    end

    -- chapter_uid is an explicit single-chapter identity only when the local
    -- EPUB really contains one readable chapter. Old/recovered full books may
    -- retain this field, so never let it override the current TOC chapter.
    if explicit_uid ~= "" and readable <= 1 then
        local chapter
        for _, row in ipairs(local_map) do
            if chapter_uid(row) == explicit_uid then chapter = row; break end
        end
        chapter = chapter or local_map[1] or {}
        return chapter, explicit_uid, chapter_index(chapter, 1), true
    end

    local chapter = local_map[toc_index]
    if type(chapter) ~= "table" then
        for index, row in ipairs(local_map) do
            local idx = chapter_index(row, index)
            if idx == toc_index or idx == toc_index - 1 then chapter = row; break end
        end
    end
    if type(chapter) ~= "table" then return nil, nil, nil, false, "local_chapter_missing" end
    local uid = chapter_uid(chapter)
    if uid == "" then return nil, nil, nil, false, "local_chapter_uid_missing" end
    return chapter, uid, chapter_index(chapter, toc_index), false
end

local function catalog_position(catalog, wanted_uid, wanted_idx)
    catalog = type(catalog) == "table" and catalog or {}
    if #catalog == 0 then return nil, "full_catalog_missing" end
    wanted_uid = tostring(wanted_uid or "")
    wanted_idx = tonumber(wanted_idx)
    local selected, before, total = nil, 0, 0
    for index, chapter in ipairs(catalog) do
        local words = chapter_words(chapter)
        local uid = chapter_uid(chapter)
        local idx = chapter_index(chapter, index)
        local matches = wanted_uid ~= "" and uid == wanted_uid
            or (wanted_uid == "" and wanted_idx ~= nil and (idx == wanted_idx or index == wanted_idx))
        if not selected and matches then
            selected = {chapter=chapter, index=index, before=before, words=words}
        end
        total = total + words
        if not selected then before = before + words end
    end
    if not selected then return nil, "current_chapter_not_in_full_catalog" end
    if selected.words <= 0 then return nil, "current_chapter_word_count_missing" end
    if total <= 0 then return nil, "full_catalog_word_counts_missing" end
    selected.total = total
    return selected
end

local function catalog_neighbor_candidates(catalog, primary_index, total_words)
    catalog = type(catalog) == "table" and catalog or {}
    primary_index = tonumber(primary_index)
    total_words = math.max(0, tonumber(total_words) or 0)
    if not primary_index or total_words <= 0 then return {} end

    local rows, before = {}, 0
    for index, chapter in ipairs(catalog) do
        local words = chapter_words(chapter)
        rows[index] = {chapter=chapter,index=index,before=before,words=words}
        before = before + words
    end

    local out = {}
    -- Only the immediate neighbourhood is eligible. This path is used solely
    -- after the declared chapter's source text cannot be matched, so ordinary
    -- books keep the existing exact mapping unchanged.
    for distance = 1, 2 do
        for _, index in ipairs({primary_index - distance, primary_index + distance}) do
            local row = rows[index]
            local uid = row and chapter_uid(row.chapter) or ""
            if row and row.words > 0 and uid ~= "" then
                out[#out + 1] = {
                    chapter_uid = uid,
                    chapter_index = chapter_index(row.chapter, index),
                    chapter_title = tostring(row.chapter.title or ""),
                    chapter_word_count = row.words,
                    total_word_count = total_words,
                    words_before = row.before,
                }
            end
        end
    end
    return out
end

local function unique_match(text, needle)
    if type(text) ~= "string" or type(needle) ~= "string" or needle == "" then return nil end
    local first = text:find(needle, 1, true)
    if not first then return nil end
    local second = text:find(needle, first + math.max(1, #needle), true)
    if second then return nil, "ambiguous" end
    return first
end

local function chapter_text(document, start_xp, end_xp, cache, cache_key)
    cache = type(cache) == "table" and cache or {}
    if cache.chapter_key == cache_key and type(cache.chapter_text) == "string"
        and cache.chapter_text ~= "" then
        return cache.chapter_text, cache.chapter_chars, true
    end
    local text, err = doc_text(document, start_xp, end_xp)
    if not text then return nil, nil, false, err end
    if #text > MAX_CHAPTER_BYTES then return nil, nil, false, "chapter_text_too_large" end
    local chars = U.utf8_len(text)
    if chars <= 0 then return nil, nil, false, "chapter_text_empty" end
    cache.chapter_key = cache_key
    cache.chapter_text = text
    cache.chapter_chars = chars
    cache.chapter_start_xp = start_xp
    cache.chapter_end_xp = end_xp
    return text, chars, false
end

local function locate_current_char(document, xp, chapter_text_value)
    for _, steps in ipairs(ANCHOR_STEPS) do
        local end_xp = advance_words(document, xp, steps)
        if end_xp then
            local anchor = doc_text(document, xp, end_xp)
            if anchor and anchor:find("%S") then
                local byte_pos = unique_match(chapter_text_value, anchor)
                if byte_pos then
                    return U.utf8_len(chapter_text_value:sub(1, byte_pos - 1)),
                        "forward_" .. tostring(steps), U.utf8_len(anchor)
                end
            end
        end
    end
    local before_xp = retreat_words(document, xp, 12)
    local after_xp = advance_words(document, xp, 24)
    if before_xp and after_xp then
        local before = doc_text(document, before_xp, xp)
        local after = doc_text(document, xp, after_xp)
        if before and after and (before .. after):find("%S") then
            local combined = before .. after
            local byte_pos = unique_match(chapter_text_value, combined)
            if byte_pos then
                local chars_before_match = U.utf8_len(chapter_text_value:sub(1, byte_pos - 1))
                return chars_before_match + U.utf8_len(before), "context_12_24", U.utf8_len(combined)
            end
        end
    end
    return nil, "anchor_not_unique"
end

-- Lightweight capture for the new source-coordinate path. It only reads a
-- small text window around the current XPointer; it never scans the full local
-- chapter and performs no network request.
function M.capture(ui, record, catalog)
    if type(record) ~= "table" then return nil, "record_missing" end
    local document = ui and ui.document or nil
    local toc = ui and ui.toc or nil
    if not document then return nil, "document_missing" end

    local xp, xp_error = current_xpointer(ui, document)
    if not xp then return nil, xp_error end
    local toc_index, toc_error = toc_index_for_xpointer(toc, xp)
    if not toc_index then return nil, toc_error end
    local local_row, uid, idx, standalone, chapter_error = local_chapter(record, toc_index)
    if not local_row then return nil, chapter_error end
    local catalog_row, catalog_error = catalog_position(catalog, uid, idx)
    if not catalog_row then return nil, catalog_error end
    if catalog_row.words > MAX_CHAPTER_WORDS then return nil, "chapter_too_large_for_precision" end

    local before_xp = retreat_words(document, xp, 12)
    local anchor_end = advance_words(document, xp, 24)
    local point_side = "start"
    local anchor_text
    local anchor_kind = "forward_24"
    if anchor_end then anchor_text = doc_text(document, xp, anchor_end) end

    if not anchor_text or not anchor_text:find("%S") then
        local anchor_start = retreat_words(document, xp, 24)
        if not anchor_start then return nil, "anchor_unavailable" end
        anchor_text = doc_text(document, anchor_start, xp)
        if not anchor_text or not anchor_text:find("%S") then return nil, "anchor_empty" end
        before_xp = retreat_words(document, anchor_start, 12)
        anchor_end = xp
        point_side = "end"
        anchor_kind = "backward_24"
    end

    local context_before = ""
    if before_xp then
        local boundary_start = point_side == "start" and xp or retreat_words(document, xp, 24)
        if boundary_start then context_before = doc_text(document, before_xp, boundary_start) or "" end
    end
    local context_after = ""
    if anchor_end then
        local after_xp = advance_words(document, anchor_end, 12)
        if after_xp then context_after = doc_text(document, anchor_end, after_xp) or "" end
    end

    return {
        xpointer = xp,
        toc_index = toc_index,
        chapter_uid = chapter_uid(catalog_row.chapter) ~= "" and chapter_uid(catalog_row.chapter) or uid,
        chapter_index = chapter_index(catalog_row.chapter, catalog_row.index),
        chapter_title = tostring(catalog_row.chapter.title or local_row.title or ""),
        chapter_word_count = catalog_row.words,
        total_word_count = catalog_row.total,
        words_before = catalog_row.before,
        standalone = standalone == true,
        anchor_text = anchor_text,
        context_before = context_before,
        context_after = context_after,
        point_side = point_side,
        anchor_kind = anchor_kind,
        anchor_chars = U.utf8_len(anchor_text),
        book_version = tonumber(record.book and (record.book.version or record.book.bookVersion))
            or tonumber(record.record and (record.record.book_version or record.record.bookVersion)) or 0,
        chapter_candidates = catalog_neighbor_candidates(catalog, catalog_row.index, catalog_row.total),
    }
end

-- Existing local-only precision path kept intact as a fallback. It scans only
-- the already-open CRE document and never uses the network.
function M.locate(ui, record, catalog, cache)
    local started = now_ms()
    if type(record) ~= "table" then return nil, "record_missing" end
    local document = ui and ui.document or nil
    local toc = ui and ui.toc or nil
    if not document then return nil, "document_missing" end

    local xp, xp_error = current_xpointer(ui, document)
    if not xp then return nil, xp_error end
    local toc_index, toc_error = toc_index_for_xpointer(toc, xp)
    if not toc_index then return nil, toc_error end

    local local_row, uid, idx, standalone, chapter_error = local_chapter(record, toc_index)
    if not local_row then return nil, chapter_error end
    local catalog_row, catalog_error = catalog_position(catalog, uid, idx)
    if not catalog_row then return nil, catalog_error end
    if catalog_row.words > MAX_CHAPTER_WORDS then return nil, "chapter_too_large_for_precision" end

    local start_xp, end_xp, bounds_error = chapter_bounds(document, toc, toc_index)
    if not start_xp then return nil, bounds_error end
    local cache_key = table.concat({
        tostring(record.path or ""), tostring(uid), tostring(toc_index), start_xp, end_xp,
    }, "|")
    local text, total_chars, reused, text_error = chapter_text(document, start_xp, end_xp, cache, cache_key)
    if not text then return nil, text_error end

    local chars_before, anchor_kind, anchor_chars = locate_current_char(document, xp, text)
    if chars_before == nil then return nil, anchor_kind end
    chars_before = math.max(0, math.min(total_chars, chars_before))
    local within = total_chars > 0 and chars_before / total_chars or 0
    within = U.clamp(within, 0, 1)
    local offset = math.max(0, math.min(catalog_row.words,
        math.floor(catalog_row.words * within + 0.5)))
    local progress = U.clamp(((catalog_row.before + offset) / catalog_row.total) * 100, 0, 100)
    local elapsed = math.max(0, now_ms() - started)

    return {
        progress = progress,
        chapter_uid = chapter_uid(catalog_row.chapter) ~= "" and chapter_uid(catalog_row.chapter) or uid,
        chapter_index = chapter_index(catalog_row.chapter, catalog_row.index),
        offset = offset,
        chapter_offset = offset,
        chapter_word_count = catalog_row.words,
        total_word_count = catalog_row.total,
        words_before = catalog_row.before,
        chapter_percent = math.floor(within * 100 + 0.5),
        chapter_ratio = within,
        summary = tostring(catalog_row.chapter.title or local_row.title or ""),
        safe = true,
        precise = true,
        standalone = standalone == true,
        source = "xpointer_text_anchor",
        position_basis = "xpointer_text_anchor",
        precision_ms = math.floor(elapsed + 0.5),
        precision_anchor = anchor_kind,
        precision_anchor_chars = tonumber(anchor_chars) or 0,
        precision_chapter_chars = total_chars,
        precision_cache_hit = reused == true,
    }
end

return M
