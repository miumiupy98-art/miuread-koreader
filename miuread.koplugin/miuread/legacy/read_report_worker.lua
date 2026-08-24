local Cookie = require("miuread.legacy.cookie")
local Client = require("miuread.legacy.client")
local Content = require("miuread.legacy.content")
local WeRead = require("miuread.legacy.weread")
local Http = require("miuread.http")
local U = require("miuread.util")

local Worker = {}

local CONTEXT_MAX_AGE_SECONDS = 15 * 60

local function deepcopy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local out = {}
    seen[value] = out
    for key, item in pairs(value) do
        local key_type = type(key)
        local item_type = type(item)
        if (key_type == "string" or key_type == "number")
            and item_type ~= "function" and item_type ~= "userdata" and item_type ~= "thread" then
            out[deepcopy(key, seen)] = deepcopy(item, seen)
        end
    end
    return out
end

local MemorySettings = {}
MemorySettings.__index = MemorySettings

function MemorySettings:new(snapshot)
    return setmetatable({ data = deepcopy(snapshot or {}), changed = {} }, self)
end

function MemorySettings:get(key, default)
    local value = self.data[key]
    if value == nil then
        return deepcopy(default)
    end
    return deepcopy(value)
end

function MemorySettings:set(key, value)
    self.data[key] = deepcopy(value)
    self.changed[key] = true
end

function MemorySettings:flush()
    -- The worker is intentionally isolated from KOReader's persistent settings.
    -- Updated cookies/context are returned to the parent process and committed there.
end

function MemorySettings:is_cookie_configured()
    return Cookie.has_login_cookie(self.data.cookies or {})
end

local function normalize_progress_ratio(value)
    value = tonumber(value)
    if not value then
        return nil
    end
    if value > 1 then
        value = value / 100
    end
    if value < 0 then
        value = 0
    elseif value > 1 then
        value = 1
    end
    return value
end

local function native_progress_percent(value)
    local ratio = normalize_progress_ratio(value) or 0
    -- The Web Reader uses parseInt(100 * ratio), i.e. floor for the valid
    -- non-negative range. Sending a rounded percentage can disagree with co by
    -- one whole percentage point on long books.
    return math.floor(math.max(0, math.min(1, ratio)) * 100)
end

local function chapter_uid(chapter)
    return chapter and (chapter.chapterUid or chapter.uid or chapter.chapter_uid)
end

local function chapter_index(chapter, fallback)
    return tonumber(chapter and (chapter.chapterIdx or chapter.index or chapter.chapter_index or chapter.chapter_idx))
        or tonumber(fallback or 0) or 0
end

local function chapter_words(chapter)
    if Content.is_structural_chapter(chapter) then return 0 end
    return math.max(0, tonumber(chapter and (chapter.wordCount or chapter.word_count) or 0) or 0)
end

local function trusted_words(book, chapter)
    local words = chapter_words(chapter)
    if words > 0 then return words end
    local uid = tostring(chapter_uid(chapter) or "")
    if uid ~= "" and uid == tostring(book.local_chapter_uid or "") then
        return math.max(0, tonumber(book.local_chapter_word_count or 0) or 0)
    end
    if uid ~= "" and uid == tostring(book.source_chapter_uid or "") then
        return math.max(0, tonumber(book.source_chapter_word_count or 0) or 0)
    end
    if uid ~= "" and uid == tostring(book.chapter_uid or "") then
        return math.max(0, tonumber(book.chapter_word_count or 0) or 0)
    end
    return 0
end

local function standalone_position(book, ratio)
    local chapters = type(book.chapters) == "table" and book.chapters or {}
    local source_uid = tostring(book.source_chapter_uid or "")
    if source_uid == "" or #chapters == 0 then return nil, "standalone chapter catalog unavailable" end

    local total, before, selected = 0, 0, nil
    for _, chapter in ipairs(chapters) do
        local words = trusted_words(book, chapter)
        if not selected and tostring(chapter_uid(chapter) or "") == source_uid then
            selected = chapter
        elseif not selected then
            before = before + words
        end
        total = total + words
    end
    if not selected or total <= 0 then return nil, "standalone chapter not found in full catalog" end

    local words = trusted_words(book, selected)
    local offset = math.max(0, math.min(words, math.floor(words * ratio + 0.5)))
    local whole_ratio = (before + offset) / total
    return {
        chapter_uid = chapter_uid(selected) or source_uid,
        chapter_idx = chapter_index(selected, book.source_chapter_index),
        chapter_offset = offset,
        progress = native_progress_percent(whole_ratio),
        source = "standalone_chapter",
    }
