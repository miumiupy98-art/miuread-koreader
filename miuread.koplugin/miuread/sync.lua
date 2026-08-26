local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local FFIUtil = require("ffi/util")
local Json = require("miuread.json")
local Config = require("miuread.config")
local ReadReportService = require("miuread.read_report_service")
local Protocol = require("miuread.protocol")
local Http = require("miuread.http")
local ReadReportWorker = require("miuread.legacy_adapter_worker")
local BookIntegrity = require("miuread.book_integrity")
local PrecisePosition = require("miuread.precise_position")
local SourcePosition = require("miuread.source_position")
local U = require("miuread.util")
local SubprocessHygiene = require("miuread.subprocess_hygiene")

local Sync = {}
Sync.__index = Sync
local legacy_daemon_retired = false

local CONTEXT_MAX_AGE = 15 * 60
local READ_REPORT_SERVICE_VERSION = 22
local FIRST_REPORT_DELAY = 60
local FINAL_REPORT_MIN_SECONDS = 10
local PRECISE_POSITION_LEAD_SECONDS = 12

-- beta.45: source-anchor reports may carry the Web Reader's native raw-XHTML
-- UTF-16 `co`. Whole-book inverse mapping remains only as a `pr`/fallback aid.

local function report_ratio_from_position(position)
    position = type(position) == "table" and position or {}
    if position.standalone == true and tonumber(position.chapter_ratio) ~= nil then
        return U.clamp(tonumber(position.chapter_ratio), 0, 1)
    end
    if position.standalone == true and tonumber(position.chapter_percent) ~= nil then
        return U.clamp(tonumber(position.chapter_percent) / 100, 0, 1)
    end
    return U.clamp((tonumber(position.progress) or 0) / 100, 0, 1)
end

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

local function progress_from_node(node, expected_book_id)
    if type(node) ~= "table" then return nil end
    local node_book_id = rawget(node, "bookId") or rawget(node, "book_id")
    if node_book_id ~= nil and tostring(node_book_id) ~= tostring(expected_book_id or "") then return nil end
    local p = tonumber(rawget(node, "progress") or rawget(node, "readingProgress")
        or rawget(node, "progressPercent") or rawget(node, "bookProgress"))
    if p == nil then return nil end
    -- The Web API normally returns 0-100. Only true fractions are expanded;
    -- a literal 1 must remain 1%, not be mistaken for 100%.
    if p > 0 and p < 1 then p = p * 100 end
    return {
        percent = U.clamp(p, 0, 100),
        chapter_uid = rawget(node, "chapterUid") or rawget(node, "chapterId") or rawget(node, "chapter_uid"),
        chapter_idx = rawget(node, "chapterIdx") or rawget(node, "chapterIndex") or rawget(node, "chapter_idx"),
        offset = rawget(node, "chapterOffset") or rawget(node, "chapterPos") or rawget(node, "offset"),
        updated_at = rawget(node, "updateTime") or rawget(node, "updatedAt") or rawget(node, "update_time"),
        raw = node,
    }
end

