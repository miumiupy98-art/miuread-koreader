--[[
MiuRead 限流补丁模块
路径：koreader/plugins/miuread.koplugin/miuread/ratelimit.lua

作用：
  1) 请求节流——保证两次请求之间有最小间隔，避免快设备瞬间打爆配额
  2) 限流退避——识别 "Hit api rate limit" 类错误体，指数等待后重试
  3) 协作模式——前台协程下载时，等待期间让出控制权，界面不会卡死
  4) 可取消——长等待切片执行，"取消下载" 仍能及时生效

慢设备（Kindle/Kobo）单次请求耗时本就超过最小间隔，行为完全不变。
]]

local logger = require("logger")
local ok_socket, socket = pcall(require, "socket")
local unpack = table.unpack or unpack

local RateLimit = {}

-- ======================= 可调参数 =======================
RateLimit.base_interval = 0.30   -- 基准最小请求间隔（秒）
RateLimit.min_interval  = 0.30   -- 当前生效间隔，会自适应变化
RateLimit.max_interval  = 2.50   -- 自适应上限
RateLimit.backoff       = {4, 8, 15, 25, 40}  -- 撞限流后的等待序列（秒）
RateLimit.blocking      = false  -- 允许退避重试（子进程/前台任务均置 true）
RateLimit.cooperative   = false  -- 前台协程模式：等待期间让出控制权
RateLimit.notifier      = nil    -- function(remaining_seconds, attempt, total)
RateLimit.interrupt     = nil    -- function() -> true 表示已取消
-- =======================================================

local last_start = 0
local success_streak = 0

local function pack(...)
    return {n = select("#", ...), ...}
end

local function monotonic()
    if ok_socket and socket and type(socket.gettime) == "function" then
        return socket.gettime()
    end
    return os.time()
end

