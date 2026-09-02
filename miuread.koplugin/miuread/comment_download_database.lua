local SQLiteStore=require("miuread.sqlite_store")
local U=require("miuread.util")

local DB={}
DB.FILE_NAME="comment-download.sqlite3"
DB.RUNTIME_FILE="comment-download-runtime.sqlite3"

local function safe(value) return U.id_name(tostring(value or "")) end
local function book_path(store,book_id)
    return store:book_dir(tostring(book_id or "")).."/"..DB.FILE_NAME
end
local function runtime_path(store)
    return tostring(store and store.data_dir or "").."/"..DB.RUNTIME_FILE
end
local function state_key(uid) return "state:"..safe(uid) end
local function checkpoint_key(uid,account_key) return "checkpoint:"..safe(uid)..":"..safe(account_key) end
local function job_key(book_id) return "job:"..safe(book_id) end

function DB.path(store,book_id) return book_path(store,book_id) end
function DB.runtime_path(store) return runtime_path(store) end

function DB.state(store,book_id,uid)
    return SQLiteStore.get_json_path(book_path(store,book_id),state_key(uid),nil,true)
end
function DB.save_state(store,book_id,uid,patch)
    local path=book_path(store,book_id)
    local current=SQLiteStore.get_json_path(path,state_key(uid),{},true)
    current=U.merge(type(current)=="table" and current or {},type(patch)=="table" and patch or {})
    current.chapter_uid=tostring(uid or current.chapter_uid or "")
    current.book_id=tostring(book_id or current.book_id or "")
    current.updated_at=tonumber(current.updated_at) or os.time()
    return SQLiteStore.set_json_path(path,state_key(uid),current)
end
function DB.states(store,book_id,chapters)
    local out={}
    local path=book_path(store,book_id)
    if not U.file_exists(path) then return out end
    local ok=pcall(SQLiteStore.with_connection,path,true,function(conn)
        for _,chapter in ipairs(type(chapters)=="table" and chapters or {}) do
            local uid=tostring(type(chapter)=="table" and (chapter.uid or chapter.chapterUid or chapter.chapter_uid) or "")
            if uid~="" then
                local row=SQLiteStore.get_json(conn,state_key(uid),nil)
                if type(row)=="table" then out[uid]=row end
            end
        end
    end)
    if not ok then return {} end
    return out
end
function DB.clear_state(store,book_id,uid)
    return SQLiteStore.delete_path(book_path(store,book_id),state_key(uid))
end
function DB.clear_states(store,book_id,chapters)
    for _,chapter in ipairs(type(chapters)=="table" and chapters or {}) do
        local uid=tostring(type(chapter)=="table" and (chapter.uid or chapter.chapterUid or chapter.chapter_uid) or "")
        if uid~="" then DB.clear_state(store,book_id,uid) end
    end
    return true
end

function DB.load_checkpoint(store,book_id,uid,account_key,annotations)
    local value=SQLiteStore.get_json_path(book_path(store,book_id),checkpoint_key(uid,account_key),nil,true)
    if type(value)~="table" or tostring(value.account_key or "")~=tostring(account_key or "") then return nil end
    local restored=annotations:from_cache(value)
    if type(restored)=="table" then restored.saved_at=tonumber(value.saved_at or 0) or 0 end
    return restored
end
function DB.save_checkpoint(store,book_id,uid,account_key,annotations,data)
    local snapshot=annotations:to_cache(type(data)=="table" and data or {})
    snapshot.account_key=tostring(account_key or "")
    snapshot.saved_at=tonumber(data and data.saved_at) or os.time()
    return SQLiteStore.set_json_path(book_path(store,book_id),checkpoint_key(uid,account_key),snapshot)
end
function DB.delete_checkpoint(store,book_id,uid,account_key)
    return SQLiteStore.delete_path(book_path(store,book_id),checkpoint_key(uid,account_key))
end

function DB.job(store,book_id)
    return SQLiteStore.get_json_path(runtime_path(store),job_key(book_id),nil,true)
end
function DB.save_job(store,book_id,patch)
    local path=runtime_path(store)
    local current=SQLiteStore.get_json_path(path,job_key(book_id),{},true)
    current=U.merge(type(current)=="table" and current or {},type(patch)=="table" and patch or {})
    current.book_id=tostring(book_id or current.book_id or "")
    current.updated_at=tonumber(current.updated_at) or os.time()
    return SQLiteStore.set_json_path(path,job_key(book_id),current)
end
function DB.clear_job(store,book_id)
    return SQLiteStore.delete_path(runtime_path(store),job_key(book_id))
end
function DB.queue(store)
    local value=SQLiteStore.get_json_path(runtime_path(store),"queue",{},true)
    return type(value)=="table" and value or {}
end
function DB.save_queue(store,queue)
    return SQLiteStore.set_json_path(runtime_path(store),"queue",type(queue)=="table" and queue or {})
end

function DB.reset_book(store,book_id,chapters)
    -- The independent database belongs only to downloaded public comments.
    -- Reset the whole per-book file so account-scoped checkpoints cannot make
    -- a user-requested reset silently reuse old fetch state. Thoughts data is
    -- stored elsewhere and is deliberately untouched.
    local path=book_path(store,book_id)
    pcall(os.remove,path)
    pcall(os.remove,path.."-wal")
    pcall(os.remove,path.."-shm")
    DB.clear_job(store,book_id)
    return true
end

return DB
