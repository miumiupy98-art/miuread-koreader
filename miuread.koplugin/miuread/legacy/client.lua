local ltn12 = require("ltn12")
local Cookie = require("miuread.legacy.cookie")
local WeRead = require("miuread.legacy.weread")

local ok_https, https = pcall(require, "ssl.https")
local ok_http, http = pcall(require, "socket.http")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local DEFAULT_TIMEOUT_SECONDS = 15
local QR_LOGIN_TIMEOUT_SECONDS = 65
local SKILLS_PAGE_URL = "https://weread.qq.com/r/weread-skills"
local LOGIN_UID_URL = "https://weread.qq.com/api/auth/getLoginUid"
local LOGIN_INFO_URL = "https://weread.qq.com/api/auth/getLoginInfo"
local USER_INFO_URL = "https://weread.qq.com/api/userInfo"
local API_KEY_URL = "https://weread.qq.com/api/skills/apikeyGet"
local unpack_args = unpack or table.unpack

local Client = {}
Client.__index = Client

local function header_value(headers, name)
    if not headers then
        return nil
    end
    local target = name:lower()
    for key, value in pairs(headers) do
        if tostring(key):lower() == target then
            return value
        end
    end
    return nil
end

local function scalar_header_value(headers, name)
    local value = header_value(headers, name)
    if type(value) == "table" then
        for _, item in pairs(value) do
            return tostring(item)
        end
        return nil
    end
    return value
end

local function merge_response_cookies(cookies, headers)
    local set_cookie = header_value(headers, "set-cookie")
    if set_cookie then
        return Cookie.merge_set_cookie(cookies or {}, set_cookie)
    end
    return cookies or {}
end

