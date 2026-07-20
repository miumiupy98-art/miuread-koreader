local Util = require("miuread.util")

local Cookies = {}

local reserved = {
    path=true, domain=true, expires=true, ["max-age"]=true,
    samesite=true, secure=true, httponly=true,
}

-- Keep the same persistent-cookie boundary used by the proven 0.3.6.7 build.
-- QR/browser-only cookies must never be written into the long-lived account jar,
-- because a second device login may rotate those temporary browser sessions.
local stable = {
    ptcz=true,
    RK=true,
    pgv_pvid=true,
}

local protected_core = {
    wr_vid=true,
    wr_skey=true,
    wr_rt=true,
}

local function segments(line)
    local out = {}
    for part in tostring(line or ""):gmatch("[^;]+") do
        table.insert(out, Util.trim(part))
    end
    return out
end

function Cookies.is_persistent_name(name)
    name = tostring(name or "")
    return name:match("^wr_") ~= nil or stable[name] == true
end

function Cookies.parse_header(text)
    local jar = {}
    for _, part in ipairs(segments(text)) do
        local k, v = part:match("^([^=]+)=(.*)$")
        if k then
            local name = Util.trim(k)
            local value = Util.trim(v)
            if not reserved[name:lower()]
                and Cookies.is_persistent_name(name)
                and value ~= "" then
                jar[name] = value
            end
        end
    end
    return jar
end

function Cookies.header(jar)
    local keys, out = {}, {}
    for k, v in pairs(jar or {}) do
        if type(k) == "string" and Cookies.is_persistent_name(k)
            and v ~= nil and tostring(v) ~= "" then
            table.insert(keys, k)
        end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        table.insert(out, k .. "=" .. tostring(jar[k]))
    end
    return table.concat(out, "; ")
end

local function split_set_cookie(raw)
    if type(raw) == "table" then
        local out = {}
        for _, value in pairs(raw) do
            local rows = split_set_cookie(value)
            for _, row in ipairs(rows) do out[#out + 1] = row end
        end
        return out
    end
    local text = tostring(raw or "")
    if text:find("\r", 1, true) or text:find("\n", 1, true) then
        local out = {}
        for line in text:gmatch("[^\r\n]+") do
            local rows = split_set_cookie(line)
            for _, row in ipairs(rows) do out[#out + 1] = row end
        end
        return out
    end
    local out, start, in_expires = {}, 1, false
    for i = 1, #text do
        local tail = text:sub(i):lower()
        if tail:sub(1, 8) == "expires=" then in_expires = true end
        local ch = text:sub(i, i)
        if in_expires and ch == ";" then in_expires = false end
        if ch == "," and not in_expires then
            local nextpart = text:sub(i + 1):match("^%s*([^=;,]+)=")
            if nextpart then
                out[#out + 1] = Util.trim(text:sub(start, i - 1))
                start = i + 1
            end
        end
    end
    if start <= #text then out[#out + 1] = Util.trim(text:sub(start)) end
    return out
end

function Cookies.sanitize(jar)
    local cleaned, changed = {}, false
    for k, v in pairs(jar or {}) do
        local value_type = type(v)
        if type(k) == "string" and Cookies.is_persistent_name(k)
            and (value_type == "string" or value_type == "number")
            and tostring(v) ~= "" then
            cleaned[k] = tostring(v)
            if value_type ~= "string" then changed = true end
        else
            changed = true
        end
    end
    for k, v in pairs(cleaned) do
        if tostring((jar or {})[k] or "") ~= v then changed = true end
    end
    return cleaned, changed
end

function Cookies.absorb(jar, raw, opt)
    opt = opt or {}
    local cleaned = Cookies.sanitize(jar or {})
    jar = cleaned
    local protect_core = opt.protect_core ~= false

    for _, line in ipairs(split_set_cookie(raw)) do
        local first = line:match("^([^;]+)") or ""
        local k, v = first:match("^%s*([^=]+)=(.*)$")
        if k then
            k, v = Util.trim(k), Util.trim(v)
            if Cookies.is_persistent_name(k) then
                local lower = line:lower()
                local deletion = v == "" or lower:find("max%-age%s*=%s*0") ~= nil
                    or lower:find("expires%s*=%s*thu,%s*01%s+jan%s+1970") ~= nil
                if deletion then
                    -- The working 0.3.6.7 path ignored browser deletion directives
                    -- for core login credentials. Preserve that behavior so an
                    -- unrelated response cannot silently invalidate this device.
                    if not (protect_core and protected_core[k] and jar[k]) then
                        jar[k] = nil
                    end
                else
                    jar[k] = v
                end
            end
        end
    end
    return jar
end

function Cookies.names(jar)
    local keys = {}
    for k, v in pairs(jar or {}) do
        if Cookies.is_persistent_name(k) and v ~= nil and tostring(v) ~= "" then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    return keys
end

function Cookies.same(a, b)
    local aa = Cookies.sanitize(a or {})
    local bb = Cookies.sanitize(b or {})
    for k, v in pairs(aa) do if bb[k] ~= v then return false end end
    for k, v in pairs(bb) do if aa[k] ~= v then return false end end
    return true
end

return Cookies
