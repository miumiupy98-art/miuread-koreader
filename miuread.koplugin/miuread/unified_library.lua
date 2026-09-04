local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local PluginLoader = require("pluginloader")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local LocalLibrary = require("miuread.local_library")
local U = require("miuread.util")

local M = {}

-- Z-Library is an external downloader rather than a remote shelf provider.
-- When the user explicitly chooses a download directory, MiuRead may index
-- that directory for the “本机” view even when it sits outside the ordinary
-- local-library root. Cache the snapshot and only rescan after one of the
-- known directory mtimes changes, so opening Home does not repeatedly walk
-- a potentially large download tree.
local ZLIB_SCAN_CACHE = nil
local ZLIB_SCAN_MAX_DEPTH = 2 -- root/category/sub-category, matching Z-Library filing
local ZLIB_SCAN_LIMIT = 2000
local ZLIB_SCAN_TTL = 30

local function trim(v)
    return tostring(v or ""):match("^%s*(.-)%s*$") or ""
end

local function norm_path(v)
    return LocalLibrary.normalize(v or "")
end

local function file_exists(path)
    return path ~= "" and lfs.attributes(path, "mode") == "file"
end

local function path_within(path, root)
    path, root = norm_path(path), norm_path(root)
    if path == "" or root == "" then return false end
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function safe_component(value)
    value = tostring(value or ""):gsub("[^%w%._-]", "_")
    return value ~= "" and value or "fanqie"
end

local function copy_row(row)
    local out = {}
    for k, v in pairs(type(row) == "table" and row or {}) do out[k] = v end
    return out
end

local function canonical_source(row, fallback)
    local source = tostring((row or {}).unified_source or fallback or (row or {}).source or "")
    if source == "account" or source == "miuread" or source == "generated" then return "weread" end
    if source == "mp" or source == "wechat_mp" or source == "mp_article" then return "wechat_mp" end
    if source == "local" then return "local" end
    if source == "fanqie" then return "fanqie" end
    if source == "zlibrary" or source == "z-lib" then return "zlibrary" end
    return source ~= "" and source or "local"
end

local function item_type(row, fallback)
    local value = tostring((row or {}).content_kind or (row or {}).content_type or fallback or "")
    if value == "mp_account" then return "collection" end
    if value == "article" or value == "mp_article" then return "article" end
    return "book"
end

local function stable_key(row, source)
    row = type(row) == "table" and row or {}
    source = source or canonical_source(row)
    local source_id = trim(row.unified_source_id or row.source_id or row.bookId or row.book_id or row.reviewId or row.originalId)
    if source_id ~= "" then return source .. ":" .. source_id end
    local path = norm_path(row.file or row.local_path)
    if path ~= "" then return "file:" .. path end
    return source .. ":title:" .. trim(row.title) .. "|" .. trim(row.author)
end

local function last_opened(row)
    local values = {
        row and row.last_opened, row and row.local_recent_read_at,
        row and row.last_read_at, row and row.lastReadTime,
        row and row.last_read_time, row and row.opened_at, row and row.read_at,
    }
    local best = 0
    for _, value in pairs(values) do
        local n = tonumber(value) or 0
        if n > 100000000000 then n = math.floor(n / 1000) end
        if n > best then best = n end
    end
    return best
end

local function added_at(row)
    local values = {row and row.added_at, row and row.downloadedAt, row and row.added_time, row and row.createTime, row and row.modified_at}
    local best = 0
    for _, value in pairs(values) do
        local n = tonumber(value) or 0
        if n > 100000000000 then n = math.floor(n / 1000) end
        if n > best then best = n end
    end
    return best
end

local function local_available(row)
    if type(row) ~= "table" then return false end
    if row.local_available == true or row.local_file == true or row.generated == true or row.downloaded == true then return true end
    local status = tostring(row.status_text or row.status or "")
    if status == "已生成" or status == "已下载" then return true end
    local path = norm_path(row.file or row.local_path)
    return file_exists(path)
end

local function decorate(row, opts)
    opts = opts or {}
    local out = copy_row(row)
    local source = canonical_source(out, opts.source)
    out.unified_source = source
    out.unified_source_id = trim(opts.source_id or out.unified_source_id or out.source_id or out.bookId or out.book_id or out.reviewId or out.originalId)
    out.content_kind = item_type(out, opts.content_kind)
    out.local_path = norm_path(out.local_path or out.file)
    if opts.local_available ~= nil then
        out.local_available = opts.local_available == true
    else
        out.local_available = local_available(out)
    end
    if opts.in_shelf ~= nil then
        out.in_shelf = opts.in_shelf == true
    else
        out.in_shelf = out.in_shelf == true or out.in_account_shelf == true
    end
    out.last_opened = tonumber(opts.last_opened) or last_opened(out)
    out.added_at = tonumber(opts.added_at) or added_at(out)
    out.source_state = tostring(opts.source_state or out.source_state or "")
    out.unified_key = stable_key(out, source)
    return out
