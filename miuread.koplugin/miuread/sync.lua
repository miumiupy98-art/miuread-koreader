local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local FFIUtil = require("ffi/util")
local Json = require("miuread.json")
local ReadReportService = require("miuread.read_report_service")
local Protocol = require("miuread.protocol")
local ReadReportWorker = require("miuread.legacy_adapter_worker")
local U = require("miuread.util")

local Sync = {}
Sync.__index = Sync

local CONTEXT_MAX_AGE = 15 * 60

local function response_confirmation(value, depth, path, seen)
    if type(value) ~= "table" or (depth or 0) > 6 then return false end
    seen = seen or {}
    if seen[value] then return false end
    seen[value] = true
    path = path or "$"
    local succ = rawget(value, "succ")
    if succ == true or tonumber(succ) == 1 then return true, path .. ".succ", value end
    for _, key in ipairs({"data", "result", "payload", "response", "book", "reader"}) do
        local child = rawget(value, key)
        if type(child) == "table" then
            local ok, found_path, node = response_confirmation(child, (depth or 0) + 1, path .. "." .. key, seen)
            if ok then return true, found_path, node end
        end
    end
    for key, child in pairs(value) do
        if type(child) == "table" then
            local ok, found_path, node = response_confirmation(child, (depth or 0) + 1, path .. "." .. tostring(key), seen)
            if ok then return true, found_path, node end
        end
    end
    return false
end

local function accepted(value)
    return response_confirmation(value, 0, "$", {})
end

local function deep_field(value, names, depth, seen)
    if type(value) ~= "table" or (depth or 0) > 6 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    for _, name in ipairs(names) do
        local found = rawget(value, name)
        if found ~= nil and type(found) ~= "table" then return found end
    end
    for _, child in pairs(value) do
        if type(child) == "table" then
            local found = deep_field(child, names, (depth or 0) + 1, seen)
            if found ~= nil then return found end
        end
    end
end

local function response_synckey(value)
    return deep_field(value, {"synckey", "syncKey"}, 0, {})
end

