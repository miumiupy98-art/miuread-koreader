local Json = require("miuread.json")
local ThoughtDatabase = require("miuread.thought_database")
local U = require("miuread.util")
local lfs = require("libs/libkoreader-lfs")

local Migration = {}
Migration.__index = Migration

function Migration:new(store)
    return setmetatable({store=store}, self)
end

local function source_files(store, book_id)
    local dir = store:book_dir(book_id) .. "/thoughts"
    local rows = {}
    if lfs.attributes(dir, "mode") ~= "directory" then return rows end
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." and name:match("%.json$") then
            rows[#rows + 1] = {
                path=dir .. "/" .. name,
                chapter_uid=name:gsub("%.json$", ""),
            }
        end
    end
    table.sort(rows, function(a, b) return a.path < b.path end)
    return rows
end

function Migration:inspect(context)
    context = type(context) == "table" and context or {}
    local book = type(context.book) == "table" and context.book or {}
    local id = tostring(book.book_id or book.bookId or context.book_id or "")
    local files = id ~= "" and source_files(self.store, id) or {}
    local pending = 0
    for _, row in ipairs(files) do
        row.imported = ThoughtDatabase.chapter_exists(self.store, id, row.chapter_uid)
        if not row.imported then pending = pending + 1 end
    end
    local report = {
        ok=true, book_id=id, title=tostring(book.title or context.title or "当前书籍"),
        files=files, pending=pending, issues={},
    }
    if #files > 0 then
        report.issues[1] = {
            code="legacy_comments",
            title=pending > 0 and "检测到旧评论数据" or "检测到可清理的旧评论缓存",
        }
    end
    return report
end

function Migration:migrate(context, report, options)
    report = type(report) == "table" and report or self:inspect(context)
    options = type(options) == "table" and options or {}
    local result = {
        ok=true, cancelled=false, book_id=report.book_id, title=report.title,
        total=#(report.files or {}), processed=0, migrated=0, skipped=0,
        failed=0, groups=0, comments=0, failures={},
    }
    for index, row in ipairs(report.files or {}) do
        if options.cancelled and options.cancelled() then
            result.cancelled=true; result.ok=false; break
        end
        if row.imported or ThoughtDatabase.chapter_exists(self.store, report.book_id, row.chapter_uid) then
            result.skipped=result.skipped+1
        else
            local raw, read_error = U.read_file(row.path, true)
            local decoded_ok, groups = false, nil
            if raw then decoded_ok, groups = pcall(Json.decode, raw) end
            if not raw or not decoded_ok or type(groups) ~= "table" then
                result.failed=result.failed+1
                result.failures[#result.failures+1]={path=row.path,error=tostring(read_error or "旧评论 JSON 损坏")}
            else
                local saved, save_error = ThoughtDatabase.save_chapter(
                    self.store, report.book_id, row.chapter_uid, groups)
                if saved then
                    result.migrated=result.migrated+1
                    result.groups=result.groups+(tonumber(saved.groups) or 0)
                    result.comments=result.comments+(tonumber(saved.comments) or 0)
                else
                    result.failed=result.failed+1
                    result.failures[#result.failures+1]={path=row.path,error=tostring(save_error or "写入失败")}
                end
            end
        end
        result.processed=index
        if options.progress then
            options.progress({stage="import",current=index,total=result.total,
                chapter=row.chapter_uid,groups=result.groups,comments=result.comments,
                percent=result.total>0 and index/result.total or 1})
        end
    end
    if result.failed > 0 then result.ok=false end
    if result.ok and not result.cancelled and tostring(report.book_id or "") ~= "" then
        local root=self.store:book_dir(report.book_id)
        U.remove_tree(root.."/thoughts")
        U.remove_tree(root.."/thought-index")
    end
    return result
end

return Migration
