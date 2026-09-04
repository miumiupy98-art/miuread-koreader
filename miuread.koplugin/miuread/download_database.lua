local SQLiteStore = require("miuread.sqlite_store")
local U = require("miuread.util")
local lfs = require("libs/libkoreader-lfs")

local DownloadDatabase = {}

DownloadDatabase.PARTIAL_FILE = "download.sqlite3"
DownloadDatabase.RUNTIME_FILE = "download-runtime.sqlite3"

local function partial_path(root)
    return tostring(root or "") .. "/" .. DownloadDatabase.PARTIAL_FILE
end

local function runtime_path(value)
    if type(value) == "table" then
        return tostring(value.data_dir or "") .. "/" .. DownloadDatabase.RUNTIME_FILE
    end
    return tostring(value or "") .. "/" .. DownloadDatabase.RUNTIME_FILE
end

local function safe_id(value)
    return U.id_name(tostring(value or ""))
end

local function task_key(token, field)
    return "task:" .. safe_id(token) .. ":" .. tostring(field or "")
end

function DownloadDatabase.partial_path(root) return partial_path(root) end
function DownloadDatabase.runtime_path(value) return runtime_path(value) end

function DownloadDatabase.partial_exists(root)
    return lfs.attributes(partial_path(root), "mode") == "file"
end

function DownloadDatabase.load_manifest(root)
    return SQLiteStore.get_json_path(partial_path(root), "manifest", nil, true)
end

function DownloadDatabase.save_manifest(root, manifest)
    return SQLiteStore.set_json_path(partial_path(root), "manifest", manifest)
end

function DownloadDatabase.save_assets(root, chapter_uid, assets)
    return SQLiteStore.set_json_path(partial_path(root), "assets:" .. safe_id(chapter_uid), assets or {})
end

function DownloadDatabase.load_assets(root, chapter_uid)
    return SQLiteStore.get_json_path(partial_path(root), "assets:" .. safe_id(chapter_uid), nil, true)
end

function DownloadDatabase.delete_assets(root, chapter_uid)
    return SQLiteStore.delete_path(partial_path(root), "assets:" .. safe_id(chapter_uid))
end

function DownloadDatabase.save_annotation(root, chapter_uid, account_key, snapshot)
    local key = "annotation:" .. safe_id(chapter_uid) .. ":" .. safe_id(account_key)
    return SQLiteStore.set_json_path(partial_path(root), key, snapshot)
end

function DownloadDatabase.load_annotation(root, chapter_uid, account_key)
    local key = "annotation:" .. safe_id(chapter_uid) .. ":" .. safe_id(account_key)
    return SQLiteStore.get_json_path(partial_path(root), key, nil, true)
end

function DownloadDatabase.delete_annotation(root, chapter_uid, account_key)
    local key = "annotation:" .. safe_id(chapter_uid) .. ":" .. safe_id(account_key)
    return SQLiteStore.delete_path(partial_path(root), key)
end

function DownloadDatabase.set_download_state(store, value)
    return SQLiteStore.set_json_path(runtime_path(store), "download_state", value or {})
end

function DownloadDatabase.get_download_state(store)
    return SQLiteStore.get_json_path(runtime_path(store), "download_state", {}, true)
end

function DownloadDatabase.clear_download_state(store)
    return SQLiteStore.delete_path(runtime_path(store), "download_state")
end

function DownloadDatabase.set_download_queue(store, value)
    return SQLiteStore.set_json_path(runtime_path(store), "download_queue", value or {})
end

function DownloadDatabase.get_download_queue(store)
    return SQLiteStore.get_json_path(runtime_path(store), "download_queue", {}, true)
end

function DownloadDatabase.set_task_value(path, token, field, value)
    return SQLiteStore.set_json_path(path, task_key(token, field), value)
end

function DownloadDatabase.get_task_value(path, token, field, default)
    return SQLiteStore.get_json_path(path, task_key(token, field), default, true)
end

function DownloadDatabase.delete_task_value(path, token, field)
    return SQLiteStore.delete_path(path, task_key(token, field))
end

function DownloadDatabase.set_owner(path, value)
    return SQLiteStore.set_json_path(path, "task_owner", value or {})
end

function DownloadDatabase.get_owner(path)
    return SQLiteStore.get_json_path(path, "task_owner", nil, true)
end

function DownloadDatabase.clear_owner(path)
    return SQLiteStore.delete_path(path, "task_owner")
end

function DownloadDatabase.set_pause(path, token, reasons)
    local ordered = {}
    for reason, enabled in pairs(reasons or {}) do
        if enabled == true and tostring(reason or "") ~= "" then ordered[#ordered + 1] = tostring(reason) end
    end
    table.sort(ordered)
    if #ordered == 0 then return DownloadDatabase.delete_task_value(path, token, "pause") end
    return DownloadDatabase.set_task_value(path, token, "pause", {
        paused=true, reasons=ordered, updated_at=os.time(),
    })
end

function DownloadDatabase.get_pause(path, token)
    return DownloadDatabase.get_task_value(path, token, "pause", nil)
end

function DownloadDatabase.remove_partial(root)
    local path = partial_path(root)
    os.remove(path); os.remove(path .. "-wal"); os.remove(path .. "-shm")
end

local function account_hash(value)
    local hash=5381
    value=tostring(value or "")
    for index=1,#value do hash=(hash*33+value:byte(index))%2147483647 end
    return string.format("a%08x",hash)
end

function DownloadDatabase.account_key(store)
    local auth=store and store:auth() or {}
    local account=type(auth.account)=="table" and auth.account or {}
    local vid=tostring(account.vid or "")
    return vid~="" and account_hash(vid) or "anonymous"
end

function DownloadDatabase.load_annotation_data(root, chapter_uid, account_key, annotations)
    local value = DownloadDatabase.load_annotation(root, chapter_uid, account_key)
    if type(value) ~= "table" or tostring(value.account_key or "") ~= tostring(account_key) then return nil end
    local restored = annotations:from_cache(value)
    if type(restored) == "table" then restored.saved_at = tonumber(value.saved_at or 0) or 0 end
    return restored
end

function DownloadDatabase.save_annotation_data(root, chapter_uid, account_key, annotations, data)
    local snapshot=annotations:to_cache(data)
    snapshot.account_key=tostring(account_key)
    snapshot.saved_at=os.time()
    return DownloadDatabase.save_annotation(root, chapter_uid, account_key, snapshot)
end

return DownloadDatabase
