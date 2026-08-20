local Config = require("miuread.config")
local Codec = require("miuread.codec")
local AnnotationCoord = require("miuread.annotation_coord")
local Footnotes = require("miuread.footnotes")
local Epub = require("miuread.epub")
local Downloader = require("miuread.downloader")
local Thoughts = require("miuread.thoughts")
local Reader = require("miuread.reader")
local Sync = require("miuread.sync")
local U = require("miuread.util")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local StreamReader = {}
StreamReader.__index = StreamReader

local BASE_CSS = [[
body { line-height: 1.75; margin: 5%; }
img { max-width: 100%; height: auto; }
.miu-chapter { display: block; page-break-before: always; break-before: page; }
.miu-chapter-title { font-size: 1.55em; font-weight: bold; line-height: 1.35; margin: 1.2em 0 .9em 0; page-break-before: always; break-before: page; }
]]
local TITLE_TRANSFORM_VERSION = 2

local function chapter_uid(chapter)
    return tostring(chapter and (chapter.chapterUid or chapter.uid) or "")
end

local function normalized_book(value)
    value = type(value) == "table" and value or {}
    local source = value.bookInfo or value.book or value
    return {
        bookId = tostring(source.bookId or source.book_id or value.bookId or value.book_id or ""),
        title = tostring(source.title or value.title or "未命名"),
        author = tostring(source.author or value.author or ""),
        cover = source.cover or source.coverUrl or value.cover,
        category = source.category or value.category,
        version = tonumber(source.version or source.bookVersion or source.book_version
            or value.version or value.bookVersion or value.book_version),
    }
end

local function catalog_map(chapters)
    local rows = {}
    for index, chapter in ipairs(chapters or {}) do
        rows[#rows + 1] = {
            uid = chapter_uid(chapter),
            chapter_uid = chapter_uid(chapter),
            title = tostring(chapter.title or ""),
            index = index,
            word_count = tonumber(chapter.wordCount or chapter.word_count) or 0,
        }
    end
    return rows
end

local function chapter_words(chapter)
    return math.max(1, tonumber(chapter and (chapter.wordCount or chapter.word_count)) or 0)
end

local function chapter_catalog_index(chapter, fallback)
    return tonumber(chapter and (chapter._miuread_catalog_index or chapter.chapterIdx
        or chapter.index or chapter.chapter_index or chapter.chapter_idx)) or tonumber(fallback)
end

local function is_copyright_chapter(chapter)
    local title = tostring(chapter and chapter.title or ""):gsub("%s+", "")
    if title == "" then return false end
    if title == "版权信息" or title == "版权页" or title == "版权" then return true end
    if title:lower() == "copyrightpage" or title:find("版权所有", 1, true) then return true end
    return false
end

local function is_auto_skip(chapter)
    chapter = type(chapter) == "table" and chapter or {}
    if Reader._is_cover_chapter(chapter) then return true end
    if is_copyright_chapter(chapter) then return true end
    if Reader._is_structure_chapter(chapter) then
        local words = tonumber(chapter.wordCount or chapter.word_count) or 0
        if words <= 0 then return true end
    end
    return false
end

