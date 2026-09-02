local AnnotationCoord = require("miuread.annotation_coord")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local U = require("miuread.util")
local logger = require("logger")

local Overlay = {}
Overlay.__index = Overlay

local MODULE_NAME = "miuread_runtime_thoughts"
local SEARCH_FLAGS = 0x00FF -- KOReader enhanced text search: nodes/spaces/punctuation normalization.
local MAX_QUERY_BYTES = 4096
local MAX_LOCATIONS_PER_REFRESH = 6

local function compact(value)
    value = tostring(value or "")
    value = value:gsub("[ \t\r\n\f\v]+", "")
    value = value:gsub("\194\160", "")      -- NBSP
    value = value:gsub("\226\128\139", "") -- zero-width space
    value = value:gsub("\226\128\140", "") -- zero-width non-joiner
    value = value:gsub("\226\128\141", "") -- zero-width joiner
    value = value:gsub("\239\187\191", "") -- UTF-8 BOM
    return value
end

local function head_chars(value, count)
    value = tostring(value or "")
    local n = U.utf8_len(value)
    if n <= count then return value end
    return U.utf8_sub(value, 1, count)
end

local function tail_chars(value, count)
    value = tostring(value or "")
    local n = U.utf8_len(value)
    if n <= count then return value end
    return U.utf8_sub(value, n - count + 1, n)
end