end

local function read_report_accepted(result)
    return type(result) == "table"
        and (result.succ == true or tonumber(result.succ) == 1)
end

local function read_report_uncertain(result)
    if type(result) ~= "table" or read_report_accepted(result) then return false end
    local err_code = result.errCode or result.errcode or result.code
    local err_message = result.errMsg or result.errmsg or result.message or result.msg
    if err_code ~= nil then
        local numeric = tonumber(err_code)
        if numeric == nil or numeric ~= 0 then return false end
    end
    if err_message ~= nil and U.trim(tostring(err_message)) ~= "" then return false end
    -- WeRead sometimes returns an empty/partial body after accepting a report.
    -- Without an explicit failure code this is "not confirmed", not proof that
    -- the account/book context is broken. The caller may verify progress later,
    -- but must never repair/replay this elapsed interval blindly.
    return true
end

local function result_summary(result)
    if type(result) ~= "table" then
        return "non_table_response"
    end
    local parts = {
        "succ=" .. tostring(result.succ),
        "has_synckey=" .. tostring(result.synckey ~= nil),
    }
    local err_code = result.errCode or result.errcode or result.code
    local err_message = result.errMsg or result.errmsg or result.message or result.msg
    if err_code ~= nil then
        parts[#parts + 1] = "error_code=" .. tostring(err_code)
    end
    if err_message ~= nil then
        parts[#parts + 1] = "error_message="
            .. U.first_line(tostring(err_message):gsub("[%c]+", " "), 160)
    end
    return table.concat(parts, ", ")
end

local function confirmation(result)
    if type(result) ~= "table" then
        return { succ = 0 }
    end
    return {
        succ = result.succ,
        synckey = result.synckey,
    }
end

local function select_context_chapter(book)
    local chapters = type(book.chapters) == "table" and book.chapters or {}

    local function by_uid(uid)
        uid = tostring(uid or "")
        if uid == "" then return nil end
        for _, chapter in ipairs(chapters) do
            if tostring(chapter_uid(chapter) or "") == uid
                and not Content.is_structural_chapter(chapter) then
                return chapter
            end
        end
    end

    -- Prefer the chapter MiuRead can prove is currently open. An exact UID
    -- remains usable even when WeRead reports wordCount=0/missing.
    local selected = by_uid(book.local_chapter_uid)
        or by_uid(book.source_is_standalone and book.source_chapter_uid or nil)
        or by_uid(book.chapter_uid)
        or by_uid(book.remote_chapter_uid)
    if selected then return selected end

    local wanted_idx = tonumber(book.local_chapter_idx or book.source_chapter_index or book.chapter_idx or book.remote_chapter_idx)
    if wanted_idx ~= nil then
        for index, chapter in ipairs(chapters) do
            local idx = chapter_index(chapter, index)
            if (idx == wanted_idx or index == wanted_idx or index - 1 == wanted_idx)
                and not Content.is_structural_chapter(chapter) then
                return chapter
            end
        end
    end

    -- Ratio fallback uses only chapters with trustworthy positive length. It
    -- must never choose a zero-length structural/random chapter just to report.
    local ratio = normalize_progress_ratio(book.progress) or 0
    local total = 0
    for _, chapter in ipairs(chapters) do total = total + trusted_words(book, chapter) end
    if total > 0 then
        local target, before = ratio * total, 0
        for _, chapter in ipairs(chapters) do
            local words = trusted_words(book, chapter)
            if words > 0 then
                if target <= before + words then return chapter end
                before = before + words
            end
        end
    end

    return Content.first_readable_chapter(chapters)
end

local function refresh_context(client, book_id, book, force)
    book_id = tostring(book_id or "")
    if book_id == "" then
        error("missing book id")
    end

    book = deepcopy(book or {})
    book.book_id = book.book_id or book.bookId or book_id
    book.title = book.title or book_id
    book.reader_url = book.reader_url or WeRead.reader_url(book_id)

    local now = os.time()
    local context_age = now - (tonumber(book.read_context_updated_at) or 0)
    local standalone_catalog_missing = book.source_is_standalone == true and book.catalog_complete ~= true
    local context_ready = book.psvts ~= nil and tostring(book.psvts) ~= ""
        and book.chapter_uid ~= nil
        and type(book.chapters) == "table" and #book.chapters > 0
        and not standalone_catalog_missing

    if not force and context_ready and context_age < CONTEXT_MAX_AGE_SECONDS then
        return book, false
    end

    Content.ensure_reader_state(client, book)

    if force or standalone_catalog_missing or type(book.chapters) ~= "table" or #book.chapters == 0 then
        Content.fetch_catalog(client, book)
        book.catalog_complete = true
    end

    local progress_ok, progress_result = pcall(function()
        return client:get_progress(book_id)
    end)
    if progress_ok and type(progress_result) == "table" then
        local remote = type(progress_result.book) == "table"
            and progress_result.book or progress_result
        local remote_uid = remote.chapterUid or remote.chapterId or remote.chapter_uid
        local remote_idx = tonumber(remote.chapterIdx or remote.chapterIndex or remote.chapter_idx)
        local remote_offset = tonumber(remote.chapterOffset or remote.chapterPos or remote.offset)
        local remote_progress = tonumber(remote.progress)
        if remote_progress ~= nil or remote_uid ~= nil then
            book.remote_progress = remote_progress or tonumber(book.progress) or 0
            book.remote_chapter_uid = remote_uid or book.chapter_uid
            book.remote_chapter_idx = remote_idx or tonumber(book.chapter_idx) or 0
            book.remote_chapter_offset = remote_offset or tonumber(book.chapter_offset) or 0
            -- Keep remote position as a fallback only. The currently open
            -- local chapter must remain the primary repair/sync identity.
            book.remote_progress_loaded = true
        end
    end

    local selected = select_context_chapter(book)
    if not selected then
        error("no readable chapter found for report context")
    end

    book.chapter_uid = chapter_uid(selected) or book.chapter_uid
    book.chapter_idx = chapter_index(selected, book.chapter_idx)
    book.chapter_word_count = trusted_words(book, selected)
    book.app_id = book.app_id or WeRead.web_app_id()
    book.read_context_updated_at = now
    book.read_context_ready = book.psvts ~= nil and tostring(book.psvts) ~= ""
        and book.chapter_uid ~= nil

    if not book.read_context_ready then
        error("reader context is incomplete")
    end
    return book, true
end

local function native_local_position(book, ratio)
    if book.local_native_chapter_offset ~= true then return nil end
    if tostring(book.local_chapter_offset_basis or "") ~= "wr_data_co" then
        return nil, "native chapter offset basis mismatch"
    end

    local uid = tostring(book.local_chapter_uid or "")
    local offset = tonumber(book.local_chapter_offset)
    if uid == "" or offset == nil then
        return nil, "native local position incomplete"
    end
    offset = math.max(0, math.floor(offset + 0.5))

    local chapters = type(book.chapters) == "table" and book.chapters or {}
    local selected
    for _, chapter in ipairs(chapters) do
        if tostring(chapter_uid(chapter) or "") == uid
            and not Content.is_structural_chapter(chapter) then
            selected = chapter
            break
        end
    end
    if not selected then
        return nil, "native local chapter not found in catalog"
    end

    local whole_ratio = math.max(0, math.min(1, tonumber(ratio) or 0))
    if book.source_is_standalone == true then
        -- For standalone EPUBs the parent intentionally reports chapter-local
        -- ratio. Convert only `pr` back to whole-book space; native `co` stays
        -- untouched because it is raw XHTML source position, not wordCount.
        local total, before = 0, 0
        local found = false
        for _, chapter in ipairs(chapters) do
            local words = trusted_words(book, chapter)
            if not found and tostring(chapter_uid(chapter) or "") == uid then
                found = true
            elseif not found then
                before = before + words
            end
            total = total + words
        end
        local words = trusted_words(book, selected)
        if not found or words <= 0 or total <= 0 then
            return nil, "standalone native progress catalog unavailable"
        end
        whole_ratio = math.max(0, math.min(1, (before + words * whole_ratio) / total))
    end

    return {
        chapter_uid = chapter_uid(selected) or uid,
        chapter_idx = chapter_index(selected, book.local_chapter_idx or book.chapter_idx),
        chapter_offset = offset,
        progress = native_progress_percent(whole_ratio),
        source = "native_wr_data_co",
        native_offset = true,
        offset_basis = "wr_data_co",
    }
end

local function estimate_position(book, progress_ratio)
    local chapters = type(book.chapters) == "table" and book.chapters or {}
    local ratio = normalize_progress_ratio(progress_ratio)
        or normalize_progress_ratio(book.progress)
        or 0

    local native, native_error = native_local_position(book, ratio)
    if native then return native end
    -- An explicitly native offset must never silently fall through to the old
    -- wordCount clamp, otherwise a valid Web Reader source coordinate can be
    -- truncated before upload.
    if book.local_native_chapter_offset == true then return nil, native_error end

    if book.source_is_standalone == true then
        local mapped, map_error = standalone_position(book, ratio)
        if mapped then return mapped end
        if book.remote_progress_loaded == true then
            return {
                chapter_uid = book.remote_chapter_uid or book.chapter_uid or 0,
                chapter_idx = tonumber(book.remote_chapter_idx or book.chapter_idx) or 0,
                chapter_offset = tonumber(book.remote_chapter_offset or book.chapter_offset) or 0,
                progress = native_progress_percent(book.remote_progress or book.progress),
                source = "remote_fallback",
            }
        end
        return nil, map_error
    end

    local function by_uid(uid)
        uid=tostring(uid or "")
        if uid=="" then return nil end
        for _,item in ipairs(chapters) do
            if tostring(chapter_uid(item) or "")==uid and not Content.is_structural_chapter(item) then return item end
        end
    end

    -- The local open-book mapping is the safest source and must win over a
    -- ratio guess, especially when WeRead reports zero/missing word counts.
    local chapter=by_uid(book.local_chapter_uid) or by_uid(book.chapter_uid)
    if chapter then
        local words=trusted_words(book,chapter)
        local offset=tonumber(book.local_chapter_offset or book.chapter_offset) or 0
        if words>0 then offset=math.max(0,math.min(words,offset)) else offset=math.max(0,offset) end
        local before,total,found=0,0,false
        for _,item in ipairs(chapters) do
            if not Content.is_structural_chapter(item) then
                local item_words=trusted_words(book,item)
                if not found and tostring(chapter_uid(item) or "")==tostring(chapter_uid(chapter) or "") then
                    found=true
                elseif not found then
                    before=before+item_words
                end
                total=total+item_words
            end
        end
        if found and words>0 and total>0 then
            ratio=math.max(0,math.min(1,(before+offset)/total))
        end
        return {
            chapter_uid=chapter_uid(chapter),
            chapter_idx=chapter_index(chapter,book.local_chapter_idx or book.chapter_idx),
            chapter_offset=offset,
            progress=native_progress_percent(ratio),
            source=found and total>0 and "trusted_local_chapter_global" or "trusted_local_chapter",
        }
    end

    local total=0
    for _,item in ipairs(chapters) do total=total+trusted_words(book,item) end
    if total<=0 then return nil,"no safe chapter length available for report position" end
    local target,before=ratio*total,0
    for _,item in ipairs(chapters) do
        local words=trusted_words(book,item)
        if words>0 then
            if target<=before+words then
                return {
                    chapter_uid=chapter_uid(item),
                    chapter_idx=chapter_index(item,0),
                    chapter_offset=math.max(0,math.min(words,math.floor(target-before))),
                    progress=native_progress_percent(ratio),
                    source="catalog_ratio",
                }
            end
            before=before+words
        end
    end
    return nil,"no safe chapter found for report position"
end

local function build_payload(book_id, elapsed_seconds, book, progress_ratio, time_only)
    local position, position_error
    if time_only ~= true then
        position, position_error = estimate_position(book, progress_ratio)
        if not position then return nil, position_error end
    end
    local payload=WeRead.make_read_payload{
        book_id = book_id,
        chapter_uid = position and position.chapter_uid or nil,
        chapter_idx = position and position.chapter_idx or nil,
        chapter_offset = position and position.chapter_offset or nil,
        progress = position and position.progress or nil,
        summary = book.summary or "",
        elapsed_seconds = elapsed_seconds,
        app_id = book.app_id or WeRead.web_app_id(),
        psvts = book.psvts,
        pclts = book.pclts,
        token = book.token,
        time_only = time_only == true,
    }
    local public={
        ci=tonumber(payload.ci), co=tonumber(payload.co), pr=tonumber(payload.pr), rt=tonumber(payload.rt),
        time_only=time_only==true,
        has_app_id=tostring(payload.appId or "")~="", has_ps=tostring(payload.ps or "")~="",
        has_pc=tostring(payload.pc or "")~="", has_signature=tostring(payload.s or "")~="",
        token_source=tostring(book.token or "")~="" and "reader_context" or "default",
        pc_source=tostring(book.pclts or "")~="" and "reader_context" or "generated",
        payload_fields_complete=tostring(payload.appId or "")~="" and tostring(payload.pc or "")~=""
            and tostring(payload.s or "")~="",
        position_source=position and position.source or nil,
        report_chapter_uid=position and position.chapter_uid or nil,
        report_chapter_idx=position and position.chapter_idx or nil,
        local_chapter_uid=book.local_chapter_uid,
        local_chapter_idx=book.local_chapter_idx,
        remote_chapter_uid=book.remote_chapter_uid,
        remote_chapter_idx=book.remote_chapter_idx,
        native_chapter_offset=position and position.native_offset == true or false,
        chapter_offset_basis=position and (position.offset_basis or book.local_chapter_offset_basis) or nil,
    }
    return payload, position, public
end

local function attempt_report(client, book_id, elapsed_seconds, book, progress_ratio, time_only)
    local payload, position_or_error, payload_public = build_payload(book_id, elapsed_seconds, book, progress_ratio, time_only)
    if not payload then
        return false, nil, tostring(position_or_error or "reading position unavailable"), "position", nil,
            {payload_fields_complete=false}
    end
    local referer = book.reader_url or WeRead.reader_url(book_id)
    local ok, result, code, headers = pcall(function()
        return client:report_read(payload, referer)
    end)
    local meta={code=tonumber(code),has_headers=type(headers)=="table"}
    if not ok then
        local message=tostring(result)
        local kind=Http.is_auth_error(message) and "authentication"
            or ((Http.is_network_error and Http.is_network_error(message)) and "transport" or "server")
        return false, nil, message, kind, position_or_error, payload_public, meta
    end
    if read_report_accepted(result) then
        return true, result, nil, nil, position_or_error, payload_public, meta
    end
    local summary=result_summary(result)
    if read_report_uncertain(result) then
        return false, result, summary, "unconfirmed", position_or_error, payload_public, meta
    end
    local kind=Http.is_auth_error(summary) and "authentication" or "server"
    return false, result, summary, kind, position_or_error, payload_public, meta
end

local BOOK_PATCH_KEYS = {
    "book_id", "bookId", "title", "author", "reader_url",
    "psvts", "pclts", "token", "chapters", "progress",
    "chapter_uid", "chapter_idx", "chapter_offset", "chapter_word_count",
    "local_native_chapter_offset", "local_chapter_offset_basis",
    "source_is_standalone", "source_chapter_uid", "source_chapter_index",
    "source_chapter_word_count", "source_chapter_title",
    "catalog_complete", "remote_progress_loaded", "remote_progress",
    "remote_chapter_uid", "remote_chapter_idx", "remote_chapter_offset",
    "app_id", "read_context_updated_at", "read_context_ready", "core_map_hash",
}

local function make_book_patch(book)
    local patch = {}
    for _, key in ipairs(BOOK_PATCH_KEYS) do
        if book and book[key] ~= nil then
            patch[key] = deepcopy(book[key])
        end
    end
    return patch
end

local function finish(settings, book, fields, context_changed)
    fields = fields or {}
    if settings.changed.cookies then
        fields.cookies_changed = true
        fields.cookies = settings:get("cookies", {})
    end
    if settings.changed.wr_ticket then
        fields.wr_ticket_changed = true
        fields.wr_ticket = settings:get("wr_ticket", "")
    end
    if settings.changed.wr_wrpa then
        fields.wr_wrpa_changed = true
        fields.wr_wrpa = settings:get("wr_wrpa", "")
    end
    if context_changed then
        fields.context_changed = true
        fields.book_patch = make_book_patch(book)
    end
    return fields
end

function Worker.run(job)
    job = job or {}
    local book_id = tostring(job.book_id or "")
    local elapsed_seconds = tonumber(job.elapsed_seconds) or 30
    local progress_ratio = normalize_progress_ratio(job.progress_ratio)
    local settings = MemorySettings:new{
        cookies = job.cookies or {},
        api_key = job.api_key or "",
        wr_ticket = job.wr_ticket or "",
        wr_wrpa = job.wr_wrpa or "",
        books = {},
    }
    local client = Client:new(settings)
    local book = deepcopy(job.book or {})
    local context_changed = false
    book.book_id = book.book_id or book.bookId or book_id
    book.title = book.title or job.book_title or book_id

    if tostring(book.book_id or book.bookId or "")~=book_id then
        return finish(settings, book, {
            ok=false,error="book context identity mismatch",error_kind="context",
        }, context_changed)
    end
    local job_core=tostring(job.core_map_hash or "")
    local book_core=tostring(book.core_map_hash or "")
    if job_core~="" and book_core~="" and job_core~=book_core then
        return finish(settings, book, {
            ok=false,error="book core map identity mismatch",error_kind="context",
        }, context_changed)
    end
    if job_core~="" then book.core_map_hash=job_core end

    if book_id == "" then
        return finish(settings, book, {
            ok = false,
            error = "missing book id",
            error_kind = "context",
        }, context_changed)
    end
    if not settings:is_cookie_configured() then
        return finish(settings, book, {
            ok = false,
            error = "cookie not configured",
            error_kind = "authentication",
        }, context_changed)
    end

    if job.time_only == true then
        -- A pure reading-time report needs no chapter catalog, progress read or
        -- local-position reconstruction. Keep only lightweight signing context.
        book.reader_url = book.reader_url or WeRead.reader_url(book_id)
        book.app_id = book.app_id or WeRead.web_app_id()
    else
        local context_ok, context_or_error, initial_context_changed = pcall(function()
            return refresh_context(client, book_id, book, job.force_context == true)
        end)
        if not context_ok then
            local message=tostring(context_or_error)
            local kind=Http.is_auth_error(message) and "authentication"
                or ((Http.is_network_error and Http.is_network_error(message)) and "transport" or "context")
            return finish(settings, book, {
                ok = false,
                error = message,
                error_kind = kind,
            }, context_changed)
        end
        book = context_or_error
        context_changed = initial_context_changed == true
    end

    -- Catalog/context preparation must be possible before progress verification.
    -- In this mode the worker performs only reader-state/catalog reads and never
    -- sends a read-report request, so preparing a chapter map cannot alter cloud
    -- progress or fabricate reading time.
    if job.context_only == true then
        return finish(settings, book, {
            ok = true,
            context_only = true,
            response_summary = "reader context and full catalog ready",
            path = "context_only",
            payload_public = { context_only = true, payload_fields_complete = false },
        }, true)
    end

    local accepted, result, first_error, first_kind, first_position, first_public, first_meta = attempt_report(
        client, book_id, elapsed_seconds, book, progress_ratio, job.time_only == true
    )
    if accepted then
        return finish(settings, book, {
            ok = true,
            result = confirmation(result),
            response_summary = result_summary(result),
            path = job.force_context == true and "manual_repair" or "initial",
            position = first_position,
            payload_public = first_public,
            meta = first_meta,
        }, context_changed)
    end

    if first_kind == "unconfirmed" then
        return finish(settings, book, {
            ok = false,
            uncertain = true,
            error = first_error,
            error_kind = "unconfirmed",
            response_summary = first_error,
            result = confirmation(result),
            position = first_position,
            payload_public = first_public,
            meta = first_meta,
        }, context_changed)
    end

    -- Explicit failures are returned to the parent. Recovery policy belongs to
    -- the parent/service so a single transient request can never rewrite the
    -- current book context or trigger a user-facing repair by itself.
    return finish(settings, book, {
        ok = false,
        error = first_error,
        error_kind = first_kind or "server",
        payload_public = first_public,
        meta = first_meta,
    }, context_changed)

end

return Worker
