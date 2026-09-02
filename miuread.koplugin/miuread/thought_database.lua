local SQLiteStore = require("miuread.sqlite_store")
local U = require("miuread.util")
local lfs = require("libs/libkoreader-lfs")

local ThoughtDatabase = {}

ThoughtDatabase.SCHEMA_VERSION = 3
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
        CREATE TABLE IF NOT EXISTS thought_migration (
            source_path TEXT PRIMARY KEY,
            source_signature TEXT NOT NULL,
            chapter_uid TEXT NOT NULL,
            group_count INTEGER NOT NULL DEFAULT 0,
            comment_count INTEGER NOT NULL DEFAULT 0,
            migrated_at INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS thought_fetch_state (
            chapter_uid TEXT PRIMARY KEY,
            status TEXT NOT NULL DEFAULT 'never',
            account_key TEXT NOT NULL DEFAULT '',
            book_version INTEGER NOT NULL DEFAULT 0,
            range_count INTEGER NOT NULL DEFAULT 0,
            group_count INTEGER NOT NULL DEFAULT 0,
            comment_count INTEGER NOT NULL DEFAULT 0,
            pending_count INTEGER NOT NULL DEFAULT 0,
            source_ready INTEGER NOT NULL DEFAULT 0,
            started_at INTEGER NOT NULL DEFAULT 0,
            fetched_at INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0,
            last_error TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS thought_fetch_job (
            job_key TEXT PRIMARY KEY,
            status TEXT NOT NULL DEFAULT 'idle',
            title TEXT NOT NULL DEFAULT '',
            mode TEXT NOT NULL DEFAULT '',
            total INTEGER NOT NULL DEFAULT 0,
            processed INTEGER NOT NULL DEFAULT 0,
            complete_count INTEGER NOT NULL DEFAULT 0,
            empty_count INTEGER NOT NULL DEFAULT 0,
            partial_count INTEGER NOT NULL DEFAULT 0,
            failed_count INTEGER NOT NULL DEFAULT 0,
            suspicious_count INTEGER NOT NULL DEFAULT 0,
            started_at INTEGER NOT NULL DEFAULT 0,
            completed_at INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0,
            last_error TEXT NOT NULL DEFAULT ''
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


function ThoughtDatabase.save_fetch_state(store, book_id, chapter_uid, patch)
    patch=type(patch)=="table" and patch or {}
    local conn=open(store,book_id,false)
    local ok,result=xpcall(function()
        return SQLiteStore.transaction(conn,function()
            local key=chapter_key(chapter_uid)
            if key=="" then error("章节标识为空") end
            local existing_statement=conn:prepare([[
                SELECT status, account_key, book_version, range_count, group_count, comment_count,
                       pending_count, source_ready, started_at, fetched_at, updated_at, last_error
                  FROM thought_fetch_state WHERE chapter_uid = ? LIMIT 1
            ]])
            local row=existing_statement:bind(key):step()
            existing_statement:close()
            local current={
                status=tostring(row and row[1] or "never"),account_key=tostring(row and row[2] or ""),
                book_version=tonumber(row and row[3] or 0) or 0,range_count=tonumber(row and row[4] or 0) or 0,
                group_count=tonumber(row and row[5] or 0) or 0,comment_count=tonumber(row and row[6] or 0) or 0,
                pending_count=tonumber(row and row[7] or 0) or 0,source_ready=tonumber(row and row[8] or 0)==1,
                started_at=tonumber(row and row[9] or 0) or 0,fetched_at=tonumber(row and row[10] or 0) or 0,
                updated_at=tonumber(row and row[11] or 0) or 0,last_error=tostring(row and row[12] or ""),
            }
            for k,v in pairs(patch) do if v~=nil then current[k]=v end end
            current.updated_at=tonumber(current.updated_at) or os.time()
            local statement=conn:prepare([[
                INSERT OR REPLACE INTO thought_fetch_state(
                    chapter_uid,status,account_key,book_version,range_count,group_count,comment_count,
                    pending_count,source_ready,started_at,fetched_at,updated_at,last_error
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            ]])
            statement:bind(key,tostring(current.status or "never"),tostring(current.account_key or ""),
                tonumber(current.book_version) or 0,tonumber(current.range_count) or 0,
                tonumber(current.group_count) or 0,tonumber(current.comment_count) or 0,
                tonumber(current.pending_count) or 0,current.source_ready==true and 1 or 0,
                tonumber(current.started_at) or 0,tonumber(current.fetched_at) or 0,
                tonumber(current.updated_at) or os.time(),tostring(current.last_error or "")):step()
            statement:close()
            return current
        end)
    end,debug.traceback)
    pcall(conn.close,conn)
    if not ok then return nil,tostring(result) end
    return result
end

function ThoughtDatabase.fetch_state(store, book_id, chapter_uid)
    if not ThoughtDatabase.exists(store,book_id) then return nil end
    local conn=open(store,book_id,true)
    local ok,result=xpcall(function()
        local statement=conn:prepare([[
            SELECT status, account_key, book_version, range_count, group_count, comment_count,
                   pending_count, source_ready, started_at, fetched_at, updated_at, last_error
              FROM thought_fetch_state WHERE chapter_uid = ? LIMIT 1
        ]])
        local row=statement:bind(chapter_key(chapter_uid)):step()
        statement:close()
        if not row then return nil end
        return {
            status=tostring(row[1] or "never"),account_key=tostring(row[2] or ""),
            book_version=tonumber(row[3] or 0) or 0,range_count=tonumber(row[4] or 0) or 0,
            group_count=tonumber(row[5] or 0) or 0,comment_count=tonumber(row[6] or 0) or 0,
            pending_count=tonumber(row[7] or 0) or 0,source_ready=tonumber(row[8] or 0)==1,
            started_at=tonumber(row[9] or 0) or 0,fetched_at=tonumber(row[10] or 0) or 0,
            updated_at=tonumber(row[11] or 0) or 0,last_error=tostring(row[12] or ""),
        }
    end,debug.traceback)
    pcall(conn.close,conn)
    return ok and result or nil
end

function ThoughtDatabase.fetch_states(store, book_id)
    if not ThoughtDatabase.exists(store,book_id) then return {} end
    local conn=open(store,book_id,true)
    local ok,result=xpcall(function()
        local rows={}
        local statement=conn:prepare([[
            SELECT chapter_uid,status,account_key,book_version,range_count,group_count,comment_count,
                   pending_count,source_ready,started_at,fetched_at,updated_at,last_error
              FROM thought_fetch_state
        ]])
        while true do
            local row=statement:step()
            if not row then break end
            rows[tostring(row[1] or "")]={
                status=tostring(row[2] or "never"),account_key=tostring(row[3] or ""),
                book_version=tonumber(row[4] or 0) or 0,range_count=tonumber(row[5] or 0) or 0,
                group_count=tonumber(row[6] or 0) or 0,comment_count=tonumber(row[7] or 0) or 0,
                pending_count=tonumber(row[8] or 0) or 0,source_ready=tonumber(row[9] or 0)==1,
                started_at=tonumber(row[10] or 0) or 0,fetched_at=tonumber(row[11] or 0) or 0,
                updated_at=tonumber(row[12] or 0) or 0,last_error=tostring(row[13] or ""),
            }
        end
        statement:close()
        return rows
    end,debug.traceback)
    pcall(conn.close,conn)
    return ok and result or {}
end

function ThoughtDatabase.clear_fetch_state(store, book_id, chapter_uid)
    if not ThoughtDatabase.exists(store,book_id) then return true end
    local conn=open(store,book_id,false)
    local ok,err=pcall(function()
        if chapter_uid~=nil then
            local statement=conn:prepare("DELETE FROM thought_fetch_state WHERE chapter_uid = ?")
            statement:bind(chapter_key(chapter_uid)):step(); statement:close()
        else
            conn:exec("DELETE FROM thought_fetch_state; DELETE FROM thought_fetch_job;")
        end
    end)
    pcall(conn.close,conn)
    return ok or nil,ok and nil or tostring(err)
end

function ThoughtDatabase.save_job_state(store, book_id, patch)
    patch=type(patch)=="table" and patch or {}
    local conn=open(store,book_id,false)
    local ok,result=xpcall(function()
        return SQLiteStore.transaction(conn,function()
            local statement=conn:prepare([[
                SELECT status,title,mode,total,processed,complete_count,empty_count,partial_count,
                       failed_count,suspicious_count,started_at,completed_at,updated_at,last_error
                  FROM thought_fetch_job WHERE job_key='book' LIMIT 1
            ]])
            local row=statement:step(); statement:close()
            local current={
                status=tostring(row and row[1] or "idle"),title=tostring(row and row[2] or ""),
                mode=tostring(row and row[3] or ""),total=tonumber(row and row[4] or 0) or 0,
                processed=tonumber(row and row[5] or 0) or 0,complete_count=tonumber(row and row[6] or 0) or 0,
                empty_count=tonumber(row and row[7] or 0) or 0,partial_count=tonumber(row and row[8] or 0) or 0,
                failed_count=tonumber(row and row[9] or 0) or 0,suspicious_count=tonumber(row and row[10] or 0) or 0,
                started_at=tonumber(row and row[11] or 0) or 0,completed_at=tonumber(row and row[12] or 0) or 0,
                updated_at=tonumber(row and row[13] or 0) or 0,last_error=tostring(row and row[14] or ""),
            }
            for k,v in pairs(patch) do if v~=nil then current[k]=v end end
            if patch.complete~=nil then current.complete_count=patch.complete end
            if patch.empty~=nil then current.empty_count=patch.empty end
            if patch.partial~=nil then current.partial_count=patch.partial end
            if patch.failed~=nil then current.failed_count=patch.failed end
            if patch.suspicious~=nil then current.suspicious_count=patch.suspicious end
            current.updated_at=tonumber(current.updated_at) or os.time()
            local write=conn:prepare([[
                INSERT OR REPLACE INTO thought_fetch_job(
                    job_key,status,title,mode,total,processed,complete_count,empty_count,partial_count,
                    failed_count,suspicious_count,started_at,completed_at,updated_at,last_error
                ) VALUES('book',?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ]])
            write:bind(tostring(current.status or "idle"),tostring(current.title or ""),tostring(current.mode or ""),
                tonumber(current.total) or 0,tonumber(current.processed) or 0,tonumber(current.complete_count) or 0,
                tonumber(current.empty_count) or 0,tonumber(current.partial_count) or 0,tonumber(current.failed_count) or 0,
                tonumber(current.suspicious_count) or 0,tonumber(current.started_at) or 0,tonumber(current.completed_at) or 0,
                tonumber(current.updated_at) or os.time(),tostring(current.last_error or "")):step()
            write:close()
            return current
        end)
    end,debug.traceback)
    pcall(conn.close,conn)
    if not ok then return nil,tostring(result) end
    return result
end

function ThoughtDatabase.job_state(store, book_id)
    if not ThoughtDatabase.exists(store,book_id) then return nil end
    local conn=open(store,book_id,true)
    local ok,result=xpcall(function()
        local statement=conn:prepare([[
            SELECT status,title,mode,total,processed,complete_count,empty_count,partial_count,
                   failed_count,suspicious_count,started_at,completed_at,updated_at,last_error
              FROM thought_fetch_job WHERE job_key='book' LIMIT 1
        ]])
        local row=statement:step(); statement:close()
        if not row then return nil end
        return {
            status=tostring(row[1] or "idle"),title=tostring(row[2] or ""),mode=tostring(row[3] or ""),
            total=tonumber(row[4] or 0) or 0,processed=tonumber(row[5] or 0) or 0,
            complete=tonumber(row[6] or 0) or 0,empty=tonumber(row[7] or 0) or 0,
            partial=tonumber(row[8] or 0) or 0,failed=tonumber(row[9] or 0) or 0,
            suspicious=tonumber(row[10] or 0) or 0,started_at=tonumber(row[11] or 0) or 0,
            completed_at=tonumber(row[12] or 0) or 0,updated_at=tonumber(row[13] or 0) or 0,last_error=tostring(row[14] or ""),
        }
    end,debug.traceback)
    pcall(conn.close,conn)
    return ok and result or nil
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
end

return ThoughtDatabase
