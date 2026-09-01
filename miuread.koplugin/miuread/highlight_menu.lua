--[[--
觅阅文字选择菜单。

把 KOReader 原本一次性铺开的划线菜单重排为：
  一级：高亮 / 添加笔记 / 书摘卡片 / 复制 / 词典 / 更多
  二级：翻译 / 维基百科 / 搜索 / 查看 HTML / 选择及其它条件动作

只替换当前 ReaderHighlight 实例的 onShowHighlightMenu，不改 KOReader 核心文件。
所有层级使用“关闭旧层 -> 下一 tick 打开新层”，避免两个 ButtonDialog 方框叠加。
--]]--

local UIManager = require("ui/uimanager")
local RawButtonDialog = require("ui/widget/buttondialog")
local GestureBridge = require("miuread.gesture_bridge")
local logger = require("logger")

local function gesture_aware_class(base, attrs)
    local class = base:extend(attrs or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local ButtonDialog = gesture_aware_class(RawButtonDialog, {
    _miuread_transient = true,
    _miuread_modal_surface = true,
})

local M = {}

local PRIMARY_KEYS = {
    "02_highlight",
    "04_add_note",
    "04_miuread_book_excerpt",
    "03_copy",
    "06_dictionary",
}

local SECONDARY_PREFERRED = {
    "07_translate",
    "05_wikipedia",
    "12_search",
    "09_view_html",
    "01_select",
    "11_follow_link",
    "08_share_text",
    "10_user_dict",
}

local PRIMARY_SET = {}
for _, key in ipairs(PRIMARY_KEYS) do PRIMARY_SET[key] = true end

local function button_for(highlight, key, index)
    local factory = highlight and type(highlight._highlight_buttons) == "table"
        and highlight._highlight_buttons[key] or nil
    if type(factory) ~= "function" then return nil end
    local ok, button = pcall(factory, highlight, index)
    if not ok then
        logger.warn("[MiuRead][HighlightMenu] button factory failed", tostring(key), tostring(button))
        return nil
    end
    if type(button) ~= "table" then return nil end
    if type(button.show_in_highlight_dialog_func) == "function" then
        local visible_ok, visible = pcall(button.show_in_highlight_dialog_func)
        if not visible_ok or visible ~= true then return nil end
    end
    return button
end

local function close_current(highlight)
    local dialog = highlight and highlight.highlight_dialog or nil
    if dialog then
        highlight.highlight_dialog = nil
        pcall(UIManager.close, UIManager, dialog)
    end
end

local function anchor_for(highlight, dialog, index)
    if highlight and type(highlight._getDialogAnchor) == "function" then
        local ok, anchor, pop_down = pcall(highlight._getDialogAnchor, highlight, dialog, index)
        if ok then return anchor, pop_down end
    end
    return nil
end

local function show_rows(highlight, index, rows)
    close_current(highlight)
    local dialog
    dialog = ButtonDialog:new{
        buttons = rows,
        anchor = function()
            return anchor_for(highlight, dialog, index)
        end,
        tap_close_callback = function()
            if highlight and highlight.hold_pos and type(highlight.clear) == "function" then
                pcall(highlight.clear, highlight)
            end
        end,
        close_callback = function()
            if highlight and highlight.highlight_dialog == dialog then
                highlight.highlight_dialog = nil
            end
        end,
    }
    highlight.highlight_dialog = dialog
    UIManager:show(dialog, "ui")
    return true
end

local function schedule_layer(highlight, index, builder)
    close_current(highlight)
    UIManager:scheduleIn(.035, function()
        if not (highlight and highlight.selected_text) then return end
        local ok, err = pcall(builder, highlight, index)
        if not ok then
            logger.warn("[MiuRead][HighlightMenu] layer failed", tostring(err))
            local original = highlight and highlight._miuread_original_on_show_highlight_menu or nil
            if type(original) == "function" then pcall(original, highlight, index) end
        end
    end)
    return true
end

local show_primary
local show_more

show_more = function(highlight, index)
    if not (highlight and highlight.selected_text) then return false end
    local rows, row = {}, {}
    local added = {}

    local function append_key(key)
        if added[key] or PRIMARY_SET[key] then return end
        local button = button_for(highlight, key, index)
        if not button then return end
        added[key] = true
        row[#row + 1] = button
        if #row >= 2 then rows[#rows + 1] = row; row = {} end
    end

    for _, key in ipairs(SECONDARY_PREFERRED) do append_key(key) end

    -- Keep third-party / device-specific actions reachable without letting them
    -- bloat the common first layer. Lexicographic order matches KOReader's own
    -- ordered highlight menu closely enough while remaining version-agnostic.
    local extras = {}
    for key, factory in pairs(type(highlight._highlight_buttons) == "table" and highlight._highlight_buttons or {}) do
        if type(factory) == "function" and not added[key] and not PRIMARY_SET[key] then
            extras[#extras + 1] = tostring(key)
        end
    end
    table.sort(extras)
    for _, key in ipairs(extras) do append_key(key) end

    if #row > 0 then rows[#rows + 1] = row end
    rows[#rows + 1] = {{
        text = "返回",
        callback = function()
            schedule_layer(highlight, index, show_primary)
        end,
    }}
    return show_rows(highlight, index, rows)
end

show_primary = function(highlight, index)
    if not (highlight and highlight.selected_text) then return false end

    local primary = {}
    for _, key in ipairs(PRIMARY_KEYS) do
        primary[#primary + 1] = button_for(highlight, key, index) or {
            text = key == "04_miuread_book_excerpt" and "书摘卡片" or "—",
            enabled = false,
        }
    end

    local more = {
        text = "更多",
        callback = function()
            schedule_layer(highlight, index, show_more)
        end,
    }

    -- Fixed 2 x 3 grid. Keeping the row count at two also lets KOReader's own
    -- highlight-position anchor choose above/below the selection more reliably.
    local rows = {
        {primary[1], primary[2], primary[3]},
        {primary[4], primary[5], more},
    }
    return show_rows(highlight, index, rows)
end

function M.install(highlight)
    if type(highlight) ~= "table" then return false, "highlight_missing" end
    if highlight._miuread_compact_highlight_menu == true then return true end
    if type(highlight.onShowHighlightMenu) ~= "function" then return false, "highlight_menu_api_missing" end
    if type(highlight._highlight_buttons) ~= "table" then return false, "highlight_buttons_missing" end

    highlight._miuread_original_on_show_highlight_menu = highlight.onShowHighlightMenu
    highlight.onShowHighlightMenu = function(this, index)
        local ok, result = pcall(show_primary, this, index)
        if ok then return result end
        logger.warn("[MiuRead][HighlightMenu] compact menu failed; using KOReader fallback", tostring(result))
        local original = this._miuread_original_on_show_highlight_menu
        if type(original) == "function" then return original(this, index) end
    end
    highlight._miuread_compact_highlight_menu = true
    logger.info("[MiuRead][HighlightMenu] compact 2x3 menu installed")
    return true
end

return M
