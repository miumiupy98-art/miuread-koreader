local Protocol = require("miuread.protocol")
local Codec = require("miuread.codec")
local Footnotes = require("miuread.footnotes")
local Thoughts = require("miuread.thoughts")
local Epub = require("miuread.epub")
local Json = require("miuread.json")
local U = require("miuread.util")
local logger = require("logger")

local Downloader = {}
Downloader.__index = Downloader

local CACHE_SCHEMA = 3

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

local function normalized_title(value)
    return plain(value):lower():gsub("[%s%p%c]", "")
end

local function prepare_chapter_body(html, title)
    local fragment = Codec.body(html)
    title = tostring(title or "")
    if title == "" then return '<section class="miu-chapter" epub:type="chapter">' .. fragment .. "</section>" end
    local wanted = normalized_title(title)
    local prefix = fragment:sub(1, 1600)
    local has_title = false
    for tag, attrs, inner in prefix:gmatch("<(h[1-6])([^>]*)>(.-)</%1%s*>") do
        if normalized_title(inner) == wanted then has_title = true; break end
    end
    if not has_title then
        local _, first_inner = prefix:match("^%s*<([pd][^>]*)>(.-)</[pd][^>]*>")
        if first_inner and normalized_title(first_inner) == wanted then has_title = true end
    end
    if not has_title then
        fragment = '<h1 class="miu-chapter-title">' .. U.xml(title) .. "</h1>\n" .. fragment
    end
    return '<section class="miu-chapter" epub:type="chapter" data-miuread-section="1">' .. fragment .. "</section>"
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