local function http_error(client, code, text, headers)
    text = text or ""
    local content_type = tostring(header_value(headers, "content-type") or "unknown")
    local parts = {
        "HTTP " .. tostring(code),
        "content_type=" .. content_type,
        "body_bytes=" .. tostring(#text),
    }
    local looks_like_json = content_type:lower():find("json", 1, true)
        or text:match("^%s*{") ~= nil
        or text:match("^%s*%[") ~= nil
    if looks_like_json and #text <= 65536 then
        local ok, data = pcall(function()
            return client:json_decode(text)
        end)
        if ok and type(data) == "table" then
            local err_code = data.errCode or data.errcode or data.code
            local err_message = data.errMsg or data.errmsg or data.message or data.msg
            if err_code ~= nil then
                table.insert(parts, "error_code=" .. tostring(err_code))
            end
            if err_message ~= nil then
                local message = tostring(err_message):gsub("[%c]+", " "):sub(1, 200)
                table.insert(parts, "error_message=" .. message)
            end
        end
    end
    return table.concat(parts, ", ")
end

local function absolute_url(base_url, location)
    if not location or location == "" then
        return nil
    end
    if location:match("^https?://") then
        return location
    end
    local scheme, host = base_url:match("^(https?)://([^/]+)")
    if not scheme then
        return location
    end
    if location:sub(1, 1) == "/" then
        return scheme .. "://" .. host .. location
    end
    local prefix = base_url:match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
    return prefix .. location
end

local function url_origin(url)
    local scheme, authority = tostring(url or ""):match("^(https?)://([^/]+)")
    if not scheme then
        return nil
    end
    return scheme:lower() .. "://" .. authority:lower()
end

local function is_weread_url(url)
    local authority = tostring(url or ""):match("^https?://([^/]+)")
    if not authority then
        return false
    end
    local host = authority:lower():gsub(":%d+$", "")
    return host == "weread.qq.com" or host:sub(-#".weread.qq.com") == ".weread.qq.com"
end

local function clear_cross_origin_headers(headers)
    for key in pairs(headers or {}) do
        local name = tostring(key):lower()
        if name == "authorization" or name == "cookie" or name == "origin" then
            headers[key] = nil
        end
    end
end

local function transport_request(transport, request, timeout)
    timeout = timeout or DEFAULT_TIMEOUT_SECONDS
    local previous_timeout = transport.TIMEOUT
    transport.TIMEOUT = timeout
    local results = { pcall(transport.request, request) }
    transport.TIMEOUT = previous_timeout
    if not results[1] then
        error(results[2])
    end
    table.remove(results, 1)
    return unpack_args(results)
end

function Client:new(settings)
    return setmetatable({
        settings = settings,
    }, self)
end

function Client:json_encode(data)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.encode then
        return json.encode(data)
    end
    return json:encode(data)
end

function Client:json_decode(text)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.decode then
        return json.decode(text)
    end
    return json:decode(text)
end

function Client:request(opts)
    local body = opts.body
    local response = {}
    local headers = opts.headers or {}
    headers["User-Agent"] = headers["User-Agent"] or WeRead.USER_AGENT
    headers["Accept"] = headers["Accept"] or "application/json, text/plain, */*"

    if body then
        headers["Content-Length"] = tostring(#body)
    end

    local transport = opts.url:match("^https:") and https or http
    if opts.url:match("^https:") and not ok_https then
        error("ssl.https is not available")
    elseif not transport and not ok_http then
        error("socket.http is not available")
    end

    local _, code, resp_headers, status = transport_request(transport, {
        url = opts.url,
        method = opts.method or (body and "POST" or "GET"),
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(response),
    }, opts.timeout)

    return table.concat(response), tonumber(code), resp_headers or {}, status
end

function Client:request_follow(opts, max_redirects)
    max_redirects = max_redirects or 5
    local url = opts.url
    for redirect_index = 1, max_redirects + 1 do
        opts.url = url
        local text, code, resp_headers, status = self:request(opts)
        if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
            local location = header_value(resp_headers, "location")
            if not location then
                return text, code, resp_headers, status
            end
            local next_url = absolute_url(url, location)
            if url_origin(url) ~= url_origin(next_url) then
                clear_cross_origin_headers(opts.headers)
            end
            url = next_url
            opts.method = "GET"
            opts.body = nil
            opts.headers = opts.headers or {}
            opts.headers["Content-Length"] = nil
        else
            return text, code, resp_headers, status
        end
    end
    error("Too many redirects")
end

function Client:post_json(url, data, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Content-Type"] = "application/json;charset=UTF-8",
        ["Origin"] = "https://weread.qq.com",
        ["Referer"] = opts.referer or "https://weread.qq.com/",
    }
    local cookie_header = Cookie.to_header(cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = "POST",
        headers = headers,
        body = self:json_encode(data),
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        return self:json_decode(text), code, resp_headers
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:post_no_cookie(url, data, opts)
    opts = opts or {}
    local headers = {
        ["Content-Type"] = "application/json;charset=UTF-8",
        ["Origin"] = "https://weread.qq.com",
        ["Referer"] = opts.referer or "https://weread.qq.com/",
    }
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = "POST",
        headers = headers,
        body = self:json_encode(data),
    })
    if code and code >= 200 and code < 300 then
        return self:json_decode(text), code, resp_headers
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:get_text(url, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = opts.accept or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Referer"] = opts.referer or "https://weread.qq.com/",
    }
    if is_weread_url(url) then
        headers["Cookie"] = Cookie.to_header(cookies)
    end
    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = headers,
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie and is_weread_url(url) then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        return text
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:get_public_text(url, opts)
    opts = opts or {}
    local text, code, resp_headers = self:request_follow({
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = opts.accept or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Referer"] = opts.referer or "https://mp.weixin.qq.com/",
        },
    })
    if code and code >= 200 and code < 300 then
        return text, {
            code = code,
            content_type = header_value(resp_headers, "content-type"),
            length = #(text or ""),
            url = url,
        }
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:get_binary(url, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = opts.accept or "*/*",
        ["Referer"] = opts.referer or "https://weread.qq.com/",
    }
    if is_weread_url(url) then
        headers["Cookie"] = Cookie.to_header(cookies)
    end
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end
    local request_opts = {
        url = url,
        method = "GET",
        headers = headers,
    }
    local text, code, resp_headers = self:request_follow(request_opts)
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie and is_weread_url(request_opts.url) then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        return text, code, resp_headers
    end
    error(http_error(self, code, text, resp_headers))
end

-- Start a fresh WeRead QR login session and return its temporary UID.
-- The initial skills-page request establishes the same session cookies used by
-- WeRead's own login page.
function Client:begin_qr_login()
    local login_cookies = {}

    local _, page_code, page_headers = self:request_follow({
        url = SKILLS_PAGE_URL,
        method = "GET",
        timeout = 20,
        headers = {
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Referer"] = "https://weread.qq.com/",
        },
    })
    login_cookies = merge_response_cookies(login_cookies, page_headers)
    if not page_code or page_code < 200 or page_code >= 300 then
        error("Unable to open WeRead login page (HTTP " .. tostring(page_code) .. ")")
    end

    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = SKILLS_PAGE_URL,
    }
    local cookie_header = Cookie.to_header(login_cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end

    local text, code, resp_headers = self:request({
        url = LOGIN_UID_URL,
        method = "GET",
        timeout = 20,
        headers = headers,
    })
    login_cookies = merge_response_cookies(login_cookies, resp_headers)
    if not code or code < 200 or code >= 300 then
        error(http_error(self, code, text, resp_headers))
    end

    local data = self:json_decode(text)
    if type(data) ~= "table" or type(data.uid) ~= "string" or data.uid == "" then
        error("WeRead did not return a valid login UID")
    end

    self._qr_login_cookies = login_cookies
    return data.uid
end

-- Wait for the phone to scan/confirm the QR code. With an empty OTP, preserve
-- WeRead's exact query form: ...&otp (without an equals sign).
function Client:poll_qr_login(uid, otp)
    if type(uid) ~= "string" or uid == "" then
        error("Missing QR login UID")
    end

    local url = LOGIN_INFO_URL .. "?uid=" .. WeRead.urlencode(uid) .. "&otp"
    if type(otp) == "string" and otp ~= "" then
        url = url .. "=" .. WeRead.urlencode(otp)
    end

    local login_cookies = self._qr_login_cookies or {}
    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = SKILLS_PAGE_URL,
    }
    local cookie_header = Cookie.to_header(login_cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        timeout = QR_LOGIN_TIMEOUT_SECONDS,
        headers = headers,
    })
    self._qr_login_cookies = merge_response_cookies(login_cookies, resp_headers)
    if not code or code < 200 or code >= 300 then
        error(http_error(self, code, text, resp_headers))
    end

    local data = self:json_decode(text)
    if type(data) ~= "table" then
        error("WeRead returned an invalid QR login response")
    end
    return data
