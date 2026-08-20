local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local ok_http, http = pcall(require, "socket.http")
local ok_https, https = pcall(require, "ssl.https")
local ok_socket, socket = pcall(require, "socket")
local ok_lfs, lfs = pcall(require, "lfs")
local Json = require("miuread.json")
local Config = require("miuread.config")
local NetworkPolicy = require("miuread.network_policy")
local Cookies = require("miuread.cookies")
local Protocol = require("miuread.protocol")
local Util = require("miuread.util")
local logger = require("logger")

local Http = {}
Http.__index = Http

local function hget(headers, name)
    local target = tostring(name):lower()
    for k, v in pairs(headers or {}) do
        if type(k) == "string" and k:lower() == target then return v end
    end
end

local function is_weread_url(url)
    local host = tostring(url or ""):match("^https?://([^/]+)")
    if not host then return false end
    host = host:lower():gsub(":%d+$", "")
    return host == "weread.qq.com" or host:sub(-#".weread.qq.com") == ".weread.qq.com"
end

local function is_weread_api_url(url)
    url = tostring(url or "")
    if not is_weread_url(url) then return false end
    return url:find("/web/", 1, true) ~= nil
        or url:find("/api/", 1, true) ~= nil
end

local function absolute(base, loc)
    loc = tostring(loc or "")
    if loc:match("^https?://") then return loc end
    local scheme, host = tostring(base):match("^(https?)://([^/]+)")
    if not scheme then return loc end
    if loc:sub(1, 1) == "/" then return scheme .. "://" .. host .. loc end
    local dir = tostring(base):match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
    return dir .. loc
end

local function transient_status(code)
    code = tonumber(code)
    -- 429/499 are explicit rate-limit responses. Retrying them inside the
    -- generic HTTP loop only amplifies the request burst, so callers receive
    -- them immediately and apply one task-level cooldown instead.
    return code == 408 or code == 425 or code == 500
        or code == 502 or code == 503 or code == 504
end

local function pause(seconds)
    if ok_socket and socket and type(socket.sleep) == "function" then
        socket.sleep(seconds)
    end
end

local function clock_now()
    if ok_socket and socket and type(socket.gettime) == "function" then
        return socket.gettime()
    end
    return os.time()
end

local function probe_origin(url)
    local scheme, host = tostring(url or ""):match("^(https?)://([^/]+)")
    if not scheme or not host then return nil end
    return scheme .. "://" .. host .. "/"
end

local function discard_sink()
    return function() return 1 end
end

local function ipv4_tcp_factory()
    if not (ok_socket and socket and type(socket.tcp4) == "function") then
        return nil, "IPv4 socket unavailable"
    end
    local conn, err = socket.tcp4()
    if not conn then return nil, err end
    if type(conn.settimeout) == "function" then
        pcall(conn.settimeout, conn, tonumber(socketutil.block_timeout) or 15, "b")
        pcall(conn.settimeout, conn, tonumber(socketutil.total_timeout) or 35, "t")
    end
    return conn
end

local function body_rate_limit(text)
    text = tostring(text or "")
    if text == "" or #text > 32768 or not text:match("^%s*[%[{]") then return nil end
    local lower = text:lower()
    local code = lower:match('"errcode"%s*:%s*([%-]?%d+)')
        or lower:match('"err_code"%s*:%s*([%-]?%d+)')
        or lower:match('"code"%s*:%s*([%-]?%d+)')
    local numeric = tonumber(code)
    if numeric == -10102 or numeric == -2014
        or lower:find("hit api rate limit", 1, true)
        or lower:find("too many requests", 1, true)
        or lower:find("rate limit", 1, true)
        or text:find("请求频率超限", 1, true)
        or text:find("请求频率受限", 1, true) then
        return tostring(code or "rate_limit")
    end
    return nil
end

local RATE_LIMIT_DELAYS = {15, 30, 60, 90}
local SHARED_RATE_LIMIT_DEFAULT = 300

function Http:new(store)
    local data_dir=tostring(store and store.data_dir or "")
    local temp_dir=tostring(store and store.temp_dir or "")
    local base=data_dir~="" and data_dir or temp_dir
    return setmetatable({
        store = store,
        user_agent = Protocol.USER_AGENT,
        last_weread_request_at = 0,
        last_weread_request_at_by_scope = {},
        rate_limit_until = 0,
        min_weread_interval = 0.35,
        shared_rate_limit_path = base~="" and (base.."/weread-rate-limit.json") or nil,
        shared_pacing_path = base~="" and (base.."/weread-pacing.json") or nil,
    }, self)
end

function Http:set_download_network_policy(options)
    self.network_policy = NetworkPolicy:new(options or {})
    return self.network_policy
end

function Http:_transport_request(transport, request, force_ipv4)
    if force_ipv4~=true then return pcall(transport.request, request) end
    if not (ok_socket and socket and type(socket.tcp4)=="function") then
        logger.warn("[MiuRead][NetworkPolicy] IPv4-only socket unavailable; keeping automatic networking")
        return pcall(transport.request, request)
    end
    local previous_tcp=socket.tcp
    socket.tcp=ipv4_tcp_factory
    local called,ok,code,headers,status=pcall(transport.request,request)
    socket.tcp=previous_tcp
    return called,ok,code,headers,status
end

function Http:_probe_once(url, force_ipv4)
    local transport
    if tostring(url):match("^https:") then
        transport=ok_https and https or (ok_http and http or nil)
    else
        transport=ok_http and http or nil
    end
    if not transport or type(transport.request)~="function" then return nil end
    if force_ipv4 and not (self.network_policy and self.network_policy:ipv4_available(socket)) then return nil end

    socketutil:set_timeout(
        tonumber(Config.DOWNLOAD_NETWORK_PROBE_BLOCK_TIMEOUT) or 4,
        tonumber(Config.DOWNLOAD_NETWORK_PROBE_TOTAL_TIMEOUT) or 6)
    local started=clock_now()
    local called,ok,code=self:_transport_request(transport,{
        url=url,
        method="HEAD",
        headers={
            ["User-Agent"]=self.user_agent,
            ["Accept"]="*/*",
            ["Connection"]="close",
        },
        sink=discard_sink(),
    },force_ipv4==true)
    local elapsed=clock_now()-started
    socketutil:reset_timeout()
    if not called or not tonumber(code) then
        logger.info("[MiuRead][NetworkPolicy] probe unavailable",
            "family=",force_ipv4 and "ipv4" or "auto",
            "status=",tostring(code or ok or "network"))
        return nil
    end
    return math.max(0,elapsed),tonumber(code)
end

function Http:_verify_ipv4_advantage(current_url, trigger)
    local policy=self.network_policy
    if not policy or policy:current_mode()~="auto" or not policy:ipv4_available(socket) then return end
    local url=probe_origin(current_url)
    if not url then return end

    -- Two reversed-order pairs are deliberate. Both pairs must independently
    -- show the same IPv4 advantage, so a server/CDN recovery between probes
    -- cannot by itself trigger the compatibility prompt.
    local auto1=self:_probe_once(url,false)
    local ipv41=self:_probe_once(url,true)
    if not auto1 or not ipv41 or not policy:probe_is_promising(auto1,ipv41) then return end
    local ipv42=self:_probe_once(url,true)
    local auto2=self:_probe_once(url,false)
    if not auto2 or not ipv42 or not policy:probe_is_promising(auto2,ipv42) then return end

    local confirmed=policy:confirm_probes({auto1,auto2},{ipv41,ipv42})
    if not confirmed or type(self.on_network_suggestion)~="function" then return end
    confirmed.trigger_baseline=trigger and trigger.baseline or nil
    local ok,err=pcall(self.on_network_suggestion,confirmed)
    if not ok then logger.warn("[MiuRead][NetworkPolicy] suggestion callback failed",tostring(err)) end
end

function Http:_observe_download_network(url, delay, code)
    local policy=self.network_policy
    if not policy or not is_weread_url(url) then return end
    code=tonumber(code)
    if not code or code<200 or code>=400 then return end
    local trigger=policy:observe(delay)
    if trigger then self:_verify_ipv4_advantage(url,trigger) end
end

function Http:_pacing_path(scope)
    local path=tostring(self.shared_pacing_path or "")
    if path=="" then return "" end
    scope=tostring(scope or "global"):gsub("[^%w%-_]","-")
    if scope=="" or scope=="global" then return path end
    return path:gsub("%.json$","").."-"..scope..".json"
end

local function release_pacing_lock(path)
    if ok_lfs and lfs and type(lfs.rmdir)=="function" then pcall(lfs.rmdir,path) end
end

local function pacing_lock_stale(path)
    if not (ok_lfs and lfs and type(lfs.attributes)=="function") then return false end
    local ok,modified=pcall(lfs.attributes,path,"modification")
    return ok and tonumber(modified) and os.time()-tonumber(modified)>10
end

local function acquire_pacing_lock(path)
    if not (ok_lfs and lfs and type(lfs.mkdir)=="function") then return false end
    local deadline=clock_now()+2.0
    while clock_now()<deadline do
        if lfs.mkdir(path)==true then return true end
        if pacing_lock_stale(path) then release_pacing_lock(path) end
        pause(0.04)
    end
    return false
end

function Http:_reserve_shared_pacing(scope,interval,jitter)
    local path=self:_pacing_path(scope)
    interval=math.max(0,tonumber(interval) or 0)
    jitter=math.max(0,tonumber(jitter) or 0)
    if path=="" or interval<=0 then return 0 end

    local lock_path=path..".lock"
    local locked=acquire_pacing_lock(lock_path)
    if not locked then return 0 end

    local ok,result=pcall(function()
        local now=clock_now()
        local next_at=0
        local raw=Util.read_file(path,true)
        if raw then
            local decoded_ok,state=pcall(Json.decode,raw)
            if decoded_ok and type(state)=="table" then next_at=tonumber(state.next_at or 0) or 0 end
        end
        -- A stale or corrupted reservation must never block requests for minutes.
        if next_at<now-interval or next_at>now+120 then next_at=now end
        local scheduled=math.max(now,next_at)
        local extra=jitter>0 and (math.random()*jitter) or 0
        local wrote,err=Util.atomic_write(path,Json.encode({
            next_at=scheduled+interval+extra,
            scope=tostring(scope or "global"),
            updated_at=os.time(),
        }),true)
        if not wrote then
            logger.warn("[MiuRead][HTTP] shared pacing state write failed",tostring(err))
            return 0
        end
        return math.max(0,scheduled-now)
    end)
    release_pacing_lock(lock_path)
    if not ok then
        logger.warn("[MiuRead][HTTP] shared pacing reservation failed",tostring(result))
        return 0
    end
    return tonumber(result) or 0
end

function Http:_rate_limit_path(scope)
    local path=tostring(self.shared_rate_limit_path or "")
    if path=="" then return "" end
    scope=tostring(scope or "global"):gsub("[^%w%-_]","-")
    if scope=="" or scope=="global" then return path end
    return path:gsub("%.json$","").."-"..scope..".json"
end

function Http:_shared_rate_limit(scope)
    local path=self:_rate_limit_path(scope)
    if path=="" then return 0,nil end
    local raw=Util.read_file(path,true)
    if not raw then return 0,nil end
    local ok,state=pcall(Json.decode,raw)
    if not ok or type(state)~="table" then
        os.remove(path)
        return 0,nil
    end
    local until_at=tonumber(state.until_at or 0) or 0
    local remaining=math.max(0,math.ceil(until_at-os.time()))
    if remaining<=0 then
        os.remove(path)
        return 0,nil
    end
    return remaining,state
end

function Http:_set_shared_rate_limit(seconds,code,url,scope)
    local path=self:_rate_limit_path(scope)
    seconds=math.max(1,math.floor(tonumber(seconds) or SHARED_RATE_LIMIT_DEFAULT))
    if path=="" then return seconds end
    local current=self:_shared_rate_limit(scope)
    local until_at=os.time()+math.max(seconds,tonumber(current) or 0)
    local payload={
        until_at=until_at,
        code=tostring(code or "rate_limit"),
        source=Util.redact_url(url or ""),
        scope=tostring(scope or "global"),
        updated_at=os.time(),
    }
    local ok,encoded=pcall(Json.encode,payload)
    if ok then
        local wrote,err=Util.atomic_write(path,encoded,true)
        if not wrote then logger.warn("[MiuRead][HTTP] shared rate-limit state write failed",tostring(err)) end
    end
    return math.max(1,until_at-os.time())
end

function Http:_cancelled()
    if type(self.cancelled) ~= "function" then return false end
    local ok, value = pcall(self.cancelled)
    return ok and value == true
end

function Http:_report_rate_limit(remaining, attempt, maximum, code)
    if type(self.on_rate_limit) ~= "function" then return end
    local ok, err = pcall(self.on_rate_limit, remaining, attempt, maximum, code)
    if not ok then logger.warn("[MiuRead][HTTP] rate-limit callback failed", tostring(err)) end
end

function Http:_wait_rate_limit(seconds, attempt, maximum, code)
    seconds = math.max(1, math.floor(tonumber(seconds) or 1))
    local deadline = clock_now() + seconds
    self.rate_limit_until = math.max(tonumber(self.rate_limit_until) or 0, deadline)
    local last_report
    while true do
        if self:_cancelled() then error("download cancelled") end
        local remaining = math.max(0, math.ceil(deadline - clock_now()))
        if remaining <= 0 then break end
        if last_report == nil or remaining <= 3 or remaining <= last_report - 10 then
            self:_report_rate_limit(remaining, attempt, maximum, code)
            last_report = remaining
        end
        pause(math.min(1, remaining))
    end
end

function Http:_pace(url, opt)
    if not is_weread_api_url(url) or opt.pacing == false then return end
    if self:_cancelled() then error("download cancelled") end
    local now = clock_now()
    local scope=tostring(opt.pacing_scope or opt.rate_limit_scope or "global")
    local scoped_last=tonumber((self.last_weread_request_at_by_scope or {})[scope]) or 0
    local wait = math.max(0, (tonumber(self.rate_limit_until) or 0) - now)
    local interval = tonumber(opt.min_interval) or tonumber(self.min_weread_interval) or 0
    wait = math.max(wait, interval - (now - scoped_last))
    if wait > 0 then pause(wait) end
    if self:_cancelled() then error("download cancelled") end
    if opt.shared_pacing==true then
        local shared_wait=self:_reserve_shared_pacing(scope,interval,opt.pacing_jitter)
        if shared_wait>0 then pause(shared_wait) end
    elseif tonumber(opt.pacing_jitter or 0)>0 then
        pause(math.random()*tonumber(opt.pacing_jitter))
    end
    if self:_cancelled() then error("download cancelled") end
    local requested_at=clock_now()
    self.last_weread_request_at=requested_at
    self.last_weread_request_at_by_scope=self.last_weread_request_at_by_scope or {}
    self.last_weread_request_at_by_scope[scope]=requested_at
end

function Http:_jar()
    local auth = self.store:auth()
    local original = auth.cookies or {}
    local jar, changed = Cookies.sanitize(original)
    if changed then
        auth.cookies = jar
        self.store:save_auth(auth)
        logger.info("[MiuRead][HTTP] removed temporary cookies from saved login",
            "names=", table.concat(Cookies.names(jar), ","))
    end
    return jar
end

function Http:_save_jar(jar, expected_login_session_id)
    local auth = self.store:auth()
    if tostring(expected_login_session_id or "")~=""
        and tostring(auth.login_session_id or "")~=tostring(expected_login_session_id or "") then
        logger.warn("[MiuRead][HTTP] stale cookie response ignored")
        return false
    end
    local cleaned = Cookies.sanitize(jar or {})
    if not Cookies.same(auth.cookies or {}, cleaned) then
        auth.cookies = cleaned
        self.store:save_auth(auth)
    end
end

function Http:_save_response_auth_headers(headers, expected_login_session_id)
    local ticket = hget(headers, "x-wr-ticket")
    local wrpa = hget(headers, "x-wrpa-0")
    if (ticket == nil or tostring(ticket) == "") and (wrpa == nil or tostring(wrpa) == "") then return false end
    local auth = self.store:auth()
    if tostring(expected_login_session_id or "")~=""
        and tostring(auth.login_session_id or "")~=tostring(expected_login_session_id or "") then
        logger.warn("[MiuRead][HTTP] stale credential response ignored")
        return false
    end
    local changed = false
    if ticket ~= nil and tostring(ticket) ~= "" and tostring(auth.wr_ticket or "") ~= tostring(ticket) then
        auth.wr_ticket = tostring(ticket)
        auth.ticket_updated_at = os.time()
        changed = true
    end
    if wrpa ~= nil and tostring(wrpa) ~= "" and tostring(auth.wr_wrpa or "") ~= tostring(wrpa) then
        auth.wr_wrpa = tostring(wrpa)
        auth.ticket_updated_at = os.time()
        changed = true
    end
    if changed then
        self.store:save_auth(auth)
        logger.info("[MiuRead][HTTP] public-account credential refreshed",
            "ticket=", tostring(auth.wr_ticket ~= ""), "wrpa=", tostring(auth.wr_wrpa ~= ""))
    end
    return changed
end

function Http:_request_once(opt)
    local redirects = tonumber(opt.redirects) or 5
    local current = assert(opt.url, "url required")
    local method = opt.method or (opt.body and "POST" or "GET")
    local body = opt.body
    local auth_snapshot=self.store:auth()
    local request_login_session_id=tostring(auth_snapshot.login_session_id or "")
    local jar = self:_jar()
    local headers = {}
    for k, v in pairs(opt.headers or {}) do headers[k] = v end
    headers["User-Agent"] = headers["User-Agent"] or self.user_agent
    headers["Accept"] = headers["Accept"] or "*/*"
    if opt.auth ~= false and is_weread_url(current) then
        local cookie = Cookies.header(jar)
        if cookie ~= "" then headers["Cookie"] = cookie end
    end
    if body then
        headers["Content-Length"] = tostring(#body)
        headers["Content-Type"] = headers["Content-Type"] or "application/json;charset=UTF-8"
    end

    for hop = 0, redirects do
        local chunks = {}
        socketutil:set_timeout((opt.timeout and opt.timeout[1]) or 15, (opt.timeout and opt.timeout[2]) or 35)
        local transport
        if current:match("^https:") then
            transport = ok_https and https or (ok_http and http or nil)
        else
            transport = ok_http and http or nil
        end
        if not transport or type(transport.request) ~= "function" then
            socketutil:reset_timeout()
            return nil, nil, nil, current, "HTTP transport unavailable"
        end
        self:_pace(current, opt)
        local first_data_at
        local sink=function(chunk,err)
            if chunk then
                if not first_data_at then first_data_at=clock_now() end
                chunks[#chunks+1]=chunk
            end
            return 1
        end
        local request_started=clock_now()
        local force_ipv4=self.network_policy and self.network_policy:should_force_ipv4() or false
        local called, ok, code, resp_headers, status = self:_transport_request(transport, {
            url = current,
            method = method,
            headers = headers,
            source = body and ltn12.source.string(body) or nil,
            sink = sink,
        }, force_ipv4)
        local request_finished=clock_now()
        socketutil:reset_timeout()
        if not called then return nil, nil, nil, current, tostring(ok) end
        local text = table.concat(chunks)
        code = tonumber(code)
        if code and self.network_policy then
            local response_delay=(first_data_at or request_finished)-request_started
            self:_observe_download_network(current,response_delay,code)
        end
        if not code then return text, nil, resp_headers, current, tostring(status or ok) end

        local set_cookie = hget(resp_headers, "set-cookie")
        if set_cookie and opt.auth ~= false then
            local before = Cookies.sanitize(jar)
            jar = Cookies.absorb(jar, set_cookie, {protect_core=true})
            if not Cookies.same(before, jar) then self:_save_jar(jar,request_login_session_id) end
            headers["Cookie"] = Cookies.header(jar)
        end
        if opt.auth ~= false and is_weread_url(current) then
            self:_save_response_auth_headers(resp_headers,request_login_session_id)
        end

        local location = hget(resp_headers, "location")
        if code >= 300 and code < 400 and location and hop < redirects then
            current = absolute(current, location)
            if opt.auth ~= false and is_weread_url(current) then
                local cookie = Cookies.header(jar)
                headers["Cookie"] = cookie ~= "" and cookie or nil
            else
                headers["Cookie"] = nil
            end
            if code == 303 then
                method, body = "GET", nil
                headers["Content-Length"] = nil
            end
        else
            return text, code, resp_headers, current
        end
    end
    return nil, nil, nil, current, "too many redirects"
end

function Http:request(opt)
    opt = opt or {}
    local retries = tonumber(opt.retries)
    if retries == nil then retries = 2 end
    retries = math.max(0, math.min(5, retries))
    local rate_retries = tonumber(opt.rate_limit_retries)
    if rate_retries == nil then
        rate_retries = is_weread_api_url(opt.url) and tonumber(self.rate_limit_retries) or 0
    end
    rate_retries = math.max(0, math.min(#RATE_LIMIT_DELAYS, rate_retries))
    local rate_limit_scope=tostring(opt.rate_limit_scope or "global")
    local shared_remaining,shared_state=self:_shared_rate_limit(rate_limit_scope)
    if shared_remaining>0 then
        local code=shared_state and shared_state.code or "rate_limit"
        if opt.rate_limit_fail_fast==true then
            error("请求频率暂时受限 [MiuReadRateLimit] error_code="..tostring(code)
                .." wait_seconds="..tostring(shared_remaining).."：已暂停附加内容请求，请稍后重试。")
        end
        logger.warn("[MiuRead][HTTP] respecting shared rate-limit cooldown",
            "wait=",tostring(shared_remaining),"code=",tostring(code),"url=",Util.redact_url(opt.url or ""))
        self:_wait_rate_limit(shared_remaining,0,math.max(1,rate_retries),code)
    end
    local rate_attempt = 0
    local last_text, last_code, last_headers, last_url, last_error

    while true do
        local limited_code
        for attempt = 1, retries + 1 do
            local text, code, headers, url, err = self:_request_once(opt)
            last_text, last_code, last_headers, last_url, last_error = text, code, headers, url, err
            limited_code = (tonumber(code) == 429 or tonumber(code) == 499)
                and tostring(code) or body_rate_limit(text)
            if limited_code then break end
            if code and not transient_status(code) then return text, code, headers, url end
            if code and transient_status(code) and attempt > retries then return text, code, headers, url end
            if not code and attempt > retries then
                error("network request failed: " .. tostring(err or "unknown"))
            end
            logger.warn("[MiuRead][HTTP] retry", "attempt=", tostring(attempt), "url=", Util.redact_url(url or opt.url),
                "status=", tostring(code or err or "network"))
            pause(math.min(2.5, 0.35 * (2 ^ (attempt - 1))))
        end

        if not limited_code then
            if last_code then return last_text, last_code, last_headers, last_url end
            error("network request failed: " .. tostring(last_error or "unknown"))
        end

        local retry_after_value = hget(last_headers, "retry-after")
        local retry_after = retry_after_value and tonumber(retry_after_value) or nil
        if rate_attempt >= rate_retries then
            local cooldown=tonumber(opt.rate_limit_cooldown) or retry_after or SHARED_RATE_LIMIT_DEFAULT
            cooldown=math.max(30,math.min(1800,cooldown))
            local remaining=self:_set_shared_rate_limit(cooldown,limited_code,last_url or opt.url,rate_limit_scope)
            error("请求频率仍受限 [MiuReadRateLimit] error_code=" .. tostring(limited_code)
                .. " wait_seconds="..tostring(remaining)
                .. "：已停止继续请求，正文和下载断点会保留，请稍后重试。")
        end

        rate_attempt = rate_attempt + 1
        local wait = RATE_LIMIT_DELAYS[rate_attempt] or RATE_LIMIT_DELAYS[#RATE_LIMIT_DELAYS]
        if retry_after then wait = math.max(wait, math.min(180, retry_after)) end
        logger.warn("[MiuRead][HTTP] rate limited; cooling down",
            "attempt=", tostring(rate_attempt), "wait=", tostring(wait),
            "code=", tostring(limited_code), "url=", Util.redact_url(last_url or opt.url))
        self:_wait_rate_limit(wait, rate_attempt, rate_retries, limited_code)
    end
end

local AUTH_ERROR_MARKER = "[MiuReadAuth]"
local RATE_LIMIT_MARKER = "[MiuReadRateLimit]"

local function auth_error_message(code, message)
    local suffix = tostring(message or ""):gsub("[%c]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local out = "登录状态已失效 " .. AUTH_ERROR_MARKER .. " error_code=" .. tostring(code or "unknown")
    if suffix ~= "" then out = out .. ": " .. suffix end
    return out
end

local function service_error(data, url)
    local code = data.errCode or data.errcode or data.code
    local message = Util.redact_url(data.errMsg or data.errmsg or data.message or data.msg or code or "")
    local lower = message:lower()
    if tonumber(code) == -10102 or tonumber(code) == -2014 or message:find("请求频率超限", 1, true)
        or lower:find("rate limit", 1, true) or lower:find("too many requests", 1, true) then
        return "请求频率受限 " .. RATE_LIMIT_MARKER .. " error_code=" .. tostring(code or "rate_limit")
            .. (message ~= "" and (": " .. message) or "")
    end
    if tonumber(code) == -2011 or tonumber(code) == -2012 or tonumber(code) == -2041 or lower:find("login timeout", 1, true)
        or message:find("登录超时", 1, true) then
        -- -2011/-2012 mean the current web session can no longer be used. They do
        -- not prove that another device replaced this one, so keep the real
        -- code and let write callers decide whether one controlled renewal is safe.
        return auth_error_message(code or -2012, message)
    end
    if is_weread_url(url) and (message == "用户不存在" or lower == "user not found") then
        return auth_error_message(code or "user_not_found", message)
    end
    if is_weread_url(url) and message:find("鉴权失败", 1, true) then
        return auth_error_message(code or "auth_failed", message)
    end
    return message
end

local function auth_error_code(value)
    local text = tostring(value or "")
    return text:match("%[MiuReadAuth%]%s+error_code=([^:%s]+)")
        or text:match("error_code=([%-]?%d+)")
end

local function is_auth_error(value)
    local text = tostring(value or "")
    local lower = text:lower()
    return text:find(AUTH_ERROR_MARKER, 1, true) ~= nil
        or tonumber(auth_error_code(text)) == -2011
        or tonumber(auth_error_code(text)) == -2012
        or tonumber(auth_error_code(text)) == -2041
        or lower:find("http 401", 1, true) ~= nil
        or lower:find("login expired", 1, true) ~= nil
        or lower:find("login timeout", 1, true) ~= nil
        or lower:find("session expired", 1, true) ~= nil
        or lower:find("not logged", 1, true) ~= nil
        or lower:find("api key is not configured", 1, true) ~= nil
        or text:find("未登录", 1, true) ~= nil
        or text:find("登录过期", 1, true) ~= nil
        or text:find("登录授权已过期", 1, true) ~= nil
        or text:find("重新登录", 1, true) ~= nil
        or text:find("登录超时", 1, true) ~= nil
        or text:find("登录失效", 1, true) ~= nil
        or text:find("登录状态已失效", 1, true) ~= nil
        or text:find("鉴权失败", 1, true) ~= nil
end

local function is_forbidden_error(value)
    return tostring(value or ""):lower():find("http 403",1,true)~=nil
end

local function is_network_error(value)
    local text=tostring(value or "")
    local lower=text:lower()
    return lower:find("network request failed",1,true)~=nil
        or lower:find("http nil",1,true)~=nil
        or lower:find("status=nil",1,true)~=nil
        or lower:find("connection",1,true)~=nil
        or lower:find("broken pipe",1,true)~=nil
        or lower:find("timed out",1,true)~=nil
        or lower:find("timeout",1,true)~=nil
        or text:find("网络不可用",1,true)~=nil
        or text:find("网络请求失败",1,true)~=nil
end

local function is_rate_limit_error(value)
    local text = tostring(value or "")
    local lower = text:lower()
    return text:find(RATE_LIMIT_MARKER, 1, true) ~= nil
        or lower:find("http 429", 1, true) ~= nil
        or lower:find("http 499", 1, true) ~= nil
        or lower:find("error_code=-10102", 1, true) ~= nil
        or lower:find("error_code=-2014", 1, true) ~= nil
        or lower:find("rate limit", 1, true) ~= nil
        or lower:find("too many requests", 1, true) ~= nil
        or text:find("请求频率超限", 1, true) ~= nil
        or text:find("请求频率受限", 1, true) ~= nil
end

function Http:json(opt)
    local text, code, headers, url = self:request(opt)
    text = text or ""
    if not code or code < 200 or code >= 300 then
        local content_type = hget(headers, "content-type") or "unknown"
        local preview = Util.redact_url(Util.first_line(text, 180))
        local message = "HTTP " .. tostring(code or "nil")
            .. ", content_type=" .. tostring(content_type)
            .. ", body_bytes=" .. tostring(#text)
        local retry_after = hget(headers, "retry-after")
        if retry_after ~= nil and tostring(retry_after) ~= "" then
            message = message .. ", retry_after=" .. tostring(retry_after)
        end
        if preview ~= "" then message = message .. ": " .. preview end
        if tonumber(code) == 429 or tonumber(code) == 499 then
            message = "请求频率受限 " .. RATE_LIMIT_MARKER .. ": " .. message
        end
        error(message)
    end
    local ok, data = pcall(Json.decode, text)
    if not ok then error("invalid JSON from " .. Util.redact_url(url) .. ": " .. Util.first_line(text, 180)) end
    if type(data) == "table" then
        local ec = data.errCode or data.errcode
        if ec == nil and tonumber(data.code) and tonumber(data.code) < 0 then ec = data.code end
        if ec and tonumber(ec) ~= 0 then error(service_error(data, url)) end
    end
    local meta = {
        code = code,
        length = #(text or ""),
        content_type = hget(headers, "content-type"),
        url = Util.redact_url(url),
        preview = Util.redact_url(Util.first_line(text, 180)),
    }
    return data, headers, meta
end

function Http:get_json(url, opt)
    opt = opt or {}; opt.url = url; opt.method = "GET"; return self:json(opt)
end

function Http:post_json(url, value, opt)
    opt = opt or {}; opt.url = url; opt.method = "POST"; opt.body = Json.encode(value); return self:json(opt)
end

function Http:download(url, opt)
    opt = opt or {}; opt.url = url; opt.method = opt.method or "GET"
    if opt.retries == nil then opt.retries = 3 end
    local body, code, headers, final = self:request(opt)
    if code < 200 or code >= 300 then error("download HTTP " .. tostring(code)) end
    return body, headers, final
end

Http.auth_error_code = auth_error_code
Http.auth_error_message = auth_error_message
Http.is_auth_error = is_auth_error
Http.is_forbidden_error = is_forbidden_error
Http.is_network_error = is_network_error
Http.is_rate_limit_error = is_rate_limit_error

return Http
