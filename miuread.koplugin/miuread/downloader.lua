local Protocol = require("miuread.protocol")
local Config = require("miuread.config")
local Codec = require("miuread.codec")
local Footnotes = require("miuread.footnotes")
local ResourceRefs = require("miuread.resource_refs")
local InternalLinks = require("miuread.internal_links")
local Thoughts = require("miuread.thoughts")
local Epub = require("miuread.epub")
local Http = require("miuread.http")
local DownloadPlan = require("miuread.download_plan")
local DownloadDatabase = require("miuread.download_database")
local EpubInstaller = require("miuread.epub_installer")
local U = require("miuread.util")
local logger = require("logger")
local ok_socket, socket = pcall(require, "socket")

local function pause(seconds)
    if ok_socket and socket and type(socket.sleep) == "function" then socket.sleep(seconds) end
end

local Downloader = {}
Downloader.__index = Downloader

local CACHE_SCHEMA = 9
local FOOTNOTE_TRANSFORM_VERSION = 2
local LEGACY_TITLE_TRANSFORM_VERSION = 1
local TITLE_TRANSFORM_VERSION = 2
local LEGACY_ANNOTATION_TRANSFORM_VERSION = 1
local ANNOTATION_TRANSFORM_VERSION = 4
local IMAGE_TRANSFORM_VERSION = 2

local BASE_CSS = [[
body { line-height: 1.75; margin: 5%; }
img { max-width: 100%; height: auto; }
.miu-chapter { display: block; page-break-before: always; break-before: page; }
.miu-chapter-title { font-size: 1.55em; font-weight: bold; line-height: 1.35; margin: 1.2em 0 .9em 0; page-break-before: always; break-before: page; }
]]

local function normalized_book(value)
    value = type(value) == "table" and value or {}
    local source = value.bookInfo or value.book or value
    return {
        bookId = tostring(source.bookId or source.book_id or value.bookId or value.book_id or ""),
        title = tostring(source.title or value.title or "未命名"),
        author = tostring(source.author or value.author or ""),
        cover = source.cover or source.coverUrl or value.cover,
        category = source.category or value.category,
    }
end

