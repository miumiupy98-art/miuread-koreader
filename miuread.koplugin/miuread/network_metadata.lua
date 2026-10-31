local logger = require("logger")
local U = require("miuread.util")

local NetworkMetadata = {}

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function url_encode(value)
    return (tostring(value or ""):gsub("\n", " "):gsub("([^%w%-_%.~ ])", function(char)
        return string.format("%%%02X", string.byte(char))
    end):gsub(" ", "+"))
end

local function plain_text(value)
    if type(value) == "table" then value = value.value or value.text or value[1] end
    value = trim(value)
    if value == "" then return nil end
    local ok, util = pcall(require, "util")
    if ok and util and type(util.htmlToPlainTextIfHtml) == "function" then
        local converted_ok, converted = pcall(util.htmlToPlainTextIfHtml, value)
        if converted_ok and converted then value = converted end
    end
    value = tostring(value):gsub("<[^>]+>", " "):gsub("%s+", " ")
    value = trim(value)
    return value ~= "" and U.utf8_truncate(value, 520, "…") or nil
end

local function normalize_isbn(value)
    value = tostring(value or ""):upper():gsub("[^0-9X]", "")
    if #value == 10 or #value == 13 then return value end
    return nil
end

local function first_isbn(value)
    if type(value) == "table" then
        for _, row in ipairs(value) do
            local isbn = normalize_isbn(type(row) == "table" and (row.identifier or row.value or row.isbn) or row)
            if isbn then return isbn end
        end
    end
    local text = tostring(value or "")
    for token in text:gmatch("[%dXx][%dXx%-%s]+") do
        local isbn = normalize_isbn(token)
        if isbn then return isbn end
    end
    return normalize_isbn(value)
end

local function join(value, separator)
    separator = separator or "、"
    if type(value) ~= "table" then return trim(value) ~= "" and tostring(value) or nil end
    local out = {}
    for _, item in ipairs(value) do
        local text
        if type(item) == "table" then text = item.name or item.title or item.value else text = item end
        text = trim(text)
        if text ~= "" then out[#out + 1] = text end
    end
    return #out > 0 and table.concat(out, separator) or nil
end

local function normalized_title(value)
    return trim(value):lower():gsub("[%s%p%c]", "")
end

local function title_score(wanted, candidate)
    local a, b = normalized_title(wanted), normalized_title(candidate)
    if a == "" or b == "" then return 0 end
    if a == b then return 100 end
    if a:find(b, 1, true) or b:find(a, 1, true) then return 70 end
    return 0
end

local function google_patch(info)
    if type(info) ~= "table" then return nil end
    local patch = {
        title = trim(info.title),
        author = join(info.authors),
        description = plain_text(info.description),
        publisher = plain_text(info.publisher),
        published_date = trim(info.publishedDate),
        category = join(info.categories, " · "),
        language = trim(info.language),
        pages = tonumber(info.pageCount),
        metadata_source = "google_books",
    }
    patch.isbn = first_isbn(info.industryIdentifiers)
    return patch
end

local function fetch_google(http, book)
    local isbn = first_isbn(book.isbn or book.identifiers)
    local query
    if isbn then
        query = "isbn:" .. isbn
    else
        local title = trim(book.title)
        if title == "" then return nil end
        query = "intitle:" .. title
        local author = trim(book.author)
        if author ~= "" then query = query .. " inauthor:" .. author end
    end
    local url = "https://www.googleapis.com/books/v1/volumes?q=" .. url_encode(query)
        .. "&maxResults=5&printType=books"
    -- Independent third-party budget. A Google 429 must never poison WeRead's
    -- global cooldown or its progress upload/readback path. Fail fast on the
    -- provider's own cooldown rather than occupying the shared HTTP worker.
    local data = http:get_json(url, {
        auth = false, retries = 1, timeout = {8, 15}, pacing = false,
        rate_limit_scope = "metadata-google", rate_limit_retries = 0,
        rate_limit_fail_fast = true,
    })
    local best, best_score
    for _, item in ipairs(type(data) == "table" and data.items or {}) do
        local info = type(item) == "table" and item.volumeInfo or nil
        if type(info) == "table" then
            local score = isbn and 100 or title_score(book.title, info.title)
            if trim(book.author) ~= "" and join(info.authors) then
                local wanted = normalized_title(book.author)
                local found = normalized_title(join(info.authors))
                if wanted ~= "" and found ~= "" and (wanted:find(found, 1, true) or found:find(wanted, 1, true)) then
                    score = score + 20
                end
            end
            if not best or score > best_score then best, best_score = info, score end
        end
    end
    if not best or (not isbn and (best_score or 0) < 70) then return nil end
    return google_patch(best)
end

local function openlibrary_patch(data)
    if type(data) ~= "table" then return nil end
    local patch = {
        title = trim(data.title),
        description = plain_text(data.description),
        publisher = join(data.publishers),
        published_date = trim(data.publish_date or data.first_publish_date),
        category = join(data.subjects, " · "),
        pages = tonumber(data.number_of_pages),
        metadata_source = "open_library",
    }
    patch.isbn = first_isbn(data.isbn_13 or data.isbn_10 or data.isbn)
    return patch
end

local function merge_patch(base, extra)
    base = type(base) == "table" and base or {}
    if type(extra) ~= "table" then return base end
    for key, value in pairs(extra) do
        if value ~= nil and value ~= "" and (base[key] == nil or base[key] == "") then base[key] = value end
    end
    return base
end

local function fetch_openlibrary(http, book)
    local isbn = first_isbn(book.isbn or book.identifiers)
    if not isbn then return nil end
    local edition = http:get_json("https://openlibrary.org/isbn/" .. url_encode(isbn) .. ".json", {
        auth = false, retries = 1, timeout = {8, 15}, pacing = false,
        rate_limit_scope = "metadata-openlibrary", rate_limit_retries = 0,
        rate_limit_fail_fast = true,
    })
    local patch = openlibrary_patch(edition)
    local work_key = type(edition) == "table" and type(edition.works) == "table"
        and type(edition.works[1]) == "table" and edition.works[1].key or nil
    if work_key and (not patch or not patch.description or not patch.category) then
        local work = http:get_json("https://openlibrary.org" .. tostring(work_key) .. ".json", {
            auth = false, retries = 1, timeout = {8, 15}, pacing = false,
            rate_limit_scope = "metadata-openlibrary", rate_limit_retries = 0,
            rate_limit_fail_fast = true,
        })
        patch = merge_patch(patch, openlibrary_patch(work))
    end
    return patch
end

local function useful(patch)
    return type(patch) == "table" and (trim(patch.description) ~= "" or trim(patch.publisher) ~= ""
        or trim(patch.category) ~= "" or trim(patch.published_date) ~= "" or tonumber(patch.pages) ~= nil)
end

function NetworkMetadata.fetch(http, book)
    if not http or type(book) ~= "table" then return nil end
    local result
    local ok_google, google = pcall(fetch_google, http, book)
    if ok_google and useful(google) then result = google
    elseif not ok_google then logger.warn("[MiuRead][NetworkMetadata] Google Books failed", tostring(google)) end

    if not result or not result.description then
        local ok_open, open = pcall(fetch_openlibrary, http, book)
        if ok_open and useful(open) then result = merge_patch(result, open)
        elseif not ok_open then logger.warn("[MiuRead][NetworkMetadata] Open Library failed", tostring(open)) end
    end
    if useful(result) then
        result.metadata_checked_at = os.time()
        return result
    end
    return nil
end

NetworkMetadata.normalize_isbn = normalize_isbn
NetworkMetadata.first_isbn = first_isbn
return NetworkMetadata
