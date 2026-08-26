local Legacy = require("miuread.legacy.read_report_worker")

local Adapter = {}

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for key, item in pairs(value) do
        if type(item) ~= "function" and type(item) ~= "userdata" and type(item) ~= "thread" then
            out[copy(key, seen)] = copy(item, seen)
        end
    end
    return out
end

local function merge(base, patch)
    local out = copy(base or {})
    for key, value in pairs(patch or {}) do out[key] = copy(value) end
    return out
end

local function normalize_ratio(value)
    value = tonumber(value) or 0
    if value > 1 then value = value / 100 end
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

local function position(context, ratio)
    local chapters = type(context.chapters) == "table" and context.chapters or {}
    ratio = normalize_ratio(ratio)

    if context.source_is_standalone == true and context.source_chapter_uid ~= nil then
        local source_uid = tostring(context.source_chapter_uid)
        local selected, total, before = nil, 0, 0
        for _, chapter in ipairs(chapters) do
            local words = math.max(1, tonumber(chapter.wordCount or chapter.word_count or 0) or 0)
            local uid = chapter.chapterUid or chapter.uid or chapter.chapter_uid
            if not selected and tostring(uid or "") == source_uid then
                selected = chapter
            elseif not selected then
                before = before + words
            end
            total = total + words
        end
        if selected and total > 0 then
            local words = math.max(1, tonumber(selected.wordCount or selected.word_count or 0) or 0)
            local offset = math.max(0, math.min(words, math.floor(ratio * words + 0.5)))
            return {
                progress = math.floor(((before + offset) / total) * 100 + 0.5),
                chapter_uid = selected.chapterUid or selected.uid or source_uid,
                chapter_index = tonumber(selected.chapterIdx or selected.index or context.source_chapter_index) or 0,
                offset = offset,
                source = "standalone_chapter",
            }
        end
        if context.remote_progress_loaded == true then
            return {
                progress = math.floor(normalize_ratio(context.remote_progress or context.progress) * 100 + 0.5),
                chapter_uid = context.remote_chapter_uid or context.chapter_uid or 0,
                chapter_index = tonumber(context.remote_chapter_idx or context.chapter_idx) or 0,
                offset = tonumber(context.remote_chapter_offset or context.chapter_offset) or 0,
                source = "remote_fallback",
            }
        end
    end

    local selected, within = nil, 0
    if #chapters > 0 then
        local total = 0
        for _, chapter in ipairs(chapters) do
            total = total + math.max(1, tonumber(chapter.wordCount or chapter.word_count or 0) or 0)
        end
        local target, before = ratio * total, 0
        for index, chapter in ipairs(chapters) do
            local words = math.max(1, tonumber(chapter.wordCount or chapter.word_count or 0) or 0)
            if target <= before + words or index == #chapters then
                selected = chapter
                within = math.max(0, math.min(1, (target - before) / words))
                break
            end
            before = before + words
        end
    end
    local words = tonumber(selected and (selected.wordCount or selected.word_count))
        or tonumber(context.chapter_word_count) or 0
    local offset = tonumber(context.chapter_offset) or 0
    if words > 0 and selected then offset = math.floor(within * words + 0.5) end
    return {
        progress = math.floor(ratio * 100 + 0.5),
        chapter_uid = selected and (selected.chapterUid or selected.uid or selected.chapter_uid) or context.chapter_uid or 0,
        chapter_index = tonumber(selected and (selected.chapterIdx or selected.index or selected.chapter_idx))
            or tonumber(context.chapter_idx) or 0,
        offset = offset,
        source = "word_weighted",
    }
end

function Adapter.run(job)
    job = job or {}
    local legacy_job = {
        book_id = job.book_id,
        book_title = job.book_title,
        book = copy(job.book or {}),
        core_map_hash = job.core_map_hash,
        progress_ratio = job.progress_ratio,
        elapsed_seconds = job.elapsed_seconds,
        cookies = copy(job.cookies or {}),
        api_key = job.api_key or "",
        wr_ticket = job.wr_ticket or "",
        wr_wrpa = job.wr_wrpa or "",
        allow_renewal = job.allow_renewal == true,
        time_only = job.time_only == true,
        report_mode = tostring(job.report_mode or ""),
        force_context = job.force_context == true,
        context_only = job.context_only == true,
    }
    local result = Legacy.run(legacy_job)
    local context = merge(legacy_job.book, result.book_patch)
    local path = "compat_read_report_" .. tostring(result.path or result.error_kind or "unknown")
    return {
        accepted = result.ok == true,
        uncertain = result.uncertain == true,
        response = result.result or {},
        error = result.error,
        error_kind = result.error_kind,
        path = path,
        legacy_context = context,
        context_changed = result.context_changed == true,
        position = result.position or (job.context_only ~= true and position(context, job.progress_ratio) or nil),
        cookies_changed = result.cookies_changed == true,
        cookies = result.cookies,
        wr_ticket_changed = result.wr_ticket_changed == true,
        wr_ticket = result.wr_ticket,
        wr_wrpa_changed = result.wr_wrpa_changed == true,
        wr_wrpa = result.wr_wrpa,
        response_summary = result.response_summary
            or (result.ok == true and "succ=1 (compatibility path)"
            or (result.uncertain == true and ("unconfirmed: " .. tostring(result.error or "no explicit acknowledgement"))
            or tostring(result.error or "compatibility path rejected"))),
        attempts = { { stage = tostring(result.path or "compatibility") } },
        payload_public = merge({
            compatibility_path = true,
            context_only = job.context_only == true,
            report_mode = tostring(job.report_mode or ""),
        }, result.payload_public or {}),
        meta = result.meta,
    }
end

return Adapter