local function sleep(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then return end
    if ok_socket and socket and type(socket.sleep) == "function" then
        socket.sleep(seconds)
    end
end

--- 判断一个错误是否属于"接口频率限制"
function RateLimit.is_rate_limit(message)
    local text = tostring(message or "")
    local lower = text:lower()
    return lower:find("rate limit", 1, true) ~= nil
        or lower:find("ratelimit", 1, true) ~= nil
        or lower:find("too many request", 1, true) ~= nil
        or lower:find("http 429", 1, true) ~= nil
        or lower:find("http 503", 1, true) ~= nil
        or text:find("频率", 1, true) ~= nil
        or text:find("过于频繁", 1, true) ~= nil
        or text:find("请求过快", 1, true) ~= nil
end

local function interrupted()
    if type(RateLimit.interrupt) ~= "function" then return false end
    local ok, stop = pcall(RateLimit.interrupt)
    return ok and stop == true
end

local function notify(remaining, attempt, total)
    if type(RateLimit.notifier) ~= "function" then return end
    pcall(RateLimit.notifier, remaining, attempt, total)
end

-- 只限制"最快速度"：上一次请求本身耗时已超过间隔时，这里完全不等待
local function throttle()
    local interval = tonumber(RateLimit.min_interval) or 0
    if interval <= 0 then
        last_start = monotonic()
        return
    end
    local wait = (last_start + interval) - monotonic()
    if wait > interval then wait = interval end   -- 防时钟跳变
    if wait > 0 then sleep(wait) end
    last_start = monotonic()
end

local function escalate(reason)
    success_streak = 0
    local current = tonumber(RateLimit.min_interval) or RateLimit.base_interval
    local raised = math.min(RateLimit.max_interval, current * 1.6 + 0.10)
    if raised > current then
        RateLimit.min_interval = raised
        logger.warn("[MiuRead][RateLimit] 放慢请求间隔 ->",
            string.format("%.2f", raised), "原因=", tostring(reason))
    end
end

local function relax()
    success_streak = success_streak + 1
    if success_streak < 25 then return end
    success_streak = 0
    local current = tonumber(RateLimit.min_interval) or RateLimit.base_interval
    if current > RateLimit.base_interval then
        RateLimit.min_interval = math.max(RateLimit.base_interval, current * 0.8)
    end
end

-- 长等待切片执行：
--   * 每秒检查一次取消
--   * 每秒回报一次剩余时间（子进程模式下同时充当心跳，避免父进程误判为死亡）
--   * 协作模式下让出协程，前台界面不会假死
local function long_sleep(seconds, attempt, total)
    local remaining = tonumber(seconds) or 0
    while remaining > 0 do
        if interrupted() then error("下载已取消", 0) end
        local slice = remaining > 1 and 1 or remaining
        sleep(slice)
        remaining = remaining - slice
        notify(remaining, attempt, total)
        if RateLimit.cooperative then
            -- 不在协程里时 coroutine.yield 会报错，用 pcall 兜住即可
            pcall(coroutine.yield)
        end
    end
    if interrupted() then error("下载已取消", 0) end
end

local function retry_count(opt)
    local explicit = tonumber(opt and opt.rate_limit_retries)
    if explicit then return explicit end
    if RateLimit.blocking then return #(RateLimit.backoff or {}) end
    return 0
end

-- 保留 "rate limit" 字样，便于上层继续识别
local function limit_error(original)
    error("接口访问频率超限（微信读书 rate limit）。已完成章节均已保存为断点，"
        .. "请等待约 10 分钟后再点“继续下载”。\n原始错误："
        .. tostring(original), 0)
end

local function with_retry(opt, fn)
    local total = retry_count(opt)
    local backoff = RateLimit.backoff or {}
    for attempt = 0, total do
        local r = pack(pcall(fn))
        if r[1] then
            relax()
            return unpack(r, 2, r.n)
        end
        local err = r[2]
        -- 非限流错误原样抛出，行为与打补丁前完全一致
        if not RateLimit.is_rate_limit(err) then error(err, 0) end
        escalate(err)
        if attempt >= total then limit_error(err) end
        local wait = tonumber(backoff[attempt + 1])
            or tonumber(backoff[#backoff]) or 30
        logger.warn("[MiuRead][RateLimit] 命中限流，等待", tostring(wait),
            "秒后重试 attempt=", tostring(attempt + 1))
        notify(wait, attempt + 1, total)
        long_sleep(wait, attempt + 1, total)
    end
end

--- 安装到 http 模块，幂等
function RateLimit.install(Http)
    if type(Http) ~= "table" then return false end
    if Http.__miuread_ratelimit then return true end
    Http.__miuread_ratelimit = true

    local original_request = Http.request
    if type(original_request) == "function" then
        Http.request = function(self, opt, ...)
            throttle()
            local r = pack(original_request(self, opt, ...))
            local code = tonumber(r[2])
            if code == 429 or code == 503 then
                escalate("HTTP " .. tostring(code))
            end
            return unpack(r, 1, r.n)
        end
    end

    local original_json = Http.json
    if type(original_json) == "function" then
        Http.json = function(self, opt, ...)
            local extra = pack(...)
            return with_retry(opt, function()
                return original_json(self, opt, unpack(extra, 1, extra.n))
            end)
        end
    end

    local original_download = Http.download
    if type(original_download) == "function" then
        Http.download = function(self, url, opt, ...)
            local extra = pack(...)
            return with_retry(opt, function()
                return original_download(self, url, opt, unpack(extra, 1, extra.n))
            end)
        end
    end

    logger.info("[MiuRead][RateLimit] 已启用请求节流与限流退避",
        "interval=", tostring(RateLimit.min_interval))
    return true
end

--- 下载任务开始时调用
function RateLimit.configure(config)
    config = type(config) == "table" and config or {}
    RateLimit.blocking = true
    RateLimit.cooperative = config.cooperative == true
    RateLimit.interrupt = config.interrupt
    RateLimit.notifier = config.notifier
    local interval = tonumber(config.min_interval)
    if interval then
        RateLimit.base_interval = interval
        RateLimit.min_interval = math.max(interval, RateLimit.min_interval)
    end
end

--- 下载任务结束时调用，恢复默认（避免影响书架浏览等前台请求）
function RateLimit.release()
    RateLimit.blocking = false
    RateLimit.cooperative = false
    RateLimit.interrupt = nil
    RateLimit.notifier = nil
end

-- 兼容旧调用名
RateLimit.configure_for_child = RateLimit.configure

return RateLimit
