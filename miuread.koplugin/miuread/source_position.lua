local U = require("miuread.util")
local PosMap = require("miuread.annotations.posmap")
local WRCo = require("miuread.wr_co")

local M = {}

local MAX_SOURCE_BYTES = 2 * 1024 * 1024

local function scalar(value)
    if type(value) == "string" or type(value) == "number" then return tostring(value) end
    return ""
end

local function chapter_uid(chapter)
    return scalar(type(chapter) == "table" and
        (chapter.chapterUid or chapter.uid or chapter.chapter_uid) or nil)
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

local function cache_paths(reader, book_id, uid, version)
    local store = reader and reader.store or nil
    local name = U.id_name(tostring(uid or "unknown"))
        .. "-v" .. U.id_name(tostring(version or 0)) .. ".xhtml"
    local paths = {}

    -- beta.14: keep coordinate source beside the book cache so downloaded
    -- chapters remain precisely mappable after restart and while offline.
    if store and type(store.book_dir) == "function" and tostring(book_id or "") ~= "" then
        local ok, book_root = pcall(store.book_dir, store, tostring(book_id))
        if ok and tostring(book_root or "") ~= "" then
            local root = tostring(book_root) .. "/progress-source-position"
            U.mkdir(root)
            paths[#paths + 1] = root .. "/" .. name
        end
    end

    -- Read the old beta.13 temp cache as a compatibility fallback. New writes
    -- prefer the persistent per-book path above.
    local temp_root = store and tostring(store.temp_dir or "") or ""
    if temp_root ~= "" then
        local root = temp_root .. "/progress-source-position"
        local dir = root .. "/" .. U.id_name(tostring(book_id or "unknown"))
        U.mkdir(root)
        U.mkdir(dir)
        paths[#paths + 1] = dir .. "/" .. name
    end
    return paths
end

local function read_cached(path)
    if not path then return nil end
    local size = U.file_size(path)
    if not size or size <= 0 or size > MAX_SOURCE_BYTES then return nil end
    local value = U.read_file(path, true)
    if type(value) ~= "string" or value == "" then return nil end
    return value
end

local function fetch_coord_html(reader, record, anchor, options)
    options = type(options) == "table" and options or {}
    if not (reader and type(reader.chapter) == "function") then
        return nil, nil, "reader_chapter_unavailable"
    end
    record = type(record) == "table" and record or {}
    local book = type(record.book) == "table" and record.book or {}
    local uid = tostring(anchor.chapter_uid or "")
    if uid == "" then return nil, nil, "chapter_uid_missing" end

    local version = tonumber(anchor.book_version or book.version or book.bookVersion
        or (record.record and (record.record.book_version or record.record.bookVersion))) or 0
    local paths = cache_paths(reader, book.book_id or book.bookId, uid, version)
    for _, path in ipairs(paths) do
        local cached = read_cached(path)
        if cached then return cached, true end
    end
    if options.cache_only == true then
        return nil, nil, "coord_cache_missing"
    end

    local chapter = {
        uid = uid,
        chapterUid = uid,
        chapterIdx = tonumber(anchor.chapter_index) or 0,
        index = tonumber(anchor.chapter_index) or 0,
        title = tostring(anchor.chapter_title or ""),
    }
    local book_arg = {
        bookId = tostring(book.book_id or book.bookId or ""),
        book_id = tostring(book.book_id or book.bookId or ""),
        title = book.title,
        author = book.author,
    }
    if book_arg.bookId == "" then return nil, nil, "book_id_missing" end

    local ok, downloaded, _, _, state = pcall(reader.chapter, reader,
        book_arg, chapter, "epub", {images=false})
    if not ok then return nil, nil, "coord_fetch_failed:" .. tostring(downloaded) end

    local coord_html = type(state) == "table" and tostring(state.coord_html or "") or ""
    if coord_html == "" then coord_html = tostring(downloaded or "") end
    if coord_html == "" then return nil, nil, "coord_html_missing" end
    if #coord_html > MAX_SOURCE_BYTES then return nil, nil, "coord_html_too_large" end

    local write_path = paths[1]
    if write_path then pcall(U.atomic_write, write_path, coord_html, true) end
    return coord_html, false
end

function M.chapterSource(reader, book_id, uid, version, options)
    options = type(options) == "table" and options or {}
    local record = {
        book = {
            book_id = tostring(book_id or ""),
            bookId = tostring(book_id or ""),
            version = tonumber(version) or 0,
            bookVersion = tonumber(version) or 0,
            title = tostring(options.book_title or ""),
            author = tostring(options.book_author or ""),
        },
    }
    local anchor = {
        chapter_uid = tostring(uid or ""),
        chapter_index = tonumber(options.chapter_index) or 0,
        chapter_title = tostring(options.chapter_title or ""),
        book_version = tonumber(version) or 0,
    }
    return fetch_coord_html(reader, record, anchor, {cache_only = options.cache_only == true})
end

function M.cacheChapter(reader, book_id, uid, version, coord_html)
    coord_html = tostring(coord_html or "")
    if coord_html == "" then return false, "coord_html_missing" end
    if #coord_html > MAX_SOURCE_BYTES then return false, "coord_html_too_large" end
    local paths = cache_paths(reader, book_id, uid, version)
    local path = paths[1]
    if not path then return false, "source_cache_unavailable" end
    local ok, err = U.atomic_write(path, coord_html, true)
    if not ok then return false, tostring(err or "source_cache_write_failed") end
    return true, path
end

local function norm_count_before(map, text_boundary)
    local norm_map = type(map) == "table" and map.norm_map or nil
    if type(norm_map) ~= "table" or #norm_map == 0 then return nil end
    text_boundary = math.max(1, math.floor(tonumber(text_boundary) or 1))
    local lo, hi, found = 1, #norm_map, 0
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if tonumber(norm_map[mid]) and norm_map[mid] < text_boundary then
            found = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return found
end

local function locate_anchor(map, anchor)
    local text = U.trim(tostring(anchor.anchor_text or ""))
    if text == "" then return nil, "anchor_text_missing" end
    local range_key, html_start, html_end_pos = PosMap.locate(map, text, {
        context_before = tostring(anchor.context_before or ""),
        context_after = tostring(anchor.context_after or ""),
    })
    if not range_key then return nil, tostring(html_start or "not_found") end
    local text_start, text_end_pos = PosMap.htmlToText(map, html_start, html_end_pos)
    if not text_start or not text_end_pos then return nil, "text_map_failed" end

    local point_side = tostring(anchor.point_side or "start")
    local boundary = point_side == "end" and text_end_pos or text_start
    local html_boundary = html_start
    local html_boundary_kind = "anchor_start"
    if point_side == "end" then
        -- Backward anchors end immediately before the current XPointer. A raw
        -- half-open HTML end can land on a closing tag, which Web Reader never
        -- exposes as a text `data-wr-co`. Prefer the next visible source rune;
        -- at chapter end fall back to the last visible anchor rune.
        local next_text
        for i = text_end_pos, #(map.text_runes or {}) do
            local r = map.text_runes[i]
            if r and not r:match("%s") and r ~= "*" then
                next_text = i
                break
            end
        end
        if next_text and map.text_to_html[next_text] then
            html_boundary = map.text_to_html[next_text]
            html_boundary_kind = "next_visible_text"
        else
            html_boundary = map.text_to_html[text_end_pos - 1] or html_end_pos
            html_boundary_kind = "last_visible_text"
        end
    end
    local norm_before = norm_count_before(map, boundary)
    local norm_total = type(map.norm_map) == "table" and #map.norm_map or 0
    if norm_before == nil or norm_total <= 0 then return nil, "normalized_text_missing" end

    return {
        range = range_key,
        html_start = html_start,
        html_end_pos = html_end_pos,
        text_start = text_start,
        text_end_pos = text_end_pos,
        text_boundary = boundary,
        html_boundary = html_boundary,
        html_boundary_kind = html_boundary_kind,
        norm_before = norm_before,
        norm_total = norm_total,
    }
end

local function locate_single(reader, record, anchor, options)
    options = type(options) == "table" and options or {}
    anchor = type(anchor) == "table" and anchor or {}
    local words = math.max(0, tonumber(anchor.chapter_word_count) or 0)
    local total_words = math.max(0, tonumber(anchor.total_word_count) or 0)
    local words_before = math.max(0, tonumber(anchor.words_before) or 0)
    if words <= 0 or total_words <= 0 then return nil, "catalog_word_counts_missing" end

    local coord_html, cache_hit, fetch_error = fetch_coord_html(reader, record, anchor, options)
    if not coord_html then return nil, fetch_error end
    local built_ok, map = pcall(PosMap.build, coord_html)
    if not built_ok or type(map) ~= "table" then
        return nil, "source_map_build_failed:" .. tostring(map)
    end

    local located, locate_error = locate_anchor(map, anchor)
    if not located then return nil, locate_error end

    local within = U.clamp(located.norm_before / located.norm_total, 0, 1)
    -- Keep the old word-space candidate only for progress/fallback diagnostics.
    -- Native Web Reader `co` is a raw source coordinate and is not bounded by
    -- chapter.wordCount.
    local source_word_offset = math.max(0, math.min(words, math.floor(words * within + 0.5)))
    local progress = U.clamp(((words_before + source_word_offset) / total_words) * 100, 0, 100)

    local native, native_error = WRCo.fromMap(map, located.html_boundary)
    local native_ok = type(native) == "table" and tonumber(native.co) ~= nil
    local offset = native_ok and math.max(0, math.floor(tonumber(native.co))) or source_word_offset

    return {
        progress = progress,
        display_progress = progress,
        display_progress_quality = "precise_source_mapped",
        chapter_uid = tostring(anchor.chapter_uid or ""),
        chapter_index = tonumber(anchor.chapter_index) or 0,
        offset = offset,
        chapter_offset = offset,
        chapter_word_count = words,
        total_word_count = total_words,
        words_before = words_before,
        chapter_percent = math.floor(within * 100 + 0.5),
        chapter_ratio = within,
        summary = tostring(anchor.chapter_title or ""),
        safe = true,
        precise = true,
        standalone = anchor.standalone == true,
        source = native_ok and "weread_native_wr_co" or "weread_source_anchor",
        position_basis = native_ok and "wr_data_co" or "weread_source_norm_anchor",
        offset_basis = native_ok and "wr_data_co" or "weread_source_norm_anchor",
        native_offset = native_ok,
        confidence = native_ok and "native" or "exact",
        source_cache_hit = cache_hit == true,
        source_html_start = located.html_start,
        source_html_boundary = located.html_boundary,
        source_html_boundary_kind = located.html_boundary_kind,
        source_text_start = located.text_start,
        source_text_boundary = located.text_boundary,
        source_norm_start = located.norm_before,
        source_norm_total = located.norm_total,
        source_xpointer = tostring(anchor.xpointer or ""),
        source_word_offset = source_word_offset,
        source_wr_co = native_ok and offset or nil,
        source_wr_co_basis = native_ok and tostring(native.basis or "raw_xhtml_utf16") or nil,
        source_wr_co_rune_boundary = native_ok and tonumber(native.rune_boundary) or nil,
        source_wr_co_utf16_extra = native_ok and tonumber(native.utf16_extra) or nil,
        source_wr_co_error = native_ok and nil or tostring(native_error or "wr_co_unavailable"),
        precision_anchor = tostring(anchor.anchor_kind or "source_anchor"),
        precision_anchor_chars = tonumber(anchor.anchor_chars) or 0,
    }
end

local function neighbour_retryable(error_value)
    local err = tostring(error_value or "")
    return err == "not_found" or err == "ambiguous"
end

function M.locate(reader, record, anchor, options)
    options = type(options) == "table" and options or {}
    anchor = type(anchor) == "table" and anchor or {}

    local primary, primary_error = locate_single(reader, record, anchor, options)
    if primary then return primary end
    if not neighbour_retryable(primary_error) then return nil, primary_error end

    local matches = {}
    for _, row in ipairs(type(anchor.chapter_candidates) == "table" and anchor.chapter_candidates or {}) do
        local candidate = U.copy(anchor)
        candidate.chapter_candidates = nil
        candidate.chapter_uid = tostring(row.chapter_uid or "")
        candidate.chapter_index = tonumber(row.chapter_index) or 0
        candidate.chapter_title = tostring(row.chapter_title or "")
        candidate.chapter_word_count = tonumber(row.chapter_word_count) or 0
        candidate.total_word_count = tonumber(row.total_word_count) or tonumber(anchor.total_word_count) or 0
        candidate.words_before = tonumber(row.words_before) or 0
        if candidate.chapter_uid ~= "" and candidate.chapter_word_count > 0 then
            local value = locate_single(reader, record, candidate, options)
            if value then
                matches[#matches + 1] = value
                if #matches > 1 then return nil, "neighbor_anchor_ambiguous" end
            end
        end
    end

    if #matches == 1 then
        local recovered = matches[1]
        recovered.mapping_recovered = true
        recovered.mapping_recovery = "neighbor_source_anchor"
        recovered.mapping_original_chapter_uid = tostring(anchor.chapter_uid or "")
        recovered.mapping_original_chapter_index = tonumber(anchor.chapter_index) or 0
        return recovered
    end
    return nil, tostring(primary_error or "source_anchor_not_found")
end

local function catalog_row(catalog, wanted_uid, wanted_idx)
    catalog = type(catalog) == "table" and catalog or {}
    wanted_uid = tostring(wanted_uid or "")
    wanted_idx = tonumber(wanted_idx)
    local selected, before, total = nil, 0, 0
    for index, row in ipairs(catalog) do
        local words = chapter_words(row)
        local uid = chapter_uid(row)
        local idx = chapter_index(row, index)
        local matches = wanted_uid ~= "" and uid == wanted_uid
            or (wanted_uid == "" and wanted_idx ~= nil and (idx == wanted_idx or index == wanted_idx))
        if not selected and matches then
            selected = {row=row, index=index, before=before, words=words}
        end
        total = total + words
        if not selected then before = before + words end
    end
    if not selected then return nil, "remote_chapter_not_in_catalog" end
    if selected.words <= 0 or total <= 0 then return nil, "remote_catalog_word_counts_missing" end
    selected.total = total
    return selected
end

local function nearest_text_index(map, html_boundary)
    local runes = type(map) == "table" and map.runes or nil
    local html_to_text = type(map) == "table" and map.html_to_text or nil
    local text_runes = type(map) == "table" and map.text_runes or nil
    if type(runes) ~= "table" or type(html_to_text) ~= "table"
        or type(text_runes) ~= "table" or #text_runes == 0 then
        return nil, "remote_source_text_map_missing"
    end
    local boundary = math.max(1, math.min(#runes + 1, math.floor(tonumber(html_boundary) or 1)))
    for i = boundary, #runes do
        local t = html_to_text[i]
        local r = t and text_runes[t] or nil
        if t and r and not r:match("%s") and r ~= "*" then return t end
    end
    for i = math.min(boundary - 1, #runes), 1, -1 do
        local t = html_to_text[i]
        local r = t and text_runes[t] or nil
        if t and r and not r:match("%s") and r ~= "*" then return t end
    end
    return nil, "remote_source_text_boundary_missing"
end

-- Cloud chapterOffset is the Web Reader's raw-XHTML UTF-16 coordinate, not a
-- wordCount offset. Convert it back through the same source map used by local
-- uploads before deriving a fractional whole-book progress. The raw `co` is
-- preserved verbatim for upload verification.
function M.remoteProgress(reader, record, remote, catalog)
    remote = type(remote) == "table" and remote or {}
    local uid = tostring(remote.chapter_uid or remote.chapterUid or "")
    local idx = tonumber(remote.chapter_idx or remote.chapterIndex)
    local co = tonumber(remote.offset or remote.chapter_offset or remote.chapterOffset)
    if uid == "" then return nil, "remote_chapter_uid_missing" end
    if co == nil then return nil, "remote_chapter_offset_missing" end

    local selected, catalog_error = catalog_row(catalog, uid, idx)
    if not selected then return nil, catalog_error end
    local anchor = {
        chapter_uid = uid,
        chapter_index = chapter_index(selected.row, idx or selected.index),
        chapter_title = tostring(selected.row.title or ""),
        book_version = tonumber(type(record) == "table" and type(record.book) == "table"
            and (record.book.version or record.book.bookVersion) or nil) or 0,
    }
    local coord_html, cache_hit, fetch_error = fetch_coord_html(reader, record, anchor, nil)
    if not coord_html then return nil, fetch_error end
    local built_ok, map = pcall(PosMap.build, coord_html)
    if not built_ok or type(map) ~= "table" then
        return nil, "remote_source_map_build_failed:" .. tostring(map)
    end
    local resolved, resolve_error = WRCo.toMap(map, co)
    if not resolved then return nil, resolve_error end
    local text_index, text_error = nearest_text_index(map, resolved.rune_boundary)
    if not text_index then return nil, text_error end
    local norm_before = norm_count_before(map, text_index)
    local norm_total = type(map.norm_map) == "table" and #map.norm_map or 0
    if norm_before == nil or norm_total <= 0 then return nil, "remote_normalized_text_missing" end

    local within = U.clamp(norm_before / norm_total, 0, 1)
    local word_offset = math.max(0, math.min(selected.words,
        math.floor(selected.words * within + 0.5)))
    local percent = U.clamp(((selected.before + word_offset) / selected.total) * 100, 0, 100)
    local out = U.copy(remote)
    out.raw_percent = tonumber(out.raw_percent or out.percent)
    out.percent = percent
    out.calculated_percent = percent
    out.chapter_uid = chapter_uid(selected.row) ~= "" and chapter_uid(selected.row) or uid
    out.chapter_idx = chapter_index(selected.row, selected.index)
    out.offset = math.max(0, math.floor(co + 0.5))
    out.chapter_offset = out.offset
    out.chapter_word_count = selected.words
    out.total_word_count = selected.total
    out.words_before = selected.before
    out.source_word_offset = word_offset
    out.chapter_ratio = within
    out.position_basis = "wr_data_co"
    out.offset_basis = "wr_data_co"
    out.native_offset = true
    out.native_resolved = true
    out.native_exact = resolved.exact ~= false
    out.source_cache_hit = cache_hit == true
    return out
end

return M
