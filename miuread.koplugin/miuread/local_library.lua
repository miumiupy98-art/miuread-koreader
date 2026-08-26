local lfs = require("libs/libkoreader-lfs")

local LocalLibrary = {}

local registry_checked = false
local registry
local filechooser_checked = false
local filechooser

local function document_registry()
    if not registry_checked then
        registry_checked = true
        local ok, value = pcall(require, "document/documentregistry")
        if ok and value then registry = value end
    end
    return registry
end

local function native_filechooser()
    if not filechooser_checked then
        filechooser_checked = true
        local ok, value = pcall(require, "ui/widget/filechooser")
        if ok and value then filechooser = value end
    end
    return filechooser
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

function LocalLibrary.normalize(path)
    path = tostring(path or ""):gsub("\\", "/"):gsub("/+", "/")
    if #path > 1 then path = path:gsub("/$", "") end
    return path
end

function LocalLibrary.basename(path) return basename(LocalLibrary.normalize(path)) end
function LocalLibrary.dirname(path) return dirname(LocalLibrary.normalize(path)) end
function LocalLibrary.title_from_path(path) return title_from_path(path) end

-- KOReader owns format support. MiuRead deliberately keeps no extension list.
function LocalLibrary.is_supported(path)
    local registry_value = document_registry()
    if not registry_value or type(registry_value.hasProvider) ~= "function" then return false end
    local ok, supported = pcall(registry_value.hasProvider, registry_value, path)
    return ok and supported == true
end

local function native_dir_visible(name)
    name = tostring(name or "")
    if name == "." or name == ".." or name:sub(1, 1) == "." then return false end
    local chooser = native_filechooser()
    if chooser and type(chooser.show_dir) == "function" then
        local ok, shown = pcall(chooser.show_dir, chooser, name)
        if ok then return shown ~= false end
    end
    return not name:lower():match("%.sdr$")
end

local NON_BOOK_IMAGE_EXTENSIONS = {
    jpg=true,jpeg=true,png=true,gif=true,bmp=true,webp=true,svg=true,
    tif=true,tiff=true,pbm=true,pgm=true,ppm=true,pnm=true,
}

local function obvious_runtime_file(name)
    local lower = tostring(name or ""):lower()
    -- Kindle may place crash diagnostics directly in documents. They are text
    -- files KOReader can technically open, but they are not user books.
    if lower:match("^kppmainappv?2?_.*_crash_.*%.txt$") then return true end
    return false
end

local function native_file_visible(name, fullpath)
    name = tostring(name or "")
    local lower = name:lower()
    if lower:sub(1, 1) == "." or lower:sub(1, 2) == "._" then return false end
    if lower:sub(-1) == "~" then return false end
    if lower:match("%.part$") or lower:match("%.tmp$") or lower:match("%.download$")
        or lower:match("%.crdownload$") then return false end
    if obvious_runtime_file(name) then return false end
    -- DocumentRegistry also has image providers. A recursive "book library"
    -- should follow KOReader for document formats without turning wallpapers
    -- and photos into books.
    if NON_BOOK_IMAGE_EXTENSIONS[extension(name)] then return false end
    if not LocalLibrary.is_supported(fullpath) then return false end
    local chooser = native_filechooser()
    if chooser and type(chooser.show_file) == "function" then
        -- No fullpath here on purpose: KOReader's status filter is a UI choice,
        -- not a definition of what belongs to the complete local library.
        local ok, shown = pcall(chooser.show_file, chooser, name)
        if ok then return shown ~= false end
    end
    return true
end

-- Compatibility helper retained for old callers.
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
    return (head .. "\n" .. tail):find("miuread://book/", 1, true) ~= nil
end

function LocalLibrary.book_from_path(path, options)
    options = options or {}
    path = LocalLibrary.normalize(path)
    local attr = lfs.attributes(path)
    local name = basename(path)
    if not attr or attr.mode ~= "file" or not native_file_visible(name, path) then return nil end
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

