local SQLiteStore = require("miuread.sqlite_store")
local Digests = require("miuread.digests")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local LocalAnnotationDatabase = {}

LocalAnnotationDatabase.SCHEMA_VERSION = 6
LocalAnnotationDatabase.FILE_NAME = "local_annotations.sqlite3"

local function database_path(store, book_id)
    return store:book_dir(book_id) .. "/" .. LocalAnnotationDatabase.FILE_NAME
end

local function safe_alter(conn, sql)
    pcall(conn.exec, conn, sql)
end

local function initialize(conn)
    local previous = tonumber(SQLiteStore.get_text(conn, "local_annotation_schema_version") or 0) or 0
    conn:exec([[
        CREATE TABLE IF NOT EXISTS local_annotations (
            local_id TEXT PRIMARY KEY,
            book_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            pos0 TEXT NOT NULL DEFAULT '',
            pos1 TEXT NOT NULL DEFAULT '',
            xpointer TEXT NOT NULL DEFAULT '',
            page INTEGER,
            text TEXT NOT NULL DEFAULT '',
            selected_text TEXT NOT NULL DEFAULT '',
            context_before TEXT NOT NULL DEFAULT '',
            context_after TEXT NOT NULL DEFAULT '',
            anchor_text TEXT NOT NULL DEFAULT '',
            note TEXT NOT NULL DEFAULT '',
            datetime TEXT NOT NULL DEFAULT '',
            drawer TEXT NOT NULL DEFAULT '',
            source_path TEXT NOT NULL DEFAULT '',
            present INTEGER NOT NULL DEFAULT 1,
            sync_state TEXT NOT NULL DEFAULT 'local_only',
            range_key TEXT NOT NULL DEFAULT '',
            remote_id TEXT NOT NULL DEFAULT '',
            chapter_uid TEXT NOT NULL DEFAULT '',
            chapter_idx INTEGER,
            book_version INTEGER NOT NULL DEFAULT 0,
            last_stage TEXT NOT NULL DEFAULT '',
            last_error TEXT NOT NULL DEFAULT '',
            last_attempt_at INTEGER NOT NULL DEFAULT 0,
            coord_version INTEGER NOT NULL DEFAULT 0,
            coord_source TEXT NOT NULL DEFAULT '',
            coord_verify TEXT NOT NULL DEFAULT '',
            sync_kind TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
        );
    ]])
    -- In-place upgrades from beta.5/beta.6 databases.
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN anchor_text TEXT NOT NULL DEFAULT '';")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN selected_text TEXT NOT NULL DEFAULT '';")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN context_before TEXT NOT NULL DEFAULT '';")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN context_after TEXT NOT NULL DEFAULT '';")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN chapter_uid TEXT NOT NULL DEFAULT '';")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN chapter_idx INTEGER;")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN book_version INTEGER NOT NULL DEFAULT 0;")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN last_stage TEXT NOT NULL DEFAULT '';")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN last_error TEXT NOT NULL DEFAULT '';")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN last_attempt_at INTEGER NOT NULL DEFAULT 0;")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN coord_version INTEGER NOT NULL DEFAULT 0;")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN coord_source TEXT NOT NULL DEFAULT '';")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN coord_verify TEXT NOT NULL DEFAULT '';")
    safe_alter(conn, "ALTER TABLE local_annotations ADD COLUMN sync_kind TEXT NOT NULL DEFAULT '';")

    if previous < LocalAnnotationDatabase.SCHEMA_VERSION then
        -- Re-evaluate old local-only failures once after upgrading. This lets a
        -- newer locator recover beta-era bookmark/highlight failures, but once
        -- the current version has tried them they stay actionable instead of
        -- being retried on every ordinary sync. `unknown`/delete_unknown may
        -- already exist remotely and must never be reset into a blind POST.
        conn:exec([[
            UPDATE local_annotations
               SET sync_state = 'local_only', last_stage = '', last_error = ''
             WHERE present = 1 AND remote_id = ''
               AND sync_state IN ('locate_failed','metadata_failed','coord_failed');
        ]])
    end

    conn:exec([[
        CREATE INDEX IF NOT EXISTS idx_local_annotation_book
            ON local_annotations(book_id, present, kind);
        CREATE INDEX IF NOT EXISTS idx_local_annotation_sync
            ON local_annotations(book_id, sync_state, updated_at);
        CREATE INDEX IF NOT EXISTS idx_local_annotation_remote
            ON local_annotations(remote_id);
        CREATE INDEX IF NOT EXISTS idx_local_annotation_chapter
            ON local_annotations(book_id, chapter_uid, chapter_idx);
    ]])
    SQLiteStore.set_text(conn, "local_annotation_schema_version",
        tostring(LocalAnnotationDatabase.SCHEMA_VERSION))
end

