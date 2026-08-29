local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local ok_http, http = pcall(require, "socket.http")
local ok_https, https = pcall(require, "ssl.https")
local ok_socket, socket = pcall(require, "socket")
local ok_url, url_module = pcall(require, "socket.url")
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

-- Connection reuse ----------------------------------------------------------
-- socket.http and ssl.https open a fresh TCP+TLS connection for every request
-- and close it again afterwards. One chapter needs four sequential requests to
-- the same host, so on slow e-ink hardware the handshakes cost more than the
-- transfers do. Both transports accept a `create` hook that supplies the
-- connection object, which lets the socket from the previous request be handed
-- back instead of a new one. This removes handshakes only: request pacing,
-- ordering and the shared rate-limit budget are untouched.
--
-- Reuse is deliberately conservative. A socket returns to the pool only when
-- the response carried a self-delimiting body, the peer did not ask for a
-- close, and LuaSocket did not restart the exchange internally. Every other
-- outcome closes the socket, which is exactly the previous behaviour.

local KEEPALIVE_IDLE_SECONDS = 25
local KEEPALIVE_MAX_REUSE = 64

local function url_endpoint(url)
    local scheme, authority = tostring(url or ""):match("^(https?)://([^/]+)")
    if not scheme then return nil end
    local host, port = authority:match("^(.-):(%d+)$")
    host = host or authority
    if host == "" then return nil end
    return scheme, host:lower(), tonumber(port) or (scheme == "https" and 443 or 80)
end

-- ssl.https rewrites the request URL so the default port is explicit, which is
-- what puts "host:443" in the Host header. Driving socket.http directly has to
-- reproduce that, otherwise the request goes out subtly differently.
local function explicit_port_url(url, port)
    if not (ok_url and url_module and type(url_module.parse) == "function"
        and type(url_module.build) == "function") then
        return nil
    end
    local built, parsed = pcall(url_module.parse, url, {port = port})
    if not built or type(parsed) ~= "table" then return nil end
    local ok_build, value = pcall(url_module.build, parsed)
    if not ok_build or type(value) ~= "string" or value == "" then return nil end
    return value
end

local function apply_socket_timeouts(conn)
    if not conn or type(conn.settimeout) ~= "function" then return end
    pcall(conn.settimeout, conn, tonumber(socketutil.block_timeout) or 15, "b")
    pcall(conn.settimeout, conn, tonumber(socketutil.total_timeout) or 35, "t")
end

-- A pooled socket the peer closed while it was idle becomes readable at once.
-- Nothing is expected on an idle connection, so anything readable - a FIN or
-- unread leftovers - means the socket cannot carry another request.
local function connection_is_stale(conn)
    if not conn then return true end
    if not (ok_socket and socket and type(socket.select) == "function") then return false end
    local called, readable = pcall(socket.select, {conn}, nil, 0)
    if not called then return true end
    return type(readable) == "table" and next(readable) ~= nil
end

local function open_connection(scheme, host, port, force_ipv4)
    local previous_tcp
    if force_ipv4 then
        if not (ok_socket and socket and type(socket.tcp4) == "function") then
            return nil, "IPv4 socket unavailable"
        end
        -- LuaSec builds its transport from socket.tcp, so the existing IPv4
        -- override is the only way to reach the same family selection here.
        previous_tcp = socket.tcp
        socket.tcp = ipv4_tcp_factory
    end

    local conn, err
    if scheme == "https" then
        local factory_ok, factory = pcall(https.tcp, {})
        if factory_ok and type(factory) == "function" then
            local created, value = pcall(factory)
            if created then conn = value else err = value end
        else
            err = factory_ok and "LuaSec create hook unavailable" or factory
        end
    elseif force_ipv4 then
        conn, err = ipv4_tcp_factory()
    else
        local created, value = pcall(socket.tcp)
        if created then conn = value else err = value end
    end

    if conn then
        apply_socket_timeouts(conn)
        local called, result, connect_error = pcall(conn.connect, conn, host, port)
        if not called then
            err = result
        elseif result == nil then
            err = connect_error or "connect failed"
        end
        if err then
            pcall(conn.close, conn)
            conn = nil
        else
            -- LuaSec swaps in the TLS socket during connect and only then
            -- exposes its methods, so the timeouts have to be applied again.
            apply_socket_timeouts(conn)
        end
    end

    if previous_tcp then socket.tcp = previous_tcp end
    if not conn then return nil, tostring(err or "connection failed") end
    return conn
