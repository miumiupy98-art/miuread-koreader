--[[--
书摘卡片局域网临时传输。

只在用户主动打开“手机扫码保存”页面时监听一个随机本地端口，
手机通过同一路由器直接从阅读器取得当前 PNG。模块不申请任何后台
保活，不参与下载/同步任务；调用 stop() 后监听地址立即失效。
--]]--

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local U = require("miuread.util")

local ok_socket, socket = pcall(require, "socket")

local M = {}
local active
local generation = 0

local function now()
    if ok_socket and socket and type(socket.gettime) == "function" then
        return socket.gettime()
    end
    return os.time()
end

local function close_socket(sock)
    if sock then pcall(sock.close, sock) end
end

local function is_kindle()
    local fn = Device and Device.isKindle
    if type(fn) ~= "function" then return false end
    local ok, yes = pcall(fn, Device)
    return ok and yes == true
end

local function shell_ok(command)
    local ok, a, _, code = pcall(os.execute, command)
    if not ok then return false, tostring(a or "execute failed") end
    if a == true then return code == nil or tonumber(code) == 0, tostring(code or "") end
    if type(a) == "number" then return a == 0, tostring(a) end
    return false, tostring(a or "unknown")
end

local function kindle_firewall_rule(action, direction, port)
    port = tonumber(port)
    if not port or port < 1 or port > 65535 then return false, "invalid port" end
    local command
    if direction == "INPUT" then
        command = string.format(
            "iptables -%s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
            action, port)
    else
        command = string.format(
            "iptables -%s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT",
            action, port)
    end
    return shell_ok(command)
end

local function open_kindle_firewall(port)
    if not is_kindle() then return true, false end
    local input_ok, input_err = kindle_firewall_rule("A", "INPUT", port)
    if not input_ok then
        logger.warn("[MiuRead][BookExcerpt] Kindle firewall open failed",
            "direction=INPUT", "port=", tostring(port), "error=", tostring(input_err or ""))
        return false, "INPUT"
    end
    local output_ok, output_err = kindle_firewall_rule("A", "OUTPUT", port)
    if not output_ok then
        kindle_firewall_rule("D", "INPUT", port)
        logger.warn("[MiuRead][BookExcerpt] Kindle firewall open failed",
            "direction=OUTPUT", "port=", tostring(port), "error=", tostring(output_err or ""))
        return false, "OUTPUT"
    end
    logger.info("[MiuRead][BookExcerpt] Kindle firewall opened", "port=", tostring(port))
    return true, true
end

local function close_kindle_firewall(port, opened)
    if not opened or not is_kindle() then return true end
    local input_ok = kindle_firewall_rule("D", "INPUT", port)
    local output_ok = kindle_firewall_rule("D", "OUTPUT", port)
    logger.info("[MiuRead][BookExcerpt] Kindle firewall closed",
        "port=", tostring(port), "input=", tostring(input_ok), "output=", tostring(output_ok))
    return input_ok and output_ok
end

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err or "open failed" end
    local data = f:read("*a")
    f:close()
    if type(data) ~= "string" or data == "" then return nil, "empty image" end
    return data
end

