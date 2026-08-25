local lfs = require("libs/libkoreader-lfs")

local LocalLibrary = {}

local registry_checked = false
local registry

local function document_registry()
    if not registry_checked then
        registry_checked = true
        local ok, value = pcall(require, "document/documentregistry")
        if ok and value then registry = value end
    end
    return registry
end

local function basename(path)
    return tostring(path or ""):match("([^/]+)$") or tostring(path or "")
end

local function dirname(path)
    return tostring(path or ""):match("^(.*)/[^/]+$") or ""
end

local function stem(path)
    local name = basename(path)
    return (name:gsub("%.[^%.]+$", ""))
end

local function extension(path)
    return (tostring(path or ""):match("%.([%w]+)$") or ""):lower()
end

local function exists(path)
    return path and lfs.attributes(path, "mode") == "file"
end

local function cover_path(path)
    -- Reuse KOReader's custom-cover lookup. MiuRead does not define a second
    -- cover naming policy; the extra candidates only preserve old sidecars.
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and DocSettings and type(DocSettings.findCustomCoverFile) == "function" then
        local found_ok, found = pcall(DocSettings.findCustomCoverFile, DocSettings, path)
        if found_ok and exists(found) then return found end
    end
    local dir = dirname(path)
    local base = stem(path)
    local candidates = {
        dir .. "/" .. base .. ".sdr/cover.jpg",
        dir .. "/" .. base .. ".sdr/cover.jpeg",
        dir .. "/" .. base .. ".sdr/cover.png",
        path .. ".sdr/cover.jpg",
        path .. ".sdr/cover.jpeg",
        path .. ".sdr/cover.png",
    }
    for _, candidate in ipairs(candidates) do
        if exists(candidate) then return candidate end
    end
    return nil
end

local function title_from_path(path)
    local title = stem(path)
    title = title:gsub("[_%-]+", " "):gsub("%s+", " ")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    return title ~= "" and title or "未命名"
end

local function should_skip_dir(name)
    local lower = tostring(name or ""):lower()
    -- Match KOReader's ordinary hidden-directory expectations without keeping
    -- a MiuRead-specific blacklist of folder names. A user folder named
    -- "System" or "Plugins" therefore remains browsable.
    if lower == "." or lower == ".." then return true end
    if lower:sub(1, 1) == "." then return true end
    if lower:match("%.sdr$") then return true end
    return false
end

local function should_skip_file(name)
    local lower = tostring(name or ""):lower()
    if lower:sub(1, 1) == "." or lower:sub(1, 2) == "._" then return true end
    if lower:sub(-1) == "~" then return true end
    if lower:match("%.part$") or lower:match("%.tmp$") or lower:match("%.download$")
        or lower:match("%.crdownload$") then return true end
    return false
end

function LocalLibrary.normalize(path)
    path = tostring(path or ""):gsub("\\", "/"):gsub("/+", "/")
    if #path > 1 then path = path:gsub("/$", "") end
    return path
end

function LocalLibrary.basename(path) return basename(LocalLibrary.normalize(path)) end
function LocalLibrary.dirname(path) return dirname(LocalLibrary.normalize(path)) end
function LocalLibrary.title_from_path(path) return title_from_path(path) end

-- Format discovery belongs to KOReader. No extension whitelist is maintained
-- here, so a format added by KOReader automatically becomes visible to MiuRead.
function LocalLibrary.is_supported(path)
    local registry_value = document_registry()
    if not registry_value or type(registry_value.hasProvider) ~= "function" then return false end
    local ok, supported = pcall(registry_value.hasProvider, registry_value, path)
    return ok and supported == true
end

-- Kept for compatibility with older callers. The new local-book architecture
-- no longer uses this heuristic to hide books.
function LocalLibrary.is_likely_dictionary(path, title)
    local normalized = LocalLibrary.normalize(path):lower()
    return normalized:find("/dictionaries/", 1, true) ~= nil
        or normalized:find("/dictionary/", 1, true) ~= nil
        or normalized:find("/dict/", 1, true) ~= nil
end

function LocalLibrary.is_miuread_generated_epub(path)
    path = LocalLibrary.normalize(path)
    if path == "" or not path:lower():match("%.epub$") or not exists(path) then return false end
    local file = io.open(path, "rb")
    if not file then return false end
    local size = file:seek("end") or 0
    file:seek("set", 0)
    local head = file:read(math.min(size, 768 * 1024)) or ""
    local tail = ""
    if size > #head then
        file:seek("set", math.max(0, size - 1024 * 1024))
        tail = file:read("*a") or ""
    end
    file:close()
    -- MiuRead-generated EPUBs write this source marker into package.opf.
    return (head .. "\n" .. tail):find("miuread://book/", 1, true) ~= nil
end

