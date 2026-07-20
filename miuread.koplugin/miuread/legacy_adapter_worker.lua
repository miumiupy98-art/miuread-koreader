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

    local selected, within
    if #chapters > 0 then
        local scaled = ratio * #chapters
        local index = math.floor(scaled) + 1
        if index < 1 then index = 1 elseif index > #chapters then index = #chapters end
        selected = chapters[index]
        within = scaled - math.floor(scaled)
        if index == #chapters and ratio >= 1 then within = 1 end
    end
    local words = tonumber(selected and selected.wordCount) or tonumber(context.chapter_word_count) or 0
    local offset = tonumber(context.chapter_offset) or 0
    if words > 0 and within then offset = math.floor(within * words) end
    return {
        progress = math.floor(ratio * 100 + 0.5),
        chapter_uid = selected and selected.chapterUid or context.chapter_uid or 0,
        chapter_index = tonumber(selected and selected.chapterIdx) or tonumber(context.chapter_idx) or 0,
        offset = offset,
    }
end

function Adapter.run(job)
    job = job or {}
    local legacy_job = {
        book_id = job.book_id,
        book_title = job.book_title,
        book = copy(job.book or {}),
        progress_ratio = job.progress_ratio,
        elapsed_seconds = job.elapsed_seconds,
        cookies = copy(job.cookies or {}),
        api_key = job.api_key or "",
        wr_ticket = job.wr_ticket or "",
        wr_wrpa = job.wr_wrpa or "",
        allow_renewal = job.allow_renewal == true,
    }
    local result = Legacy.run(legacy_job)
    local context = merge(legacy_job.book, result.book_patch)
    local path = "legacy_0.3.6.7_" .. tostring(result.path or result.error_kind or "unknown")
    return {
        accepted = result.ok == true,
        response = result.result or {},
        error = result.error,
        error_kind = result.error_kind,
        path = path,
        legacy_context = context,
        context_changed = result.context_changed == true,
        position = result.position or position(context, job.progress_ratio),
        cookies_changed = result.cookies_changed == true,
        cookies = result.cookies,
        wr_ticket_changed = result.wr_ticket_changed == true,
        wr_ticket = result.wr_ticket,
        wr_wrpa_changed = result.wr_wrpa_changed == true,
        wr_wrpa = result.wr_wrpa,
        response_summary = result.ok == true and "succ=1 (0.3.6.7 original path)"
            or tostring(result.error or "0.3.6.7 original path rejected"),
        attempts = { { stage = tostring(result.path or "legacy") } },
        payload_public = { legacy_original = true },
    }
end

return Adapter
