local lfs = require("libs/libkoreader-lfs")
local U = require("miuread.util")
local BookIntegrity = require("miuread.book_integrity")

local Service = {}
Service.__index = Service

local KIND_LABELS = {
    clean = "纯净版",
    notes = "划线与想法版",
    range_clean = "章节版 · 纯净版",
    range_notes = "章节版 · 划线与想法版",
    preview_clean = "试读版 · 纯净版",
    preview_notes = "试读版 · 划线与想法版",
}

local PREFERRED_KINDS = {"notes", "clean", "range_notes", "range_clean", "preview_notes", "preview_clean"}

local function norm(path)
    local value = tostring(path or ""):gsub("\\", "/"):gsub("/+", "/")
    if #value > 1 then value = value:gsub("/$", "") end
    return value
end

local function exists(path)
    return path ~= "" and lfs.attributes(path) ~= nil
end

local function path_size(path)
    local attr = lfs.attributes(path)
    if not attr then return 0 end
    if attr.mode == "file" then return tonumber(attr.size) or 0 end
    if attr.mode ~= "directory" then return 0 end
    local total = 0
    local ok, iter, state = pcall(lfs.dir, path)
    if not ok or type(iter) ~= "function" then return 0 end
    for name in iter, state do
        if name ~= "." and name ~= ".." then total = total + path_size(path .. "/" .. name) end
    end
    return total
end