local function response_progress(value, expected_book_id)
    if type(value) ~= "table" then return nil end
    local queue = {value}
    local seen = {}
    local allowed = {"book", "data", "result", "reader", "progressInfo", "bookProgress", "payload", "books", "bookList", "progresses"}
    local index = 1
    while index <= #queue and index <= 32 do
        local node = queue[index]; index = index + 1
        if type(node) == "table" and not seen[node] then
            seen[node] = true
            local found = progress_from_node(node, expected_book_id)
            if found then return found end
            for _, key in ipairs(allowed) do
                local child = rawget(node, key)
                if type(child) == "table" then queue[#queue + 1] = child end
            end
            for i = 1, math.min(#node, 20) do
                if type(node[i]) == "table" then queue[#queue + 1] = node[i] end
            end
        end
    end
end

local function normalize_timestamp(value)
    local ts=tonumber(value)
    if not ts then return nil end
    if ts>100000000000 then ts=math.floor(ts/1000) end
    return ts
end

local function sourced_progress(value, expected_book_id, source)
    local progress=response_progress(value, expected_book_id)
    if not progress then return nil end
    progress.source=tostring(source or "unknown")
    progress.updated_at=normalize_timestamp(progress.updated_at)
    progress.fetched_at=os.time()
    return progress
end

local function remote_coordinate(progress)
    if type(progress)~="table" then return nil,nil end
    local uid=tostring(progress.chapter_uid or progress.chapterUid or "")
    local offset=tonumber(progress.offset or progress.chapter_offset or progress.chapterOffset)
    if uid=="" or offset==nil then return nil,nil end
    return uid,offset
end

local function choose_remote_progress(web,agent,threshold)
    threshold=math.max(0,tonumber(threshold) or 2)
    if web and agent then
        local web_uid,web_offset=remote_coordinate(web)
        local agent_uid,agent_offset=remote_coordinate(agent)
        local wt,at=normalize_timestamp(web.updated_at) or 0,normalize_timestamp(agent.updated_at) or 0
        local function newest()
            local selected=wt>at and web or agent
            if wt==at then selected=web end
            selected.sources={web=web,agent=agent}
            selected.source=(wt==at and "web_cookie" or selected.source)
            return selected
        end
        if web_uid and agent_uid then
            if web_uid~=agent_uid or math.abs(web_offset-agent_offset)>32 then
                return {
                    conflict=true,conflict_reason="coordinate_mismatch",
                    web=web,agent=agent,source="conflict",fetched_at=os.time(),
                }
            end
            local selected=newest()
            selected.selection_reason="coordinate_match"
            return selected
        end
        if web_uid or agent_uid then
            local selected=web_uid and web or agent
            selected.sources={web=web,agent=agent}
            selected.selection_reason="coordinate_preferred"
            return selected
        end
        local delta=math.abs((tonumber(web.percent) or 0)-(tonumber(agent.percent) or 0))
        if delta>threshold then
            return {
                conflict=true,conflict_reason="percent_mismatch",
                web=web,agent=agent,source="conflict",fetched_at=os.time(),
            }
        end
        local selected=newest()
        selected.selection_reason="percent_match"
        return selected
    end
    local selected=web or agent
    if selected then
        selected.sources={web=web,agent=agent}
        local uid=remote_coordinate(selected)
        selected.selection_reason=uid and "single_coordinate_source" or "single_percent_source"
    end
    return selected
end

local function positions_match(submitted,remote,threshold)
    submitted=type(submitted)=="table" and submitted or {}
    remote=type(remote)=="table" and remote or {}
    if remote.conflict then return false,"remote_source_conflict" end
    threshold=math.max(0,tonumber(threshold) or 2)
    local submitted_uid=tostring(submitted.chapter_uid or submitted.chapterUid or "")
    local remote_uid=tostring(remote.chapter_uid or remote.chapterUid or "")
    if submitted_uid~="" and remote_uid~="" and submitted_uid~=remote_uid then
        return false,"chapter_uid_mismatch"
    end

    -- chapterUid + chapterOffset are the authoritative reading coordinates.
    -- Whole-book percentages may differ when the catalog contains a different
    -- number of structural chapters, so never reject an exact coordinate match
    -- merely because the derived percentages disagree.
    if submitted_uid~="" and remote_uid~="" then
        local a,b=tonumber(submitted.offset or submitted.chapter_offset),tonumber(remote.offset or remote.chapter_offset)
        local chapter_words=tonumber(submitted.chapter_word_count) or 0
        if a~=nil and b~=nil then
            local tolerance=submitted.native_offset==true and 32
                or math.max(12,math.floor(chapter_words*0.005))
            if math.abs(a-b)<=tolerance then return true,"chapter_offset_match" end
            return false,"chapter_offset_mismatch"
        end
    end

    local submitted_percent=tonumber(submitted.progress)
    local remote_percent=tonumber(remote.percent)
    if submitted_percent~=nil and remote_percent~=nil
        and math.abs(submitted_percent-remote_percent)>threshold then
        return false,"progress_mismatch"
    end
    return true,"percent_match"
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
            progress = U.clamp(ratio * 100, 0, 100),
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
                progress = U.clamp(ratio * 100, 0, 100),
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

local function readable_local_chapter_count(chapters)
    local count = 0
    for _, chapter in ipairs(type(chapters) == "table" and chapters or {}) do
        if type(chapter) == "table" and chapter.structural ~= true
            and tostring(chapter_uid(chapter) or "") ~= "" then
            count = count + 1
        end
    end
    return count
end

local function local_chapter_by_uid(chapters, wanted_uid)
    wanted_uid = tostring(wanted_uid or "")
    if wanted_uid == "" then return nil end
    for index, chapter in ipairs(type(chapters) == "table" and chapters or {}) do
        if type(chapter) == "table" and tostring(chapter_uid(chapter) or "") == wanted_uid then
            return chapter, index
        end
    end
end

local function catalog_progress_from_remote(remote, chapters)
    if type(remote)~="table" then return remote end
    chapters=type(chapters)=="table" and chapters or {}
    remote.raw_percent=tonumber(remote.raw_percent or remote.percent)

    -- WeRead's chapterOffset (`co`) is a raw-XHTML UTF-16 source coordinate,
    -- not a wordCount offset. beta.5 incorrectly clamped it to chapter words,
    -- turning every native co above wordCount into the same artificial value
    -- (e.g. 5993/8325 -> 5531) and then falsely reporting cloud mismatches.
    local raw_offset=tonumber(remote.offset)
    if raw_offset~=nil then
        remote.offset=math.max(0,math.floor(raw_offset+0.5))
        remote.chapter_offset=remote.offset
        remote.position_basis="wr_data_co_unresolved"
        remote.offset_basis="wr_data_co"
        remote.native_offset=true
    end

    if #chapters==0 then return remote end
    local wanted_uid=tostring(remote.chapter_uid or "")
    local wanted_idx=tonumber(remote.chapter_idx)
    local selected,selected_pos=nil,nil
    for index,chapter in ipairs(chapters) do
        local uid=tostring(chapter_uid(chapter) or "")
        local idx=chapter_index(chapter,index)
        local matches=(wanted_uid~="" and uid==wanted_uid)
            or (wanted_uid=="" and wanted_idx~=nil and (idx==wanted_idx or index==wanted_idx or index-1==wanted_idx))
        if matches then selected=chapter; selected_pos=index; break end
    end
    if selected then
        remote.chapter_uid=chapter_uid(selected) or remote.chapter_uid
        remote.chapter_idx=chapter_index(selected,selected_pos)
        remote.chapter_word_count=chapter_words(selected)
    end
    return remote
end

function Sync:new(reader, api, store, host, async, identity_async)
    local object = setmetatable({
        reader=reader, api=api, store=store, host=host, async=async,
        identity_async=identity_async,
        timer=nil, current=nil, last_activity=0, last_page=nil, suspended=false,
        busy=false, progress_hold=false, session_uploads=0, last_upload=0, last_attempt=0,
        last_error=nil, last_path=nil, last_stage=nil, last_response_summary=nil,
        last_response_path=nil, last_http_code=nil, last_http_length=nil,
        state="stopped", tick_count=0, last_report_clock=0, next_due=0,
        consecutive_failures=0, first_success_notified=false, failure_notified=false, last_error_kind=nil,
        verified_book_id=nil, verified_at=0, verified_local_percent=nil,
        verified_remote_percent=nil, verified_login_session_id=nil, verification_ttl=4 * 60 * 60,
        daemon=nil, daemon_poll=nil, daemon_status_stamp=nil,
        daemon_context=nil, daemon_last_persist=0, daemon_generation=0,
        daemon_restart_count=0, auth_recovery_busy=false, auth_recovery_at=0,
        auto_repair_busy=false, repair_busy=false, repair_book_id=nil, repair_generation=0,
        daemon_auth_retry_at=0, auth_transitioning=false,
        control_write_task=nil, session_started_at=0, suspend_generation=0,
        precise_position_cache={}, precise_due_refreshed=0,
        record_generation=0, record_retry_task=nil, record_checked_path=nil,
        time_enabled=(store:preferences().sync or {}).time_enabled==true,
        controller_token=tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999)),
    }, self)
    -- Retire the pre-1.1.33 service so an OTA reload cannot keep reusing an
    -- older worker that was already resident in the KOReader process.
    if not legacy_daemon_retired then
        object:_retire_legacy_daemon()
        legacy_daemon_retired = true
    end
    -- Start the lightweight reporter only after a real reading session has
    -- been verified. Prestarting it on the bookshelf competes with startup I/O
    -- on older e-ink devices and provides no value before a book is opened.
    return object
end

function Sync:_document_path()
    if not self.host.ui or not self.host.ui.document then return nil end
    local document=self.host.ui.document
    local path=document.file or (document.getFilePath and document:getFilePath())
    return path and path~="" and path or nil
end

function Sync:_usable_record(book,record,variant,path)
    if not book then return nil end
    local content_type=tostring((type(record)=="table" and record.content_type)
        or (type(book)=="table" and book.content_type) or "")
    local partial_range=type(record)=="table" and record.partial_range==true
    if content_type=="mp_collection" or tostring(variant or "")=="mp_collection"
        or (type(record)=="table" and record.sync_enabled==false and not partial_range) then return nil end
    if type(record)=="table" and tostring(record.preview_mode or "")=="info" then return nil end
    return {book=book,record=record,variant=variant,path=path}
end

function Sync:record()
    local path=self:_document_path()
    if not path then return nil end
    if self.current and self.current.path==path then return self.current end
    if self.record_checked_path==path then return nil end
    local finder=type(self.store.file_record_fast)=="function" and self.store.file_record_fast or self.store.file_record
    local book,record,variant=finder(self.store,path,true)
    local current=self:_usable_record(book,record,variant,path)
    if current then self.current=current; return current end
end

function Sync:_read_report_allowed(record)
    record=record or self:record()
    local row=record and record.record or nil
    if type(row)~="table" then return false end
    if row.partial_range==true then return false end
    return row.read_report_enabled~=false
end

function Sync:local_ratio()
    local ui = self.host.ui
    if not ui or not ui.document then return nil end
    local document = ui.document

    -- For reflowable documents, prefer the current XPointer's continuous
    -- document Y coordinate. ReaderFooter.percent_finished is page/page-count
    -- and therefore quantized to one rendered KOReader page; converting that
    -- back into WeRead's whole-book word space makes the absolute error grow
    -- with book length. CRE exposes a continuous position for the same XPointer
    -- we already use for precise source anchoring, so keep that precision here.
    local height = document.info and tonumber(document.info.doc_height) or nil
    if ui.rolling and height and height > 0 and type(document.getPosFromXPointer) == "function" then
        local xp = ui.rolling.xpointer
        if (xp == nil or tostring(xp) == "") and type(document.getXPointer) == "function" then
            local ok_xp, current_xp = pcall(document.getXPointer, document)
            if ok_xp then xp = current_xp end
        end
        if xp ~= nil and tostring(xp) ~= "" then
            local ok_pos, y = pcall(document.getPosFromXPointer, document, xp)
            y = ok_pos and tonumber(y) or nil
            if y then
                self.last_local_ratio_source = "xpointer_doc_pos"
                return U.clamp(y / height, 0, 1)
            end
        end
    end

    -- current_pos is also continuous and cheaper than page/page-count. Keep it
    -- as the second choice when an XPointer position cannot be resolved.
    if ui.rolling and height and height > 0 then
        local pos = tonumber(ui.rolling.current_pos)
        if pos then
            self.last_local_ratio_source = "rolling_doc_pos"
            return U.clamp(pos / height, 0, 1)
        end
    end

    local footer = ui.view and ui.view.footer
    local value = footer and tonumber(footer.percent_finished)
    if value then
        self.last_local_ratio_source = "footer_page_ratio"
        return value > 1 and U.clamp(value / 100, 0, 1) or U.clamp(value, 0, 1)
    end
    if document.getCurrentPage and document.getPageCount then
        local a, page = pcall(document.getCurrentPage, document)
        local b, total = pcall(document.getPageCount, document)
        if a and b and tonumber(total) and tonumber(total) > 0 then
            self.last_local_ratio_source = "document_page_ratio"
            return U.clamp(tonumber(page) / tonumber(total), 0, 1)
        end
    end
end

function Sync:_core_map_hash(record)
    record=record or self:record()
    if not record then return "" end
    return BookIntegrity.record_hash(record.book,record.record)
end

function Sync:_record_mode(record)
    record = record or self:record()
    local local_map = record and record.record and record.record.chapter_map or {}
    local explicit_uid = tostring(record and record.record and record.record.chapter_uid or "")
    local readable = readable_local_chapter_count(local_map)
    if explicit_uid ~= "" and readable <= 1 then
        return "standalone", explicit_uid, readable
    end
    return "full", nil, readable
end

function Sync:_book_catalog_is_complete(record, catalog)
    catalog = type(catalog) == "table" and catalog or {}
    if #catalog == 0 or type(record) ~= "table" then return false end
    local book = type(record.book) == "table" and record.book or {}
    local row = type(record.record) == "table" and record.record or {}
    local mode, _, local_readable = self:_record_mode(record)
    local local_map = type(row.chapter_map) == "table" and row.chapter_map or {}

    -- beta.18: completeness is a property of the whole WeRead catalog, never
    -- of the number of chapters selected into this EPUB. beta.14-17 stored
    -- `catalog_chapter_count=#selected` for chapter/range downloads, which made
    -- one local chapter look like a complete one-chapter book.
    local expected = tonumber(book.catalog_chapter_count
        or row.catalog_chapter_count or row.expected_catalog_chapter_count)
    local explicit_complete = book.catalog_complete == true or row.catalog_complete == true
    if explicit_complete then
        return expected == nil or expected <= 0 or #catalog >= expected
    end

    -- Runtime migration for beta.14-17 downloads: Downloader already saved the
    -- full catalog at book level and a catalog-only hash, even though the row's
    -- count was wrong. Trust that exact hash, not a non-empty hash in general.
    local book_id = tostring(book.book_id or book.bookId or row.book_id or "")
    local stored_catalog_hash = tostring(book.core_catalog_hash or "")
    if stored_catalog_hash ~= "" and book_id ~= "" then
        local actual_catalog_hash = BookIntegrity.core_map_hash(book_id, catalog, {})
        if actual_catalog_hash ~= "" and actual_catalog_hash == stored_catalog_hash then
            if mode == "standalone" or row.partial_range == true then
                -- For legacy partial EPUBs, a catalog no larger than the local
                -- selection is ambiguous and therefore unsafe. A genuine
                -- one-chapter whole book will be confirmed by the context worker
                -- once and then stored with explicit catalog_complete metadata.
                if #catalog > math.max(0, tonumber(local_readable) or 0) then
                    -- Promote only in the current in-memory record. Avoid a
                    -- flash write on page-turn while also avoiding re-hashing
                    -- the same legacy catalog on every idle display refresh.
                    book.catalog_complete=true
                    book.catalog_chapter_count=#catalog
                    return true
                end
            else
                book.catalog_complete=true
                book.catalog_chapter_count=#catalog
                return true
            end
        end
    end

    -- Full EPUBs remain safely recognizable without migration metadata because
    -- the local chapter map and whole-book catalog are equivalent.
    if mode ~= "standalone" and row.partial_range ~= true
        and BookIntegrity.maps_equivalent(local_map, catalog) then
        return true
    end
    return false
end

function Sync:_progress_catalog(record)
    record = record or self:record()
    if not record then return {}, "missing_record" end
    local book_id = tostring(record.book and record.book.book_id or "")
    local core_hash = self:_core_map_hash(record)
    local auth = self.store:auth()
    local login_id = tostring(auth.login_session_id or "")
    local session = self.store:session(book_id) or {}

    local function context_catalog(context, source, session_bound)
        if type(context) ~= "table" or context.catalog_complete ~= true
            or type(context.chapters) ~= "table" or #context.chapters == 0 then return nil end
        if tostring(context.book_id or context.bookId or book_id) ~= book_id then return nil end
        local context_core = tostring(context.core_map_hash or "")
        if core_hash ~= "" and context_core ~= "" and context_core ~= core_hash then return nil end
        if session_bound then
            if tostring(session.report_login_session_id or "") ~= login_id then return nil end
            local session_core = tostring(session.report_core_map_hash or "")
            if core_hash ~= "" and session_core ~= "" and session_core ~= core_hash then return nil end
            if core_hash ~= "" and context_core == "" and session_core == "" then return nil end
        elseif core_hash ~= "" and context_core == "" then
            return nil
        end
        return context.chapters, source
    end

    local chapters, source = context_catalog(self.daemon_context, "daemon_context", false)
    if chapters then return chapters, source end
    chapters, source = context_catalog(session.legacy_report_context, "session_context", true)
    if chapters then return chapters, source end

    local catalog = record.book and record.book.catalog or {}
    if self:_book_catalog_is_complete(record, catalog) then return catalog, "book_catalog" end
    return {}, "missing"
end

function Sync:chapter_catalog_context(record)
    record=record or self:record()
    if not record then return {catalog_complete=false,chapters={},source="missing_record",book_id=""} end
    local chapters,source=self:_progress_catalog(record)
    local book_id=tostring(record.book and (record.book.book_id or record.book.bookId) or "")
    local complete=type(chapters)=="table" and #chapters>0 and tostring(source or "")~="missing"
    return {catalog_complete=complete,chapters=complete and U.copy(chapters) or {},
        source=tostring(source or "missing"),book_id=book_id}
end

function Sync:ensure_chapter_catalog_context(callback)
    local current=self:chapter_catalog_context()
    if current.catalog_complete==true then
        if callback then callback(current,nil) end
        return true,"cached"
    end
    return self:_prepare_progress_catalog(function(_,err,meta)
        local refreshed=self:chapter_catalog_context()
        if refreshed.catalog_complete==true then
            if callback then callback(refreshed,nil) end
        elseif callback then
            callback(nil,err or "catalog_context_failed",meta)
        end
    end)
end

function Sync:position(record, ratio, chapters, full_catalog)
    ratio = ratio or self:local_ratio() or 0
    local local_map = chapters or (record.record and record.record.chapter_map) or {}
    local full_map = full_catalog
    if type(full_map) ~= "table" or #full_map == 0 then
        full_map = select(1, self:_progress_catalog(record))
    end
    local mapped,map_error=BookIntegrity.position_from_maps(local_map,full_map,ratio,{
        chapter_uid = record.record and record.record.chapter_uid or 0,
        summary = record.book.title,
    })
    if mapped then return mapped end
    local fallback=map_position(local_map,ratio,{
        chapter_uid=record.record and record.record.chapter_uid or 0,
        summary=record.book.title,
    })
    fallback.safe=BookIntegrity.maps_equivalent(local_map,full_map)
    fallback.mapping_error=map_error
    fallback.source=fallback.safe and "equivalent_local_map" or "unsafe_local_ratio"
    return fallback
end

function Sync:_decorate_legacy_context(context, record)
    context = context or {}
    local core_hash=self:_core_map_hash(record)
    context.book_id=tostring(record and record.book and record.book.book_id or context.book_id or "")
    context.core_map_hash=core_hash
    local full_catalog=select(1,self:_progress_catalog(record))
    if type(full_catalog)=="table" and #full_catalog>0 then
        context.chapters=U.copy(full_catalog)
        context.catalog_complete=true
    end
    local mode, standalone_uid = self:_record_mode(record)
    if mode == "standalone" and standalone_uid then
        local local_map = record.record.chapter_map or {}
        local local_chapter = local_chapter_by_uid(local_map, standalone_uid) or local_map[1] or {}
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
    local position = self:position(record, ratio)
    position.safe = position.safe~=false and position.progress~=nil and tostring(position.chapter_uid or "")~=""
    local mode = self:_record_mode(record)
    position.standalone = mode == "standalone"
    position.epub_percent = math.floor(U.clamp(ratio, 0, 1) * 100 + .5)
    position.chapter_percent = tonumber(position.chapter_percent) or position.epub_percent
    position.estimated_progress = tonumber(position.progress)
    position.display_progress_quality = "estimated_document_ratio"
    return position
end

function Sync:_prefer_inverse_cloud_mapping(record, position, ratio_override)
    if type(position) ~= "table" or position.safe ~= true then return position end
    record = record or self:record()
    if not record or type(record.record) ~= "table" then return position end

    local native_offset = position.native_offset == true
        and tostring(position.offset_basis or position.position_basis or "") == "wr_data_co"
    local local_map = type(record.record.chapter_map) == "table" and record.record.chapter_map or {}
    local catalog = self:_precision_catalog(record)
    -- Whole-book inverse mapping is still useful for `pr`, but native Web
    -- Reader `co` is source-coordinate based and must never be overwritten by
    -- a wordCount-space estimate.
    if record.record.partial_range == true
        or not BookIntegrity.maps_equivalent(local_map, catalog) then
        position.inverse_mapping_used = false
        position.inverse_mapping_reason = "local_map_not_full_catalog"
        return position
    end

    local ratio = tonumber(ratio_override)
    if ratio == nil then ratio = self:local_ratio() end
    if ratio == nil then
        position.inverse_mapping_used = false
        position.inverse_mapping_reason = "local_global_ratio_missing"
        return position
    end
    local inverse = self:position(record, ratio, local_map, catalog)
    if type(inverse) ~= "table" or inverse.safe ~= true
        or tostring(inverse.chapter_uid or "") == "" then
        position.inverse_mapping_used = false
        position.inverse_mapping_reason = tostring(type(inverse) == "table"
            and inverse.mapping_error or "inverse_position_unavailable")
        return position
    end

    local source_uid = tostring(position.chapter_uid or "")
    local inverse_uid = tostring(inverse.chapter_uid or "")
    local source_offset = tonumber(position.chapter_offset or position.offset)
    local inverse_offset = tonumber(inverse.chapter_offset or inverse.offset)
    position.source_anchor_offset = source_offset
    position.source_anchor_progress = tonumber(position.progress)
    position.source_anchor_chapter_ratio = tonumber(position.chapter_ratio)
    position.inverse_offset = inverse_offset
    position.inverse_progress = tonumber(inverse.progress)
    position.inverse_delta = source_offset ~= nil and inverse_offset ~= nil
        and (inverse_offset - source_offset) or nil
    position.local_global_ratio = U.clamp(tonumber(ratio) or 0, 0, 1)

    if source_uid == "" or inverse_uid == "" or source_uid ~= inverse_uid then
        position.inverse_mapping_used = false
        position.inverse_mapping_reason = "inverse_chapter_mismatch"
        position.inverse_chapter_uid = inverse_uid
        logger.info("[MiuRead][ProgressOffset]",
            "book=", tostring(record.book and record.book.book_id or ""),
            "chapter=", source_uid ~= "" and source_uid or "-",
            native_offset and "native_co=" or "source_co=", tostring(source_offset or "-"),
            "inverse_co=", tostring(inverse_offset or "-"),
            native_offset and "selected=native" or "selected=source", "reason=chapter_mismatch")
        return position
    end

    if inverse_offset == nil then
        position.inverse_mapping_used = false
        position.inverse_mapping_reason = "inverse_offset_missing"
        return position
    end

    if native_offset then
        -- beta.18: native source matching already gives us an exact chapter
        -- ratio. Keep the whole-book percentage derived from that exact source
        -- position. The document inverse ratio is only a diagnostic/cheap
        -- estimate and must never overwrite the precise display/report value.
        position.estimated_progress = tonumber(inverse.progress)
        position.display_progress = tonumber(position.progress)
        position.display_progress_quality = position.display_progress_quality or "precise_source_mapped"
        position.inverse_mapping_used = true
        position.inverse_mapping_role = "estimate_only"
        logger.info("[MiuRead][ProgressOffset]",
            "book=", tostring(record.book and record.book.book_id or ""),
            "chapter=", source_uid,
            "native_co=", tostring(source_offset or "-"),
            "source_word_co=", tostring(position.source_word_offset or "-"),
            "inverse_co=", tostring(inverse_offset),
            "global_ratio=", string.format("%.8f", tonumber(position.local_global_ratio) or 0),
            "ratio_source=", tostring(self.last_local_ratio_source or "-"),
            "selected=native")
        return position
    end

    -- Legacy beta43 fallback: when native source coordinates are unavailable,
    -- retain the proven full-book inverse mapping for chapter offset.
    position.offset = inverse_offset
    position.chapter_offset = inverse_offset
    position.progress = tonumber(inverse.progress) or position.progress
    position.chapter_word_count = tonumber(inverse.chapter_word_count) or position.chapter_word_count
    position.total_word_count = tonumber(inverse.total_word_count) or position.total_word_count
    position.words_before = tonumber(inverse.words_before) or position.words_before
    if tonumber(position.chapter_word_count) and tonumber(position.chapter_word_count) > 0 then
        position.chapter_ratio = U.clamp(inverse_offset / tonumber(position.chapter_word_count), 0, 1)
        position.chapter_percent = math.floor(position.chapter_ratio * 100 + 0.5)
    end
    position.source = "inverse_cloud_map"
    position.position_basis = "inverse_remote_chapter_offset"
    position.offset_basis = "inverse_remote_chapter_offset"
    position.native_offset = false
    position.inverse_mapping_used = true

    logger.info("[MiuRead][ProgressOffset]",
        "book=", tostring(record.book and record.book.book_id or ""),
        "chapter=", source_uid,
        "source_co=", tostring(source_offset or "-"),
        "inverse_co=", tostring(inverse_offset),
        "delta=", tostring(position.inverse_delta or "-"),
        "global_ratio=", string.format("%.8f", tonumber(position.local_global_ratio) or 0),
        "ratio_source=", tostring(self.last_local_ratio_source or "-"),
        "selected=inverse")
    return position
end
function Sync:_precision_catalog(record)
    local catalog = select(1, self:_progress_catalog(record))
    return type(catalog) == "table" and catalog or {}
end

function Sync:_prepare_progress_catalog(callback)
    local record = self:record()
    if not record then return false, "position_context_missing" end
    local book_id = tostring(record.book and record.book.book_id or "")
    if book_id == "" then return false, "book_id_missing" end
    local auth = self.store:auth()
    local account = type(auth.account) == "table" and auth.account or {}
    local login_snapshot = tostring(auth.login_session_id or "")
    local auth_revision_snapshot=math.max(0,tonumber(auth.auth_revision or 0) or 0)
    local vid_snapshot = tostring(account.vid or "")
    if login_snapshot == "" or vid_snapshot == "" then return false, "authentication_required" end

    local worker
    if self.identity_async and self.identity_async:available() and not self.identity_async:busy() then
        worker = self.identity_async
    elseif self.async and self.async:available() and not self.async:busy() then
        worker = self.async
    elseif (self.identity_async and self.identity_async:busy()) or (self.async and self.async:busy()) then
        return false, "catalog_worker_busy"
    else
        return false, "catalog_worker_unavailable"
    end

    local generation = tonumber(self.record_generation or 0) or 0
    local path = tostring(record.path or "")
    local core_hash = self:_core_map_hash(record)
    local session = self.store:session(book_id) or {}
    local saved = type(session.legacy_report_context) == "table" and session.legacy_report_context or nil
    local context_matches = saved ~= nil
        and tostring(session.report_login_session_id or "") == login_snapshot
        and (tostring(session.report_core_map_hash or "") == ""
            or tostring(session.report_core_map_hash or "") == tostring(core_hash or ""))
    local legacy_book = U.copy(context_matches and saved or {})
    legacy_book.book_id = book_id
    legacy_book.title = record.book.title
    self:_decorate_legacy_context(legacy_book, record)

    -- Even before the full catalog exists, preserve the current local chapter
    -- identity so the context worker can choose a sensible reader chapter.
    local local_guess = map_position((record.record and record.record.chapter_map) or {},
        self:local_ratio() or 0, {chapter_uid=record.record and record.record.chapter_uid, summary=record.book.title})
    if type(local_guess) == "table" then
        legacy_book.local_chapter_uid = local_guess.chapter_uid
        legacy_book.local_chapter_idx = local_guess.chapter_index
        legacy_book.local_chapter_offset = local_guess.offset
        legacy_book.local_native_chapter_offset = false
        legacy_book.local_chapter_offset_basis = "catalog_word_fallback"
        local row = local_chapter_by_uid(record.record and record.record.chapter_map or {}, local_guess.chapter_uid)
        legacy_book.local_chapter_word_count = tonumber(row and (row.word_count or row.wordCount) or 0) or 0
    end

    local ratio_snapshot = self:local_ratio() or 0
    local book_title = tostring(record.book.title or "")
    logger.info("[MiuRead][ProgressMap] catalog prepare started",
        "book=", book_id, "mode=", self:_record_mode(record),
        "local_chapters=", tostring(#((record.record and record.record.chapter_map) or {})),
        "core=", tostring(core_hash):sub(1,12))

    local started, run_error = worker:run("progress_catalog_context", function()
        return ReadReportWorker.run{
            book_id = book_id,
            book_title = book_title,
            book = legacy_book,
            core_map_hash = core_hash,
            progress_ratio = ratio_snapshot,
            elapsed_seconds = 0,
            cookies = auth.cookies or {},
            api_key = auth.api_key or "",
            wr_ticket = auth.wr_ticket or "",
            wr_wrpa = auth.wr_wrpa or "",
            allow_renewal = false,
            force_context = true,
            context_only = true,
        }
    end, function(result)
        local current = self:record()
        local current_auth = self.store:auth()
        local current_account = type(current_auth.account) == "table" and current_auth.account or {}
        if generation ~= tonumber(self.record_generation or 0)
            or not current or tostring(current.book and current.book.book_id or "") ~= book_id
            or tostring(current.path or "") ~= path then
            if callback then callback(nil, "stale_catalog_result", {error_kind="context"}) end
            return
        end
        if login_snapshot ~= tostring(current_auth.login_session_id or "")
            or auth_revision_snapshot~=math.max(0,tonumber(current_auth.auth_revision or 0) or 0)
            or vid_snapshot ~= tostring(current_account.vid or "") then
            if callback then callback(nil, "login_changed", {error_kind="authentication"}) end
            return
        end
        local value = result and result.ok == true and result.value or nil
        local context = type(value) == "table" and value.legacy_context or nil
        if type(value) ~= "table" or value.accepted ~= true
            or type(context) ~= "table" or context.catalog_complete ~= true
            or type(context.chapters) ~= "table" or #context.chapters == 0 then
            local err = tostring((type(value)=="table" and value.error) or (result and result.error) or "catalog_context_failed")
            local kind = tostring(type(value)=="table" and value.error_kind or "context")
            logger.warn("[MiuRead][ProgressMap] catalog prepare failed", "book=",book_id,
                "kind=",kind,"reason=",err)
            if callback then callback(nil, err, {error_kind=kind}) end
            return
        end
        context.core_map_hash = core_hash

        -- Keep a catalog that has already produced a verified cloud position
        -- stable for the rest of the verification TTL. A transient Web Reader
        -- catalog that adds/removes structural chapters must not silently change
        -- the whole-book percentage basis from e.g. 22 to 23 chapters.
        local verified_at=tonumber(session.verified_at or 0) or 0
        local verified_age=os.time()-verified_at
        local saved_verified=session.remote_verified==true
            and verified_at>0 and verified_age>=0 and verified_age<=(tonumber(self.verification_ttl) or 14400)
            and type(saved)=="table" and saved.catalog_complete==true
            and type(saved.chapters)=="table" and #saved.chapters>0
        if saved_verified then
            local saved_hash=BookIntegrity.core_map_hash(book_id,saved.chapters,{})
            local new_hash=BookIntegrity.core_map_hash(book_id,context.chapters,{})
            if saved_hash~="" and new_hash~="" and saved_hash~=new_hash then
                logger.warn("[MiuRead][ProgressMap] catalog drift ignored during verified session",
                    "book=",book_id,"kept=",tostring(#saved.chapters),
                    "new=",tostring(#context.chapters))
                context=U.copy(saved)
                context.core_map_hash=core_hash
            end
        end

        if value.cookies_changed and type(value.cookies) == "table" then
            local latest_auth = self.store:auth()
            latest_auth.cookies = value.cookies
            if value.wr_ticket_changed then latest_auth.wr_ticket = value.wr_ticket end
            if value.wr_wrpa_changed then latest_auth.wr_wrpa = value.wr_wrpa end
            local saved_auth,save_error=self.store:save_auth(latest_auth,{expected_revision=auth_revision_snapshot})
            if saved_auth~=true then
                logger.warn("[MiuRead][ProgressMap] stale worker credential update ignored",U.first_line(save_error or "",120))
            end
        end
        self.daemon_context = U.copy(context)
        self.store:save_session(book_id,{
            legacy_report_context=U.copy(context),
            report_login_session_id=login_snapshot,
            report_core_map_hash=core_hash,
            book_core_map_hash=core_hash,
            last_stage="完整章节信息已准备",
        })
        logger.info("[MiuRead][ProgressMap] catalog ready", "book=",book_id,
            "chapters=",tostring(#context.chapters),"source=context_only")
        if callback then callback(context.chapters, nil, {source="context_only"}) end
    end, 55)
    if not started then return false, run_error end
    return true
end

function Sync:resolve_local_progress(callback, options)
    options = options or {}
    local detached=options.detached==true
    local record = type(options.record_snapshot)=="table" and U.copy(options.record_snapshot) or self:record()
    if not record then return false, "position_context_missing" end
    local book_id = tostring(record.book and record.book.book_id or "")
    local generation = tonumber(options.record_generation_override or self.record_generation or 0) or 0
    local path = tostring(record.path or "")
    local ratio_snapshot=tonumber(options.ratio_snapshot)
    if ratio_snapshot==nil then ratio_snapshot=self:local_ratio() end

    local function still_current()
        if detached then return true end
        local current = self:record()
        return generation == tonumber(self.record_generation or 0)
            and current and tostring(current.book and current.book.book_id or "") == book_id
            and tostring(current.path or "") == path
    end

    local function emit(stage, detail)
        if type(options.on_stage) == "function" then pcall(options.on_stage, stage, detail) end
    end

    local function complete_fallback(prepared, source_error)
        if not still_current() then
            if callback then callback(nil, "stale_position_result", {error_kind="context"}) end
            return
        end
        local ratio = ratio_snapshot or self:local_ratio() or 0
        local position = options.precise == false and self:local_position(ratio)
            or self:_position_for_report(ratio, true)
        if type(position) == "table" and position.safe == true and position.progress ~= nil
            and tostring(position.chapter_uid or "") ~= "" then
            if source_error then position.precision_fallback = position.precision_fallback or tostring(source_error) end
            if callback then callback(position, nil, {source=position.source or position.position_basis}) end
            return
        end
        local mapping_error = tostring(type(position)=="table" and position.mapping_error or source_error or "position_unavailable")
        if options.prepare_catalog ~= false and prepared ~= true then
            emit("mapping_preparing", mapping_error)
            local started, err = self:_prepare_progress_catalog(function(chapters, prepare_error, meta)
                if chapters then
                    -- Re-run once with the freshly cached full catalog. This is
                    -- also the recovery path for stale/incomplete stored catalogs.
                    local next_options = U.copy(options)
                    next_options._catalog_prepared = true
                    next_options.on_stage = options.on_stage
                    self:resolve_local_progress(callback, next_options)
                elseif callback then
                    callback(nil, prepare_error or "catalog_prepare_failed", meta or {error_kind="context"})
                end
            end)
            if started then return end
            if callback then callback(nil, tostring(err or "catalog_prepare_unavailable"), {error_kind="busy"}) end
            return
        end
        if callback then callback(nil, mapping_error, {error_kind="position"}) end
    end

    local catalog, catalog_source = self:_progress_catalog(record)
    local prepared = options._catalog_prepared == true
    if type(catalog) ~= "table" or #catalog == 0 then
        if options.prepare_catalog == false or prepared then
            complete_fallback(prepared, "full_catalog_missing")
            return true
        end
        emit("mapping_preparing", "full_catalog_missing")
        local started, err = self:_prepare_progress_catalog(function(chapters, prepare_error, meta)
            if chapters then
                local next_options = U.copy(options)
                next_options._catalog_prepared = true
                next_options.on_stage = options.on_stage
                self:resolve_local_progress(callback, next_options)
            elseif callback then
                callback(nil, prepare_error or "catalog_prepare_failed", meta or {error_kind="context"})
            end
        end)
        if not started then return false, err end
        return true
    end

    logger.info("[MiuRead][ProgressMap] position resolving",
        "book=",book_id,"mode=",self:_record_mode(record),
        "catalog=",tostring(catalog_source),"chapters=",tostring(#catalog))

    if options.precise == false then
        complete_fallback(prepared, nil)
        return true
    end

    emit("position_locating", catalog_source)
    local started, source_error = self:_source_position_async(function(position, err)
        if position then
            local exact_cloud=position.native_offset==true
                and tostring(position.offset_basis or position.position_basis or "")=="wr_data_co"
                and tonumber(position.chapter_offset or position.offset)~=nil
            position.precision_level=exact_cloud and "exact_cloud" or "precise_local"
            position.canonical_offset=tonumber(position.chapter_offset or position.offset)
            logger.info("[MiuRead][ProgressSource] ready", "book=",book_id,
                "chapter=",tostring(position.chapter_uid or "-"),
                "offset=",tostring(position.offset or "-"),
                "basis=",tostring(position.offset_basis or position.position_basis or "-"),
                "native=",tostring(position.native_offset == true),
                "precision=",tostring(position.precision_level),
                "progress=",string.format("%.3f",tonumber(position.progress) or 0),
                "cache=",tostring(position.source_cache_hit == true))
            if options.require_cloud_coordinate==true and not exact_cloud then
                if callback then callback(nil,"cloud_coordinate_unavailable",{error_kind="position"}) end
                return
            end
            if callback then callback(position, nil, {source=position.source or "weread_source_anchor"}) end
            return
        end
        emit("position_fallback", err)
        if options.require_cloud_coordinate==true then
            if callback then callback(nil,tostring(err or "cloud_coordinate_unavailable"),{error_kind="position"}) end
            return
        end
        complete_fallback(prepared, err)
    end,{
        detached=detached,
        record_snapshot=record,
        record_generation_override=generation,
        ratio_snapshot=ratio_snapshot,
        defer_seconds=options.defer_seconds,
    })
    if started then return true end
    emit("position_fallback", source_error)
    if options.require_cloud_coordinate==true then
        if callback then callback(nil,tostring(source_error or "cloud_coordinate_unavailable"),{error_kind="busy"}) end
        return true
    end
    complete_fallback(prepared, source_error)
    return true
end

function Sync:_source_position_async(callback, options)
    options=type(options)=="table" and options or {}
    local detached=options.detached==true
    local record = type(options.record_snapshot)=="table" and U.copy(options.record_snapshot) or self:record()
    local ui = self.host and self.host.ui or nil
    if not record or not ui or not ui.document then return false, "position_context_missing" end
    -- The source-coordinate path is intentionally subprocess-only. If this
    -- device cannot fork a worker, keep the existing local precision path
    -- rather than doing a network request on the Reader UI thread.
    if not self.async or not self.async:available() then return false, "source_worker_unavailable" end
    if self.async:busy() then return false, "source_worker_busy" end

    local anchor, anchor_error = PrecisePosition.capture(
        ui, record, self:_precision_catalog(record))
    if not anchor then return false, anchor_error end

    local generation = tonumber(options.record_generation_override or self.record_generation or 0) or 0
    local book_id = tostring(record.book and record.book.book_id or "")
    local path = tostring(record.path or "")
    local ratio_snapshot=tonumber(options.ratio_snapshot)
    if ratio_snapshot==nil then ratio_snapshot=self:local_ratio() end
    local reader = self.reader
    local source_cache_only=options.cache_only==true
    local record_snapshot = {
        book = U.copy(record.book or {}),
        record = U.copy(record.record or {}),
        variant = record.variant,
        path = record.path,
    }
    local function on_result(result)
        local current = self:record()
        if not detached and (generation ~= tonumber(self.record_generation or 0)
            or not current
            or tostring(current.book and current.book.book_id or "") ~= book_id
            or tostring(current.path or "") ~= path) then
            if callback then callback(nil, "stale_position_result") end
            return
        end
        local envelope=result and result.ok==true and type(result.value)=="table" and result.value or nil
        local value=envelope and envelope.position or nil
        if type(value) == "table" and value.safe == true then
            local mapping_record=detached and record_snapshot or current
            local adjusted = self:_prefer_inverse_cloud_mapping(mapping_record, value, ratio_snapshot)
            adjusted.captured_at = os.time()
            if adjusted.mapping_recovered==true then
                logger.info("[MiuRead][ProgressSource] neighbour chapter mapping recovered",
                    "book=",book_id,
                    "from=",tostring(adjusted.mapping_original_chapter_uid or "-"),
                    "to=",tostring(adjusted.chapter_uid or "-"))
            end
            if callback then callback(adjusted, nil) end
            return
        end
        local detail=tostring(envelope and envelope.error or (result and result.error) or "source_position_failed")
        logger.warn("[MiuRead][ProgressSource] source mapping failed",
            "book=",book_id,"error=",detail)
        if callback then callback(nil, "source_position_failed") end
    end
    local function launch()
        if self.async:busy() then return false,"source_worker_busy" end
        return self.async:run("progress_source_position", function()
            local value,source_error=SourcePosition.locate(reader, record_snapshot, anchor,{cache_only=source_cache_only})
            return {position=value,error=source_error}
        end,on_result,40)
    end
    local defer_seconds=math.max(0,tonumber(options.defer_seconds) or 0)
    if detached and defer_seconds>0 then
        -- Capture the Reader anchor now, but postpone network/source mapping until
        -- after the close transition. This keeps the first Home frame ahead of
        -- PosMap building or a source-chapter fetch on single-core Kindles. A
        -- quickly opened next book may briefly own the sync worker, so retry a
        -- few times in the background instead of dropping the old book immediately.
        local attempts=0
        local function deferred_launch()
            attempts=attempts+1
            local started,run_error=launch()
            if started then return end
            if tostring(run_error or "")=="source_worker_busy" and attempts<4 then
                UIManager:scheduleIn(1.2,deferred_launch)
                return
            end
            if callback then callback(nil,tostring(run_error or "source_worker_unavailable")) end
        end
        UIManager:scheduleIn(defer_seconds,deferred_launch)
        return true
    end
    local started,run_error=launch()
    if not started then return false,run_error end
    return true
end

-- beta.18 display-only precise resolver. It is deliberately cache-only and
-- subprocess-only: toolbar painting must never fetch a chapter, prepare a
-- catalog or build PosMap on the Reader UI thread.
function Sync:resolve_display_position(callback, options)
    options=type(options)=="table" and options or {}
    local record=self:record()
    if not record then return false,"position_context_missing" end
    local catalog,source=self:_progress_catalog(record)
    if type(catalog)~="table" or #catalog==0 then return false,"full_catalog_missing" end
    local book_id=tostring(record.book and record.book.book_id or "")
    local page_token=options.page_token
    local started,err=self:_source_position_async(function(position,position_error)
        if type(position)=="table" and position.safe==true then
            position.precision_level=(position.native_offset==true
                and tostring(position.offset_basis or position.position_basis or "")=="wr_data_co")
                and "exact_cloud" or "precise_local"
            position.canonical_offset=tonumber(position.chapter_offset or position.offset)
            position.display_progress=tonumber(position.progress)
            position.display_progress_quality=position.display_progress_quality or "precise_source_mapped"
            position.display_catalog_source=source
            position.display_page_token=page_token
            self:_save_local_snapshot(book_id,position)
            if callback then callback(position,nil,{source=source,quality=position.display_progress_quality}) end
        elseif callback then
            callback(nil,tostring(position_error or "display_position_unavailable"),{source=source})
        end
    end,{
        cache_only=true,
        ratio_snapshot=tonumber(options.ratio_snapshot),
        defer_seconds=0,
    })
    if not started then return false,err end
    return true
end

function Sync:_position_for_report(ratio, precise)
    local fallback = self:local_position(ratio)
    if precise ~= true then return fallback end
    local record = self:record()
    local ui = self.host and self.host.ui or nil
    if not record or not ui or not ui.document then return fallback end
    self.precise_position_cache = type(self.precise_position_cache) == "table"
        and self.precise_position_cache or {}
    local position, err = PrecisePosition.locate(
        ui, record, self:_precision_catalog(record), self.precise_position_cache)
    if position then
        position.display_progress = tonumber(position.progress)
        position.display_progress_quality = "precise_local_text_anchor"
        position = self:_prefer_inverse_cloud_mapping(record, position)
        position.epub_percent = math.floor(U.clamp(tonumber(ratio) or self:local_ratio() or 0, 0, 1) * 100 + .5)
        logger.info("[MiuRead][Progress] precise position",
            "book=", tostring(record.book and record.book.book_id or ""),
            "chapter=", tostring(position.chapter_uid or "-"),
            "offset=", tostring(position.offset or "-"),
            "progress=", string.format("%.3f", tonumber(position.progress) or 0),
            "ms=", tostring(position.precision_ms or 0),
            "cache=", tostring(position.precision_cache_hit == true))
        return position
    end
    if type(fallback) == "table" then
        fallback.position_basis = fallback.position_basis or fallback.source or "page_ratio"
        fallback.precision_fallback = tostring(err or "precision_unavailable")
    end
    logger.info("[MiuRead][Progress] precise position fallback",
        "book=", tostring(record.book and record.book.book_id or ""),
        "reason=", tostring(err or "unknown"))
    return fallback
end

function Sync:jump_remote(remote)
    remote = remote or {}
    local record = self:record()
    if not record then return false, "未识别到当前觅阅书籍" end
    local mode, standalone_uid = self:_record_mode(record)
    local row=type(record.record)=="table" and record.record or {}
    local partial_range=row.partial_range==true
    local ok, err

    local function within_chapter_ratio(selected_words)
        local ratio=tonumber(remote.chapter_ratio)
        if ratio~=nil then return U.clamp(ratio,0,1) end
        local source_word_offset=tonumber(remote.source_word_offset)
        if source_word_offset~=nil and selected_words>0 then
            return U.clamp(source_word_offset/selected_words,0,1)
        end
        -- Old/non-native records may still use word-space offsets. Native WR
        -- `co` must never be divided by wordCount.
        if remote.native_offset~=true and tonumber(remote.offset)~=nil and selected_words>0 then
            return U.clamp(tonumber(remote.offset)/selected_words,0,1)
        end
        return nil
    end

    if partial_range then
        local local_map=type(row.chapter_map)=="table" and row.chapter_map or {}
        local remote_uid=tostring(remote.chapter_uid or "")
        if remote_uid=="" then return false,"云端位置缺少章节信息" end
        local selected,local_before,local_total=nil,0,0
        for _,chapter in ipairs(local_map) do
            local words=chapter_words(chapter)
            if not selected and tostring(chapter_uid(chapter) or "")==remote_uid then
                selected=chapter
            elseif not selected then
                local_before=local_before+words
            end
            local_total=local_total+words
        end
        if not selected then return false,"云端位置不在当前章节版范围内" end
        local words=chapter_words(selected)
        if words<=0 or local_total<=0 then return false,"章节版位置信息不完整" end
        local within=within_chapter_ratio(words)
        if within==nil then
            local catalog=select(1,self:_progress_catalog(record))
            local target=tonumber(remote.percent)
            if type(catalog)=="table" and #catalog>0 and target~=nil then
                local before,total=0,0
                local full_selected
                for _,chapter in ipairs(catalog) do
                    local cw=chapter_words(chapter)
                    if not full_selected and tostring(chapter_uid(chapter) or "")==remote_uid then
                        full_selected={before=before,words=cw}
                    end
                    total=total+cw
                    if not full_selected then before=before+cw end
                end
                if full_selected and full_selected.words>0 and total>0 then
                    local target_words=U.clamp(target,0,100)/100*total
                    within=U.clamp((target_words-full_selected.before)/full_selected.words,0,1)
                end
            end
        end
        if within==nil then return false,"云端位置缺少可换算的章节内坐标" end
        local local_ratio=U.clamp((local_before+words*within)/local_total,0,1)
        ok=self:jump(local_ratio*100)
        err=ok and nil or "无法跳转到云端阅读位置"
    elseif mode ~= "standalone" or not standalone_uid then
        ok = self:jump(remote.percent)
        err = ok and nil or "无法跳转到云端阅读位置"
    else
        local remote_uid = remote.chapter_uid
        if remote_uid == nil or tostring(remote_uid) ~= tostring(standalone_uid) then
            return false, "云端位置不在当前下载章节中"
        end

        local chapters = select(1,self:_progress_catalog(record))
        if type(chapters) ~= "table" or #chapters == 0 then return false, "完整目录尚未准备好" end
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
        local local_ratio=within_chapter_ratio(words)
        if local_ratio==nil and tonumber(remote.percent) and total > 0 and words>0 then
            local target = U.clamp(tonumber(remote.percent), 0, 100) / 100 * total
            local_ratio = (target - before) / words
        end
        if local_ratio == nil then return false, "云端位置缺少章节内偏移" end
        local_ratio = U.clamp(local_ratio, 0, 1)
        ok = self:jump(local_ratio * 100)
        err = ok and nil or "无法跳转到云端阅读位置"
    end

    return ok, err
end

function Sync:is_verified(book_id)
    book_id = tostring(book_id or "")
    if book_id=="" then return false end
    local auth=self.store:auth()
    local login=tostring(auth.login_session_id or "")
    local ttl=tonumber(self.verification_ttl) or 14400

    if tostring(self.verified_book_id or "")==book_id
        and tostring(self.verified_login_session_id or "")==login then
        local age=os.time()-(tonumber(self.verified_at or 0) or 0)
        if age>=0 and age<=ttl then return true end
    end

    -- Verification must survive closing/reopening the book and KOReader restarts.
    -- Restore it only for the same account and the same generated book mapping.
    local session=self.store:session(book_id) or {}
    local verified_at=tonumber(session.verified_at or 0) or 0
    local age=os.time()-verified_at
    if session.remote_verified~=true or verified_at<=0 or age<0 or age>ttl
        or tostring(session.verification_login_session_id or "")~=login then return false end
    local record=self:record()
    if not record or tostring(record.book and record.book.book_id or "")~=book_id then return false end
    local current_core=self:_core_map_hash(record)
    local verified_core=tostring(session.verified_core_map_hash or session.report_core_map_hash or "")
    if current_core=="" or verified_core=="" or verified_core~=current_core then return false end

    self.verified_book_id=book_id
    self.verified_at=verified_at
    self.verified_local_percent=tonumber(session.verified_local_percent)
    self.verified_remote_percent=tonumber(session.verified_remote_percent)
    self.verified_login_session_id=login
    logger.info("[MiuRead][Sync] restored verified state",
        "book=",book_id,"age=",tostring(age),"core=",current_core:sub(1,12))
    return true
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
    self.verified_login_session_id = nil
    if old_book then
        self.store:save_session(tostring(old_book), {
            remote_verified=false, verified_at=nil, verified_reason=tostring(reason or "cleared"),
            verified_local_percent=nil, verified_remote_percent=nil,
            verified_chapter_uid=nil, verified_chapter_offset=nil,
            verified_core_map_hash=nil, verified_catalog_hash=nil,
        })
    end
    logger.info("[MiuRead][Sync] progress verification cleared", tostring(reason or "cleared"))
end

function Sync:begin_progress_sync(reason)
    -- Reading-time reporting stays independent from progress comparison in
    -- beta.8. Progress checks never make the 60-second timer compute positions.
    self.progress_hold = false
    self.state = "fetching_remote"
    self.last_stage = reason or "读取云端进度"
    return true
end

function Sync:end_progress_sync(reason)
    self.progress_hold = false
    self.last_stage = reason or "阅读进度检查完成"
    self.last_report_clock = os.time()
    if self:periodic_progress_enabled() and not self:is_current_verified() then
        self.state = "verification_required"
        return true
    end
    self.state = self.store:preferences().sync.time_enabled and "waiting" or "stopped"
    if self.store:preferences().sync.time_enabled and not self.suspended then
        self:start("progress_check_finished")
    end
    return true
end

function Sync:_remote_catalog(book_id)
    local record=self:record()
    if not record or tostring(record.book.book_id or "")~=tostring(book_id or "") then return {} end
    local map=select(1,self:_progress_catalog(record))
    if type(map)=="table" and #map>0 then return map end
    return type(record.record and record.record.chapter_map)=="table" and record.record.chapter_map or {}
end

function Sync:_normalize_remote_progress(remote,book_id)
    if type(remote)~="table" then return remote end
    local chapters=self:_remote_catalog(book_id)
    return catalog_progress_from_remote(remote,chapters)
end

function Sync:remote(book_id, callback, options)
    options=options or {}
    local detached=options.detached==true
    local generation_snapshot=tonumber(self.record_generation or 0) or 0
    local current_record=self:record()
    local source_record=type(options.record_snapshot)=="table" and options.record_snapshot or current_record
    if detached and source_record and tostring(source_record.book and source_record.book.book_id or "")~=tostring(book_id or "") then
        source_record=nil
    end
    local path_snapshot=source_record and tostring(source_record.path or "") or ""
    if not detached then
        self.state = "fetching_remote"
        self.last_stage = "读取云端进度"
    end
    local threshold=tonumber(self.store:preferences().sync.threshold) or 2
    local auth_snapshot=self.store:auth()
    local account_snapshot=type(auth_snapshot.account)=="table" and auth_snapshot.account or {}
    local login_snapshot=tostring(auth_snapshot.login_session_id or "")
    local vid_snapshot=tostring(account_snapshot.vid or "")
    local catalog_snapshot
    if type(options.catalog_snapshot)=="table" then
        catalog_snapshot=U.copy(options.catalog_snapshot)
    elseif source_record and tostring(source_record.book and source_record.book.book_id or "")==tostring(book_id or "") then
        local map=select(1,self:_progress_catalog(source_record))
        catalog_snapshot=type(map)=="table" and U.copy(map) or {}
    else
        catalog_snapshot=U.copy(self:_remote_catalog(book_id))
    end
    local resolve_native_progress=options.raw_coordinate~=true
    local record_snapshot=source_record and {
        book=U.copy(source_record.book or {}),
        record=U.copy(source_record.record or {}),
        variant=source_record.variant,
        path=source_record.path,
    } or nil
    local reader_snapshot=self.reader
    local ok, err = self.async:run("remote_progress", function()
        local out={}
        local agent_ok,agent=pcall(self.api.progress,self.api,book_id)
        if agent_ok then out.agent=agent else out.agent_error=tostring(agent) end
        local web_ok,web=pcall(self.api.web_progress,self.api,book_id)
        if web_ok then out.web=web else out.web_error=tostring(web) end

        local function normalize_native(value,source)
            local progress=sourced_progress(value,book_id,source)
            if not progress then return nil end
            if resolve_native_progress and record_snapshot and tonumber(progress.offset)~=nil
                and tostring(progress.chapter_uid or "")~="" and #catalog_snapshot>0 then
                local exact,why=SourcePosition.remoteProgress(
                    reader_snapshot,record_snapshot,progress,catalog_snapshot)
                if exact then return exact end
                progress.native_resolve_error=tostring(why or "remote_native_resolve_failed")
            end
            return catalog_progress_from_remote(progress,catalog_snapshot)
        end
        out.agent_progress=normalize_native(out.agent,"agent_gateway")
        out.web_progress=normalize_native(out.web,"web_cookie")
        return out
    end, function(result)
        local now_record=self:record()
        if not detached and (generation_snapshot~=tonumber(self.record_generation or 0)
            or not now_record or tostring(now_record.book.book_id or "")~=tostring(book_id or "")
            or tostring(now_record.path or "")~=path_snapshot) then
            logger.warn("[MiuRead][Sync] stale remote progress ignored after book switch",
                "book=",tostring(book_id))
            callback(nil,"书籍已切换")
            return
        end
        self.store:reload()
        local current_auth=self.store:auth()
        local current_account=type(current_auth.account)=="table" and current_auth.account or {}
        if login_snapshot=="" or login_snapshot~=tostring(current_auth.login_session_id or "")
            or vid_snapshot~=tostring(current_account.vid or "") then
            logger.warn("[MiuRead][Sync] stale remote progress ignored")
            callback(nil,"登录状态已变化")
            return
        end
        if not detached then self.state = self.progress_hold and "progress_sync" or "waiting" end
        if not result.ok or type(result.value)~="table" then
            local remote_error=result.error or "remote progress unavailable"
            if not detached then self.last_error=remote_error end
            logger.warn("[MiuRead][Sync] remote progress failed", tostring(remote_error))
            if Http.is_auth_error(remote_error) and self.host.on_auth_required then
                pcall(self.host.on_auth_required,self.host,"progress",remote_error)
            end
            callback(nil, remote_error)
            return
        end
        local value=result.value
        local web=value.web_progress or self:_normalize_remote_progress(
            sourced_progress(value.web,book_id,"web_cookie"),book_id)
        local agent=value.agent_progress or self:_normalize_remote_progress(
            sourced_progress(value.agent,book_id,"agent_gateway"),book_id)
        local remote=choose_remote_progress(web,agent,threshold)
        if not remote then
            local remote_error=tostring(value.web_error or value.agent_error or "remote progress unavailable")
            if not detached then self.last_error=remote_error end
            if Http.is_auth_error(remote_error) and self.host.on_auth_required then
                pcall(self.host.on_auth_required,self.host,"progress",remote_error)
            end
            callback(nil,remote_error)
            return
        end
        if not detached then self.last_error=nil end
        if self.host.on_auth_channel_ok then pcall(self.host.on_auth_channel_ok,self.host,"progress") end
        self.store:save_session(book_id,{
            remote=remote,
            remote_sources={web=web,agent=agent},
            remote_checked_at=os.time(),
            remote_web_error=value.web_error,
            remote_agent_error=value.agent_error,
        })
        if remote.conflict then
            logger.warn("[MiuRead][Sync] cloud progress source conflict",
                "book=",tostring(book_id),
                "web=",tostring(web and web.percent or "-"),
                "agent=",tostring(agent and agent.percent or "-"))
        else
            logger.info("[MiuRead][Sync] remote progress", "book=", tostring(book_id),
                "percent=", tostring(remote.percent), "raw_percent=",tostring(remote.raw_percent or "-"),
                "basis=",tostring(remote.position_basis or "raw_percent"),
                "source=",tostring(remote.source or "-"),
                "chapter=", tostring(remote.chapter_uid or "-"),
                "offset=", tostring(remote.offset or "-"), "updated=", tostring(remote.updated_at or "-"))
        end
        callback(remote,nil)
    end, 42)
    if not ok then callback(nil, err) end
end

function Sync:mark_verified(book_id, reason, local_percent, remote_percent, position, options)
    options=type(options)=="table" and options or {}
    book_id = tostring(book_id or "")
    if book_id == "" then return false end
    local verified_at=os.time()
    local verified_local=tonumber(local_percent)
    local verified_remote=tonumber(remote_percent)
    local verified_login=tostring(self.store:auth().login_session_id or "")
    local record_snapshot=type(options.record_snapshot)=="table" and options.record_snapshot or self:record()
    local core_hash=self:_core_map_hash(record_snapshot)
    position=type(position)=="table" and position or nil
    local catalog=type(options.catalog_snapshot)=="table" and options.catalog_snapshot
        or select(1,self:_progress_catalog(record_snapshot))
    local catalog_hash=(type(catalog)=="table" and #catalog>0)
        and BookIntegrity.core_map_hash(book_id,catalog,{}) or ""
    local current=self:record()
    local current_same=current and tostring(current.book and current.book.book_id or "")==book_id
    if options.detached~=true or current_same then
        self.verified_book_id = book_id
        self.verified_at = verified_at
        self.verified_local_percent = verified_local
        self.verified_remote_percent = verified_remote
        self.verified_login_session_id = verified_login
    end
    self.store:save_session(book_id, {
        remote_verified=true, verified_at=verified_at,
        verified_reason=tostring(reason or "confirmed"),
        verified_local_percent=verified_local,
        verified_remote_percent=verified_remote,
        verified_chapter_uid=position and tostring(position.chapter_uid or position.chapterUid or "") or nil,
        verified_chapter_offset=position and tonumber(position.chapter_offset or position.offset) or nil,
        verification_login_session_id=verified_login,
        verified_core_map_hash=core_hash~="" and core_hash or nil,
        verified_catalog_hash=catalog_hash~="" and catalog_hash or nil,
        report_core_map_hash=core_hash~="" and core_hash or nil,
        progress_local_percent=verified_local, pending=false,
    })
    self.store:update_cached_progress(book_id, verified_local)
    logger.info("[MiuRead][Sync] cloud progress verified",
        "book=", book_id, "reason=", tostring(reason or "confirmed"),
        "detached=",tostring(options.detached==true),
        "local=", tostring(verified_local or "-"),
        "remote=", tostring(verified_remote or "-"),
        "chapter=",tostring(position and position.chapter_uid or "-"),
        "offset=",tostring(position and (position.chapter_offset or position.offset) or "-"))
    return true
end

function Sync:_save_local_snapshot(book_id,position)
    if type(position)~="table" or tostring(book_id or "")=="" then return end
    local snapshot=U.copy(position)
    snapshot.captured_at=os.time()
    self.store:save_session(book_id,{local_position_snapshot=snapshot})
end

function Sync:_recover_auth_once(channel,error,on_done,force)
    local now=os.time()
    if self.auth_recovery_busy or (not force and now-(tonumber(self.auth_recovery_at) or 0)<60) then
        if on_done then on_done(false,"登录恢复正在进行或刚刚尝试过") end
        return false
    end
    self.auth_recovery_busy=true
    self.auth_recovery_at=now
    UIManager:scheduleIn(.1,function()
        local called,renewed,detail=pcall(self.reader._recover_login_session,self.reader)
        self.auth_recovery_busy=false
        local success=called and renewed==true
        if success then
            if self.host.on_auth_channel_ok then pcall(self.host.on_auth_channel_ok,self.host,channel) end
            logger.info("[MiuRead][Sync] parent login recovery succeeded","channel=",tostring(channel))
        else
            local reason=called and detail or renewed
            logger.warn("[MiuRead][Sync] parent login recovery failed","channel=",tostring(channel),
                "error=",U.first_line(reason or error,180))
            if not force and self.host.on_auth_required then
                pcall(self.host.on_auth_required,self.host,channel,reason or error)
            end
        end
        if on_done then on_done(success,detail) end
    end)
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

function Sync:_normalize_report_error_kind(kind, err)
    kind=tostring(kind or "")
    if kind=="unconfirmed" then return "unconfirmed" end
    if kind=="position" then return "context" end
    if kind=="authentication" or kind=="context" or kind=="transport" or kind=="server" then return kind end
    err=tostring(err or "")
    if Http.is_auth_error(err) then return "authentication" end
    if Http.is_network_error and Http.is_network_error(err) then return "transport" end
    local lower=err:lower()
    if lower:find("chapter",1,true) or lower:find("context",1,true) or err:find("章节",1,true) then
        return "context"
    end
    return "server"
end

function Sync:_clear_noncontext_repair_flag(book_id, session, reason)
    session=type(session)=="table" and session or self.store:session(book_id) or {}
    if session.sync_repair_required~=true then return false end
    local kind=self:_normalize_report_error_kind(session.sync_repair_kind,session.sync_repair_error)
    if kind=="context" then return false end
    self.store:save_session(book_id,{
        sync_repair_required=false,
        sync_repair_kind=nil,
        sync_repair_error=nil,
        sync_repair_at=nil,
        repair_flag_cleared_at=os.time(),
        repair_flag_cleared_reason=tostring(reason or "transient_failure_reclassified"),
    })
    logger.info("[MiuRead][Sync] cleared legacy transient repair flag",
        "book=",tostring(book_id),"kind=",kind)
    return true
end

function Sync:_record_report_issue(book_id, kind, err, options)
    options=type(options)=="table" and options or {}
    book_id=tostring(book_id or "")
    if book_id=="" then return false end
    kind=self:_normalize_report_error_kind(kind,err)
    err=tostring(err or "阅读同步暂时未完成")
    local session=self.store:session(book_id) or {}
    local failures=(tonumber(session.consecutive_failures) or 0)+1
    local context_failures=tonumber(session.report_context_failures) or 0

    if kind=="unconfirmed" then
        local unconfirmed_count=(tonumber(session.consecutive_unconfirmed) or 0)+1
        self.last_error=nil
        self.last_error_kind=nil
        self.consecutive_failures=0
        self.state=self.progress_hold and "verification_required" or "waiting"
        self.last_stage=unconfirmed_count>=3
            and "云端连续未确认，正在刷新当前书籍同步状态"
            or "微信读书未明确确认本次请求，后续继续同步"
        self.store:save_session(book_id,{
            last_unconfirmed=err,
            last_unconfirmed_at=os.time(),
            consecutive_unconfirmed=unconfirmed_count,
            last_error=false,
            consecutive_failures=0,
            report_state="unconfirmed",
            report_recovery_state=unconfirmed_count>=3 and "refreshing_context" or nil,
        })
        self:_clear_noncontext_repair_flag(book_id,session,"unconfirmed_response")
        return false
    end

    self.last_error=err
    self.last_error_kind=kind
    self.consecutive_failures=failures
    local patch={
        last_error=err,
        last_error_kind=kind,
        last_error_at=os.time(),
        consecutive_failures=failures,
        report_state=kind,
    }
    if kind=="context" then
        context_failures=context_failures+1
        patch.report_context_failures=context_failures
    else
        patch.report_context_failures=0
    end
    self.store:save_session(book_id,patch)

    if kind=="authentication" then
        self.state="waiting"
        self.last_stage="登录状态需要重新验证"
        self:_clear_noncontext_repair_flag(book_id,session,"authentication_failure")
        if self.host.on_auth_required then pcall(self.host.on_auth_required,self.host,"read_report",err) end
        return false
    end
    if kind=="transport" or kind=="server" then
        self.state="waiting"
        self.last_stage=kind=="transport" and "网络暂不可用，稍后自动继续" or "微信读书暂未确认，稍后自动继续"
        self:_clear_noncontext_repair_flag(book_id,session,"transient_failure")
        return false
    end

    -- A real context/position failure is book-specific. Give the automatic
    -- recovery path one chance; only a repeated context failure is allowed to
    -- become a user-facing Repair Sync state.
    if options.force_repair_required==true or context_failures>=2 then
        self:_mark_repair_required(book_id,"context",err,options.suppress_prompt==true)
        return true
    end
    self.state="waiting"
    self.last_stage="当前书籍同步信息异常，等待自动重建"
    return false
end

function Sync:_mark_repair_required(book_id, kind, err, suppress_prompt)
    book_id=tostring(book_id or "")
    if book_id=="" then return false end
    kind=self:_normalize_report_error_kind(kind,err)
    err=tostring(err or "阅读同步失败")
    -- Repair Sync is reserved for book-specific chapter/context corruption.
    -- Network, server and login problems have their own recovery paths.
    if kind~="context" then
        self.store:save_session(book_id,{
            sync_repair_required=false,
            last_error=err,
            last_error_kind=kind,
            last_error_at=os.time(),
            pending_report_seconds=0,
        })
        self.state="waiting"
        return false
    end
    self.last_error=err
    self.last_error_kind=kind
    self.consecutive_failures=math.max(1,tonumber(self.consecutive_failures) or 0)
    self.store:save_session(book_id,{
        sync_repair_required=true,
        sync_repair_kind=kind,
        sync_repair_error=err,
        sync_repair_at=os.time(),
        pending_report_seconds=0,
        last_error=err,
        consecutive_failures=self.consecutive_failures,
    })
    local daemon=self.daemon
    if daemon and tostring(daemon.book_id or "")==book_id and daemon.active then
        daemon.active=false
        self:_write_daemon_control(false,true)
        self.next_due=0
    end
    self.state="repair_required"
    if not suppress_prompt and not self.failure_notified then
        self.failure_notified=true
        if self.host.on_read_report_failure then
            pcall(self.host.on_read_report_failure,self.host,err,kind,book_id)
        end
    end
    return true
end

function Sync:repair_current(callback)
    local record=self:record()
    if not record then if callback then callback(false,"未识别当前觅阅书籍") end; return false end
    local book_id=tostring(record.book.book_id or "")
    if book_id=="" then if callback then callback(false,"当前书籍 ID 无效") end; return false end
    local core_hash=self:_core_map_hash(record)
    if core_hash=="" then if callback then callback(false,"当前书籍章节映射不完整") end; return false end

    -- Automatic repair, manual repair and repeated taps must share one job.
    -- Starting a second transaction used to leave an old verification callback
    -- alive after the first repair had already succeeded.
    if self.repair_busy==true then
        if tostring(self.repair_book_id or "")==book_id then
            logger.info("[MiuRead][SyncRepair] duplicate repair ignored","book=",book_id)
            if callback then callback(false,"检查与修复正在进行",nil,{error_kind="busy",already_running=true}) end
            return true
        end
        logger.info("[MiuRead][SyncRepair] repair busy for another book",
            "active=",tostring(self.repair_book_id or "-"),"requested=",book_id)
        if callback then callback(false,"上一项检查与修复正在结束") end
        return false
    end
    self.repair_busy=true
    self.repair_book_id=book_id
    self.repair_generation=(tonumber(self.repair_generation) or 0)+1
    local generation=self.repair_generation

    local function active()
        return self.repair_busy==true
            and tostring(self.repair_book_id or "")==book_id
            and generation==tonumber(self.repair_generation or 0)
    end
    local function release()
        if generation==tonumber(self.repair_generation or 0) then
            self.repair_busy=false
            self.repair_book_id=nil
        end
    end

    local daemon=self.daemon
    if daemon and daemon.active then
        daemon.active=false
        self:_write_daemon_control(false,true)
        self.next_due=0
    end

    local session=self.store:session(book_id) or {}
    local prior_kind=tostring(session.sync_repair_kind or self.last_error_kind or "")
    local prior_error=tostring(session.sync_repair_error or session.last_error or self.last_error or "")
    self.store:save_session(book_id,{
        last_stage="正在检查登录与当前书籍同步状态",
        pending_report_seconds=0,
        book_core_map_hash=core_hash,
    })
    self.state="repairing"
    self.failure_notified=false

    local finished=false
    local function cancel(result,value)
        if finished or not active() then return end
        finished=true
        release()
        self.state="waiting"
        logger.info("[MiuRead][SyncRepair] cancelled","book=",book_id,"reason=",tostring(result or "cancelled"))
        if callback then callback(false,tostring(result or "检查与修复已取消"),nil,value or {error_kind="cancelled"}) end
    end
    local function fail(result,value)
        if finished or not active() then return end
        finished=true
        release()
        local err=tostring(result or "阅读同步修复失败")
        local kind=(value and value.error_kind) or nil
        if Http.is_auth_error(err) then kind="authentication" end
        kind=self:_normalize_report_error_kind(kind or (err:lower():find("chapter",1,true) and "context" or "server"),err)
        local repair_required=self:_mark_repair_required(book_id,kind,err,true)==true
        self.state=repair_required and "repair_required" or "waiting"
        if callback then callback(false,err,nil,value) end
    end

    local function commit(result,position,value,remote)
        if finished or not active() then return end
        local auth=self.store:auth()
        local login=tostring(auth.login_session_id or "")
        local candidate=value and value.legacy_context
        if type(candidate)~="table" or tostring(candidate.book_id or candidate.bookId or "")~=book_id then
            fail("修复结果缺少当前书籍的有效同步上下文",{error_kind="context"})
            return
        end
        candidate.core_map_hash=core_hash
        finished=true
        release()
        self.store:save_session(book_id,{
            legacy_report_context=U.copy(candidate),
            report_login_session_id=login,
            report_core_map_hash=core_hash,
            book_core_map_hash=core_hash,
            sync_repair_required=false,
            sync_repair_kind=nil,
            sync_repair_error=nil,
            sync_repair_at=nil,
            consecutive_failures=0,
            consecutive_unconfirmed=0,
            report_context_failures=0,
            report_recovery_state=false,
            report_state="ok",
            last_error=false,
            sync_repaired_at=os.time(),
            last_stage="阅读同步已修复并通过云端回读确认",
            pending_report_seconds=0,
            progress_upload_state="verified",
            progress_upload_verified_at=os.time(),
        })
        self.last_error=nil
        self.last_error_kind=nil
        self.consecutive_failures=0
        self.failure_notified=false
        self:mark_verified(book_id,"repair_cloud_verified",position and position.progress,remote and remote.percent,position)
        self.state="waiting"
        if self.store:preferences().sync.time_enabled==true and not self.suspended then
            UIManager:scheduleIn(1,function()
                local current=self:record()
                if current and tostring(current.book and current.book.book_id or "")==book_id then
                    self:start("manual_repair_success")
                end
            end)
        end
        logger.info("[MiuRead][SyncRepair] cloud verification accepted",
            "book=",book_id,
            "chapter=",tostring(position and position.chapter_uid or "-"),
            "progress=",tostring(position and position.progress or "-"))
        if callback then callback(true,result,position,value) end
    end

    local function verify(result,position,value,attempt)
        if not active() then return end
        attempt=tonumber(attempt) or 1
        self.store:save_session(book_id,{last_stage="正在回读微信读书云端位置确认修复结果"})
        UIManager:scheduleIn(attempt==1 and 1.4 or 2.4,function()
            if finished or not active() then return end
            local current=self:record()
            if not current or tostring(current.book.book_id or "")~=book_id then
                cancel("书籍已切换，已取消旧书同步修复",{error_kind="cancelled"})
                return
            end
            self:remote(book_id,function(remote,remote_error)
                if finished or not active() then return end
                local matched,reason=positions_match(position,remote,self.store:preferences().sync.threshold)
                if matched then
                    commit(result,position,value,remote)
                elseif attempt<2 and remote then
                    logger.info("[MiuRead][SyncRepair] cloud verification pending",
                        "book=",book_id,"reason=",tostring(reason))
                    verify(result,position,value,attempt+1)
                else
                    local detail=remote_error or reason or "云端位置未更新"
                    logger.warn("[MiuRead][SyncRepair] cloud verification failed",
                        "book=",book_id,"reason=",tostring(detail),
                        "submitted_uid=",tostring(position and position.chapter_uid or "-"),
                        "remote_uid=",tostring(remote and remote.chapter_uid or "-"),
                        "submitted_progress=",tostring(position and position.progress or "-"),
                        "remote_progress=",tostring(remote and remote.percent or "-"))
                    fail("微信读书已接收请求，但云端位置未与当前书籍一致",{error_kind="context"})
                end
            end,{force=true})
        end)
    end

    local function run_upload(force_context,label)
        if not active() then return false end
        logger.info("[MiuRead][SyncRepair] "..tostring(label or "testing context"),
            "book=",book_id,"core=",core_hash:sub(1,12))
        self.store:save_session(book_id,{last_stage=force_context and "正在重新建立当前书籍章节同步信息" or "正在验证原有章节同步信息"})
        if force_context then
            self.daemon_context=nil
            if daemon and daemon.paths and daemon.paths.context then os.remove(daemon.paths.context) end
        end
        local started=self:upload(0,function(ok,result,position,value)
            if not active() then return end
            if ok then
                verify(result,position,value,1)
                return
            end
            local err=tostring(result or "")
            local kind=tostring((value and value.error_kind) or "")
            if not force_context and kind~="authentication" and not Http.is_auth_error(err) then
                run_upload(true,"rebuilding current book context")
            else
                fail(result,value)
            end
        end,{silent=true,progress_only=true,force_context=force_context,repair=true,transactional_context=true})
        if not started then fail("暂时无法启动阅读同步修复",{error_kind="context"}) end
        return started
    end

    local saved_context=type(session.legacy_report_context)=="table" and session.legacy_report_context or nil
    local auth=self.store:auth()
    local can_preserve=type(saved_context)=="table"
        and tostring(saved_context.book_id or saved_context.bookId or "")==book_id
        and tostring(session.report_login_session_id or "")==tostring(auth.login_session_id or "")
        and tostring(session.report_core_map_hash or "")~=""
        and tostring(session.report_core_map_hash or "")==core_hash

    local function after_auth()
        if not active() then return end
        if can_preserve then
            run_upload(false,"testing preserved context")
        else
            run_upload(true,"rebuilding current book context")
        end
    end

    local needs_auth_check=prior_kind=="authentication" or prior_kind=="context" or Http.is_auth_error(prior_error)
    if needs_auth_check then
        logger.info("[MiuRead][SyncRepair] explicit login renewal requested","book=",book_id,
            "previous_kind=",prior_kind~="" and prior_kind or "unknown")
        self.store:save_session(book_id,{last_stage="正在验证微信读书登录状态"})
        local started=self:_recover_auth_once("read_report",prior_error,function(recovered,detail)
            if not active() then return end
            if recovered then after_auth()
            else fail(tostring(detail or "微信读书登录验证失败"),{error_kind="authentication"}) end
        end,true)
        if not started then fail("登录状态正在处理 请稍后再试",{error_kind="authentication"}) end
        return started
    end

    after_auth()
    return true
end

function Sync:upload(elapsed, callback, options)
    options = options or {}
    local record = type(options.record_override)=="table" and U.copy(options.record_override) or self:record()
    if not record then if callback then callback(false, "未识别到 MiuRead 生成的当前书籍") end; return false end
    if self.progress_hold and not options.progress_only then
        if callback then callback(false, "阅读位置尚未确认") end
        return false
    end
    if self.busy then if callback then callback(false, "同步任务忙") end; return false end

    local book_id = tostring(record.book.book_id)
    local generation_snapshot=tonumber(options.record_generation_override or self.record_generation or 0) or 0
    local path_snapshot=tostring(record.path or "")
    local core_hash=self:_core_map_hash(record)
    local session = self.store:session(book_id) or {}
    if session.sync_repair_required==true and options.repair~=true then
        local repair_kind=self:_normalize_report_error_kind(session.sync_repair_kind,session.sync_repair_error)
        if repair_kind~="context" then
            self:_clear_noncontext_repair_flag(book_id,session,"upload_reclassified")
            session=self.store:session(book_id) or session
        else
            self.last_error=tostring(session.sync_repair_error or "当前书籍需要修复同步")
            self.last_error_kind="context"
            if callback then callback(false,self.last_error) end
            return false
        end
    end
    local auth = self.store:auth()
    local account=type(auth.account)=="table" and auth.account or {}
    local login_snapshot=tostring(auth.login_session_id or "")
    local auth_revision_snapshot=math.max(0,tonumber(auth.auth_revision or 0) or 0)
    local vid_snapshot=tostring(account.vid or "")
    if login_snapshot=="" or vid_snapshot=="" then
        if callback then callback(false,"当前登录记录不完整，请先在账号状态中重新检查；仍无法恢复时再重新扫码") end
        return false
    end
    local ratio = type(options.position_override)=="table" and tonumber(options.position_override.progress)
        and U.clamp((tonumber(options.position_override.progress) or 0)/100,0,1)
        or self:local_ratio() or 0
    local auth_channel=options.progress_only and "progress" or "read_report"
    local chapters = (record.record and record.record.chapter_map) or record.book.catalog or {}
    -- Keep the old worker's own field names and cached context isolated from
    -- MiuRead's newer protocol model. On first use it refreshes the reader page,
    -- catalog and reporting context through the isolated compatibility worker.
    local saved_context=type(session.legacy_report_context)=="table" and session.legacy_report_context or nil
    local context_matches=tostring(session.report_login_session_id or "")==login_snapshot
        and tostring(session.report_core_map_hash or "")~=""
        and tostring(session.report_core_map_hash or "")==tostring(core_hash or "")
        and type(saved_context)=="table"
        and tostring(saved_context.book_id or saved_context.bookId or "")==book_id
        and (tostring(saved_context.core_map_hash or "")==""
            or tostring(saved_context.core_map_hash or "")==tostring(core_hash or ""))
    local legacy_book = U.copy(context_matches and saved_context or {})
    legacy_book.book_id = book_id
    legacy_book.title = record.book.title
    self:_decorate_legacy_context(legacy_book, record)
    local position_snapshot=type(options.position_override)=="table" and U.copy(options.position_override)
        or self:_position_for_report(ratio,options.precise_position==true or options.progress_only==true)
    self:_save_local_snapshot(book_id,position_snapshot)
    if type(position_snapshot)~="table" or position_snapshot.safe~=true or position_snapshot.progress==nil
        or tostring(position_snapshot.chapter_uid or "")=="" then
        local mapping_error=type(position_snapshot)=="table" and position_snapshot.mapping_error or "position_unavailable"
        local message="当前书籍无法可靠换算微信读书整书进度"
            ..(mapping_error and ("（"..tostring(mapping_error).."）") or "")
        self.last_error=message
        self.last_error_kind="context"
        if callback then callback(false,message,position_snapshot,{error_kind="context"}) end
        return false
    end
    legacy_book.local_chapter_uid=position_snapshot.chapter_uid
    legacy_book.local_chapter_idx=position_snapshot.chapter_index or position_snapshot.chapter_idx
    legacy_book.local_chapter_offset=position_snapshot.offset or position_snapshot.chapter_offset
    legacy_book.local_chapter_word_count=position_snapshot.chapter_word_count
    legacy_book.local_native_chapter_offset=position_snapshot.native_offset == true
    legacy_book.local_chapter_offset_basis=position_snapshot.offset_basis or position_snapshot.position_basis
    legacy_book.progress=position_snapshot.progress
    legacy_book.core_map_hash=core_hash
    local report_ratio=report_ratio_from_position(position_snapshot)

    self.busy, self.state, self.last_attempt = true, options.progress_only and "progress_uploading" or "uploading", os.time()
    self.last_stage = options.progress_only and "主动提交阅读进度" or "调用兼容阅读时间上传链路"
    local ok, err = self.async:run("legacy_read_report", function()
        return ReadReportWorker.run{
            book_id = book_id,
            book_title = record.book.title,
            book = legacy_book,
            core_map_hash = core_hash,
            progress_ratio = report_ratio,
            elapsed_seconds = elapsed or 0,
            cookies = auth.cookies or {},
            api_key = auth.api_key or "",
            wr_ticket = auth.wr_ticket or "",
            wr_wrpa = auth.wr_wrpa or "",
            allow_renewal = false,
            force_context = options.force_context == true,
        }
    end, function(result)
        self.busy = false
        local current_record=self:record()
        local same_book=current_record
            and tostring(current_record.book.book_id or "")==book_id
            and tostring(current_record.path or "")==path_snapshot
        local generation_changed=generation_snapshot~=tonumber(self.record_generation or 0)
        local allow_same_book_generation=options.allow_same_book_generation_change==true and same_book
        local allow_detached_result=options.allow_book_switch_result==true
        local detached_result=allow_detached_result and (not same_book or generation_changed)
        local previous_state,previous_last_stage=self.state,self.last_stage
        local previous_last_error,previous_last_error_kind=self.last_error,self.last_error_kind
        local previous_failures,previous_failure_notified=self.consecutive_failures,self.failure_notified
        local previous_last_path,previous_response=self.last_path,self.last_response_summary
        local previous_http_code,previous_http_length=self.last_http_code,self.last_http_length
        local function restore_detached_state()
            if not detached_result then return end
            self.state=previous_state
            self.last_stage=previous_last_stage
            self.last_error=previous_last_error
            self.last_error_kind=previous_last_error_kind
            self.consecutive_failures=previous_failures
            self.failure_notified=previous_failure_notified
            self.last_path=previous_last_path
            self.last_response_summary=previous_response
            self.last_http_code=previous_http_code
            self.last_http_length=previous_http_length
        end
        local function emit_callback(...)
            restore_detached_state()
            if callback then callback(...) end
        end
        if not detached_result then self.state = self.progress_hold and "verification_required" or "waiting" end
        if (not same_book or (generation_changed and not allow_same_book_generation)) and not allow_detached_result then
            logger.warn("[MiuRead][ReadReport] stale book worker result ignored",
                "book=",book_id,"generation=",tostring(generation_snapshot))
            emit_callback(false,"书籍已切换，本次旧同步结果已忽略")
            return
        end
        if allow_detached_result and (not same_book or generation_changed) then
            logger.info("[MiuRead][ReadingEnd] detached upload result retained",
                "book=",book_id,"generation=",tostring(generation_snapshot),
                "current_generation=",tostring(self.record_generation or 0))
        elseif generation_changed and allow_same_book_generation then
            logger.info("[MiuRead][ReadingEnd] same-book generation advanced; final result retained",
                "book=",book_id,"from=",tostring(generation_snapshot),
                "to=",tostring(self.record_generation or 0))
        end
        self.store:reload()
        local current_auth=self.store:auth()
        local current_account=type(current_auth.account)=="table" and current_auth.account or {}
        if login_snapshot~=tostring(current_auth.login_session_id or "")
            or auth_revision_snapshot~=math.max(0,tonumber(current_auth.auth_revision or 0) or 0)
            or vid_snapshot~=tostring(current_account.vid or "") then
            logger.warn("[MiuRead][ReadReport] stale worker result ignored")
            emit_callback(false,"登录状态已变化")
            return
        end
        if not result.ok or type(result.value) ~= "table" then
            self.last_error = result.error or "阅读同步工作器无结果"
            self.last_stage = "同步工作器失败"
            local kind=Http.is_auth_error(self.last_error) and "authentication"
                or ((Http.is_network_error and Http.is_network_error(self.last_error)) and "transport" or "context")
            logger.warn("[MiuRead][ReadReport] worker failed", tostring(self.last_error))
            self:_record_report_issue(book_id,kind,self.last_error,{
                force_repair_required=options.repair==true,
                suppress_prompt=options.repair==true,
            })
            emit_callback(false, self.last_error)
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
            local saved_auth,save_error=self.store:save_auth(latest_auth,{expected_revision=auth_revision_snapshot})
            if saved_auth~=true then
                logger.warn("[MiuRead][ReadReport] stale worker credential update ignored",U.first_line(save_error or "",120))
            end
        end
        local attempts_count = #(value.attempts or {})
        local public = value.payload_public or {}
        self.last_path = value.path
        self.last_response_summary = value.response_summary or value.error
        self.last_http_code = value.meta and value.meta.code or nil
        self.last_http_length = value.meta and value.meta.length or nil
        self.last_stage = value.accepted and "兼容上传链路已确认"
            or (tostring(value.path or ""):find("context", 1, true) and "兼容上传上下文失败"
            or "兼容上传链路被服务端拒绝")

        local diagnostic_patch={
            last_attempt=self.last_attempt,
            last_path=value.path,
            last_attempts=attempts_count,
            last_stage=self.last_stage,
            last_response_summary=self.last_response_summary,
            last_http_code=self.last_http_code,
            last_http_length=self.last_http_length,
            last_payload_public=public,
        }
        if options.transactional_context~=true and value.accepted==true then
            diagnostic_patch.legacy_report_context=legacy_context
            diagnostic_patch.report_login_session_id=login_snapshot
            diagnostic_patch.report_core_map_hash=core_hash
        end
        self.store:save_session(book_id,diagnostic_patch)

        if value.uncertain==true or tostring(value.error_kind or "")=="unconfirmed" then
            local target_label=options.progress_only and "阅读进度" or "阅读时长"
            local message="微信读书未明确确认本次"..target_label.."（"..tostring(value.error or "无明确回执").."）"
            self.last_response_summary=value.response_summary or value.error
            self:_record_report_issue(book_id,"unconfirmed",message)
            self.store:save_session(book_id,{
                last_response_summary=self.last_response_summary,
                last_http_code=self.last_http_code,
                last_http_length=self.last_http_length,
                last_payload_public=public,
                progress_upload_state=options.progress_only and "unconfirmed" or nil,
            })
            logger.warn("[MiuRead][ReadReport] unconfirmed",
                "book=",book_id,"target=",target_label,
                "ci=",tostring(public.ci or "-"),"co=",tostring(public.co or "-"),
                "pr=",tostring(public.pr or "-"),"summary=",tostring(self.last_response_summary or "-"))
            -- A progress-only request can be safely checked by reading cloud
            -- position. A reading-time interval must not be replayed because it
            -- may already have been accepted server-side.
            if options.progress_only then emit_callback(true,value.response or {},position,value)
            else emit_callback(false,message,position,value) end
            return
        end

        if not value.accepted then
            local rejected_auth=tostring(value.error_kind or "")=="authentication" or Http.is_auth_error(value.error)
            local target_label=options.progress_only and "阅读进度" or "阅读时长"
            self.last_error = "微信读书未确认接收"..target_label.."（" .. tostring(value.error or "unknown") .. "）"
            self.last_error_kind=rejected_auth and "authentication" or self:_normalize_report_error_kind(value.error_kind,value.error)
            self.store:save_session(book_id, {
                last_error=self.last_error,
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
                "fields_complete=", tostring(public.payload_fields_complete == true),
                "position_source=", tostring(public.position_source or "-"),
                "report_uid=", tostring(public.report_chapter_uid or "-"),
                "report_idx=", tostring(public.report_chapter_idx or "-"),
                "local_uid=", tostring(public.local_chapter_uid or "-"),
                "local_idx=", tostring(public.local_chapter_idx or "-"),
                "remote_uid=", tostring(public.remote_chapter_uid or "-"),
                "remote_idx=", tostring(public.remote_chapter_idx or "-"))
            self:_record_report_issue(book_id,self.last_error_kind,self.last_error,{
                force_repair_required=options.repair==true,
                suppress_prompt=options.repair==true,
            })
            emit_callback(false, self.last_error, position, value)
            return
        end

        local response = value.response or {}
        local completed_at=os.time()
        self.last_error = nil
        self.consecutive_failures = 0
        if self.host.on_auth_channel_ok then pcall(self.host.on_auth_channel_ok,self.host,"read_report") end
        self.failure_notified = false
        local patch={
            local_percent=position.progress,
            pending=nil,
            synckey=response_synckey(response) or legacy_context.synckey or session.synckey,
            last_error=false,
            consecutive_failures=0,
            consecutive_unconfirmed=0,
            report_recovery_state=false,
            last_path=value.path,
            last_attempts=attempts_count,
            last_response_summary=self.last_response_summary,
            last_http_code=self.last_http_code,
            last_http_length=self.last_http_length,
            last_payload_public=public,
            book_core_map_hash=core_hash,
        }
        if options.transactional_context~=true then
            patch.legacy_report_context=legacy_context
            patch.report_login_session_id=login_snapshot
            patch.report_core_map_hash=core_hash
            patch.sync_repair_required=false
            patch.sync_repair_kind=nil
            patch.sync_repair_error=nil
            patch.sync_repair_at=nil
            patch.report_context_failures=0
            patch.report_state="ok"
        end
        if options.progress_only then
            patch.progress_upload_at=completed_at
            patch.progress_upload_percent=position.progress
            patch.progress_upload_state="submitted"
            self.last_stage="阅读进度已提交，等待云端确认"
            logger.info("[MiuRead][Progress] submit accepted",
                "book=",tostring(book_id),"progress=",tostring(position.progress),
                "path=",tostring(value.path),"attempts=",tostring(attempts_count))
        else
            self.session_uploads = self.session_uploads + 1
            self.last_upload = completed_at
            patch.last_upload=self.last_upload
            logger.info("[MiuRead][ReadReport] success", "count=", tostring(self.session_uploads),
                "book=", tostring(book_id), "elapsed=", tostring(elapsed or 0),
                "progress=", tostring(position.progress), "path=", tostring(value.path),
                "attempts=", tostring(attempts_count))
        end
        self.store:save_session(book_id,patch)
        if not options.progress_only and not self.first_success_notified and not options.silent then
            self.first_success_notified = true
            if self.host.on_read_report_success then pcall(self.host.on_read_report_success, self.host, value.path) end
        end
        emit_callback(true, response, position, value)
    end, 95)

    if not ok then
        self.busy = false
        self.last_error = err
        if callback then callback(false, err) end
        return false
    end
    return true
end

function Sync:upload_progress(callback, options)
    options = options or {}
    self.state = "progress_locating"
    self.last_stage = "正在定位当前阅读位置"
    local detached=options.detached==true or options.reading_end==true
    if type(options.position_override) == "table" then
        return self:upload(0,callback,{
            silent=true,progress_only=true,
            position_override=options.position_override,
            record_override=options.record_override,
            record_generation_override=options.record_generation_override,
            allow_same_book_generation_change=detached,
            allow_book_switch_result=detached,
        })
    end
    local started, resolve_error = self:resolve_local_progress(function(position, err, meta)
        if not position then
            if callback then callback(false,err,nil,{error_kind=meta and meta.error_kind or "position"}) end
            return
        end
        self:upload(0,callback,{
            silent=true,progress_only=true,
            position_override=position,
            allow_same_book_generation_change=detached,
            allow_book_switch_result=detached,
        })
    end,{
        precise=true,
        prepare_catalog=true,
        require_cloud_coordinate=true,
        on_stage=options.on_stage,
    })
    if not started then
        if callback then callback(false,resolve_error,nil,{error_kind="busy"}) end
        return false
    end
    return true
end

function Sync:_notify_failure()
    local record=self:record()
    local book_id=record and record.book and record.book.book_id
    if book_id then self:_mark_repair_required(book_id,self.last_error_kind or "server",self.last_error) end
end

function Sync:test_upload(callback)
    local record=self:record()
    if not record then if callback then callback(false,"未识别到 MiuRead 生成的当前书籍") end; return false end
    if not self:_read_report_allowed(record) then
        if callback then callback(false,"当前章节版仅同步阅读进度，不上传阅读时间") end
        return false
    end
    if self.busy or (self.async and self.async:busy()) then
        if callback then callback(false,"同步任务忙") end
        return false
    end
    local auth=self.store:auth()
    local account=type(auth.account)=="table" and auth.account or {}
    if tostring(auth.login_session_id or "")=="" or tostring(account.vid or "")=="" then
        if callback then callback(false,"当前登录记录不完整，请先在账号状态中重新检查；仍无法恢复时再重新扫码") end
        return false
    end
    local book_id=tostring(record.book.book_id or "")
    local core_hash=self:_core_map_hash(record)
    local legacy_book={book_id=book_id,title=record.book.title,core_map_hash=core_hash}
    local restart=self.daemon and self.daemon.active==true
    if restart then self:_stop_daemon("manual_time_only_test",true,0) end
    self.busy=true
    self.state="uploading"
    self.last_stage="测试纯阅读时间上传"
    local started,err=self.async:run("time_only_read_report_test",function()
        return ReadReportWorker.run{
            book_id=book_id,book_title=record.book.title,book=legacy_book,
            core_map_hash=core_hash,progress_ratio=nil,elapsed_seconds=30,time_only=true,
            cookies=auth.cookies or {},api_key=auth.api_key or "",
            wr_ticket=auth.wr_ticket or "",wr_wrpa=auth.wr_wrpa or "",
            allow_renewal=false,force_context=false,
        }
    end,function(result)
        self.busy=false
        self.state="waiting"
        local value=result and result.ok==true and result.value or nil
        local ok=value and value.accepted==true or false
        if restart and self.store:preferences().sync.time_enabled and not self.suspended then
            self:start("manual_time_only_test_finished")
        end
        if callback then
            if ok then callback(true,value.response or {},nil,value)
            else callback(false,(value and value.error) or (result and result.error) or "纯阅读时间上传失败",nil,value) end
        end
    end,95)
    if not started then
        self.busy=false
        if restart and self.store:preferences().sync.time_enabled and not self.suspended then self:start("manual_time_only_test_failed") end
        if callback then callback(false,err or "无法启动纯阅读时间测试") end
        return false
    end
    return true
end

function Sync:compare(local_percent, remote)
    if not remote then return "unknown" end
    local delta = (tonumber(remote.percent) or 0) - (tonumber(local_percent) or 0)
    local threshold = tonumber(self.store:preferences().sync.threshold) or 2
    if math.abs(delta) <= threshold then return "same" end
    return delta > 0 and "remote_ahead" or "local_ahead"
end

function Sync:jump(percent)
    -- KOReader accepts fractional GotoPercent values. Do not round this to an
    -- integer: +/-0.5% of a long book is several phone pages and was the last
    -- visible book-length-dependent error in cloud -> local positioning.
    percent = U.clamp(tonumber(percent) or 0, 0, 100)
    local ui = self.host.ui
    if not ui or not ui.document then return false end
    logger.info("[MiuRead][ProgressJump]",
        "percent=", string.format("%.6f", percent),
        "ratio_source=", tostring(self.last_local_ratio_source or "-"))
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

function Sync:_retire_legacy_daemon()
    -- Stop workers created by every earlier service layout before starting the
    -- current one. Their job files contain credential snapshots; leaving an old
    -- worker alive across OTA would defeat the auth-revision barrier.
    local base = self.store.temp_dir .. "/readtime-service"
    local retired={}
    local suffixes={""}
    for version=1,READ_REPORT_SERVICE_VERSION-1 do suffixes[#suffixes+1]="-v"..tostring(version) end
    for _, suffix in ipairs(suffixes) do
        local prefix=base..suffix
        local owner_path=prefix..".owner.json"
        retired[#retired+1]={
            job=prefix..".job.json",control=prefix..".control.json",status=prefix..".status.json",
            context=prefix..".context.json",stop=prefix..".stop",owner=owner_path,lock=prefix..".lock",
        }
        local generation=2147483000
        U.atomic_write(prefix..".job.json",Json.encode({
            generation=generation,controller_token="retired",book_id="",book={},auth={},interval=Config.READ_INTERVAL,
        }),true)
        U.atomic_write(prefix..".control.json",Json.encode({
            active=false,generation=generation,controller_token="retired",updated_at=os.time(),
        }),true)
        U.atomic_write(prefix..".stop", "1", true)
        -- Status/context may contain old cookies or report tokens. They are not
        -- needed once the worker has been retired, so remove them immediately.
        os.remove(prefix..".status.json")
        os.remove(prefix..".context.json")
    end
    local function purge()
        for _,paths in ipairs(retired) do
            local owner=read_json_file(paths.owner)
            if not owner or not process_alive(owner.pid) then
                os.remove(paths.job); os.remove(paths.control); os.remove(paths.status)
                os.remove(paths.context); os.remove(paths.stop); os.remove(paths.owner)
                remove_lock_dir(paths.lock)
            end
        end
    end
    purge()
    UIManager:scheduleIn(4,purge)
    UIManager:scheduleIn(15,purge)
end

function Sync:_daemon_paths()
    -- One versioned service per KOReader process. The version suffix prevents
    -- an OTA reload from reusing a worker created by older plugin code.
    local base = self.store.temp_dir .. "/readtime-service-v"
        .. tostring(READ_REPORT_SERVICE_VERSION)
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
    if tonumber(owner.service_version or 0) ~= READ_REPORT_SERVICE_VERSION then return false end
    local parent_pid = current_pid()
    if tonumber(owner.parent_pid or 0) ~= tonumber(parent_pid or 0) then return false end
    local control = read_json_file(paths.control) or {}
    local job = read_json_file(paths.job) or {}
    self.daemon = {
        pid=tonumber(owner.pid), paths=paths, active=false,
        generation=tonumber(control.generation or 0) or 0,
        book_id=nil, interval=Config.READ_INTERVAL, reason="reused", is_child=false,
        service_version=READ_REPORT_SERVICE_VERSION,
        login_session_id=tostring(job.login_session_id or ""),
        auth_revision=math.max(0,tonumber(job.auth_revision or 0) or 0),
        account_vid=tostring(job.account_vid or ""),
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
        service_version = READ_REPORT_SERVICE_VERSION,
        poll_interval = 1,
        job_path = paths.job,
        control_path = paths.control,
        status_path = paths.status,
        context_path = paths.context,
        stop_path = paths.stop,
        owner_path = paths.owner,
        lock_path = paths.lock,
        reader_busy_path = "/tmp/miuread-reader-busy.until",
    }
    local child = function()
        -- A forked long-lived worker must not retain KOReader listeners such as
        -- HTTP Inspector :8080. Open its own sockets only after this boundary.
        SubprocessHygiene.close_inherited_sockets()
        return ReadReportService.run(service_job)
    end
    local ok, pid, err = pcall(FFIUtil.runInSubProcess, child, false, false)
    if not ok or not pid then
        os.remove(paths.owner)
        remove_lock_dir(paths.lock)
        self.last_error = tostring(err or pid or "无法启动后台阅读时间服务")
        return false, self.last_error
    end
    U.atomic_write(paths.owner, Json.encode({
        pid=pid, parent_pid=current_pid(), started_at=os.time(),
        service_version=READ_REPORT_SERVICE_VERSION,
    }), true)
    self.daemon = {
        pid=pid, paths=paths, active=false, generation=0,
        book_id=nil, interval=Config.READ_INTERVAL, reason="prestarted", is_child=true,
        service_version=READ_REPORT_SERVICE_VERSION,
    }
    self.daemon_status_stamp = nil
    self:_schedule_daemon_poll(10)
    logger.info("[MiuRead][ReadReport] lightweight service started", "pid=", tostring(pid))
    return true
end

function Sync:progress_mode()
    local prefs=self.store:preferences().sync or {}
    local mode=tostring(prefs.progress_mode or "")
    if mode=="continuous" then return "close" end
    if mode=="close" or mode=="manual" then return mode end
    return prefs.progress_enabled==false and "manual" or "close"
end

function Sync:periodic_progress_enabled()
    -- beta.8 keeps the reading-time daemon permanently time-only. Exact cloud
    -- coordinates are resolved only for manual or end-of-reading submissions.
    return false
end

function Sync:_write_daemon_control(active, immediate, extra)
    local daemon = self.daemon
    if not daemon and not self:_ensure_daemon() then return false end
    daemon = self.daemon
    if not daemon then return false end
    extra = type(extra) == "table" and extra or {}
    local precise_position = extra._precise_position == true
    local position_override = type(extra._position_override) == "table"
        and U.copy(extra._position_override) or nil
    local time_only = extra._time_only == true or not self:periodic_progress_enabled()

    local function write_now()
        self.control_write_task = nil
        local d = self.daemon
        if not d then return end
        local existing = read_json_file(d.paths.control) or {}
        local existing_generation = tonumber(existing.generation or 0) or 0
        local own_generation = tonumber(d.generation or 0) or 0
        if existing_generation > own_generation then return end
        if existing_generation == own_generation
            and tostring(existing.controller_token or "") ~= ""
            and tostring(existing.controller_token or "") ~= tostring(self.controller_token)
        then return end
        local auth=self.store:auth()
        local account=type(auth.account)=="table" and auth.account or {}
        local book_id=tostring(d.book_id or d.final_book_id or "")
        local position=nil
        if not time_only then
            local record=self:record()
            if record and book_id~="" and tostring(record.book.book_id or "")==book_id then
                position=position_override or self:_position_for_report(nil,precise_position)
                if type(position)=="table" and position.safe==true then
                    self:_save_local_snapshot(book_id,position)
                else
                    position=nil
                end
            end
        end
        local native_offset_flag = existing.local_native_chapter_offset == true
        if position then native_offset_flag = position.native_offset == true end
        local control = {
            active = active ~= false and d.active == true,
            generation = own_generation,
            controller_token = self.controller_token,
            login_session_id = tostring(d.login_session_id or auth.login_session_id or ""),
            auth_revision = math.max(0,tonumber(d.auth_revision or auth.auth_revision or 0) or 0),
            account_vid = tostring(d.account_vid or account.vid or ""),
            book_id = book_id,
            core_map_hash = tostring(d.core_map_hash or existing.core_map_hash or ""),
            record_generation = tonumber(d.record_generation or existing.record_generation or 0) or 0,
            time_only = time_only,
            progress_ratio = position and report_ratio_from_position(position) or tonumber(existing.progress_ratio) or 0,
            local_chapter_uid = position and position.chapter_uid or existing.local_chapter_uid,
            local_chapter_idx = position and position.chapter_index or existing.local_chapter_idx,
            local_chapter_offset = position and (position.chapter_offset or position.offset) or existing.local_chapter_offset,
            local_chapter_word_count = position and position.chapter_word_count or existing.local_chapter_word_count,
            local_native_chapter_offset = native_offset_flag,
            local_chapter_offset_basis = position and (position.offset_basis or position.position_basis or "") or existing.local_chapter_offset_basis,
            position_source = position and position.source or existing.position_source,
            position_basis = position and position.position_basis or existing.position_basis,
            position_precision_ms = position and position.precision_ms or existing.position_precision_ms,
            position_safe = time_only or (position and true or existing.position_safe==true),
            last_activity = tonumber(self.last_activity) or os.time(),
            updated_at = os.time(),
        }
        for key, value in pairs(extra) do
            if key ~= "_precise_position" and key ~= "_position_override" and key ~= "_time_only" then
                control[key] = value
            end
        end
        if control.active and not time_only and (not position or tostring(control.local_chapter_uid or "")=="") then
            control.active=false
            control.position_safe=false
        end
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
    UIManager:scheduleIn(tonumber(Config.CONTROL_WRITE_DELAY) or 60, task)
    return true
end

function Sync:_persist_daemon_session(force, explicit_book_id)
    local daemon = self.daemon
    local book_id = explicit_book_id or (daemon and (daemon.book_id or daemon.final_book_id))
    if not book_id or not daemon then return end
    local now = os.time()
    if not force and now - (tonumber(self.daemon_last_persist) or 0) < 300 then return end
    self.daemon_last_persist = now
    local patch={
        last_attempt = self.last_attempt,
        last_upload = self.last_upload,
        last_path = self.last_path,
        last_stage = self.last_stage,
        last_response_summary = self.last_response_summary,
        last_error = self.last_error or false,
        consecutive_failures = self.consecutive_failures,
        book_core_map_hash=tostring(daemon.core_map_hash or ""),
    }
    local context=self.daemon_context
    if type(context)=="table"
        and tostring(context.book_id or context.bookId or "")==tostring(book_id)
        and tostring(context.core_map_hash or "")==tostring(daemon.core_map_hash or "") then
        patch.legacy_report_context=context
        patch.report_login_session_id=tostring(daemon.login_session_id or "")
        patch.report_core_map_hash=tostring(daemon.core_map_hash or "")
    end
    self.store:save_session(book_id,patch)
end

function Sync:_load_daemon_context()
    local daemon = self.daemon
    if not daemon then return end
    local context_raw = U.read_file(daemon.paths.context, true)
    if not context_raw then return end
    local context_ok, envelope = pcall(Json.decode, context_raw)
    if not context_ok or type(envelope) ~= "table" then return end
    local auth=self.store:auth()
    local account=type(auth.account)=="table" and auth.account or {}
    if tonumber(envelope.generation or -1)~=tonumber(daemon.generation or 0)
        or tostring(envelope.controller_token or "")~=tostring(self.controller_token or "")
        or tostring(envelope.login_session_id or "")~=tostring(auth.login_session_id or "")
        or math.max(0,tonumber(envelope.auth_revision or 0) or 0)~=math.max(0,tonumber(auth.auth_revision or 0) or 0)
        or tostring(envelope.account_vid or "")~=tostring(account.vid or "")
        or tostring(envelope.book_id or "")~=tostring(daemon.book_id or daemon.final_book_id or "")
        or tostring(envelope.core_map_hash or "")~=tostring(daemon.core_map_hash or "") then
        logger.warn("[MiuRead][ReadReport] stale daemon context ignored",
            "book=",tostring(envelope.book_id or "-"),"core=",tostring(envelope.core_map_hash or "-"):sub(1,12))
        return
    end
    if type(envelope.context)=="table"
        and tostring(envelope.context.book_id or envelope.context.bookId or "")==tostring(envelope.book_id or "")
        and tostring(envelope.context.core_map_hash or "")==tostring(envelope.core_map_hash or "") then
        self.daemon_context=U.copy(envelope.context)
    end
end

function Sync:_import_daemon_status(force)
    local daemon = self.daemon
    if not daemon then return end
    local raw = U.read_file(daemon.paths.status, true)
    if not raw then return end
    local ok, status = pcall(Json.decode, raw)
    if not ok or type(status) ~= "table" then return end
    if self.auth_transitioning then return end
    if tonumber(status.generation or -1) ~= tonumber(daemon.generation or 0) then return end
    if tostring(status.controller_token or "")~=tostring(self.controller_token or "") then return end
    local auth=self.store:auth()
    local account=type(auth.account)=="table" and auth.account or {}
    local current_session=tostring(auth.login_session_id or "")
    local current_revision=math.max(0,tonumber(auth.auth_revision or 0) or 0)
    local current_vid=tostring(account.vid or "")
    if current_session=="" or current_vid==""
        or tostring(status.login_session_id or "")~=current_session
        or math.max(0,tonumber(status.auth_revision or 0) or 0)~=current_revision
        or tostring(status.account_vid or "")~=current_vid then
        logger.warn("[MiuRead][ReadReport] stale login status ignored",
            "status_session=",tostring(status.login_session_id or ""),
            "current_session=",current_session)
        return
    end

    local status_book_id = tostring(status.book_id or daemon.book_id or daemon.final_book_id or "")
    local expected_book_id=tostring(daemon.book_id or daemon.final_book_id or "")
    if status_book_id~="" and expected_book_id~="" and status_book_id~=expected_book_id then return end
    if tostring(status.core_map_hash or "")~=tostring(daemon.core_map_hash or "") then
        logger.warn("[MiuRead][ReadReport] stale core-map status ignored",
            "book=",status_book_id,"status_core=",tostring(status.core_map_hash or "-"):sub(1,12),
            "current_core=",tostring(daemon.core_map_hash or "-"):sub(1,12))
        return
    end
    local final_flush = status.final_flush == true
    local barrier_seq=tonumber(status.writer_barrier_seq or 0) or 0
    if barrier_seq>0 and tostring(status.state or "")~="reporting" then
        daemon.writer_barrier_ack_seq=math.max(tonumber(daemon.writer_barrier_ack_seq or 0) or 0,barrier_seq)
    end
    local stamp = daemon_stamp(status)
    if final_flush and stamp and self.store:is_read_report_consumed(stamp) then
        self.daemon_status_stamp=stamp
        daemon.final_flush_pending=false
        if not daemon.active then daemon.book_id=nil end
        if force then self:_load_daemon_context() end
        return
    end
    if stamp and stamp == self.daemon_status_stamp then
        if force then
            self:_load_daemon_context()
            self:_persist_daemon_session(true, status_book_id ~= "" and status_book_id or nil)
        end
        return
    end
    self.daemon_status_stamp = stamp

    if status.context_changed or force then self:_load_daemon_context() end
    self.next_due = tonumber(status.next_due) or self.next_due or 0
    if status_book_id~="" then
        self.pending_report_elapsed=0
        self.pending_report_status_at=tonumber(status.completed_at) or os.time()
        -- beta.24 never persists report carry. Older status files may still
        -- advertise carry_consumed after OTA, but they are normalized to zero.
        if status.carry_consumed == true then
            self.store:save_session(status_book_id,{pending_report_seconds=0})
        end
    end
    if status.state == "service_waiting" or status.state == "inactive" then
        if final_flush then
            daemon.final_flush_pending = false
            if not daemon.active then daemon.book_id = nil end
        end
        if not daemon.active then self.state = "stopped" end
        return
    elseif status.state == "waiting" and status.accepted == nil then
        if daemon.active then self.state = "waiting" end
        return
    elseif status.state == "service_stopped" then
        self.state = "stopped"
        return
    end

    if not daemon.active and not final_flush then return end
    self.last_attempt = tonumber(status.attempted_at) or self.last_attempt
    self.last_path = status.path or self.last_path
    self.last_response_summary = status.response_summary or status.error or self.last_response_summary
    if final_flush then
        self.last_stage = status.accepted and "关闭前阅读时间上传成功" or "关闭前阅读时间上传失败"
    else
        self.last_stage = status.accepted and "兼容上传链路已确认" or "后台上传失败"
    end

    if status.cookies_changed or status.wr_ticket_changed or status.wr_wrpa_changed then
        -- The long-lived service is not an authentication authority. It may use
        -- response cookies inside its own current job, but it is never allowed
        -- to overwrite the parent's durable credentials. Renewal/relogin is
        -- serialized by the parent and then pushed back as a new job revision.
        logger.info("[MiuRead][ReadReport] background credential update kept local",
            "revision=",tostring(status.auth_revision or 0))
    end

    if status.accepted then
        self.pending_report_elapsed=0
        self.pending_report_status_at=tonumber(status.completed_at) or os.time()
        self.state = daemon.active and "waiting" or "stopped"
        self.session_uploads = self.session_uploads + 1
        self.last_upload = tonumber(status.completed_at) or os.time()
        self.last_error = nil
        self.last_error_kind = nil
        self.consecutive_failures = 0
        self.failure_notified = false
        if self.host.on_auth_channel_ok then pcall(self.host.on_auth_channel_ok,self.host,"read_report") end
        if status_book_id ~= "" then
            self.store:save_session(status_book_id, {
                last_error=false,
                last_error_kind=false,
                consecutive_failures=0,
                consecutive_unconfirmed=0,
                report_context_failures=0,
                report_recovery_state=false,
                report_state="ok",
                last_upload=self.last_upload,
                last_elapsed=tonumber(status.elapsed_seconds),
                last_report_reason=final_flush and tostring(status.flush_reason or "stop") or "interval",
            })
        end
        if not final_flush and self.host.on_read_report_interval_success then
            pcall(self.host.on_read_report_interval_success,self.host,status)
        end
        if final_flush then
            logger.info("[MiuRead][ReadingTime] final flush success",
                "book=", status_book_id, "elapsed=", tostring(status.elapsed_seconds or "-"),
                "reason=", tostring(status.flush_reason or "stop"),
                "path=", tostring(status.path or "-"))
            daemon.final_flush_pending = false
            if not daemon.active then daemon.book_id = nil end
        elseif not self.first_success_notified then
            logger.info("[MiuRead][ReadReport] service first success",
                "book=", status_book_id, "elapsed=", tostring(status.elapsed_seconds or "-"),
                "path=", tostring(status.path or "-"))
            self.first_success_notified = true
            if self.host.on_read_report_success then
                pcall(self.host.on_read_report_success, self.host, status.path)
            end
        end
        self:_persist_daemon_session(force or final_flush, status_book_id ~= "" and status_book_id or nil)
        if final_flush and stamp then self.store:mark_read_report_consumed(stamp) end
    elseif status.uncertain==true or status.state=="unconfirmed" then
        self.state = daemon.active and "waiting" or "stopped"
        self.consecutive_failures=0
        self.last_error=nil
        self.last_error_kind=nil
        self.last_stage=final_flush and "关闭前阅读时间未获明确回执" or "本次阅读时间未获明确回执，后续继续"
        if status_book_id~="" then
            local saved=self.store:session(status_book_id) or {}
            local unconfirmed_count=math.max(1,tonumber(status.unconfirmed_count) or ((tonumber(saved.consecutive_unconfirmed) or 0)+1))
            self.store:save_session(status_book_id,{
                last_unconfirmed=tostring(status.error or status.response_summary or "微信读书未明确确认"),
                last_unconfirmed_at=tonumber(status.completed_at) or os.time(),
                last_response_summary=status.response_summary or status.error,
                consecutive_unconfirmed=unconfirmed_count,
                last_error=false,
                consecutive_failures=0,
                report_state="unconfirmed",
                report_recovery_state=status.context_refresh_requested==true and "refreshing_context" or nil,
            })
            self:_clear_noncontext_repair_flag(status_book_id,saved,"daemon_unconfirmed")
        end
        if final_flush then
            logger.info("[MiuRead][ReadingTime] final flush unconfirmed",
                "book=",status_book_id,"elapsed=",tostring(status.elapsed_seconds or "-"),
                "reason=",tostring(status.flush_reason or "stop"))
            daemon.final_flush_pending=false
            if not daemon.active then daemon.book_id=nil end
        else
            logger.info("[MiuRead][ReadReport] service response unconfirmed; continuing",
                "book=",status_book_id,"count=",tostring(status.unconfirmed_count or 1),
                "context_refresh=",tostring(status.context_refresh_requested==true),
                "summary=",tostring(status.response_summary or status.error or "-"),
                "next_due=",tostring(status.next_due or "-"))
        end
        self:_persist_daemon_session(force or final_flush,status_book_id~="" and status_book_id or nil)
        if final_flush and stamp then self.store:mark_read_report_consumed(stamp) end
    elseif status.error then
        local error_kind=self:_normalize_report_error_kind(status.error_kind,status.error)
        local time_only=status.time_only==true
        self.state = daemon.active and "waiting" or "stopped"
        self.last_error = tostring(status.error)
        self.last_error_kind=error_kind
        local repair_required=false
        if status_book_id~="" then
            if time_only then
                -- A pure-time request can fail because the server rejects that
                -- request shape. Never turn that into a book-position repair.
                self.store:save_session(status_book_id,{
                    last_error=self.last_error,last_error_kind=error_kind,
                    last_response_summary=status.response_summary or status.error,
                    report_state="time_only_failed",
                })
            else
                repair_required=self:_record_report_issue(status_book_id,error_kind,self.last_error,{suppress_prompt=false})
            end
        end
        self.consecutive_failures=math.max(tonumber(self.consecutive_failures) or 0,
            tonumber(status.consecutive_failures) or 0)
        if final_flush then
            logger.warn("[MiuRead][ReadReport] final upload failed",
                "book=", status_book_id, "elapsed=", tostring(status.elapsed_seconds or "-"),
                "reason=", tostring(status.flush_reason or "stop"),
                "kind=",error_kind,"error=", self.last_error)
            daemon.final_flush_pending = false
            if not daemon.active then daemon.book_id = nil end
        else
            logger.warn("[MiuRead][ReadReport] service rejected",
                "kind=",error_kind,"retry_delay=",tostring(status.retry_delay or 0),
                "failures=",tostring(self.consecutive_failures),"repair=",tostring(repair_required),
                "error=",self.last_error)
            if error_kind=="authentication" and not repair_required then
                self:_recover_auth_once("read_report",self.last_error,function(ok_recover)
                    if ok_recover and not self.suspended and self:record() then self:start("auth_recovered") end
                end,false)
            elseif error_kind=="context" and not time_only and not repair_required and not self.auto_repair_busy then
                self.auto_repair_busy=true
                UIManager:scheduleIn(.35,function()
                    local current=self:record()
                    if not current or tostring(current.book.book_id or "")~=status_book_id then
                        self.auto_repair_busy=false
                        return
                    end
                    logger.info("[MiuRead][SyncRepair] automatic context rebuild requested","book=",status_book_id)
                    self:repair_current(function(ok_repair,detail)
                        self.auto_repair_busy=false
                        if not ok_repair then
                            local current_session=self.store:session(status_book_id) or {}
                            if current_session.sync_repair_required==true and self.host.on_read_report_failure then
                                pcall(self.host.on_read_report_failure,self.host,
                                    tostring(detail or "自动恢复当前书籍同步信息失败"),"context",status_book_id)
                            end
                        end
                    end)
                end)
            end
        end
        self:_persist_daemon_session(true, status_book_id ~= "" and status_book_id or nil)
        if final_flush and stamp then self.store:mark_read_report_consumed(stamp) end
    end
end

function Sync:_maybe_refresh_precise_position()
    -- Periodic exact-progress preparation was retired in beta.8. Keep this
    -- no-op bridge because the long-lived service poll still calls it.
    return false
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
        self:_maybe_refresh_precise_position()
        if not process_alive(daemon.pid) then
            local was_active = daemon.active
            logger.warn("[MiuRead][ReadReport] lightweight service exited unexpectedly")
            self:_cleanup_daemon_files(daemon)
            self.daemon = nil
            self.state = "stopped"
            if was_active and self.store:preferences().sync.time_enabled and not self.suspended and self:record() then
                self.daemon_restart_count=(tonumber(self.daemon_restart_count) or 0)+1
                if self.daemon_restart_count<=1 then
                    UIManager:scheduleIn(10, function() self:start("service_restart") end)
                else
                    self.last_error="阅读时间后台服务连续异常退出"
                    self.last_stage="本次阅读会话已停止自动重启"
                    logger.warn("[MiuRead][ReadReport] automatic restart suppressed")
                end
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
    if not self:_read_report_allowed(record) then
        self.state = "stopped"
        self.last_stage = "章节版仅同步阅读进度"
        return false, "当前章节版不上传阅读时间"
    end
    local book_id = tostring(record.book.book_id or "")
    local core_hash=self:_core_map_hash(record)
    local time_only=not self:periodic_progress_enabled()
    -- beta.8 daemon jobs are permanently time-only. Exact position work is
    -- owned by manual and end-of-reading submissions.
    local position_snapshot=nil
    if core_hash=="" then
        self.state="stopped"
        return false,"当前书籍章节信息不可用"
    end
    local ok, err = self:_ensure_daemon()
    if not ok then self.state="stopped"; return false, err end

    local daemon = self.daemon
    local prefs = self.store:preferences().sync
    local interval = math.max(10, tonumber(prefs.interval) or tonumber(Config.READ_INTERVAL) or 60)
    local session = self.store:session(book_id) or {}
    if not time_only and session.sync_repair_required==true then
        local repair_kind=self:_normalize_report_error_kind(session.sync_repair_kind,session.sync_repair_error)
        if repair_kind~="context" then
            self:_clear_noncontext_repair_flag(book_id,session,"daemon_start_reclassified")
            session=self.store:session(book_id) or session
        else
            self.state="repair_required"
            self.last_error=tostring(session.sync_repair_error or "当前书籍需要修复同步")
            self.last_error_kind="context"
            return false,"当前书籍需要修复同步"
        end
    end
    local auth = self.store:auth()
    local current_account=type(auth.account)=="table" and auth.account or {}
    local login_session_id=tostring(auth.login_session_id or "")
    local auth_revision=math.max(0,tonumber(auth.auth_revision or 0) or 0)
    local account_vid=tostring(current_account.vid or "")
    if login_session_id=="" or account_vid=="" then
        self.state="stopped"
        return false,"当前登录记录不完整，请先在账号状态中重新检查；仍无法恢复时再重新扫码"
    end
    self.pending_report_elapsed=0
    self.pending_report_status_at=os.time()
    -- beta.24 does not replay previously cached reading-time debt. Clear any
    -- beta.17-beta.23 carry that may still exist after OTA and continue from
    -- fresh reading only.
    local carry_elapsed=0
    if math.max(0,math.floor(tonumber(session.pending_report_seconds) or 0))>0 then
        self.store:save_session(book_id,{pending_report_seconds=0})
    end
    local existing_job=read_json_file(daemon.paths.job) or {}
    local same_account=tostring(existing_job.login_session_id or "")==login_session_id
        and math.max(0,tonumber(existing_job.auth_revision or 0) or 0)==auth_revision
        and tostring(existing_job.account_vid or "")==account_vid
    local same_document=tostring(existing_job.book_path or "")==tostring(record.path or "")
    local same_core=tostring(existing_job.core_map_hash or "")==core_hash
    if daemon.active and tostring(daemon.book_id or "")==book_id and same_account and same_document and same_core
        and process_alive(daemon.pid) then
        daemon.reason=reason
        daemon.core_map_hash=core_hash
        daemon.record_generation=tonumber(self.record_generation or 0) or 0
        self.state="waiting"
        self.last_stage="轻量后台服务运行中"
        if position_snapshot then self:_save_local_snapshot(book_id,position_snapshot) end
        self:_write_daemon_control(true,true,{_time_only=true})
        self:_schedule_daemon_poll(5)
        logger.info("[MiuRead][ReadReport] duplicate activation ignored",
            "pid=",tostring(daemon.pid),"book=",book_id,"reason=",tostring(reason or "start"))
        return true
    end
    local context_matches=tostring(session.report_login_session_id or "")==login_session_id
        and tostring(session.report_core_map_hash or "")==core_hash
    local legacy_book = time_only and {} or U.copy((context_matches and self.daemon_context)
        or (context_matches and type(session.legacy_report_context) == "table" and session.legacy_report_context)
        or {})
    legacy_book.book_id = book_id
    legacy_book.title = record.book.title
    if not time_only then self:_decorate_legacy_context(legacy_book, record) end
    if position_snapshot then
        legacy_book.local_chapter_uid=position_snapshot.chapter_uid
        legacy_book.local_chapter_idx=position_snapshot.chapter_index
        legacy_book.local_chapter_offset=position_snapshot.chapter_offset or position_snapshot.offset
        legacy_book.local_chapter_word_count=position_snapshot.chapter_word_count
        legacy_book.local_native_chapter_offset=position_snapshot.native_offset == true
        legacy_book.local_chapter_offset_basis=position_snapshot.offset_basis or position_snapshot.position_basis
        legacy_book.progress=position_snapshot.progress
        self:_save_local_snapshot(book_id,position_snapshot)
    end
    legacy_book.core_map_hash=core_hash

    local existing_control = read_json_file(daemon.paths.control) or {}
    local existing_status = read_json_file(daemon.paths.status) or {}
    self.daemon_generation = math.max(
        tonumber(self.daemon_generation or 0) or 0,
        tonumber(existing_control.generation or 0) or 0,
        tonumber(existing_status.generation or 0) or 0
    ) + 1
    daemon.generation = self.daemon_generation
    daemon.active = true
    self.precise_due_refreshed = 0
    daemon.book_id = book_id
    daemon.final_book_id = nil
    daemon.final_flush_pending = false
    daemon.interval = interval
    daemon.reason = reason
    daemon.login_session_id = login_session_id
    daemon.auth_revision = auth_revision
    daemon.account_vid = account_vid
    daemon.core_map_hash=core_hash
    daemon.record_generation=tonumber(self.record_generation or 0) or 0
    if not time_only then self.daemon_context=U.copy(legacy_book) end

    local job = {
        generation = daemon.generation,
        controller_token = self.controller_token,
        login_session_id = login_session_id,
        auth_revision = auth_revision,
        account_vid = account_vid,
        book_id = book_id,
        core_map_hash = core_hash,
        record_generation = daemon.record_generation,
        book_title = record.book.title,
        book_path = record.path,
        book = legacy_book,
        time_only = time_only,
        carry_elapsed = carry_elapsed,
        auth = {
            cookies = auth.cookies or {},
            api_key = auth.api_key or "",
            wr_ticket = auth.wr_ticket or "",
            wr_wrpa = auth.wr_wrpa or "",
            login_session_id = login_session_id,
            auth_revision = auth_revision,
            account = U.copy(auth.account or {}),
        },
        interval = interval,
        first_delay = interval,
        idle_timeout = tonumber(prefs.idle_timeout) or 600,
    }
    U.atomic_write(daemon.paths.job, Json.encode(job), true)
    self.daemon_status_stamp = nil
    self.daemon_last_persist = os.time()
    self.state = "waiting"
    self.next_due = os.time() + interval
    self.last_stage = "阅读时间后台服务运行中，首次约60秒后上传"
    self:_write_daemon_control(true, true, {_time_only=true})
    self:_schedule_daemon_poll(5)
    logger.info("[MiuRead][ReadReport] service activated",
        "pid=", tostring(daemon.pid), "book=", book_id,
        "core=",core_hash:sub(1,12),"first_delay=", tostring(interval),
        "interval=", tostring(interval), "reason=", tostring(reason or "start"))
    return true
end

function Sync:_park_daemon_for_suspend(reason,preserve_final_flush)
    local daemon=self.daemon
    if self.control_write_task then
        UIManager:unschedule(self.control_write_task)
        self.control_write_task=nil
    end
    if self.session_flush_task then
        UIManager:unschedule(self.session_flush_task)
        self.session_flush_task=nil
    end
    if not daemon then return true end
    if preserve_final_flush==true and daemon.final_flush_pending==true then
        daemon.active=false
        self.next_due=0
        self.state="stopped"
        logger.info("[MiuRead][ReadReport] suspend preserves final reading-time flush",
            "reason=",tostring(reason or "suspend"),"book=",tostring(daemon.final_book_id or daemon.book_id or "-"))
        return true
    end

    -- Suspend is intentionally network-silent. Do not call _write_daemon_control
    -- here: that helper resolves the current position and can re-enter ReaderUI.
    -- Reuse the last safe control snapshot and only park the service.
    local existing=read_json_file(daemon.paths.control) or {}
    local existing_generation=tonumber(existing.generation or 0) or 0
    local own_generation=tonumber(daemon.generation or 0) or 0
    if existing_generation<=own_generation
        and (existing_generation~=own_generation
            or tostring(existing.controller_token or "")==""
            or tostring(existing.controller_token or "")==tostring(self.controller_token)) then
        existing.active=false
        existing.generation=own_generation
        existing.controller_token=tostring(self.controller_token or "")
        existing.login_session_id=tostring(daemon.login_session_id or existing.login_session_id or "")
        existing.account_vid=tostring(daemon.account_vid or existing.account_vid or "")
        existing.book_id=tostring(daemon.book_id or existing.book_id or "")
        existing.core_map_hash=tostring(daemon.core_map_hash or existing.core_map_hash or "")
        existing.record_generation=tonumber(daemon.record_generation or existing.record_generation or 0) or 0
        existing.updated_at=os.time()
        existing.suspend_parked=true
        existing.suspend_reason=tostring(reason or "suspend")
        -- Never synthesize a final flush during Suspend. Existing flush fields
        -- belong to an earlier explicit close and are removed for this session.
        existing.flush_seq=0
        existing.flush_elapsed=nil
        existing.flush_reason=nil
        U.atomic_write(daemon.paths.control,Json.encode(existing),true)
    end
    daemon.active=false
    daemon.final_flush_pending=false
    daemon.final_book_id=nil
    self.next_due=0
    self.state="stopped"
    logger.info("[MiuRead][ReadReport] parked silently",
        "reason=",tostring(reason or "suspend"),"book=",tostring(daemon.book_id or "-"))
    return true
end

function Sync:_next_writer_barrier(reason)
    local daemon=self.daemon
    if not daemon or not daemon.paths then return nil end
    local existing=read_json_file(daemon.paths.control) or {}
    local seq=math.max(
        tonumber(existing.writer_barrier_seq or 0) or 0,
        tonumber(daemon.writer_barrier_seq or 0) or 0,
        tonumber(daemon.writer_barrier_ack_seq or 0) or 0
    )+1
    daemon.writer_barrier_seq=seq
    daemon.writer_barrier_reason=tostring(reason or "writer_barrier")
    return seq
end

function Sync:writer_barrier_done(seq)
    seq=tonumber(seq or 0) or 0
    if seq<=0 then return true end
    local daemon=self.daemon
    if not daemon then return true end
    -- Barrier polling runs every ~200 ms. A forced import also persists the
    -- daemon session when the status stamp is unchanged, creating needless
    -- flash writes for the entire network timeout. A normal import still reads
    -- the status file immediately and processes every new status exactly once.
    self:_import_daemon_status(false)
    local ack=tonumber(daemon.writer_barrier_ack_seq or 0) or 0
    local done=ack>=seq and daemon.final_flush_pending~=true
    if done and daemon.active~=true then daemon.book_id=nil end
    return done
end

function Sync:wait_writer_barrier(seq,callback,timeout)
    callback=type(callback)=="function" and callback or function() end
    seq=tonumber(seq or 0) or 0
    if seq<=0 or self:writer_barrier_done(seq) then callback(true); return true end
    local started=os.time()
    timeout=math.max(2,tonumber(timeout) or 12)
    local done=false
    local poll
    poll=function()
        if done then return end
        if self:writer_barrier_done(seq) then
            done=true
            callback(true)
            return
        end
        if os.time()-started>=timeout then
            done=true
            logger.warn("[MiuRead][ReadReport] writer barrier timeout",
                "seq=",tostring(seq),"timeout=",tostring(timeout))
            callback(false)
            return
        end
        UIManager:scheduleIn(.20,poll)
    end
    UIManager:scheduleIn(.12,poll)
    return true
end

function Sync:_stop_daemon_fast(reason, flush_elapsed)
    local daemon = self.daemon
    if self.control_write_task then
        UIManager:unschedule(self.control_write_task)
        self.control_write_task = nil
    end
    if not daemon then return nil end

    local extra = {}
    local barrier_seq=self:_next_writer_barrier(reason or "stop_fast")
    if barrier_seq then
        extra.writer_barrier_seq=barrier_seq
        extra.writer_barrier_reason=tostring(reason or "stop_fast")
    end
    flush_elapsed = math.floor(tonumber(flush_elapsed) or 0)
    if daemon.book_id and flush_elapsed >= FINAL_REPORT_MIN_SECONDS then
        local existing = read_json_file(daemon.paths.control) or {}
        extra.flush_seq = (tonumber(existing.flush_seq or 0) or 0) + 1
        extra.flush_elapsed = flush_elapsed
        extra.flush_reason = tostring(reason or "stop")
        daemon.final_book_id = daemon.book_id
        daemon.final_flush_pending = true
    end

    -- beta.8 attaches a writer barrier to every explicit close. The service
    -- acknowledges it only after any already-running time report and the final
    -- short flush have left /web/book/read, so final progress can safely write last.
    daemon.active = false
    self:_write_daemon_control(false, true, extra)
    self.next_due = 0
    if not daemon.final_flush_pending and not barrier_seq then daemon.book_id = nil end
    return barrier_seq
end

function Sync:_stop_daemon(reason, persist, flush_elapsed)
    local daemon = self.daemon
    if self.control_write_task then UIManager:unschedule(self.control_write_task); self.control_write_task=nil end
    if not daemon then return nil end
    self:_import_daemon_status(true)
    if persist ~= false then self:_persist_daemon_session(true) end

    local extra = {}
    local barrier_seq=self:_next_writer_barrier(reason or "stop")
    if barrier_seq then
        extra.writer_barrier_seq=barrier_seq
        extra.writer_barrier_reason=tostring(reason or "stop")
    end
    flush_elapsed = math.floor(tonumber(flush_elapsed) or 0)
    if daemon.book_id and flush_elapsed >= FINAL_REPORT_MIN_SECONDS then
        local existing = read_json_file(daemon.paths.control) or {}
        extra.flush_seq = (tonumber(existing.flush_seq or 0) or 0) + 1
        extra.flush_elapsed = flush_elapsed
        extra.flush_reason = tostring(reason or "stop")
        daemon.final_book_id = daemon.book_id
        daemon.final_flush_pending = true
    end

    daemon.active = false
    self:_write_daemon_control(false, true, extra)
    self.next_due = 0

    UIManager:scheduleIn(2, function() self:_import_daemon_status(true) end)
    UIManager:scheduleIn(6, function() self:_import_daemon_status(true) end)
    return barrier_seq
end

function Sync:_final_elapsed(skip_status_import)
    local record=self:record()
    if not self.store:preferences().sync.time_enabled or not record or not self:_read_report_allowed(record) then return nil end
    if skip_status_import ~= true then self:_import_daemon_status(true) end
    local now = os.time()
    local started = tonumber(self.session_started_at or 0) or 0
    if started <= 0 then started = now end
    local uploaded = tonumber(self.last_upload or 0) or 0
    local base = math.max(started, uploaded)
    local elapsed = math.max(0, now - base)
    local maximum = math.max(FINAL_REPORT_MIN_SECONDS, tonumber(Config.READ_INTERVAL) or 60)
    elapsed = math.min(elapsed, maximum)
    if elapsed < FINAL_REPORT_MIN_SECONDS then return nil end
    return elapsed
end

function Sync:start(reason)
    self.last_activity = os.time()
    if (self.host and (self.host._reading_end_barrier_active==true
            or self.host._reading_end_sync_active==true))
        or self.reading_end_finalized==true then
        self.state="stopped"
        self.last_stage="结束阅读收尾中"
        logger.info("[MiuRead][ReadReport] start deferred",
            "reason=reading_end_barrier","requested=",tostring(reason or "start"))
        return false,"结束阅读收尾中"
    end
    if reason == "reader_ready" or reason == "resume" or reason == "enabled"
        or tonumber(self.session_started_at or 0) <= 0
    then
        self.session_started_at = self.last_activity
    end
    local prefs = self.store:preferences().sync or {}
    local enabled = prefs.time_enabled == true
    self.time_enabled = enabled
    if not enabled then
        self.progress_hold = false
        self.state = "stopped"
        self.last_stage = "阅读时间同步已关闭"
        return false
    end
    local record = self:record()
    if not record then
        self.state = "stopped"
        self.last_stage = "未识别当前觅阅书籍"
        logger.info("[MiuRead][ReadReport] start deferred", "reason=", tostring(reason), "record=not_found")
        return false, "未识别到 MiuRead 书籍"
    end
    if not self:_read_report_allowed(record) then
        self.progress_hold=false
        self.state="stopped"
        self.last_stage="章节版仅同步阅读进度"
        logger.info("[MiuRead][ReadReport] disabled for progress-only range",
            "book=",tostring(record.book and record.book.book_id or ""))
        return false,"当前章节版不上传阅读时间"
    end
    if enabled and self:periodic_progress_enabled() and not self:is_verified(record.book.book_id) then
        self.progress_hold = true
        self.state = "verification_required"
        self.last_stage = "等待确认本机与云端阅读位置"
        logger.info("[MiuRead][ReadReport] start deferred", "reason=", tostring(reason),
            "book=", tostring(record.book.book_id), "progress=unverified")
        return false, "阅读位置尚未确认"
    end
    self.progress_hold = false
    self.state = enabled and "waiting" or "stopped"
    self.last_stage = enabled and "准备后台阅读时间工作器" or "阅读时间同步已关闭"
    logger.info("[MiuRead][ReadReport] start requested", "reason=", tostring(reason),
        "enabled=", tostring(enabled), "mode=long_lived_worker")
    if enabled and not self.suspended then return self:_start_daemon(reason) end
    return enabled
end

function Sync:stop(reason, flush_elapsed)
    self.time_enabled = (self.store:preferences().sync or {}).time_enabled==true
    local barrier_seq=self:_stop_daemon(reason, true, flush_elapsed)
    self.async:cancel(reason)
    self.busy = false
    self.progress_hold = false
    self.state = "stopped"
    logger.info("[MiuRead][ReadReport] stopped", "reason=", tostring(reason),
        "writer_barrier=",tostring(barrier_seq or "-"))
    return barrier_seq
end

function Sync:stop_fast(reason, flush_elapsed)
    self.time_enabled = (self.store:preferences().sync or {}).time_enabled==true
    local barrier_seq=self:_stop_daemon_fast(reason, flush_elapsed)
    self.async:cancel(reason)
    self.busy = false
    self.progress_hold = false
    self.state = "stopped"
    logger.info("[MiuRead][ReadReport] stopped fast", "reason=", tostring(reason),
        "writer_barrier=",tostring(barrier_seq or "-"))
    return barrier_seq
end

function Sync:_cancel_record_retry()
    if self.record_retry_task then
        UIManager:unschedule(self.record_retry_task)
        self.record_retry_task = nil
    end
end

function Sync:_accept_reader_record(current,attempt)
    self.current=current
    self.record_checked_path=nil
    self.progress_hold=self:periodic_progress_enabled()
    self.state=self.progress_hold and "verification_required" or "stopped"
    self.last_stage=self.progress_hold and "等待读取云端位置" or "当前书籍已识别"
    logger.info("[MiuRead][Sync] reader record",tostring(current.book.book_id),
        "attempt=",tostring(attempt))
    if self.host.on_sync_record_ready then pcall(self.host.on_sync_record_ready,self.host,current) end
    if not self:periodic_progress_enabled() then self:start("reader_ready") end
end

function Sync:_record_missing(path,attempt)
    self.current=nil
    self.record_checked_path=path
    self.progress_hold=false
    self.state="stopped"
    self.last_stage="未识别当前觅阅书籍"
    logger.info("[MiuRead][Sync] reader record not_found","attempt=",tostring(attempt))
    if self.host.on_sync_record_missing then pcall(self.host.on_sync_record_missing,self.host) end
end

function Sync:_resolve_reader_record(generation,attempt)
    if generation~=self.record_generation or not self.host.ui or not self.host.ui.document then return end
    self.record_retry_task=nil
    local current=self:record()
    if current then self:_accept_reader_record(current,attempt); return end
    local path=self:_document_path()
    if not path then
        local delays={0.55,1.25,2.25}
        if attempt<#delays+1 then
            local task
            task=function()
                if self.record_retry_task~=task then return end
                self:_resolve_reader_record(generation,attempt+1)
            end
            self.record_retry_task=task
            UIManager:scheduleIn(delays[attempt] or 1,task)
        else self:_record_missing(nil,attempt) end
        return
    end
    if self.record_checked_path==path then self:_record_missing(path,attempt); return end
    if not self.identity_async or not self.identity_async:available() then
        logger.dbg("[MiuRead][Sync] deep EPUB identity deferred; background worker unavailable")
        self:_record_missing(path,attempt)
        return
    end
    if self.identity_async:busy() then
        local task
        task=function()
            if self.record_retry_task~=task then return end
            self:_resolve_reader_record(generation,attempt+1)
        end
        self.record_retry_task=task
        UIManager:scheduleIn(.25,task)
        return
    end
    local started,err=self.identity_async:run("epub-identity",function()
        return self.store:epub_identity(path)
    end,function(result)
        if generation~=self.record_generation or self:_document_path()~=path then return end
        local meta=result and result.ok and result.value or nil
        local book,record,variant
        if type(meta)=="table" and type(self.store.file_record_from_identity)=="function" then
            book,record,variant=self.store:file_record_from_identity(path,meta,true)
        end
        local resolved=self:_usable_record(book,record,variant,path)
        if resolved then
            self:_accept_reader_record(resolved,attempt)
        else
            if result and result.ok~=true then
                logger.warn("[MiuRead][Sync] EPUB identity worker failed",tostring(result.error or "unknown"))
            end
            self:_record_missing(path,attempt)
        end
    end,25)
    if not started then
        logger.warn("[MiuRead][Sync] EPUB identity worker unavailable",tostring(err))
        self:_record_missing(path,attempt)
    end
end

function Sync:on_reader_ready()
    self:_import_daemon_status(true)
    if self.host and (self.host._reading_end_barrier_active==true
        or self.host._reading_end_sync_active==true) then
        local ending_record=self:record()
        if ending_record then self.current=ending_record end
        logger.info("[MiuRead][ReadingEnd] reader-ready deferred until finalizer completes",
            "book=",tostring(ending_record and ending_record.book and ending_record.book.book_id or "-"))
        return true
    end
    local ready_record=self:record()
    local ready_job=self.daemon and read_json_file(self.daemon.paths.job) or {}
    if self.daemon and self.daemon.active and ready_record
        and tostring(self.daemon.book_id or "")==tostring(ready_record.book.book_id or "")
        and tostring(ready_job.book_path or "")==tostring(ready_record.path or "") then
        self.current=ready_record
        self.suspended=false
        self:_write_daemon_control(true,true)
        logger.info("[MiuRead][Sync] duplicate reader-ready ignored",
            "book=",tostring(ready_record.book.book_id),"path=",tostring(ready_record.path or ""))
        return
    end
    if self.daemon and self.daemon.active then self:_stop_daemon("reader_switch", true) end
    if self.identity_async then self.identity_async:cancel("reader_switch") end
    self:_cancel_record_retry()
    self.record_generation = (tonumber(self.record_generation) or 0) + 1
    self.current = nil
    self.record_checked_path = nil
    self.suspended = false
    self.session_uploads = 0
    self.daemon_restart_count = 0
    self.last_upload = 0
    self.session_started_at = os.time()
    self.first_success_notified = false
    self.failure_notified = false
    self.consecutive_failures = 0
    self.last_error = nil
    self.progress_hold = false
    self.daemon_context = nil
    self.precise_position_cache = {}
    self.precise_due_refreshed = 0
    self.verified_book_id = nil
    self.verified_at = 0
    self.verified_local_percent = nil
    self.verified_remote_percent = nil
    self.verified_login_session_id = nil
    self:_resolve_reader_record(self.record_generation, 1)
end

function Sync:on_page(page)
    if self.time_enabled~=true or self.suspended or not self.current then return end
    if page and page ~= self.last_page then
        self.last_page = page
        self.last_activity = os.time()
        self:_write_daemon_control(true, false)
    end
end

function Sync:_defer_session_flush(delay)
    if self.session_flush_task then
        UIManager:unschedule(self.session_flush_task)
        self.session_flush_task = nil
    end
    local task
    task = function()
        if self.session_flush_task ~= task then return end
        self.session_flush_task = nil
        pcall(self.store.flush, self.store)
    end
    self.session_flush_task = task
    UIManager:scheduleIn(math.max(.3, tonumber(delay) or .8), task)
end

function Sync:on_suspend(options)
    options=type(options)=="table" and options or {}
    local generation=tonumber(options.generation or 0) or 0
    if generation>0 and generation==tonumber(self.suspend_generation or 0) then return true end
    if generation>0 then self.suspend_generation=generation end
    self.suspended = true
    if options.reading_end_active==true then
        logger.info("[MiuRead][ReadingEnd] suspend barrier keeps final sync owner",
            "progress_worker=",tostring(self.async and self.async:busy() or false),
            "final_time=",tostring(self.daemon and self.daemon.final_flush_pending==true or false))
    end

    local r=self.current
    local now=os.time()

    if r and r.book and tostring(r.book.book_id or "")~="" then
        local book_id=tostring(r.book.book_id)
        local saved=self.store:session(book_id) or {}
        local position=type(saved.local_position_snapshot)=="table" and U.copy(saved.local_position_snapshot) or nil
        local patch={
            last_read_at=now,last_read_path=r.path,
            -- Suspend is network-silent and also debt-silent: no elapsed time is
            -- queued for post-resume replay. Fresh reading starts a new interval.
            pending_report_seconds=0,
            suspend_generation=generation>0 and generation or nil,
            suspend_power_state=tostring(options.power_state or "REAL_SUSPEND"),
        }
        if position then
            patch.pending={
                percent=position.progress,
                chapter_percent=position.chapter_percent,
                chapter_uid=position.chapter_uid,
                saved_at=now,reason="suspend_cached",
            }
            patch.progress_local_percent=position.progress
        end
        -- One small synchronous local write; no delayed post-suspend flush.
        self.store:save_session(book_id,patch,true)
        logger.info("[MiuRead][ReadReport] suspend parked without time replay",
            "book=",book_id,"position_cached=",tostring(position~=nil),
            "power=",tostring(options.power_state or "REAL_SUSPEND"))
    end
    return self:_park_daemon_for_suspend("suspend",options.preserve_final_flush==true)
end

function Sync:on_resume(_slept)
    self:_import_daemon_status(true)
    self.suspended = false
    self.last_upload = 0
    self.session_started_at = os.time()
    if self.host and self.host._reading_end_sync_active==true then
        -- A short wake can arrive while the lock-screen final sync is still
        -- confirming progress. Starting a new 60 s worker here races the old
        -- book worker and creates stale-result warnings. Let the final sync own
        -- the session until it finishes.
        logger.info("[MiuRead][ReadReport] resume deferred", "reason=reading_end_sync_active")
        return true
    end
    self.reading_end_finalized=false
    self:start("resume")
end

function Sync:on_close(options)
    options=type(options)=="table" and options or {}
    self.record_generation = (tonumber(self.record_generation) or 0) + 1
    self:_cancel_record_retry()
    if self.identity_async then self.identity_async:cancel("document_closed") end
    local r = self.current or self:record()
    local now=os.time()
    local duplicate=false
    if r then
        local session=self.store:session(r.book.book_id) or {}
        local path=tostring(r.path or "")
        duplicate=path~="" and tostring(session.last_close_path or "")==path
            and now-(tonumber(session.last_close_at) or 0)<=4
        if duplicate then
            logger.info("[MiuRead][ReadReport] duplicate close ignored","path=",path)
        else
            local position = self:local_position()
            self.store:save_session(r.book.book_id, {
                pending={
                    percent=position and position.progress or nil,
                    chapter_percent=position and position.chapter_percent or math.floor((self:local_ratio() or 0) * 100 + .5),
                    chapter_uid=position and position.chapter_uid or nil,
                    saved_at=now, reason="close",
                },
                last_read_at=now,last_read_path=r.path,
                progress_local_percent=position and position.progress or nil,
                last_close_path=path,last_close_at=now,
            }, false)
            self:_defer_session_flush(.8)
        end
    end
    -- Even a duplicate close event must stop this plugin instance's service.
    -- It simply must not emit a second final upload.
    local finalized=self.reading_end_finalized==true
    if finalized then
        -- A Home return may already have queued the final short time flush. Do
        -- not rewrite the daemon control file with an empty close command before
        -- the service has consumed that flush.
        if not (self.daemon and self.daemon.final_flush_pending==true) then
            self:_stop_daemon_fast("close",0)
        end
        if options.preserve_async~=true and self.async then self.async:cancel("document_closed") end
    else
        self:stop_fast("close", duplicate and 0 or self:_final_elapsed(true))
    end
    self.reading_end_finalized=false
    self.current = nil
    self.record_checked_path = nil
    self.precise_position_cache = {}
    self.precise_due_refreshed = 0
end

function Sync:invalidate_login_session(reason)
    reason=tostring(reason or "auth_transition")
    self.auth_transitioning=true
    if self.control_write_task then UIManager:unschedule(self.control_write_task); self.control_write_task=nil end
    if self.daemon_poll then UIManager:unschedule(self.daemon_poll); self.daemon_poll=nil end
    if self.async then self.async:cancel(reason) end
    self.busy=false
    self.progress_hold=false
    self.daemon_context=nil
    self.daemon_status_stamp=nil
    self.last_error=nil
    self.consecutive_failures=0
    self.verified_book_id=nil
    self.verified_at=0
    self.verified_local_percent=nil
    self.verified_remote_percent=nil
    self.verified_login_session_id=nil
    local daemon=self.daemon
    if not daemon then
        -- A service may survive an OTA reload even when time sync is currently
        -- disabled and therefore was not attached during Sync:new(). Sanitize it
        -- as part of the login boundary instead of leaving its old auth snapshot.
        local paths=self:_daemon_paths()
        local owner=read_json_file(paths.owner)
        local parent_pid=current_pid()
        if type(owner)=="table" and process_alive(owner.pid)
            and tonumber(owner.service_version or 0)==READ_REPORT_SERVICE_VERSION
            and tonumber(owner.parent_pid or 0)==tonumber(parent_pid or 0) then
            daemon={
                pid=tonumber(owner.pid),paths=paths,active=false,
                generation=0,book_id=nil,interval=Config.READ_INTERVAL,reason="auth_reset_attach",
                is_child=false,service_version=READ_REPORT_SERVICE_VERSION,
            }
            self.daemon=daemon
        end
    end
    if daemon and daemon.paths and process_alive(daemon.pid) then
        local control=read_json_file(daemon.paths.control) or {}
        local status=read_json_file(daemon.paths.status) or {}
        local job=read_json_file(daemon.paths.job) or {}
        local generation=math.max(tonumber(daemon.generation or 0) or 0,
            tonumber(control.generation or 0) or 0,tonumber(status.generation or 0) or 0,
            tonumber(job.generation or 0) or 0)+1
        daemon.generation=generation
        daemon.active=false
        daemon.book_id=nil
        daemon.final_book_id=nil
        daemon.final_flush_pending=false
        daemon.login_session_id=""
        daemon.account_vid=""
        os.remove(daemon.paths.context)
        os.remove(daemon.paths.status)
        U.atomic_write(daemon.paths.job,Json.encode({
            action="reset_auth",generation=generation,controller_token=self.controller_token,
            login_session_id="",auth_revision=0,account_vid="",book_id="",book={},auth={},interval=Config.READ_INTERVAL,first_delay=10,
        }),true)
        U.atomic_write(daemon.paths.control,Json.encode({
            active=false,generation=generation,controller_token=self.controller_token,
            login_session_id="",auth_revision=0,account_vid="",book_id="",updated_at=os.time(),reset_reason=reason,
        }),true)
        logger.info("[MiuRead][ReadReport] login session invalidated",
            "reason=",reason,"generation=",tostring(generation))
    elseif daemon then
        self:_cleanup_daemon_files(daemon)
        self.daemon=nil
    end
    self.state="stopped"
    self.next_due=0
    return true
end

function Sync:on_auth_restored()
    self.auth_transitioning=false
    self.last_error=nil
    self.consecutive_failures=0
    self.failure_notified=false
    self.busy=false
    self.daemon_context=nil
    self.store:ensure_login_session_id()
    local record=self:record()
    if not record or self.suspended then return false end
    if self.store:preferences().sync.time_enabled~=true then return false end
    self.state="waiting"
    self.last_stage="登录已恢复，正在重建上传上下文"
    return self:start("auth_restored") == true
end

function Sync:status_label()
    if not self.store:preferences().sync.time_enabled then return "已关闭" end
    local labels = {
        stopped="未运行", waiting="运行中", uploading="正在上传", progress_uploading="上传阅读进度", fetching_remote="读取云进度",
        progress_sync="检查云端位置", verification_required="等待位置选择", repair_required="需要修复同步", paused="已暂停", idle="空闲暂停",
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
        last_error_kind=self.last_error_kind or (session and session.last_error_kind),
        last_path=self.last_path or (session and session.last_path),
        last_stage=self.last_stage or (session and session.last_stage),
        last_response_summary=self.last_response_summary or (session and session.last_response_summary),
        last_response_path=self.last_response_path or (session and session.last_response_path),
        last_http_code=self.last_http_code or (session and session.last_http_code),
        last_http_length=self.last_http_length or (session and session.last_http_length),
        last_payload_public=session and session.last_payload_public,
        next_due=self.next_due,consecutive_failures=self.consecutive_failures or (session and session.consecutive_failures) or 0,
        tick_count=self.tick_count,
        progress_enabled=self:progress_mode()~="manual",
        progress_mode=self:progress_mode(),
        progress_state=session and session.progress_sync_state,
        progress_message=session and session.progress_sync_message,
        service_pid=self.daemon and self.daemon.pid or nil,
        service_version=self.daemon and self.daemon.service_version or READ_REPORT_SERVICE_VERSION,
        final_flush_pending=self.daemon and self.daemon.final_flush_pending==true or false,
        last_elapsed=session and session.last_elapsed,
        pending_report_elapsed=0,
        last_report_reason=session and session.last_report_reason,
    }
end

Sync._accepted = accepted
Sync._response_summary = response_summary
Sync._response_synckey = response_synckey
Sync._response_progress = response_progress
Sync._catalog_progress_from_remote = catalog_progress_from_remote

return Sync
