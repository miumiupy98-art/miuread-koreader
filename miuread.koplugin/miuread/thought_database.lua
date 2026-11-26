local SQLiteStore = require("miuread.sqlite_store")
local Json = require("miuread.json")
local U = require("miuread.util")
local lfs = require("libs/libkoreader-lfs")

local ThoughtDatabase = {}

ThoughtDatabase.SCHEMA_VERSION = 5
ThoughtDatabase.FILE_NAME = "thoughts.sqlite3"

local function chapter_key(value)
    return U.id_name(tostring(value or ""))
end

-- Read-only lookups must not recreate an empty cache directory after a
-- book is deleted. Only a write operation is allowed to create the book dir.
local function database_path(store, book_id)
    local root = type(store.book_cache_path) == "function"
        and store:book_cache_path(book_id) or store:book_dir(book_id)
    return root .. "/" .. ThoughtDatabase.FILE_NAME
end

local function initialize(conn)
    conn:exec([[
        CREATE TABLE IF NOT EXISTS thought_chapters (
            chapter_uid TEXT PRIMARY KEY,
            group_count INTEGER NOT NULL DEFAULT 0,
            comment_count INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS thought_groups (
            chapter_uid TEXT NOT NULL,
            range_key TEXT NOT NULL,
            ordinal INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(chapter_uid, range_key)
        );
        CREATE TABLE IF NOT EXISTS thought_comments (
            chapter_uid TEXT NOT NULL,
            range_key TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            content TEXT NOT NULL DEFAULT '',
            abstract TEXT NOT NULL DEFAULT '',
            author TEXT NOT NULL DEFAULT '',
            likes INTEGER NOT NULL DEFAULT 0,
            created INTEGER NOT NULL DEFAULT 0,
            review_id TEXT NOT NULL DEFAULT '',
            PRIMARY KEY(chapter_uid, range_key, ordinal),
            FOREIGN KEY(chapter_uid, range_key)
                REFERENCES thought_groups(chapter_uid, range_key)
                ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_thought_group_chapter
            ON thought_groups(chapter_uid, ordinal);
        CREATE INDEX IF NOT EXISTS idx_thought_comment_lookup
            ON thought_comments(chapter_uid, range_key, ordinal);
        CREATE INDEX IF NOT EXISTS idx_thought_comment_review
            ON thought_comments(review_id);
        CREATE INDEX IF NOT EXISTS idx_thought_comment_created
            ON thought_comments(created);
        -- V4 stores synchronization and future document-location state separately
        -- from the original review rows. The existing V3 tables are never rebuilt.
        CREATE TABLE IF NOT EXISTS thought_sync_state (
            chapter_uid TEXT PRIMARY KEY,
            status TEXT NOT NULL DEFAULT 'legacy',
            last_attempt_at INTEGER NOT NULL DEFAULT 0,
            last_success_at INTEGER NOT NULL DEFAULT 0,
            last_error TEXT NOT NULL DEFAULT '',
            cursor TEXT NOT NULL DEFAULT '',
            FOREIGN KEY(chapter_uid) REFERENCES thought_chapters(chapter_uid) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS thought_locations (
            chapter_uid TEXT NOT NULL,
            range_key TEXT NOT NULL,
            document_fingerprint TEXT NOT NULL DEFAULT '',
            xpointer_start TEXT NOT NULL DEFAULT '',
            xpointer_end TEXT NOT NULL DEFAULT '',
            match_status TEXT NOT NULL DEFAULT 'pending',
            updated_at INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(chapter_uid, range_key)
        );
        INSERT OR IGNORE INTO thought_chapters(chapter_uid, group_count, comment_count, updated_at)
        SELECT g.chapter_uid,
               COUNT(*),
               (SELECT COUNT(*) FROM thought_comments c WHERE c.chapter_uid = g.chapter_uid),
               0
          FROM thought_groups g
         GROUP BY g.chapter_uid;
    ]])
    conn:exec([[
        CREATE TABLE IF NOT EXISTS thought_range_pages (
            chapter_uid TEXT NOT NULL,
            range_key TEXT NOT NULL,
            account TEXT NOT NULL,
            cursor INTEGER NOT NULL,
            PRIMARY KEY(chapter_uid, range_key, account)
        );
    ]])
    -- Preserve legacy migration records: a schema open must never destroy data.
    conn:exec([[INSERT OR IGNORE INTO thought_sync_state(chapter_uid, status, last_success_at)
        SELECT chapter_uid, 'legacy', updated_at FROM thought_chapters;]])
    SQLiteStore.set_text(conn, "thought_schema_version", tostring(ThoughtDatabase.SCHEMA_VERSION))
end

local function compact_group(group)
    if type(group) ~= "table" then return nil end
    local range = tostring(group.range or "")
    if range == "" then return nil end
    local texts = {}
    for _, row in ipairs(group.texts or {}) do
        if type(row) == "table" and tostring(row.content or "") ~= "" then
            texts[#texts + 1] = {
                content = tostring(row.content or ""),
                abstract = tostring(row.abstract or ""),
                author = tostring(row.author or ""),
                likes = tonumber(row.likes or 0) or 0,
                created = tonumber(row.created or 0) or 0,
                review_id = tostring(row.review_id or ""),
            }
        end
    end
    if #texts == 0 then return nil end
    return {range=range, texts=texts}
end

local function normalized_groups(groups)
    local rows, seen_ranges = {}, {}
    for _, group in ipairs(groups or {}) do
        local item = compact_group(group)
        if item then
            local previous = seen_ranges[item.range]
            if previous then
                for _, row in ipairs(item.texts) do previous.texts[#previous.texts + 1] = row end
            else
                seen_ranges[item.range] = item
                rows[#rows + 1] = item
            end
        end
    end
    return rows
end

local function open(store, book_id, read_only)
    if read_only ~= true then store:book_dir(book_id) end
    local conn = SQLiteStore.open(database_path(store, book_id), read_only == true)
    if read_only ~= true then initialize(conn) end
    return conn
end

-- Append/merge responses. A partial network batch must NEVER replace older reviews.
-- Keep the V3 ordinal keys and group order so old reading clients can still load
-- the database. IDs are preferred; a content fingerprint is the legacy fallback.
local function review_fingerprint(item)
    return table.concat({tostring(item.author or ""), tostring(item.content or ""),
        tostring(item.created or 0)}, "\31")
end

local function merge_chapter(conn, chapter_uid, groups, keep_complete)
    chapter_uid = chapter_key(chapter_uid)
    if chapter_uid == "" then error("章节标识为空") end
    local rows = normalized_groups(groups)
    local previous = conn:prepare("SELECT 1 FROM thought_chapters WHERE chapter_uid = ? LIMIT 1")
    local was_known = previous:bind(chapter_uid):step() ~= nil
    previous:close()

    local existing_groups = {}
    local group_stmt = conn:prepare([[SELECT range_key, ordinal FROM thought_groups
        WHERE chapter_uid = ? ORDER BY ordinal]])
    group_stmt:bind(chapter_uid)
    local next_group = 0
    while true do
        local row = group_stmt:step()
        if not row then break end
        local range = tostring(row[1] or "")
        local ordinal = tonumber(row[2] or 0) or 0
        existing_groups[range] = true
        if ordinal > next_group then next_group = ordinal end
    end
    group_stmt:close()

    local added = 0
    for _, group in ipairs(rows) do
        local range = group.range
        if not existing_groups[range] then
            next_group = next_group + 1
            local add_group = conn:prepare([[INSERT INTO thought_groups
                (chapter_uid, range_key, ordinal) VALUES(?, ?, ?)]])
            add_group:bind(chapter_uid, range, next_group):step()
            add_group:close()
            existing_groups[range] = true
        end
        local by_id, by_fingerprint = {}, {}
        local next_ordinal = 0
        local old = conn:prepare([[SELECT ordinal, content, abstract, author, likes, created, review_id
            FROM thought_comments WHERE chapter_uid = ? AND range_key = ? ORDER BY ordinal]])
        old:bind(chapter_uid, range)
        while true do
            local row = old:step()
            if not row then break end
            local ordinal = tonumber(row[1] or 0) or 0
            if ordinal > next_ordinal then next_ordinal = ordinal end
            local item = {content=row[2], abstract=row[3], author=row[4],
                created=row[6], review_id=tostring(row[7] or "")}
            if item.review_id ~= "" then by_id[item.review_id] = ordinal end
            by_fingerprint[review_fingerprint(item)] = ordinal
        end
        old:close()
        for _, item in ipairs(group.texts) do
            local fingerprint = review_fingerprint(item)
            local ordinal = (item.review_id ~= "" and by_id[item.review_id]) or by_fingerprint[fingerprint]
            if ordinal then
                -- Nonempty incoming text is the latest known text, while an empty
                -- value must not blank a previously stored review.
                local update = conn:prepare([[UPDATE thought_comments
                    SET content = CASE WHEN ? <> '' THEN ? ELSE content END,
                        abstract = CASE WHEN ? <> '' THEN ? ELSE abstract END,
                        author = CASE WHEN ? <> '' THEN ? ELSE author END,
                        likes = ?,
                        review_id = CASE WHEN ? <> '' THEN ? ELSE review_id END
                    WHERE chapter_uid = ? AND range_key = ? AND ordinal = ?]])
                update:bind(item.content, item.content, item.abstract, item.abstract,
                    item.author, item.author, item.likes, item.review_id, item.review_id,
                    chapter_uid, range, ordinal):step()
                update:close()
            else
                next_ordinal = next_ordinal + 1
                ordinal = next_ordinal
                local insert = conn:prepare([[INSERT INTO thought_comments(
                    chapter_uid, range_key, ordinal, content, abstract, author, likes, created, review_id
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)]])
                insert:bind(chapter_uid, range, ordinal, item.content, item.abstract,
                    item.author, item.likes, item.created, item.review_id):step()
                insert:close()
                added = added + 1
            end
            if item.review_id ~= "" then by_id[item.review_id] = ordinal end
            by_fingerprint[fingerprint] = ordinal
        end
    end

    local counts = conn:prepare([[SELECT
        (SELECT COUNT(*) FROM thought_groups WHERE chapter_uid = ?),
        (SELECT COUNT(*) FROM thought_comments WHERE chapter_uid = ?)]])
    local count_row = counts:bind(chapter_uid, chapter_uid):step()
    counts:close()
    local group_count = tonumber(count_row and count_row[1] or 0) or 0
    local comment_count = tonumber(count_row and count_row[2] or 0) or 0
    local create_chapter = conn:prepare([[INSERT OR IGNORE INTO thought_chapters
        (chapter_uid, group_count, comment_count, updated_at) VALUES(?, 0, 0, 0)]])
    create_chapter:bind(chapter_uid):step()
    create_chapter:close()
    local mark = conn:prepare([[UPDATE thought_chapters SET group_count = ?,
        comment_count = ?, updated_at = ? WHERE chapter_uid = ?]])
    mark:bind(group_count, comment_count, os.time(), chapter_uid):step()
    mark:close()
    -- 'partial' is intentionally conservative: the reader's API might return
    -- only the first page, and B2 will own verified pagination/completeness.
    local new_state = conn:prepare([[INSERT OR IGNORE INTO thought_sync_state
        (chapter_uid, status) VALUES(?, 'legacy')]])
    new_state:bind(chapter_uid):step()
    new_state:close()
    local state = conn:prepare([[UPDATE thought_sync_state
        SET status = CASE WHEN ? = 1 AND status = 'cached' THEN status ELSE 'partial' END,
        last_attempt_at = ?, last_success_at = ?, last_error = '' WHERE chapter_uid = ?]])
    state:bind(keep_complete and 1 or 0, os.time(), os.time(), chapter_uid):step()
    state:close()
    return {groups=group_count, comments=comment_count, added=added, previously_known=was_known}
end

local function chapter_counts_conn(conn, chapter_uid)
    chapter_uid = chapter_key(chapter_uid)
    local statement = conn:prepare([[
        SELECT group_count, comment_count
          FROM thought_chapters WHERE chapter_uid = ? LIMIT 1
    ]])
    local row = statement:bind(chapter_uid):step()
    statement:close()
    return {
        groups=tonumber(row and row[1] or 0) or 0,
        comments=tonumber(row and row[2] or 0) or 0,
    }
end

function ThoughtDatabase.path(store, book_id)
    return database_path(store, book_id)
end

function ThoughtDatabase.exists(store, book_id)
    return lfs.attributes(database_path(store, book_id), "mode") == "file"
end

function ThoughtDatabase.save_chapter(store, book_id, chapter_uid, groups, keep_complete)
    local conn = open(store, book_id, false)
    local ok, result = xpcall(function()
        return SQLiteStore.transaction(conn, function()
            return merge_chapter(conn, chapter_uid, groups, keep_complete)
        end)
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(result) end
    return result
end

local function cursor_on(conn,uid,range,account)
    local stmt=conn:prepare([[SELECT cursor FROM thought_range_pages
        WHERE chapter_uid=? AND range_key=? AND account=? LIMIT 1]])
    local row=stmt:bind(chapter_key(uid),range,account):step()
    stmt:close()
    return row and tonumber(row[1]) or nil
end

-- nil means no segment-specific request has been made. Zero means the API
-- confirmed the end, including a segment without displayable reviews.
function ThoughtDatabase.range_cursor(store,book_id,uid,range,account)
    if not account or account=="" or not ThoughtDatabase.exists(store,book_id) then return nil end
    local ok,cursor=pcall(SQLiteStore.with_connection,database_path(store,book_id),true,function(conn)
        local schema=conn:prepare("SELECT name FROM sqlite_master WHERE name='thought_range_pages' LIMIT 1")
        local available=schema:step()
        schema:close()
        if available then return cursor_on(conn,uid,range,account) end
    end)
    return ok and cursor or nil
end

function ThoughtDatabase.save_range_page(store,book_id,uid,range,account,expected,page)
    local conn=open(store,book_id,false)
    local ok,result=xpcall(function()
        return SQLiteStore.transaction(conn,function()
            if cursor_on(conn,uid,range,account)~=expected then
                return false
            end
            if #page.texts>0 then merge_chapter(conn,uid,{page},true) end
            local stmt=conn:prepare([[INSERT OR REPLACE INTO thought_range_pages
                (chapter_uid,range_key,account,cursor) VALUES(?,?,?,?)]])
            stmt:bind(chapter_key(uid),range,account,page.cursor):step()
            stmt:close()
            return true
        end)
    end,debug.traceback)
    pcall(conn.close,conn)
    if not ok then return nil,tostring(result) end
    return result
end

function ThoughtDatabase.match_review_ids(store,book_id,ids)
    local known={}
    if #ids==0 or not ThoughtDatabase.exists(store,book_id) then return known end
    local ok,result=pcall(SQLiteStore.with_connection,database_path(store,book_id),true,function(conn)
        local match=conn:prepare("SELECT 1 FROM thought_comments WHERE review_id = ? LIMIT 1")
        for _,id in ipairs(ids) do
            if match:bind(id):step() then known[id]=true end
            match:reset()
        end
        match:close()
        return known
    end)
    return ok and result or {}
end

function ThoughtDatabase.sync_state(store, book_id, chapter_uid, with_cursor)
    if not ThoughtDatabase.exists(store, book_id) then return nil end
    local ok, result = pcall(function()
        return SQLiteStore.with_connection(database_path(store, book_id), true, function(conn)
            local stmt = conn:prepare(with_cursor and [[SELECT status, last_attempt_at, last_success_at,
                last_error, cursor FROM thought_sync_state WHERE chapter_uid = ? LIMIT 1]] or
                [[SELECT status, last_attempt_at, last_success_at,
                last_error FROM thought_sync_state WHERE chapter_uid = ? LIMIT 1]])
            local row = stmt:bind(chapter_key(chapter_uid)):step()
            stmt:close()
            if not row then return nil end
            return {status=tostring(row[1] or "legacy"),
                last_attempt_at=tonumber(row[2] or 0) or 0,
                last_success_at=tonumber(row[3] or 0) or 0,
                last_error=tostring(row[4] or ""), cursor=with_cursor and tostring(row[5] or "") or ""}
        end)
    end)
    return ok and result or nil
end

-- B2 checkpoint and comments are committed in one SQLite transaction. The
-- `cursor` is a compact range-level checkpoint, not a fabricated API page token.
function ThoughtDatabase.load_checkpoint(store, book_id, chapter_uid)
    local state=ThoughtDatabase.sync_state(store,book_id,chapter_uid,true)
    if not state or state.cursor=="" then return nil end
    local ok,snapshot=pcall(Json.decode,state.cursor)
    return ok and type(snapshot)=="table" and snapshot or nil
end

function ThoughtDatabase.record_fetch(store, book_id, chapter_uid, groups, checkpoint, metadata)
    metadata=type(metadata)=="table" and metadata or {}
    local ok,serialized=pcall(Json.encode,checkpoint)
    if not ok or type(serialized)~="string" then return nil,"评论断点无法序列化" end
    local conn=open(store,book_id,false)
    local good,result=xpcall(function()
        return SQLiteStore.transaction(conn,function()
            local counts=merge_chapter(conn,chapter_uid,groups or {})
            local now=os.time()
            local status=metadata.partial==true and "partial" or
                (metadata.empty==true and counts.comments==0 and "empty" or "cached")
            local stmt=conn:prepare([[UPDATE thought_sync_state SET
                status=?,last_attempt_at=?,
                last_success_at=CASE WHEN ? = 1 THEN ? ELSE last_success_at END,
                last_error=?,cursor=? WHERE chapter_uid=?]])
            stmt:bind(status,now,metadata.succeeded==true and 1 or 0,now,
                tostring(metadata.error or ""),serialized,chapter_key(chapter_uid)):step()
            stmt:close()
            return counts
        end)
    end,debug.traceback)
    pcall(conn.close,conn)
    if not good then return nil,tostring(result) end
    return result
end

-- Preserve all cached groups and the last known good cursor on any error.
function ThoughtDatabase.record_error(store,book_id,chapter_uid,reason)
    local conn=open(store,book_id,false)
    local ok,result=xpcall(function()
        return SQLiteStore.transaction(conn,function()
            local key=chapter_key(chapter_uid)
            local ch=conn:prepare([[INSERT OR IGNORE INTO thought_chapters(chapter_uid)
                VALUES(?) ]])
            ch:bind(key):step(); ch:close()
            local stmt=conn:prepare([[INSERT OR IGNORE INTO thought_sync_state(chapter_uid)
                VALUES(?) ]])
            stmt:bind(key):step(); stmt:close()
            local update=conn:prepare([[UPDATE thought_sync_state
                SET status='error',last_attempt_at=?,last_error=? WHERE chapter_uid=?]])
            update:bind(os.time(),tostring(reason or "unknown"),key):step()
            update:close()
            return true
        end)
    end,debug.traceback)
    pcall(conn.close,conn)
    if not ok then return nil,tostring(result) end
    return result
end

function ThoughtDatabase.chapter_exists(store, book_id, chapter_uid)
    if not ThoughtDatabase.exists(store, book_id) then return false end
    local ok, result = pcall(function()
        local conn = open(store, book_id, true)
        local statement = conn:prepare("SELECT 1 FROM thought_chapters WHERE chapter_uid = ? LIMIT 1")
        local row = statement:bind(chapter_key(chapter_uid)):step()
        statement:close(); conn:close()
        return row ~= nil
    end)
    return ok and result == true
end

function ThoughtDatabase.load_chapter(store, book_id, chapter_uid)
    if not ThoughtDatabase.exists(store, book_id) then return nil, "想法数据库不存在" end
    local conn = open(store, book_id, true)
    local ok, result = xpcall(function()
        local key = chapter_key(chapter_uid)
        local known_statement = conn:prepare([[
            SELECT group_count, comment_count FROM thought_chapters
             WHERE chapter_uid = ? LIMIT 1
        ]])
        local known = known_statement:bind(key):step()
        known_statement:close()
        if not known then return nil end
        local groups, by_range = {}, {}
        local group_stmt = conn:prepare([[
            SELECT range_key FROM thought_groups
             WHERE chapter_uid = ? ORDER BY ordinal
        ]])
        group_stmt:bind(key)
        while true do
            local row = group_stmt:step()
            if not row then break end
            local group = {range=tostring(row[1] or ""), texts={}}
            groups[#groups + 1] = group
            by_range[group.range] = group
        end
        group_stmt:close()

        local comment_stmt = conn:prepare([[
            SELECT range_key, content, abstract, author, likes, created, review_id
              FROM thought_comments
             WHERE chapter_uid = ? ORDER BY range_key, ordinal
        ]])
        comment_stmt:bind(key)
        while true do
            local row = comment_stmt:step()
            if not row then break end
            local group = by_range[tostring(row[1] or "")]
            if group then
                group.texts[#group.texts + 1] = {
                    content=tostring(row[2] or ""), abstract=tostring(row[3] or ""),
                    author=tostring(row[4] or ""), likes=tonumber(row[5] or 0) or 0,
                    created=tonumber(row[6] or 0) or 0, review_id=tostring(row[7] or ""),
                }
            end
        end
        comment_stmt:close()
        return groups
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(result) end
    if result == nil then return nil, "想法缓存不存在" end
    return result
end

function ThoughtDatabase.prewarm_chapter(store, book_id, chapter_uid, limit)
    if not ThoughtDatabase.exists(store, book_id) then return {groups={}, comments=0} end
    limit=math.max(1,math.min(12,tonumber(limit) or 6))
    local conn=open(store,book_id,true)
    local ok,result=xpcall(function()
        local key=chapter_key(chapter_uid)
        if key=="" then return {groups={},comments=0} end
        local groups={}
        local group_stmt=conn:prepare([[
            SELECT range_key FROM thought_groups
             WHERE chapter_uid = ? ORDER BY ordinal LIMIT ?
        ]])
        group_stmt:bind(key,limit)
        while true do
            local row=group_stmt:step()
            if not row then break end
            groups[#groups+1]={range=tostring(row[1] or ""),texts={}}
        end
        group_stmt:close()
        local comments=0
        for _,group in ipairs(groups) do
            local comment_stmt=conn:prepare([[
                SELECT content, abstract, author, likes, created, review_id
                  FROM thought_comments
                 WHERE chapter_uid = ? AND range_key = ? ORDER BY ordinal
            ]])
            comment_stmt:bind(key,group.range)
            while true do
                local row=comment_stmt:step()
                if not row then break end
                group.texts[#group.texts+1]={
                    content=tostring(row[1] or ""), abstract=tostring(row[2] or ""),
                    author=tostring(row[3] or ""), likes=tonumber(row[4] or 0) or 0,
                    created=tonumber(row[5] or 0) or 0, review_id=tostring(row[6] or ""),
                }
                comments=comments+1
            end
            comment_stmt:close()
        end
        return {groups=groups,comments=comments}
    end,debug.traceback)
    pcall(conn.close,conn)
    if not ok then return nil,tostring(result) end
    return result
end

function ThoughtDatabase.find(store, book_id, chapter_uid, range)
    if not ThoughtDatabase.exists(store, book_id) then return nil, "想法数据库不存在" end
    local conn = open(store, book_id, true)
    local ok, result = xpcall(function()
        local key = chapter_key(chapter_uid)
        local known_statement = conn:prepare([[
            SELECT 1 FROM thought_chapters WHERE chapter_uid = ? LIMIT 1
        ]])
        local known = known_statement:bind(key):step() ~= nil
        known_statement:close()
        if not known then return {known=false} end
        local group = {range=tostring(range or ""), texts={}}
        local statement = conn:prepare([[
            SELECT content, abstract, author, likes, created, review_id
              FROM thought_comments
             WHERE chapter_uid = ? AND range_key = ? ORDER BY ordinal
        ]])
        statement:bind(key, tostring(range or ""))
        while true do
            local row = statement:step()
            if not row then break end
            group.texts[#group.texts + 1] = {
                content=tostring(row[1] or ""), abstract=tostring(row[2] or ""),
                author=tostring(row[3] or ""), likes=tonumber(row[4] or 0) or 0,
                created=tonumber(row[5] or 0) or 0, review_id=tostring(row[6] or ""),
            }
        end
        statement:close()
        return {known=true, group=group}
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(result) end
    local token={database=database_path(store, book_id), index_hit=true, authoritative=result.known==true}
    if not result.known then return nil, "想法缓存不存在", token end
    if not result.group or #result.group.texts == 0 then
        return nil, "没有找到该划线对应的想法", token
    end
    return result.group, nil, token
end

function ThoughtDatabase.integrity(store, book_id)
    local path = database_path(store, book_id)
    local healthy = SQLiteStore.integrity_check(path)
    if healthy ~= true then return false end
    local ok, result = pcall(function()
        return SQLiteStore.with_connection(path, true, function(conn)
            local required = {
                thought_chapters=false, thought_groups=false,
                thought_comments=false, kv=false,
            }
            local statement = conn:prepare([[
                SELECT name FROM sqlite_master
                 WHERE type = 'table' AND name IN (
                    'thought_chapters','thought_groups','thought_comments','kv'
                 )
            ]])
            while true do
                local row = statement:step()
                if not row then break end
                required[tostring(row[1] or "")] = true
            end
            statement:close()
            for _, present in pairs(required) do
                if present ~= true then return false end
            end
            local mismatch_statement = conn:prepare([[
                SELECT COUNT(*)
                  FROM thought_chapters c
                  LEFT JOIN (
                        SELECT chapter_uid, COUNT(*) AS actual_groups
                          FROM thought_groups GROUP BY chapter_uid
                  ) g ON g.chapter_uid = c.chapter_uid
                  LEFT JOIN (
                        SELECT chapter_uid, COUNT(*) AS actual_comments
                          FROM thought_comments GROUP BY chapter_uid
                  ) t ON t.chapter_uid = c.chapter_uid
                 WHERE c.group_count <> COALESCE(g.actual_groups, 0)
                    OR c.comment_count <> COALESCE(t.actual_comments, 0)
            ]])
            local mismatch_row = mismatch_statement:step()
            mismatch_statement:close()
            if tonumber(mismatch_row and mismatch_row[1] or 0) ~= 0 then return false end
            local orphan_statement = conn:prepare([[
                SELECT COUNT(*) FROM (
                    SELECT chapter_uid FROM thought_groups
                    UNION
                    SELECT chapter_uid FROM thought_comments
                    EXCEPT
                    SELECT chapter_uid FROM thought_chapters
                )
            ]])
            local orphan_row = orphan_statement:step()
            orphan_statement:close()
            if tonumber(orphan_row and orphan_row[1] or 0) ~= 0 then return false end
            return true
        end)
    end)
    return ok and result == true
end

-- B3: location cache remains inside the existing per-book SQLite file.
-- Entries are document- and quote-specific; a different EPUB or text revision
-- cannot silently reuse the wrong XPointer. All writes are transactional.
function ThoughtDatabase.load_locations(store,book_id,chapter_uid)
    if not ThoughtDatabase.exists(store,book_id) then return {} end
    local ok,rows=pcall(function()
        return SQLiteStore.with_connection(database_path(store,book_id),true,function(conn)
            local out={}
            local stmt=conn:prepare([[SELECT range_key, document_fingerprint,
                xpointer_start,xpointer_end,match_status FROM thought_locations
                WHERE chapter_uid=?]])
            stmt:bind(chapter_key(chapter_uid))
            while true do
                local row=stmt:step();if not row then break end
                out[tostring(row[1] or "")]= {
                    document_fingerprint=tostring(row[2] or ""),
                    xpointer_start=tostring(row[3] or ""),
                    xpointer_end=tostring(row[4] or ""),
                    match_status=tostring(row[5] or "pending")}
            end
            stmt:close()
            return out
        end)
    end)
    return ok and rows or nil
end

function ThoughtDatabase.save_locations(store,book_id,chapter_uid,entries)
    if type(entries)~="table" or #entries==0 then return true end
    local conn=open(store,book_id,false)
    local ok,result=xpcall(function()
        return SQLiteStore.transaction(conn,function()
            local stmt=conn:prepare([[INSERT OR REPLACE INTO thought_locations
                (chapter_uid,range_key,document_fingerprint,xpointer_start,
                 xpointer_end,match_status,updated_at) VALUES(?,?,?,?,?,?,?)]])
            for _,entry in ipairs(entries) do
                if type(entry)=="table" and tostring(entry.range or "")~="" then
                    stmt:bind(chapter_key(chapter_uid),tostring(entry.range),
                        tostring(entry.document_fingerprint or ""),
                        tostring(entry.xpointer_start or ""),
                        tostring(entry.xpointer_end or ""),
                        tostring(entry.match_status or "unmatched"),os.time()):step()
                    stmt:reset()
                end
            end
            stmt:close()
            return true
        end)
    end,debug.traceback)
    pcall(conn.close,conn)
    if not ok then return nil,tostring(result) end
    return result
end

function ThoughtDatabase.remove(store, book_id)
    local path = database_path(store, book_id)
    os.remove(path)
    os.remove(path .. "-wal")
    os.remove(path .. "-shm")
end

return ThoughtDatabase