end

local function member_key(row)
    local source = canonical_source(row)
    local source_id = trim(row.unified_source_id or row.source_id or row.bookId or row.book_id or row.reviewId or row.originalId)
    if source_id ~= "" then return source .. ":" .. source_id end
    local path = norm_path(row.file or row.local_path)
    if path ~= "" then return "file:" .. path end
    return stable_key(row, source)
end

local function is_member(row, membership)
    if type(membership) ~= "table" then return false end
    return membership[member_key(row)] == true
end

local function merge_prefer(existing, incoming)
    if not existing then return incoming end
    -- Prefer a local, directly-openable representation, but retain richer
    -- metadata and the remote identity from either side.
    local a_local, b_local = existing.local_available == true, incoming.local_available == true
    local a_source, b_source = canonical_source(existing), canonical_source(incoming)
    local prefer_specific_local = a_local and b_local and a_source == "local" and b_source ~= "local"
    local base = ((b_local and not a_local) or prefer_specific_local) and incoming or existing
    local other = base == existing and incoming or existing
    local out = copy_row(base)
    local fields = {
        "title","author","cover","cover_path","description","intro","summary","format",
        "bookId","book_id","unified_source_id","progress","last_opened","added_at",
        "source_state","external_payload","external_source",
    }
    for _, key in ipairs(fields) do
        if (out[key] == nil or out[key] == "" or out[key] == 0) and other[key] ~= nil and other[key] ~= "" then out[key] = other[key] end
    end
    out.in_shelf = existing.in_shelf == true or incoming.in_shelf == true
    out.local_available = existing.local_available == true or incoming.local_available == true
    if trim(out.file) == "" and trim(other.file) ~= "" then out.file = other.file end
    if trim(out.local_path) == "" and trim(other.local_path) ~= "" then out.local_path = other.local_path end
    out.last_opened = math.max(tonumber(existing.last_opened) or 0, tonumber(incoming.last_opened) or 0)
    out.added_at = math.max(tonumber(existing.added_at) or 0, tonumber(incoming.added_at) or 0)
    out.unified_key = existing.unified_key or incoming.unified_key
    return out
end