local function context_score(entry, before, after)
    local score = 0
    local expected_before = tail_chars(compact(entry.context_before), 18)
    local expected_after = head_chars(compact(entry.context_after), 18)
    local actual_before = compact(before)
    local actual_after = compact(after)
    if expected_before ~= "" and #actual_before >= #expected_before
        and actual_before:sub(-#expected_before) == expected_before then
        score = score + 1
    end
    if expected_after ~= "" and #actual_after >= #expected_after
        and actual_after:sub(1, #expected_after) == expected_after then
        score = score + 1
    end
    return score
end

local function rect_visible(rect, screen_w, screen_h)
    if type(rect) ~= "table" then return false end
    local x, y = tonumber(rect.x), tonumber(rect.y)
    local w, h = tonumber(rect.w), tonumber(rect.h)
    if not x or not y or not w or not h or w <= 0 or h <= 0 then return false end
    return x < screen_w and y < screen_h and x + w > 0 and y + h > 0
end

local function result_key(row)
    if type(row) ~= "table" then return "" end
    return tostring(row.start or "") .. "\0" .. tostring(row["end"] or "")
end

function Overlay:new(host)
    return setmetatable({
        host = host,
        ui = nil,
        view = nil,
        document = nil,
        enabled = true,
        book_id = "",
        chapter_uid = "",
        entries = {},
        hitboxes = {},
        prepared = false,
        source_error = nil,
    }, self)
end

function Overlay:install(ui)
    if not (ui and ui.view and type(ui.view.registerViewModule) == "function") then
        return false, "reader_view_module_unavailable"
    end
    if self.view and self.view ~= ui.view and type(self.view.view_modules) == "table" then
        self.view.view_modules[MODULE_NAME] = nil
    end
    self.ui = ui
    self.view = ui.view
    self.document = ui.document
    self.view:registerViewModule(MODULE_NAME, self)
    return true
end

function Overlay:detach()
    if self.view and type(self.view.view_modules) == "table"
        and self.view.view_modules[MODULE_NAME] == self then
        self.view.view_modules[MODULE_NAME] = nil
    end
    self.ui = nil
    self.view = nil
    self.document = nil
    self:clear()
end

function Overlay:setEnabled(enabled)
    self.enabled = enabled ~= false
    if not self.enabled then self.hitboxes = {} end
    if self.ui then UIManager:setDirty(self.ui, "partial") end
end

function Overlay:clear()
    self.book_id = ""
    self.chapter_uid = ""
    self.entries = {}
    self.hitboxes = {}
    self.prepared = false
    self.source_error = nil
    if self.ui then UIManager:setDirty(self.ui, "partial") end
end

function Overlay:isPreparedFor(book_id, chapter_uid)
    return self.prepared == true
        and self.book_id == tostring(book_id or "")
        and self.chapter_uid == tostring(chapter_uid or "")
end

function Overlay:hasEntries()
    return self.prepared == true and #self.entries > 0
end

function Overlay:stats()
    local mapped = 0
    for _, entry in ipairs(self.entries) do
        if entry.pos0 and entry.pos1 then mapped = mapped + 1 end
    end
    return {groups=#self.entries, mapped=mapped}
end

function Overlay:prepare(book_id, chapter_uid, coord_html, groups)
    book_id = tostring(book_id or "")
    chapter_uid = tostring(chapter_uid or "")
    if book_id == "" or chapter_uid == "" then
        self:clear()
        return false, "comment_scope_missing"
    end
    local ok, map = pcall(AnnotationCoord.build, tostring(coord_html or ""))
    if not ok or type(map) ~= "table" then
        self:clear()
        self.source_error = "coord_map_build_failed"
        return false, tostring(map or "coord_map_build_failed")
    end

    local entries = {}
    for _, group in ipairs(type(groups) == "table" and groups or {}) do
        local range = tostring(type(group) == "table" and group.range or "")
        if range ~= "" then
            local resolved, err = AnnotationCoord.resolveRangeOnMap(map, range)
            if resolved and resolved.point ~= true then
                local text = tostring(resolved.text or "")
                local query = U.trim(text)
                local normalized = compact(text)
                if normalized ~= "" and query ~= "" and #query <= MAX_QUERY_BYTES then
                    local before, after = AnnotationCoord.contextForSpan(
                        map, resolved.text_start, resolved.text_end_pos, 36)
                    entries[#entries + 1] = {
                        range = range,
                        text = text,
                        query = query,
                        compact = normalized,
                        head = head_chars(normalized, 12),
                        tail = tail_chars(normalized, 12),
                        context_before = before,
                        context_after = after,
                        source_start = tonumber(resolved.text_start) or 0,
                    }
                else
                    logger.warn("[MiuRead][RuntimeThought] source text skipped",
                        "chapter=", chapter_uid, "range=", range,
                        "reason=", normalized == "" and "empty" or "oversize")
                end
            elseif err then
                logger.warn("[MiuRead][RuntimeThought] range resolve skipped",
                    "chapter=", chapter_uid, "range=", range, "reason=", tostring(err))
            end
        end
    end
    table.sort(entries, function(a, b)
        if a.source_start == b.source_start then return a.range < b.range end
        return a.source_start < b.source_start
    end)

    self.book_id = book_id
    self.chapter_uid = chapter_uid
    self.entries = entries
    self.hitboxes = {}
    self.prepared = true
    self.source_error = nil
    logger.info("[MiuRead][RuntimeThought] chapter prepared",
        "book=", book_id, "chapter=", chapter_uid, "groups=", tostring(#entries))
    if self.ui then UIManager:setDirty(self.ui, "partial") end
    return true, {groups=#entries}
end

function Overlay:_screen_text()
    local doc = self.document
    if not (doc and type(doc.getTextFromPositions) == "function") then return nil end
    local w, h = Device.screen:getWidth(), Device.screen:getHeight()
    local ok, value = pcall(doc.getTextFromPositions, doc,
        {x=1, y=1}, {x=math.max(1, w - 2), y=math.max(1, h - 2)}, true)
    if not ok or type(value) ~= "table" then return nil end
    return tostring(value.text or "")
end

function Overlay:_candidate_on_screen(entry, visible_compact)
    if entry.compact == "" or visible_compact == "" then return false end
    if visible_compact:find(entry.compact, 1, true) then return true end
    -- Long selections may cross a page boundary. A source-side signature is
    -- enough to trigger exact full-range search; acceptance still requires the
    -- full returned text and on-screen geometry to match.
    if #entry.head >= 6 and visible_compact:find(entry.head, 1, true) then return true end
    if #entry.tail >= 6 and visible_compact:find(entry.tail, 1, true) then return true end
    return false
end

function Overlay:_locate_entry(entry)
    local doc = self.document
    if not (doc and type(doc.findText) == "function"
        and type(doc.getTextFromXPointers) == "function"
        and type(doc.getScreenBoxesFromPositions) == "function") then
        return false, "document_search_unavailable"
    end

    local rows, seen = {}, {}
    for _, direction in ipairs({0, 1}) do
        local ok, found = pcall(doc.findText, doc, entry.query, 0, direction,
            true, nil, false, 64, SEARCH_FLAGS)
        if ok and type(found) == "table" then
            for _, row in ipairs(found) do
                local key = result_key(row)
                if key ~= "" and not seen[key] then
                    seen[key] = true
                    rows[#rows + 1] = row
                end
            end
        end
    end
    if #rows == 0 then return false, "not_found" end

    local screen_w, screen_h = Device.screen:getWidth(), Device.screen:getHeight()
    local valid = {}
    for _, row in ipairs(rows) do
        local pos0, pos1 = row.start, row["end"]
        if pos0 and pos1 then
            local boxes_ok, boxes = pcall(doc.getScreenBoxesFromPositions, doc, pos0, pos1, true)
            local visible = false
            if boxes_ok and type(boxes) == "table" then
                for _, box in ipairs(boxes) do
                    if rect_visible(box, screen_w, screen_h) then visible = true; break end
                end
            end
            if visible then
                local text_ok, selected = pcall(doc.getTextFromXPointers, doc, pos0, pos1, false)
                if text_ok and compact(selected) == entry.compact then
                    local score = 0
                    if type(doc.getSelectedWordContext) == "function" then
                        local context_ok, before, after = pcall(
                            doc.getSelectedWordContext, doc, entry.text, 6, pos0, pos1, false)
                        if context_ok then score = context_score(entry, before, after) end
                    end
                    valid[#valid + 1] = {pos0=pos0, pos1=pos1, score=score}
                end
            end
        end
    end
    if #valid == 0 then return false, "no_visible_exact_match" end
    if #valid == 1 then
        entry.pos0, entry.pos1 = valid[1].pos0, valid[1].pos1
        return true
    end

    table.sort(valid, function(a, b) return a.score > b.score end)
    if valid[1].score > 0 and valid[1].score > valid[2].score then
        entry.pos0, entry.pos1 = valid[1].pos0, valid[1].pos1
        return true
    end
    return false, "ambiguous"
end

function Overlay:refreshVisible(max_new)
    if not self.enabled or not self.prepared or #self.entries == 0 then return 0 end
    local visible_text = self:_screen_text()
    if not visible_text then return 0 end
    local visible_compact = compact(visible_text)
    if visible_compact == "" then return 0 end

    max_new = math.max(1, math.min(MAX_LOCATIONS_PER_REFRESH, tonumber(max_new) or MAX_LOCATIONS_PER_REFRESH))
    local mapped = 0
    for _, entry in ipairs(self.entries) do
        if mapped >= max_new then break end
        if not entry.pos0 and self:_candidate_on_screen(entry, visible_compact) then
            local ok, reason = self:_locate_entry(entry)
            if ok then
                mapped = mapped + 1
                logger.info("[MiuRead][RuntimeThought] range mapped",
                    "chapter=", self.chapter_uid, "range=", entry.range)
            elseif reason == "ambiguous" then
                logger.warn("[MiuRead][RuntimeThought] ambiguous range left hidden",
                    "chapter=", self.chapter_uid, "range=", entry.range)
            end
        end
    end
    if mapped > 0 and self.ui then UIManager:setDirty(self.ui, "partial") end
    return mapped
end

function Overlay:hitTest(pos)
    if not self.enabled or not self.prepared or type(pos) ~= "table" then return nil end
    local x, y = tonumber(pos.x), tonumber(pos.y)
    if not x or not y then return nil end
    for _, hit in ipairs(self.hitboxes or {}) do
        if x >= hit.x and x <= hit.x + hit.w and y >= hit.y and y <= hit.y + hit.h then
            return {
                book_id = self.book_id,
                chapter_uid = self.chapter_uid,
                range = hit.range,
            }
        end
    end
    return nil
end

function Overlay:resetLayout()
    self.hitboxes = {}
    if self.host and type(self.host._schedule_runtime_thought_refresh) == "function" then
        self.host:_schedule_runtime_thought_refresh(.18, true)
    end
end

function Overlay:paintTo(bb, _x, _y)
    self.hitboxes = {}
    if not self.enabled or not self.prepared or #self.entries == 0 then return end
    local doc = self.document
    if not (doc and type(doc.getCurrentPos) == "function"
        and type(doc.getPosFromXPointer) == "function"
        and type(doc.getScreenBoxesFromPositions) == "function") then return end

    local current_ok, current_top = pcall(doc.getCurrentPos, doc)
    if not current_ok or type(current_top) ~= "number" then return end
    local screen_w, screen_h = Device.screen:getWidth(), Device.screen:getHeight()
    local current_bottom = current_top + screen_h * 2
    local thickness = math.max(1, Device.screen:scaleBySize(1))
    local dash = math.max(3, Device.screen:scaleBySize(4))
    local gap = math.max(2, Device.screen:scaleBySize(3))
    local hit_margin = math.max(4, Device.screen:scaleBySize(6))

    for _, entry in ipairs(self.entries) do
        if entry.pos0 and entry.pos1 then
            local start_ok, start_pos = pcall(doc.getPosFromXPointer, doc, entry.pos0)
            local end_ok, end_pos = pcall(doc.getPosFromXPointer, doc, entry.pos1)
            if start_ok and end_ok and type(start_pos) == "number" and type(end_pos) == "number"
                and start_pos <= current_bottom and end_pos >= current_top then
                local boxes_ok, boxes = pcall(doc.getScreenBoxesFromPositions, doc, entry.pos0, entry.pos1, true)
                if boxes_ok and type(boxes) == "table" then
                    for _, box in ipairs(boxes) do
                        if rect_visible(box, screen_w, screen_h) then
                            local left = math.max(0, math.floor(tonumber(box.x) or 0))
                            local right = math.min(screen_w, math.ceil((tonumber(box.x) or 0) + (tonumber(box.w) or 0)))
                            local line_y = math.min(screen_h - thickness,
                                math.max(0, math.floor((tonumber(box.y) or 0) + (tonumber(box.h) or 0) - thickness)))
                            local cursor = left
                            while cursor < right do
                                local width = math.min(dash, right - cursor)
                                if width > 0 then
                                    bb:paintRect(cursor, line_y, width, thickness, Blitbuffer.COLOR_BLACK)
                                end
                                cursor = cursor + dash + gap
                            end
                            self.hitboxes[#self.hitboxes + 1] = {
                                x = math.max(0, left - hit_margin),
                                y = math.max(0, math.floor((tonumber(box.y) or 0) - hit_margin)),
                                w = math.min(screen_w, right + hit_margin) - math.max(0, left - hit_margin),
                                h = math.min(screen_h, math.ceil((tonumber(box.y) or 0) + (tonumber(box.h) or 0) + hit_margin))
                                    - math.max(0, math.floor((tonumber(box.y) or 0) - hit_margin)),
                                range = entry.range,
                            }
                        end
                    end
                end
            end
        end
    end
end

return Overlay