local function excluded_path(path, excluded)
    path = LocalLibrary.normalize(path)
    for _, value in ipairs(excluded or {}) do
        local root = LocalLibrary.normalize(value)
        if root ~= "" and (path == root or path:sub(1, #root + 1) == root .. "/") then return true end
    end
    return false
end

local function is_symlink(path)
    if type(lfs.symlinkattributes) ~= "function" then return false end
    local ok, mode = pcall(lfs.symlinkattributes, path, "mode")
    return ok and mode == "link"
end

-- Recursive KOReader-backed discovery. Folder cards represent immediate child
-- folders, while books contain every KOReader-supported document below path.
-- Discovery builds a complete snapshot first; callers swap it into the UI only
-- after this scan has finished, so page turns never mutate library membership.
local TreeScan = {}
TreeScan.__index = TreeScan

function TreeScan:_close_current()
    local state = self.current_state
    self.current_iter, self.current_state, self.current_var, self.current_path = nil, nil, nil, nil
    pcall(function() if state and state.close then state:close() end end)
end

function TreeScan:_open_next()
    self:_close_current()
    while self.queue_index <= #self.queue do
        local path = self.queue[self.queue_index]
        self.queue_index = self.queue_index + 1
        local ok, iter, state, var = pcall(lfs.dir, path)
        if ok and iter then
            self.current_path, self.current_iter, self.current_state, self.current_var = path, iter, state, var
            self.directories_scanned = self.directories_scanned + 1
            return true
        end
        self.unreadable_dirs[#self.unreadable_dirs + 1] = path
        if path == self.path then
            self.error = tostring(iter or state or "无法读取目录")
            self.done = true
            return false
        end
    end
    self.done = true
    return false
end

function TreeScan:cancel()
    self.cancelled = true
    self.done = true
    self:_close_current()
end

function TreeScan:_accept(name)
    if name == "." or name == ".." then return end
    local base = self.current_path
    local full = (base == "/" and "/" .. name or base .. "/" .. name)
    if excluded_path(full, self.excluded_paths) then return end
    local attr = lfs.attributes(full)
    if not attr then
        self.unreadable_paths[#self.unreadable_paths + 1] = full
        return
    end
    if attr.mode == "directory" then
        if native_dir_visible(name) and not is_symlink(full) then
            if base == self.path then
                self.folders[#self.folders + 1] = {
                    kind = "folder", local_folder = true, title = name,
                    path = full, folder_path = full, modified_at = tonumber(attr.modification) or 0,
                }
            end
            self.queue[#self.queue + 1] = full
        end
    elseif attr and attr.mode == "file" then
        local book = LocalLibrary.book_from_path(full, {include_cover = self.include_cover})
        if book then
            self.books[#self.books + 1] = book
            self.seen = self.seen + 1
            if self.limit and self.seen >= self.limit then
                self.truncated = true
                self.done = true
                self:_close_current()
            end
        end
    end
end

function TreeScan:step(batch_size)
    if self.done or self.cancelled then return true end
    batch_size = math.max(1, tonumber(batch_size) or 32)
    local processed = 0
    while processed < batch_size and not self.done do
        if not self.current_iter and not self:_open_next() then break end
        if self.current_iter then
            local ok, name = pcall(self.current_iter, self.current_state, self.current_var)
            if not ok then
                self.unreadable_dirs[#self.unreadable_dirs + 1] = self.current_path
                if self.current_path == self.path then self.error = tostring(name or "无法读取目录") end
                self:_close_current()
            else
                self.current_var = name
                if not name then
                    self:_close_current()
                else
                    processed = processed + 1
                    self:_accept(name)
                end
            end
        end
    end
    return self.done
end

function TreeScan:snapshot()
    if not self._sorted then
        table.sort(self.folders, function(a, b)
            return tostring(a.title or ""):lower() < tostring(b.title or ""):lower()
        end)
        table.sort(self.books, function(a, b)
            if self.options.sort == "modified" then
                local am, bm = tonumber(a.modified_at) or 0, tonumber(b.modified_at) or 0
                if am ~= bm then return am > bm end
            end
            local at, bt = tostring(a.title or ""):lower(), tostring(b.title or ""):lower()
            if at ~= bt then return at < bt end
            return tostring(a.file or "") < tostring(b.file or "")
        end)
        self._sorted = true
    end
    return {
        path = self.path,
        root = self.path,
        scanned_at = os.time(),
        folders = self.folders,
        books = self.books,
        truncated = self.truncated == true,
        recursive = true,
        direct_count = #self.folders,
        book_count = #self.books,
        directories_scanned = self.directories_scanned,
        unreadable_dirs = self.unreadable_dirs,
        unreadable_paths = self.unreadable_paths,
        partial = (#self.unreadable_dirs > 0 or #self.unreadable_paths > 0) and self.error == nil,
        error = self.error,
    }
end

function LocalLibrary.new_tree_scan(path, options)
    options = options or {}
    path = LocalLibrary.normalize(path)
    local explicit_limit = tonumber(options.limit)
    if explicit_limit and explicit_limit <= 0 then explicit_limit = nil end
    local scanner = setmetatable({
        path = path,
        options = options,
        limit = explicit_limit and math.max(20, explicit_limit) or nil,
        include_cover = options.include_cover == true,
        excluded_paths = type(options.exclude_paths) == "table" and options.exclude_paths or {},
        folders = {}, books = {}, seen = 0,
        queue = {path}, queue_index = 1,
        directories_scanned = 0, unreadable_dirs = {}, unreadable_paths = {},
        truncated = false, done = false, cancelled = false,
    }, TreeScan)
    if path == "" or lfs.attributes(path, "mode") ~= "directory" then
        scanner.done = true
        scanner.error = "文件夹不存在"
    end
    return scanner
end

function LocalLibrary.list_tree(path, options)
    local scanner = LocalLibrary.new_tree_scan(path, options)
    while not scanner:step(256) do end
    return scanner:snapshot()
end

-- Compatibility aliases. 5.2 beta.4 restores complete recursive discovery;
-- callers using the old names now receive the same KOReader-backed snapshot.
function LocalLibrary.new_directory_scan(path, options)
    return LocalLibrary.new_tree_scan(path, options)
end

function LocalLibrary.list_directory(path, options)
    return LocalLibrary.list_tree(path, options)
end

function LocalLibrary.scan(root, options)
    return LocalLibrary.list_tree(root, options)
end

return LocalLibrary
