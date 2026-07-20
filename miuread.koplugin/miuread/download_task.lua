local FFIUtil = require("ffi/util")
local Json = require("miuread.json")
local U = require("miuread.util")
local UIManager = require("ui/uimanager")
local Device = require("device")
local logger = require("logger")

local DownloadTask = {}
DownloadTask.__index = DownloadTask

local function serializable_copy(value, seen)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" or kind == "nil" then return value end
    if kind ~= "table" then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local out = {}
    for k, v in pairs(value) do
        if type(k) == "string" or type(k) == "number" then
            local x = serializable_copy(v, seen)
            if x ~= nil then out[k] = x end
        end
    end
    return out
end

function DownloadTask:new(store)
    return setmetatable({store = store, job = nil, poll_task = nil, standby_held = false, keep_awake_enabled = true}, self)
end

function DownloadTask:_reset_device_timeout()
    if not self.keep_awake_enabled then return false end
    local powerd = Device and Device.powerd
    if powerd and type(powerd.resetT1Timeout) == "function" then
        local ok, err = pcall(powerd.resetT1Timeout, powerd)
        if not ok then logger.warn("[MiuRead][DownloadTask] Kindle T1 reset failed", tostring(err)) end
        return ok
    end
    return false
end

function DownloadTask:_hold_awake()
    if not self.keep_awake_enabled or self.standby_held then return end
    local ok, err = pcall(function() UIManager:preventStandby() end)
    if ok then
        self.standby_held = true
        local reset = self:_reset_device_timeout()
        logger.info("[MiuRead][DownloadTask] standby lock acquired", "t1_reset=", tostring(reset))
    else
        logger.warn("[MiuRead][DownloadTask] standby lock failed", tostring(err))
    end
end

function DownloadTask:_release_awake()
    if not self.standby_held then return end
    self.standby_held = false
    pcall(function() UIManager:allowStandby() end)
    logger.info("[MiuRead][DownloadTask] standby lock released")
end

function DownloadTask:available()
    return type(FFIUtil.runInSubProcess) == "function"
        and type(FFIUtil.isSubProcessDone) == "function"
end

function DownloadTask:busy()
    return self.job ~= nil
end

function DownloadTask:_schedule()
    if self.poll_task then return end
    local task
    task = function()
        if self.poll_task ~= task then return end
        self.poll_task = nil
        self:_poll()
    end
    self.poll_task = task
    UIManager:scheduleIn(0.30, task)
end

function DownloadTask:_read_progress(job)
    local raw = U.read_file(job.progress_path, true)
    if not raw or raw == job.last_progress_raw then return end
    job.last_progress_raw = raw
    local ok, state = pcall(Json.decode, raw)
    if ok and type(state) == "table" then
        job.last_progress_state = state
        if job.on_progress then job.on_progress(state) end
    end
end

function DownloadTask:_finish(job, forced_error)
    self:_read_progress(job)
    local raw = U.read_file(job.result_path, true)
    local result
    if forced_error then
        result = {ok = false, error = forced_error}
    elseif not raw then
        local stage = job.last_progress_state and job.last_progress_state.stage
        if stage == "package" then
            result = {ok = false, error = "EPUB 生成进程异常退出；原有完整书未被覆盖，已下载章节仍保存在断点缓存。请再次下载继续。"}
        else
            result = {ok = false, error = "下载子进程异常退出；已完成的下载进度会继续保留。"}
        end
    else
        local ok, decoded = pcall(Json.decode, raw)
        result = ok and decoded or {ok = false, error = "下载结果无法解析"}
    end

    os.remove(job.progress_path)
    os.remove(job.result_path)
    os.remove(job.cancel_path)
    self.job = nil
    self:_release_awake()
    if job.on_done then job.on_done(result) end
end

function DownloadTask:_poll()
    local job = self.job
    if not job then return end
    self:_read_progress(job)
    if not job.last_keepalive or os.time() - job.last_keepalive >= 5 then
        job.last_keepalive = os.time()
        local reset = self:_reset_device_timeout()
        if reset then logger.dbg("[MiuRead][DownloadTask] Kindle T1 timer reset") end
    end

    local done_ok, done = pcall(FFIUtil.isSubProcessDone, job.pid, false)
    if not done_ok then
        logger.warn("[MiuRead][DownloadTask] poll failed", tostring(done))
        self:_schedule()
        return
    end
    if not done then
        if job.cancel_requested_at and os.time() - job.cancel_requested_at >= 3 then
            pcall(FFIUtil.terminateSubProcess, job.pid)
            self:_finish(job, "下载已取消")
            return
        end
        self:_schedule()
        return
    end
    self:_finish(job)
end