end

local function authenticated_get_json(client, url, cookies, web_login_vid, access_token)
    local text, code, resp_headers = client:request({
        url = url,
        method = "GET",
        timeout = 20,
        headers = {
            ["Accept"] = "application/json, text/plain, */*",
            ["Referer"] = SKILLS_PAGE_URL,
            ["Cookie"] = Cookie.to_header(cookies),
            ["X-Vid"] = web_login_vid,
            ["X-Skey"] = access_token,
        },
    })
    cookies = merge_response_cookies(cookies, resp_headers)
    if not code or code < 200 or code >= 300 then
        error(http_error(client, code, text, resp_headers))
    end
    local data = client:json_decode(text)
    if type(data) ~= "table" then
        error("WeRead returned an invalid JSON response")
    end
    return data, cookies
end

-- Convert a successful QR result into persistent Cookie/API-key settings.
-- Credentials are saved only after userInfo and apikeyGet both succeed.
function Client:complete_qr_login(login_result)
    if type(login_result) ~= "table" or login_result.succeed ~= true then
        error("QR login has not succeeded")
    end

    local web_login_vid = tostring(login_result.webLoginVid or "")
    local access_token = tostring(login_result.accessToken or "")
    local refresh_token = tostring(login_result.refreshToken or "")
    if web_login_vid == "" or access_token == "" then
        error("QR login response is missing account credentials")
    end

    local cookies = self.settings:get("cookies", {})
    for key, value in pairs(self._qr_login_cookies or {}) do
        cookies[key] = value
    end
    cookies.wr_vid = web_login_vid
    cookies.wr_skey = access_token
    cookies.wr_ql = "0"
    if refresh_token ~= "" then
        cookies.wr_rt = WeRead.urlencode(refresh_token)
    end

    local user_url = USER_INFO_URL .. "?userVid=" .. WeRead.urlencode(web_login_vid)
    local user_info
    user_info, cookies = authenticated_get_json(
        self, user_url, cookies, web_login_vid, access_token
    )

    local api_result
    api_result, cookies = authenticated_get_json(
        self, API_KEY_URL .. "?only_show=1", cookies, web_login_vid, access_token
    )
    local api_key = type(api_result.apikey) == "string" and api_result.apikey or ""
    if api_key == "" then
        -- only_show=1 reports an empty result for accounts that have never
        -- created a Skills API key. Calling the base endpoint creates it.
        api_result, cookies = authenticated_get_json(
            self, API_KEY_URL, cookies, web_login_vid, access_token
        )
        api_key = type(api_result.apikey) == "string" and api_result.apikey or ""
    end
    if api_key == "" then
        error("WeRead did not return an API key")
    end

    local account = {
        name = type(user_info.name) == "string" and user_info.name or "",
        user_vid = web_login_vid,
        login_method = "qr",
        login_time = os.time(),
    }
    self.settings:set("cookies", cookies)
    self.settings:set("api_key", api_key)
    self.settings:set("account", account)
    self.settings:flush()
    self._qr_login_cookies = nil

    return account