local function failure_message(failures, expected, actual)
    local lines = {
        "下载不完整，未生成新的 EPUB",
        "应下载章节：" .. tostring(expected),
        "成功章节：" .. tostring(actual),
        "已完成内容已保存；再次下载时只补未完成章节。",
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

local function namespace_assets(body, assets, uid)
    local out = {}
    local prefix = "ch-" .. U.id_name(uid)
    for index, asset in ipairs(assets or {}) do
        local item = U.copy(asset)
        local old = tostring(item.href or "")
        local base = old:match("([^/]+)$") or ("asset-" .. tostring(index) .. ".bin")
        local new = "images/" .. prefix .. "-" .. tostring(index) .. "-" .. U.id_name(base)
        if old ~= "" and old ~= new then
            body = body:gsub(pattern_escape("../" .. old), "../" .. new)
            body = body:gsub(pattern_escape(old), new)
        end
        item.href = new
        out[#out + 1] = item
    end
    return body, out
end

local function option_key(opt)
    return table.concat({
        opt.annotations and "notes" or "clean",
        opt.images == false and "no-images" or "images",
        opt.chapter_uid and ("chapter-" .. U.id_name(opt.chapter_uid)) or "book",
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

local function read_json(path)
    local raw = U.read_file(path, true)
    if not raw then return nil end
    local ok, data = pcall(Json.decode, raw)
    return ok and type(data) == "table" and data or nil
end

local function write_json(path, value)
    local ok, encoded = pcall(Json.encode, value)
    if not ok then return nil, encoded end
    return U.atomic_write(path, encoded, true)
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
        assets = dir .. "/assets.json",
        asset_dir = dir .. "/assets",
    }
end

local function cache_save(cache)
    cache.manifest.updated_at = os.time()
    local ok, err = write_json(cache.path, cache.manifest)
    if not ok then error("无法保存下载断点：" .. tostring(err)) end
end

local function cache_new(store, book, opt, selected, format)
    local root = store:book_dir(book.bookId) .. "/.miuread-partial-" .. option_key(opt)
    local path = root .. "/manifest.json"
    local signature = catalog_signature(selected)
    local manifest = read_json(path)
    local valid = manifest
        and tonumber(manifest.schema) == CACHE_SCHEMA
        and tostring(manifest.book_id or "") == tostring(book.bookId)
        and tostring(manifest.signature or "") == signature
        and tostring(manifest.option_key or "") == option_key(opt)
        and tostring(manifest.format or "") == tostring(format)
    if not valid then
        U.remove_tree(root)
        U.mkdir(root .. "/chapters")
        manifest = {
            schema = CACHE_SCHEMA,
            book_id = tostring(book.bookId),
            option_key = option_key(opt),
            signature = signature,
            format = format,
            created_at = os.time(),
            updated_at = os.time(),
            chapters = {},
        }
        write_json(path, manifest)
    else
        U.mkdir(root .. "/chapters")
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
    local ok, err = write_json(paths.assets, meta)
    if not ok then error("无法保存图片清单：" .. tostring(err)) end
end

local function cache_load_assets(cache, entry)
    local path = absolute(cache.root, entry.assets_file)
    local meta = read_json(path)
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
    entry.assets_file = relative(cache.root, paths.assets)
    entry.content_format = state and state.content_format
    entry.structural = state and state.structural == true or false
    entry.error = nil
    cache.manifest.chapters[uid] = entry
    if state then
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

local function cache_save_final(cache, chapter, body, annotation, style)
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
    cache_save(cache)
    return entry
end

local function cache_load_final(cache, entry)
    if not entry or not entry.complete then return nil, "完成断点不存在" end
    local body = U.read_file(absolute(cache.root, entry.final_file), true)
    local style = U.read_file(absolute(cache.root, entry.css_file), true)
    local assets, asset_error = cache_load_assets(cache, entry)
    if body == nil or style == nil or not assets then return nil, asset_error or "完成断点文件缺失" end
    return body, style, assets
end

local function validate_epub(path, expected)
    local raw = U.read_file(path, true)
    if not raw or #raw < 512 then return nil, "EPUB 文件为空或过小" end
    if raw:sub(1, 4) ~= "PK\003\004" then return nil, "EPUB ZIP 头无效" end
    if not raw:find("PK\005\006", math.max(1, #raw - 65558), true) then return nil, "EPUB ZIP 目录结束标记缺失" end
    for index = 1, expected do
        local name = string.format("OEBPS/text/chapter-%04d.xhtml", index)
        if not raw:find(name, 1, true) then return nil, "EPUB 缺少章节文件：" .. tostring(index) end
    end
    return true
end

function Downloader:new(reader, api, annotations, store, http)
    return setmetatable({reader=reader, api=api, annotations=annotations, store=store, http=http}, self)
end

function Downloader:catalog(id)
    local catalog = self.reader:catalog(id)
    local source = catalog.updated or catalog.chapterInfos or catalog.chapters or {}
    local out = {}
    for _, chapter in ipairs(source) do
        local title = tostring(chapter.title or "")
        local words = tonumber(chapter.wordCount or chapter.word_count or 0) or 0
        local structural = self.reader._is_structure_chapter and self.reader._is_structure_chapter(chapter)
        if title ~= "封面" and (words > 0 or structural) then out[#out + 1] = chapter end
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

function Downloader:_save(book, chapters, assets, css, cover, opt, failures, session)
    local kind = opt.annotations and "notes" or "clean"
    local suffix = kind == "notes" and "划线与想法版" or "纯净版"
    local dir = self.store:epub_root()
    local standalone = opt.chapter_uid ~= nil
    local chapter_name = standalone and (" - " .. U.safe_name(chapters[1] and chapters[1].title or "章节")) or ""
    local filename = U.safe_name(book.title, "book") .. chapter_name .. " [" .. suffix .. "].epub"
    local path = self.store:epub_path(filename)
    local map = {}
    for index, chapter in ipairs(chapters) do
        map[#map + 1] = {uid=chapter.uid, index=chapter.index or index, title=chapter.title, word_count=chapter.word_count or 0, structural=chapter.structural == true}
    end
    local temp_path = path .. ".miuread-new-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
    local built, build_error = pcall(Epub.build, temp_path, book, chapters, css, assets, cover, {
        schema=3, book_id=book.bookId, variant=kind, standalone=standalone,
        chapters=map, generated_at=os.time(), complete=true,
    })
    if not built then os.remove(temp_path); error(build_error) end
    local valid, validation_error = validate_epub(temp_path, #chapters)
    if not valid then os.remove(temp_path); error("EPUB 完整性验证失败：" .. tostring(validation_error)) end

    local backup_path = path .. ".miuread-backup"
    os.remove(backup_path)
    local had_previous = U.file_exists(path)
    if had_previous then
        local backed_up, backup_error = os.rename(path, backup_path)
        if not backed_up then os.remove(temp_path); error("无法保护原 EPUB：" .. tostring(backup_error)) end
    end
    local installed, install_error = os.rename(temp_path, path)
    if not installed then
        if had_previous then os.rename(backup_path, path) end
        os.remove(temp_path)
        error("无法安装新 EPUB：" .. tostring(install_error))
    end
    if had_previous then os.remove(backup_path) end

    local record = {
        book_id=book.bookId, title=book.title, author=book.author, cover=book.cover,
        file=path, directory=dir, variant=kind, downloaded_at=os.time(),
        chapter_count=#chapters, chapter_map=map, failures=failures or {},
    }
    if standalone then
        record.chapter_uid = tostring(opt.chapter_uid)
        self.store:save_chapter_variant(book.bookId, opt.chapter_uid, kind, record)
    else
        self.store:save_variant(book.bookId, kind, record)
    end
    self.store:save_book(book.bookId, {
        book_id=book.bookId, title=book.title, author=book.author, cover=book.cover,
        directory=dir, updated_at=os.time(), catalog=map,
    })
    if session then
        self.store:save_session(book.bookId, {
            psvts=session.psvts, pclts=session.pclts, token=session.token,
            reader_url=session.url, chapters=map, context_updated_at=os.time(),
            app_id=Protocol.app_id(Protocol.USER_AGENT),
        })
    end
    return record
end

local function append_entry(chapters, assets, css_list, css_seen, entry, body, style, chapter_assets, index)
    css_add(css_list, css_seen, style)
    for _, asset in ipairs(chapter_assets or {}) do assets[#assets + 1] = asset end
    chapters[#chapters + 1] = {
        title=entry.title or ("第 " .. tostring(index) .. " 章"), body=body,
        uid=entry.uid, index=entry.index or index,
        word_count=tonumber(entry.word_count or 0) or 0,
        structural=entry.structural == true,
    }
end

function Downloader:book(input, opt, progress)
    opt = opt or {}
    progress = progress or function() end
    local book = normalized_book(input)
    if book.bookId == "" then error("bookId missing") end

    local chapters, assets, failures = {}, {}, {}
    local annotation_summary = {underlines=0, thoughts=0, chapters_ok=0, chapters_failed=0, errors={}}
    local css_list, css_seen = {}, {}
    css_add(css_list, css_seen, BASE_CSS)
    local session, expected = nil, 0

    if Protocol.is_mp(book.bookId) then
        local list = self.reader:mp_articles(book.bookId)
        expected = math.min(#list, tonumber(opt.limit) or #list)
        for index, article in ipairs(list) do
            if index > expected then break end
            if opt.cancelled and opt.cancelled() then error("download cancelled") end
            progress("content", index, expected, article.title)
            local ok, body = pcall(self.reader.mp_content, self.reader, article.reviewId)
            if ok then
                body = localize(self.http, body, assets, opt.images)
                local foot_body, foot_section = Footnotes.process(body, {is_txt=false})
                body = prepare_chapter_body(foot_body .. (foot_section or ""), article.title)
                if foot_section and foot_section ~= "" then css_add(css_list, css_seen, Footnotes.FOOTNOTES_CSS) end
                chapters[#chapters + 1] = {title=article.title, body=body, uid=article.reviewId, index=index, word_count=#plain(body)}
            else
                failures[#failures + 1] = {uid=article.reviewId, title=article.title, error=tostring(body)}
            end
        end
    else
        progress("catalog", 0, 1, book.title)
        local catalog, all = self:catalog(book.bookId)
        local selected = {}
        if opt.chapter_uid then
            for _, chapter in ipairs(all) do
                if tostring(chapter.chapterUid or chapter.uid) == tostring(opt.chapter_uid) then selected[1] = chapter; break end
            end
        else
            for index, chapter in ipairs(all) do
                if not opt.limit or index <= tonumber(opt.limit) then selected[#selected + 1] = chapter end
            end
        end
        if #selected == 0 then error("no readable chapter") end
        expected = #selected
        local format = catalog.format == "txt" and "txt" or "epub"
        local cache = cache_new(self.store, book, opt, selected, format)
        session = cache.manifest.session

        for index, chapter in ipairs(selected) do
            if opt.cancelled and opt.cancelled() then error("download cancelled") end
            local uid = tostring(chapter.chapterUid or chapter.uid)
            local entry = cache.manifest.chapters[uid]
            local body, style, new_assets

            repeat
            if entry and entry.complete then
                local cached, cached_style, cached_assets = cache_load_final(cache, entry)
                if cached then
                    progress("resume", index, expected, chapter.title, {message="已读取本地断点"})
                    append_entry(chapters, assets, css_list, css_seen, entry, cached, cached_style, cached_assets, index)
                    annotation_summary.underlines = annotation_summary.underlines + (tonumber(entry.underlines) or 0)
                    annotation_summary.thoughts = annotation_summary.thoughts + (tonumber(entry.thoughts) or 0)
                    if opt.annotations then annotation_summary.chapters_ok = annotation_summary.chapters_ok + 1 end
                    break
                end
                logger.warn("[MiuRead][Download] completed checkpoint invalid", "chapter=", uid, "error=", tostring(cached_style))
                cache_reset_entry(cache, uid)
                entry = nil
            end

            if entry and entry.content_done then
                body, style, new_assets = cache_load_base(cache, entry)
                if body then
                    progress("resume", index, expected, chapter.title, {message="正文已完成，继续补全附加内容"})
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
                    failures[#failures + 1] = {uid=uid, title=chapter.title, error=tostring(downloaded)}
                    local failed_entry = cache.manifest.chapters[uid] or {uid=uid, title=chapter.title}
                    failed_entry.error = tostring(downloaded)
                    cache.manifest.chapters[uid] = failed_entry
                    cache_save(cache)
                    break
                end
                session = state or session
                body = Codec.body(downloaded)
                body, new_assets = namespace_assets(body, downloaded_assets, uid)
                style = downloaded_style
                -- Save the untouched chapter body. Annotation ranges refer to
                -- this original text, not to the visible markers and endnotes
                -- later inserted by Footnotes.process().
                entry = cache_save_base(cache, chapter, body, style, new_assets, state)
            end

            local annotation
            if opt.annotations then
                progress("underlines", index, expected, chapter.title)
                annotation = self.annotations:fetch_chapter(book.bookId, chapter.chapterUid, function(stage, current, total)
                    progress(stage, index, expected, chapter.title, {
                        batch=current, batches=total,
                        underlines=annotation_summary.underlines,
                        thoughts=annotation_summary.thoughts,
                    })
                end)
                if not annotation.underline_request_ok or #(annotation.errors or {}) > 0 then
                    annotation_summary.chapters_failed = annotation_summary.chapters_failed + 1
                    for _, error_value in ipairs(annotation.errors or {}) do
                        annotation_summary.errors[#annotation_summary.errors + 1] = {uid=uid, title=chapter.title, error=error_value}
                    end
                    failures[#failures + 1] = {uid=uid, title=chapter.title, error="批注数据未完整获取"}
                    entry.error = "批注数据未完整获取"
                    cache_save(cache)
                    break
                end
                annotation_summary.chapters_ok = annotation_summary.chapters_ok + 1
                annotation_summary.underlines = annotation_summary.underlines + (annotation.underline_count or 0)
                annotation_summary.thoughts = annotation_summary.thoughts + (annotation.thought_count or 0)
                Thoughts.save(self.store, book.bookId, chapter.chapterUid, annotation.review_groups)
                local extra_css
                body, extra_css = self.annotations:apply(body, annotation)
                style = tostring(style or "") .. "\n" .. tostring(extra_css or "")
            end

            -- Footnote conversion must happen after range injection. In the
            -- old order, added [1] markers and endnote text shifted every
            -- later underline/comment in books containing footnotes.
            progress("footnotes", index, expected, chapter.title, {
                underlines=annotation_summary.underlines,
                thoughts=annotation_summary.thoughts,
            })
            local content_format = entry and entry.content_format or format
            local foot_body, foot_section = Footnotes.process(body, {is_txt=content_format == "txt" or format == "txt"})
            body = foot_body .. (foot_section or "")
            if foot_section and foot_section ~= "" then
                style = tostring(style or "") .. "\n" .. Footnotes.FOOTNOTES_CSS
            end
            progress("images", index, expected, chapter.title, {
                underlines=annotation_summary.underlines,
                thoughts=annotation_summary.thoughts,
            })

            body = prepare_chapter_body(body, chapter.title or ("第 " .. tostring(index) .. " 章"))
            entry = cache_save_final(cache, chapter, body, annotation, style)
            append_entry(chapters, assets, css_list, css_seen, entry, body, style, new_assets or {}, index)

            until true
        end

        if #chapters ~= expected or #failures > 0 then error(failure_message(failures, expected, #chapters)) end
        progress("package", #chapters, #chapters, book.title)
        local record = self:_save(book, chapters, assets, table.concat(css_list, "\n"), self:_cover(book, true), opt, failures, session)
        record.annotation_summary = annotation_summary
        if opt.annotations then
            if opt.chapter_uid then self.store:save_chapter_variant(book.bookId, opt.chapter_uid, "notes", record)
            else self.store:save_variant(book.bookId, "notes", record) end
        end
        U.remove_tree(cache.root)
        return record
    end

    if #chapters ~= expected or #failures > 0 then error(failure_message(failures, expected, #chapters)) end
    progress("package", #chapters, #chapters, book.title)
    local record = self:_save(book, chapters, assets, table.concat(css_list, "\n"), self:_cover(book, true), opt, failures, session)
    record.annotation_summary = annotation_summary
    return record
end

Downloader._prepare_chapter_body = prepare_chapter_body
Downloader._namespace_assets = namespace_assets
Downloader._catalog_signature = catalog_signature
Downloader._option_key = option_key
Downloader._validate_epub = validate_epub

return Downloader