local function skip_forward(chapters, index)
    index = math.max(1, tonumber(index) or 1)
    while index <= #(chapters or {}) and is_auto_skip(chapters[index]) do
        index = index + 1
    end
    if index > #(chapters or {}) then
        return math.max(1, #(chapters or {}))
    end
    return index
end

local function resolve_by_percent(chapters, percent)
    local ratio = U.clamp(tonumber(percent) or 0, 0, 100) / 100
    local total, acc = 0, 0
    for _, chapter in ipairs(chapters or {}) do
        total = total + chapter_words(chapter)
    end
    if total <= 0 then return 1, 0 end
    local target = ratio * total
    for index, chapter in ipairs(chapters or {}) do
        local words = chapter_words(chapter)
        if target <= acc + words or index == #(chapters or {}) then
            return index, math.max(0, math.floor(target - acc))
        end
        acc = acc + words
    end
    return 1, 0
end

local function resolve_start_index(chapters, progress)
    progress = type(progress) == "table" and progress or {}
    chapters = chapters or {}
    if #chapters == 0 then return 1, 0 end

    local wanted_uid = tostring(progress.chapter_uid or progress.chapterUid or "")
    local wanted_idx = tonumber(progress.chapter_idx or progress.chapterIdx or progress.chapter_index)
    local offset = tonumber(progress.offset or progress.chapterOffset or progress.chapterPos)

    if wanted_uid ~= "" then
        for index, chapter in ipairs(chapters) do
            if chapter_uid(chapter) == wanted_uid then
                return index, offset or 0
            end
        end
    end

    if wanted_idx ~= nil then
        for index, chapter in ipairs(chapters) do
            local cat_idx = chapter_catalog_index(chapter, index)
            if cat_idx == wanted_idx or index == wanted_idx or index - 1 == wanted_idx
                or cat_idx == wanted_idx + 1 then
                return index, offset or 0
            end
        end
    end

    local percent = tonumber(progress.percent or progress.progress or progress.readingProgress)
    if percent ~= nil then
        if percent > 0 and percent <= 1 then percent = percent * 100 end
        return resolve_by_percent(chapters, percent)
    end

    return nil, offset or 0
end

local function choose_remote_progress(web, agent)
    if web and agent then
        local delta = math.abs((tonumber(web.percent) or 0) - (tonumber(agent.percent) or 0))
        if delta <= 2 then return web end
        local wt = tonumber(web.updated_at) or 0
        local at = tonumber(agent.updated_at) or 0
        return wt >= at and web or agent
    end
    return web or agent
end

local function resolve_index(chapters, progress)
    local index, offset = resolve_start_index(chapters, progress)
    if not index then
        index = skip_forward(chapters, 1)
    else
        index = skip_forward(chapters, index)
    end
    return index, offset
end

local function chapter_offset_percent(chapter, progress, resolved_offset)
    local offset = tonumber(resolved_offset)
    if offset == nil then
        progress = type(progress) == "table" and progress or {}
        offset = tonumber(progress.chapterOffset or progress.chapterPos or progress.offset) or 0
    end
    local words = tonumber(chapter and (chapter.wordCount or chapter.word_count)) or 0
    if offset <= 0 or words <= 0 then return nil end
    return U.clamp(offset / words * 100, 0, 99.5)
end

local function ensure_dir(path)
    path = tostring(path or "")
    if path == "" then return false, "invalid path" end
    if lfs.attributes(path, "mode") == "directory" then return true end
    if not U.mkdir(path) and lfs.attributes(path, "mode") ~= "directory" then
        return false, "mkdir failed"
    end
    return true
end

local function wipe_dir(path)
    if not path or lfs.attributes(path, "mode") ~= "directory" then return end
    for _, entry in ipairs(U.list(path)) do
        local mode = lfs.attributes(entry, "mode")
        if mode == "directory" then
            U.remove_tree(entry)
        else
            os.remove(entry)
        end
    end
end

function StreamReader:new(store, reader, api, annotations, downloader)
    return setmetatable({
        store = store,
        reader = reader,
        api = api,
        annotations = annotations,
        downloader = downloader,
        annotation_cache = {},
        annotation_suspended = false,
        annotation_error_kind = nil,
        annotation_recovery_attempted = false,
    }, self)
end

function StreamReader:fetch_progress(book_id)
    book_id = tostring(book_id or "")
    if book_id == "" then return {} end

    local ok_web, web_raw = pcall(self.api.web_progress, self.api, book_id)
    local ok_agent, agent_raw = pcall(self.api.progress, self.api, book_id)
    local web = ok_web and Sync._response_progress(web_raw, book_id) or nil
    local agent = ok_agent and Sync._response_progress(agent_raw, book_id) or nil
    local selected = choose_remote_progress(web, agent) or {}

    if type(selected) == "table" then
        selected._progress_source = tostring(selected.source or (web and "web_cookie" or (agent and "agent_gateway" or "none")))
    end
    return selected
end

function StreamReader:init_book(book)
    book = normalized_book(book)
    if book.bookId == "" then return nil end

    local catalog_raw, chapters = self.downloader:catalog(book.bookId)
    if not chapters or #chapters == 0 then return nil end

    local progress = self:fetch_progress(book.bookId)
    if type(progress) == "table" and #chapters > 0 and Sync._catalog_progress_from_remote then
        local mapped = catalog_map(chapters)
        for index, row in ipairs(mapped) do
            row.index = index
        end
        progress = Sync._catalog_progress_from_remote(U.copy(progress), mapped) or progress
    end

    local tmp_dir = tostring(Config.STREAM_TMP_DIR or "/tmp/miuread-stream") .. "/" .. U.id_name(book.bookId)
    local ok_dir, dir_err = ensure_dir(tmp_dir)
    if not ok_dir then return nil end

    self.book = book
    self.catalog_raw = catalog_raw
    self.chapters = chapters
    self.format = catalog_raw.format == "txt" and "txt" or "epub"
    self.progress = progress
    self.tmp_dir = tmp_dir
    self.epub_clean_path = tmp_dir .. "/stream-clean.epub"
    self.epub_notes_path = tmp_dir .. "/stream-notes.epub"
    self.epub_path = self.epub_clean_path
    self.work_dir = tmp_dir .. "/.work"
    self.active = true

    local start_index, start_offset = resolve_index(chapters, progress)
    self.current_index = start_index
    self.pending_percent = chapter_offset_percent(chapters[start_index], progress, start_offset)

    logger.info("[MiuRead][Stream] book ready", "book=", book.bookId,
        "chapters=", tostring(#chapters), "start=", tostring(start_index),
        "uid=", tostring(progress.chapter_uid or progress.chapterUid or ""),
        "idx=", tostring(progress.chapter_idx or progress.chapterIdx or ""),
        "percent=", tostring(progress.percent or progress.progress or ""),
        "offset=", tostring(start_offset or ""),
        "progress_source=", tostring(progress._progress_source or progress.source or "none"))
    return self
end

function StreamReader:_fetch_annotations(book_id, chapter)
    local uid = chapter_uid(chapter)
    logger.warn("[MiuRead][Stream] fetching annotations",
        "book=", tostring(book_id), "chapter=", uid)
    if not self.annotations or type(self.annotations.fetch_chapter) ~= "function" then
        logger.warn("[MiuRead][Stream] annotations module unavailable",
            "book=", tostring(book_id), "chapter=", uid)
        return {
            book_id = tostring(book_id), chapter_uid = uid,
            underlines = {}, review_map = {}, review_groups = {},
            underline_count = 0, thought_count = 0, thought_entry_count = 0,
            complete = false, errors = {"annotations module unavailable"},
        }
    end

    local previous = self.annotation_cache[uid]
    if type(previous) ~= "table" then
        previous = self.annotations:from_cache({book_id = tostring(book_id), chapter_uid = uid})
    end

    if self.annotation_suspended == true then
        local cached = previous or self.annotations:from_cache({book_id = tostring(book_id), chapter_uid = uid})
        cached.complete = false
        cached.review_complete = false
        cached.error_kind = self.annotation_error_kind or "deferred"
        cached.errors = cached.errors or {}
        if #cached.errors == 0 then
            if cached.error_kind == "rate_limit" then
                cached.errors[#cached.errors + 1] = "划线和想法请求暂时受限，章节继续加载，稍后可重试"
            elseif cached.error_kind == "forbidden" then
                cached.errors[#cached.errors + 1] = "划线和想法接口暂时不可用，章节继续加载"
            else
                cached.errors[#cached.errors + 1] = "划线和想法暂未补全，章节继续加载"
            end
        end
        return cached
    end

    local function persist_checkpoint(snapshot)
        local merged = self.annotations:merge(previous, snapshot)
        merged.saved_at = os.time()
        self.annotation_cache[uid] = merged
        previous = merged
        return merged
    end

    local function fetch_once()
        return self.annotations:fetch_chapter(book_id, uid, nil, {
            previous = previous,
            checkpoint = persist_checkpoint,
            review_batch_size = 5,
        })
    end

    local ok, current = pcall(fetch_once)
    if not ok or type(current) ~= "table" then
        current = {
            book_id = tostring(book_id), chapter_uid = uid,
            underlines = {}, review_map = {}, review_groups = {},
            underline_count = 0, thought_count = 0, thought_entry_count = 0,
            underline_request_ok = false, review_complete = false, complete = false,
            error_kind = "server", errors = { tostring(current) },
        }
    end

    if (current.auth_required == true or current.forbidden == true)
        and not self.annotation_recovery_attempted
        and self.reader and type(self.reader._recover_login_session) == "function" then
        self.annotation_recovery_attempted = true
        local recovered = self.reader:_recover_login_session()
        if recovered then
            local retry_ok, retry_data = pcall(fetch_once)
            if retry_ok and type(retry_data) == "table" then current = retry_data end
        end
    end

    local merged
    if current == previous then
        merged = current
    else
        merged = self.annotations:merge(previous, current)
    end
    merged.saved_at = os.time()
    self.annotation_cache[uid] = merged

    if current.rate_limited == true then
        self.annotation_suspended = true
        self.annotation_error_kind = "rate_limit"
        merged.complete = false
        merged.review_complete = false
        merged.rate_limited = true
        merged.error_kind = "rate_limit"
        merged.errors = merged.errors or {}
        if #merged.errors == 0 then
            merged.errors[#merged.errors + 1] = "划线和想法请求暂时受限，章节继续加载，稍后可重试"
        end
        self.annotation_cache[uid] = merged
        logger.warn("[MiuRead][Stream] annotation rate limit deferred",
            "book=", tostring(book_id), "chapter=", uid)
    end
    if current.forbidden == true then
        self.annotation_suspended = true
        self.annotation_error_kind = "forbidden"
    elseif merged.complete ~= true and tostring(current.error_kind or "") ~= "data" then
        self.annotation_suspended = true
        self.annotation_error_kind = current.error_kind or "incomplete"
    end

    logger.warn("[MiuRead][Stream] annotations fetched",
        "book=", tostring(book_id), "chapter=", uid,
        "underlines=", tostring(merged.underline_count or 0),
        "thought_groups=", tostring(merged.thought_count or 0),
        "thought_entries=", tostring(merged.thought_entry_count or 0),
        "review_complete=", tostring(merged.review_complete == true),
        "pending=", tostring(#(merged.pending_ranges or {})),
        "errors=", tostring(#(merged.errors or {})))
    if type(merged.review_groups) == "table" and #merged.review_groups > 0 then
        local saved, save_err = Thoughts.save(self.store, book_id, uid, merged.review_groups)
        if not saved then
            logger.warn("[MiuRead][Stream] thoughts save failed",
                "book=", tostring(book_id), "chapter=", uid, "error=", tostring(save_err or ""))
        else
            logger.info("[MiuRead][Stream] thoughts saved",
                "book=", tostring(book_id), "chapter=", uid,
                "groups=", tostring(merged.thought_count or #merged.review_groups))
        end
    end
    return merged
end

function StreamReader:build_chapter(index, options)
    options = type(options) == "table" and options or {}
    local fetch_annotations = options.fetch_annotations == true
    index = tonumber(index) or self.current_index or 1
    local chapter = self.chapters[index]
    if not chapter then return nil, "章节不存在" end
    logger.warn("[MiuRead][Stream] build_chapter",
        "book=", tostring(self.book and self.book.bookId or ""), "index=", tostring(index),
        "uid=", chapter_uid(chapter), "annotations=", tostring(fetch_annotations))

    wipe_dir(self.work_dir)
    ensure_dir(self.work_dir)

    local book = self.book
    local uid = chapter_uid(chapter)
    local ok_content, body, style, assets, state = pcall(
        self.reader.chapter, self.reader, book, chapter, self.format, { images = true })
    if not ok_content then return nil, tostring(body) end

    local coord_body = type(state) == "table" and tostring(state.coord_html or "") or ""
    if coord_body == "" then coord_body = AnnotationCoord.fromDownloadedXhtml(body) end
    body = Codec.body(body)
    body, style, assets = Downloader._namespace_assets(body, style, assets, uid)

    local annotation, apply_stats
    if fetch_annotations then
        annotation = self:_fetch_annotations(book.bookId, chapter)
        local extra_css
        body, extra_css, apply_stats = self.annotations:apply(body, annotation, coord_body)
        style = tostring(style or "") .. "\n" .. tostring(extra_css or "")
    end

    local foot_ok, foot_body, foot_section, foot_stats = pcall(Footnotes.process, body, {
        is_txt = self.format == "txt" or (state and state.content_format == "txt"),
        book_dir = self.work_dir,
        current_chapter_uid = uid,
        defer_cross_file = true,
    })
    if foot_ok and foot_stats and tonumber(foot_stats.unresolved or 0) == 0 then
        local transformed = tostring(foot_body or "") .. tostring(foot_section or "")
        local footnote_valid = Footnotes.validate(transformed)
        if footnote_valid then
            body = transformed
            if foot_section and foot_section ~= "" then
                style = style .. "\n" .. Footnotes.FOOTNOTES_CSS
            end
        end
    end

    local fallback_title = "第 " .. tostring(index) .. " 节"
    local title = chapter.title and chapter.title ~= "" and chapter.title or fallback_title
    body = Downloader._prepare_chapter_body(body, title, TITLE_TRANSFORM_VERSION)

    local css = BASE_CSS .. "\n" .. tostring(style or "")
    local chapter_entry = {
        title = title,
        body = body,
        uid = uid,
        assets = assets,
    }

    local output_path = fetch_annotations and self.epub_notes_path or self.epub_clean_path
    if U.file_exists(output_path) then os.remove(output_path) end

    local meta = {
        book_id = book.bookId,
        title = book.title,
        author = book.author,
        standalone = true,
        chapter_uid = uid,
        variant = fetch_annotations and "notes" or "clean",
        stream = true,
        annotation_requested = fetch_annotations,
        chapters = catalog_map(self.chapters),
        chapter_count = 1,
        complete = true,
        generated_at = os.time(),
        annotation_fallback = tonumber(apply_stats and apply_stats.fallback or 0) or 0,
        annotation_official = tonumber(apply_stats and apply_stats.official or 0) or 0,
        annotation_official_verified = tonumber(apply_stats and apply_stats.official_verified or 0) or 0,
        annotation_official_roundtrip = tonumber(apply_stats and apply_stats.official_roundtrip or 0) or 0,
        annotation_official_failed = tonumber(apply_stats and apply_stats.official_failed or 0) or 0,
    }

    local build_ok, build_err = pcall(Epub.build, output_path, book, { chapter_entry }, css, assets, nil, meta)
    wipe_dir(self.work_dir)
    if not build_ok then return nil, tostring(build_err) end

    self.epub_path = output_path
    self.current_index = index
    self.current_uid = uid
    self.current_chapter = chapter
    self.last_annotation = annotation

    logger.info("[MiuRead][Stream] chapter built", "book=", book.bookId,
        "index=", tostring(index), "uid=", uid, "title=", title,
        "annotations=", tostring(fetch_annotations))
    return output_path, {
        index = index,
        uid = uid,
        title = title,
        annotation = annotation,
        annotation_stats = apply_stats,
        annotation_requested = fetch_annotations,
    }
end

function StreamReader:open(book, options)
    options = type(options) == "table" and options or {}
    if not self:init_book(book) then
        return nil, "无法获取书籍目录"
    end
    local pending = self.pending_percent
    local epub_path, meta = self:build_chapter(self.current_index or 1, {
        fetch_annotations = options.fetch_annotations == true,
    })
    if not epub_path then return nil, meta end
    if pending then meta.pending_percent = pending end
    return epub_path, meta
end

function StreamReader:load_chapter(index, options)
    options = type(options) == "table" and options or {}
    if not self.active then return nil, "流式会话未启动" end
    return self:build_chapter(index, {
        fetch_annotations = options.fetch_annotations == true,
    })
end

function StreamReader:load_chapter_with_annotations(index)
    if not self.active then return nil, "流式会话未启动" end
    return self:build_chapter(index, { fetch_annotations = true })
end

function StreamReader:next_index()
    local next_index = skip_forward(self.chapters, (tonumber(self.current_index) or 0) + 1)
    if next_index > #(self.chapters or {}) then return nil end
    return next_index
end

function StreamReader:prev_index()
    local index = (tonumber(self.current_index) or 0) - 1
    while index >= 1 and is_auto_skip(self.chapters[index]) do
        index = index - 1
    end
    if index < 1 then return nil end
    return index
end

function StreamReader:has_next()
    return self:next_index() ~= nil
end

function StreamReader:close()
    self.active = false
    if self.tmp_dir and lfs.attributes(self.tmp_dir, "mode") == "directory" then
        U.remove_tree(self.tmp_dir)
    end
    self.book = nil
    self.chapters = nil
    self.catalog_raw = nil
    self.progress = nil
    self.tmp_dir = nil
    self.epub_path = nil
    logger.info("[MiuRead][Stream] session closed")
end

return StreamReader
