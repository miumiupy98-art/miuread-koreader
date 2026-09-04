local lfs = require("libs/libkoreader-lfs")
local U = require("miuread.util")

local M = {}

local function human_size(bytes)
    bytes = tonumber(bytes or 0) or 0
    if bytes >= 1024 * 1024 * 1024 then return string.format("%.1f GB", bytes / (1024 * 1024 * 1024)) end
    if bytes >= 1024 * 1024 then return string.format("%.1f MB", bytes / (1024 * 1024)) end
    if bytes >= 1024 then return string.format("%.1f KB", bytes / 1024) end
    return tostring(math.floor(bytes + .5)) .. " B"
end

local function generated_book(plugin, book_id)
    local stored = plugin.store:book(book_id) or {}
    return {
        bookId = tostring(stored.book_id or book_id),
        book_id = tostring(stored.book_id or book_id),
        title = stored.title,
        author = stored.author,
        cover = stored.cover,
    }
end

local function show_variant(plugin, book_id, variant)
    local book = generated_book(plugin, book_id)
    local kind = tostring(variant.kind or "")
    local label = tostring(variant.label or "版本")
    local items = {
        {text = "文件大小", post_text = human_size(variant.size), enabled = false},
        {text = "打开" .. label, callback = function() plugin:open_file(variant.file) end},
    }
    if kind == "clean" or kind == "notes" then
        local annotations = kind == "notes"
        items[#items + 1] = {
            text = "重新下载" .. label,
            callback = function() plugin:choose_download_mode(book, {annotations = annotations}, false) end,
        }
    end
    items[#items + 1] = {
        text = "删除" .. label,
        callback = function() plugin:_confirm_delete_variant(book_id, kind, book.title or book_id) end,
    }
    return plugin:list(label .. " · 本机文件", items)
end

function M.open_variant(plugin, book_id, kind)
    book_id,kind=tostring(book_id or ""),tostring(kind or "")
    if book_id=="" or kind=="" then plugin:toast("无法识别这个版本"); return false end
    plugin.store:reload(); plugin.store:prune_missing_files()
    local summary=plugin.book_delete_service and plugin.book_delete_service:summary(book_id) or nil
    for _,variant in ipairs(summary and summary.variants or {}) do
        if tostring(variant.kind or "")==kind then return show_variant(plugin,book_id,variant) end
    end
    plugin:toast("这个版本已经不在本机")
    return false
end

function M.open_generated(plugin, book_ref)
    local book_id = type(book_ref) == "table" and tostring(book_ref.book_id or book_ref.bookId or "") or tostring(book_ref or "")
    if book_id == "" then plugin:toast("无法识别这本书"); return false end
    plugin.store:reload()
    plugin.store:prune_missing_files()
    local service = plugin.book_delete_service
    local summary = service and service:summary(book_id) or nil
    if not summary or summary.has_local ~= true then
        plugin:toast("这本书没有本机可阅读内容")
        return false
    end
    local stored = plugin.store:book(book_id) or {}
    local items = {}
    for _, variant in ipairs(summary.variants or {}) do
        local current = variant
        items[#items + 1] = {
            text = tostring(current.label),
            post_text = human_size(current.size),
            callback = function() show_variant(plugin, book_id, current) end,
        }
    end
    if tonumber(summary.chapter_count or 0) > 0 then
        items[#items + 1] = {
            text = "已下载章节",
            post_text = tostring(summary.chapter_count) .. " 章 · " .. human_size(summary.chapter_bytes),
            callback = function() plugin:downloaded_chapters_menu(book_id) end,
        }
    end
    items[#items + 1] = {
        text = "删除全部本机内容",
        separator = true,
        callback = function() plugin:_confirm_delete_book_downloads(book_id, stored.title or book_id) end,
    }
    return plugin:list("本机文件 · " .. tostring(stored.title or book_id), items)
end

function M.open_local(plugin, book)
    book = type(book) == "table" and U.copy(book) or {}
    local path = tostring(book.file or book.local_path or "")
    if path == "" or lfs.attributes(path, "mode") ~= "file" then
        plugin:toast("本地文件已经不存在")
        if plugin.book_delete_service then plugin.book_delete_service:prune_missing_local_references() end
        if type(plugin._emit_book_local_content_changed) == "function" then plugin:_emit_book_local_content_changed(nil, path) end
        return false
    end
    local size = plugin.book_delete_service and plugin.book_delete_service:local_file_size(path) or (tonumber((lfs.attributes(path) or {}).size) or 0)
    local items = {
        {text = path:match("([^/]+)$") or path, post_text = human_size(size), enabled = false},
        {text = "在 KOReader 文件管理中查看", callback = function() plugin:_home_open_koreader_filemanager(path, true) end},
        {text = "删除本地文件", separator = true, callback = function()
            local current = tostring(plugin:_current_document_path() or "")
            if current ~= "" and current == path then
                plugin:info("当前书籍正在阅读中，请先退出后再删除。")
                return
            end
            local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
            if not ok or not FileManager or type(FileManager.showDeleteFileDialog) ~= "function" then
                plugin:info("当前 KOReader 没有可用的原生文件删除入口。")
                return
            end
            local plan = plugin.book_delete_service:plan_local_file(path)
            FileManager:showDeleteFileDialog(path, function()
                plugin.store:reload()
                plugin.book_delete_service:commit(plan)
                local checked = plugin.book_delete_service:verify(plan)
                if not checked.ok then
                    -- Native KOReader owns the physical file delete; retry only
                    -- MiuRead's reference cleanup once instead of bypassing the
                    -- native file manager with a raw filesystem delete.
                    plugin.book_delete_service:commit(plan)
                    plugin.book_delete_service:prune_missing_local_references()
                    checked = plugin.book_delete_service:verify(plan)
                end
                if not checked.ok then
                    plugin:info("本地文件删除已经执行，但仍检测到 "..tostring(#(checked.paths or {})).." 个文件残留或 "
                        ..tostring(#(checked.refs or {})).." 个索引残留。请刷新本地书库后再检查。")
                else
                    plugin:toast("本地文件已删除", 3)
                end
                if type(plugin._emit_book_local_content_changed) == "function" then plugin:_emit_book_local_content_changed(nil, path) end
            end)
        end},
    }
    return plugin:list("本机文件 · " .. tostring(book.title or (path:match("([^/]+)$") or "本地书")), items)
end

return M