local function put(map, order, row)
    local key = tostring(row and row.unified_key or "")
    if key == "" then return end
    if not map[key] then order[#order + 1] = key end
    map[key] = merge_prefer(map[key], row)
end

local function load_lua_table(path)
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local chunk, err = loadfile(path)
    if not chunk then
        logger.warn("[MiuRead][UnifiedLibrary] cache load failed", path, tostring(err))
        return nil
    end
    local ok, value = pcall(chunk)
    if ok and type(value) == "table" then return value end
    logger.warn("[MiuRead][UnifiedLibrary] cache execute failed", path, tostring(value))
    return nil
end

local function fanqie_cache_state(cache_dir, book)
    local book_id = trim(book and (book.book_id or book.bookId))
    if cache_dir == "" or book_id == "" then return false, 0, tonumber(book and book.total_chapters) or 0 end
    local index_path=norm_path(cache_dir) .. "/" .. safe_component(book_id) .. "/cache_index.lua"
    -- Mirror FanQie's own cache-index validity window. MiuRead must not call a
    -- stale chapter cache “本机可用” when the plugin itself would reject that
    -- index and refetch it.
    local index_attr=lfs.attributes(index_path)
    if index_attr and tonumber(index_attr.modification) and os.time()-tonumber(index_attr.modification)>86400 then
        return false,0,tonumber(book and book.total_chapters) or 0
    end
    local index = load_lua_table(index_path) or {}
    local count = 0
    for _, path in pairs(index) do
        if file_exists(norm_path(path)) then count = count + 1 end
    end
    local total = tonumber(book and (book.total_chapters or book.serial_count)) or 0
    return total > 0 and count >= total, count, total
end

local function fanqie_rows()
    local settings_path = DataStorage:getSettingsDir() .. "/fanqie.lua"
    local instance = PluginLoader:getPluginInstance("fanqie")
    local installed = instance ~= nil or lfs.attributes(settings_path, "mode") == "file"
    if not installed then return {}, {installed=false} end

    local cookies, download_dir = {}, ""
    if lfs.attributes(settings_path, "mode") == "file" then
        local store = LuaSettings:open(settings_path)
        cookies = store:readSetting("cookies", {}) or {}
        download_dir = trim(store:readSetting("download_dir", ""))
    end
    -- FanQie's QR login is complete only after the official sessionid exists;
    -- temporary CSRF/passport cookies must not resurrect an old account shelf.
    local logged_in = type(cookies) == "table" and trim(cookies.sessionid) ~= ""
    if download_dir == "" then download_dir = DataStorage:getFullDataDir() .. "/fanqie/cache" end
    local cache_path = norm_path(download_dir) .. "/shelf_cache.lua"
    local cached = load_lua_table(cache_path) or {}
    local rows, local_count = {}, 0

    for _, book in ipairs(cached) do
        if type(book) == "table" and trim(book.book_id or book.bookId) ~= "" then
            local complete, cached_count, total = fanqie_cache_state(download_dir, book)
            if complete then local_count = local_count + 1 end
            -- Logged-in users see their cached remote shelf. After explicit
            -- logout, only fully cached books remain in “本机”; the old remote
            -- shelf itself is no longer treated as current account data.
            if logged_in or complete then
                local row = decorate(book, {
                    source="fanqie", source_id=book.book_id or book.bookId,
                    in_shelf=logged_in, local_available=complete,
                    source_state=complete and "local_cache" or "cached",
                })
                row.remote_shelf = logged_in == true
                row.external_source = "fanqie"
                row.external_payload = copy_row(book)
                row.fanqie_cache_dir = norm_path(download_dir) .. "/" .. safe_component(book.book_id or book.bookId)
                row.source = "fanqie"
                row.cached_chapters = cached_count
                row.total_chapters = total > 0 and total or row.total_chapters
                rows[#rows + 1] = row
            end
        end
    end
    return rows, {
        installed=installed, logged_in=logged_in, cache_path=cache_path,
        cached_count=#cached, local_count=local_count, download_dir=download_dir,
    }
end

local function zlibrary_download_dir()
    -- Only classify a directory as Z-Library when the plugin has an explicit
    -- download-directory setting. Its built-in fallback may be KOReader's home
    -- directory; treating that fallback as Z-Library would mislabel unrelated
    -- user books.
    local settings_candidates = {
        DataStorage:getSettingsDir() .. "/zlibrary.lua",
        DataStorage:getSettingsDir() .. "/zlibrary_settings.lua",
    }
    for _, settings_path in ipairs(settings_candidates) do
        if lfs.attributes(settings_path, "mode") == "file" then
            local store = LuaSettings:open(settings_path)
            local configured = trim(store:readSetting("zlibrary_download_dir", ""))
            if configured ~= "" then return norm_path(configured) end
        end
    end
    return ""
end

local function zlibrary_cache_valid(dir)
    local cache = ZLIB_SCAN_CACHE
    if not cache or cache.dir ~= dir or type(cache.directories) ~= "table" then return false end
    -- Some embedded filesystems expose directory mtimes with one-second
    -- granularity. A bounded TTL prevents a download created in the same
    -- timestamp tick from leaving the cache stale indefinitely. Explicit Home
    -- refresh also invalidates this cache immediately.
    if os.time()-(tonumber(cache.scanned_at) or 0) >= ZLIB_SCAN_TTL then return false end
    for path, old_mtime in pairs(cache.directories) do
        local attr = lfs.attributes(path)
        if not attr or attr.mode ~= "directory" or (tonumber(attr.modification) or 0) ~= old_mtime then
            return false
        end
    end
    return true
end

local function zlibrary_scan_rows(dir)
    dir = norm_path(dir)
    if dir == "" or lfs.attributes(dir, "mode") ~= "directory" then return {}, false end
    if zlibrary_cache_valid(dir) then
        local rows = {}
        for i, row in ipairs(ZLIB_SCAN_CACHE.rows or {}) do rows[i] = copy_row(row) end
        return rows, ZLIB_SCAN_CACHE.truncated == true
    end

    local rows, directories, seen_paths = {}, {}, {}
    local queue = {{path=dir, depth=0}}
    local q = 1
    local truncated = false
    while q <= #queue and #rows < ZLIB_SCAN_LIMIT do
        local current = queue[q]
        q = q + 1
        local attr = lfs.attributes(current.path)
        if attr and attr.mode == "directory" then
            directories[current.path] = tonumber(attr.modification) or 0
            local ok, iter, state, var = pcall(lfs.dir, current.path)
            if ok and iter then
                while #rows < ZLIB_SCAN_LIMIT do
                    local next_ok, name = pcall(iter, state, var)
                    if not next_ok or not name then break end
                    var = name
                    if name ~= "." and name ~= ".." and name:sub(1,1) ~= "." then
                        local full = norm_path(current.path .. "/" .. name)
                        local child = lfs.attributes(full)
                        if child and child.mode == "directory" then
                            local lower = name:lower()
                            local symlink = false
                            if type(lfs.symlinkattributes) == "function" then
                                local sy_ok, sy_mode = pcall(lfs.symlinkattributes, full, "mode")
                                symlink = sy_ok and sy_mode == "link"
                            end
                            if current.depth < ZLIB_SCAN_MAX_DEPTH and not symlink and not lower:match("%.sdr$") then
                                queue[#queue + 1] = {path=full, depth=current.depth + 1}
                            end
                        elseif child and child.mode == "file" and not seen_paths[full] then
                            local book = LocalLibrary.book_from_path(full, {include_cover=false})
                            if book then
                                seen_paths[full] = true
                                local row = decorate(book, {source="zlibrary", in_shelf=false, local_available=true})
                                row.source = "zlibrary"
                                rows[#rows + 1] = row
                            end
                        end
                    end
                end
            end
        end
    end
    if q <= #queue or #rows >= ZLIB_SCAN_LIMIT then truncated = true end
    ZLIB_SCAN_CACHE = {dir=dir, rows=rows, directories=directories, truncated=truncated, scanned_at=os.time()}
    local copies = {}
    for i, row in ipairs(rows) do copies[i] = copy_row(row) end
    return copies, truncated
end

local function external_rows()
    local fanqie, fanqie_state = fanqie_rows()
    local zdir = zlibrary_download_dir()
    local zrows, ztruncated = zlibrary_scan_rows(zdir)
    return {fanqie=fanqie, zlibrary=zrows}, {
        fanqie=fanqie_state,
        zlibrary={installed=zdir~="", download_dir=zdir, count=#zrows, truncated=ztruncated},
    }
end

function M.build(opts)
    opts = type(opts) == "table" and opts or {}
    local membership = type(opts.membership) == "table" and opts.membership or {}
    local map, order = {}, {}
    local account_ids = {}

    local weread_state=tostring(opts.weread_state or "")
    -- An explicit logout must not resurrect a stale remote WeRead shelf from
    -- a settings/cache recovery. Local generated files are still kept in the
    -- device view below, but their old remote-shelf flag is not trusted while
    -- logged out. Auth-expired/recovering sessions may retain cached rows with
    -- an explicit source-state label so the user can re-authenticate.
    if weread_state~="logged_out" then
        for _, row in ipairs(type(opts.account) == "table" and opts.account or {}) do
            local item = decorate(row, {source="weread", in_shelf=true, source_state=weread_state})
            local id = trim(item.bookId or item.book_id or item.unified_source_id)
            if id ~= "" then account_ids[id] = true end
            put(map, order, item)
        end
    end

    for _, row in ipairs(type(opts.generated) == "table" and opts.generated or {}) do
        local id = trim(row.bookId or row.book_id)
        local in_remote_shelf=weread_state~="logged_out" and (account_ids[id] == true or row.in_account_shelf == true)
        local item = decorate(row, {source="weread", in_shelf=in_remote_shelf, local_available=true, source_state=weread_state})
        put(map, order, item)
    end

    local externals, external_state = external_rows()
    local zdir = norm_path(external_state.zlibrary and external_state.zlibrary.download_dir or "")
    for _, row in ipairs(type(opts.local_rows) == "table" and opts.local_rows or {}) do
        if not (row.local_folder == true or row.kind == "folder") then
            local path = norm_path(row.file or row.local_path)
            local source = row.unified_source or (zdir ~= "" and path_within(path, zdir) and "zlibrary" or "local")
            local item = decorate(row, {source=source, in_shelf=false, local_available=true})
            item.in_shelf = is_member(item, membership)
            put(map, order, item)
        end
    end

    -- An explicitly configured Z-Library download folder is a reliable source
    -- boundary in its own right. Merge its cached scan even when that folder is
    -- outside MiuRead's ordinary local-library root. Duplicate file paths merge
    -- back into the same unified record.
    for _, row in ipairs(externals.zlibrary or {}) do
        row.in_shelf = is_member(row, membership)
        put(map, order, row)
    end

    for _, row in ipairs(type(opts.mp_articles) == "table" and opts.mp_articles or {}) do
        local item = decorate(row, {source="wechat_mp", content_kind="article", in_shelf=false, local_available=true})
        item.in_shelf = is_member(item, membership)
        put(map, order, item)
    end

    for _, row in ipairs(externals.fanqie or {}) do
        -- A logged-out but fully cached FanQie book can be kept on the local
        -- MiuRead shelf without pretending it still belongs to the current
        -- remote FanQie account. Logged-in remote-shelf membership remains
        -- owned by FanQie itself.
        if row.remote_shelf ~= true and row.local_available == true and is_member(row, membership) then
            row.in_shelf = true
        end
        put(map, order, row)
    end

    -- KOReader read history is authoritative for local "recent" ordering.
    -- Overlay it by exact file path only; do not import unrelated history rows
    -- into the library or use filesystem modification time as a read event.
    local recent_by_file = {}
    for _, row in ipairs(type(opts.recent_local) == "table" and opts.recent_local or {}) do
        local path = norm_path(row.file or row.local_path)
        local stamp = tonumber(row.local_recent_read_at or row.read_at or row.last_opened) or 0
        if stamp > 100000000000 then stamp = math.floor(stamp / 1000) end
        if path ~= "" and stamp > (recent_by_file[path] or 0) then recent_by_file[path] = stamp end
    end
    for _, key in ipairs(order) do
        local row = map[key]
        local path = norm_path(row and (row.file or row.local_path) or "")
        local stamp = recent_by_file[path] or 0
        -- FanQie opens cached chapter HTML files rather than one monolithic
        -- book file. Map KOReader history entries inside that deterministic
        -- per-book cache directory back to the corresponding FanQie shelf row
        -- so “最近” remains source-agnostic without modifying FanQie's API.
        local fanqie_dir = norm_path(row and row.fanqie_cache_dir or "")
        if canonical_source(row) == "fanqie" and fanqie_dir ~= "" then
            for recent_path, recent_stamp in pairs(recent_by_file) do
                if path_within(recent_path, fanqie_dir) and recent_stamp > stamp then stamp = recent_stamp end
            end
        end
        if stamp > (tonumber(row and row.last_opened) or 0) then row.last_opened = stamp end
    end

    local all = {}
    for _, key in ipairs(order) do all[#all + 1] = map[key] end

    -- A remote representation can merge into a local file via book id/path.
    -- Re-sort by a stable user-facing recency so mixed sources do not appear in
    -- arbitrary source-append order.
    table.sort(all, function(a, b)
        local at, bt = tonumber(a.last_opened) or 0, tonumber(b.last_opened) or 0
        if at ~= bt then return at > bt end
        local aa, ba = tonumber(a.added_at) or 0, tonumber(b.added_at) or 0
        if aa ~= ba then return aa > ba end
        return trim(a.title):lower() < trim(b.title):lower()
    end)

    local shelf, device, recent = {}, {}, {}
    local zlibrary_count = 0
    for _, item in ipairs(all) do
        if item.in_shelf == true then shelf[#shelf + 1] = item end
        if item.local_available == true then
            device[#device + 1] = item
            if canonical_source(item) == "zlibrary" then zlibrary_count = zlibrary_count + 1 end
        end
        if (tonumber(item.last_opened) or 0) > 0 then recent[#recent + 1] = item end
    end
    if external_state.zlibrary then external_state.zlibrary.count = zlibrary_count end
    table.sort(recent, function(a,b) return (tonumber(a.last_opened) or 0) > (tonumber(b.last_opened) or 0) end)

    return {
        all=all,
        shelf=shelf,
        device=device,
        recent=recent,
        external_state=external_state,
    }
end

local SOURCE_LABELS = {
    all="全部来源", weread="微信读书", fanqie="番茄小说", zlibrary="Z-Library",
    ["local"]="本地导入", wechat_mp="公众号",
}
local TYPE_LABELS = {all="全部内容", book="书籍", article="文章"}
local LOCAL_LABELS = {all="全部", available="本机已有", remote="尚未下载"}
local SORT_LABELS = {recent="最近阅读", added="最近加入", title="书名", author="作者"}

function M.source_labels() return SOURCE_LABELS end
function M.type_labels() return TYPE_LABELS end
function M.local_labels() return LOCAL_LABELS end
function M.sort_labels() return SORT_LABELS end

function M.available_sources(rows)
    local seen, out = {}, {"all"}
    for _, row in ipairs(rows or {}) do
        local source = canonical_source(row)
        if source ~= "" and not seen[source] then seen[source] = true; out[#out + 1] = source end
    end
    local rank={weread=1,fanqie=2,zlibrary=3,["local"]=4,wechat_mp=5}
    table.sort(out,function(a,b)
        if a=="all" then return true end
        if b=="all" then return false end
        local ar,br=rank[a] or 99,rank[b] or 99
        if ar~=br then return ar<br end
        return tostring(SOURCE_LABELS[a] or a)<tostring(SOURCE_LABELS[b] or b)
    end)
    return out
end

function M.apply(rows, state, mode)
    rows = type(rows) == "table" and rows or {}
    state = type(state) == "table" and state or {}
    mode = tostring(mode or "shelf")
    local source = tostring(state.source or "all")
    local kind = tostring(state.kind or "all")
    local locality = tostring(state.locality or "all")
    local sort = tostring(state.sort or "recent")
    local filtered = {}
    for _, row in ipairs(rows) do
        local source_ok = source == "all" or canonical_source(row) == source
        local kind_ok = kind == "all" or item_type(row) == kind
        local local_ok = locality == "all"
            or (locality == "available" and row.local_available == true)
            or (locality == "remote" and row.local_available ~= true)
        if source_ok and kind_ok and (mode ~= "device" or row.local_available == true) and local_ok then
            filtered[#filtered + 1] = row
        end
    end
    table.sort(filtered, function(a,b)
        if sort == "title" then return trim(a.title):lower() < trim(b.title):lower() end
        if sort == "author" then
            local aa,ba=trim(a.author):lower(),trim(b.author):lower()
            if aa~=ba then return aa<ba end
            return trim(a.title):lower()<trim(b.title):lower()
        end
        if sort == "added" then
            local av,bv=tonumber(a.added_at) or 0,tonumber(b.added_at) or 0
            if av~=bv then return av>bv end
            return trim(a.title):lower()<trim(b.title):lower()
        end
        local av,bv=tonumber(a.last_opened) or 0,tonumber(b.last_opened) or 0
        if av~=bv then return av>bv end
        local aa,ba=tonumber(a.added_at) or 0,tonumber(b.added_at) or 0
        if aa~=ba then return aa>ba end
        return trim(a.title):lower()<trim(b.title):lower()
    end)
    return filtered
end

function M.invalidate_external_cache(source)
    source=tostring(source or "")
    if source=="" or source=="zlibrary" then ZLIB_SCAN_CACHE=nil end
end

function M.membership_key(row) return member_key(row) end
function M.canonical_source(row) return canonical_source(row) end
function M.content_type(row) return item_type(row) end

function M.open_source(owner, source)
    source=tostring(source or "")
    if source=="fanqie" then
        local instance=PluginLoader:getPluginInstance("fanqie")
        if not instance then
            if owner and owner.info then owner:info("番茄小说当前尚未加载。请从“插件与扩展”进入番茄小说，或重启 KOReader 后再试。") end
            return true
        end
        if type(instance.getMainMenuItems)=="function" and owner and type(owner._show_standalone_menu)=="function" then
            local ok,items=xpcall(function() return instance:getMainMenuItems() end,debug.traceback)
            if ok and type(items)=="table" and #items>0 then
                owner:_show_standalone_menu("番茄小说",items,{})
                return true
            end
        end
        if type(instance.showBookshelf)=="function" then
            instance:showBookshelf()
            return true
        end
        if owner and owner.info then owner:info("番茄小说当前没有可直接打开的菜单入口。") end
        return true
    end
    return false
end

function M.open_external(owner, row)
    if type(row) ~= "table" then return false end
    if row.external_source == "fanqie" then
        local instance = PluginLoader:getPluginInstance("fanqie")
        if not instance then
            if owner and owner.info then owner:info("番茄小说当前尚未加载。请从“插件与扩展”进入番茄小说，或重启 KOReader 后再试。") end
            return true
        end
        local payload = type(row.external_payload) == "table" and row.external_payload or row
        if type(instance.showBookDetail) == "function" then
            local ok, err = xpcall(function() instance:showBookDetail(payload) end, debug.traceback)
            if not ok and owner and owner.info then owner:info("无法打开番茄书籍。\n\n" .. tostring(err)) end
            return true
        end
        if type(instance.showBookshelf) == "function" then
            instance:showBookshelf()
            return true
        end
    end
    return false
end

return M
