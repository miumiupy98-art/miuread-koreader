local SQLiteStore = require("miuread.sqlite_store")
local Digests = require("miuread.digests")
local U = require("miuread.util")
local lfs = require("libs/libkoreader-lfs")

local Favorites = {}
Favorites.SCHEMA_VERSION = 1
Favorites.FILE_NAME = "thought_favorites.sqlite3"

local function clean(value)
    return U.trim(tostring(value or ""))
end

local function database_path(store)
    return tostring(store.data_dir) .. "/" .. Favorites.FILE_NAME
end

local function initialize(conn)
    conn:exec([[
        CREATE TABLE IF NOT EXISTS thought_favorites (
            favorite_id TEXT PRIMARY KEY,
            book_id TEXT NOT NULL DEFAULT '',
            book_title TEXT NOT NULL DEFAULT '',
            book_author TEXT NOT NULL DEFAULT '',
            chapter_uid TEXT NOT NULL DEFAULT '',
            chapter_title TEXT NOT NULL DEFAULT '',
            range_key TEXT NOT NULL DEFAULT '',
            review_id TEXT NOT NULL DEFAULT '',
            source_text TEXT NOT NULL DEFAULT '',
            comment_author TEXT NOT NULL DEFAULT '',
            comment_content TEXT NOT NULL DEFAULT '',
            likes INTEGER NOT NULL DEFAULT 0,
            comment_created INTEGER NOT NULL DEFAULT 0,
            saved_at INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_thought_favorites_saved
            ON thought_favorites(saved_at DESC);
        CREATE INDEX IF NOT EXISTS idx_thought_favorites_book
            ON thought_favorites(book_id, saved_at DESC);
        CREATE INDEX IF NOT EXISTS idx_thought_favorites_review
            ON thought_favorites(review_id);
    ]])
    SQLiteStore.set_text(conn, "thought_favorites_schema_version",
        tostring(Favorites.SCHEMA_VERSION))
end

local function open(store, read_only)
    local path = database_path(store)
    if read_only == true and lfs.attributes(path, "mode") ~= "file" then
        return nil
    end
    local conn = SQLiteStore.open(path, read_only == true)
    if read_only ~= true then initialize(conn) end
    return conn
end

local function identity_parts(row)
    row = type(row) == "table" and row or {}
    local book_id = clean(row.book_id)
    local chapter_uid = clean(row.chapter_uid)
    local range_key = clean(row.range_key or row.range)
    local review_id = clean(row.review_id)
    if review_id ~= "" then
        return table.concat({"review", book_id, chapter_uid, range_key, review_id}, "\31")
    end
    return table.concat({
        "content", book_id, chapter_uid, range_key,
        clean(row.comment_author or row.author),
        clean(row.comment_content or row.content),
    }, "\31")
end

function Favorites.favorite_id(row)
    return Digests.sha256(identity_parts(row)):sub(1, 40)
end

local function normalize(row)
    row = type(row) == "table" and row or {}
    local item = {
        book_id = clean(row.book_id),
        book_title = clean(row.book_title),
        book_author = clean(row.book_author),
        chapter_uid = clean(row.chapter_uid),
        chapter_title = clean(row.chapter_title),
        range_key = clean(row.range_key or row.range),
        review_id = clean(row.review_id),
        source_text = clean(row.source_text),
        comment_author = clean(row.comment_author or row.author),
        comment_content = clean(row.comment_content or row.content),
        likes = math.max(0, tonumber(row.likes or 0) or 0),
        comment_created = math.max(0, tonumber(row.comment_created or row.created or 0) or 0),
        saved_at = math.max(0, tonumber(row.saved_at or 0) or 0),
    }
    if item.comment_author == "" then item.comment_author = "微信读书用户" end
    item.favorite_id = Favorites.favorite_id(item)
    return item
end

function Favorites.path(store)
    return database_path(store)
end

function Favorites.exists(store)
    return lfs.attributes(database_path(store), "mode") == "file"
end

function Favorites.contains(store, row)
    if not Favorites.exists(store) then return false end
    local item = normalize(row)
    local conn = open(store, true)
    if not conn then return false end
    local ok, found = pcall(function()
        local stmt = conn:prepare("SELECT 1 FROM thought_favorites WHERE favorite_id = ? LIMIT 1")
        local result = stmt:bind(item.favorite_id):step()
        stmt:close()
        return result ~= nil
    end)
    pcall(conn.close, conn)
    return ok and found == true
end

function Favorites.save(store, row)
    local item = normalize(row)
    if item.book_id == "" or item.comment_content == "" then
        return nil, "收藏内容不完整"
    end
    local now = os.time()
    local conn = open(store, false)
    local ok, result = xpcall(function()
        if item.saved_at <= 0 then
            local existing = conn:prepare("SELECT saved_at FROM thought_favorites WHERE favorite_id = ? LIMIT 1")
            local row = existing:bind(item.favorite_id):step()
            existing:close()
            item.saved_at = math.max(0, tonumber(row and row[1] or 0) or 0)
            if item.saved_at <= 0 then item.saved_at = now end
        end
        local stmt = conn:prepare([[
            INSERT OR REPLACE INTO thought_favorites(
                favorite_id, book_id, book_title, book_author,
                chapter_uid, chapter_title, range_key, review_id,
                source_text, comment_author, comment_content, likes,
                comment_created, saved_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        stmt:bind(
            item.favorite_id, item.book_id, item.book_title, item.book_author,
            item.chapter_uid, item.chapter_title, item.range_key, item.review_id,
            item.source_text, item.comment_author, item.comment_content, item.likes,
            item.comment_created, item.saved_at, now
        ):step()
        stmt:close()
        return item
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(result) end
    return result
end

function Favorites.remove(store, row_or_id)
    if not Favorites.exists(store) then return true end
    local favorite_id = type(row_or_id) == "string"
        and tostring(row_or_id) or Favorites.favorite_id(row_or_id)
    local conn = open(store, false)
    local ok, err = xpcall(function()
        local stmt = conn:prepare("DELETE FROM thought_favorites WHERE favorite_id = ?")
        stmt:bind(favorite_id):step()
        stmt:close()
        return true
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(err) end
    return true
end

function Favorites.toggle(store, row)
    local item = normalize(row)
    if Favorites.contains(store, item) then
        local ok, err = Favorites.remove(store, item)
        if not ok then return nil, err end
        return false, item
    end
    local saved, err = Favorites.save(store, item)
    if not saved then return nil, err end
    return true, saved
end

local function row_from_sql(row)
    return {
        favorite_id = tostring(row[1] or ""),
        book_id = tostring(row[2] or ""),
        book_title = tostring(row[3] or ""),
        book_author = tostring(row[4] or ""),
        chapter_uid = tostring(row[5] or ""),
        chapter_title = tostring(row[6] or ""),
        range_key = tostring(row[7] or ""),
        review_id = tostring(row[8] or ""),
        source_text = tostring(row[9] or ""),
        comment_author = tostring(row[10] or ""),
        comment_content = tostring(row[11] or ""),
        likes = tonumber(row[12] or 0) or 0,
        comment_created = tonumber(row[13] or 0) or 0,
        saved_at = tonumber(row[14] or 0) or 0,
        updated_at = tonumber(row[15] or 0) or 0,
    }
end

function Favorites.list(store, options)
    options = type(options) == "table" and options or {}
    if not Favorites.exists(store) then return {} end
    local limit = math.max(1, math.min(500, tonumber(options.limit) or 200))
    local book_id = clean(options.book_id)
    local conn = open(store, true)
    if not conn then return {} end
    local ok, result = xpcall(function()
        local sql = [[
            SELECT favorite_id, book_id, book_title, book_author,
                   chapter_uid, chapter_title, range_key, review_id,
                   source_text, comment_author, comment_content, likes,
                   comment_created, saved_at, updated_at
              FROM thought_favorites
        ]]
        if book_id ~= "" then sql = sql .. " WHERE book_id = ?" end
        sql = sql .. " ORDER BY saved_at DESC, favorite_id DESC LIMIT ?"
        local stmt = conn:prepare(sql)
        if book_id ~= "" then stmt:bind(book_id, limit) else stmt:bind(limit) end
        local rows, row = {}, {}
        while stmt:step(row) do
            rows[#rows + 1] = row_from_sql(row)
            row = {}
        end
        stmt:close()
        return rows
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(result) end
    return result
end

function Favorites.books(store)
    if not Favorites.exists(store) then return {} end
    local conn = open(store, true)
    if not conn then return {} end
    local ok, result = xpcall(function()
        local stmt = conn:prepare([[
            SELECT book_id, MAX(book_title), MAX(book_author), COUNT(*), MAX(saved_at)
              FROM thought_favorites
             GROUP BY book_id
             ORDER BY MAX(saved_at) DESC, MAX(book_title) ASC
        ]])
        local rows, row = {}, {}
        while stmt:step(row) do
            rows[#rows + 1] = {
                book_id=tostring(row[1] or ""),
                book_title=tostring(row[2] or ""),
                book_author=tostring(row[3] or ""),
                count=tonumber(row[4] or 0) or 0,
                saved_at=tonumber(row[5] or 0) or 0,
            }
            row = {}
        end
        stmt:close()
        return rows
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(result) end
    return result
end

function Favorites.count(store)
    if not Favorites.exists(store) then return 0 end
    local conn = open(store, true)
    if not conn then return 0 end
    local ok, count = pcall(function()
        local stmt = conn:prepare("SELECT COUNT(*) FROM thought_favorites")
        local row = stmt:step()
        stmt:close()
        return tonumber(row and row[1] or 0) or 0
    end)
    pcall(conn.close, conn)
    return ok and count or 0
end

return Favorites