local function open(store, book_id, read_only)
    local conn = SQLiteStore.open(database_path(store, book_id), read_only == true)
    if read_only ~= true then initialize(conn) end
    return conn
end

local function scalar(value)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then
        return tostring(value)
    end
    return ""
end

local function nonempty(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") ~= ""
end

--- Canonical KOReader annotation classification used by both snapshot and UI.
-- A drawer means a text highlight. It is a thought only when the note has
-- actual non-whitespace content; Lua treats "" as truthy, so `item.note and`
-- is not safe here.
function LocalAnnotationDatabase.annotation_kind(item)
    if type(item) ~= "table" then return nil end
    if item.drawer then
        return nonempty(item.note) and "thought" or "highlight"
    end
    return "bookmark"
end

local function stable_id(book_id, item, kind)
    for _, key in ipairs({"id", "uuid", "annotation_id", "annotationId"}) do
        local value = scalar(item[key])
        if value ~= "" then return "ko:" .. value end
    end
    local pos0 = scalar(item.pos0 or item.start)
    local pos1 = scalar(item.pos1 or item["end"])
    local xpointer = scalar(item.xpointer)
    local page = scalar(item.page or item.pageno)
    local datetime = scalar(item.datetime or item.date)
    local base = table.concat({
        tostring(book_id or ""), tostring(kind or ""), pos0, pos1,
        xpointer, page, datetime,
    }, "\31")
    if pos0 == "" and pos1 == "" and xpointer == "" and page == "" then
        base = base .. "\31" .. scalar(item.text or item.notes)
            .. "\31" .. scalar(item.note)
    end
    return "miu:" .. Digests.md5(base):lower()
end

local function compact(book_id, item, source_path, resolver)
    if type(item) ~= "table" then return nil end
    local kind = LocalAnnotationDatabase.annotation_kind(item)
    if not kind then return nil end
    local resolved = {}
    if type(resolver) == "function" then
        local ok, value = pcall(resolver, item, kind)
        if ok and type(value) == "table" then resolved = value end
    end
    local page_value = item.page or item.pageno
    local xpointer = item.xpointer
    if (xpointer == nil or xpointer == "") and kind == "bookmark"
        and type(page_value) == "string" and tonumber(page_value) == nil then
        xpointer = page_value
    end
    local item_text = scalar(item.text or item.notes)
    local selected = tostring(resolved.selected_text or "")
    if selected == "" and kind ~= "bookmark" then selected = item_text end
    return {
        local_id = stable_id(book_id, item, kind),
        book_id = tostring(book_id or ""),
        kind = kind,
        pos0 = scalar(item.pos0 or item.start),
        pos1 = scalar(item.pos1 or item["end"]),
        xpointer = scalar(xpointer),
        page = tonumber(page_value),
        text = item_text,
        selected_text = selected,
        context_before = tostring(resolved.context_before or ""),
        context_after = tostring(resolved.context_after or ""),
        anchor_text = tostring(resolved.anchor_text or ""),
        note = scalar(item.note),
        datetime = scalar(item.datetime or item.date),
        drawer = scalar(item.drawer),
        source_path = tostring(source_path or ""),
        chapter_uid = tostring(resolved.chapter_uid or resolved.uid or ""),
        chapter_idx = tonumber(resolved.chapter_idx or resolved.index),
    }
end

function LocalAnnotationDatabase.path(store, book_id)
    return database_path(store, book_id)
end

function LocalAnnotationDatabase.exists(store, book_id)
    return lfs.attributes(database_path(store, book_id), "mode") == "file"
end

--- Replace the current KOReader annotation snapshot without doing network work.
-- resolver(item, kind) may add chapter/context information while the document is open.
function LocalAnnotationDatabase.snapshot(store, book_id, annotations, source_path, resolver)
    book_id = tostring(book_id or "")
    if book_id == "" then return nil, "bookId missing" end
    annotations = type(annotations) == "table" and annotations or {}

    local conn = open(store, book_id, false)
    local ok, result = xpcall(function()
        return SQLiteStore.transaction(conn, function()
            local now = os.time()
            local mark_missing = conn:prepare([[
                UPDATE local_annotations SET present = 0, updated_at = ? WHERE book_id = ?
            ]])
            mark_missing:bind(now, book_id):step()
            mark_missing:close()

            local insert = conn:prepare([[
                INSERT OR IGNORE INTO local_annotations(
                    local_id, book_id, kind, pos0, pos1, xpointer, page,
                    text, selected_text, context_before, context_after, anchor_text,
                    note, datetime, drawer, source_path, chapter_uid, chapter_idx,
                    present, sync_state, created_at, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 'local_only', ?, ?)
            ]])
            local update = conn:prepare([[
                UPDATE local_annotations
                   SET book_id = ?, kind = ?, pos0 = ?, pos1 = ?, xpointer = ?, page = ?,
                       text = ?,
                       selected_text = CASE WHEN ? <> '' THEN ? ELSE selected_text END,
                       context_before = CASE WHEN ? <> '' THEN ? ELSE context_before END,
                       context_after = CASE WHEN ? <> '' THEN ? ELSE context_after END,
                       anchor_text = CASE WHEN ? <> '' THEN ? ELSE anchor_text END,
                       note = ?, datetime = ?, drawer = ?, source_path = ?,
                       chapter_uid = CASE WHEN ? <> '' THEN ? ELSE chapter_uid END,
                       chapter_idx = COALESCE(?, chapter_idx),
                       present = 1, updated_at = ?
                 WHERE local_id = ?
            ]])

            local count = 0
            for _, item in ipairs(annotations) do
                local row = compact(book_id, item, source_path, resolver)
                if row then
                    insert:bind(
                        row.local_id, row.book_id, row.kind, row.pos0, row.pos1,
                        row.xpointer, row.page, row.text, row.selected_text,
                        row.context_before, row.context_after, row.anchor_text,
                        row.note, row.datetime, row.drawer, row.source_path,
                        row.chapter_uid, row.chapter_idx, now, now
                    ):step()
                    insert:clearbind():reset()
                    update:bind(
                        row.book_id, row.kind, row.pos0, row.pos1, row.xpointer, row.page,
                        row.text,
                        row.selected_text, row.selected_text,
                        row.context_before, row.context_before,
                        row.context_after, row.context_after,
                        row.anchor_text, row.anchor_text,
                        row.note, row.datetime, row.drawer, row.source_path,
                        row.chapter_uid, row.chapter_uid, row.chapter_idx,
                        now, row.local_id
                    ):step()
                    update:clearbind():reset()
                    count = count + 1
                end
            end
            insert:close()
            update:close()

            -- Records never seen by the server can disappear locally without a tombstone.
            conn:exec([[
                DELETE FROM local_annotations
                 WHERE present = 0 AND remote_id = ''
                   AND sync_state IN ('local_only','locate_failed','metadata_failed','coord_failed','held_local');
            ]])
            -- Anything already known/possibly known by the server is retained until
            -- the cloud side is confirmed gone.
            conn:exec([[
                UPDATE local_annotations
                   SET sync_state = 'delete_pending'
                 WHERE present = 0
                   AND sync_state IN ('synced','unknown','delete_unknown');
            ]])
            return {count=count, updated_at=now}
        end)
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(result) end
    return result
end

local SELECT_COLUMNS = [[
    local_id, book_id, kind, pos0, pos1, xpointer, page, text,
    selected_text, context_before, context_after, anchor_text, note,
    datetime, drawer, source_path, present, sync_state, range_key,
    remote_id, chapter_uid, chapter_idx, book_version, last_stage, last_error,
    last_attempt_at, coord_version, coord_source, coord_verify, created_at, updated_at,
    sync_kind
]]

local function row_from_sql(row)
    if not row then return nil end
    return {
        local_id=tostring(row[1] or ""), book_id=tostring(row[2] or ""),
        kind=tostring(row[3] or ""), pos0=tostring(row[4] or ""), pos1=tostring(row[5] or ""),
        xpointer=tostring(row[6] or ""), page=tonumber(row[7]), text=tostring(row[8] or ""),
        selected_text=tostring(row[9] or ""), context_before=tostring(row[10] or ""),
        context_after=tostring(row[11] or ""), anchor_text=tostring(row[12] or ""),
        note=tostring(row[13] or ""), datetime=tostring(row[14] or ""),
        drawer=tostring(row[15] or ""), source_path=tostring(row[16] or ""),
        present=tonumber(row[17] or 0)==1, sync_state=tostring(row[18] or ""),
        range_key=tostring(row[19] or ""), remote_id=tostring(row[20] or ""),
        chapter_uid=tostring(row[21] or ""), chapter_idx=tonumber(row[22]),
        book_version=tonumber(row[23] or 0) or 0, last_stage=tostring(row[24] or ""),
        last_error=tostring(row[25] or ""), last_attempt_at=tonumber(row[26] or 0) or 0,
        coord_version=tonumber(row[27] or 0) or 0, coord_source=tostring(row[28] or ""),
        coord_verify=tostring(row[29] or ""), created_at=tonumber(row[30] or 0) or 0,
        updated_at=tonumber(row[31] or 0) or 0, sync_kind=tostring(row[32] or ""),
    }
end

function LocalAnnotationDatabase.list(store, book_id, limit)
    if not LocalAnnotationDatabase.exists(store, book_id) then return {} end
    local conn = open(store, book_id, true)
    local out = {}
    local ok, err = xpcall(function()
        local statement = conn:prepare("SELECT " .. SELECT_COLUMNS .. [[
            FROM local_annotations
            WHERE book_id = ? AND present = 1
            ORDER BY updated_at DESC LIMIT ?
        ]])
        statement:bind(tostring(book_id or ""), math.max(1, tonumber(limit) or 200))
        while true do
            local row = statement:step()
            if not row then break end
            out[#out + 1] = row_from_sql(row)
        end
        statement:close()
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(err) end
    return out
end

function LocalAnnotationDatabase.pending(store, book_id, limit)
    if not LocalAnnotationDatabase.exists(store, book_id) then return {} end
    local conn = open(store, book_id, false)
    local out = {}
    local ok, err = xpcall(function()
        local statement = conn:prepare("SELECT " .. SELECT_COLUMNS .. [[
            FROM local_annotations
            WHERE book_id = ? AND sync_state IN
                ('local_only','unknown','delete_pending','delete_unknown')
            ORDER BY updated_at ASC LIMIT ?
        ]])
        statement:bind(tostring(book_id or ""), math.max(1, tonumber(limit) or 200))
        while true do
            local row = statement:step()
            if not row then break end
            out[#out + 1] = row_from_sql(row)
        end
        statement:close()
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(err) end
    return out
end

local function update_state(store, book_id, local_id, state, fields)
    fields = fields or {}
    local conn = open(store, book_id, false)
    local ok, err = xpcall(function()
        local statement = conn:prepare([[
            UPDATE local_annotations
               SET sync_state = ?, range_key = CASE WHEN ? IS NULL THEN range_key ELSE ? END,
                   remote_id = CASE WHEN ? IS NULL THEN remote_id ELSE ? END,
                   book_version = CASE WHEN ? IS NULL THEN book_version ELSE ? END,
                   chapter_uid = CASE WHEN ? IS NULL THEN chapter_uid ELSE ? END,
                   chapter_idx = CASE WHEN ? IS NULL THEN chapter_idx ELSE ? END,
                   coord_version = CASE WHEN ? IS NULL THEN coord_version ELSE ? END,
                   coord_source = CASE WHEN ? IS NULL THEN coord_source ELSE ? END,
                   coord_verify = CASE WHEN ? IS NULL THEN coord_verify ELSE ? END,
                   last_stage = ?, last_error = ?, last_attempt_at = ?, updated_at = ?
             WHERE local_id = ?
        ]])
        local range = fields.range_key
        local remote = fields.remote_id
        local version = fields.book_version
        local chapter_uid = fields.chapter_uid
        local chapter_idx = fields.chapter_idx
        local coord_version = fields.coord_version
        local coord_source = fields.coord_source
        local coord_verify = fields.coord_verify
        local now = os.time()
        statement:bind(
            tostring(state or "local_only"),
            range, range, remote, remote,
            version, version,
            chapter_uid, chapter_uid,
            chapter_idx, chapter_idx,
            coord_version, coord_version,
            coord_source, coord_source,
            coord_verify, coord_verify,
            tostring(fields.last_stage or ""), tostring(fields.last_error or ""),
            tonumber(fields.last_attempt_at) or now, now,
            tostring(local_id or "")
        ):step()
        statement:close()
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(err) end
    return true
end

function LocalAnnotationDatabase.mark_synced(store, book_id, local_id, remote_id, range_key, book_version, fields)
    fields = type(fields) == "table" and fields or {}
    fields.remote_id = tostring(remote_id or "")
    fields.range_key = tostring(range_key or "")
    fields.book_version = tonumber(book_version) or 0
    fields.last_stage = "done"
    fields.last_error = ""
    return update_state(store, book_id, local_id, "synced", fields)
end

function LocalAnnotationDatabase.mark_state(store, book_id, local_id, state, fields)
    return update_state(store, book_id, local_id, state, fields)
end

function LocalAnnotationDatabase.set_sync_kind(store, book_id, local_id, kind)
    kind = tostring(kind or "")
    if kind ~= "" and kind ~= "bookmark" and kind ~= "highlight" and kind ~= "thought" then
        return nil, "invalid sync kind"
    end
    local conn = open(store, book_id, false)
    local ok, err = xpcall(function()
        local statement = conn:prepare([[
            UPDATE local_annotations
               SET sync_kind = ?, updated_at = ?
             WHERE local_id = ?
        ]])
        statement:bind(kind, os.time(), tostring(local_id or "")):step()
        statement:close()
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(err) end
    return true
end

function LocalAnnotationDatabase.delete_row(store, book_id, local_id)
    if not LocalAnnotationDatabase.exists(store, book_id) then return true end
    local conn = open(store, book_id, false)
    local ok, err = xpcall(function()
        local statement = conn:prepare("DELETE FROM local_annotations WHERE local_id = ?")
        statement:bind(tostring(local_id or "")):step()
        statement:close()
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(err) end
    return true
end

function LocalAnnotationDatabase.retry_failure(store, book_id, local_id)
    if not LocalAnnotationDatabase.exists(store, book_id) then return nil, "annotation database missing" end
    local conn = open(store, book_id, false)
    local changed = 0
    local ok, err = xpcall(function()
        local statement = conn:prepare([[
            UPDATE local_annotations
               SET sync_state = 'local_only', last_stage = '', last_error = '',
                   last_attempt_at = 0, updated_at = ?
             WHERE book_id = ? AND local_id = ? AND present = 1 AND remote_id = ''
               AND sync_state IN ('locate_failed','metadata_failed','coord_failed','held_local')
        ]])
        statement:bind(os.time(), tostring(book_id or ""), tostring(local_id or "")):step()
        statement:close()
        local query=conn:prepare("SELECT changes()")
        local row=query:step()
        changed=row and (tonumber(row[1] or 0) or 0) or 0
        query:close()
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(err) end
    return changed > 0
end

function LocalAnnotationDatabase.retry_failures(store, book_id)
    if not LocalAnnotationDatabase.exists(store, book_id) then return 0 end
    local conn = open(store, book_id, false)
    local changed = 0
    local ok, err = xpcall(function()
        local statement = conn:prepare([[
            UPDATE local_annotations
               SET sync_state = 'local_only', last_stage = '', last_error = '',
                   last_attempt_at = 0, updated_at = ?
             WHERE book_id = ? AND present = 1 AND remote_id = ''
               AND sync_state IN ('locate_failed','metadata_failed','coord_failed','held_local')
        ]])
        statement:bind(os.time(), tostring(book_id or "")):step()
        statement:close()
        local query=conn:prepare("SELECT changes()")
        local row=query:step()
        changed=row and (tonumber(row[1] or 0) or 0) or 0
        query:close()
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(err) end
    return changed
end

function LocalAnnotationDatabase.hold_local(store, book_id, local_id)
    if not LocalAnnotationDatabase.exists(store, book_id) then return nil, "annotation database missing" end
    local conn = open(store, book_id, false)
    local changed = 0
    local ok, err = xpcall(function()
        local statement = conn:prepare([[
            UPDATE local_annotations
               SET sync_state = 'held_local', last_stage = 'held_local',
                   last_error = '', updated_at = ?
             WHERE book_id = ? AND local_id = ? AND present = 1 AND remote_id = ''
               AND sync_state IN ('local_only','locate_failed','metadata_failed','coord_failed')
        ]])
        statement:bind(os.time(), tostring(book_id or ""), tostring(local_id or "")):step()
        statement:close()
        local query=conn:prepare("SELECT changes()")
        local row=query:step()
        changed=row and (tonumber(row[1] or 0) or 0) or 0
        query:close()
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(err) end
    return changed > 0
end

local function empty_summary()
    return {total=0, bookmark=0, highlight=0, thought=0, pending=0, synced=0,
        delete_pending=0, locate_failed=0, metadata_failed=0, coord_failed=0,
        unknown=0, action_required=0, held_local=0, legacy_synced=0}
end

local function read_summary(conn, book_id)
    local out = empty_summary()
    local statement = conn:prepare([[
        SELECT kind, sync_state, COUNT(*) FROM local_annotations
         WHERE book_id = ? AND (present = 1 OR sync_state IN ('delete_pending','delete_unknown'))
         GROUP BY kind, sync_state
    ]])
    statement:bind(tostring(book_id or ""))
    while true do
        local row = statement:step()
        if not row then break end
        local kind = tostring(row[1] or "")
        local state = tostring(row[2] or "")
        local count = tonumber(row[3] or 0) or 0
        out.total = out.total + count
        if out[kind] ~= nil then out[kind] = out[kind] + count end
        if state == "synced" then out.synced = out.synced + count
        elseif state == "delete_pending" or state == "delete_unknown" then
            out.delete_pending = out.delete_pending + count
        elseif state == "locate_failed" then
            out.locate_failed = out.locate_failed + count; out.action_required = out.action_required + count
        elseif state == "metadata_failed" then
            out.metadata_failed = out.metadata_failed + count; out.action_required = out.action_required + count
        elseif state == "coord_failed" then
            out.coord_failed = out.coord_failed + count; out.action_required = out.action_required + count
        elseif state == "unknown" then
            out.unknown = out.unknown + count; out.pending = out.pending + count
        elseif state == "held_local" then
            out.held_local = out.held_local + count
        else
            out.pending = out.pending + count
        end
    end
    statement:close()
    local legacy = conn:prepare([[
        SELECT COUNT(*) FROM local_annotations
         WHERE book_id = ? AND present = 1 AND sync_state = 'synced'
           AND COALESCE(coord_version, 0) < 2
    ]])
    legacy:bind(tostring(book_id or ""))
    local legacy_row = legacy:step()
    out.legacy_synced = legacy_row and (tonumber(legacy_row[1] or 0) or 0) or 0
    legacy:close()
    return out
end

function LocalAnnotationDatabase.summary(store, book_id)
    if not LocalAnnotationDatabase.exists(store, book_id) then return empty_summary() end
    local conn = open(store, book_id, false)
    local ok, result = xpcall(function() return read_summary(conn, book_id) end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(result) end
    return result
end

-- Lifecycle-safe summary used by close/suspend. It never initializes/migrates
-- schema and caps SQLite lock waiting to a tiny interval. If an old/busy DB
-- cannot be read immediately, callers defer the authoritative check to the
-- background worker instead of making the user wait.
function LocalAnnotationDatabase.summary_fast(store, book_id)
    if not LocalAnnotationDatabase.exists(store, book_id) then return empty_summary() end
    local conn
    local opened, open_err = pcall(function()
        conn = open(store, book_id, true)
        pcall(conn.exec, conn, "PRAGMA busy_timeout=80;")
    end)
    if not opened or not conn then return nil, tostring(open_err or "annotation database unavailable") end
    local ok, result = xpcall(function() return read_summary(conn, book_id) end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(result) end
    return result
end

local FAILURE_STATES = {
    locate_failed=true, metadata_failed=true, coord_failed=true,
    unknown=true, delete_unknown=true,
}

local function database_paths(store)
    local root = tostring(store and store.cache_books_dir or "")
    local out = {}
    if root == "" or lfs.attributes(root, "mode") ~= "directory" then return out end
    local ok, iter, state, var = pcall(lfs.dir, root)
    if not ok or not iter then return out end
    while true do
        local name = iter(state, var)
        var = name
        if not name then break end
        if name ~= "." and name ~= ".." then
            local path = root .. "/" .. name .. "/" .. LocalAnnotationDatabase.FILE_NAME
            if lfs.attributes(path, "mode") == "file" then out[#out + 1] = path end
        end
    end
    return out
end

-- Aggregate pending local mutations across every generated book. The home
-- screen uses this instead of pretending there is a "current book" while no
-- reader is open.

local function escape_like(value)
    return (tostring(value or ""):gsub("[%%_\\]", "\\%0"))
end

-- Read-only full-text search across every cached book annotation database.
-- Multiple whitespace-separated terms are AND-ed, while each term may occur
-- in any searchable text field of the same annotation row.
function LocalAnnotationDatabase.search_all(store, query, limit)
    limit = math.max(1, math.min(500, tonumber(limit) or 200))
    local plain_terms, escaped_terms = {}, {}
    for term in tostring(query or ""):gmatch("%S+") do
        if term ~= "" then
            plain_terms[#plain_terms + 1] = term
            escaped_terms[#escaped_terms + 1] = escape_like(term)
        end
    end
    if #plain_terms == 0 then return {} end

    local columns = {
        "selected_text", "note", "anchor_text", "text",
        "context_before", "context_after",
    }
    local clauses, bindings = {}, {}
    for _, term in ipairs(escaped_terms) do
        local choices = {}
        for _, column in ipairs(columns) do
            choices[#choices + 1] = column .. " LIKE ? ESCAPE '\\'"
            bindings[#bindings + 1] = "%" .. term .. "%"
        end
        clauses[#clauses + 1] = "(" .. table.concat(choices, " OR ") .. ")"
    end

    local sql = [[
        SELECT local_id, book_id, kind, pos0, pos1, xpointer, page,
               text, selected_text, note, anchor_text, context_before,
               context_after, datetime, updated_at, source_path, sync_state
          FROM local_annotations
         WHERE present = 1 AND ]] .. table.concat(clauses, " AND ") .. [[
         ORDER BY updated_at DESC
         LIMIT ?
    ]]

    local out = {}
    for _, path in ipairs(database_paths(store)) do
        local ok_conn, conn = pcall(SQLiteStore.open, path, true)
        if ok_conn and conn then
            local ok, err = xpcall(function()
                local statement = conn:prepare(sql)
                local values = {}
                for _, value in ipairs(bindings) do values[#values + 1] = value end
                values[#values + 1] = limit
                statement:bind(unpack(values))
                while true do
                    local row = statement:step()
                    if not row then break end
                    local fields = {
                        selected_text = tostring(row[9] or ""),
                        note = tostring(row[10] or ""),
                        anchor_text = tostring(row[11] or ""),
                        text = tostring(row[8] or ""),
                        context_before = tostring(row[12] or ""),
                        context_after = tostring(row[13] or ""),
                    }
                    -- Pick the field containing the most query terms for the
                    -- visible excerpt. SQL already guarantees all terms exist
                    -- somewhere on this row.
                    local matched_field, matched_text, matched_score = "", "", -1
                    for _, name in ipairs({"note","selected_text","anchor_text","text","context_before","context_after"}) do
                        local value = fields[name]
                        if value ~= "" then
                            local lower = value:lower()
                            local score = 0
                            for _, term in ipairs(plain_terms) do
                                if lower:find(term:lower(), 1, true) then score = score + 1 end
                            end
                            if score > matched_score then
                                matched_field, matched_text, matched_score = name, value, score
                            end
                        end
                    end
                    out[#out + 1] = {
                        local_id = tostring(row[1] or ""),
                        book_id = tostring(row[2] or ""),
                        kind = tostring(row[3] or ""),
                        pos0 = tostring(row[4] or ""),
                        pos1 = tostring(row[5] or ""),
                        xpointer = tostring(row[6] or ""),
                        page = tonumber(row[7]),
                        text = fields.text,
                        selected_text = fields.selected_text,
                        note = fields.note,
                        anchor_text = fields.anchor_text,
                        context_before = fields.context_before,
                        context_after = fields.context_after,
                        datetime = tostring(row[14] or ""),
                        updated_at = tonumber(row[15] or 0) or 0,
                        source_path = tostring(row[16] or ""),
                        sync_state = tostring(row[17] or ""),
                        matched_field = matched_field,
                        matched_text = matched_text,
                    }
                end
                statement:close()
            end, debug.traceback)
            pcall(conn.close, conn)
            if not ok then
                logger.warn("[MiuRead][LocalAnnotations] search skipped database", tostring(path), tostring(err))
            end
        end
    end

    table.sort(out, function(a, b)
        if a.updated_at ~= b.updated_at then return a.updated_at > b.updated_at end
        if a.book_id ~= b.book_id then return a.book_id < b.book_id end
        return a.local_id < b.local_id
    end)
    while #out > limit do table.remove(out) end
    return out
end

function LocalAnnotationDatabase.global_summary(store)
    local out = {pending=0, failed=0, action_required=0, held_local=0,
        delete_pending=0, bookmark=0, highlight=0, thought=0,
        action_bookmark=0, action_highlight=0, action_thought=0,
        books=0, upgrade_recheck=0}
    for _, path in ipairs(database_paths(store)) do
        local ok_conn, conn = pcall(SQLiteStore.open, path, true)
        if ok_conn and conn then
            local ok = pcall(function()
                local schema_version=tonumber(SQLiteStore.get_text(conn, "local_annotation_schema_version") or 0) or 0
                local statement = conn:prepare([[
                    SELECT kind, sync_state, COUNT(*) FROM local_annotations
                     WHERE (present = 1 AND sync_state IN
                        ('local_only','locate_failed','metadata_failed','coord_failed','unknown','held_local'))
                        OR sync_state IN ('delete_pending','delete_unknown')
                     GROUP BY kind, sync_state
                ]])
                local touched = false
                while true do
                    local row = statement:step()
                    if not row then break end
                    local kind, state_name = tostring(row[1] or ""), tostring(row[2] or "")
                    local count = tonumber(row[3] or 0) or 0
                    if count > 0 then touched = true end
                    if state_name ~= "held_local" and out[kind] ~= nil then out[kind] = out[kind] + count end
                    if state_name == "delete_pending" or state_name == "delete_unknown" then
                        out.delete_pending = out.delete_pending + count
                        out.pending = out.pending + count
                    elseif state_name == "held_local" then
                        out.held_local = out.held_local + count
                    elseif state_name == "locate_failed" or state_name == "metadata_failed" or state_name == "coord_failed" then
                        out.action_required = out.action_required + count
                        local action_key="action_"..kind
                        if out[action_key]~=nil then out[action_key]=out[action_key]+count end
                        if schema_version < LocalAnnotationDatabase.SCHEMA_VERSION then
                            out.upgrade_recheck = out.upgrade_recheck + count
                        end
                    else
                        out.pending = out.pending + count
                    end
                    if FAILURE_STATES[state_name] then out.failed = out.failed + count end
                end
                statement:close()
                if touched then out.books = out.books + 1 end
            end)
            pcall(conn.close, conn)
            if not ok then -- ignore one damaged cache DB; the rest remain usable
            end
        end
    end
    return out
end

function LocalAnnotationDatabase.pending_books(store, limit)
    limit = math.max(1, tonumber(limit) or 100)
    local by_book, order = {}, {}
    for _, path in ipairs(database_paths(store)) do
        local ok_conn, conn = pcall(SQLiteStore.open, path, true)
        if ok_conn and conn then
            pcall(function()
                local schema_version=tonumber(SQLiteStore.get_text(conn, "local_annotation_schema_version") or 0) or 0
                local states=schema_version < LocalAnnotationDatabase.SCHEMA_VERSION
                    and "('local_only','locate_failed','metadata_failed','coord_failed','unknown')"
                    or "('local_only','unknown')"
                local statement = conn:prepare([[
                    SELECT book_id, kind, sync_state, COUNT(*) FROM local_annotations
                     WHERE (present = 1 AND sync_state IN ]]..states..[[)
                        OR sync_state IN ('delete_pending','delete_unknown')
                     GROUP BY book_id, kind, sync_state
                ]])
                while true do
                    local row = statement:step()
                    if not row then break end
                    local book_id = tostring(row[1] or "")
                    local kind, state_name = tostring(row[2] or ""), tostring(row[3] or "")
                    local count = tonumber(row[4] or 0) or 0
                    if book_id ~= "" and count > 0 then
                        local item = by_book[book_id]
                        if not item then
                            item = {book_id=book_id, pending=0, failed=0, bookmark=0, highlight=0, thought=0}
                            by_book[book_id] = item
                            order[#order + 1] = item
                        end
                        item.pending = item.pending + count
                        if item[kind] ~= nil then item[kind] = item[kind] + count end
                        if FAILURE_STATES[state_name] then item.failed = item.failed + count end
                    end
                end
                statement:close()
            end)
            pcall(conn.close, conn)
        end
    end
    table.sort(order, function(a, b)
        if a.failed ~= b.failed then return a.failed > b.failed end
        if a.pending ~= b.pending then return a.pending > b.pending end
        return a.book_id < b.book_id
    end)
    while #order > limit do table.remove(order) end
    return order
end

function LocalAnnotationDatabase.failures(store, book_id, limit)
    if not LocalAnnotationDatabase.exists(store, book_id) then return {} end
    local conn = open(store, book_id, false)
    local out = {}
    local ok, err = xpcall(function()
        local statement = conn:prepare([[
            SELECT local_id, kind, sync_state, last_stage, last_error,
                   text, selected_text, anchor_text, note, chapter_uid,
                   chapter_idx, updated_at
              FROM local_annotations
             WHERE book_id = ? AND present = 1
               AND sync_state IN ('locate_failed','metadata_failed','coord_failed')
             ORDER BY updated_at DESC LIMIT ?
        ]])
        statement:bind(tostring(book_id or ""), math.max(1, tonumber(limit) or 6))
        while true do
            local row = statement:step()
            if not row then break end
            out[#out + 1] = {
                local_id=tostring(row[1] or ""), kind=tostring(row[2] or ""),
                state=tostring(row[3] or ""), stage=tostring(row[4] or ""),
                error=tostring(row[5] or ""), text=tostring(row[6] or ""),
                selected_text=tostring(row[7] or ""), anchor_text=tostring(row[8] or ""),
                note=tostring(row[9] or ""), chapter_uid=tostring(row[10] or ""),
                chapter_idx=tonumber(row[11]), updated_at=tonumber(row[12] or 0) or 0,
            }
        end
        statement:close()
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(err) end
    return out
end

function LocalAnnotationDatabase.global_failures(store, limit)
    limit = math.max(1, math.min(500, tonumber(limit) or 100))
    local out = {}
    for _, path in ipairs(database_paths(store)) do
        if #out >= limit then break end
        local ok_conn, conn = pcall(SQLiteStore.open, path, true)
        if ok_conn and conn then
            pcall(function()
                local statement = conn:prepare([[
                    SELECT book_id, local_id, kind, sync_state, last_stage, last_error,
                           text, selected_text, anchor_text, note, chapter_uid,
                           chapter_idx, updated_at
                      FROM local_annotations
                     WHERE present = 1
                       AND sync_state IN ('locate_failed','metadata_failed','coord_failed')
                     ORDER BY updated_at DESC LIMIT ?
                ]])
                statement:bind(limit - #out)
                while #out < limit do
                    local row = statement:step()
                    if not row then break end
                    out[#out + 1] = {
                        book_id=tostring(row[1] or ""), local_id=tostring(row[2] or ""),
                        kind=tostring(row[3] or ""), state=tostring(row[4] or ""),
                        stage=tostring(row[5] or ""), error=tostring(row[6] or ""),
                        text=tostring(row[7] or ""), selected_text=tostring(row[8] or ""),
                        anchor_text=tostring(row[9] or ""), note=tostring(row[10] or ""),
                        chapter_uid=tostring(row[11] or ""), chapter_idx=tonumber(row[12]),
                        updated_at=tonumber(row[13] or 0) or 0,
                    }
                end
                statement:close()
            end)
            pcall(conn.close, conn)
        end
    end
    table.sort(out, function(a, b)
        if a.updated_at ~= b.updated_at then return a.updated_at > b.updated_at end
        if a.book_id ~= b.book_id then return a.book_id < b.book_id end
        return a.local_id < b.local_id
    end)
    while #out > limit do table.remove(out) end
    return out
end

return LocalAnnotationDatabase
