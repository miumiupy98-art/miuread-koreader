local FFIUtil = require("ffi/util")
local Json = require("miuread.json")
local U = require("miuread.util")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local SubprocessHygiene = require("miuread.subprocess_hygiene")

local CacheCleanupTask = {}
CacheCleanupTask.__index = CacheCleanupTask

local function normalize_path(path)
    local value = tostring(path or ""):gsub("\\", "/"):gsub("/+", "/")
    if #value > 1 then value = value:gsub("/$", "") end
    return value
end

local function basename(path)
    return normalize_path(path):match("([^/]+)$") or ""
end

local function under_parent(path, parent)
    path, parent = normalize_path(path), normalize_path(parent)
    return path == parent or path:sub(1, #parent + 1) == parent .. "/"
end

local function direct_child(path, parent)
    path, parent = normalize_path(path), normalize_path(parent)
    if parent == "" or path:sub(1, #parent + 1) ~= parent .. "/" then return false end
    return not path:sub(#parent + 2):find("/", 1, true)
end

local function parent_dir(path)
    return normalize_path(path):match("^(.*)/[^/]+$") or ""
end

local function process_alive(pid)
    pid = tonumber(pid)
    if not pid or pid <= 1 or lfs.attributes("/proc", "mode") ~= "directory" then return nil end
    local root = "/proc/" .. tostring(pid)
    if lfs.attributes(root, "mode") ~= "directory" then return false end
    local status = U.read_file(root .. "/status", true) or ""
    local state = status:match("[\r\n]State:%s*([A-Z])") or status:match("^State:%s*([A-Z])")
    if state == "Z" or state == "X" then return false end
    return true
end

local function clean_paths(paths)
    local rows, seen = {}, {}
    for _, path in ipairs(paths or {}) do
        path = normalize_path(path)
        if path ~= "" and not seen[path] then
            seen[path] = true
            rows[#rows + 1] = path
        end
    end
    table.sort(rows, function(a, b)
        if #a ~= #b then return #a < #b end
        return a < b
    end)
    local out = {}
    for _, path in ipairs(rows) do
        local nested = false
        for _, parent in ipairs(out) do
            if under_parent(path, parent) then nested = true; break end
        end
        if not nested then out[#out + 1] = path end
    end
    return out
end

local function path_size(path)
    local attr = lfs.attributes(path)
    if not attr then return 0 end
    if attr.mode == "file" then return tonumber(attr.size) or 0 end
    if attr.mode ~= "directory" then return 0 end
    local total = 0
    local ok, iter, state = pcall(lfs.dir, path)
    if not ok or type(iter) ~= "function" then return 0 end
    for name in iter, state do
        if name ~= "." and name ~= ".." then total = total + path_size(path .. "/" .. name) end
    end
    return total
end

local function is_download_temp_name(name)
    name = tostring(name or "")
    return name == "download-task-owner.json"
        or name:match("^download%-settings%-.+%.lua$") ~= nil
        or name:match("^download%-diagnostic%-.+%.txt$") ~= nil
        or name:match("^download%-progress%-.+%.json$") ~= nil
        or name:match("^download%-result%-.+%.json$") ~= nil
        or name:match("^download%-recovery%-.+%.json$") ~= nil
        or name:match("^download%-pause%-.+%.json$") ~= nil
        or name:match("^download%-cancel%-.+") ~= nil
        or name:match("^extension%-.+%.zip$") ~= nil
        or name:match("^extension%-json%-.+%.json$") ~= nil
        or name:match("^extension%-stage%-.+") ~= nil
end

local function validate_delete_path(path, policy)
    policy = type(policy) == "table" and policy or {}
    local mode = tostring(policy.mode or "")
    local data_dir = normalize_path(policy.data_dir)
    local cache_books_dir = normalize_path(policy.cache_books_dir)
    local books_root = normalize_path(policy.books_root)
    local covers_dir = normalize_path(policy.covers_dir)
    local temp_dir = normalize_path(policy.temp_dir)
    path = normalize_path(path)

    if path == "" or path == "/" or path == data_dir or path == cache_books_dir
        or path == books_root or path == temp_dir then
        if mode == "cover_cache" and path == covers_dir then return true end
        return false, "拒绝删除受保护的根目录"
    end

    if mode == "download_residue" then
        local name = basename(path)
        if direct_child(path, temp_dir) and is_download_temp_name(name) then return true end
        if direct_child(parent_dir(path), cache_books_dir)
            and name:match("^%.miuread%-partial%-") then return true end
        if direct_child(path, books_root)
            and (name:match("%.miuread%-new%-%d+%-%d+$")
                or name:match("%.miuread%-backup$")
                or name:match("%.miuread%-linkfix$")
                or name:match("%.miuread%-linkbak$")) then
            return true
        end
        return false, "不在临时文件残留白名单中"
    end

    if mode == "cover_cache" then
        if path == covers_dir then return true end
        return false, "只允许清理封面缓存目录"
    end

    if mode == "variant_delete" or mode == "chapter_delete" then
        if direct_child(path, books_root) and path:lower():match("%.epub$") then return true end
        return false, "只允许删除明确选择的 EPUB"
    end

    if mode == "book_delete" then
        local allowed = type(policy.allowed_paths) == "table" and policy.allowed_paths or {}
        for _, exact_path in ipairs(allowed) do
            if path == normalize_path(exact_path) then return true end
        end
        return false, "不在当前书籍完整删除白名单中"
    end

    return false, "清理策略缺失"
end

function CacheCleanupTask:new(store)
    return setmetatable({store = store, job = nil, poll_task = nil}, self)
end

function CacheCleanupTask:available()
    return type(FFIUtil.runInSubProcess) == "function"
        and type(FFIUtil.isSubProcessDone) == "function"
end

function CacheCleanupTask:busy()
    return self.job ~= nil
end

function CacheCleanupTask:_schedule()
    if self.poll_task then return end
    local task
    task = function()
        if self.poll_task ~= task then return end
        self.poll_task = nil
        self:_poll()
    end
    self.poll_task = task
    UIManager:scheduleIn(0.20, task)
end

function CacheCleanupTask:_finish(job, forced_error)
    local raw = U.read_file(job.result_path, true)
    local result
    if forced_error then
        result = {ok = false, error = forced_error, removed = 0, missing = 0, freed_bytes = 0}
    elseif not raw then
        result = {ok = false, error = "后台任务异常退出", removed = 0, missing = 0, freed_bytes = 0}
    else
        local ok, decoded = pcall(Json.decode, raw)
        result = ok and decoded or {ok = false, error = "后台任务结果无法解析", removed = 0, missing = 0, freed_bytes = 0}
    end
    if job.kind == "cleanup" then
        pcall(function()
            result.finished_at = result.finished_at or os.time()
            result.operation = result.operation or tostring(job.operation or "后台清理")
            self.store:save_cleanup_result(result)
        end)
    end
    os.remove(job.result_path)
    self.job = nil
    if job.on_done then
        local ok, err = xpcall(function() job.on_done(result) end, debug.traceback)
        if not ok then logger.err("[MiuRead][CacheCleanup] completion callback failed", tostring(err)) end
    end
end

function CacheCleanupTask:_poll()
    local job = self.job
    if not job then return end
    if os.time() - job.started_at > job.timeout then
        pcall(FFIUtil.terminateSubProcess, job.pid)
        self:_finish(job, "后台任务超时")
        return
    end
    if U.file_exists(job.result_path) then self:_finish(job); return end
    local alive = process_alive(job.pid)
    local ok, done = pcall(FFIUtil.isSubProcessDone, job.pid, false)
    if not ok then
        logger.warn("[MiuRead][CacheCleanup] poll failed", tostring(done))
        if alive ~= false then self:_schedule(); return end
    end
    if alive == true or (alive == nil and ok and done == false) then
        job.dead_seen_at = nil
        self:_schedule()
        return
    end
    job.dead_seen_at = job.dead_seen_at or os.time()
    if os.time() - job.dead_seen_at < 2 then self:_schedule(); return end
    self:_finish(job)
end

function CacheCleanupTask:_result_path(prefix)
    local stamp = tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))
    return self.store.temp_dir .. "/" .. tostring(prefix or "cache-task") .. "-" .. stamp .. ".json"
end

function CacheCleanupTask:start(paths, on_done, policy)
    if self.job then return false, "已有缓存任务正在运行" end
    if not self:available() then return false, "当前 KOReader 不支持后台清理" end
    paths = clean_paths(paths)
    if #paths == 0 then
        if on_done then on_done({ok = true, removed = 0, missing = 0, freed_bytes = 0, errors = {}}) end
        return true
    end

    policy = type(policy) == "table" and policy or {}
    policy.data_dir = policy.data_dir or self.store.data_dir
    policy.cache_books_dir = policy.cache_books_dir or self.store.cache_books_dir
    policy.books_root = policy.books_root or self.store:books_root()
    policy.covers_dir = policy.covers_dir or self.store.covers_dir
    policy.temp_dir = policy.temp_dir or self.store.temp_dir

    local rejected = {}
    for _, path in ipairs(paths) do
        local ok, reason = validate_delete_path(path, policy)
        if not ok then rejected[#rejected + 1] = tostring(path) .. "：" .. tostring(reason or "拒绝删除") end
    end
    if #rejected > 0 then
        if on_done then on_done({ok = false, removed = 0, missing = 0, freed_bytes = 0,
            errors = rejected, error = table.concat(rejected, "\n")}) end
        return true
    end

    local result_path = self:_result_path("cache-cleanup")
    local child_paths = U.copy(paths)
    local child_policy = U.copy(policy)
    local child = function()
        SubprocessHygiene.close_inherited_sockets()
        local JsonChild = require("miuread.json")
        local UChild = require("miuread.util")
        local lfsChild = require("libs/libkoreader-lfs")
        local errors = {}
        local removed, missing, freed_bytes = 0, 0, 0

        local function child_size(path)
            local attr = lfsChild.attributes(path)
            if not attr then return 0 end
            if attr.mode == "file" then return tonumber(attr.size) or 0 end
            if attr.mode ~= "directory" then return 0 end
            local total = 0
            local ok, iter, state = pcall(lfsChild.dir, path)
            if not ok or type(iter) ~= "function" then return 0 end
            for name in iter, state do
                if name ~= "." and name ~= ".." then total = total + child_size(path .. "/" .. name) end
            end
            return total
        end

        for _, path in ipairs(child_paths) do
            local allowed, reason = validate_delete_path(path, child_policy)
            if not allowed then
                errors[#errors + 1] = tostring(path) .. "：" .. tostring(reason or "拒绝删除")
            else
                local existed = lfsChild.attributes(path) ~= nil
                local before = existed and child_size(path) or 0
                local ok, err = UChild.remove_tree(path)
                if ok then
                    if existed then removed = removed + 1; freed_bytes = freed_bytes + before
                    else missing = missing + 1 end
                else
                    errors[#errors + 1] = tostring(path) .. "：" .. tostring(err or "删除失败")
                end
            end
        end
        local payload = {
            ok = #errors == 0, removed = removed, missing = missing,
            freed_bytes = freed_bytes, errors = errors,
            error = #errors > 0 and table.concat(errors, "\n") or nil,
        }
        UChild.atomic_write(result_path, JsonChild.encode(payload), true)
    end

    local ok, pid, err = pcall(FFIUtil.runInSubProcess, child, false, false)
    if not ok or not pid then return false, tostring(err or pid or "无法启动缓存清理") end
    self.job = {pid = pid, result_path = result_path, on_done = on_done, started_at = os.time(), timeout = 300, dead_seen_at = nil, kind = "cleanup", operation = tostring(policy.mode or "cleanup")}
    self:_schedule()
    return true
end

function CacheCleanupTask:start_scan(categories, on_done)
    if self.job then return false, "已有缓存任务正在运行" end
    if not self:available() then return false, "当前 KOReader 不支持后台统计" end
    local clean = {}
    for key, paths in pairs(type(categories) == "table" and categories or {}) do
        clean[tostring(key)] = clean_paths(paths)
    end
    local result_path = self:_result_path("storage-scan")
    local child_categories = U.copy(clean)
    local child = function()
        SubprocessHygiene.close_inherited_sockets()
        local JsonChild = require("miuread.json")
        local UChild = require("miuread.util")
        local lfsChild = require("libs/libkoreader-lfs")
        local function child_size(path)
            local attr = lfsChild.attributes(path)
            if not attr then return 0 end
            if attr.mode == "file" then return tonumber(attr.size) or 0 end
            if attr.mode ~= "directory" then return 0 end
            local total = 0
            local ok, iter, state = pcall(lfsChild.dir, path)
            if not ok or type(iter) ~= "function" then return 0 end
            for name in iter, state do
                if name ~= "." and name ~= ".." then total = total + child_size(path .. "/" .. name) end
            end
            return total
        end
        local sizes = {}
        for key, paths in pairs(child_categories) do
            local total = 0
            for _, path in ipairs(paths) do total = total + child_size(path) end
            sizes[key] = total
        end
        UChild.atomic_write(result_path, JsonChild.encode({ok = true, sizes = sizes}), true)
    end
    local ok, pid, err = pcall(FFIUtil.runInSubProcess, child, false, false)
    if not ok or not pid then return false, tostring(err or pid or "无法启动存储统计") end
    self.job = {pid = pid, result_path = result_path, on_done = on_done, started_at = os.time(), timeout = 300, dead_seen_at = nil, kind = "scan"}
    self:_schedule()
    return true
end

return CacheCleanupTask