local function add_unique(list, seen, path)
    path = norm(path)
    if path ~= "" and not seen[path] then
        seen[path] = true
        list[#list + 1] = path
    end
end

local function collect_document(plan, path)
    path = norm(path)
    if path == "" then return end
    add_unique(plan.documents, plan._document_seen, path)
    add_unique(plan.paths, plan._path_seen, path)

    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or not DocSettings then return end
    local opened, settings = pcall(DocSettings.open, DocSettings, path)
    if not opened or not settings then return end

    local function sidecar(kind)
        if type(settings.getSidecarDir) ~= "function" then return end
        local good, value = pcall(settings.getSidecarDir, settings, path, kind)
        if good then add_unique(plan.paths, plan._path_seen, value) end
    end
    sidecar("doc")
    sidecar("dir")
    if type(DocSettings.isHashLocationEnabled) == "function" then
        local good, enabled = pcall(DocSettings.isHashLocationEnabled, DocSettings)
        if good and enabled then sidecar("hash") end
    end
    if type(settings.getHistoryPath) == "function" then
        local good, value = pcall(settings.getHistoryPath, settings, path)
        if good then add_unique(plan.paths, plan._path_seen, value) end
    end
end

local function collect_record(plan, record)
    if type(record) ~= "table" then return end
    collect_document(plan, record.file)
    collect_document(plan, record.original_file)
    collect_document(plan, record.pending_file)
end

local function new_plan(scope, book_id)
    return {
        scope = scope,
        book_id = tostring(book_id or ""),
        paths = {},
        documents = {},
        _path_seen = {},
        _document_seen = {},
        removed_paths = {},
        created_at = os.time(),
    }
end

local function finalize_plan(plan)
    plan.estimated_bytes = 0
    for _, path in ipairs(plan.paths) do
        if exists(path) then plan.estimated_bytes = plan.estimated_bytes + path_size(path) end
    end
    plan._path_seen = nil
    plan._document_seen = nil
    return plan
end

function Service:new(plugin)
    return setmetatable({plugin = plugin, store = assert(plugin and plugin.store)}, self)
end

function Service:variant_label(kind)
    return KIND_LABELS[tostring(kind or "")] or tostring(kind or "版本")
end

function Service:_fallback_record(book_id)
    local book = self.store:book(book_id)
    if not book then return nil end
    for _, kind in ipairs(PREFERRED_KINDS) do
        local record = book.variants and book.variants[kind]
        if type(record) == "table" and record.file and exists(record.file) then return record, kind end
    end
    for _, row in pairs(book.chapters or {}) do
        for _, kind in ipairs(PREFERRED_KINDS) do
            local record = type(row) == "table" and row[kind] or nil
            if type(record) == "table" and record.file and exists(record.file) then return record, kind end
        end
    end
    return nil
end

function Service:summary(book_id)
    book_id = tostring(book_id or "")
    local book = self.store:book(book_id)
    local out = {
        book_id = book_id, variants = {},
        chapter_count = 0, chapter_bytes = 0,
        downloaded_chapter_count = 0,
        total_bytes = 0, has_local = false,
    }
    if not book then return out end

    -- "按章节下载（已下载 N 章）" should also understand a contiguous
    -- range EPUB. Build one union of chapter indexes/UIDs so a clean and notes
    -- copy of the same range is counted once.
    local catalog_index = {}
    for index, chapter in ipairs(book.catalog or {}) do
        local uid = tostring(type(chapter) == "table" and (chapter.uid or chapter.chapterUid or chapter.chapter_uid) or "")
        if uid ~= "" then catalog_index[uid] = index end
    end
    local downloaded_units = {}
    local function mark_uid(uid)
        uid = tostring(uid or "")
        if uid == "" then return end
        local index = catalog_index[uid]
        downloaded_units[index and ("idx:" .. tostring(index)) or ("uid:" .. uid)] = true
    end
    local function mark_range(record)
        if type(record) ~= "table" or record.partial_range ~= true then return end
        local first = tonumber(record.range_start_index)
        local last = tonumber(record.range_end_index)
        if first and last then
            if last < first then first, last = last, first end
            for index = first, last do downloaded_units["idx:" .. tostring(index)] = true end
        else
            local count = math.max(0, tonumber(record.chapter_count) or 0)
            for index = 1, count do
                downloaded_units["range:" .. tostring(record.file or "") .. ":" .. tostring(index)] = true
            end
        end
    end

    for _, kind in ipairs(PREFERRED_KINDS) do
        local record = book.variants and book.variants[kind]
        if type(record) == "table" and record.file and exists(record.file) then
            local size = path_size(record.file)
            out.variants[#out.variants + 1] = {
                kind = kind,
                label = self:variant_label(kind),
                file = record.file,
                size = size,
                record = U.copy(record),
            }
            out.total_bytes = out.total_bytes + size
            out.has_local = true
            if kind == "range_clean" or kind == "range_notes" then mark_range(record) end
        end
    end

    for uid, row in pairs(book.chapters or {}) do
        local found = false
        for _, record in pairs(type(row) == "table" and row or {}) do
            if type(record) == "table" and record.file and exists(record.file) then
                found = true
                local size = path_size(record.file)
                out.chapter_bytes = out.chapter_bytes + size
                out.total_bytes = out.total_bytes + size
            end
        end
        if found then
            out.chapter_count = out.chapter_count + 1
            out.has_local = true
            mark_uid(uid)
        end
    end
    for _ in pairs(downloaded_units) do out.downloaded_chapter_count = out.downloaded_chapter_count + 1 end
    return out
end

local function add_matching_partial_repairs(plan, store, book_id, predicate)
    local ok, repairs = pcall(BookIntegrity.partial_repairs, store, book_id)
    if not ok or type(repairs) ~= "table" then return end
    for _, repair in ipairs(repairs) do
        if type(repair) == "table" and predicate(repair) then
            add_unique(plan.paths, plan._path_seen, repair.root)
        end
    end
end

function Service:plan_variant(book_id, kind)
    book_id, kind = tostring(book_id or ""), tostring(kind or "")
    local plan = new_plan("variant", book_id)
    plan.kind = kind
    plan.label = self:variant_label(kind)
    local record = self.store:variant(book_id, kind)
    if record then collect_record(plan, record) end

    local base_kind = (kind == "notes" or kind == "range_notes" or kind == "preview_notes") and "notes" or "clean"
    add_matching_partial_repairs(plan, self.store, book_id, function(repair)
        if tostring(repair.kind or "") ~= base_kind then return false end
        local options = type(repair.options) == "table" and repair.options or {}
        if kind == "clean" or kind == "notes" then
            return options.chapter_uid == nil and options.range_start_index == nil and options.range_end_index == nil
        end
        if kind == "range_clean" or kind == "range_notes" then
            if options.range_start_index == nil and options.range_end_index == nil then return false end
            if type(record) ~= "table" then return true end
            return tonumber(options.range_start_index) == tonumber(record.range_start_index)
                and tonumber(options.range_end_index) == tonumber(record.range_end_index)
        end
        return false
    end)
    return finalize_plan(plan)
end

function Service:plan_chapter(book_id, uid)
    book_id, uid = tostring(book_id or ""), tostring(uid or "")
    local plan = new_plan("chapter", book_id)
    plan.uid = uid
    local book = self.store:book(book_id)
    local row = book and book.chapters and book.chapters[uid]
    for _, record in pairs(type(row) == "table" and row or {}) do collect_record(plan, record) end
    if type(self.store.hidden_prefetch_entries) == "function" then
        for _, entry in ipairs(self.store:hidden_prefetch_entries(book_id)) do
            if tostring(entry.uid or "") == uid then collect_document(plan, entry.file) end
        end
    end
    add_matching_partial_repairs(plan, self.store, book_id, function(repair)
        local options = type(repair) == "table" and type(repair.options) == "table" and repair.options or {}
        return tostring(options.chapter_uid or "") == uid
    end)
    return finalize_plan(plan)
end

function Service:plan_book(book_id)
    book_id = tostring(book_id or "")
    local plan = new_plan("book", book_id)
    local book = self.store:book(book_id)
    if book then
        for _, record in pairs(book.variants or {}) do collect_record(plan, record) end
        for _, row in pairs(book.chapters or {}) do
            for _, record in pairs(type(row) == "table" and row or {}) do collect_record(plan, record) end
        end
    end
    if type(self.store.hidden_prefetch_entries) == "function" then
        for _, entry in ipairs(self.store:hidden_prefetch_entries(book_id)) do collect_document(plan, entry.file) end
    end
    add_unique(plan.paths, plan._path_seen, self.store:book_cache_path(book_id))
    add_unique(plan.paths, plan._path_seen, self.store:prefetch_book_path(book_id))
    add_unique(plan.paths, plan._path_seen, self.store:cover_path(book_id))
    local cover_index = self.store:get("cover_index", {})
    add_unique(plan.paths, plan._path_seen, type(cover_index) == "table" and cover_index[book_id] or nil)

    for _, row in ipairs(self.store:pending_installs()) do
        if tostring(row.book_id or "") == book_id then
            collect_document(plan, row.file)
            collect_document(plan, row.pending_file)
        end
    end
    local state = self.store:download_state()
    local state_id = tostring(state.book_id or (state.book and (state.book.bookId or state.book.book_id)) or "")
    if state_id == book_id then
        collect_document(plan, state.file)
        collect_document(plan, state.original_file)
        collect_document(plan, state.pending_file)
    end
    return finalize_plan(plan)
end

function Service:plan_local_file(path)
    local plan = new_plan("local_file", "")
    plan.local_path = norm(path)
    collect_document(plan, plan.local_path)
    return finalize_plan(plan)
end

function Service:is_currently_open(plan)
    local plugin = self.plugin
    local current = plugin and type(plugin._current_document_path) == "function" and norm(plugin:_current_document_path()) or ""
    if current == "" then return false end
    for _, path in ipairs(plan.documents or {}) do if norm(path) == current then return true end end
    return false
end

local function remove_koreader_document_refs(documents)
    local ok_history, history = pcall(require, "readhistory")
    local ok_collection, collection = pcall(require, "readcollection")
    local ok_booklist, BookList = pcall(require, "ui/widget/booklist")
    for _, path in ipairs(documents or {}) do
        if ok_history and history and type(history.removeItemByPath) == "function" then
            pcall(history.removeItemByPath, history, path)
        end
        if ok_collection and collection and type(collection.removeItem) == "function" then
            pcall(collection.removeItem, collection, path)
        end
        if ok_booklist and BookList and type(BookList.resetBookInfoCache) == "function" then
            pcall(BookList.resetBookInfoCache, path)
        end
    end
end

local function removed_set(plan)
    local out = {}
    for _, path in ipairs(plan.documents or {}) do out[norm(path)] = true end
    return out
end

local function update_session_last_path(store, book_id, removed, fallback)
    local session = store:session(book_id)
    if type(session) ~= "table" then return end
    local last = norm(session.last_read_path)
    if last ~= "" and removed[last] then
        store:save_session(book_id, {last_read_path = fallback and fallback.file or false}, false)
    end
end

local function repair_store_recent(service, plan, delete_book)
    local store = service.store
    local book_id = tostring(plan.book_id or "")
    local removed = removed_set(plan)
    local fallback, fallback_kind = delete_book and nil or service:_fallback_record(book_id)
    local fallback_file = fallback and norm(fallback.file) or ""

    local state = store:recent_reads()
    local items = {}
    for _, row in ipairs(state.items or {}) do
        if type(row) == "table" then
            local row_id = tostring(row.book_id or row.bookId or "")
            local row_file = norm(row.file)
            local hit = (delete_book and book_id ~= "" and row_id == book_id) or (row_file ~= "" and removed[row_file])
            if hit then
                if not delete_book and book_id ~= "" and row_id == book_id and fallback_file ~= "" then
                    local copy = U.copy(row)
                    copy.file = fallback_file
                    copy.key = "book:" .. book_id
                    items[#items + 1] = copy
                end
            else
                items[#items + 1] = row
            end
        end
        if #items >= 10 then break end
    end
    state.items = items
    store:set("recent_reads", state)

    local authoritative = store:get("recent_read_state", {version = 2, seq = 0, current = nil})
    if type(authoritative) == "table" and type(authoritative.current) == "table" then
        local current = authoritative.current
        local current_id = tostring(current.book_id or current.bookId or "")
        local current_file = norm(current.file)
        local hit = (delete_book and book_id ~= "" and current_id == book_id) or (current_file ~= "" and removed[current_file])
        if hit then
            if fallback_file ~= "" then
                current.file = fallback_file
                current.book_id = book_id
                current.bookId = book_id
                current.key = "book:" .. book_id
                current.recent_key = current.key
                current.variant = fallback_kind
            else
                authoritative.current = nil
            end
            store:set("recent_read_state", authoritative)
        end
    end
    if not delete_book and book_id ~= "" then update_session_last_path(store, book_id, removed, fallback) end
end

local function prune_network_metadata(store, book_id, path)
    local cache = store:get("home_network_metadata", {version = 1, rows = {}})
    if type(cache) ~= "table" then return end
    cache.rows = type(cache.rows) == "table" and cache.rows or {}
    local changed = false
    if book_id and book_id ~= "" and cache.rows["book:" .. book_id] ~= nil then
        cache.rows["book:" .. book_id] = nil; changed = true
    end
    path = norm(path)
    if path ~= "" and cache.rows["file:" .. path] ~= nil then
        cache.rows["file:" .. path] = nil; changed = true
    end
    if changed then store:set("home_network_metadata", cache) end
end

local function prune_missing_network_file_rows(store)
    local cache=store:get("home_network_metadata",{version=1,rows={}})
    if type(cache)~="table" or type(cache.rows)~="table" then return 0 end
    local changed,count=false,0
    for key in pairs(cache.rows) do
        local path=tostring(key or ""):match("^file:(.+)$")
        path=path and norm(path) or ""
        if path~="" and not exists(path) then cache.rows[key]=nil; changed=true; count=count+1 end
    end
    if changed then store:set("home_network_metadata",cache) end
    return count
end

local function prune_local_cache_rows(store, only_path)
    only_path = norm(only_path)
    local metadata = store:get("home_local_recent_metadata_v1", {version = 1, rows = {}})
    if type(metadata) == "table" then
        metadata.rows = type(metadata.rows) == "table" and metadata.rows or {}
        local changed = false
        for path in pairs(metadata.rows) do
            local normalized = norm(path)
            if (only_path == "" or normalized == only_path) and not exists(normalized) then
                metadata.rows[path] = nil; changed = true
            end
        end
        if changed then store:set("home_local_recent_metadata_v1", metadata) end
    end

    local tree = store:get("home_local_directory_cache_v5", {version = 5, dirs = {}})
    if type(tree) == "table" and type(tree.dirs) == "table" then
        local changed = false
        local function filter(rows)
            local out = {}
            for _, row in ipairs(type(rows) == "table" and rows or {}) do
                local path = norm(type(row) == "table" and row.file or "")
                if path == "" or exists(path) or (only_path ~= "" and path ~= only_path) then out[#out + 1] = row else changed = true end
            end
            return out
        end
        for _, snapshot in pairs(tree.dirs) do
            if type(snapshot) == "table" then
                snapshot.books = filter(snapshot.books)
                snapshot.direct_books = filter(snapshot.direct_books)
            end
        end
        if changed then tree.updated_at = os.time(); store:set("home_local_directory_cache_v5", tree) end
    end
end

local function prune_home_membership(store, only_path)
    only_path = norm(only_path)
    local preferences = store:preferences()
    local home = type(preferences.home_ui) == "table" and preferences.home_ui or {}
    local membership = type(home.library_membership) == "table" and home.library_membership or {}
    local changed = false
    for key in pairs(membership) do
        local path = tostring(key or ""):match("^file:(.+)$")
        path = path and norm(path) or ""
        if path ~= "" and (only_path == "" or path == only_path) and not exists(path) then
            membership[key] = nil
            changed = true
        end
    end
    if changed then
        home.library_membership = membership
        preferences.home_ui = home
        store:save_preferences(preferences)
    end
    return changed
end

local function cleanup_orphan_document_artifacts(plan)
    local documents = {}
    for _, path in ipairs(plan.documents or {}) do documents[norm(path)] = true end
    local removed = 0
    for _, path in ipairs(plan.paths or {}) do
        local normalized = norm(path)
        if normalized ~= "" and not documents[normalized] and exists(normalized) then
            local ok = U.remove_tree(normalized)
            if ok then removed = removed + 1 end
        end
    end
    return removed
end


function Service:commit(plan)
    plan = type(plan) == "table" and plan or {}
    local scope = tostring(plan.scope or "")
    remove_koreader_document_refs(plan.documents)

    if scope == "variant" then
        self.store:forget_variant(plan.book_id, plan.kind)
        repair_store_recent(self, plan, false)
    elseif scope == "chapter" then
        self.store:forget_chapter_all(plan.book_id, plan.uid)
        if type(self.store.hidden_prefetch_entries) == "function" then
            for _, entry in ipairs(self.store:hidden_prefetch_entries(plan.book_id)) do
                if tostring(entry.uid or "") == tostring(plan.uid or "") then
                    self.store:forget_hidden_prefetch(plan.book_id, entry.uid, entry.kind, false)
                end
            end
        end
        repair_store_recent(self, plan, false)
    elseif scope == "book" then
        repair_store_recent(self, plan, true)
        self.store:forget_book_local_state(plan.book_id)
        prune_network_metadata(self.store, plan.book_id, nil)
    elseif scope == "local_file" then
        -- The physical user file is owned by KOReader's native delete flow.
        -- Once it is gone, MiuRead may safely remove only its orphan sidecar /
        -- history artifacts and local indexes.
        local all_documents_missing = true
        for _, path in ipairs(plan.documents or {}) do
            if exists(path) then all_documents_missing = false; break end
        end
        if all_documents_missing then cleanup_orphan_document_artifacts(plan) end
        repair_store_recent(self, plan, false)
        prune_network_metadata(self.store, nil, plan.local_path)
        prune_local_cache_rows(self.store, plan.local_path)
        prune_home_membership(self.store, plan.local_path)
    end

    self.store:prune_missing_files()
    if self.plugin and type(self.plugin._book_delete_runtime_cleanup) == "function" then
        self.plugin:_book_delete_runtime_cleanup(plan)
    end
    return true
end

function Service:prune_missing_local_references()
    prune_local_cache_rows(self.store, "")
    prune_missing_network_file_rows(self.store)
    prune_home_membership(self.store, "")
    local plan = new_plan("local_file", "")
    local recent = self.store:recent_reads()
    for _, row in ipairs(recent.items or {}) do
        local path = norm(type(row) == "table" and row.file or "")
        if path ~= "" and not exists(path) and tostring(row.book_id or row.bookId or "") == "" then
            collect_document(plan, path)
        end
    end
    local authoritative = self.store:get("recent_read_state", {})
    local current = type(authoritative) == "table" and authoritative.current or nil
    if type(current) == "table" and tostring(current.book_id or current.bookId or "") == "" then
        local path = norm(current.file)
        if path ~= "" and not exists(path) then collect_document(plan, path) end
    end
    plan = finalize_plan(plan)
    if #plan.documents > 0 then
        remove_koreader_document_refs(plan.documents)
        cleanup_orphan_document_artifacts(plan)
        repair_store_recent(self, plan, false)
    end
    if self.plugin and type(self.plugin._book_delete_runtime_cleanup) == "function" then
        self.plugin:_book_delete_runtime_cleanup(plan)
    end
    return #plan.documents
end

local function store_has_removed_reference(store, plan)
    local removed = removed_set(plan)
    local recent = store:recent_reads()
    for _, row in ipairs(recent.items or {}) do
        if removed[norm(type(row) == "table" and row.file or "")] then return true, "recent_reads" end
    end
    local authoritative = store:get("recent_read_state", {})
    local current = type(authoritative) == "table" and authoritative.current or nil
    if type(current) == "table" and removed[norm(current.file)] then return true, "recent_read_state" end
    return false
end

function Service:verify(plan)
    plan = type(plan) == "table" and plan or {}
    local residual_paths, residual_refs = {}, {}
    for _, path in ipairs(plan.paths or {}) do if exists(path) then residual_paths[#residual_paths + 1] = path end end
    local scope = tostring(plan.scope or "")
    if scope == "variant" and self.store:variant(plan.book_id, plan.kind) ~= nil then residual_refs[#residual_refs + 1] = "variant" end
    if scope == "chapter" then
        local book = self.store:book(plan.book_id)
        if book and book.chapters and book.chapters[tostring(plan.uid or "")] ~= nil then residual_refs[#residual_refs + 1] = "chapter" end
    end
    if scope == "book" and self.store:book(plan.book_id) ~= nil then residual_refs[#residual_refs + 1] = "library" end
    local recent_hit, recent_name = store_has_removed_reference(self.store, plan)
    if recent_hit then residual_refs[#residual_refs + 1] = recent_name end
    return {ok = #residual_paths == 0 and #residual_refs == 0, paths = residual_paths, refs = residual_refs}
end

function Service:local_file_size(path)
    return path_size(norm(path))
end

function Service.normalize_path(path)
    return norm(path)
end

return Service
