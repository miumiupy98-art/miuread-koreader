local M = {}

M.MARKER_BEGIN = "/* MIUREAD_ANNOTATION_STYLE_V2_BEGIN */"
M.MARKER_END = "/* MIUREAD_ANNOTATION_STYLE_V2_END */"

-- Keep this intentionally close to the proven weread implementation.
-- The thought text uses its own class, so it can never inherit the solid
-- underline rule used by ordinary WeRead marks.
M.CSS = [[
/* MIUREAD_ANNOTATION_STYLE_V2_BEGIN */
.miu-inline-mark {
    text-decoration: underline;
}
.miu-thought-link {
    text-decoration: none;
    color: inherit;
}
.miu-thought-link .miu-thought-mark {
    color: inherit;
}
.miu-thought-mark {
    border-bottom: 2px dashed #ff6b35;
    padding-bottom: 2px;
}
.miu-thought-star {
    font-size: 0;
    line-height: 0;
    margin: 0;
    padding: 0;
    color: transparent;
}
/* MIUREAD_ANNOTATION_STYLE_V2_END */
]]

M.INLINE_STYLE_ID = "miuread-annotation-style"

function M.inline_style_tag()
    return '<style id="' .. M.INLINE_STYLE_ID .. '" type="text/css">\n'
        .. M.CSS
        .. '\n</style>'
end

local OLD_MARKERS = {
    {"/* MIUREAD_ANNOTATION_STYLE_REPAIR_BEGIN */", "/* MIUREAD_ANNOTATION_STYLE_REPAIR_END */"},
    {M.MARKER_BEGIN, M.MARKER_END},
}

local TARGET_SELECTORS = {
    ".miu-inline-mark",
    ".miu-thought-mark",
    ".miu-thought-link",
    ".miu-thought-star",
    ".miu-has-thought",
    -- Legacy selectors are kept only so regenerated books discard stale rules.
    ".miu-unlocated",
    ".miu-unlocated-note",
    ".miu-unlocated-item",
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

local function style_bounds_for_token(html, token)
    local token_at = html:find(token, 1, true)
    if not token_at then return nil end
    local before = html:sub(1, token_at)
    local open_at = before:match(".*()<style")
    local open_end = open_at and html:find(">", open_at, true) or nil
    local close_at = open_end and html:find("</style>", open_end + 1, true) or nil
    if not open_at or not open_end or not close_at then return nil end
    return open_at, open_end, close_at
end

local function replace_style_block(html, open_at, close_at, replacement)
    return html:sub(1, open_at - 1)
        .. replacement
        .. html:sub(close_at + #"</style>")
end

local function ensure_inline_style(html)
    if not html:find("data-miuread-book=", 1, true) then return html, false end

    local replacement = M.inline_style_tag()
    local open_at, _, close_at = style_bounds_for_token(html, 'id="' .. M.INLINE_STYLE_ID .. '"')
    if not open_at then
        open_at, _, close_at = style_bounds_for_token(html, "id='" .. M.INLINE_STYLE_ID .. "'")
    end
    if open_at then
        local current = html:sub(open_at, close_at + #"</style>" - 1)
        if current == replacement then return html, false end
        return replace_style_block(html, open_at, close_at, replacement), true
    end

    -- Experimental builds embedded the whole book stylesheet without an id.
    -- Replace it with the lightweight annotation-only block; the full stylesheet
    -- remains available through the existing external style.css reference.
    open_at, _, close_at = style_bounds_for_token(html, M.MARKER_BEGIN)
    if open_at then
        return replace_style_block(html, open_at, close_at, replacement), true
    end

    local head_end = html:find("</head>", 1, true)
    if not head_end then return html, false end
    return html:sub(1, head_end - 1) .. replacement .. html:sub(head_end), true
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
    local with_style, style_changed = ensure_inline_style(rewritten)
    return with_style, changed or style_changed or with_style ~= original
end

function M.xhtml_is_current(html)
    html = tostring(html or "")
    if not html:find("data-miuread-book=", 1, true) then return true end
    return html:find('id="' .. M.INLINE_STYLE_ID .. '"', 1, true) ~= nil
        and html:find(M.MARKER_BEGIN, 1, true) ~= nil
        and html:find("border-bottom: 2px dashed #ff6b35;", 1, true) ~= nil
end

function M.css_is_current(css)
    css = tostring(css or "")
    return css:find(M.MARKER_BEGIN, 1, true) ~= nil
        and css:find(".miu-thought-mark", 1, true) ~= nil
        and css:find("border-bottom: 2px dashed #ff6b35;", 1, true) ~= nil
        and css:find(".miu-inline-mark.miu-has-thought", 1, true) == nil
        and css:find(".miu-thought-link .miu-inline-mark", 1, true) == nil
end

return M
