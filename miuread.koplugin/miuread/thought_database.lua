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

local function database_path(store, book_id)
    return store:book_dir(book_id) .. "/" .. ThoughtDatabase.FILE_NAME
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
        CREATE TABLE IF NOT EXISTS thought_fetch_state (
            chapter_uid TEXT PRIMARY KEY,
            status TEXT NOT NULL DEFAULT 'unknown',
            fetched_at INTEGER NOT NULL DEFAULT 0,
            complete INTEGER NOT NULL DEFAULT 0,
            last_error TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS thought_fetch_checkpoint (
            chapter_uid TEXT PRIMARY KEY,
            payload TEXT NOT NULL DEFAULT '',
            updated_at INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS thought_locators (
            chapter_uid TEXT NOT NULL,
            range_key TEXT NOT NULL,
            ordinal INTEGER NOT NULL DEFAULT 0,
            source_text TEXT NOT NULL DEFAULT '',
            embedded INTEGER NOT NULL DEFAULT 0,
            body_fingerprint TEXT NOT NULL DEFAULT '',
            updated_at INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(chapter_uid, range_key)
        );
        CREATE INDEX IF NOT EXISTS idx_thought_locator_chapter
            ON thought_locators(chapter_uid, ordinal);
        CREATE TABLE IF NOT EXISTS thought_migration (
            source_path TEXT PRIMARY KEY,
            source_signature TEXT NOT NULL,
            chapter_uid TEXT NOT NULL,
            group_count INTEGER NOT NULL DEFAULT 0,
            comment_count INTEGER NOT NULL DEFAULT 0,
            migrated_at INTEGER NOT NULL DEFAULT 0
        );
        INSERT OR IGNORE INTO thought_chapters(chapter_uid, group_count, comment_count, updated_at)
        SELECT g.chapter_uid,
               COUNT(*),
               (SELECT COUNT(*) FROM thought_comments c WHERE c.chapter_uid = g.chapter_uid),
               0
          FROM thought_groups g
         GROUP BY g.chapter_uid;
        INSERT OR IGNORE INTO thought_chapters(chapter_uid, group_count, comment_count, updated_at)
        SELECT chapter_uid, MAX(group_count), MAX(comment_count), MAX(migrated_at)
          FROM thought_migration
         GROUP BY chapter_uid;
        -- beta.10-beta.12 could persist a false successful empty result.
        -- beta.13 never trusts those legacy empty states: comments may be
        -- re-fetched from the persisted locator ranges without touching正文.
        UPDATE thought_fetch_state
           SET status = 'stale_empty', complete = 0
         WHERE status = 'empty' AND complete = 1;
    ]])
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
        if item and not seen_ranges[item.range] then
            seen_ranges[item.range] = true
            rows[#rows + 1] = item
        end
    end
    return rows
end

local function open(store, book_id, read_only)
    local conn = SQLiteStore.open(database_path(store, book_id), read_only == true)
    if read_only ~= true then initialize(conn) end
    return conn
end

local function replace_chapter(conn, chapter_uid, groups)
    chapter_uid = chapter_key(chapter_uid)
    if chapter_uid == "" then error("章节标识为空") end
    local rows = normalized_groups(groups)

    local delete_comments = conn:prepare("DELETE FROM thought_comments WHERE chapter_uid = ?")
    delete_comments:bind(chapter_uid):step()
    delete_comments:close()
    local delete_groups = conn:prepare("DELETE FROM thought_groups WHERE chapter_uid = ?")
    delete_groups:bind(chapter_uid):step()
    delete_groups:close()

    local insert_group = conn:prepare([[
        INSERT INTO thought_groups(chapter_uid, range_key, ordinal) VALUES(?, ?, ?)
    ]])
    local insert_comment = conn:prepare([[
        INSERT INTO thought_comments(
            chapter_uid, range_key, ordinal, content, abstract, author, likes, created, review_id
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    local comments = 0
    for group_index, group in ipairs(rows) do
        insert_group:bind(chapter_uid, group.range, group_index):step()
        insert_group:clearbind():reset()
        for comment_index, item in ipairs(group.texts or {}) do
            insert_comment:bind(chapter_uid, group.range, comment_index,
                item.content, item.abstract, item.author, item.likes, item.created, item.review_id):step()
            insert_comment:clearbind():reset()
            comments = comments + 1
        end
    end
    insert_group:close()
    insert_comment:close()
    local chapter_statement = conn:prepare([[
        INSERT OR REPLACE INTO thought_chapters(
            chapter_uid, group_count, comment_count, updated_at
        ) VALUES(?, ?, ?, ?)
    ]])
    chapter_statement:bind(chapter_uid, #rows, comments, os.time()):step()
    chapter_statement:close()
    return {groups=#rows, comments=comments}
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

local function record_migration_conn(conn, source_path, source_signature, chapter_uid, counts)
    local statement = conn:prepare([[
        INSERT OR REPLACE INTO thought_migration(
            source_path, source_signature, chapter_uid, group_count, comment_count, migrated_at
        ) VALUES(?, ?, ?, ?, ?, ?)
    ]])
    statement:bind(tostring(source_path or ""), tostring(source_signature or ""), chapter_key(chapter_uid),
        tonumber(counts and counts.groups or 0) or 0,
        tonumber(counts and counts.comments or 0) or 0,
        os.time()):step()
    statement:close()
end

function ThoughtDatabase.path(store, book_id)
    return database_path(store, book_id)
end

function ThoughtDatabase.exists(store, book_id)
    return lfs.attributes(database_path(store, book_id), "mode") == "file"
end

function ThoughtDatabase.save_chapter(store, book_id, chapter_uid, groups)
    local conn = open(store, book_id, false)
    local ok, result = xpcall(function()
        return SQLiteStore.transaction(conn, function()
            return replace_chapter(conn, chapter_uid, groups)
        end)
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(result) end
    return result
end

function ThoughtDatabase.migrate_chapter(store, book_id, chapter_uid, groups, source_path, source_signature, expected)
    local conn = open(store, book_id, false)
    local ok, result = xpcall(function()
        return SQLiteStore.transaction(conn, function()
            local saved = replace_chapter(conn, chapter_uid, groups)
            local actual = chapter_counts_conn(conn, chapter_uid)
            local wanted = type(expected) == "table" and expected or saved
            if actual.groups ~= (tonumber(wanted.groups) or 0)
                or actual.comments ~= (tonumber(wanted.comments) or 0) then
                error("迁移后数量不一致")
            end
            record_migration_conn(conn, source_path, source_signature, chapter_uid, actual)
            return actual
        end)
    end, debug.traceback)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(result) end
    return result
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

function ThoughtDatabase.chapter_counts(store, book_id, chapter_uid)
    if not ThoughtDatabase.exists(store, book_id) then return {groups=0, comments=0} end
    local ok, result = pcall(function()
        local conn = open(store, book_id, true)
        local counts = chapter_counts_conn(conn, chapter_uid)
        conn:close()
        return counts
    end)
    return ok and result or {groups=0, comments=0}
end

local function compact_locator(row, fallback_ordinal, fallback_fingerprint)
    if type(row) ~= "table" then return nil end
    local range=tostring(row.range or row.range_key or "")
    if range=="" then return nil end
    return {
        range=range,
        ordinal=tonumber(row.ordinal or fallback_ordinal or 0) or 0,
        source_text=tostring(row.source_text or row.text or row.markText or row.abstract or ""),
        embedded=row.embedded==true,
        body_fingerprint=tostring(row.body_fingerprint or fallback_fingerprint or ""),
    }
end

function ThoughtDatabase.save_locators(store, book_id, chapter_uid, rows, body_fingerprint, replace_existing)
    local conn=open(store,book_id,false)
    local ok,result=xpcall(function()
        return SQLiteStore.transaction(conn,function()
            local key=chapter_key(chapter_uid)
            if key=="" then error("章节标识为空") end
            if replace_existing==true then
                local st=conn:prepare("DELETE FROM thought_locators WHERE chapter_uid = ?")
                st:bind(key):step(); st:close()
            end
            local existing={}
            if replace_existing~=true then
                local st=conn:prepare([[SELECT range_key, embedded, body_fingerprint FROM thought_locators WHERE chapter_uid = ?]])
                st:bind(key)
                while true do
                    local row=st:step(); if not row then break end
                    existing[tostring(row[1] or "")]={embedded=tonumber(row[2] or 0)==1,fingerprint=tostring(row[3] or "")}
                end
                st:close()
            end
            local statement=conn:prepare([[
                INSERT OR REPLACE INTO thought_locators(
                    chapter_uid, range_key, ordinal, source_text, embedded, body_fingerprint, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?)
            ]])
            local saved=0
            for index,row in ipairs(type(rows)=="table" and rows or {}) do
                local item=compact_locator(row,index,body_fingerprint)
                if item then
                    local old=existing[item.range]
                    if old then
                        -- A later underlines refresh must not downgrade a locator
                        -- that is already embedded in the canonical EPUB.
                        if old.embedded then item.embedded=true end
                        if item.body_fingerprint=="" then item.body_fingerprint=old.fingerprint end
                    end
                    statement:bind(key,item.range,item.ordinal,item.source_text,item.embedded and 1 or 0,
                        item.body_fingerprint,os.time()):step()
                    statement:clearbind():reset()
                    saved=saved+1
                end
            end
            statement:close()
            return saved
        end)
    end,debug.traceback)
    pcall(conn.close,conn)
    if not ok then return nil,tostring(result) end
    return true,result
end

function ThoughtDatabase.load_locators(store, book_id, chapter_uid)
    if not ThoughtDatabase.exists(store,book_id) then return {} end
    local ok,result=pcall(function()
        local conn=open(store,book_id,true)
        local rows={}
        local statement=conn:prepare([[
            SELECT range_key, ordinal, source_text, embedded, body_fingerprint, updated_at
              FROM thought_locators WHERE chapter_uid = ? ORDER BY ordinal, range_key
        ]])
        statement:bind(chapter_key(chapter_uid))
        while true do
            local row=statement:step(); if not row then break end
            rows[#rows+1]={
                range=tostring(row[1] or ""),ordinal=tonumber(row[2] or 0) or 0,
                source_text=tostring(row[3] or ""),embedded=tonumber(row[4] or 0)==1,
                body_fingerprint=tostring(row[5] or ""),updated_at=tonumber(row[6] or 0) or 0,
            }
        end
        statement:close(); conn:close(); return rows
    end)
    return ok and result or {}
end

function ThoughtDatabase.locator_chapters(store, book_id)
    if not ThoughtDatabase.exists(store,book_id) then return {} end
    local ok,result=pcall(function()
        local conn=open(store,book_id,true)
        local rows={}
        local statement=conn:prepare([[
            SELECT chapter_uid, COUNT(*), SUM(CASE WHEN embedded = 1 THEN 1 ELSE 0 END), MAX(updated_at)
              FROM thought_locators GROUP BY chapter_uid ORDER BY MAX(updated_at) DESC, chapter_uid
        ]])
        while true do
            local row=statement:step(); if not row then break end
            rows[#rows+1]={chapter_uid=tostring(row[1] or ""),locators=tonumber(row[2] or 0) or 0,
                embedded=tonumber(row[3] or 0) or 0,updated_at=tonumber(row[4] or 0) or 0}
        end
        statement:close(); conn:close(); return rows
    end)
    return ok and result or {}
end

function ThoughtDatabase.locator_count(store, book_id, chapter_uid)
    local rows=ThoughtDatabase.load_locators(store,book_id,chapter_uid)
    return #rows
end

function ThoughtDatabase.delete_book_comments(store, book_id)
    if not ThoughtDatabase.exists(store,book_id) then return true end
    local conn=open(store,book_id,false)
    local ok,err=xpcall(function()
        SQLiteStore.transaction(conn,function()
            for _,sql in ipairs({
                "DELETE FROM thought_comments",
                "DELETE FROM thought_groups",
                "DELETE FROM thought_chapters",
                "DELETE FROM thought_fetch_state",
                "DELETE FROM thought_fetch_checkpoint",
            }) do conn:exec(sql) end
        end)
    end,debug.traceback)
    pcall(conn.close,conn)
    if not ok then return nil,tostring(err) end
    return true
end

function ThoughtDatabase.set_fetch_state(store, book_id, chapter_uid, status, complete, last_error)
    local conn = open(store, book_id, false)
    local ok, err = pcall(function()
        local statement=conn:prepare([[
            INSERT OR REPLACE INTO thought_fetch_state(
                chapter_uid, status, fetched_at, complete, last_error
            ) VALUES(?, ?, ?, ?, ?)
        ]])
        statement:bind(chapter_key(chapter_uid), tostring(status or "unknown"), os.time(), complete==true and 1 or 0,
            tostring(last_error or "")):step()
        statement:close()
    end)
    pcall(conn.close, conn)
    if not ok then return nil,tostring(err) end
    return true
end

function ThoughtDatabase.chapter_status(store, book_id, chapter_uid)
    if not ThoughtDatabase.exists(store,book_id) then
        return {known=false,status="missing",groups=0,comments=0,complete=false,fetched_at=0}
    end
    local ok,result=pcall(function()
        local conn=open(store,book_id,false)
        local key=chapter_key(chapter_uid)
        local counts=chapter_counts_conn(conn,key)
        local statement=conn:prepare([[
            SELECT status, fetched_at, complete, last_error
              FROM thought_fetch_state WHERE chapter_uid = ? LIMIT 1
        ]])
        local row=statement:bind(key):step()
        statement:close()
        local known_statement=conn:prepare("SELECT 1 FROM thought_chapters WHERE chapter_uid = ? LIMIT 1")
        local known=known_statement:bind(key):step()~=nil
        known_statement:close()
        conn:close()
        local locator_count=ThoughtDatabase.locator_count(store,book_id,chapter_uid)
        return {
            known=known or locator_count>0,status=tostring(row and row[1] or (known and "cached" or "missing")),
            fetched_at=tonumber(row and row[2] or 0) or 0,complete=tonumber(row and row[3] or 0)==1,
            last_error=tostring(row and row[4] or ""),groups=counts.groups,comments=counts.comments,
            locators=locator_count,
        }
    end)
    return ok and result or {known=false,status="error",groups=0,comments=0,complete=false,fetched_at=0}
end

function ThoughtDatabase.book_status(store, book_id, chapter_uids)
    local ids=type(chapter_uids)=="table" and chapter_uids or {}
    local result={chapters=#ids,cached=0,complete=0,empty=0,partial=0,error=0,suspicious=0,comments=0,groups=0}
    if #ids==0 or not ThoughtDatabase.exists(store,book_id) then return result end
    local wanted={}
    for _,uid in ipairs(ids) do
        local key=chapter_key(uid)
        if key~="" then wanted[key]=true end
    end
    local ok,value=pcall(function()
        -- Open once for the whole menu/status calculation. Opening one SQLite
        -- connection per chapter made the comment center unnecessarily costly
        -- on e-ink devices with long books. Writable open also initializes the
        -- beta.9 fetch-state table when this is an older beta.8 database.
        local conn=open(store,book_id,false)
        local rows={}
        local chapter_stmt=conn:prepare([[
            SELECT chapter_uid, group_count, comment_count FROM thought_chapters
        ]])
        while true do
            local row=chapter_stmt:step()
            if not row then break end
            local key=tostring(row[1] or "")
            if wanted[key] then
                rows[key]={groups=tonumber(row[2] or 0) or 0,comments=tonumber(row[3] or 0) or 0}
            end
        end
        chapter_stmt:close()
        local complete,state={} ,{}
        local state_stmt=conn:prepare([[
            SELECT chapter_uid, complete, status FROM thought_fetch_state
        ]])
        while true do
            local row=state_stmt:step()
            if not row then break end
            local key=tostring(row[1] or "")
            if wanted[key] then
                if tonumber(row[2] or 0)==1 then complete[key]=true end
                state[key]=tostring(row[3] or "unknown")
            end
        end
        state_stmt:close()
        conn:close()
        return {rows=rows,complete=complete,state=state}
    end)
    if not ok or type(value)~="table" then return result end
    local counted={}
    for key,row in pairs(value.rows or {}) do
        counted[key]=true
        result.cached=result.cached+1
        result.groups=result.groups+(tonumber(row.groups) or 0)
        result.comments=result.comments+(tonumber(row.comments) or 0)
        if value.complete and value.complete[key] then result.complete=result.complete+1 end
        local state=value.state and tostring(value.state[key] or "") or ""
        if state=="verified_empty" then result.empty=result.empty+1
        elseif state=="partial" or state=="stale_empty" then result.partial=result.partial+1
        elseif state=="suspicious_empty" then result.suspicious=result.suspicious+1
        elseif state=="error" then result.error=result.error+1 end
    end
    -- A failed first fetch can have state but no thought_chapters row yet. Keep
    -- those failures visible in book-level status instead of reporting a clean book.
    for key,state in pairs(value.state or {}) do
        if not counted[key] then
            state=tostring(state or "")
            if state=="partial" or state=="stale_empty" then result.partial=result.partial+1
            elseif state=="suspicious_empty" then result.suspicious=result.suspicious+1
            elseif state=="error" then result.error=result.error+1 end
        end
    end
    return result
end

function ThoughtDatabase.delete_chapter(store, book_id, chapter_uid)
    if not ThoughtDatabase.exists(store,book_id) then return true end
    local conn=open(store,book_id,false)
    local ok,err=xpcall(function()
        SQLiteStore.transaction(conn,function()
            local key=chapter_key(chapter_uid)
            for _,sql in ipairs({
                "DELETE FROM thought_comments WHERE chapter_uid = ?",
                "DELETE FROM thought_groups WHERE chapter_uid = ?",
                "DELETE FROM thought_chapters WHERE chapter_uid = ?",
                "DELETE FROM thought_fetch_state WHERE chapter_uid = ?",
                "DELETE FROM thought_fetch_checkpoint WHERE chapter_uid = ?",
            }) do
                local st=conn:prepare(sql); st:bind(key):step(); st:close()
            end
        end)
    end,debug.traceback)
    pcall(conn.close,conn)
    if not ok then return nil,tostring(err) end
    return true
end


function ThoughtDatabase.save_checkpoint(store, book_id, chapter_uid, snapshot)
    local ok_encoded, payload = pcall(Json.encode, type(snapshot)=="table" and snapshot or {})
    if not ok_encoded then return nil, tostring(payload) end
    local conn=open(store,book_id,false)
    local ok,err=pcall(function()
        local statement=conn:prepare([[
            INSERT OR REPLACE INTO thought_fetch_checkpoint(chapter_uid, payload, updated_at)
            VALUES(?, ?, ?)
        ]])
        statement:bind(chapter_key(chapter_uid), tostring(payload or ""), os.time()):step()
        statement:close()
    end)
    pcall(conn.close,conn)
    if not ok then return nil,tostring(err) end
    return true
end

function ThoughtDatabase.load_checkpoint(store, book_id, chapter_uid)
    if not ThoughtDatabase.exists(store,book_id) then return nil end
    local ok,result=pcall(function()
        local conn=open(store,book_id,true)
        local statement=conn:prepare([[
            SELECT payload FROM thought_fetch_checkpoint WHERE chapter_uid = ? LIMIT 1
        ]])
        local row=statement:bind(chapter_key(chapter_uid)):step()
        statement:close(); conn:close()
        if not row or tostring(row[1] or "")=="" then return nil end
        local decoded_ok,value=pcall(Json.decode,tostring(row[1]))
        return decoded_ok and type(value)=="table" and value or nil
    end)
    return ok and result or nil
end

function ThoughtDatabase.clear_checkpoint(store, book_id, chapter_uid)
    if not ThoughtDatabase.exists(store,book_id) then return true end
    local conn=open(store,book_id,false)
    local ok,err=pcall(function()
        local statement=conn:prepare("DELETE FROM thought_fetch_checkpoint WHERE chapter_uid = ?")
        statement:bind(chapter_key(chapter_uid)):step(); statement:close()
    end)
    pcall(conn.close,conn)
    if not ok then return nil,tostring(err) end
    return true
end

function ThoughtDatabase.cached_chapters(store, book_id)
    if not ThoughtDatabase.exists(store,book_id) then return {} end
    local ok,result=pcall(function()
        local conn=open(store,book_id,false)
        local rows={}
        local statement=conn:prepare([[
            SELECT c.chapter_uid, c.group_count, c.comment_count, c.updated_at,
                   COALESCE(f.status, 'cached'), COALESCE(f.complete, 0),
                   COALESCE(f.fetched_at, 0), COALESCE(f.last_error, '')
              FROM thought_chapters c
              LEFT JOIN thought_fetch_state f ON f.chapter_uid = c.chapter_uid
             ORDER BY c.updated_at DESC, c.chapter_uid
        ]])
        while true do
            local row=statement:step(); if not row then break end
            rows[#rows+1]={
                chapter_uid=tostring(row[1] or ""),groups=tonumber(row[2] or 0) or 0,
                comments=tonumber(row[3] or 0) or 0,updated_at=tonumber(row[4] or 0) or 0,
                status=tostring(row[5] or "cached"),complete=tonumber(row[6] or 0)==1,
                fetched_at=tonumber(row[7] or 0) or 0,last_error=tostring(row[8] or ""),
            }
        end
        statement:close(); conn:close(); return rows
    end)
    return ok and result or {}
end

function ThoughtDatabase.delete_chapters(store, book_id, chapter_uids)
    local ids=type(chapter_uids)=="table" and chapter_uids or {}
    if #ids==0 or not ThoughtDatabase.exists(store,book_id) then return true,0 end
    local conn=open(store,book_id,false)
    local deleted=0
    local ok,err=xpcall(function()
        SQLiteStore.transaction(conn,function()
            local statements={}
            for _,sql in ipairs({
                "DELETE FROM thought_comments WHERE chapter_uid = ?",
                "DELETE FROM thought_groups WHERE chapter_uid = ?",
                "DELETE FROM thought_chapters WHERE chapter_uid = ?",
                "DELETE FROM thought_fetch_state WHERE chapter_uid = ?",
                "DELETE FROM thought_fetch_checkpoint WHERE chapter_uid = ?",
            }) do statements[#statements+1]=conn:prepare(sql) end
            for _,uid in ipairs(ids) do
                local key=chapter_key(uid)
                if key~="" then
                    for _,st in ipairs(statements) do st:bind(key):step(); st:clearbind():reset() end
                    deleted=deleted+1
                end
            end
            for _,st in ipairs(statements) do st:close() end
        end)
    end,debug.traceback)
    pcall(conn.close,conn)
    if not ok then return nil,tostring(err) end
    return true,deleted
end

function ThoughtDatabase.record_migration(store, book_id, source_path, source_signature, chapter_uid, counts)
    local conn = open(store, book_id, false)
    local ok, err = pcall(record_migration_conn, conn, source_path, source_signature, chapter_uid, counts)
    pcall(conn.close, conn)
    if not ok then return nil, tostring(err) end
    return true
end

function ThoughtDatabase.migration_record(store, book_id, source_path)
    if not ThoughtDatabase.exists(store, book_id) then return nil end
    local ok, result = pcall(function()
        local conn = open(store, book_id, true)
        local statement = conn:prepare([[
            SELECT source_signature, chapter_uid, group_count, comment_count, migrated_at
              FROM thought_migration WHERE source_path = ? LIMIT 1
        ]])
        local row = statement:bind(tostring(source_path or "")):step()
        statement:close()
        conn:close()
        if not row then return nil end
        return {
            source_signature=tostring(row[1] or ""), chapter_uid=tostring(row[2] or ""),
            groups=tonumber(row[3] or 0) or 0, comments=tonumber(row[4] or 0) or 0,
            migrated_at=tonumber(row[5] or 0) or 0,
        }
    end)
    return ok and result or nil
end

function ThoughtDatabase.migration_records(store, book_id)
    if not ThoughtDatabase.exists(store, book_id) then return {} end
    local ok, result = pcall(function()
        local conn = open(store, book_id, true)
        local rows = {}
        local statement = conn:prepare([[
            SELECT m.source_path, m.source_signature, m.chapter_uid,
                   m.group_count, m.comment_count, m.migrated_at,
                   COALESCE(g.actual_groups, 0),
                   COALESCE(t.actual_comments, 0),
                   CASE WHEN c.chapter_uid IS NULL THEN 0 ELSE 1 END
              FROM thought_migration m
              LEFT JOIN thought_chapters c ON c.chapter_uid = m.chapter_uid
              LEFT JOIN (
                    SELECT chapter_uid, COUNT(*) AS actual_groups
                      FROM thought_groups GROUP BY chapter_uid
              ) g ON g.chapter_uid = m.chapter_uid
              LEFT JOIN (
                    SELECT chapter_uid, COUNT(*) AS actual_comments
                      FROM thought_comments GROUP BY chapter_uid
              ) t ON t.chapter_uid = m.chapter_uid
        ]])
        while true do
            local row = statement:step()
            if not row then break end
            rows[tostring(row[1] or "")] = {
                source_signature=tostring(row[2] or ""), chapter_uid=tostring(row[3] or ""),
                groups=tonumber(row[4] or 0) or 0, comments=tonumber(row[5] or 0) or 0,
                migrated_at=tonumber(row[6] or 0) or 0,
                actual_groups=row[7]~=nil and (tonumber(row[7]) or 0) or nil,
                actual_comments=row[8]~=nil and (tonumber(row[8]) or 0) or nil,
                chapter_present=tonumber(row[9] or 0)==1,
            }
        end
        statement:close()
        conn:close()
        return rows
    end)
    return ok and result or {}
end

function ThoughtDatabase.integrity(store, book_id)
    local path = database_path(store, book_id)
    local healthy = SQLiteStore.integrity_check(path)
    if healthy ~= true then return false end
    local ok, result = pcall(function()
        return SQLiteStore.with_connection(path, true, function(conn)
            local required = {
                thought_chapters=false, thought_groups=false,
                thought_comments=false, thought_migration=false, kv=false,
            }
            local statement = conn:prepare([[
                SELECT name FROM sqlite_master
                 WHERE type = 'table' AND name IN (
                    'thought_chapters','thought_groups','thought_comments','thought_migration','kv'
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

function ThoughtDatabase.remove(store, book_id)
    local path = database_path(store, book_id)
    os.remove(path)
    os.remove(path .. "-wal")
    os.remove(path .. "-shm")
    return true
end

return ThoughtDatabase