end

-- The object handed to socket.http through `create`. It looks like a socket to
-- LuaSocket while keeping ownership of the underlying connection: close() only
-- marks the exchange finished, and Http:_keepalive_finish decides afterwards
-- whether the socket is clean enough to serve another request.
local KeepaliveMethods = {}

local Keepalive_mt = {
    __index = function(session, key)
        local method = KeepaliveMethods[key]
        if method then return method end
        local conn = rawget(session, "conn")
        local target = conn and conn[key]
        if type(target) ~= "function" then return nil end
        return function(_, ...) return target(conn, ...) end
    end,
}

function KeepaliveMethods:_drop()
    local conn = rawget(self, "conn")
    self.conn = nil
    self.reused = false
    if conn then pcall(conn.close, conn) end
end

function KeepaliveMethods:settimeout(...)
    local conn = rawget(self, "conn")
    if not conn or type(conn.settimeout) ~= "function" then return 1 end
    return conn:settimeout(...)
end

function KeepaliveMethods:connect(host, port)
    -- socket.http passes the port through from the parsed URL, where it is a
    -- string. The pool compares it against a number, so normalise first.
    port = tonumber(port) or port
    self.hops = self.hops + 1
    -- A second connect inside one request means LuaSocket restarted the
    -- exchange for an internal redirect. It abandoned the previous response
    -- without reading the body, so that socket can only be replaced.
    if self.hops > 1 then self:_drop() end
    if rawget(self, "conn") and not self.dirty and self.host == host and self.port == port then
        apply_socket_timeouts(self.conn)
        self.reused = true
        return 1
    end
    self:_drop()
    local conn, err = open_connection(self.scheme, host, port, self.force_ipv4)
    if not conn then return nil, tostring(err) end
    self.conn, self.host, self.port = conn, host, port
    self.dirty, self.reused, self.uses = false, false, 0
    return 1
end

function KeepaliveMethods:close()
    self.dirty = true
    return 1
end

function KeepaliveMethods:send(...)
    local conn = rawget(self, "conn")
    if not conn then return nil, "closed" end
    local sent, err, last = conn:send(...)
    if sent then self.sent_ok = true end
    return sent, err, last
end

