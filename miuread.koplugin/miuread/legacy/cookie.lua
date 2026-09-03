local Cookie = {}


function Cookie.to_header(cookies)
    local parts = {}
    for key, value in pairs(cookies or {}) do
        table.insert(parts, key .. "=" .. value)
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

function Cookie.merge_set_cookie(cookies, set_cookie)
    if not set_cookie or set_cookie == "" then
        return cookies
    end
    cookies = cookies or {}
    if type(set_cookie) == "table" then
        for _, value in pairs(set_cookie) do
            Cookie.merge_set_cookie(cookies, value)
        end
        return cookies
    end
    local allowed = {
        ptcz = true,
        RK = true,
        pgv_pvid = true,
    }
    for pair in set_cookie:gmatch("([^;,\r\n]+=[^;,\r\n]+)") do
        local name, value = pair:match("^%s*([%w_]+)=([^;,\r\n]+)")
        if name and value and (name:match("^wr_") or allowed[name]) then
            cookies[name] = value
        end
    end
    return cookies
end

function Cookie.has_login_cookie(cookies)
    return cookies and cookies.wr_skey and #cookies.wr_skey >= 8
end

return Cookie