end

function Client:cancel_qr_login()
    self._qr_login_cookies = nil
end

function Client:renew_cookie()
    local result, code, resp_headers = self:post_json("https://weread.qq.com/web/login/renewal", {
        rq = "%2Fweb%2Fbook%2Fread",
        ql = false,
    })
    local changed = false
    local wr_ticket = scalar_header_value(resp_headers, "x-wr-ticket")
    if wr_ticket and wr_ticket ~= "" then
        self.settings:set("wr_ticket", wr_ticket)
        changed = true
    end
    local wr_wrpa = scalar_header_value(resp_headers, "x-wrpa-0")
    if wr_wrpa and wr_wrpa ~= "" then
        self.settings:set("wr_wrpa", wr_wrpa)
        changed = true
    end
    if changed then
        self.settings:flush()
    end
    return result, code, resp_headers
end

function Client:gateway(api_name, params)
    params = params or {}
    params.api_name = api_name
    params.skill_version = params.skill_version or WeRead.SKILL_VERSION
    local api_key = self.settings:get("api_key", "")
    if api_key == "" then
        error("WeRead API key is not configured")
    end
    return self:post_no_cookie("https://i.weread.qq.com/api/agent/gateway", params, {
        headers = {
            ["Authorization"] = "Bearer " .. api_key,
        },
    })
end

function Client:get_book_info(book_id)
    return self:gateway("/book/info", { bookId = book_id })
end

function Client:get_web_progress(book_id)
    local cookies = self.settings:get("cookies", {})
    local cookie_header = Cookie.to_header(cookies)
    if cookie_header == "" then
        error("WeRead cookie is not configured")
    end

    local url = "https://weread.qq.com/web/book/getProgress?bookId="
        .. WeRead.urlencode(book_id)
        .. "&_=" .. tostring(os.time())
    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = "application/json, text/plain, */*",
            ["Referer"] = WeRead.reader_url(book_id),
            ["Cookie"] = cookie_header,
            ["Cache-Control"] = "no-cache, no-store, max-age=0",
            ["Pragma"] = "no-cache",
        },
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if not code or code < 200 or code >= 300 then
        error(http_error(self, code, text, resp_headers))
    end
    local result = self:json_decode(text)
    if type(result) ~= "table" then
        error("web progress response is not a table")
    end
    local err_code = tonumber(result.errCode or result.errcode or result.code)
    if err_code and err_code ~= 0 then
        error("web progress error: " .. tostring(result.errMsg or result.errmsg or result.message or err_code))
    end
    result._progress_source = "web_cookie"
    result._progress_fetched_at = os.time()
    return result
end

function Client:get_agent_progress(book_id)
    local result = self:gateway("/book/getprogress", { bookId = book_id })
    if type(result) == "table" then
        result._progress_source = "agent_gateway"
        result._progress_fetched_at = os.time()
    end
    return result
end

function Client:get_progress(book_id)
    -- The mobile app's latest cross-device position is exposed by the official
    -- Agent Gateway. The web-cookie endpoint tracks a separate web-reader
    -- position and is intentionally reserved for diagnostics.
    local api_key = self.settings:get("api_key", "")
    if api_key == "" then
        error("WeRead official API key is not configured")
    end
    return self:get_agent_progress(book_id)
end

