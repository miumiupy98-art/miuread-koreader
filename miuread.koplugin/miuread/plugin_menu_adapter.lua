local logger = require("logger")

local M = {}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function call_provider(owner, label, fn, fallback)
    if type(fn) ~= "function" then
        return fn == nil and fallback or fn, true
    end
    local ok, result = xpcall(fn, debug.traceback)
    if ok then return result, true end
    logger.warn("[MiuRead][PluginMenuAdapter] provider failed", tostring(label or "provider"), tostring(result))
    if owner and type(owner.info) == "function" then
        owner:info("这个插件菜单暂时无法读取。\n\n" .. tostring(result))
    end
    return fallback, false
end

local function resolve_text(owner, source)
    if type(source.text_func) == "function" then
        local value = call_provider(owner, "text_func", source.text_func, "")
        return tostring(value or "")
    end
    return tostring(source.text or source.label or "")
end

local function resolve_enabled(owner, source)
    local enabled = source.enabled ~= false
    if type(source.enabled_func) == "function" then
        local value, ok = call_provider(owner, "enabled_func", source.enabled_func, false)
        enabled = ok and value ~= false
    end
    return enabled
end

local function resolve_checked(owner, source)
    if type(source.checked_func) == "function" then
        local value, ok = call_provider(owner, "checked_func", source.checked_func, false)
        return ok and value == true
    end
    return source.checked == true
end

local function resolve_visible(owner, source)
    if source.hidden == true or source.visible == false then return false end
    if type(source.visible_func) == "function" then
        local value, ok = call_provider(owner, "visible_func", source.visible_func, true)
        return ok and value ~= false
    end
    return true
end

local function resolve_right_value(owner, source)
    local providers = {
        {"right_value_func", source.right_value_func},
        {"mandatory_func", source.mandatory_func},
        {"post_text_func", source.post_text_func},
    }
    for _, entry in ipairs(providers) do
        if type(entry[2]) == "function" then
            local value = call_provider(owner, entry[1], entry[2], "")
            value = trim(value)
            if value ~= "" then return value end
        end
    end
    local static = source.right_value
    if static == nil or static == "" then static = source.mandatory end
    if static == nil or static == "" then static = source.post_text end
    if type(static) == "function" then
        local value = call_provider(owner, "post_text", static, "")
        return trim(value)
    end
    return trim(static)
end

local function resolve_children(owner, source)
    local child = source.sub_item_table
    if type(source.sub_item_table_func) == "function" then
        local result, ok = call_provider(owner, "sub_item_table_func", source.sub_item_table_func, {})
        if not ok then return {} end
        child = result
    end
    return type(child) == "table" and child or {}
end

local function action_wrapper(owner, source, label, kind)
    local fn = kind == "hold" and source.hold_callback or source.callback
    if type(fn) ~= "function" then return nil end
    return function(...)
        logger.info("[MiuRead][PluginMenu] item", kind == "hold" and "held" or "tapped", tostring(label or ""))
        local args = {...}
        local unpack_args = unpack or table.unpack
        local ok, result = xpcall(function() return fn(unpack_args(args)) end, debug.traceback)
        if not ok then
            logger.warn("[MiuRead][PluginMenuAdapter] callback failed", tostring(label or ""), tostring(result))
            if owner and type(owner.info) == "function" then
                owner:info("这个插件功能暂时无法打开。\n\n" .. tostring(result))
            end
        end
        return result
    end
end

function M.rows(owner, items, options)
    options = type(options) == "table" and options or {}
    items = type(items) == "table" and items or {}
    local rows = {}
    for _, source in ipairs(items) do
        if type(source) == "table" and resolve_visible(owner, source) then
            local label = resolve_text(owner, source)
            local enabled = resolve_enabled(owner, source)
            local checked = resolve_checked(owner, source)
            local value = resolve_right_value(owner, source)
            local has_children = type(source.sub_item_table_func) == "function" or type(source.sub_item_table) == "table"
            local row = {
                label = label,
                value = value,
                detail = tostring(source.detail or source.help_text or ""),
                enabled = enabled,
                checked = checked,
                radio = source.radio == true,
                bold = source.bold == true or source.heading == true,
                separator = source.separator == true,
                value_bold = source.mandatory_bold == true or source.value_bold == true,
                arrow = has_children or source.arrow == true or source.show_chevron == true,
                keep_open = source.keep_menu_open == true,
            }
            local icon_key = source.icon_key or source.icon
            if icon_key and tostring(icon_key) ~= "" then row.icon = tostring(icon_key) end

            if checked and options.prefix_checked ~= false then
                row.label = (source.radio == true and "● " or "✓ ") .. row.label
            end

            if has_children then
                row.child_title = label ~= "" and label or tostring(options.child_title or "插件菜单")
                row.children_provider = function()
                    return M.rows(owner, resolve_children(owner, source), options)
                end
            elseif type(source.callback) == "function" then
                row.callback = action_wrapper(owner, source, label, "tap")
            end
            if type(source.hold_callback) == "function" then
                row.hold_callback = action_wrapper(owner, source, label, "hold")
            end
            rows[#rows + 1] = row
        end
    end
    return rows
end

function M.menu_items(instance)
    if type(instance) ~= "table" or type(instance.addToMainMenu) ~= "function" then return nil end

    -- Most KOReader plugins register entries with assignments such as
    -- menu_items.foo = {...}. Capture those writes so MiuRead can preserve the
    -- author's registration order instead of alphabetically re-sorting it.
    -- A small fallback pass still includes plugins that deliberately use rawset.
    local map, insertion_order, seen = {}, {}, {}
    setmetatable(map, {
        __newindex = function(t, key, value)
            if rawget(t, key) == nil and not seen[key] then
                seen[key] = true
                insertion_order[#insertion_order + 1] = key
            end
            rawset(t, key, value)
        end,
    })
    local ok, err = xpcall(function() return instance:addToMainMenu(map) end, debug.traceback)
    if not ok then
        logger.warn("[MiuRead][PluginMenuAdapter] addToMainMenu failed", tostring(err))
        return nil, err
    end

    local out = {}
    for _, key in ipairs(insertion_order) do
        local item = rawget(map, key)
        if type(item) == "table" then out[#out + 1] = item end
    end
    local fallback = {}
    for key, item in pairs(map) do
        if type(item) == "table" and not seen[key] then fallback[#fallback + 1] = {key=key,item=item} end
    end
    table.sort(fallback, function(a,b)
        if type(a.key)=="number" and type(b.key)=="number" then return a.key<b.key end
        if type(a.key)=="number" then return true end
        if type(b.key)=="number" then return false end
        return tostring(a.key)<tostring(b.key)
    end)
    for _, entry in ipairs(fallback) do out[#out + 1] = entry.item end
    return out
end

return M