local function css_add(list, seen, css)
    css = tostring(css or "")
    if css ~= "" and not seen[css] then seen[css] = true; list[#list + 1] = css end
end

local function plain(value)
    return tostring(value or ""):gsub("<[^>]+>", " "):gsub("&[%#%w]+;", " "):gsub("%s+", " ")
end

-- Fold the full-width ASCII block (U+FF01-U+FF5E) onto plain ASCII so a title
-- differing from the body only by punctuation width still compares equal.
local function fold_fullwidth(value)
    value = tostring(value or "")
    value = value:gsub("\239\188([\129-\191])", function(c) return string.char(c:byte() - 96) end)
    value = value:gsub("\239\189([\128-\158])", function(c) return string.char(c:byte() - 32) end)
    return value
end

-- Lua's %s and %p only cover single-byte ASCII. Remove common invisible spacing
-- and CJK punctuation explicitly so visually identical headings compare equal.
local BLANK_PATTERNS = {
    "\194\160",             -- U+00A0 no-break space
    "\194\173",             -- U+00AD soft hyphen
    "\227\128[\128-\191]",  -- U+3000-U+303F ideographic space and CJK punctuation
    "\226\128[\128-\191]",  -- U+2000-U+203F spaces, dashes, quotes and ellipsis
    "\226\129[\128-\175]",  -- U+2040-U+206F
    "\239\187\191",         -- U+FEFF byte order mark
}

local function normalized_title(value)
    local text = fold_fullwidth(plain(value)):lower()
    for _, pattern in ipairs(BLANK_PATTERNS) do text = text:gsub(pattern, "") end
    return text:gsub("[%s%p%c]", "")
end

local function trim_lead(value)
    value = tostring(value or "")
    while true do
        local stripped = value:gsub("^[%s%c]+", "")
        for _, pattern in ipairs(BLANK_PATTERNS) do stripped = stripped:gsub("^" .. pattern, "") end
        if stripped == value then return value end
        value = stripped
    end
end

local CJK_DIGITS = {
    ["〇"]=true, ["零"]=true, ["一"]=true, ["二"]=true, ["三"]=true, ["四"]=true,
    ["五"]=true, ["六"]=true, ["七"]=true, ["八"]=true, ["九"]=true, ["十"]=true,
    ["百"]=true, ["千"]=true, ["两"]=true,
}
local NUMBER_UNITS = {"章", "节", "節", "回", "卷", "篇", "部", "夜", "话", "話", "集", "幕", "折", "出"}
local NUMBER_SEPARATORS = {["、"]=true, ["．"]=true, ["："]=true, ["，"]=true, ["。"]=true}

local function has_number_unit(text)
    for _, unit in ipairs(NUMBER_UNITS) do
        if text:find(unit, 1, true) then return true end
    end
    return false
end

local function title_is_numbered(title)
    title = trim_lead(title)
    if title == "" then return false end
    if title:find("^%d") or title:find("^[%(%[]%s*%d") then return true end
    if title:find("^（%s*%d") or title:find("^【%s*%d") then return true end
    local lowered = title:lower()
    if lowered:find("^chapter") or lowered:find("^part%s") or lowered:find("^section%s") then return true end
    if title:sub(1, 3) == "第" then
        local following = title:sub(4, 6)
        if CJK_DIGITS[following] or title:sub(4, 4):find("%d") then return true end
    end
    if CJK_DIGITS[title:sub(1, 3)] then
        local head = title:sub(1, 24)
        if has_number_unit(head) then return true end
        if NUMBER_SEPARATORS[title:sub(4, 6)] then return true end
        if title:find("^...[%.%s]") then return true end
    end
    return false
end

local TITLE_SCAN_LIMIT = 2400
local TITLE_SCAN_WINDOW = TITLE_SCAN_LIMIT + 2000
local TITLE_SCAN_HEADINGS = 8
local TITLE_SLACK_BYTES = 40

local function attribute(attrs, name)
    attrs = tostring(attrs or "")
    return attrs:match(name .. '%s*=%s*"([^"]*)"')
        or attrs:match(name .. "%s*=%s*'([^']*)'")
        or ""
end

local function heading_labels(head)
    local out = {head.inner, attribute(head.attrs, "title")}
    for image_attrs in tostring(head.inner or ""):gmatch("<img([^>]*)>") do
        out[#out + 1] = attribute(image_attrs, "alt")
        out[#out + 1] = attribute(image_attrs, "title")
    end
    return out
end

local function collect_headings(window, limit)
    local headings, position = {}, 1
    while #headings < TITLE_SCAN_HEADINGS do
        local first, last, tag, attrs, inner = window:find("<(h[1-6])([^>]*)>(.-)</%1%s*>", position)
        if not first or first > limit then break end
        headings[#headings + 1] = {first=first, last=last, tag=tag, attrs=attrs, inner=inner}
        position = last + 1
    end
    return headings
end

local function normalized_title_legacy(value)
    return plain(value):lower():gsub("[%s%p%c]", "")
end

local function prepare_chapter_body_legacy(html, title)
    local fragment = Codec.body(html)
    title = tostring(title or "")
    if title == "" then return '<section class="miu-chapter" epub:type="chapter">' .. fragment .. "</section>" end
    local wanted = normalized_title_legacy(title)
    local prefix = fragment:sub(1, 1600)
    local has_title = false
    for _tag, _attrs, inner in prefix:gmatch("<(h[1-6])([^>]*)>(.-)</%1%s*>") do
        if normalized_title_legacy(inner) == wanted then has_title = true; break end
    end
    if not has_title then
        local _, first_inner = prefix:match("^%s*<([pd][^>]*)>(.-)</[pd][^>]*>")
        if first_inner and normalized_title_legacy(first_inner) == wanted then has_title = true end
    end
    if not has_title then
        fragment = '<h1 class="miu-chapter-title">' .. U.xml(title) .. "</h1>\n" .. fragment
    end
    return '<section class="miu-chapter" epub:type="chapter" data-miuread-section="1">' .. fragment .. "</section>"
end

local function prepare_chapter_body_current(html, title)
    local fragment = Codec.body(html)
    title = tostring(title or "")
    if title == "" then
        return '<section class="miu-chapter" epub:type="chapter">' .. fragment .. "</section>"
    end

    local wanted = normalized_title(title)
    local has_title = false
    if wanted ~= "" then
        local window = fragment:sub(1, TITLE_SCAN_WINDOW)
        local headings = collect_headings(window, TITLE_SCAN_LIMIT)
        local slack = #trim_lead(title) + TITLE_SLACK_BYTES

        local function exact(value)
            return normalized_title(value) == wanted
        end

        local function numbered_variant(value)
            local text = trim_lead(plain(value))
            if text == "" or #text > slack or not title_is_numbered(text) then return false end
            local folded = normalized_title(text)
            return #folded > #wanted and folded:find(wanted, 1, true) ~= nil
        end

        for index, head in ipairs(headings) do
            for _, label in ipairs(heading_labels(head)) do
                if exact(label) or numbered_variant(label) then
                    has_title = true
                    break
                end
            end
            if has_title then break end

            -- Some books split one catalog title over neighbouring headings.
            local joined = normalized_title(head.inner)
            for next_index = index + 1, math.min(index + 2, #headings) do
                local previous = headings[next_index - 1]
                local gap = window:sub(previous.last + 1, headings[next_index].first - 1)
                if normalized_title(gap) ~= "" then break end
                joined = joined .. normalized_title(headings[next_index].inner)
                if joined == wanted then has_title = true; break end
            end
            if has_title then break end
        end

        if not has_title then
            local _, first_inner = window:match("^%s*<([pd])[^>]*>(.-)</%1%s*>")
            if first_inner and exact(first_inner) then has_title = true end
        end
    end

    if not has_title then
        fragment = '<h1 class="miu-chapter-title">' .. U.xml(title) .. "</h1>\n" .. fragment
    end
    return '<section class="miu-chapter" epub:type="chapter" data-miuread-section="1">' .. fragment .. "</section>"
end

local function prepare_chapter_body(html, title, transform_version)
    if tonumber(transform_version) == LEGACY_TITLE_TRANSFORM_VERSION then
        return prepare_chapter_body_legacy(html, title)
    end
    return prepare_chapter_body_current(html, title)
end

local function preview_information_chapter(book, mode, catalog_count, readable_count, restricted_count, failures)
    local title = mode == "info" and "试读信息" or "试读内容说明"
    local lines = {
        '<section class="miu-chapter miu-preview-info" epub:type="frontmatter">',
        '<h1 class="miu-chapter-title">' .. U.xml(title) .. '</h1>',
        '<p><strong>书名：</strong>' .. U.xml(book.title or "未命名") .. '</p>',
        '<p><strong>作者：</strong>' .. U.xml(book.author or "") .. '</p>',
        '<p><strong>当前状态：</strong>微信读书已明确限制为试读。</p>',
        '<p><strong>官方目录：</strong>' .. tostring(catalog_count or 0) .. ' 章</p>',
        '<p><strong>本次取得正文：</strong>' .. tostring(readable_count or 0) .. ' 章</p>',
        '<p><strong>明确受限章节：</strong>' .. tostring(restricted_count or 0) .. ' 章</p>',
    }
    if mode == "info" then
        lines[#lines + 1] = '<p>本次没有取得可写入 EPUB 的试读正文。该文件仅保留书籍信息和权限状态，不代表正文已经下载。</p>'
    else
        lines[#lines + 1] = '<p>本次只收录成功取得的试读正文。未成功取得的章节没有写入文件，可稍后重新生成。</p>'
    end
    if #(failures or {}) > 0 then
        lines[#lines + 1] = '<h2>未能收录的章节</h2><ol>'
        for index, item in ipairs(failures or {}) do
            if index > 30 then break end
            lines[#lines + 1] = '<li>' .. U.xml(item.title or item.uid or "未知章节") .. '：' .. U.xml(U.first_line(item.error, 120)) .. '</li>'
        end
        lines[#lines + 1] = '</ol>'
    end
    lines[#lines + 1] = '<p>生成时间：' .. U.xml(os.date("%Y-%m-%d %H:%M:%S")) .. '</p></section>'
    return table.concat(lines, "\n"), title
end

local function localize(http, html, assets, enabled)
    if not enabled then return html end
    local cache = {}
    local function replace(prefix, quote, url)
        local clean = tostring(url):gsub("&amp;", "&")
        if cache[clean] then return prefix .. quote .. cache[clean] .. quote end
        local ok, data = pcall(http.download, http, clean, {auth=false, retries=3})
        if not ok or not data or #data == 0 then return prefix .. quote .. url .. quote end
        local ext, mime = Codec.media(data)
        local href = "images/remote-" .. tostring(#assets + 1) .. ext
        assets[#assets + 1] = {href=href, data=data, mime=mime}
        cache[clean] = "../" .. href
        return prefix .. quote .. cache[clean] .. quote
    end
    html = html:gsub("(data%-src=)([\"'])(https?://[^\"']+)%2", replace)
    html = html:gsub("(src=)([\"'])(https?://[^\"']+)%2", replace)
    return html
end

local function failure_message(failures, expected, actual, checkpointed)
    local lines = {
        "下载不完整，未生成新的 EPUB",
        "必需内容：" .. tostring(expected),
        "已完整获取：" .. tostring(actual),
        checkpointed
            and "已完成章节保存在断点缓存；再次下载时只补未完成章节。"
            or "请检查网络或登录状态后重新下载。",
    }
    for index, item in ipairs(failures or {}) do
        if index > 5 then break end
        lines[#lines + 1] = "• " .. tostring(item.title or item.uid or "未知章节") .. "：" .. U.first_line(item.error, 120)
    end
    return table.concat(lines, "\n")
end

local function pattern_escape(value)
    return tostring(value or ""):gsub("([^%w])", "%%%1")
end

local function namespace_assets(body, style, assets, uid)
    local out = {}
    local prefix = "ch-" .. U.id_name(uid)
    body = tostring(body or "")
    style = tostring(style or "")
    for index, asset in ipairs(assets or {}) do
        local item = U.copy(asset)
        local old = tostring(item.href or "")
        local base = old:match("([^/]+)$") or ("asset-" .. tostring(index) .. ".bin")
        local new = "images/" .. prefix .. "-" .. tostring(index) .. "-" .. U.id_name(base)
        if old ~= "" and old ~= new then
            body = body:gsub(pattern_escape("../" .. old), "../" .. new)
            body = body:gsub(pattern_escape(old), new)
            -- Chapter CSS is merged into OEBPS/style.css, where image paths
            -- are relative to OEBPS rather than OEBPS/text. Keep CSS and XHTML
            -- references in sync with the per-chapter asset namespace.
            style = style:gsub(pattern_escape("../" .. old), new)
            style = style:gsub(pattern_escape(old), new)
        end
        item.href = new
        out[#out + 1] = item
    end
    return body, style, out
end

local function migrate_cached_style_assets(style, assets, uid)
    style = tostring(style or "")
    local prefix = "ch-" .. U.id_name(uid)
    for index, asset in ipairs(assets or {}) do
        local current = tostring(asset.href or "")
        local marker = "images/" .. prefix .. "-" .. tostring(index) .. "-"
        if current:sub(1, #marker) == marker then
            local old = "images/" .. current:sub(#marker + 1)
            if old ~= current then
                style = style:gsub(pattern_escape("../" .. old), current)
                style = style:gsub(pattern_escape(old), current)
            end
        end
    end
    return style
end

local function option_key(opt)
    return table.concat({
        opt.annotations and "notes" or "clean",
        opt.images == false and "no-images" or "images",
        opt.chapter_uid and ("chapter-" .. U.id_name(opt.chapter_uid))
            or ((opt.range_start_index and opt.range_end_index) and "range" or "book"),
    }, "-")
end

local function catalog_signature(chapters)
    local rows = {}
    for _, chapter in ipairs(chapters or {}) do
        rows[#rows + 1] = table.concat({
            tostring(chapter.chapterUid or chapter.uid or ""),
            tostring(chapter.wordCount or chapter.word_count or ""),
            tostring(chapter.title or ""),
        }, "\31")
    end
    return table.concat(rows, "\30")
end

local function relative(root, path)
    if path:sub(1, #root + 1) == root .. "/" then return path:sub(#root + 2) end
    return path
end

local function absolute(root, path)
    path = tostring(path or "")
    if path:sub(1, 1) == "/" then return path end
    return root .. "/" .. path
end

local function chapter_paths(cache, uid)
    local key = U.id_name(uid)
    local dir = cache.root .. "/chapters/" .. key
    return {
        dir = dir,
        base = dir .. "/base.xhtml",
        final = dir .. "/final.xhtml",
        css = dir .. "/style.css",
        asset_dir = dir .. "/assets",
    }
end

local function cache_save(cache)
    cache.manifest.updated_at = os.time()
    local ok, err = DownloadDatabase.save_manifest(cache.root, cache.manifest)
    if not ok then error("无法保存下载断点：" .. tostring(err)) end
end

local function cache_new(store, book, opt, selected, format)
    local root = store:book_dir(book.bookId) .. "/.miuread-partial-" .. option_key(opt)
    local path = DownloadDatabase.partial_path(root)
    local signature = catalog_signature(selected)
    local migrated, migration_error = DownloadDatabase.migrate_legacy_partial(root)
    if migrated == nil then error("无法迁移旧下载断点：" .. tostring(migration_error)) end
    local manifest = DownloadDatabase.load_manifest(root)
    local valid = manifest
        and tonumber(manifest.schema) == CACHE_SCHEMA
        and tostring(manifest.book_id or "") == tostring(book.bookId)
        and tostring(manifest.option_key or "") == option_key(opt)
        and tostring(manifest.format or "") == tostring(format)
    if not valid then
        U.remove_tree(root)
        U.mkdir(root .. "/chapters")
        local previous_record=type(opt.existing_download_record)=="table" and opt.existing_download_record or nil
        local inherited_title_version=previous_record and tonumber(previous_record.title_transform_version) or nil
        if not inherited_title_version and previous_record then
            inherited_title_version=previous_record.task_id and TITLE_TRANSFORM_VERSION
                or LEGACY_TITLE_TRANSFORM_VERSION
        end
        manifest = {
            schema = CACHE_SCHEMA,
            book_id = tostring(book.bookId),
            option_key = option_key(opt),
            signature = signature,
            format = format,
            title_transform_version = inherited_title_version or TITLE_TRANSFORM_VERSION,
            image_transform_version = IMAGE_TRANSFORM_VERSION,
            created_at = os.time(),
            updated_at = os.time(),
            chapters = {},
        }
        local wrote, write_error = DownloadDatabase.save_manifest(root, manifest)
        if not wrote then error("无法建立 SQLite 下载断点：" .. tostring(write_error)) end
    else
        U.mkdir(root .. "/chapters")
        manifest.signature = signature
        if tonumber(manifest.title_transform_version or 0) <= 0 then
            local detected
            for _, cached_entry in pairs(manifest.chapters or {}) do
                local version = tonumber(cached_entry.title_transform_version or 0)
                if version > 0 then detected = version; break end
            end
            manifest.title_transform_version = detected or LEGACY_TITLE_TRANSFORM_VERSION
        end
        if tonumber(manifest.image_transform_version or 0)<=0 then
            manifest.image_transform_version=1
        end
        manifest.updated_at = os.time()
        local wrote, write_error = DownloadDatabase.save_manifest(root, manifest)
        if not wrote then error("无法更新 SQLite 下载断点：" .. tostring(write_error)) end
    end
    return {root=root, path=path, manifest=manifest}
end

local function cache_reset_entry(cache, uid)
    local key = tostring(uid)
    local paths = chapter_paths(cache, uid)
    U.remove_tree(paths.dir)
    cache.manifest.chapters[key] = nil
    cache_save(cache)
end

local function cache_save_assets(cache, uid, assets)
    local paths = chapter_paths(cache, uid)
    U.mkdir(paths.asset_dir)
    local meta = {}
    for index, asset in ipairs(assets or {}) do
        local file = paths.asset_dir .. "/" .. string.format("%04d.bin", index)
        local ok, err = U.atomic_write(file, asset.data or "", true)
        if not ok then error("无法保存章节图片断点：" .. tostring(err)) end
        meta[#meta + 1] = {
            href = asset.href,
            mime = asset.mime,
            source = asset.source,
            file = relative(cache.root, file),
        }
    end
    local ok, err = DownloadDatabase.save_assets(cache.root, uid, meta)
    if not ok then error("无法保存 SQLite 图片清单：" .. tostring(err)) end
end

local function cache_load_assets(cache, entry)
    local meta = DownloadDatabase.load_assets(cache.root, entry.uid)
    if type(meta) ~= "table" then return nil, "图片断点清单缺失" end
    local assets = {}
    for _, item in ipairs(meta) do
        local data = U.read_file(absolute(cache.root, item.file), true)
        if data == nil then return nil, "章节图片断点缺失" end
        assets[#assets + 1] = {href=item.href, mime=item.mime, source=item.source, data=data}
    end
    return assets
end

local function cache_save_base(cache, chapter, body, style, assets, state)
    local uid = tostring(chapter.chapterUid or chapter.uid)
    local paths = chapter_paths(cache, uid)
    U.remove_tree(paths.dir)
    U.mkdir(paths.asset_dir)
    local ok, err = U.atomic_write(paths.base, body or "", true)
    if not ok then error("无法保存章节正文断点：" .. tostring(err)) end
    ok, err = U.atomic_write(paths.css, style or "", true)
    if not ok then error("无法保存章节样式断点：" .. tostring(err)) end
    cache_save_assets(cache, uid, assets)
    local entry = cache.manifest.chapters[uid] or {}
    entry.uid = uid
    entry.title = chapter.title
    entry.index = chapter.chapterIdx
    entry.word_count = tonumber(chapter.wordCount or chapter.word_count or 0) or 0
    entry.content_done = true
    entry.complete = false
    entry.base_file = relative(cache.root, paths.base)
    entry.css_file = relative(cache.root, paths.css)
    entry.content_format = state and state.content_format
    entry.structural = state and state.structural == true or false
    entry.image_only = state and state.image_only == true or false
    entry.image_summary = state and state.image_summary or nil
    entry.image_transform_version = IMAGE_TRANSFORM_VERSION
    entry.title_transform_version = tonumber(entry.title_transform_version
        or cache.manifest.title_transform_version) or TITLE_TRANSFORM_VERSION
    entry.error = nil
    cache.manifest.chapters[uid] = entry
    if state and (state.psvts or state.pclts or state.token or state.url) then
        cache.manifest.session = {
            psvts=state.psvts, pclts=state.pclts, token=state.token,
            url=state.url, content_format=state.content_format,
        }
    end
    cache_save(cache)
    return entry
end

local function cache_load_base(cache, entry)
    if not entry or not entry.content_done then return nil, "正文断点不存在" end
    local body = U.read_file(absolute(cache.root, entry.base_file), true)
    local style = U.read_file(absolute(cache.root, entry.css_file), true)
    local assets, asset_error = cache_load_assets(cache, entry)
    if body == nil or style == nil or not assets then return nil, asset_error or "正文断点文件缺失" end
    return body, style, assets
end

local function cache_save_final(cache, chapter, body, annotation, style, footnote_stats)
    local uid = tostring(chapter.chapterUid or chapter.uid)
    local entry = cache.manifest.chapters[uid]
    if not entry or not entry.content_done then error("正文断点尚未建立") end
    local paths = chapter_paths(cache, uid)
    local ok, err = U.atomic_write(paths.final, body or "", true)
    if not ok then error("无法保存完成章节断点：" .. tostring(err)) end
    ok, err = U.atomic_write(paths.css, style or "", true)
    if not ok then error("无法保存完成章节样式：" .. tostring(err)) end
    entry.final_file = relative(cache.root, paths.final)
    entry.complete = true
    entry.error = nil
    entry.underlines = annotation and (annotation.underline_count or 0) or 0
    entry.thoughts = annotation and (annotation.thought_count or 0) or 0
    entry.thought_entries = annotation and (annotation.thought_entry_count or 0) or 0
    entry.footnote_transform_version = FOOTNOTE_TRANSFORM_VERSION
    entry.title_transform_version = tonumber(entry.title_transform_version
        or cache.manifest.title_transform_version) or TITLE_TRANSFORM_VERSION
    entry.annotation_transform_version = annotation and ANNOTATION_TRANSFORM_VERSION
        or tonumber(entry.annotation_transform_version or 0)
    entry.footnote_candidates = footnote_stats and tonumber(footnote_stats.candidates or footnote_stats.refs or 0) or 0
    entry.footnote_refs = footnote_stats and tonumber(footnote_stats.refs or 0) or 0
    entry.footnotes_converted = footnote_stats and tonumber(footnote_stats.converted or 0) or 0
    entry.footnotes_backlinks = footnote_stats and tonumber(footnote_stats.backlinks or 0) or 0
    entry.footnotes_inferred_backlinks = footnote_stats and tonumber(footnote_stats.inferred_backlinks or 0) or 0
    entry.footnotes_missing = footnote_stats and tonumber(footnote_stats.unresolved or 0) or 0
    entry.footnotes_deferred = footnote_stats and tonumber(footnote_stats.deferred or 0) or 0
    entry.footnotes_fallback = footnote_stats and footnote_stats.fallback == true or false
    entry.footnotes_fallback_reason = footnote_stats and footnote_stats.fallback_reason or nil
    cache_save(cache)
    return entry
end

local function cache_load_asset_sources(cache, entry)
    local meta = DownloadDatabase.load_assets(cache.root, entry.uid)
    if type(meta) ~= "table" then return nil, "图片断点清单缺失" end
    local assets = {}
    for _, item in ipairs(meta) do
        local file = absolute(cache.root, item.file)
        if U.file_size(file) == nil then return nil, "章节图片断点缺失" end
        assets[#assets + 1] = {
            href=item.href, mime=item.mime, source=item.source, data_path=file,
        }
    end
    return assets
end

local function cache_load_final_source(cache, entry)
    if not entry or not entry.complete then return nil, "完成断点不存在" end
    local body_path = absolute(cache.root, entry.final_file)
    if U.file_size(body_path) == nil then return nil, "完成章节正文断点缺失" end
    local style = U.read_file(absolute(cache.root, entry.css_file), true)
    local assets, asset_error = cache_load_asset_sources(cache, entry)
    if style == nil or not assets then return nil, asset_error or "完成断点文件缺失" end
    return body_path, style, assets
end

local function validate_cached_chapter(path)
    local raw, read_error=U.read_file(path,true)
    if type(raw)~="string" then return nil,read_error or "无法读取完成章节断点" end
    local valid, validation_error=Footnotes.validate(raw)
    raw=nil
    return valid,validation_error
end


function Downloader:new(reader, api, annotations, store, http)
    return setmetatable({reader=reader, api=api, annotations=annotations, store=store, http=http}, self)
end

local function catalog_level(chapter)
    chapter = type(chapter) == "table" and chapter or {}
    return tonumber(chapter.level or chapter.chapterLevel or chapter.chapter_level or chapter.depth)
end

local function catalog_has_children(source, index)
    local chapter = source[index]
    if type(chapter) ~= "table" then return false end
    local declared = tonumber(chapter.childCount or chapter.childrenCount or chapter.subChapterCount or 0) or 0
    if declared > 0 then return true end
    local level = catalog_level(chapter)
    local next_level = catalog_level(source[index + 1])
    return level ~= nil and next_level ~= nil and next_level > level
end

function Downloader:catalog(id)
    local catalog = self.reader:catalog(id)
    local source = catalog.updated or catalog.chapterInfos or catalog.chapters or {}
    -- The chapterInfos response does not report the book format. Read it from
    -- the reader page context instead; on failure keep the raw titles rather
    -- than guessing.
    local book_format
    local ok_state, state = pcall(self.reader.access_state, self.reader, id)
    if ok_state and type(state) == "table" and type(state.book) == "table" then
        book_format = state.book.format
    else
        logger.warn("[MiuRead][Download] book format unavailable; keeping raw catalog titles",
            "book=", tostring(id), "error=", ok_state and "reader context has no book info" or tostring(state))
    end
    local out, seen = {}, {}
    for index, chapter in ipairs(source) do
        local uid = tostring(chapter.chapterUid or chapter.uid or "")
        chapter._miuread_has_children = catalog_has_children(source, index)
        chapter._miuread_catalog_index = index
        -- Do not decide readability from title or wordCount. Those fields are
        -- hints only and are inconsistent for short, image-only and special
        -- catalog items. Actual EPUB/TXT responses determine the result.
        if uid ~= "" and not seen[uid]
            and not self.reader._is_cover_chapter(chapter)
            and not self.reader._is_unavailable_chapter(chapter) then
            seen[uid] = true
            -- The official web reader displays every catalog title of a txt
            -- (web novel) book as "第{chapterIdx}章 {title}" and uses EPUB
            -- titles as-is. Mirror that rule so headings and the TOC match
            -- the official display.
            if book_format == "txt" then
                local idx = tonumber(chapter.chapterIdx)
                if idx then
                    local title = tostring(chapter.title or "")
                    chapter.title = title == "" and ("第" .. tostring(idx) .. "章")
                        or ("第" .. tostring(idx) .. "章 " .. title)
                end
            end
            if tostring(chapter.title or ""):gsub("%s+", "") == "" then
                chapter.title = "第 " .. tostring(#out + 1) .. " 节"
            end
            out[#out + 1] = chapter
        end
    end
    return catalog, out
end

function Downloader:_cover(book, enabled)
    if not enabled or not book.cover or book.cover == "" then return nil end
    local ok, data = pcall(self.http.download, self.http, book.cover, {auth=false, retries=3})
    if not ok or not data or #data == 0 then return nil end
    local ext, mime = Codec.media(data)
    return {data=data, ext=ext, mime=mime}
end

local function repair_internal_links(chapters)
    local file_entries, all_on_disk = {}, true
    for index, chapter in ipairs(chapters or {}) do
        if not chapter.body_path then all_on_disk = false; break end
        file_entries[index] = {
            path = string.format("OEBPS/text/chapter-%04d.xhtml", index),
            full = chapter.body_path,
        }
    end

    if all_on_disk then
        local stats, repair_error = InternalLinks.rewrite_files_strict(file_entries, {sample_limit = 12, neutralize_unresolved = true})
        if not stats then error("书内链接索引失败：" .. tostring(repair_error)) end
        if repair_error then
            local detail = #(stats.samples or {}) > 0 and ("\n" .. table.concat(stats.samples, "\n")) or ""
            error("书内链接处理未完成：" .. tostring(repair_error) .. detail)
        end
        logger.info("[MiuRead][InternalLinks] low-memory links=", tostring(stats.links or 0),
            "rewritten=", tostring(stats.rewritten or 0),
            "unresolved=", tostring(stats.unresolved or 0),
            "critical=", tostring(stats.unresolved_critical or 0),
            "dropped=", tostring(stats.dropped or 0),
            "aliases=", tostring(stats.aliases and stats.aliases.resolved or 0))
        collectgarbage("collect")
        return stats
    end

    -- Small in-memory fallback for article downloads that do not use chapter
    -- checkpoint files.
    local documents = {}
    for index, chapter in ipairs(chapters or {}) do
        local raw, read_error
        if chapter.body_path then raw, read_error = U.read_file(chapter.body_path, true)
        else raw = tostring(chapter.body or "") end
        if type(raw) ~= "string" then
            error("无法读取章节以检查内部链接：" .. tostring(read_error or chapter.title or index))
        end
        documents[index] = {
            path = string.format("OEBPS/text/chapter-%04d.xhtml", index),
            html = raw,
            chapter = chapter,
        }
    end
    local stats = InternalLinks.rewrite_documents_strict(documents, {sample_limit = 12, neutralize_unresolved = true})
    for index, doc in ipairs(documents) do
        if doc.changed then
            local chapter = chapters[index]
            if chapter.body_path then
                local ok, write_error = U.atomic_write(chapter.body_path, doc.html, true)
                if not ok then error("无法写入修复后的章节：" .. tostring(write_error or index)) end
            else
                chapter.body = doc.html
            end
        end
    end
    local valid, validation_error, validation_stats = InternalLinks.validate_documents(documents, {sample_limit = 12})
    if not valid then
        local detail = validation_stats and #validation_stats.samples > 0
            and ("\n" .. table.concat(validation_stats.samples, "\n")) or ""
        error("书内链接验证失败：" .. tostring(validation_error) .. detail)
    end
    return stats
end

function Downloader:_save(book, chapters, assets, css, cover, opt, failures, session)
    local kind = opt.annotations and "notes" or "clean"
    local expected_chapter_count = tonumber(opt.expected_chapter_count) or #chapters
    local preview_mode=tostring(opt.preview_mode or "complete")
    local relaxed_preview=opt.access_scope=="preview" and (preview_mode=="partial" or preview_mode=="info")
    if not relaxed_preview and (#chapters ~= expected_chapter_count or #(failures or {}) > 0) then
        error(failure_message(failures, expected_chapter_count, #chapters, opt.checkpointed == true))
    end
    if #chapters<=0 then error("EPUB 至少需要一个说明页面") end

    local suffix = kind == "notes" and "划线与想法版" or "纯净版"
    local dir = self.store:epub_root()
    local standalone = opt.chapter_uid ~= nil
    local partial_range = not standalone and opt.range_start_index ~= nil and opt.range_end_index ~= nil
    local access_scope=tostring(opt.access_scope or "full")
    local storage_kind=partial_range and ("range_"..kind)
        or ((access_scope=="preview" and not standalone) and ("preview_"..kind) or kind)
    local existing_record
    if standalone then existing_record=self.store:chapter_variant(book.bookId,opt.chapter_uid,storage_kind)
    else existing_record=self.store:variant(book.bookId,storage_kind) end

    local chapter_name = standalone and (" - " .. U.safe_name(chapters[1] and chapters[1].title or "章节")) or ""
    local range_name = partial_range and "【章节版】" or ""
    local preview_name=""
    if not standalone and opt.access_scope=="preview" then
        if preview_mode=="info" then preview_name="【试读信息版】"
        elseif preview_mode=="partial" then preview_name="【试读版·部分内容】"
        else preview_name="【试读版】" end
    end
    local filename=U.safe_name(book.title,"book")..preview_name..range_name..chapter_name.." ["..suffix.."].epub"
    local path=self.store:epub_path(filename)
    -- Keep the exact path of an existing variant. KOReader sidecar notes are
    -- associated with the document path, so a title or filename change must not
    -- silently create a second EPUB and leave the old .sdr behind.
    local recorded_path=type(existing_record)=="table" and tostring(existing_record.file or "") or ""
    if recorded_path~="" then
        path=recorded_path
        filename=recorded_path:match("([^/]+)$") or filename
    end
    if U.file_exists(path) then
        local identity=type(self.store.epub_identity)=="function" and self.store:epub_identity(path) or nil
        local same_identity=type(identity)=="table"
            and tostring(identity.book_id or "")==tostring(book.bookId)
            and (tostring(identity.variant or "")=="" or tostring(identity.variant)==storage_kind)
            and (not standalone or tostring(identity.chapter_uid or "")==tostring(opt.chapter_uid))
        if not same_identity and type(existing_record)=="table" and tostring(existing_record.file or "")==tostring(path) then
            same_identity=true
        end
        if not same_identity and recorded_path=="" then
            local collision_id=standalone and (tostring(book.bookId).."-"..tostring(opt.chapter_uid)) or tostring(book.bookId)
            local stem=filename:gsub("%.epub$","")
            filename=stem.." ["..U.id_name(collision_id):sub(-12).."].epub"
            path=self.store:epub_path(filename)
        end
    end
    local map = {}
    for index, chapter in ipairs(chapters) do
        map[#map + 1] = {
            uid=chapter.uid, index=chapter.index or index, title=chapter.title,
            word_count=chapter.word_count or 0, structural=chapter.structural == true,
        }
    end

    local function ensure_not_cancelled()
        if opt.cancelled and opt.cancelled() then error("download cancelled") end
    end
    ensure_not_cancelled()
    local previous_chapters=type(opt.previous_chapter_map)=="table" and opt.previous_chapter_map
        or (type(existing_record)=="table" and existing_record.chapter_map or nil)
    if opt.annotations==true and opt.annotation_pending==true then
        logger.warn("[MiuRead][Download] packaging正文 with deferred annotations",
            "book=",tostring(book.bookId),"kind=",tostring(opt.annotation_error_kind or "incomplete"))
    end

    local estimate=1024*1024
    for _,chapter in ipairs(chapters) do
        estimate=estimate+(chapter.body_path and (U.file_size(chapter.body_path) or 0) or #tostring(chapter.body or ""))
    end
    for _,asset in ipairs(assets) do
        estimate=estimate+(asset.data_path and (U.file_size(asset.data_path) or 0) or #tostring(asset.data or ""))
    end
    if cover then estimate=estimate+(cover.data_path and (U.file_size(cover.data_path) or 0) or #tostring(cover.data or "")) end
    local free=U.free_space(dir)
    local required=estimate+(U.file_size(path) or 0)+8*1024*1024
    if free and free<required then
        error("存储空间不足，未生成新的 EPUB。原文件和下载断点均已保留。")
    end

    local link_stats=repair_internal_links(chapters)
    ensure_not_cancelled()

    -- Final XHTML and CSS are the source of truth. Footnote conversion and
    -- annotation injection may intentionally remove an earlier image marker,
    -- so prune no-longer-referenced candidates instead of treating them as a
    -- corrupt book or listing them in the OPF manifest.
    local final_assets,resource_stats,resource_error=ResourceRefs.prune(chapters,css,assets)
    if not final_assets then
        logger.warn("[MiuRead][Download] final resource scan failed",tostring(resource_error))
        error("书籍内容整理失败，未覆盖原文件。 [MiuReadResourceScan]")
    end
    logger.info("[MiuRead][Download] final image references",
        "references=",tostring(resource_stats.references or 0),
        "kept=",tostring(resource_stats.kept or 0),
        "pruned=",tostring(resource_stats.pruned or 0),
        "embedded=",tostring(resource_stats.embedded or 0),
        "missing=",tostring(resource_stats.missing or 0),
        "external=",tostring(resource_stats.external or 0))
    if tonumber(resource_stats.missing or 0)>0 then
        logger.warn("[MiuRead][Download] final image references missing",
            table.concat(resource_stats.missing_samples or {},","))
        error("书籍正文图片未完整获取，未覆盖原文件。 [MiuReadImageMissing]")
    end
    if tonumber(resource_stats.external or 0)>0 then
        logger.warn("[MiuRead][Download] final image references remain external",
            table.concat(resource_stats.external_samples or {},","))
        error("书籍正文图片尚未完成本地化，未覆盖原文件。 [MiuReadImageExternal]")
    end
    assets=final_assets
    opt.image_summary=type(opt.image_summary)=="table" and opt.image_summary or {}
    opt.image_summary.final_referenced=tonumber(resource_stats.references or 0) or 0
    opt.image_summary.orphan_pruned=tonumber(resource_stats.pruned or 0) or 0
    opt.image_summary.embedded=math.max(tonumber(opt.image_summary.embedded or 0) or 0,
        tonumber(resource_stats.embedded or 0) or 0)
    opt.image_summary.assets=#assets

    local stamp=tostring(opt.download_run_id or os.time()):gsub("[^%w%-]","-")
    local temp_path=path:gsub("%.epub$","")..".miuread-new-"..stamp..".epub"
    os.remove(temp_path)
    collectgarbage("collect")
    logger.info("[MiuRead][Download] low-memory EPUB package started",
        "chapters=",tostring(#chapters),"assets=",tostring(#assets),
        "memory_kb=",tostring(math.floor(collectgarbage("count"))))
    local now=os.time()
    local built,build_error=pcall(Epub.build,temp_path,book,chapters,css,assets,cover,{
        schema=8,book_id=book.bookId,title=book.title,author=book.author,
        variant=storage_kind,base_variant=kind,standalone=standalone,chapter_uid=opt.chapter_uid,
        partial_range=partial_range,range_start_index=tonumber(opt.range_start_index),
        range_end_index=tonumber(opt.range_end_index),range_start_title=opt.range_start_title,
        range_end_title=opt.range_end_title,content_type="book",
        sync_enabled=not partial_range,read_report_enabled=not partial_range,
        chapters=map,generated_at=now,complete=true,task_id=opt.download_run_id,
        title_transform_version=tonumber(opt.title_transform_version) or TITLE_TRANSFORM_VERSION,
        access_scope=access_scope,catalog_count=tonumber(opt.catalog_chapter_count) or expected_chapter_count,
        readable_count=tonumber(opt.readable_chapter_count) or #chapters,
        restricted_count=tonumber(opt.restricted_chapter_count) or 0,
        preview_mode=access_scope=="preview" and preview_mode or nil,
        failed_count=tonumber(opt.failed_chapter_count) or #(failures or {}),
        guard_chapter_uid=opt.guard_chapter_uid or (chapters[#chapters] and chapters[#chapters].uid),
        annotation_requested=opt.annotation_requested==true or opt.annotations==true,
        annotation_pending=opt.annotation_pending==true or nil,
        annotation_fallback=opt.annotation_fallback==true or nil,
        annotation_error_kind=opt.annotation_error_kind,
        images=U.copy(opt.image_summary or {}),
        image_transform_version=IMAGE_TRANSFORM_VERSION,
        internal_links={links=link_stats.links or 0,rewritten=link_stats.rewritten or 0,
            unresolved=link_stats.unresolved or 0,critical=link_stats.unresolved_critical or 0},
    })
    if not built then os.remove(temp_path); error(build_error) end
    ensure_not_cancelled()
    local validation_options={book_id=book.bookId,variant=storage_kind,chapters=map,previous_chapters=previous_chapters,
        image_summary=U.copy(opt.image_summary or {})}
    local valid,validation_error=EpubInstaller.validate(temp_path,validation_options)
    if not valid then
        logger.warn("[MiuRead][Download] EPUB validation failed",tostring(validation_error))
        os.remove(temp_path)
        error("书籍内容验证未通过，未覆盖原文件。 [MiuReadEpubValidation]")
    end
    logger.info("[MiuRead][Download] low-memory EPUB package completed",
        "bytes=",tostring(U.file_size(temp_path) or 0),
        "memory_kb=",tostring(math.floor(collectgarbage("count"))))

    local active_path=tostring(opt.active_document_path or "")
    local defer_install=active_path~="" and active_path==tostring(path) and U.file_exists(path)
    local pending_path
    ensure_not_cancelled()
    if defer_install then
        pending_path=path:gsub("%.epub$","")..".miuread-pending-"..stamp..".epub"
        local staged,stage_mode_or_error=EpubInstaller.stage(temp_path,pending_path,validation_options)
        if not staged then os.remove(temp_path); error("无法暂存当前正在阅读书籍的新版本："..tostring(stage_mode_or_error)) end
        local old_pending=type(existing_record)=="table" and tostring(existing_record.pending_file or "") or ""
        if old_pending~="" and old_pending~=pending_path and U.file_exists(old_pending) then os.remove(old_pending) end
        logger.info("[MiuRead][Download] pending EPUB staged","mode=",tostring(stage_mode_or_error))
    else
        local installed,install_mode_or_error=EpubInstaller.install(temp_path,path,validation_options)
        if not installed then os.remove(temp_path); error("无法安装新 EPUB："..tostring(install_mode_or_error)) end
        logger.info("[MiuRead][Download] EPUB installed","mode=",tostring(install_mode_or_error))
    end

    local record = {
        book_id=book.bookId, title=book.title, author=book.author, cover=book.cover,
        file=path, directory=dir, variant=storage_kind, base_variant=kind, downloaded_at=now,
        content_type="book",
        sync_enabled=not partial_range,
        read_report_enabled=not partial_range,
        partial_range=partial_range,range_start_index=tonumber(opt.range_start_index),
        range_end_index=tonumber(opt.range_end_index),range_start_title=opt.range_start_title,
        range_end_title=opt.range_end_title,
        chapter_count=#chapters, expected_chapter_count=expected_chapter_count,
        catalog_chapter_count=tonumber(opt.catalog_chapter_count) or expected_chapter_count,
        readable_chapter_count=tonumber(opt.readable_chapter_count) or #chapters,
        restricted_chapter_count=tonumber(opt.restricted_chapter_count) or 0,
        failed_chapter_count=tonumber(opt.failed_chapter_count) or #(failures or {}),
        preview_mode=access_scope=="preview" and preview_mode or nil,
        access_scope=access_scope,
        guard_chapter_uid=opt.guard_chapter_uid or (chapters[#chapters] and chapters[#chapters].uid),
        chapter_map=map,failures=U.copy(failures or {}),complete=true,
        file_size=defer_install and U.file_size(pending_path) or U.file_size(path),
        previous_chapter_map=defer_install and U.copy(previous_chapters or {}) or nil,
        task_id=opt.download_run_id,
        title_transform_version=tonumber(opt.title_transform_version) or TITLE_TRANSFORM_VERSION,
        pending_install=defer_install or nil,
        pending_file=pending_path,
        annotation_requested=opt.annotation_requested==true or opt.annotations==true,
        annotation_pending=opt.annotation_pending==true or nil,
        annotation_fallback=opt.annotation_fallback==true or nil,
        annotation_error_kind=opt.annotation_error_kind,
        annotation_errors=U.copy(opt.annotation_errors or {}),
        annotation_account_key=opt.annotations and annotation_account_key or nil,
        image_count=#assets,image_summary=U.copy(opt.image_summary or {}),
        image_transform_version=IMAGE_TRANSFORM_VERSION,
    }
    if standalone then
        record.chapter_uid = tostring(opt.chapter_uid)
        self.store:save_chapter_variant(book.bookId, opt.chapter_uid, storage_kind, record)
    else
        self.store:save_variant(book.bookId, storage_kind, record)
    end
    self.store:save_book(book.bookId, {
        book_id=book.bookId, title=book.title, author=book.author, cover=book.cover,
        directory=dir, updated_at=now, catalog=(type(opt.full_catalog_map)=="table" and opt.full_catalog_map or map),
        content_type="book",
    })
    if type(self.store.clear_book_access)=="function" then self.store:clear_book_access(book.bookId) end
    if session then
        self.store:save_session(book.bookId, {
            psvts=session.psvts, pclts=session.pclts, token=session.token,
            reader_url=session.url, chapters=map, context_updated_at=os.time(),
            app_id=Protocol.app_id(Protocol.USER_AGENT),
        })
    end
    return record
end

local function append_entry(chapters, assets, css_list, css_seen, entry, body_source, style, chapter_assets, index)
    style = migrate_cached_style_assets(style, chapter_assets, entry and entry.uid)
    css_add(css_list, css_seen, style)
    for _, asset in ipairs(chapter_assets or {}) do assets[#assets + 1] = asset end
    local chapter = {
        title=entry.title or ("第 " .. tostring(index) .. " 章"),
        uid=entry.uid, index=entry.index or index,
        word_count=tonumber(entry.word_count or 0) or 0,
        structural=entry.structural == true,
    }
    if type(body_source) == "table" and body_source.path then
        chapter.body_path = body_source.path
    else
        chapter.body = body_source
    end
    chapters[#chapters + 1] = chapter
end

function Downloader:book(input, opt, progress)
    opt = opt or {}
    progress = progress or function() end
    local function respect_reader_priority(stage)
        local pause_logged=false
        local function worker_paused()
            return type(opt.paused)=="function" and opt.paused()==true
        end
        while worker_paused() do
            if type(opt.cancelled)=="function" and opt.cancelled() then error("download cancelled") end
            if not pause_logged then
                pause_logged=true
                logger.info("[MiuRead][Download] worker paused",tostring(stage or "work"))
            end
            pause(.25)
        end
        if pause_logged then logger.info("[MiuRead][Download] worker resumed",tostring(stage or "work")) end

        local active_path=tostring(opt.reader_active_path or "")
        if active_path=="" or not U.file_exists(active_path) then return end
        local busy_until=tonumber(U.read_file(tostring(opt.reader_busy_path or ""),true) or 0) or 0
        local waited=0
        while busy_until>os.time() and waited<30 do
            if type(opt.cancelled)=="function" and opt.cancelled() then error("download cancelled") end
            if worker_paused() then return respect_reader_priority(stage) end
            pause(.25)
            waited=waited+.25
            busy_until=tonumber(U.read_file(tostring(opt.reader_busy_path or ""),true) or 0) or 0
        end
        pause(stage=="chapter" and .12 or .05)
    end
    local book = normalized_book(input)
    if book.bookId == "" then error("bookId missing") end

    local chapters, assets, failures = {}, {}, {}
    local annotation_summary = {underlines=0, thoughts=0, chapters_ok=0, chapters_failed=0, errors={}}
    local css_list, css_seen = {}, {}
    css_add(css_list, css_seen, BASE_CSS)
    local session, expected = nil, 0

    if Protocol.is_mp(book.bookId) then
        error("公众号文章请在公众号文章列表中单篇打开")
    end

    respect_reader_priority("catalog")
    progress("catalog", 0, 1, book.title)
    local catalog, all = self:catalog(book.bookId)
    local full_catalog_map={}
    for index,chapter in ipairs(all or {}) do
        full_catalog_map[#full_catalog_map+1]={
            uid=chapter.chapterUid or chapter.uid,
            index=tonumber(chapter.chapterIdx or chapter.index) or index,
            title=chapter.title,
            word_count=tonumber(chapter.wordCount or chapter.word_count) or 0,
            structural=chapter.structural==true,
        }
    end
    opt.full_catalog_map=full_catalog_map
    local requested_kind=opt.annotations==true and "notes" or "clean"
    local existing_range=(opt.range_start_index and opt.range_end_index)
        and self.store:variant(book.bookId,"range_"..requested_kind) or nil
    local existing_download_record
    if opt.chapter_uid then
        existing_download_record=self.store:chapter_variant(book.bookId,opt.chapter_uid,requested_kind)
    elseif existing_range then
        existing_download_record=existing_range
    else
        existing_download_record=self.store:variant(book.bookId,requested_kind)
    end
    opt.existing_download_record=existing_download_record
    local selected=DownloadPlan.select(all,opt,existing_range)
    if type(opt.missing_previous_chapter_uids)=="table" and #opt.missing_previous_chapter_uids>0 then
        error("微信读书目录已经变化，无法安全覆盖已有章节版。原文件已保留；请删除旧章节版后重新生成。")
    end
    if #selected == 0 then error("no readable chapter") end
    expected = #selected
    local format = catalog.format == "txt" and "txt" or "epub"
    local cache = cache_new(self.store, book, opt, selected, format)
    opt.title_transform_version=tonumber(cache.manifest.title_transform_version) or TITLE_TRANSFORM_VERSION
    session = cache.manifest.session
    local failure_map, restricted_map = {}, {}
    local requested_annotations=opt.annotations==true
    opt.download_run_id=tostring(opt.download_run_id or (os.time().."-"..math.random(100000,999999)))
    local annotation_account_key=DownloadDatabase.account_key(self.store)
    local annotation_suspended=false
    local annotation_error_kind=nil
    local annotation_error_map={}
    local annotation_recovery_attempted=false
    local function chapter_uid(chapter)
        return tostring(chapter and (chapter.chapterUid or chapter.uid) or "")
    end
    local function record_annotation_error(chapter,annotation)
        local uid=chapter_uid(chapter)
        local message=table.concat(annotation and annotation.errors or {},"; ")
        if message=="" then message="批注数据尚未完整" end
        annotation_error_map[uid]={uid=uid,title=chapter and chapter.title,error=message,
            error_kind=annotation and annotation.error_kind or "incomplete"}
        annotation_error_kind=annotation_error_kind or (annotation and annotation.error_kind) or "incomplete"
    end

    local function fetch_annotation(chapter,report_progress)
        local uid=chapter_uid(chapter)
        local previous=DownloadDatabase.load_annotation_data(cache.root,uid,annotation_account_key,self.annotations)
        if annotation_suspended then
            local cached=previous or self.annotations:from_cache({book_id=book.bookId,chapter_uid=uid})
            cached.complete=false
            cached.review_complete=false
            cached.error_kind=annotation_error_kind or "deferred"
            cached.errors=cached.errors or {}
            if #cached.errors==0 then
                if cached.error_kind=="rate_limit" then
                    cached.errors[#cached.errors+1]="划线和想法请求暂时受限，正文继续下载，稍后可从断点补全"
                elseif cached.error_kind=="forbidden" then
                    cached.errors[#cached.errors+1]="划线和想法接口暂时不可用，正文继续下载"
                else
                    cached.errors[#cached.errors+1]="划线和想法暂未补全，正文继续下载"
                end
            end
            return cached
        end

        local function persist_checkpoint(snapshot)
            local merged=self.annotations:merge(previous,snapshot)
            merged.saved_at=os.time()
            local saved,save_error=DownloadDatabase.save_annotation_data(cache.root,uid,annotation_account_key,self.annotations,merged)
            if not saved then error("无法保存批注断点："..tostring(save_error)) end
            previous=DownloadDatabase.load_annotation_data(cache.root,uid,annotation_account_key,self.annotations) or merged
            -- Keep the compact per-download checkpoint after every successful
            -- batch, but update the shared popup cache only once when the
            -- chapter finishes. This avoids dozens of redundant Kindle writes.
            return previous
        end

        local function fetch_once()
            return self.annotations:fetch_chapter(book.bookId,chapter.chapterUid or chapter.uid,
                function(stage,current_index,total)
                    respect_reader_priority("annotation_batch")
                    if report_progress then report_progress(stage,current_index,total) end
                end,
                {previous=previous,checkpoint=persist_checkpoint})
        end

        local ok,current=pcall(fetch_once)
        if not ok or type(current)~="table" then
            current={book_id=tostring(book.bookId),chapter_uid=uid,underlines={},review_map={},review_groups={},
                underline_count=0,thought_count=0,thought_entry_count=0,underline_request_ok=false,
                review_complete=false,complete=false,error_kind="server",errors={tostring(current)}}
        end

        if (current.auth_required==true or current.forbidden==true) and not annotation_recovery_attempted
            and self.reader and type(self.reader._recover_login_session)=="function" then
            annotation_recovery_attempted=true
            local recovered,recover_error=self.reader:_recover_login_session()
            logger.info("[MiuRead][Download] annotation login renewal attempted",
                "renewed=",tostring(recovered),"book=",tostring(book.bookId),
                "error=",recovered and "" or tostring(recover_error))
            if recovered then
                local retry_ok,retry_annotation=pcall(fetch_once)
                if retry_ok and type(retry_annotation)=="table" then
                    current=retry_annotation
                    if current.complete==true or (current.auth_required~=true and current.forbidden~=true) then
                        logger.info("[MiuRead][Download] annotation access restored after renewal",
                            "book=",tostring(book.bookId),"chapter=",uid)
                    else
                        logger.warn("[MiuRead][Download] annotation access still unavailable after renewal",
                            "book=",tostring(book.bookId),"chapter=",uid,
                            "kind=",tostring(current.error_kind or "incomplete"))
                    end
                else
                    current.errors=current.errors or {}
                    current.errors[#current.errors+1]=tostring(retry_annotation)
                    logger.warn("[MiuRead][Download] annotation endpoint retry failed after renewal",
                        "book=",tostring(book.bookId),"chapter=",uid,
                        "error=",tostring(retry_annotation))
                end
            else
                current.errors=current.errors or {}
                current.errors[#current.errors+1]="自动续期失败："..tostring(recover_error)
            end
        end

        local merged
        if current==previous then
            merged=current
        else
            merged=self.annotations:merge(previous,current)
        end
        merged.saved_at=os.time()
        local saved,save_error=DownloadDatabase.save_annotation_data(cache.root,uid,annotation_account_key,self.annotations,merged)
        if not saved then error("无法保存批注断点："..tostring(save_error)) end

        if current.auth_required==true then
            error(table.concat(current.errors or {},"; ")~="" and table.concat(current.errors or {},"; ")
                or "登录状态已失效 [MiuReadAuth]")
        end
        if current.rate_limited==true then
            annotation_suspended=true
            annotation_error_kind="rate_limit"
            merged.complete=false
            merged.review_complete=false
            merged.rate_limited=true
            merged.error_kind="rate_limit"
            merged.errors=merged.errors or {}
            if #merged.errors==0 then
                merged.errors[#merged.errors+1]="划线和想法请求暂时受限，正文继续下载，稍后可从断点补全"
            end
            local resaved,resave_error=DownloadDatabase.save_annotation_data(
                cache.root,uid,annotation_account_key,self.annotations,merged)
            if not resaved then error("无法保存批注断点："..tostring(resave_error)) end
            logger.warn("[MiuRead][Download] annotation rate limit deferred without stopping content",
                "book=",tostring(book.bookId),"chapter=",uid)
        end
        if current.forbidden==true then
            annotation_suspended=true
            annotation_error_kind="forbidden"
        elseif merged.complete~=true and tostring(current.error_kind or "")~="data" then
            annotation_suspended=true
            annotation_error_kind=current.error_kind or "incomplete"
        end

        if type(merged.review_groups)=="table" then
            Thoughts.save(self.store,book.bookId,chapter.chapterUid or chapter.uid,merged.review_groups)
        end
        return merged
    end

    local function mark_failure(chapter, message)
        local uid = tostring(chapter.chapterUid or chapter.uid)
        local item = {uid=uid, title=chapter.title, error=tostring(message)}
        failure_map[uid] = item
        local failed_entry = cache.manifest.chapters[uid] or {uid=uid, title=chapter.title}
        failed_entry.error = tostring(message)
        failed_entry.complete = false
        cache.manifest.chapters[uid] = failed_entry
        cache_save(cache)
        return false
    end

    local function mark_restricted(chapter, message)
        local uid=tostring(chapter.chapterUid or chapter.uid)
        restricted_map[uid]={uid=uid,title=chapter.title,error=tostring(message)}
        failure_map[uid]=nil
        local entry=cache.manifest.chapters[uid] or {uid=uid,title=chapter.title}
        entry.restricted=true
        entry.restricted_error=tostring(message)
        entry.error=nil
        entry.complete=false
        cache.manifest.chapters[uid]=entry
        cache_save(cache)
        logger.info("[MiuRead][Download] chapter limited by official preview",
            "chapter=",uid,"title=",tostring(chapter.title or ""))
        return true
    end

    local function finalize_chapter(chapter,index,entry,body,style,annotation,detail_message)
        respect_reader_priority("transform")
        local uid=tostring(chapter.chapterUid or chapter.uid)
        if detail_message then
            progress("resume",index,expected,chapter.title,{message=detail_message})
        end
        progress("footnotes", index, expected, chapter.title)
        local content_format = entry and entry.content_format or format
        local original_body = body
        local original_style = style
        local foot_stats
        local processed, foot_body, foot_section, stats_or_error = pcall(Footnotes.process, body, {
            is_txt=content_format == "txt" or format == "txt",
            book_dir=cache.root,
            current_chapter_uid=uid,
            defer_cross_file=true,
        })

        if not processed then
            foot_stats={
                candidates=0,refs=0,converted=0,backlinks=0,image_notes=0,
                unresolved=0,deferred=0,fallback=true,fallback_reason="process_error",
            }
            body=original_body
            style=original_style
            logger.warn("[MiuRead][Download] footnote transform fallback",
                "chapter=",uid,"reason=process_error","error=",tostring(foot_body))
        else
            foot_stats=type(stats_or_error)=="table" and stats_or_error or {}
            local unresolved=tonumber(foot_stats.unresolved or 0) or 0
            if unresolved>0 then
                foot_stats.fallback=true
                foot_stats.fallback_reason="unresolved_targets"
                body=original_body
                style=original_style
                logger.warn("[MiuRead][Download] footnote transform fallback",
                    "chapter=",uid,"reason=unresolved_targets",
                    "candidates=",tostring(foot_stats.candidates or foot_stats.refs or 0),
                    "missing=",tostring(unresolved))
            else
                local transformed=tostring(foot_body or "")..tostring(foot_section or "")
                local footnote_valid,footnote_error=Footnotes.validate(transformed)
                if footnote_valid then
                    body=transformed
                    if foot_section and foot_section ~= "" then
                        style=tostring(style or "").."\n"..Footnotes.FOOTNOTES_CSS
                    end
                else
                    foot_stats.fallback=true
                    foot_stats.fallback_reason="validation_error"
                    body=original_body
                    style=original_style
                    logger.warn("[MiuRead][Download] footnote transform fallback",
                        "chapter=",uid,"reason=validation_error",
                        "error=",tostring(footnote_error))
                end
            end
        end
        progress("images", index, expected, chapter.title)
        local fallback_title = "第 " .. tostring(index) .. " 节"
        local title_transform_version = entry and tonumber(entry.title_transform_version)
            or tonumber(cache.manifest.title_transform_version) or TITLE_TRANSFORM_VERSION
        body = prepare_chapter_body(body,
            chapter.title and chapter.title ~= "" and chapter.title or fallback_title,
            title_transform_version)
        return cache_save_final(cache, chapter, body, annotation, style, foot_stats)
    end

    local function process_one(chapter, index, retry_round)
        if opt.cancelled and opt.cancelled() then error("download cancelled") end
        respect_reader_priority("chapter")
        local uid = tostring(chapter.chapterUid or chapter.uid)
        local entry = cache.manifest.chapters[uid]
        local body, style, new_assets

        if entry then
            local current_title = tostring(chapter.title or "")
            local current_words = tonumber(chapter.wordCount or chapter.word_count or 0) or 0
            local cached_words = tonumber(entry.word_count or 0) or 0
            if current_words > 0 and current_words ~= cached_words then
                logger.info("[MiuRead][Download] chapter metadata changed; refreshing checkpoint",
                    "chapter=", uid, "old_words=", tostring(cached_words), "new_words=", tostring(current_words))
                cache_reset_entry(cache, uid)
                entry = nil
            elseif current_title ~= "" and current_title ~= tostring(entry.title or "") then
                -- Update the catalog/TOC title without rewriting completed XHTML.
                -- Replacing a heading inside the chapter can invalidate KOReader
                -- local-note positions even though the正文 itself did not change.
                entry.title = current_title
                entry.error = nil
                cache_save(cache)
            end
        end

        if retry_round and retry_round > 0 then
            progress("resume", index, expected, chapter.title, {
                message="正在重试失败项目（第 " .. tostring(retry_round) .. " 轮）",
            })
        end

        if entry and opt.images~=false
            and tonumber(entry.image_transform_version or cache.manifest.image_transform_version or 1)<IMAGE_TRANSFORM_VERSION then
            logger.info("[MiuRead][Download] refreshing legacy image checkpoint",
                "chapter=",uid,"old_version=",tostring(entry.image_transform_version or cache.manifest.image_transform_version or 1))
            cache_reset_entry(cache,uid)
            entry=nil
        end

        -- Transformer version changes no longer force completed chapters to be
        -- regenerated. The current transformers apply to new or genuinely changed
        -- chapters, while existing XHTML remains stable for KOReader local notes.

        if entry and entry.complete then
            local migrated=false
            if tonumber(entry.title_transform_version or 0)<=0 then
                entry.title_transform_version=tonumber(cache.manifest.title_transform_version)
                    or LEGACY_TITLE_TRANSFORM_VERSION
                migrated=true
            end
            if requested_annotations and tonumber(entry.annotation_transform_version or 0)<=0 then
                entry.annotation_transform_version=LEGACY_ANNOTATION_TRANSFORM_VERSION
                migrated=true
            end
            if requested_annotations and tostring(entry.annotation_account_key or "")=="" then
                -- Older caches did not record the account. Preserve their final
                -- XHTML and bind it to the current account instead of rebuilding
                -- every chapter during the upgrade.
                entry.annotation_account_key=annotation_account_key
                migrated=true
            end
            if migrated then cache_save(cache) end
        end

        -- A completed chapter is stable across download runs. Re-fetching and
        -- re-injecting every annotation on every update changes EPUB text nodes
        -- and invalidates KOReader local-note positions. Only pending, changed,
        -- new, or account-mismatched chapters are rebuilt.
        local annotation_current=not requested_annotations or (
            entry and entry.annotation_pending~=true
            and tostring(entry.annotation_account_key or "")==tostring(annotation_account_key))
        if entry and entry.complete and annotation_current then
            local cached_path, cached_style = cache_load_final_source(cache, entry)
            if cached_path then
                local valid,validation_error=validate_cached_chapter(cached_path)
                if valid then
                    failure_map[uid] = nil
                    restricted_map[uid] = nil
                    return true
                end
                cached_style="完成章节结构无效："..tostring(validation_error)
            end
            logger.warn("[MiuRead][Download] completed checkpoint invalid", "chapter=", uid, "error=", tostring(cached_style))
            cache_reset_entry(cache, uid)
            entry = nil
        end

        if entry and entry.content_done then
            body, style, new_assets = cache_load_base(cache, entry)
            if body then
                progress("resume", index, expected, chapter.title, {message="正文已完成，正在获取附加内容"})
            else
                logger.warn("[MiuRead][Download] content checkpoint invalid", "chapter=", uid, "error=", tostring(style))
                cache_reset_entry(cache, uid)
                entry = nil
            end
        end

        if not body then
            progress("content", index, expected, chapter.title)
            local ok, downloaded, downloaded_style, downloaded_assets, state = pcall(
                self.reader.chapter, self.reader, book, chapter, format, {images=opt.images})
            if not ok then
                if Http.is_rate_limit_error(downloaded) then error(downloaded) end
                if not opt.chapter_uid and type(self.reader.is_access_denied_error)=="function"
                    and self.reader.is_access_denied_error(downloaded) then
                    return mark_restricted(chapter, downloaded)
                end
                return mark_failure(chapter, downloaded)
            end
            if state and (state.psvts or state.pclts or state.token or state.url) then
                session = state
            end
            body = Codec.body(downloaded)
            body, style, new_assets = namespace_assets(body, downloaded_style, downloaded_assets, uid)
            entry = cache_save_base(cache, chapter, body, style, new_assets, state)
        end

        local annotation
        if requested_annotations then
            progress("underlines",index,expected,chapter.title)
            annotation=fetch_annotation(chapter,function(stage,current_index,total)
                progress(stage,index,expected,chapter.title,{batch=current_index,batches=total})
            end)
            local pending=annotation.complete~=true
            entry.annotation_done=not pending
            entry.annotation_pending=pending or nil
            entry.annotation_error_kind=pending and (annotation.error_kind or "incomplete") or nil
            entry.annotation_error=pending and table.concat(annotation.errors or {},"; ") or nil
            entry.annotation_account_key=annotation_account_key
            entry.annotation_run_id=opt.download_run_id
            if pending then
                record_annotation_error(chapter,annotation)
                logger.warn("[MiuRead][Download] annotations preserved with pending items",
                    "book=",tostring(book.bookId),"chapter=",uid,
                    "kind=",tostring(annotation.error_kind or "incomplete"))
            else
                annotation_error_map[uid]=nil
            end
            local extra_css,apply_stats
            body,extra_css,apply_stats=self.annotations:apply(body,annotation)
            entry.annotation_fallback=tonumber(apply_stats and apply_stats.fallback or 0) or 0
            style=tostring(style or "").."\n"..tostring(extra_css or "")
            cache_save(cache)
        end

        entry = finalize_chapter(chapter,index,entry,body,style,annotation)
        local final_path, final_error = cache_load_final_source(cache, entry)
        if not final_path then return mark_failure(chapter, final_error) end
        failure_map[uid] = nil
        restricted_map[uid] = nil
        body, annotation, new_assets = nil, nil, nil
        collectgarbage("collect")
        return true
    end

    for index, chapter in ipairs(selected) do process_one(chapter, index, 0) end

    -- Retry only unresolved items. Successful checkpoints are never fetched
    -- again, and a later success removes the earlier failure state.
    for retry_round = 1, 2 do
        local pending = {}
        for index,chapter in ipairs(selected) do
            local uid=tostring(chapter.chapterUid or chapter.uid)
            local entry=cache.manifest.chapters[uid]
            if failure_map[uid] then
                pending[#pending+1]={chapter=chapter,index=index}
            end
        end
        if #pending == 0 then break end
        pause(retry_round == 1 and 1.5 or 3.0)
        for _, item in ipairs(pending) do process_one(item.chapter, item.index, retry_round) end
    end


    -- Rebuild in catalog order from verified checkpoints. This avoids wrong
    -- ordering when a failed item succeeds in a later retry round.
    chapters, assets = {}, {}
    css_list, css_seen = {}, {}
    css_add(css_list, css_seen, BASE_CSS)
    annotation_summary = {underlines=0, thoughts=0, fallbacks=0, chapters_ok=0, chapters_failed=0, errors={}}
    local image_summary={
        discovered=0,localized=0,optional=0,recovered=0,stale=0,missing=0,chapters=0,
        required_discovered=0,required_localized=0,required_missing=0,
        optional_dropped=0,stale_dropped=0,embedded=0,
    }
    for index, chapter in ipairs(selected) do
        local uid = tostring(chapter.chapterUid or chapter.uid)
        local entry = cache.manifest.chapters[uid]
        local final_path, final_style, final_assets = cache_load_final_source(cache, entry)
        if restricted_map[uid] then
            -- Official preview limits are intentionally omitted. They are
            -- not download failures and must not create empty chapters.
        elseif final_path then
            append_entry(chapters, assets, css_list, css_seen, entry, {path=final_path}, final_style, final_assets, index)
            local chapter_images=type(entry.image_summary)=="table" and entry.image_summary or {}
            image_summary.chapters=image_summary.chapters+1
            for _,key in ipairs({
                "discovered","localized","optional","recovered","stale","missing",
                "required_discovered","required_localized","required_missing",
                "optional_dropped","stale_dropped","embedded",
            }) do
                image_summary[key]=image_summary[key]+(tonumber(chapter_images[key]) or 0)
            end
            if opt.annotations then
                annotation_summary.chapters_ok = annotation_summary.chapters_ok + 1
                annotation_summary.underlines = annotation_summary.underlines + (tonumber(entry.underlines) or 0)
                annotation_summary.thoughts = annotation_summary.thoughts + (tonumber(entry.thoughts) or 0)
                annotation_summary.fallbacks = annotation_summary.fallbacks + (tonumber(entry.annotation_fallback) or 0)
            end
        else
            failure_map[uid] = failure_map[uid] or {uid=uid, title=chapter.title, error=tostring(final_style)}
        end
    end

    failures = {}
    for _, chapter in ipairs(selected) do
        local uid = tostring(chapter.chapterUid or chapter.uid)
        if failure_map[uid] then failures[#failures + 1] = failure_map[uid] end
    end
    local annotation_errors={}
    for _,chapter in ipairs(selected) do
        local uid=tostring(chapter.chapterUid or chapter.uid)
        if annotation_error_map[uid] then annotation_errors[#annotation_errors+1]=annotation_error_map[uid] end
    end
    annotation_summary.chapters_failed=requested_annotations and #annotation_errors or 0
    annotation_summary.pending=#annotation_errors>0
    annotation_summary.error_kind=annotation_error_kind
    annotation_summary.errors=U.copy(annotation_errors)
    opt.annotation_requested=requested_annotations
    opt.annotation_pending=#annotation_errors>0
    opt.annotation_fallback=tonumber(annotation_summary.fallbacks or 0)>0
    opt.annotation_error_kind=annotation_error_kind
    opt.annotation_errors=U.copy(annotation_errors)
    image_summary.assets=#assets
    opt.image_summary=image_summary

    local restricted_count=0
    for _ in pairs(restricted_map) do restricted_count=restricted_count+1 end
    local accessible_expected=expected-restricted_count
    local preview=restricted_count>0
    local readable_count=#chapters
    local guard_uid=chapters[#chapters] and chapters[#chapters].uid or nil
    local preview_mode="complete"

    if not preview then
        if #chapters ~= accessible_expected or #failures > 0 then
            error(failure_message(failures, accessible_expected, #chapters, true))
        end
    elseif readable_count<accessible_expected or #failures>0 then
        preview_mode=readable_count>0 and "partial" or "info"
        local body,title=preview_information_chapter(book,preview_mode,expected,readable_count,restricted_count,failures)
        chapters[#chapters+1]={
            title=title,body=body,uid="miuread-preview-info",index=expected+1,
            word_count=#plain(body),structural=true,
        }
    elseif readable_count<=0 then
        preview_mode="info"
        local body,title=preview_information_chapter(book,preview_mode,expected,0,restricted_count,failures)
        chapters[#chapters+1]={
            title=title,body=body,uid="miuread-preview-info",index=expected+1,
            word_count=#plain(body),structural=true,
        }
    end

    progress("package", #chapters, math.max(1,accessible_expected), book.title, {
        message=preview and (preview_mode=="info" and "正在生成试读信息版"
            or (preview_mode=="partial" and ("正在生成部分试读版 · "..tostring(readable_count).."/"..tostring(expected).." 章")
            or ("正在生成官方试读版 · "..tostring(readable_count).."/"..tostring(expected).." 章"))) or nil,
    })
    opt.expected_chapter_count = accessible_expected
    opt.catalog_chapter_count = expected
    opt.readable_chapter_count = readable_count
    opt.restricted_chapter_count = restricted_count
    opt.failed_chapter_count = #failures
    opt.access_scope = preview and "preview" or "full"
    opt.preview_mode = preview and preview_mode or nil
    opt.guard_chapter_uid = guard_uid
    opt.checkpointed = true
    local record = self:_save(book, chapters, assets, table.concat(css_list, "\n"), self:_cover(book, true), opt, failures, session)
    record.annotation_summary = annotation_summary
    if requested_annotations then
        cache.manifest.annotation_pending=opt.annotation_pending==true or nil
        cache.manifest.annotation_error_kind=opt.annotation_error_kind
        cache.manifest.annotation_errors=U.copy(opt.annotation_errors or {})
        cache_save(cache)
    else
        U.remove_tree(cache.root)
    end
    return record
end

Downloader._prepare_chapter_body = prepare_chapter_body
Downloader._prepare_chapter_body_legacy = prepare_chapter_body_legacy
Downloader._prepare_chapter_body_current = prepare_chapter_body_current
Downloader._namespace_assets = namespace_assets
Downloader._catalog_signature = catalog_signature
Downloader._option_key = option_key
Downloader._validate_epub = function(path,expected)
    if type(expected)=="number" then
        local meta,err=EpubInstaller.inspect(path)
        if not meta then return nil,err end
        if tonumber(meta._chapter_count)~=tonumber(expected) then return nil,"EPUB 章节数量不一致" end
        return true,meta
    end
    return EpubInstaller.validate(path,expected)
end

return Downloader