local function response_summary(value, meta)
    local out = {}
    if type(meta) == "table" then
        if meta.code then out[#out + 1] = "HTTP=" .. tostring(meta.code) end
        if meta.length then out[#out + 1] = "bytes=" .. tostring(meta.length) end
        if meta.content_type then out[#out + 1] = "type=" .. tostring(meta.content_type) end
    end
    if type(value) ~= "table" then
        out[#out + 1] = "non-table-response"
        return table.concat(out, ", ")
    end
    local ok, path = accepted(value)
    out[#out + 1] = ok and ("succ=1@" .. tostring(path)) or "succ=not-found"
    local code = deep_field(value, {"errCode", "errcode", "code"}, 0, {})
    local message = deep_field(value, {"errMsg", "errmsg", "message", "msg"}, 0, {})
    if code ~= nil then out[#out + 1] = "code=" .. tostring(code) end
    if message ~= nil then out[#out + 1] = "message=" .. U.first_line(message, 140) end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    if #keys > 0 then out[#out + 1] = "keys=" .. table.concat(keys, "|") end
    return table.concat(out, ", ")
end

local function deep_progress(value, depth)
    if type(value) ~= "table" or (depth or 0) > 5 then return nil end
    local p = tonumber(value.progress or value.readingProgress or value.bookProgress or value.progressPercent)
    if p then
        if p <= 1 then p = p * 100 end
        return {
            percent = U.clamp(p, 0, 100),
            chapter_uid = value.chapterUid or value.chapterId or value.chapter_uid,
            chapter_idx = value.chapterIdx or value.chapterIndex or value.chapter_idx,
            offset = value.chapterOffset or value.chapterPos or value.offset,
            updated_at = value.updateTime or value.updatedAt,
            raw = value,
        }
    end
    for _, key in ipairs({"data", "bookProgress", "progressInfo", "reader", "result", "book"}) do
        local found = deep_progress(value[key], (depth or 0) + 1)
        if found then return found end
    end
end

local function context_from(state, fallback)
    fallback = fallback or {}
    if type(state) ~= "table" then state = {} end
    return {
        psvts = Protocol.optional(state.psvts) or Protocol.optional(fallback.psvts),
        pclts = Protocol.optional(state.pclts) or Protocol.optional(fallback.pclts),
        token = Protocol.optional(state.token) or Protocol.optional(fallback.token),
        reader_url = state.url or fallback.reader_url,
        app_id = fallback.app_id or Protocol.app_id(Protocol.USER_AGENT),
        chapters = fallback.chapters,
        context_updated_at = tonumber(fallback.context_updated_at or 0) or 0,
    }
end

local function map_position(chapters, ratio, fallback)
    chapters = type(chapters) == "table" and chapters or {}
    ratio = U.clamp(tonumber(ratio) or 0, 0, 1)
    fallback = fallback or {}
    if #chapters == 0 then
        return {
            progress = math.floor(ratio * 100 + .5),
            chapter_uid = fallback.chapter_uid or 0,
            chapter_index = tonumber(fallback.chapter_index or 0) or 0,
            offset = tonumber(fallback.offset or 0) or 0,
            summary = fallback.summary or "",
        }
    end
    local total = 0
    for _, ch in ipairs(chapters) do total = total + math.max(1, tonumber(ch.word_count or 0) or 0) end
    local target, acc = ratio * total, 0
    for index, ch in ipairs(chapters) do
        local words = math.max(1, tonumber(ch.word_count or 0) or 0)
        if target <= acc + words or index == #chapters then
            return {
                progress = math.floor(ratio * 100 + .5),
                chapter_uid = ch.uid or 0,
                chapter_index = tonumber(ch.index) or index,
                offset = math.max(0, math.floor(target - acc)),
                summary = ch.title or fallback.summary or "",
            }
        end
        acc = acc + words
    end
end

local function chapter_uid(chapter)
    return chapter and (chapter.chapterUid or chapter.uid or chapter.chapter_uid)
end

local function chapter_index(chapter, fallback)
    return tonumber(chapter and (chapter.chapterIdx or chapter.index or chapter.chapter_index or chapter.chapter_idx))
        or tonumber(fallback or 0) or 0
end

local function chapter_words(chapter)
    return math.max(1, tonumber(chapter and (chapter.wordCount or chapter.word_count) or 0) or 0)
end

local function map_standalone_position(chapters, source_uid, ratio, fallback)
    chapters = type(chapters) == "table" and chapters or {}
    source_uid = tostring(source_uid or "")
    ratio = U.clamp(tonumber(ratio) or 0, 0, 1)
    fallback = fallback or {}
    if source_uid == "" or #chapters == 0 then return nil end

    local total, before, selected = 0, 0, nil
    for _, chapter in ipairs(chapters) do
        local words = chapter_words(chapter)
        if not selected and tostring(chapter_uid(chapter) or "") == source_uid then
            selected = chapter
        elseif not selected then
            before = before + words
        end
        total = total + words
    end
    if not selected or total <= 0 then return nil end

    local words = chapter_words(selected)
    local offset = math.max(0, math.min(words, math.floor(words * ratio + .5)))
    local progress = U.clamp(((before + offset) / total) * 100, 0, 100)
    return {
        progress = progress,
        chapter_uid = chapter_uid(selected) or source_uid,
        chapter_index = chapter_index(selected, fallback.chapter_index),
        offset = offset,
        summary = selected.title or fallback.summary or "",
        standalone = true,
        safe = true,
        chapter_percent = math.floor(ratio * 100 + .5),
        chapter_word_count = words,
        total_word_count = total,
        words_before = before,
    }
end

function Sync:new(reader, api, store, host, async)
    local object = setmetatable({
        reader=reader, api=api, store=store, host=host, async=async,
        timer=nil, current=nil, last_activity=0, last_page=nil, suspended=false,
        busy=false, progress_hold=false, session_uploads=0, last_upload=0, last_attempt=0,
        last_error=nil, last_path=nil, last_stage=nil, last_response_summary=nil,
        last_response_path=nil, last_http_code=nil, last_http_length=nil,
        state="stopped", tick_count=0, last_report_clock=0, next_due=0,
        consecutive_failures=0, first_success_notified=false, failure_notified=false,
        verified_book_id=nil, verified_at=0, verified_local_percent=nil,
        verified_remote_percent=nil, verification_ttl=4 * 60 * 60,
        daemon=nil, daemon_poll=nil, daemon_status_stamp=nil,
        daemon_context=nil, daemon_last_persist=0, daemon_generation=0,
        control_write_task=nil,
        controller_token=tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999)),
    }, self)
    -- Start the lightweight service before a large EPUB is opened. Forking after
    -- CREngine loads a book duplicates far more memory on low-RAM Kindles.
    object:_ensure_daemon()
    return object
end

function Sync:record()
    if not self.host.ui or not self.host.ui.document then return nil end
    local document = self.host.ui.document
    local path = document.file or (document.getFilePath and document:getFilePath())
    local book, record, variant = self.store:file_record(path)
    if book then return {book=book, record=record, variant=variant, path=path} end
end

function Sync:local_ratio()
    local ui = self.host.ui
    if not ui or not ui.document then return nil end
    local footer = ui.view and ui.view.footer
    local value = footer and tonumber(footer.percent_finished)
    if value then return value > 1 and U.clamp(value / 100, 0, 1) or U.clamp(value, 0, 1) end
    local document = ui.document
    if document.getCurrentPage and document.getPageCount then
        local a, page = pcall(document.getCurrentPage, document)
        local b, total = pcall(document.getPageCount, document)
        if a and b and tonumber(total) and tonumber(total) > 0 then return U.clamp(tonumber(page) / tonumber(total), 0, 1) end
    end
    if ui.rolling and document.info then
        local pos, height = tonumber(ui.rolling.current_pos), tonumber(document.info.doc_height)
        if pos and height and height > 0 then return U.clamp(pos / height, 0, 1) end
    end
end

function Sync:position(record, ratio, chapters)
    ratio = ratio or self:local_ratio() or 0
    local map = chapters or (record.record and record.record.chapter_map) or record.book.catalog or {}
    return map_position(map, ratio, {
        chapter_uid = record.record and record.record.chapter_uid or 0,
        summary = record.book.title,
    })
end

function Sync:_decorate_legacy_context(context, record)
    context = context or {}
    local standalone_uid = record and record.record and record.record.chapter_uid
    if standalone_uid ~= nil and tostring(standalone_uid) ~= "" then
        local local_map = record.record.chapter_map or {}
        local local_chapter = local_map[1] or {}
        context.source_is_standalone = true
        context.source_chapter_uid = tostring(standalone_uid)
        context.source_chapter_index = chapter_index(local_chapter, 0)
        context.source_chapter_word_count = tonumber(local_chapter.word_count or local_chapter.wordCount or 0) or 0
        context.source_chapter_title = local_chapter.title or record.book.title
    else
        context.source_is_standalone = nil
        context.source_chapter_uid = nil
        context.source_chapter_index = nil
        context.source_chapter_word_count = nil
        context.source_chapter_title = nil
    end
    return context
end

function Sync:local_position(ratio)
    local record = self:record()
    if not record then return nil end
    ratio = ratio or self:local_ratio() or 0
    local standalone_uid = record.record and record.record.chapter_uid
    if standalone_uid ~= nil and tostring(standalone_uid) ~= "" then
        local session = self.store:session(record.book.book_id) or {}
        local context = self.daemon_context
            or (type(session.legacy_report_context) == "table" and session.legacy_report_context)
            or {}
        local position = context.catalog_complete == true and map_standalone_position(context.chapters, standalone_uid, ratio, {
            chapter_index = record.record and record.record.chapter_map
                and record.record.chapter_map[1] and record.record.chapter_map[1].index,
            summary = record.book.title,
        }) or nil
        if position then return position end
        return {
            progress = nil,
            chapter_uid = tostring(standalone_uid),
            standalone = true,
            safe = false,
            chapter_percent = math.floor(U.clamp(ratio, 0, 1) * 100 + .5),
            summary = record.book.title,
        }
    end
    local position = self:position(record, ratio)
    position.safe = true
    position.standalone = false
    position.chapter_percent = math.floor(U.clamp(ratio, 0, 1) * 100 + .5)
    return position
end

function Sync:jump_remote(remote)
    remote = remote or {}
    local record = self:record()
    if not record then return false, "未识别到当前觅阅书籍" end
    local standalone_uid = record.record and record.record.chapter_uid
    if standalone_uid == nil or tostring(standalone_uid) == "" then
        return self:jump(remote.percent), nil
    end

    local remote_uid = remote.chapter_uid
    if remote_uid == nil or tostring(remote_uid) ~= tostring(standalone_uid) then
        return false, "云端位置不在当前下载章节中"
    end

    local session = self.store:session(record.book.book_id) or {}
    local context = self.daemon_context
        or (type(session.legacy_report_context) == "table" and session.legacy_report_context)
        or {}
    if context.catalog_complete ~= true then return false, "完整目录尚未准备好" end
    local chapters = type(context.chapters) == "table" and context.chapters or {}
    local selected, before, total
    before, total = 0, 0
    for _, chapter in ipairs(chapters) do
        local words = chapter_words(chapter)
        if not selected and tostring(chapter_uid(chapter) or "") == tostring(standalone_uid) then
            selected = chapter
        elseif not selected then
            before = before + words
        end
        total = total + words
    end
    if not selected then return false, "暂时无法换算当前章节位置" end

    local words = chapter_words(selected)
    local local_ratio
    if tonumber(remote.offset) then
        local_ratio = tonumber(remote.offset) / words
    elseif tonumber(remote.percent) and total > 0 then
        local target = U.clamp(tonumber(remote.percent), 0, 100) / 100 * total
        local_ratio = (target - before) / words
    end
    if local_ratio == nil then return false, "云端位置缺少章节内偏移" end
    local_ratio = U.clamp(local_ratio, 0, 1)
    return self:jump(local_ratio * 100), nil
end

function Sync:is_verified(book_id)
    book_id = tostring(book_id or "")
    if book_id == "" or tostring(self.verified_book_id or "") ~= book_id then return false end
    local age = os.time() - (tonumber(self.verified_at or 0) or 0)
    return age >= 0 and age <= (tonumber(self.verification_ttl) or 14400)
end

function Sync:is_current_verified()
    local record = self:record()
    return record and self:is_verified(record.book.book_id) or false
end

function Sync:clear_verified(reason)
    local old_book = self.verified_book_id
    if not old_book then
        local record = self:record()
        old_book = record and record.book and record.book.book_id or nil
    end
    self.verified_book_id = nil
    self.verified_at = 0
    self.verified_local_percent = nil
    self.verified_remote_percent = nil
    if old_book then
        self.store:save_session(tostring(old_book), {
            remote_verified=false, verified_at=nil, verified_reason=tostring(reason or "cleared"),
            verified_local_percent=nil, verified_remote_percent=nil,
        })
    end
    logger.info("[MiuRead][Sync] progress verification cleared", tostring(reason or "cleared"))
end

function Sync:begin_progress_sync(reason)
    -- Cloud-position checks are informational and must never pause the 30-second
    -- reading-time service.
    self.progress_hold = false
    self.state = "fetching_remote"
    self.last_stage = reason or "读取云端进度"
    return true
end

function Sync:end_progress_sync(reason)
    self.progress_hold = false
    self.state = self.store:preferences().sync.time_enabled and "waiting" or "stopped"
    self.last_stage = reason or "阅读进度检查完成"
    self.last_report_clock = os.time()
end

function Sync:remote(book_id, callback)
    self.state = "fetching_remote"
    self.last_stage = "读取云端进度"
    local ok, err = self.async:run("remote_progress", function() return self.api:progress(book_id) end, function(result)
        self.store:reload()
        self.state = self.progress_hold and "progress_sync" or "waiting"
        if not result.ok then
            self.last_error = result.error
            logger.warn("[MiuRead][Sync] remote progress failed", tostring(result.error))
            callback(nil, result.error)
            return
        end
        local remote = deep_progress(result.value)
        if not remote then self.last_error = "remote progress unavailable"; callback(nil, self.last_error); return end
        self.store:save_session(book_id, {remote=remote, remote_checked_at=os.time()})
        logger.info("[MiuRead][Sync] remote progress", "book=", tostring(book_id), "percent=", tostring(remote.percent))
        callback(remote)
    end, 35)
    if not ok then callback(nil, err) end
end

function Sync:mark_verified(book_id, reason, local_percent, remote_percent)
    book_id = tostring(book_id or "")
    if book_id == "" then return false end
    self.verified_book_id = book_id
    self.verified_at = os.time()
    self.verified_local_percent = tonumber(local_percent)
    self.verified_remote_percent = tonumber(remote_percent)
    self.store:save_session(book_id, {
        remote_verified=true, verified_at=self.verified_at,
        verified_reason=tostring(reason or "confirmed"),
        verified_local_percent=self.verified_local_percent,
        verified_remote_percent=self.verified_remote_percent,
    })
    logger.info("[MiuRead][Sync] cloud progress verified",
        "book=", book_id, "reason=", tostring(reason or "confirmed"),
        "local=", tostring(self.verified_local_percent or "-"),
        "remote=", tostring(self.verified_remote_percent or "-"))
    return true
end

function Sync:_prepare_context(record, ratio, session, force)
    local book_id = record.book.book_id
    local saved = type(session.report_context) == "table" and session.report_context or session
    local ctx = context_from(nil, saved)
    local base_map = (record.record and record.record.chapter_map) or record.book.catalog or saved.chapters or {}
    ctx.chapters = (#(saved.chapters or {}) > 0 and saved.chapters) or base_map
    local position = map_position(ctx.chapters, ratio, {
        chapter_uid = record.record and record.record.chapter_uid or 0,
        summary = record.book.title,
    })
    local now = os.time()
    local stale = now - (tonumber(ctx.context_updated_at) or 0) >= CONTEXT_MAX_AGE
    if force or stale or not Protocol.optional(ctx.psvts) then
        local ok_base, state = pcall(self.reader.state, self.reader, book_id, nil)
        if not ok_base then state = self.reader:state(book_id, position.chapter_uid) end
        ctx = context_from(state, ctx)
        ctx.chapters = ctx.chapters or base_map
        ctx.reader_url = state.url or Protocol.reader_url(book_id)
        ctx.context_updated_at = now
    end
    return ctx, position
end

function Sync:upload(elapsed, callback, options)
    options = options or {}
    local record = self:record()
    if not record then if callback then callback(false, "未识别到 MiuRead 生成的当前书籍") end; return false end
    -- Reading-time upload is independent from cloud progress synchronization.
    self.progress_hold = false
    if self.busy then if callback then callback(false, "同步任务忙") end; return false end

    local book_id = tostring(record.book.book_id)
    local session = self.store:session(book_id) or {}
    local auth = self.store:auth()
    local ratio = self:local_ratio() or 0
    local chapters = (record.record and record.record.chapter_map) or record.book.catalog or {}
    -- Keep the old worker's own field names and cached context isolated from
    -- MiuRead's newer protocol model. On first use it refreshes the reader page,
    -- catalog and reporting context exactly as 0.3.6.7 did.
    local legacy_book = U.copy(type(session.legacy_report_context) == "table"
        and session.legacy_report_context or {})
    legacy_book.book_id = book_id
    legacy_book.title = record.book.title
    self:_decorate_legacy_context(legacy_book, record)

    self.busy, self.state, self.last_attempt = true, "uploading", os.time()
    self.last_stage = "调用 0.3.6.7 原版阅读时长链路"
    local ok, err = self.async:run("legacy_read_report", function()
        return ReadReportWorker.run{
            book_id = book_id,
            book_title = record.book.title,
            book = legacy_book,
            progress_ratio = ratio,
            elapsed_seconds = elapsed or 0,
            cookies = auth.cookies or {},
            api_key = auth.api_key or "",
            wr_ticket = auth.wr_ticket or "",
            wr_wrpa = auth.wr_wrpa or "",
            allow_renewal = false,
        }
    end, function(result)
        self.busy = false
        self.state = "waiting"
        self.store:reload()
        if not result.ok or type(result.value) ~= "table" then
            self.consecutive_failures = self.consecutive_failures + 1
            self.last_error = result.error or "阅读时间工作器无结果"
            self.last_stage = "工作器失败"
            logger.warn("[MiuRead][ReadReport] worker failed", tostring(self.last_error))
            self:_notify_failure()
            if callback then callback(false, self.last_error) end
            return
        end

        local value = result.value
        local legacy_context = value.legacy_context or legacy_book
        local position = value.position or self:position(record, ratio, chapters)
        if value.cookies_changed and type(value.cookies) == "table" then
            local latest_auth = self.store:auth()
            latest_auth.cookies = value.cookies
            if value.wr_ticket_changed then latest_auth.wr_ticket = value.wr_ticket end
            if value.wr_wrpa_changed then latest_auth.wr_wrpa = value.wr_wrpa end
            self.store:save_auth(latest_auth)
        end
        local attempts_count = #(value.attempts or {})
        local public = value.payload_public or {}
        self.last_path = value.path
        self.last_response_summary = value.response_summary or value.error
        self.last_http_code = value.meta and value.meta.code or nil
        self.last_http_length = value.meta and value.meta.length or nil
        self.last_stage = value.accepted and "0.3.6.7 原版链路已确认"
            or (tostring(value.path or ""):find("context", 1, true) and "0.3.6.7 原版上下文失败"
            or "0.3.6.7 原版链路被服务端拒绝")

        self.store:save_session(book_id, {
            legacy_report_context=legacy_context,
            last_attempt=self.last_attempt,
            last_path=value.path,
            last_attempts=attempts_count,
            last_stage=self.last_stage,
            last_response_summary=self.last_response_summary,
            last_http_code=self.last_http_code,
            last_http_length=self.last_http_length,
            last_payload_public=public,
        })

        if not value.accepted then
            self.consecutive_failures = self.consecutive_failures + 1
            self.last_error = "微信读书未确认接收阅读时长（" .. tostring(value.error or "unknown") .. "）"
            self.store:save_session(book_id, {
                last_error=self.last_error,
                consecutive_failures=self.consecutive_failures,
                last_response_summary=self.last_response_summary,
                last_http_code=self.last_http_code,
                last_http_length=self.last_http_length,
                last_payload_public=public,
            })
            logger.warn("[MiuRead][ReadReport] rejected", self.last_error,
                "attempts=", tostring(attempts_count),
                "ci=", tostring(public.ci or "-"),
                "co=", tostring(public.co or "-"),
                "pr=", tostring(public.pr or "-"),
                "token_source=", tostring(public.token_source or "-"),
                "pc_source=", tostring(public.pc_source or "-"),
                "fields_complete=", tostring(public.payload_fields_complete == true))
            self:_notify_failure()
            if callback then callback(false, self.last_error, position, value) end
            return
        end

        local response = value.response or {}
        self.session_uploads = self.session_uploads + 1
        self.last_upload = os.time()
        self.last_error = nil
        self.consecutive_failures = 0
        self.failure_notified = false
        self.store:save_session(book_id, {
            local_percent=position.progress,
            last_upload=self.last_upload,
            pending=nil,
            synckey=response_synckey(response) or legacy_context.synckey or session.synckey,
            last_error=false,
            consecutive_failures=0,
            last_path=value.path,
            last_attempts=attempts_count,
            last_response_summary=self.last_response_summary,
            last_http_code=self.last_http_code,
            last_http_length=self.last_http_length,
            last_payload_public=public,
        })
        logger.info("[MiuRead][ReadReport] success", "count=", tostring(self.session_uploads),
            "book=", tostring(book_id), "elapsed=", tostring(elapsed or 0),
            "progress=", tostring(position.progress), "path=", tostring(value.path),
            "attempts=", tostring(attempts_count))
        if not self.first_success_notified and not options.silent then
            self.first_success_notified = true
            if self.host.on_read_report_success then pcall(self.host.on_read_report_success, self.host, value.path) end
        end
        if callback then callback(true, response, position, value) end
    end, 95)

    if not ok then
        self.busy = false
        self.last_error = err
        if callback then callback(false, err) end
        return false
    end
    return true
end

function Sync:_notify_failure()
    if self.consecutive_failures >= 2 and not self.failure_notified then
        self.failure_notified = true
        if self.host.on_read_report_failure then pcall(self.host.on_read_report_failure, self.host, self.last_error) end
    end
end

function Sync:test_upload(callback)
    self.failure_notified = false
    local restart = self.daemon ~= nil
    if restart then self:_stop_daemon("manual_test", true) end
    return self:upload(30, function(...)
        local args = {...}
        if restart and self.store:preferences().sync.time_enabled and not self.suspended then
            self:start("manual_test_finished")
        end
        if callback then callback(unpack(args)) end
    end, {silent=true, test=true})
end

function Sync:compare(local_percent, remote)
    if not remote then return "unknown" end
    local delta = (tonumber(remote.percent) or 0) - (tonumber(local_percent) or 0)
    local threshold = tonumber(self.store:preferences().sync.threshold) or 2
    if math.abs(delta) <= threshold then return "same" end
    return delta > 0 and "remote_ahead" or "local_ahead"
end

function Sync:jump(percent)
    percent = math.floor(U.clamp(percent, 0, 100) + .5)
    local ui = self.host.ui
    if not ui or not ui.document then return false end
    return pcall(function()
        if ui.rolling and ui.rolling.onGotoPercent then ui.rolling:onGotoPercent(percent)
        else ui:handleEvent(Event:new("GotoPercent", percent)) end
    end)
end

local function daemon_stamp(status)
    if type(status) ~= "table" then return nil end
    return table.concat({
        tostring(status.generation or 0),
        tostring(status.seq or 0),
        tostring(status.state or ""),
        tostring(status.completed_at or status.attempted_at or status.written_at or 0),
    }, ":")
end

local process_ffi
local function process_helpers()
    if process_ffi ~= nil then return process_ffi or nil end
    local ok, ffi = pcall(require, "ffi")
    if not ok then process_ffi = false; return nil end
    pcall(function()
        ffi.cdef[[
            int getpid(void);
            int kill(int pid, int sig);
        ]]
    end)
    process_ffi = ffi
    return ffi
end

local function current_pid()
    local ffi = process_helpers()
    if not ffi then return nil end
    local ok, pid = pcall(function() return tonumber(ffi.C.getpid()) end)
    return ok and pid or nil
end

local function process_alive(pid)
    pid = tonumber(pid)
    if not pid or pid <= 1 then return false end
    local ffi = process_helpers()
    if not ffi then return true end
    local ok, result = pcall(function() return ffi.C.kill(pid, 0) end)
    return ok and result == 0
end

local function read_json_file(path)
    local raw = U.read_file(path, true)
    if not raw then return nil end
    local ok, value = pcall(Json.decode, raw)
    if ok and type(value) == "table" then return value end
end

local function remove_lock_dir(path)
    local ok, lfs = pcall(require, "lfs")
    if ok and lfs and type(lfs.rmdir) == "function" then pcall(lfs.rmdir, path) end
end

local function acquire_lock_dir(path)
    local ok, lfs = pcall(require, "lfs")
    if not ok or not lfs or type(lfs.mkdir) ~= "function" then return true end
    local made = lfs.mkdir(path)
    return made == true
end

function Sync:_daemon_paths()
    -- One fixed service per KOReader process. A random path allowed every plugin
    -- instance to start its own 30-second uploader.
    local base = self.store.temp_dir .. "/readtime-service"
    return {
        job = base .. ".job.json",
        control = base .. ".control.json",
        status = base .. ".status.json",
        context = base .. ".context.json",
        stop = base .. ".stop",
        owner = base .. ".owner.json",
        lock = base .. ".lock",
    }
end

function Sync:_cleanup_daemon_files(daemon)
    if not daemon or not daemon.paths then return end
    local paths = daemon.paths
    local owner = read_json_file(paths.owner)
    if not owner or not process_alive(owner.pid) then
        os.remove(paths.job)
        os.remove(paths.control)
        os.remove(paths.status)
        os.remove(paths.context)
        os.remove(paths.stop)
        os.remove(paths.owner)
        remove_lock_dir(paths.lock)
    end
end

function Sync:_attach_existing_daemon(paths, owner)
    if type(owner) ~= "table" or not process_alive(owner.pid) then return false end
    local control = read_json_file(paths.control) or {}
    self.daemon = {
        pid=tonumber(owner.pid), paths=paths, active=false,
        generation=tonumber(control.generation or 0) or 0,
        book_id=nil, interval=30, reason="reused", is_child=false,
    }
    self.daemon_status_stamp = nil
    self:_schedule_daemon_poll(10)
    logger.info("[MiuRead][ReadReport] lightweight service reused", "pid=", tostring(owner.pid))
    return true
end

function Sync:_ensure_daemon()
    if self.daemon and process_alive(self.daemon.pid) then return true end
    if self.daemon then self:_cleanup_daemon_files(self.daemon); self.daemon=nil end
    if type(FFIUtil.runInSubProcess) ~= "function" then
        self.last_error = "当前 KOReader 不支持后台阅读时间服务"
        return false, self.last_error
    end

    local paths = self:_daemon_paths()
    local owner = read_json_file(paths.owner)
    if self:_attach_existing_daemon(paths, owner) then return true end

    -- Remove stale ownership before acquiring the lifetime lock.
    os.remove(paths.owner)
    remove_lock_dir(paths.lock)
    if not acquire_lock_dir(paths.lock) then
        owner = read_json_file(paths.owner)
        if self:_attach_existing_daemon(paths, owner) then return true end
        self.last_error = "后台阅读时间服务正在启动"
        return false, self.last_error
    end

    U.atomic_write(paths.control, Json.encode({active=false,generation=0,controller_token="",updated_at=os.time()}), true)
    os.remove(paths.stop)
    local service_job = {
        parent_pid = current_pid(),
        poll_interval = 1,
        job_path = paths.job,
        control_path = paths.control,
        status_path = paths.status,
        context_path = paths.context,
        stop_path = paths.stop,
        owner_path = paths.owner,
        lock_path = paths.lock,
    }
    local child = function() return ReadReportService.run(service_job) end
    local ok, pid, err = pcall(FFIUtil.runInSubProcess, child, false, false)
    if not ok or not pid then
        os.remove(paths.owner)
        remove_lock_dir(paths.lock)
        self.last_error = tostring(err or pid or "无法启动后台阅读时间服务")
        return false, self.last_error
    end
    U.atomic_write(paths.owner, Json.encode({pid=pid,parent_pid=current_pid(),started_at=os.time()}), true)
    self.daemon = {
        pid=pid, paths=paths, active=false, generation=0,
        book_id=nil, interval=30, reason="prestarted", is_child=true,
    }
    self.daemon_status_stamp = nil
    self:_schedule_daemon_poll(10)
    logger.info("[MiuRead][ReadReport] lightweight service started", "pid=", tostring(pid))
    return true
end

function Sync:_write_daemon_control(active, immediate)
    local daemon = self.daemon
    if not daemon and not self:_ensure_daemon() then return false end
    daemon = self.daemon
    if not daemon then return false end

    local function write_now()
        self.control_write_task = nil
        local d = self.daemon
        if not d then return end
        local existing = read_json_file(d.paths.control) or {}
        local existing_generation = tonumber(existing.generation or 0) or 0
        local own_generation = tonumber(d.generation or 0) or 0
        -- An older plugin instance must never pause or overwrite a newer reader.
        if existing_generation > own_generation then return end
        if existing_generation == own_generation
            and tostring(existing.controller_token or "") ~= ""
            and tostring(existing.controller_token or "") ~= tostring(self.controller_token)
        then return end
        local control = {
            active = active ~= false and d.active == true,
            generation = own_generation,
            controller_token = self.controller_token,
            progress_ratio = self:local_ratio() or 0,
            last_activity = tonumber(self.last_activity) or os.time(),
            updated_at = os.time(),
        }
        U.atomic_write(d.paths.control, Json.encode(control), true)
    end

    if immediate then
        if self.control_write_task then UIManager:unschedule(self.control_write_task); self.control_write_task=nil end
        write_now()
        return true
    end
    if self.control_write_task then return true end
    local task
    task = function()
        if self.control_write_task ~= task then return end
        write_now()
    end
    self.control_write_task = task
    UIManager:scheduleIn(1.25, task)
    return true
end

function Sync:_persist_daemon_session(force)
    local daemon = self.daemon
    local book_id = daemon and daemon.book_id
    if not book_id then return end
    local now = os.time()
    if not force and now - (tonumber(self.daemon_last_persist) or 0) < 300 then return end
    self.daemon_last_persist = now
    self.store:save_session(book_id, {
        legacy_report_context = self.daemon_context,
        last_attempt = self.last_attempt,
        last_upload = self.last_upload,
        last_path = self.last_path,
        last_stage = self.last_stage,
        last_response_summary = self.last_response_summary,
        last_error = self.last_error or false,
        consecutive_failures = self.consecutive_failures,
    })
end

function Sync:_load_daemon_context()
    local daemon = self.daemon
    if not daemon then return end
    local context_raw = U.read_file(daemon.paths.context, true)
    if not context_raw then return end
    local context_ok, context = pcall(Json.decode, context_raw)
    if context_ok and type(context) == "table" then self.daemon_context = U.copy(context) end
end

function Sync:_import_daemon_status(force)
    local daemon = self.daemon
    if not daemon then return end
    local raw = U.read_file(daemon.paths.status, true)
    if not raw then return end
    local ok, status = pcall(Json.decode, raw)
    if not ok or type(status) ~= "table" then return end
    if daemon.active and tonumber(status.generation or -1) ~= tonumber(daemon.generation or 0) then return end

    local stamp = daemon_stamp(status)
    if stamp and stamp == self.daemon_status_stamp then
        if force then self:_load_daemon_context(); self:_persist_daemon_session(true) end
        return
    end
    self.daemon_status_stamp = stamp

    if status.context_changed or force then self:_load_daemon_context() end
    self.next_due = tonumber(status.next_due) or self.next_due or 0
    if status.state == "service_waiting" or status.state == "inactive" then
        if not daemon.active then self.state = "stopped" end
        return
    elseif status.state == "waiting" and status.accepted == nil then
        if daemon.active then self.state = "waiting" end
        return
    elseif status.state == "service_stopped" then
        self.state = "stopped"
        return
    end

    if not daemon.active then return end
    self.last_attempt = tonumber(status.attempted_at) or self.last_attempt
    self.last_path = status.path or self.last_path
    self.last_response_summary = status.response_summary or status.error or self.last_response_summary
    self.last_stage = status.accepted and "0.3.6.7 原版链路已确认" or "后台上传失败"

    if status.cookies_changed and type(status.cookies) == "table" then
        local auth = self.store:auth()
        auth.cookies = status.cookies
        if status.wr_ticket_changed then auth.wr_ticket = status.wr_ticket or "" end
        if status.wr_wrpa_changed then auth.wr_wrpa = status.wr_wrpa or "" end
        self.store:save_auth(auth)
    end

    if status.accepted then
        self.state = "waiting"
        self.session_uploads = self.session_uploads + 1
        self.last_upload = tonumber(status.completed_at) or os.time()
        self.last_error = nil
        self.consecutive_failures = 0
        self.failure_notified = false
        -- Clear an older persisted error as soon as the service succeeds again.
        -- This is a one-time write after recovery, not a 30-second log write.
        if not self.first_success_notified then
            self.store:save_session(tostring(daemon.book_id), {
                last_error=false,
                consecutive_failures=0,
                last_upload=self.last_upload,
            })
        end
        -- Avoid a synchronous log write every 30 seconds on e-ink devices.
        if not self.first_success_notified then
            logger.info("[MiuRead][ReadReport] service first success",
                "book=", tostring(daemon.book_id), "path=", tostring(status.path or "-"))
            self.first_success_notified = true
            if self.host.on_read_report_success then
                pcall(self.host.on_read_report_success, self.host, status.path)
            end
        end
        self:_persist_daemon_session(force)
    elseif status.error then
        self.state = "waiting"
        self.consecutive_failures = self.consecutive_failures + 1
        self.last_error = tostring(status.error)
        logger.warn("[MiuRead][ReadReport] service rejected", self.last_error)
        self:_notify_failure()
        if force or self.consecutive_failures >= 2 then self:_persist_daemon_session(force) end
    end
end

function Sync:_schedule_daemon_poll(delay)
    if self.daemon_poll or not self.daemon then return end
    local task
    task = function()
        if self.daemon_poll ~= task then return end
        self.daemon_poll = nil
        local daemon = self.daemon
        if not daemon then return end
        self:_import_daemon_status(false)
        if not process_alive(daemon.pid) then
            local was_active = daemon.active
            logger.warn("[MiuRead][ReadReport] lightweight service exited unexpectedly")
            self:_cleanup_daemon_files(daemon)
            self.daemon = nil
            self.state = "stopped"
            if was_active and self.store:preferences().sync.time_enabled and not self.suspended and self:record() then
                UIManager:scheduleIn(10, function() self:start("service_restart") end)
            else
                UIManager:scheduleIn(10, function() self:_ensure_daemon() end)
            end
            return
        end
        self:_schedule_daemon_poll(10)
    end
    self.daemon_poll = task
    UIManager:scheduleIn(delay or 10, task)
end

function Sync:_start_daemon(reason)
    local record = self:record()
    if not record then
        self.state = "stopped"
        return false, "未识别到 MiuRead 书籍"
    end
    local ok, err = self:_ensure_daemon()
    if not ok then self.state="stopped"; return false, err end

    local daemon = self.daemon
    local book_id = tostring(record.book.book_id)
    local prefs = self.store:preferences().sync
    local interval = math.max(10, tonumber(prefs.interval) or 30)
    local session = self.store:session(book_id) or {}
    local auth = self.store:auth()
    local legacy_book = U.copy(self.daemon_context
        or (type(session.legacy_report_context) == "table" and session.legacy_report_context)
        or {})
    legacy_book.book_id = book_id
    legacy_book.title = record.book.title
    self:_decorate_legacy_context(legacy_book, record)

    local existing_control = read_json_file(daemon.paths.control) or {}
    local existing_status = read_json_file(daemon.paths.status) or {}
    self.daemon_generation = math.max(
        tonumber(self.daemon_generation or 0) or 0,
        tonumber(existing_control.generation or 0) or 0,
        tonumber(existing_status.generation or 0) or 0
    ) + 1
    daemon.generation = self.daemon_generation
    daemon.active = true
    daemon.book_id = book_id
    daemon.interval = interval
    daemon.reason = reason

    local job = {
        generation = daemon.generation,
        controller_token = self.controller_token,
        book_id = book_id,
        book_title = record.book.title,
        book = legacy_book,
        auth = {
            cookies = auth.cookies or {},
            api_key = auth.api_key or "",
            wr_ticket = auth.wr_ticket or "",
            wr_wrpa = auth.wr_wrpa or "",
        },
        interval = interval,
        idle_timeout = tonumber(prefs.idle_timeout) or 600,
    }
    U.atomic_write(daemon.paths.job, Json.encode(job), true)
    self.daemon_status_stamp = nil
    self.daemon_last_persist = os.time()
    self.state = "waiting"
    self.next_due = os.time() + interval
    self.last_stage = "轻量后台服务运行中，每30秒上传一次"
    self:_write_daemon_control(true, true)
    self:_schedule_daemon_poll(5)
    logger.info("[MiuRead][ReadReport] service activated",
        "pid=", tostring(daemon.pid), "book=", book_id,
        "interval=", tostring(interval), "reason=", tostring(reason or "start"))
    return true
end

function Sync:_stop_daemon(reason, persist)
    local daemon = self.daemon
    if self.control_write_task then UIManager:unschedule(self.control_write_task); self.control_write_task=nil end
    if not daemon then return end
    self:_import_daemon_status(true)
    if persist ~= false then self:_persist_daemon_session(true) end
    daemon.active = false
    self:_write_daemon_control(false, true)
    daemon.book_id = nil
    self.next_due = 0
end

-- Kept for compatibility with older callers. Automatic reporting now uses one
-- long-lived subprocess instead of forking a fresh worker every 30 seconds.
function Sync:_schedule(_delay)
    if self.store:preferences().sync.time_enabled and not self.suspended then
        self:_start_daemon("schedule_compat")
    end
end

function Sync:_tick()
    self:_write_daemon_control(true)
end

function Sync:start(reason)
    self.last_activity = os.time()
    local enabled = self.store:preferences().sync.time_enabled
    self.progress_hold = false
    self.state = enabled and "waiting" or "stopped"
    self.last_stage = enabled and "准备后台阅读时间工作器" or "阅读时间同步已关闭"
    logger.info("[MiuRead][ReadReport] start requested", "reason=", tostring(reason),
        "enabled=", tostring(enabled), "mode=long_lived_worker")
    if enabled and not self.suspended then return self:_start_daemon(reason) end
    return enabled
end

function Sync:stop(reason)
    self:_stop_daemon(reason, true)
    self.async:cancel(reason)
    self.busy = false
    self.progress_hold = false
    self.state = "stopped"
    logger.info("[MiuRead][ReadReport] stopped", "reason=", tostring(reason))
end

function Sync:on_reader_ready()
    self.current = self:record()
    self.suspended = false
    self.session_uploads = 0
    self.last_upload = 0
    self.first_success_notified = false
    self.failure_notified = false
    self.consecutive_failures = 0
    self.last_error = nil
    self.progress_hold = false
    self.daemon_context = nil
    logger.info("[MiuRead][Sync] reader record", self.current and tostring(self.current.book.book_id) or "not_found")
    self:start("reader_ready")
end

function Sync:on_page(page)
    if page and page ~= self.last_page then
        self.last_page = page
        self.last_activity = os.time()
        self:_write_daemon_control(true)
    end
end

function Sync:on_suspend()
    self.suspended = true
    local r = self:record()
    if r then
        local position = self:local_position()
        self.store:save_session(r.book.book_id, {
            pending={
                percent=position and position.progress or nil,
                chapter_percent=position and position.chapter_percent or math.floor((self:local_ratio() or 0) * 100 + .5),
                chapter_uid=position and position.chapter_uid or nil,
                saved_at=os.time(), reason="suspend",
            }
        })
        self.store:mark_last_read(r.book.book_id,r.path,position and position.progress or nil)
    end
    self:stop("suspend")
end

function Sync:on_resume(_slept)
    self.suspended = false
    self:start("resume")
end

function Sync:on_close()
    local r = self:record()
    if r then
        local position = self:local_position()
        self.store:save_session(r.book.book_id, {
            pending={
                percent=position and position.progress or nil,
                chapter_percent=position and position.chapter_percent or math.floor((self:local_ratio() or 0) * 100 + .5),
                chapter_uid=position and position.chapter_uid or nil,
                saved_at=os.time(), reason="close",
            }
        })
        self.store:mark_last_read(r.book.book_id,r.path,position and position.progress or nil)
    end
    self:stop("close")
    self.current = nil
end

function Sync:status_label()
    if not self.store:preferences().sync.time_enabled then return "已关闭" end
    local labels = {
        stopped="未运行", waiting="运行中", uploading="正在上传", fetching_remote="读取云进度",
        progress_sync="检查云端位置", verification_required="等待位置选择", paused="已暂停", idle="空闲暂停",
    }
    if self.last_error then return "上传失败" end
    if self.busy or self.state == "uploading" then return "正在上传" end
    return labels[self.state] or tostring(self.state)
end

function Sync:status()
    self:_import_daemon_status(false)
    local r = self:record()
    local session = r and self.store:session(r.book.book_id) or {}
    local local_position = self:local_position()
    return {
        record=r,
        local_percent=local_position and local_position.progress
            and math.floor(local_position.progress + .5) or nil,
        local_chapter_percent=local_position and local_position.chapter_percent or nil,
        local_position_safe=local_position and local_position.safe == true or false,
        remote=session and session.remote, remote_checked_at=session and session.remote_checked_at,
        verified=self:is_current_verified(), verified_at=self.verified_at,
        verified_local_percent=self.verified_local_percent,
        verified_remote_percent=self.verified_remote_percent,
        state=self.state, state_label=self:status_label(),
        progress_hold=self.progress_hold,time_enabled=self.store:preferences().sync.time_enabled,
        session_uploads=self.session_uploads,last_upload=self.last_upload or (session and session.last_upload) or 0,
        last_attempt=self.last_attempt or (session and session.last_attempt) or 0,
        last_error=(self.last_error~=nil and self.last_error or (session and session.last_error)),
        last_path=self.last_path or (session and session.last_path),
        last_stage=self.last_stage or (session and session.last_stage),
        last_response_summary=self.last_response_summary or (session and session.last_response_summary),
        last_response_path=self.last_response_path or (session and session.last_response_path),
        last_http_code=self.last_http_code or (session and session.last_http_code),
        last_http_length=self.last_http_length or (session and session.last_http_length),
        last_payload_public=session and session.last_payload_public,
        next_due=self.next_due,consecutive_failures=self.consecutive_failures or (session and session.consecutive_failures) or 0,
        tick_count=self.tick_count,
        progress_enabled=self.store:preferences().sync.progress_enabled~=false,
        progress_state=session and session.progress_sync_state,
        progress_message=session and session.progress_sync_message,
        service_pid=self.daemon and self.daemon.pid or nil,
    }
end

Sync._accepted = accepted
Sync._response_summary = response_summary
Sync._response_synckey = response_synckey

return Sync