local function html_escape(value)
    return tostring(value or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;")
end

local function valid_ipv4(ip)
    ip = tostring(ip or "")
    if ip == "" or ip == "0.0.0.0" or ip == "127.0.0.1" then return false end
    if not ip:match("^%d+%.%d+%.%d+%.%d+$") then return false end
    return true
end

local function ip_from_udp()
    if not (ok_socket and socket and type(socket.udp) == "function") then return nil end
    local ok_udp, udp = pcall(socket.udp)
    if not ok_udp or not udp then return nil end
    pcall(udp.settimeout, udp, 0)
    -- UDP setpeername only asks the kernel which route would be used; it does
    -- not need a successful Internet request and does not transmit card data.
    local ok = pcall(udp.setpeername, udp, "1.1.1.1", 53)
    local ip
    if ok then
        local good, value = pcall(udp.getsockname, udp)
        if good then ip = value end
    end
    close_socket(udp)
    return valid_ipv4(ip) and ip or nil
end

local function command_output(command)
    local ok, pipe = pcall(io.popen, command, "r")
    if not ok or not pipe then return "" end
    local read_ok, data = pcall(pipe.read, pipe, "*a")
    pcall(pipe.close, pipe)
    return read_ok and (data or "") or ""
end

local function ip_from_system()
    local route = command_output("ip -4 route get 1.1.1.1 2>/dev/null")
    local ip = route:match("%ssrc%s+(%d+%.%d+%.%d+%.%d+)")
    if valid_ipv4(ip) then return ip end

    local addr = command_output("ip -4 addr 2>/dev/null")
    for candidate in addr:gmatch("inet%s+(%d+%.%d+%.%d+%.%d+)") do
        if valid_ipv4(candidate) then return candidate end
    end

    local ifconfig = command_output("ifconfig 2>/dev/null")
    for candidate in ifconfig:gmatch("inet addr:(%d+%.%d+%.%d+%.%d+)") do
        if valid_ipv4(candidate) then return candidate end
    end
    for candidate in ifconfig:gmatch("inet%s+(%d+%.%d+%.%d+%.%d+)") do
        if valid_ipv4(candidate) then return candidate end
    end
    return nil
end

local function local_ipv4()
    local wifi_off = false
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and type(NetworkMgr.isWifiOn) == "function" then
        local ok, on = pcall(NetworkMgr.isWifiOn, NetworkMgr)
        wifi_off = ok and on == false
    end
    -- Prefer the actual route/IP over NetworkMgr's cached flag. Some Kindle/Kobo
    -- builds update that flag slightly later than the interface itself.
    local ip = ip_from_udp() or ip_from_system()
    if ip then return ip end
    if wifi_off then return nil, "阅读器尚未连接 Wi-Fi" end
    return nil, "无法取得阅读器的局域网地址"
end

local alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
local function random_token(length)
    local out = {}
    length = math.max(8, math.floor(tonumber(length) or 24))

    -- Prefer the device entropy source so a temporary LAN URL is not predictable.
    local random_bytes
    local f = io.open("/dev/urandom", "rb")
    if f then
        random_bytes = f:read(length)
        f:close()
    end
    if type(random_bytes) == "string" and #random_bytes == length then
        for i = 1, length do
            local n = (random_bytes:byte(i) % #alphabet) + 1
            out[i] = alphabet:sub(n, n)
        end
        return table.concat(out)
    end

    -- Very old/non-POSIX ports may not expose /dev/urandom; keep a harmless
    -- compatibility fallback. The URL is short-lived and LAN-only.
    for i = 1, length do
        local n = math.random(1, #alphabet)
        out[i] = alphabet:sub(n, n)
    end
    return table.concat(out)
end

local function response_header(status, content_type, content_length, extra)
    local lines = {
        "HTTP/1.1 " .. status,
        "Content-Type: " .. content_type,
        "Content-Length: " .. tostring(content_length or 0),
        "Cache-Control: no-store, no-cache, must-revalidate",
        "Pragma: no-cache",
        "Connection: close",
        "X-Content-Type-Options: nosniff",
    }
    if extra then
        for _, line in ipairs(extra) do lines[#lines + 1] = line end
    end
    return table.concat(lines, "\r\n") .. "\r\n\r\n"
end

local function html_page(state)
    local image_url = "/" .. state.token .. "/card.png"
    local title = html_escape(state.title ~= "" and state.title or "书摘卡片")
    return [[<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">]]
        .. [[<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">]]
        .. [[<title>]] .. title .. [[</title><style>]]
        .. [[body{margin:0;background:#f3f3f3;color:#111;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;text-align:center}]]
        .. [[main{max-width:760px;margin:0 auto;padding:18px 14px 32px}h1{font-size:20px;margin:4px 0 14px}]]
        .. [[img{display:block;width:100%;height:auto;background:#fff;box-shadow:0 1px 8px rgba(0,0,0,.12)}]]
        .. [[a{display:block;margin:18px auto 10px;padding:13px 18px;max-width:320px;background:#111;color:#fff;text-decoration:none;border-radius:8px;font-size:17px}]]
        .. [[p{font-size:14px;line-height:1.6;color:#555}]]
        .. [[</style></head><body><main><h1>书摘卡片</h1>]]
        .. [[<a href="]] .. image_url .. [[" style="display:block;margin:0;padding:0;max-width:none;background:none"><img src="]] .. image_url .. [[" alt="书摘卡片"></a>]]
        .. [[<a href="]] .. image_url .. [[" download="book-excerpt.png">打开 / 保存原图</a>]]
        .. [[<p>也可以长按上方图片保存。离开阅读器扫码页面后，此地址立即失效。</p>]]
        .. [[</main></body></html>]]
end

local function queue_response(client, status, content_type, body, extra)
    body = body or ""
    client.chunks = {response_header(status, content_type, #body, extra), body}
    client.chunk_index = 1
    client.chunk_pos = 1
end

local function parse_request(state, client)
    local request_line = client.inbuf:match("^([^\r\n]+)") or ""
    local method, path = request_line:match("^(%u+)%s+([^%s]+)")
    if method ~= "GET" and method ~= "HEAD" then
        queue_response(client, "405 Method Not Allowed", "text/plain; charset=utf-8", "Method not allowed")
        return
    end
    local head_only = method == "HEAD"
    path = tostring(path or ""):match("^[^?]+") or ""
    local base = "/" .. state.token
    if path == base or path == base .. "/" then
        logger.info("[MiuRead][BookExcerpt] phone request", "resource=page",
            "peer=", tostring(client.peer_ip or "unknown"))
        local body = state.html
        if head_only then
            client.chunks = {response_header("200 OK", "text/html; charset=utf-8", #body)}
            client.chunk_index, client.chunk_pos = 1, 1
        else
            queue_response(client, "200 OK", "text/html; charset=utf-8", body)
        end
        return
    end
    if path == base .. "/card.png" then
        logger.info("[MiuRead][BookExcerpt] phone request", "resource=card",
            "peer=", tostring(client.peer_ip or "unknown"), "method=", tostring(method or ""))
        if head_only then
            client.chunks = {response_header("200 OK", "image/png", #state.image, {
                'Content-Disposition: inline; filename="book-excerpt.png"',
            })}
            client.chunk_index, client.chunk_pos = 1, 1
            return
        end
        queue_response(client, "200 OK", "image/png", state.image, {
            'Content-Disposition: inline; filename="book-excerpt.png"',
        })
        -- Only report success after the whole PNG has actually been sent.
        client.card_fetch = true
        return
    end
    logger.info("[MiuRead][BookExcerpt] phone request", "resource=not_found",
        "peer=", tostring(client.peer_ip or "unknown"))
    queue_response(client, "404 Not Found", "text/plain; charset=utf-8", "Not found")
end

local function receive_request(state, client)
    if client.chunks then return end
    for _ = 1, 4 do
        local data, err, partial = client.sock:receive(2048)
        local got = data or partial
        if got and got ~= "" then client.inbuf = client.inbuf .. got end
        if client.inbuf:find("\r\n\r\n", 1, true) or client.inbuf:find("\n\n", 1, true) then
            parse_request(state, client)
            return
        end
        if #client.inbuf > 8192 then
            queue_response(client, "431 Request Header Fields Too Large", "text/plain; charset=utf-8", "Request too large")
            return
        end
        if err == "timeout" then return end
        if err == "closed" then client.closed = true; return end
        if not data and not partial then return end
    end
end

local function send_response(state, client)
    if not client.chunks then return end
    local budget = 96 * 1024
    while budget > 0 and not client.closed do
        local chunk = client.chunks[client.chunk_index]
        if not chunk then
            if client.card_fetch and not state.download_seen then
                state.download_seen = true
                logger.info("[MiuRead][BookExcerpt] phone fetched card",
                    "peer=", tostring(client.peer_ip or "unknown"), "bytes=", tostring(#state.image))
                if type(state.on_download) == "function" then pcall(state.on_download) end
            end
            client.closed = true
            return
        end
        local from = client.chunk_pos
        if from > #chunk then
            client.chunk_index = client.chunk_index + 1
            client.chunk_pos = 1
        else
            local to = math.min(#chunk, from + budget - 1)
            local sent, err, last = client.sock:send(chunk, from, to)
            local final = sent or last
            if final and final >= from then
                local bytes = final - from + 1
                client.chunk_pos = final + 1
                budget = budget - bytes
            end
            if sent then
                if sent >= #chunk then
                    client.chunk_index = client.chunk_index + 1
                    client.chunk_pos = 1
                end
            elseif err == "timeout" then
                return
            else
                client.closed = true
                return
            end
        end
    end
end

local function drop_client(state, index)
    local client = state.clients[index]
    if client then close_socket(client.sock) end
    table.remove(state.clients, index)
end

local function poll(state, expected_generation)
    if active ~= state or generation ~= expected_generation then return end

    for _ = 1, 3 do
        local client_sock = state.server:accept()
        if not client_sock then break end
        client_sock:settimeout(0)
        local peer_ip, peer_port
        local peer_ok, a, b = pcall(client_sock.getpeername, client_sock)
        if peer_ok then peer_ip, peer_port = a, b end
        logger.info("[MiuRead][BookExcerpt] phone connected",
            "peer=", tostring(peer_ip or "unknown"), "port=", tostring(peer_port or ""))
        state.clients[#state.clients + 1] = {
            sock = client_sock,
            inbuf = "",
            chunks = nil,
            chunk_index = 1,
            chunk_pos = 1,
            deadline = now() + 30,
            peer_ip = peer_ip,
            peer_port = peer_port,
            closed = false,
        }
    end

    for index = #state.clients, 1, -1 do
        local client = state.clients[index]
        if now() > client.deadline then
            logger.warn("[MiuRead][BookExcerpt] phone connection timed out",
                "peer=", tostring(client.peer_ip or "unknown"))
            client.closed = true
        end
        if not client.closed then receive_request(state, client) end
        if not client.closed then send_response(state, client) end
        if client.closed then drop_client(state, index) end
    end

    if active == state and generation == expected_generation then
        state.poll_task = function() poll(state, expected_generation) end
        UIManager:scheduleIn(0.04, state.poll_task)
    end
end

function M.stop(reason)
    generation = generation + 1
    local state = active
    active = nil
    if not state then return true end
    if state.poll_task then pcall(UIManager.unschedule, UIManager, state.poll_task) end
    for index = #state.clients, 1, -1 do drop_client(state, index) end
    close_socket(state.server)
    close_kindle_firewall(state.port, state.kindle_firewall_open == true)
    logger.info("[MiuRead][BookExcerpt] local transfer stopped", tostring(reason or "closed"),
        "download_seen=", tostring(state.download_seen == true))
    return true
end

function M.active()
    return active ~= nil
end

function M.url()
    return active and active.url or nil
end

function M.start(opts)
    opts = opts or {}
    M.stop("restart")
    if not (ok_socket and socket and type(socket.bind) == "function") then
        return nil, "当前设备缺少局域网传输组件"
    end
    local image, image_err = read_file(opts.file_path)
    if not image then return nil, "读取书摘图片失败：" .. tostring(image_err or "unknown") end

    local ip, ip_err = local_ipv4()
    if not ip then return nil, tostring(ip_err or "阅读器尚未连接 Wi-Fi") end

    local bind_ok, server, bind_err = pcall(socket.bind, "*", 0)
    if not bind_ok or not server then
        return nil, "无法开启手机获取：" .. tostring(bind_ok and bind_err or server or "端口不可用")
    end
    server:settimeout(0)
    local _, port = server:getsockname()
    port = tonumber(port)
    if not port or port <= 0 then
        close_socket(server)
        return nil, "无法取得临时传输端口"
    end

    local firewall_ok, firewall_open = open_kindle_firewall(port)
    if not firewall_ok then
        close_socket(server)
        return nil, "Kindle 无法临时开放手机访问端口，请保留日志后重试"
    end

    generation = generation + 1
    local token = random_token(26)
    local state = {
        server = server,
        clients = {},
        ip = ip,
        port = port,
        token = token,
        image = image,
        title = U.trim(tostring(opts.title or "")),
        on_download = opts.on_download,
        download_seen = false,
        kindle_firewall_open = firewall_open == true,
    }
    state.url = string.format("http://%s:%d/%s", ip, port, token)
    state.html = html_page(state)
    active = state
    local expected_generation = generation
    logger.info("[MiuRead][BookExcerpt] local transfer started", "ip=", ip, "port=", tostring(port))
    state.poll_task = function() poll(state, expected_generation) end
    UIManager:scheduleIn(0.02, state.poll_task)
    return state.url, {ip = ip, port = port, token = token}
end

return M