function DownloadTask:cancel()
    local job = self.job
    if not job or job.cancel_requested_at then return end
    job.cancel_requested_at = os.time()
    U.atomic_write(job.cancel_path, "1", true)
end

function DownloadTask:start(book, options, on_progress, on_done)
    if self.job then return false, "已有下载任务正在运行" end
    if not self:available() then return false, "当前 KOReader 不支持下载子进程" end

    local stamp = tostring(os.time()) .. "-" .. tostring(math.random(10000, 99999))
    local progress_path = self.store.temp_dir .. "/download-progress-" .. stamp .. ".json"
    local result_path = self.store.temp_dir .. "/download-result-" .. stamp .. ".json"
    local cancel_path = self.store.temp_dir .. "/download-cancel-" .. stamp
    local clean_book = serializable_copy(book)
    local clean_options = serializable_copy(options or {})
    self.keep_awake_enabled = self.store:preferences().download_keep_awake ~= false
    clean_options.cancelled = nil

    local child = function()
        local Store = require("miuread.store")
        local Http = require("miuread.http")
        local Api = require("miuread.api")
        local Reader = require("miuread.reader")
        local Annotations = require("miuread.annotations")
        local Downloader = require("miuread.downloader")
        local JsonChild = require("miuread.json")
        local UChild = require("miuread.util")
        local LoggerChild = require("logger")

        local function emit(state)
            state = state or {}
            state.updated_at = os.time()
            local ok, encoded = pcall(JsonChild.encode, state)
            if ok then UChild.atomic_write(progress_path, encoded, true) end
        end

        local ok, value = xpcall(function()
            local store = Store:new()
            local http = Http:new(store)
            local api = Api:new(http, store)
            local reader = Reader:new(http, store)
            local annotations = Annotations:new(api)
            local downloader = Downloader:new(reader, api, annotations, store, http)
            clean_options.cancelled = function()
                return UChild.file_exists(cancel_path)
            end
            emit{stage = "prepare", current = 0, total = 1, chapter = clean_book.title or ""}
            return downloader:book(clean_book, clean_options, function(stage, current, total, chapter, detail)
                detail = detail or {}
                local percent
                if stage == "package" then
                    percent = 0.96
                elseif total and total > 0 then
                    local base = (math.max(1, current) - 1) / total
                    local step = 0
                    if stage == "resume" then step = 0.90
                    elseif stage == "content" then step = 0.08
                    elseif stage == "underlines" then step = 0.35
                    elseif stage == "thoughts" then step = 0.55
                    elseif stage == "footnotes" then step = 0.75
                    elseif stage == "images" then step = 0.88 end
                    percent = math.min(0.94, base * 0.94 + step / total)
                end
                if stage == "package" then
                    detail.message = detail.message or "正在低内存生成并验证 EPUB"
                end
                emit{
                    stage = stage,
                    current = current,
                    total = total,
                    chapter = chapter,
                    batch = detail.batch,
                    batch_total = detail.batches,
                    underlines = detail.underlines,
                    thoughts = detail.thoughts,
                    percent = percent,
                    message = detail.message,
                }
            end)
        end, debug.traceback)

        local payload
        if ok then
            emit{stage = "done", current = 1, total = 1, percent = 1, chapter = clean_book.title or ""}
            payload = {ok = true, value = serializable_copy(value)}
        else
            local raw_error = tostring(value)
            LoggerChild.warn("[MiuRead][DownloadTask] child failed", raw_error)
            local display_error = raw_error:match("^(.-)\nstack traceback:") or raw_error
            if raw_error:lower():find("not enough memory", 1, true) then
                display_error = "设备内存不足，未生成新的 EPUB。原有完整书未被覆盖，已完成章节仍保存在断点缓存；再次下载时会继续。"
            end
            emit{stage = UChild.file_exists(cancel_path) and "cancelled" or "error", message = display_error}
            payload = {ok = false, error = display_error}
        end
        local encoded = JsonChild.encode(payload)
        UChild.atomic_write(result_path, encoded, true)
    end

    local ok, pid, err = pcall(FFIUtil.runInSubProcess, child, false, false)
    if not ok or not pid then
        return false, tostring(err or pid or "无法启动下载子进程")
    end

    self.job = {
        pid = pid,
        progress_path = progress_path,
        result_path = result_path,
        cancel_path = cancel_path,
        on_progress = on_progress,
        on_done = on_done,
        last_progress_raw = nil,
        last_progress_state = nil,
        last_keepalive = 0,
    }
    self:_hold_awake()
    logger.info("[MiuRead][DownloadTask] started", "pid=", tostring(pid))
    self:_schedule()
    return true
end

return DownloadTask
