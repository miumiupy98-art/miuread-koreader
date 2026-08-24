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

return LocalLibrary
