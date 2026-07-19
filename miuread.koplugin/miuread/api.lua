local Protocol = require("miuread.protocol")
local U = require("miuread.util")

local Api = {}
Api.__index = Api

local function scalar(value, depth, seen)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then return value end
    if kind ~= "table" or (depth or 0) > 4 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    for _, key in ipairs({"chapterUid", "chapterId", "uid", "id", "value", "node"}) do
        local candidate = scalar(value[key], (depth or 0) + 1, seen)
        if candidate ~= nil then return candidate end
    end
end

local function sanitize(value, path, seen)
    local kind = type(value)
    path = path or "$"
    if kind == "nil" or kind == "string" or kind == "number" or kind == "boolean" then return value end
    if kind ~= "table" then error("unsupported parameter at " .. path .. ": " .. kind) end
    seen = seen or {}
    if seen[value] then error("cyclic parameter at " .. path) end
    seen[value] = true
    local out, max, count, array = {}, 0, 0, true
    for key in pairs(value) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then array = false else max = math.max(max, key) end
    end
    if array and max ~= count then array = false end
    if array then
        for i = 1, max do out[i] = sanitize(value[i], path .. "[" .. i .. "]", seen) end
    else
        for key, item in pairs(value) do
            if type(key) ~= "string" then error("non-string object key at " .. path) end
            local clean = sanitize(item, path .. "." .. key, seen)
            if clean ~= nil then out[key] = clean end
        end
    end
    seen[value] = nil
    return out
end

local function unwrap(data)
    local current = data
    for _ = 1, 4 do
        if type(current) ~= "table" then break end
        local candidate
        for _, key in ipairs({"data", "result", "payload"}) do
            if type(current[key]) == "table" then
                local only = true
                for k in pairs(current) do
                    if k ~= key and k ~= "errCode" and k ~= "errMsg" and k ~= "code" and k ~= "message" then only = false; break end
                end
                if only then candidate = current[key]; break end
            end
        end
        if not candidate then break end
        current = candidate
    end
    return current
end

local function unique_candidates(value)
    local raw = scalar(value)
    local out, seen = {}, {}
    local function add(v)
        if type(v) ~= "string" and type(v) ~= "number" then return end
        if type(v) == "string" and v == "" then return end
        local key = type(v) .. ":" .. tostring(v)
        if not seen[key] then seen[key] = true; out[#out + 1] = v end
    end
    add(raw)
    local number = tonumber(raw)
    if number then add(number) end
    if raw ~= nil then add(tostring(raw)) end
    return out
end

function Api:new(http, store) return setmetatable({http = http, store = store}, self) end

function Api:call(name, params, request_options)
    local auth = self.store:auth()
    if tostring(auth.api_key or "") == "" then error("API key is not configured") end
    local payload = sanitize(U.copy(params or {}))
    payload.api_name = tostring(name)
    payload.skill_version = Protocol.SKILL_VERSION
    local options = U.copy(request_options or {})
    options.auth = false
    options.headers = options.headers or {}
    options.headers.Authorization = "Bearer " .. auth.api_key
    if options.retries == nil then options.retries = 2 end
    local ok, data = pcall(self.http.post_json, self.http,
        "https://i.weread.qq.com/api/agent/gateway", payload, options)
    if not ok then error(tostring(name) .. ": " .. tostring(data)) end
    return unwrap(data)
end

function Api:shelf()
    return self:call("/shelf/sync", {}, {retries=1, timeout={10, 18}})
end
function Api:search(q, offset, count)
    return self:call("/store/search", {keyword=tostring(q or ""), scope=10, maxIdx=offset or 0, count=count or 30}, {retries=1, timeout={10, 18}})
end
function Api:book(id) return self:call("/book/info", {bookId=tostring(id)}) end
function Api:chapters(id) return self:call("/book/chapterinfo", {bookId=tostring(id)}) end
function Api:progress(id) return self:call("/book/getprogress", {bookId=tostring(id), _t=os.time()}) end

function Api:_chapter_call(name, id, chapter_uid, extra)
    local last
    local candidates = unique_candidates(chapter_uid)
    if #candidates == 0 then error(name .. ": invalid chapterUid") end
    for _, uid in ipairs(candidates) do
        local payload = U.copy(extra or {})
        payload.bookId = tostring(id)
        payload.chapterUid = uid
        local ok, value = pcall(self.call, self, name, payload)
        if ok then return value end
        last = value
        if not tostring(value):lower():find("params error%(node%)") then error(value) end
    end
    error(last or (name .. ": params error(node)"))
end

function Api:underlines(id, chapter_uid)
    return self:_chapter_call("/book/underlines", id, chapter_uid)
end

function Api:review_batches(ranges, batch_size)
    local out = {}
    batch_size = tonumber(batch_size) or 5
    for first = 1, #(ranges or {}), batch_size do
        local batch = {}
        for i = first, math.min(first + batch_size - 1, #ranges) do
            local range = scalar(ranges[i]) or ranges[i]
            batch[#batch + 1] = {range=tostring(range or ""), maxIdx=0, count=30, synckey=0}
        end
        out[#out + 1] = batch
    end
    return out
end

function Api:readreviews(id, chapter_uid, batch)
    return self:_chapter_call("/book/readreviews", id, chapter_uid, {reviews=sanitize(batch or {})})
end

Api._scalar = scalar
Api._sanitize = sanitize
Api._unique_candidates = unique_candidates

return Api
