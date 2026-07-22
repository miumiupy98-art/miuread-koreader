local M = {}

M.MARKER_BEGIN = "/* MIUREAD_ANNOTATION_STYLE_V4_BEGIN */"
M.MARKER_END = "/* MIUREAD_ANNOTATION_STYLE_V4_END */"
M.LINK_INLINE_STYLE = "text-decoration:none; border-bottom:0; color:inherit;"
M.MARK_INLINE_STYLE = "text-decoration:none; border-bottom:2px dashed #555; padding-bottom:2px; color:inherit;"

-- Use one unmistakable style for every WeRead mark. Publisher styles and
-- KOReader's default link decoration must not turn thought links into solid
-- or double underlines.
M.CSS = [[
/* MIUREAD_ANNOTATION_STYLE_V4_BEGIN */
.miu-inline-mark {
    text-decoration: none;
    border-bottom: 2px dashed #555;
    padding-bottom: 2px;
}
.miu-thought-link {
    text-decoration: none;
    border-bottom: 0;
    color: inherit;
}
.miu-thought-mark {
    text-decoration: none;
    border-bottom: 2px dashed #555;
    padding-bottom: 2px;
    color: inherit;
}
.miu-thought-star {
    font-size: 0;
    line-height: 0;
    margin: 0;
    padding: 0;
    color: transparent;
}
/* MIUREAD_ANNOTATION_STYLE_V4_END */
]]

local OLD_MARKERS = {
    {"/* MIUREAD_ANNOTATION_STYLE_REPAIR_BEGIN */", "/* MIUREAD_ANNOTATION_STYLE_REPAIR_END */"},
    {"/* MIUREAD_ANNOTATION_STYLE_V2_BEGIN */", "/* MIUREAD_ANNOTATION_STYLE_V2_END */"},
    {"/* MIUREAD_ANNOTATION_STYLE_V3_BEGIN */", "/* MIUREAD_ANNOTATION_STYLE_V3_END */"},
    {"/* MIUREAD_UNIFIED_DASHED_MARKS_BEGIN */", "/* MIUREAD_UNIFIED_DASHED_MARKS_END */"},
    {M.MARKER_BEGIN, M.MARKER_END},
}

local TARGET_SELECTORS = {
    ".miu-inline-mark",
    ".miu-thought-mark",
    ".miu-thought-link",
    ".miu-thought-star",
    ".miu-has-thought",
}

local function strip_marked_block(css, begin_marker, end_marker)
    local start_at = css:find(begin_marker, 1, true)
    while start_at do
        local end_at = css:find(end_marker, start_at + #begin_marker, true)
        if not end_at then
            css = css:sub(1, start_at - 1)
            break
        end
        css = css:sub(1, start_at - 1) .. css:sub(end_at + #end_marker)
        start_at = css:find(begin_marker, 1, true)
    end
    return css
end

local function selector_is_annotation(selector)
    selector = tostring(selector or "")
    for _, needle in ipairs(TARGET_SELECTORS) do
        if selector:find(needle, 1, true) then return true end
    end
    return false
end

-- MiuRead-generated style.css is a flat list of rules. Remove every previous
-- annotation rule completely, instead of appending a higher-specificity patch.
local function strip_annotation_rules(css)
    local out = {}
    local cursor = 1
    while true do
        local open_at = css:find("{", cursor, true)
        if not open_at then
            out[#out + 1] = css:sub(cursor)
            break
        end
        local close_at = css:find("}", open_at + 1, true)
        if not close_at then
            out[#out + 1] = css:sub(cursor)
            break
        end
        local selector = css:sub(cursor, open_at - 1)
        local rule = css:sub(cursor, close_at)
        if not selector_is_annotation(selector) then out[#out + 1] = rule end
        cursor = close_at + 1
    end
    return table.concat(out)
end

function M.rewrite_css(css)
    local original = tostring(css or "")
    local rewritten = original
    for _, markers in ipairs(OLD_MARKERS) do
        rewritten = strip_marked_block(rewritten, markers[1], markers[2])
    end
    rewritten = strip_annotation_rules(rewritten)
    rewritten = rewritten:gsub("%s+$", "") .. "\n\n" .. M.CSS
    return rewritten, rewritten ~= original
end

local function rewrite_class_value(value)
    local kept, seen = {}, {}
    local has_inline, has_thought, has_thought_mark = false, false, false
    for token in tostring(value or ""):gmatch("%S+") do
        if token == "miu-inline-mark" then
            has_inline = true
        elseif token == "miu-has-thought" then
            has_thought = true
        elseif token == "miu-thought-mark" then
            has_thought_mark = true
        elseif not seen[token] then
            seen[token] = true
            kept[#kept + 1] = token
        end
    end
    if has_thought or has_thought_mark then
        local out = {"miu-thought-mark"}
        for _, token in ipairs(kept) do out[#out + 1] = token end
        local normalized = table.concat(out, " ")
        return normalized, normalized ~= tostring(value or "")
    end
    if has_inline then
        local out = {"miu-inline-mark"}
        for _, token in ipairs(kept) do out[#out + 1] = token end
        local normalized = table.concat(out, " ")
        return normalized, normalized ~= tostring(value or "")
    end
    return tostring(value or ""), false
end

function M.rewrite_xhtml(html)
    local original = tostring(html or "")
    local changed = false
    local rewritten = original:gsub('class%s*=%s*"([^"]*)"', function(value)
        local new_value, did_change = rewrite_class_value(value)
        if did_change then changed = true end
        return 'class="' .. new_value .. '"'
    end)
    rewritten = rewritten:gsub("class%s*=%s*'([^']*)'", function(value)
        local new_value, did_change = rewrite_class_value(value)
        if did_change then changed = true end
        return "class='" .. new_value .. "'"
    end)
    return rewritten, changed or rewritten ~= original
end

function M.css_is_current(css)
    css = tostring(css or "")
    local rewritten = M.rewrite_css(css)
    return rewritten == css
        and css:find(M.MARKER_BEGIN, 1, true) ~= nil
        and css:find("border-bottom: 2px dashed #555;", 1, true) ~= nil
end

return M