function KeepaliveMethods:receive(...)
    local conn = rawget(self, "conn")
    if not conn then return nil, "closed" end
    local data, err, partial = conn:receive(...)
    if data ~= nil or (partial ~= nil and #partial > 0) then self.received_any = true end
    return data, err, partial
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

-- Instrumentation. The counters answer the only question an A/B download run
-- needs: how much of the elapsed time was handshakes, transfers, or deliberate
-- pacing, and how many connections the run actually had to open.
function Http:_stats()
    local stats = self.stats
    if not stats then
        stats = {
            requests = 0, connections_opened = 0, connections_reused = 0,
            network_seconds = 0, pacing_seconds = 0, rate_limit_seconds = 0,
            bytes = 0,
        }
        self.stats = stats
    end
    return stats
end

function Http:stats_snapshot()
    local copy = {}
    for key, value in pairs(self:_stats()) do copy[key] = value end
    return copy
end

function Http:_sleep_accounted(seconds, field)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then return end
    local stats = self:_stats()
    stats[field] = (stats[field] or 0) + seconds
    pause(seconds)
end

function Http:set_download_network_policy(options)
    self.network_policy = NetworkPolicy:new(options or {})
    return self.network_policy
end

-- Hands out a reusable connection for `url`, taking the socket left over by
-- the previous request to the same origin when one is still usable. Returns
-- nil whenever reuse does not apply, which keeps the caller on the stock
-- one-connection-per-request path.
function Http:_keepalive_begin(url, opt, force_ipv4, sink_path)
    if Config.HTTP_KEEPALIVE == false then return nil end
    if opt and opt.keepalive == false then return nil end
    -- Streaming downloads write straight into a file and are large enough that
    -- the handshake is noise; leaving them out keeps the replay below simple.
    if tostring(sink_path or "") ~= "" then return nil end
    if not is_weread_url(url) then return nil end
    local scheme, host, port = url_endpoint(url)
    if not scheme then return nil end
    -- ssl.https rejects a request table that already carries a create hook
    -- ("create function not permitted"), so a reused TLS connection has to be
    -- driven through socket.http directly. That is what ssl.https does
    -- internally anyway: it only installs the TLS-aware create and forwards.
    -- ssl.https.tcp builds exactly that connection, with LuaSec's own defaults,
    -- so the TLS parameters stay identical to the non-pooled path.
    local transport_url
    if scheme == "https" then
        local usable = ok_https and https and type(https.tcp) == "function"
            and ok_http and http and type(http.request) == "function"
        if usable then transport_url = explicit_port_url(url, port) end
        if not transport_url then
            if not self.keepalive_unavailable_logged then
                self.keepalive_unavailable_logged = true
                logger.warn("[MiuRead][HTTP] connection reuse unavailable for TLS",
                    "luasec_tcp=", tostring(ok_https and https and type(https.tcp) == "function"),
                    "socket_url=", tostring(ok_url and url_module ~= nil))
            end
            return nil
        end
    elseif not (ok_socket and socket and type(socket.tcp) == "function") then
        return nil
    end

    force_ipv4 = force_ipv4 == true
    local key = scheme .. "://" .. host .. (force_ipv4 and "#4" or "#a")
    local pool = self.keepalive_pool
    if not pool then pool = {}; self.keepalive_pool = pool end
    local entry = pool[key]
    pool[key] = nil
    if entry and (clock_now() - (tonumber(entry.idle_since) or 0) > KEEPALIVE_IDLE_SECONDS
        or connection_is_stale(entry.conn)) then
        pcall(entry.conn.close, entry.conn)
        entry = nil
    end
    return setmetatable({
        scheme = scheme, force_ipv4 = force_ipv4, key = key,
        conn = entry and entry.conn or nil,
        host = entry and entry.host or nil,
        port = entry and entry.port or port,
        uses = entry and tonumber(entry.uses) or 0,
        pooled = entry ~= nil,
        transport_url = transport_url,
        dirty = false, hops = 0, reused = false,
        sent_ok = false, received_any = false,
    }, Keepalive_mt)
end

-- Decides after the exchange whether the socket may serve another request. The
-- response must have been complete and self-delimiting, otherwise the next
-- request would start reading in the middle of this one.
function Http:_keepalive_finish(session, called, code, headers, status, stream_error)
    if not session then return end
    local conn = rawget(session, "conn")
    if not conn then return end

    local reusable = called == true and tonumber(code) ~= nil
        and session.hops == 1 and not stream_error
    if reusable then
        local numeric = tonumber(code)
        local version = tostring(status or ""):match("^HTTP/(%d+%.%d+)") or "1.1"
        local connection = tostring(hget(headers, "connection") or ""):lower()
        local encoding = tostring(hget(headers, "transfer-encoding") or ""):lower()
        local delimited = hget(headers, "content-length") ~= nil
            or encoding:find("chunked", 1, true) ~= nil
            or numeric == 204 or numeric == 304
        if connection:find("close", 1, true) then
            reusable = false
        elseif version == "1.0" and not connection:find("keep-alive", 1, true) then
            reusable = false
        elseif not delimited then
            reusable = false
        elseif session.uses + 1 >= KEEPALIVE_MAX_REUSE then
            reusable = false
        end
    end
    if not reusable then return session:_drop() end

    session.uses = session.uses + 1
    local pool = self.keepalive_pool
    if not pool then pool = {}; self.keepalive_pool = pool end
    -- Every download stage is serial, so one idle socket per origin is enough.
    local previous = pool[session.key]
    if previous and previous.conn ~= conn then pcall(previous.conn.close, previous.conn) end
    pool[session.key] = {
        conn = conn, host = session.host, port = session.port,
        uses = session.uses, idle_since = clock_now(),
    }
    session.conn = nil
end

function Http:close_idle_connections()
    local pool = self.keepalive_pool
    if not pool then return end
    self.keepalive_pool = {}
    for _, entry in pairs(pool) do
        if entry and entry.conn then pcall(entry.conn.close, entry.conn) end
    end
end

function Http:_transport_request(transport, request, force_ipv4, keepalive)
    if keepalive then request.create = function() return keepalive end end
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

function Http:probe_download_recovery()
    -- This runs only after the route was lost, so nothing in the pool can have
    -- survived. Drop the sockets before probing rather than reusing a dead one.
    self:close_idle_connections()
    local policy=self.network_policy
    local base=probe_origin(self.last_request_url) or "https://weread.qq.com/"
    local mode=policy and policy:current_mode() or "auto"

    if mode=="ipv4" then
        local elapsed,code=self:_probe_once(base,true)
        return elapsed~=nil,{mode="ipv4",seconds=elapsed,code=code}
    end

    local auto_elapsed,auto_code=self:_probe_once(base,false)
    if auto_elapsed~=nil then
        return true,{mode="auto",seconds=auto_elapsed,code=auto_code}
    end

    local ipv4_elapsed,ipv4_code=self:_probe_once(base,true)
    if ipv4_elapsed~=nil then
        local detail={
            recovery_ipv4=true, ipv4_only=true, ipv4_seconds=ipv4_elapsed,
            ipv4_code=ipv4_code, auto_unavailable=true,
        }
        if policy and not policy.suggestion_suppressed and not policy.suggestion_sent then
            policy.suggestion_sent=true
            if type(self.on_network_suggestion)=="function" then
                local ok,err=pcall(self.on_network_suggestion,detail)
                if not ok then logger.warn("[MiuRead][NetworkPolicy] recovery suggestion callback failed",tostring(err)) end
            end
        end
        return false,detail
    end
    return false,{mode="offline",auto_unavailable=true,ipv4_unavailable=true}
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
    -- A cooldown outlasts any server-side keep-alive window, so the pooled
    -- sockets are certain to be dead by the time the wait ends.
    self:close_idle_connections()
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
        self:_sleep_accounted(math.min(1, remaining), "rate_limit_seconds")
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
    if wait > 0 then self:_sleep_accounted(wait, "pacing_seconds") end
    if self:_cancelled() then error("download cancelled") end
    if opt.shared_pacing==true then
        local shared_wait=self:_reserve_shared_pacing(scope,interval,opt.pacing_jitter)
        if shared_wait>0 then self:_sleep_accounted(shared_wait, "pacing_seconds") end
    elseif tonumber(opt.pacing_jitter or 0)>0 then
        self:_sleep_accounted(math.random()*tonumber(opt.pacing_jitter), "pacing_seconds")
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
        local saved,save_error=self.store:save_auth(auth)
        if saved==true then
            logger.info("[MiuRead][HTTP] removed temporary cookies from saved login",
                "names=", table.concat(Cookies.names(jar), ","))
        else
            logger.warn("[MiuRead][HTTP] cookie cleanup not persisted",Util.first_line(save_error or "unknown",160))
        end
    end
    return jar
end

function Http:_save_response_auth(headers, set_cookie, expected_login_session_id, expected_auth_revision)
    local ticket=hget(headers,"x-wr-ticket")
    local wrpa=hget(headers,"x-wrpa-0")
    local auth=self.store:auth()
    if tostring(expected_login_session_id or "")~=""
        and tostring(auth.login_session_id or "")~=tostring(expected_login_session_id or "") then
        logger.warn("[MiuRead][HTTP] stale authentication response ignored","reason=login_session_changed")
        return false
    end
    local current_revision=math.max(0,tonumber(auth.auth_revision or 0) or 0)
    if expected_auth_revision~=nil and current_revision~=tonumber(expected_auth_revision) then
        logger.warn("[MiuRead][HTTP] stale authentication response ignored","reason=credential_revision_changed")
        return false
    end
    local candidate=Util.copy(auth)
    local changed=false
    if set_cookie~=nil then
        local merged=Cookies.absorb(candidate.cookies or {},set_cookie,{protect_core=true})
        merged=Cookies.sanitize(merged)
        if not Cookies.same(candidate.cookies or {},merged) then candidate.cookies=merged; changed=true end
    end
    if ticket~=nil and tostring(ticket)~="" and tostring(candidate.wr_ticket or "")~=tostring(ticket) then
        candidate.wr_ticket=tostring(ticket); changed=true
    end
    if wrpa~=nil and tostring(wrpa)~="" and tostring(candidate.wr_wrpa or "")~=tostring(wrpa) then
        candidate.wr_wrpa=tostring(wrpa); changed=true
    end
    if not changed then return false end
    if (ticket~=nil and tostring(ticket)~="") or (wrpa~=nil and tostring(wrpa)~="") then
        candidate.ticket_updated_at=os.time()
    end
    local saved,save_error=self.store:save_auth(candidate,{expected_revision=current_revision})
    if saved~=true then
        logger.warn("[MiuRead][HTTP] response credentials not persisted",Util.first_line(save_error or "unknown",160))
        return false
    end
    logger.info("[MiuRead][HTTP] response credentials merged",
        "cookies=",tostring(set_cookie~=nil),"ticket=",tostring(ticket~=nil and tostring(ticket)~=""),
        "wrpa=",tostring(wrpa~=nil and tostring(wrpa)~=""))
    return true
end

local function response_allows_auth_persist(code,text)
    code=tonumber(code)
    if not code or code<200 or code>=300 then return false end
    text=tostring(text or "")
    if #text==0 or #text>65536 then return true end
    local first=text:match("^%s*(.)")
    if first~="{" and first~="[" then return true end
    local ok,value=pcall(Json.decode,text)
    if not ok or type(value)~="table" then return true end
    local err=value.errCode or value.errcode or value.errorCode or value.error_code
    if err~=nil then
        local n=tonumber(err)
        if (n and n~=0) or (not n and tostring(err)~="" and tostring(err)~="0") then return false end
    end
    local service_code=value.code
    if service_code~=nil then
        local n=tonumber(service_code)
        if n and n<0 then return false end
    end
    if value.succ==false or tostring(value.succ or "")=="0" then return false end
    return true
end

function Http:_request_once(opt)
    local redirects = tonumber(opt.redirects) or 5
    local current = assert(opt.url, "url required")
    self.last_request_url=current
    local method = opt.method or (opt.body and "POST" or "GET")
    local body = opt.body
    local auth_snapshot=self.store:auth()
    local request_login_session_id=tostring(auth_snapshot.login_session_id or "")
    local request_auth_revision=math.max(0,tonumber(auth_snapshot.auth_revision or 0) or 0)
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
        local chunks, preview = {}, {}
        local preview_bytes, total_bytes = 0, 0
        local sink_path=tostring(opt.sink_path or "")
        local stream_file,stream_error
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
        if sink_path~="" then
            local parent=sink_path:match("^(.*)/[^/]+$")
            if parent and parent~="" then Util.mkdir(parent) end
            stream_file,stream_error=io.open(sink_path,"wb")
            if not stream_file then
                socketutil:reset_timeout()
                return nil,nil,nil,current,"download sink open failed: "..tostring(stream_error or sink_path)
            end
        end
        local first_data_at
        local request_started=clock_now()
        local last_chunk_report_at=request_started
        local last_chunk_report_bytes=0
        local heartbeat_seconds=math.max(1,tonumber(opt.heartbeat_seconds)
            or tonumber(Config.DOWNLOAD_TRANSFER_HEARTBEAT_SECONDS) or 3)
        local heartbeat_bytes=math.max(64*1024,tonumber(opt.heartbeat_bytes)
            or tonumber(Config.DOWNLOAD_TRANSFER_HEARTBEAT_BYTES) or 512*1024)
        local sink=function(chunk,err)
            if chunk then
                if not first_data_at then first_data_at=clock_now() end
                total_bytes=total_bytes+#chunk
                if stream_file then
                    local wrote,write_error=stream_file:write(chunk)
                    if not wrote then
                        stream_error=write_error or "download sink write failed"
                        return nil,stream_error
                    end
                    if preview_bytes<32768 then
                        local part=chunk:sub(1,32768-preview_bytes)
                        preview[#preview+1]=part
                        preview_bytes=preview_bytes+#part
                    end
                else
                    chunks[#chunks+1]=chunk
                end
                if type(opt.on_chunk)=="function" then
                    local current_time=clock_now()
                    if total_bytes-last_chunk_report_bytes>=heartbeat_bytes
                        or current_time-last_chunk_report_at>=heartbeat_seconds then
                        last_chunk_report_at=current_time
                        last_chunk_report_bytes=total_bytes
                        pcall(opt.on_chunk,total_bytes,current)
                    end
                end
            end
            return 1
        end
        local force_ipv4=self.network_policy and self.network_policy:should_force_ipv4() or false
        local keepalive=self:_keepalive_begin(current,opt,force_ipv4,sink_path)
        local request_url,request_port=current,nil
        if keepalive and keepalive.scheme=="https" then
            -- ssl.https would refuse the create hook, so drive socket.http with
            -- the URL and port ssl.https would have produced for it.
            transport=http
            request_url=keepalive.transport_url
            request_port=keepalive.port
        end
        headers["Connection"]=keepalive and "keep-alive" or nil
        local called, ok, code, resp_headers, status
        local transport_started=clock_now()
        for attempt = 1, 2 do
            called, ok, code, resp_headers, status = self:_transport_request(transport, {
                url = request_url,
                port = request_port,
                method = method,
                headers = headers,
                source = body and ltn12.source.string(body) or nil,
                sink = sink,
            }, force_ipv4, keepalive)
            if attempt > 1 or (called and tonumber(code)) then break end
            -- A pooled socket the peer closed between requests fails before the
            -- response starts. Nothing was delivered, so replaying it once is
            -- safe; for a write only while the request itself never got out.
            local replayable = keepalive ~= nil and keepalive.reused == true
                and keepalive.received_any ~= true and total_bytes == 0
                and (method == "GET" or method == "HEAD" or keepalive.sent_ok ~= true)
            if not replayable then break end
            logger.info("[MiuRead][HTTP] reused connection closed by peer; retrying on a new socket",
                "url=", Util.redact_url(current))
            keepalive:_drop()
            keepalive.hops, keepalive.pooled, keepalive.sent_ok = 0, false, false
            chunks, first_data_at = {}, nil
        end
        local request_finished=clock_now()
        local stats=self:_stats()
        stats.requests=stats.requests+1
        stats.network_seconds=stats.network_seconds+math.max(0,request_finished-transport_started)
        stats.bytes=stats.bytes+total_bytes
        if keepalive and keepalive.reused==true then
            stats.connections_reused=stats.connections_reused+1
        else
            stats.connections_opened=stats.connections_opened+1
        end
        if stream_file then
            local flushed,flush_error=stream_file:flush()
            stream_file:close()
            stream_file=nil
            if flushed==nil and not stream_error then stream_error=flush_error or "download sink flush failed" end
        end
        if type(opt.on_chunk)=="function" and total_bytes>last_chunk_report_bytes then
            pcall(opt.on_chunk,total_bytes,current)
        end
        socketutil:reset_timeout()
        self:_keepalive_finish(keepalive,called,code,resp_headers,status,stream_error)
        local text = sink_path~="" and table.concat(preview) or table.concat(chunks)
        if stream_error then return text,nil,resp_headers,current,tostring(stream_error) end
        if not called then return text, nil, resp_headers, current, tostring(ok) end
        code = tonumber(code)
        if code and self.network_policy then
            local response_delay=(first_data_at or request_finished)-request_started
            self:_observe_download_network(current,response_delay,code)
        end
        if not code then
            self.last_request_url=current
            return text, nil, resp_headers, current, tostring(status or ok)
        end

        local set_cookie = hget(resp_headers, "set-cookie")
        if set_cookie and opt.auth ~= false then
            jar = Cookies.absorb(jar, set_cookie, {protect_core=true})
            headers["Cookie"] = Cookies.header(jar)
        end
        if opt.auth ~= false and is_weread_url(current) and opt.defer_auth_persist~=true
            and response_allows_auth_persist(code,text) then
            local persisted=self:_save_response_auth(resp_headers,set_cookie,request_login_session_id,request_auth_revision)
            -- Only this exact request may advance its redirect-chain revision.
            -- If another request won the race, keep the old revision so every
            -- later response from this chain remains stale and cannot write back.
            if persisted==true then
                request_auth_revision=math.max(0,tonumber(self.store:auth().auth_revision or request_auth_revision) or request_auth_revision)
            end
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
            self.last_request_url=current
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
            local retry_delay=math.min(2.5, 0.35 * (2 ^ (attempt - 1)))
            if type(opt.on_retry)=="function" then
                local retry_detail={
                    attempt=attempt, next_attempt=attempt+1, maximum=retries+1,
                    url=Util.redact_url(url or opt.url), code=tonumber(code),
                    error=tostring(err or ""), wait_seconds=retry_delay,
                }
                local cb_ok,cb_err=pcall(opt.on_retry,retry_detail)
                if not cb_ok then logger.warn("[MiuRead][HTTP] retry callback failed",tostring(cb_err)) end
            end
            logger.warn("[MiuRead][HTTP] retry", "attempt=", tostring(attempt), "url=", Util.redact_url(url or opt.url),
                "status=", tostring(code or err or "network"))
            pause(retry_delay)
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
    local out = "登录凭证需要更新 " .. AUTH_ERROR_MARKER .. " error_code=" .. tostring(code or "unknown")
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

-- Large chapter image archives must never be assembled as one Lua string on
-- low-memory Kindles. The normal request path still owns cookies, redirects,
-- retry pacing and IPv4 compatibility; only the response sink changes.
function Http:download_to_file(url,path,opt)
    path=tostring(path or "")
    if path=="" then error("download target path required") end
    local request_opt={}
    for key,value in pairs(opt or {}) do request_opt[key]=value end
    request_opt.url=url
    request_opt.method=request_opt.method or "GET"
    request_opt.sink_path=path
    if request_opt.retries==nil then request_opt.retries=3 end
    os.remove(path)
    local called,preview,code,headers,final=pcall(self.request,self,request_opt)
    if not called then
        os.remove(path)
        error(preview)
    end
    if not code or code<200 or code>=300 then
        os.remove(path)
        error("download HTTP "..tostring(code))
    end
    local size=Util.file_size(path)
    if not size or size<=0 then
        os.remove(path)
        error("download returned empty content")
    end
    local expected=tonumber(hget(headers,"content-length") or "")
    if expected and expected>=0 and size~=expected then
        os.remove(path)
        local attempt=math.max(1,tonumber(request_opt._integrity_attempt) or 1)
        local maximum=math.max(1,tonumber(request_opt.integrity_attempts) or 2)
        logger.warn("[MiuRead][HTTP] streamed download length mismatch",
            "url=",Util.redact_url(url),"expected=",tostring(expected),"received=",tostring(size),
            "attempt=",tostring(attempt),"maximum=",tostring(maximum))
        if attempt<maximum then
            request_opt._integrity_attempt=attempt+1
            return self:download_to_file(url,path,request_opt)
        end
        error("download incomplete: expected "..tostring(expected).." bytes, received "..tostring(size))
    end
    return path,headers,final,{length=size,expected_length=expected,preview=preview}
end

Http.auth_error_code = auth_error_code
Http.auth_error_message = auth_error_message
Http.is_auth_error = is_auth_error
Http.is_forbidden_error = is_forbidden_error
Http.is_network_error = is_network_error
Http.is_rate_limit_error = is_rate_limit_error

return Http
