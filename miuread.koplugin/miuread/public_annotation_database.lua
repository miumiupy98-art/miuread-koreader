local SQLiteStore = require("miuread.sqlite_store")
local U = require("miuread.util")
local lfs = require("libs/libkoreader-lfs")

local DB = {}
DB.SCHEMA_VERSION = 1
DB.FILE_NAME = "public_annotations.sqlite3"

local function path(store, book_id)
    return store:book_dir(tostring(book_id or "")) .. "/" .. DB.FILE_NAME
end

local function open(store, book_id, read_only)
    local conn = SQLiteStore.open(path(store, book_id), read_only == true)
    if read_only ~= true then
        conn:exec([[
            CREATE TABLE IF NOT EXISTS public_annotation_chapters (
                chapter_uid TEXT PRIMARY KEY,
                underline_count INTEGER NOT NULL DEFAULT 0,
                thought_count INTEGER NOT NULL DEFAULT 0,
                reviews_complete INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'missing',
                error_kind TEXT NOT NULL DEFAULT '',
                book_version INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS public_annotation_marks (
                chapter_uid TEXT NOT NULL,
                range_key TEXT NOT NULL,
                ordinal INTEGER NOT NULL DEFAULT 0,
                source_text TEXT NOT NULL DEFAULT '',
                context_before TEXT NOT NULL DEFAULT '',
                context_after TEXT NOT NULL DEFAULT '',
                server_text TEXT NOT NULL DEFAULT '',
                thought_state INTEGER NOT NULL DEFAULT -1,
                locate_state TEXT NOT NULL DEFAULT '',
                PRIMARY KEY(chapter_uid, range_key),
                FOREIGN KEY(chapter_uid) REFERENCES public_annotation_chapters(chapter_uid)
                    ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_public_annotation_marks_chapter
                ON public_annotation_marks(chapter_uid, ordinal);
        ]])
        SQLiteStore.set_text(conn, "public_annotation_schema_version", tostring(DB.SCHEMA_VERSION))
    end
    return conn
end

local function scalar(value)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then return tostring(value) end
    return ""
end

function DB.path(store, book_id)
    return path(store, book_id)
end

function DB.exists(store, book_id)
    return lfs.attributes(path(store, book_id), "mode") == "file"
end

function DB.save_chapter(store, book_id, chapter_uid, marks, meta, replace)
    chapter_uid = tostring(chapter_uid or "")
    if chapter_uid == "" then return nil, "chapter_uid_missing" end
    marks = type(marks) == "table" and marks or {}
    meta = type(meta) == "table" and meta or {}
    local conn = open(store, book_id, false)
    local ok, result = xpcall(function()
        return SQLiteStore.transaction(conn, function()
            local ensure = conn:prepare([[
                INSERT OR IGNORE INTO public_annotation_chapters(
                    chapter_uid, underline_count, thought_count, reviews_complete,
                    status, error_kind, book_version, updated_at
                ) VALUES(?, 0, 0, 0, 'missing', '', 0, 0)
            ]])
            ensure:bind(chapter_uid):step(); ensure:close()
            if replace ~= false then
                local del = conn:prepare("DELETE FROM public_annotation_marks WHERE chapter_uid = ?")
                del:bind(chapter_uid):step(); del:close()
            end
            local upsert = conn:prepare([[
                INSERT OR REPLACE INTO public_annotation_marks(
                    chapter_uid, range_key, ordinal, source_text, context_before,
                    context_after, server_text, thought_state, locate_state
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ]])
            local count, thoughts = 0, 0
            for index, row in ipairs(marks) do
                local range = scalar(row.range or row.range_key)
                if range ~= "" then
                    local thought_state = tonumber(row.thought_state)
                    if thought_state == nil then thought_state = -1 end
                    upsert:bind(
                        chapter_uid, range, tonumber(row.ordinal) or index,
                        scalar(row.source_text), scalar(row.context_before),
                        scalar(row.context_after), scalar(row.server_text),
                        thought_state, scalar(row.locate_state)
                    ):step()
                    upsert:clearbind():reset()
                    count = count + 1
                    if thought_state == 1 then thoughts = thoughts + 1 end
                end
            end
            upsert:close()
            local stmt = conn:prepare([[
                UPDATE public_annotation_chapters
                   SET underline_count = ?, thought_count = ?, reviews_complete = ?,
                       status = ?, error_kind = ?, book_version = ?, updated_at = ?
                 WHERE chapter_uid = ?
            ]])
            stmt:bind(
                tonumber(meta.underline_count) or count,
                tonumber(meta.thought_count) or thoughts,
                meta.reviews_complete == true and 1 or 0,
                scalar(meta.status ~= nil and meta.status or "ready"),
                scalar(meta.error_kind), tonumber(meta.book_version) or 0,
                tonumber(meta.updated_at) or os.time(), chapter_uid
            ):step()
            stmt:close()
            return {marks=count, thoughts=thoughts}
        end)
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(result) end
    return result
end

function DB.set_status(store, book_id, chapter_uid, status, error_kind, preserve_counts)
    chapter_uid = tostring(chapter_uid or "")
    if chapter_uid == "" then return nil, "chapter_uid_missing" end
    local conn = open(store, book_id, false)
    local ok, err = xpcall(function()
        if preserve_counts == true then
            local stmt = conn:prepare([[
                UPDATE public_annotation_chapters
                   SET status = ?, error_kind = ?, updated_at = ?
                 WHERE chapter_uid = ?
            ]])
            stmt:bind(tostring(status or "error"), tostring(error_kind or ""), os.time(), chapter_uid):step()
            stmt:close()
        else
            local stmt = conn:prepare([[
                INSERT OR REPLACE INTO public_annotation_chapters(
                    chapter_uid, underline_count, thought_count, reviews_complete,
                    status, error_kind, book_version, updated_at
                ) VALUES(?, 0, 0, 0, ?, ?, 0, ?)
            ]])
            stmt:bind(chapter_uid, tostring(status or "error"), tostring(error_kind or ""), os.time()):step()
            stmt:close()
        end
    end, debug.traceback)
    pcall(conn.close, conn)
    return ok and true or nil, ok and nil or tostring(err)
end

function DB.load_chapter(store, book_id, chapter_uid)
    if not DB.exists(store, book_id) then return {}, {known=false, status="missing"} end
    chapter_uid = tostring(chapter_uid or "")
    local conn = open(store, book_id, true)
    local marks, meta = {}, {known=false, status="missing"}
    local ok, err = xpcall(function()
        local head = conn:prepare([[
            SELECT underline_count, thought_count, reviews_complete, status,
                   error_kind, book_version, updated_at
              FROM public_annotation_chapters WHERE chapter_uid = ? LIMIT 1
        ]])
        local row = head:bind(chapter_uid):step()
        head:close()
        if row then
            meta = {
                known=true,
                underline_count=tonumber(row[1] or 0) or 0,
                thought_count=tonumber(row[2] or 0) or 0,
                reviews_complete=tonumber(row[3] or 0)==1,
                status=tostring(row[4] or ""), error_kind=tostring(row[5] or ""),
                book_version=tonumber(row[6] or 0) or 0,
                updated_at=tonumber(row[7] or 0) or 0,
            }
        end
        local stmt = conn:prepare([[
            SELECT range_key, ordinal, source_text, context_before, context_after,
                   server_text, thought_state, locate_state
              FROM public_annotation_marks
             WHERE chapter_uid = ? ORDER BY ordinal, range_key
        ]])
        stmt:bind(chapter_uid)
        while true do
            local r = stmt:step(); if not r then break end
            marks[#marks + 1] = {
                range=tostring(r[1] or ""), ordinal=tonumber(r[2] or 0) or 0,
                source_text=tostring(r[3] or ""), context_before=tostring(r[4] or ""),
                context_after=tostring(r[5] or ""), server_text=tostring(r[6] or ""),
                thought_state=tonumber(r[7] or -1) or -1,
                locate_state=tostring(r[8] or ""),
            }
        end
        stmt:close()
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, nil, tostring(err) end
    return marks, meta
end

function DB.delete_chapter(store, book_id, chapter_uid)
    if not DB.exists(store, book_id) then return true end
    local conn = open(store, book_id, false)
    local ok, err = xpcall(function()
        SQLiteStore.transaction(conn, function()
            local a=conn:prepare("DELETE FROM public_annotation_marks WHERE chapter_uid = ?")
            a:bind(tostring(chapter_uid or "")):step(); a:close()
            local b=conn:prepare("DELETE FROM public_annotation_chapters WHERE chapter_uid = ?")
            b:bind(tostring(chapter_uid or "")):step(); b:close()
        end)
    end, debug.traceback)
    pcall(conn.close, conn)
    return ok and true or nil, ok and nil or tostring(err)
end

function DB.remove(store, book_id)
    os.remove(path(store, book_id))
    os.remove(path(store, book_id).."-wal")
    os.remove(path(store, book_id).."-shm")
    return true
end

return DB