function LocalLibrary.book_from_path(path, options)
    options = options or {}
    path = LocalLibrary.normalize(path)
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" or should_skip_file(basename(path)) or not LocalLibrary.is_supported(path) then return nil end
    return {
        file = path,
        title = title_from_path(path),
        author = "",
        format = extension(path):upper(),
        size = tonumber(attr.size) or 0,
        modified_at = tonumber(attr.modification) or 0,
        last_read_at = tonumber(options.last_read_at) or nil,
        cover_path = options.include_cover == true and cover_path(path) or nil,
        local_file = true,
        source = "local",
    }
end

-- Current-directory browsing only. No recursion, no depth limit, and no
-- fixed item cap unless a caller explicitly supplies one for compatibility.
local DirectoryScan = {}
DirectoryScan.__index = DirectoryScan

function DirectoryScan:_close()
    if self._closed then return end
    self._closed = true
    pcall(function()
        if self.state and self.state.close then self.state:close() end
    end)
end

function DirectoryScan:cancel()
    self.cancelled = true
    self.done = true
    self:_close()
end

function DirectoryScan:_accept(name)
    if name == "." or name == ".." then return end
    local full = (self.path == "/" and "/" .. name or self.path .. "/" .. name)
    local attr = lfs.attributes(full)
    if attr and attr.mode == "directory" then
        if not should_skip_dir(name) then
            self.folders[#self.folders + 1] = {
                kind = "folder", local_folder = true, title = name,
                path = full, folder_path = full, modified_at = tonumber(attr.modification) or 0,
            }
            self.seen = self.seen + 1
        end
    elseif attr and attr.mode == "file" and not should_skip_file(name) then
        local book = LocalLibrary.book_from_path(full, {include_cover = self.include_cover})
        if book then
            self.books[#self.books + 1] = book
            self.seen = self.seen + 1
        end
    end
    if self.limit and self.seen >= self.limit then
        self.truncated = true
        self.done = true
        self:_close()
    end
end

function DirectoryScan:step(batch_size)
    if self.done or self.cancelled then return true end
    batch_size = math.max(1, tonumber(batch_size) or 32)
    local processed = 0
    while processed < batch_size and not self.done do
        local ok, name = pcall(self.iter, self.state, self.var)
        if not ok then
            self.error = tostring(name or "无法读取目录")
            self.done = true
            self:_close()
            break
        end
        self.var = name
        if not name then
            self.done = true
            self:_close()
            break
        end
        processed = processed + 1
        self:_accept(name)
    end
    return self.done
end

function DirectoryScan:snapshot()
    if not self._sorted then
        table.sort(self.folders, function(a, b)
            return tostring(a.title or ""):lower() < tostring(b.title or ""):lower()
        end)
        table.sort(self.books, function(a, b)
            if self.options.sort == "name" then
                return tostring(a.title or ""):lower() < tostring(b.title or ""):lower()
            end
            local am, bm = tonumber(a.modified_at) or 0, tonumber(b.modified_at) or 0
            if am ~= bm then return am > bm end
            return tostring(a.title or ""):lower() < tostring(b.title or ""):lower()
        end)
        self._sorted = true
    end
    return {
        path = self.path, scanned_at = os.time(), folders = self.folders, books = self.books,
        truncated = self.truncated == true, direct_count = #self.folders + #self.books,
        error = self.error,
    }
end

function LocalLibrary.new_directory_scan(path, options)
    options = options or {}
    path = LocalLibrary.normalize(path)
    local explicit_limit = tonumber(options.limit)
    if explicit_limit and explicit_limit <= 0 then explicit_limit = nil end
    local scanner = setmetatable({
        path = path, options = options, limit = explicit_limit and math.max(20, explicit_limit) or nil,
        include_cover = options.include_cover == true, folders = {}, books = {}, seen = 0,
        truncated = false, done = false, cancelled = false,
    }, DirectoryScan)
    local ok, iter, state, var = pcall(lfs.dir, path)
    if not ok or not iter then
        scanner.done = true
        scanner.error = tostring(iter or state or "无法读取目录")
        return scanner
    end
    scanner.iter, scanner.state, scanner.var = iter, state, var
    return scanner
end

function LocalLibrary.list_directory(path, options)
    local scanner = LocalLibrary.new_directory_scan(path, options)
    while not scanner:step(256) do end
    return scanner:snapshot()
end

-- Compatibility only: old code may still call scan(). It is intentionally a
-- non-recursive current-directory read, so no missed legacy call can revive the
-- retired whole-library scanner.
function LocalLibrary.scan(root, options)
    local snapshot = LocalLibrary.list_directory(root, options)
    return {
        root = LocalLibrary.normalize(root),
        scanned_at = snapshot.scanned_at or os.time(),
        books = snapshot.books or {},
        folders = snapshot.folders or {},
        truncated = snapshot.truncated == true,
        error = snapshot.error,
        non_recursive = true,
    }
end

return LocalLibrary
