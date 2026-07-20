local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local ok_http, http = pcall(require, "socket.http")
local ok_https, https = pcall(require, "ssl.https")
local ok_socket, socket = pcall(require, "socket")
local Json = require("miuread.json")
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
    return code == 408 or code == 425 or code == 429 or code == 500
        or code == 502 or code == 503 or code == 504
end

local function pause(seconds)
    if ok_socket and socket and type(socket.sleep) == "function" then
        socket.sleep(seconds)
    end
end

function Http:new(store)
    return setmetatable({store = store, user_agent = Protocol.USER_AGENT}, self)
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

function Http:_save_jar(jar)
    local auth = self.store:auth()
    local cleaned = Cookies.sanitize(jar or {})
    if not Cookies.same(auth.cookies or {}, cleaned) then
        auth.cookies = cleaned
        self.store:save_auth(auth)
    end
end

function Http:_request_once(opt)
    local redirects = tonumber(opt.redirects) or 5
    local current = assert(opt.url, "url required")
    local method = opt.method or (opt.body and "POST" or "GET")
    local body = opt.body
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
        local called, ok, code, resp_headers, status = pcall(transport.request, {
            url = current,
            method = method,
            headers = headers,
            source = body and ltn12.source.string(body) or nil,
            sink = ltn12.sink.table(chunks),
        })
        socketutil:reset_timeout()
        if not called then return nil, nil, nil, current, tostring(ok) end
        local text = table.concat(chunks)
        code = tonumber(code)
        if not code then return text, nil, resp_headers, current, tostring(status or ok) end

        local set_cookie = hget(resp_headers, "set-cookie")
        if set_cookie and opt.auth ~= false then
            local before = Cookies.sanitize(jar)
            jar = Cookies.absorb(jar, set_cookie, {protect_core=true})
            if not Cookies.same(before, jar) then self:_save_jar(jar) end
            headers["Cookie"] = Cookies.header(jar)
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
    local last_text, last_code, last_headers, last_url, last_error

    for attempt = 1, retries + 1 do
        local text, code, headers, url, err = self:_request_once(opt)
        last_text, last_code, last_headers, last_url, last_error = text, code, headers, url, err
        if code and not transient_status(code) then return text, code, headers, url end
        if code and transient_status(code) and attempt > retries then return text, code, headers, url end
        if not code and attempt > retries then
            error("network request failed: " .. tostring(err or "unknown"))
        end
        logger.warn("[MiuRead][HTTP] retry", "attempt=", tostring(attempt), "url=", tostring(url or opt.url),
            "status=", tostring(code or err or "network"))
        pause(math.min(2.5, 0.35 * (2 ^ (attempt - 1))))
    end
    if last_code then return last_text, last_code, last_headers, last_url end
    error("network request failed: " .. tostring(last_error or "unknown"))
end

local function service_error(data, url)
    local code = data.errCode or data.errcode or data.code
    local message = tostring(data.errMsg or data.errmsg or data.message or data.msg or code or "")
    local lower = message:lower()
    if tonumber(code) == -2012 or lower:find("login timeout", 1, true)
        or message:find("登录超时", 1, true) then
        return "登录状态已失效（可能被另一台设备的新扫码登录替换）"
    end
    if is_weread_url(url) and (message == "用户不存在" or lower == "user not found") then
        return "登录状态已失效（服务端未识别当前用户）"
    end
    return message
end

function Http:json(opt)
    local text, code, headers, url = self:request(opt)
    text = text or ""
    if not code or code < 200 or code >= 300 then
        local content_type = hget(headers, "content-type") or "unknown"
        local preview = Util.first_line(text, 180)
        local message = "HTTP " .. tostring(code or "nil")
            .. ", content_type=" .. tostring(content_type)
            .. ", body_bytes=" .. tostring(#text)
        if preview ~= "" then message = message .. ": " .. preview end
        error(message)
    end
    local ok, data = pcall(Json.decode, text)
    if not ok then error("invalid JSON from " .. tostring(url) .. ": " .. Util.first_line(text, 180)) end
    if type(data) == "table" then
        local ec = data.errCode or data.errcode
        if ec and tonumber(ec) ~= 0 then error(service_error(data, url)) end
    end
    local meta = {
        code = code,
        length = #(text or ""),
        content_type = hget(headers, "content-type"),
        url = url,
        preview = Util.first_line(text, 180),
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

return Http