function Client:get_mp_articles(book_id, max_idx, count, wr_ticket)
    local url = "https://weread.qq.com/web/mp/articles?bookId="
        .. WeRead.urlencode(book_id)
        .. "&maxIdx=" .. tostring(max_idx or 0)
        .. "&count=" .. tostring(count or 100)
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = "https://weread.qq.com/",
        ["Cookie"] = Cookie.to_header(cookies),
    }
    if wr_ticket and wr_ticket ~= "" then
        headers["x-wr-ticket"] = wr_ticket
    end
    local wrpa = self.settings:get("wr_wrpa", "")
    if wrpa ~= "" then
        headers["x-wrpa-0"] = wrpa
    end
    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = headers,
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        local data = self:json_decode(text)
        if data.errCode and data.errCode ~= 0 then
            return nil, data.errCode
        end
        return data, nil
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:get_mp_content(review_id, opts)
    opts = opts or {}
    local url = "https://weread.qq.com/web/mp/content?reviewId="
        .. WeRead.urlencode(review_id)
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = "text/html,application/xhtml+xml,*/*",
        ["Referer"] = opts.referer or "https://weread.qq.com/",
        ["Cookie"] = Cookie.to_header(cookies),
    }
    if not opts.skip_mp_auth_headers then
        local wr_ticket = self.settings:get("wr_ticket", "")
        if wr_ticket ~= "" then
            headers["x-wr-ticket"] = wr_ticket
        end
        local wrpa = self.settings:get("wr_wrpa", "")
        if wrpa ~= "" then
            headers["x-wrpa-0"] = wrpa
        end
    end
    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = headers,
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        return text, {
            code = code,
            content_type = header_value(resp_headers, "content-type"),
            length = #(text or ""),
            url = url,
        }
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:report_read(payload, referer)
    return self:post_json("https://weread.qq.com/web/book/read", payload, {
        referer = referer or "https://weread.qq.com/",
    })
end

function Client:refresh_read_context(book_id)
    book_id = tostring(book_id or "")
    if book_id == "" then
        error("book_id is required to refresh reading context")
    end
    return self:post_json("https://weread.qq.com/web/book/chapterInfos", {
        bookIds = { book_id },
    }, {
        referer = "https://weread.qq.com/web/reader/" .. WeRead.urlencode(book_id),
    })
end

function Client:get_chapter_underlines(book_id, chapter_uid)
    if not book_id or tostring(book_id) == "" then
        return false, nil, "empty book_id"
    end
    if not chapter_uid then
        return false, nil, "empty chapter_uid"
    end

    local ok, result = pcall(function()
        return self:gateway("/book/underlines", {
            bookId = tostring(book_id),
            chapterUid = chapter_uid,
        })
    end)
    if not ok then
        return false, nil, tostring(result)
    end
    if type(result) ~= "table" then
        return false, nil, "underlines: gateway returned non-table"
    end
    return true, result
end

function Client:build_chapter_review_batches(ranges)
    local BATCH_SIZE = 5
    local batches = {}
    for batch_start = 1, #(ranges or {}), BATCH_SIZE do
        local batch = {}
        for index = batch_start, math.min(batch_start + BATCH_SIZE - 1, #ranges) do
            batch[#batch + 1] = {
                range = ranges[index],
                maxIdx = 0,
                count = 30,
                synckey = 0,
            }
        end
        batches[#batches + 1] = batch
    end
    return batches
end

function Client:get_chapter_reviews_batch(book_id, chapter_uid, batch)
    if not book_id or tostring(book_id) == "" then
        return false, nil, "empty book_id"
    end
    if not chapter_uid then
        return false, nil, "empty chapter_uid"
    end
    if type(batch) ~= "table" or #batch == 0 then
        return true, { reviews = {} }
    end

    local ok, result = pcall(function()
        return self:gateway("/book/readreviews", {
            bookId = tostring(book_id),
            chapterUid = chapter_uid,
            reviews = batch,
        })
    end)
    if not ok then
        return false, nil, tostring(result)
    end
    if type(result) ~= "table" or type(result.reviews) ~= "table" then
        return false, nil, "readreviews: gateway returned invalid data"
    end
    return true, result
end

function Client:get_chapter_reviews(book_id, chapter_uid, ranges)
    if type(ranges) ~= "table" or #ranges == 0 then
        return true, { reviews = {} }
    end

    local all_reviews = {}
    local batches = self:build_chapter_review_batches(ranges)
    local socket_ok, socket = pcall(require, "socket")

    for batch_index, batch in ipairs(batches) do
        local ok, result = self:get_chapter_reviews_batch(book_id, chapter_uid, batch)
        if ok and type(result) == "table" and type(result.reviews) == "table" then
            for _i, review in ipairs(result.reviews) do
                all_reviews[#all_reviews + 1] = review
            end
        end

        if batch_index < #batches and socket_ok and socket.sleep then
            socket.sleep(0.3)
        end
    end

    return true, { reviews = all_reviews }
end

return Client
