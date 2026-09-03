-- Reading-context subset used by the compatibility reporting path.
local WeRead = require("miuread.legacy.weread")
local Content = {}

function Content.extract_reader_state(html)
    return {
        book_id = html:match([["bookId"%s*:%s*"([^"]+)"]]) or html:match([["bookId"%s*:%s*(%d+)]]),
        title = html:match([["title"%s*:%s*"([^"]+)"]]),
        author = html:match([["author"%s*:%s*"([^"]+)"]]),
        psvts = html:match([["psvts"%s*:%s*"([^"]+)"]]),
        pclts = html:match([["pclts"%s*:%s*"([^"]+)"]]),
        token = html:match([["token"%s*:%s*"([^"]+)"]]),
    }
end

function Content.normalize_chapters(payload, book_id)
    local records = payload
    if type(payload) == "table" and payload.data then records = payload.data end
    if type(records) ~= "table" then return {} end
    if records.bookId or records.updated then records = { records } end
    for _, record in ipairs(records) do
        if tostring(record.bookId or "") == tostring(book_id) then
            return record.updated or record.chapterInfos or record.chapters or {}
        end
    end
    return {}
end

local function truthy(value)
    return value == true or value == 1 or value == "1" or value == "true"
end

function Content.chapter_uid(chapter)
    return chapter and (chapter.chapterUid or chapter.uid or chapter.chapter_uid)
end

function Content.is_structural_chapter(chapter)
    if type(chapter) ~= "table" then return true end
    local title = tostring(chapter.title or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if title == "封面" then return true end
    if truthy(chapter.isCover) or truthy(chapter.cover) then return true end
    local kind = tostring(chapter.chapterType or chapter.type or ""):lower()
    if kind == "cover" then return true end
    return Content.chapter_uid(chapter) == nil
end

function Content.is_readable_chapter(chapter)
    if Content.is_structural_chapter(chapter) then return false end
    return (tonumber(chapter.wordCount or chapter.word_count or 0) or 0) > 0
end

function Content.first_readable_chapter(chapters)
    for _, chapter in ipairs(chapters or {}) do
        if Content.is_readable_chapter(chapter) then return chapter end
    end
end


function Content.ensure_reader_state(client, book)
    local book_id = book.book_id or book.bookId
    local reader_url = book.reader_url or WeRead.reader_url(book_id)
    local reader_html = client:get_text(reader_url, { referer = reader_url })
    local state = Content.extract_reader_state(reader_html)
    book.book_id = book.book_id or state.book_id or book.bookId
    book.title = book.title or state.title
    book.author = book.author or state.author
    book.psvts = state.psvts or book.psvts
    book.pclts = state.pclts or book.pclts
    book.token = state.token or book.token
    book.reader_url = reader_url
    if not book.psvts then error("reader.psvts not found") end
    return state
end

function Content.fetch_catalog(client, book)
    local book_id = book.book_id or book.bookId
    local reader_url = book.reader_url or WeRead.reader_url(book_id)
    local catalog = client:post_json("https://weread.qq.com/web/book/chapterInfos", {
        bookIds = { tostring(book_id) },
    }, { referer = reader_url })
    -- Keep the complete catalog. Some WeRead books expose real text chapters
    -- with a missing/zero wordCount; dropping them here makes that book
    -- permanently impossible to repair. Selection is performed later using
    -- trusted local/remote chapter identities.
    local chapters = Content.normalize_chapters(catalog, book_id)
    book.chapters = chapters
    return chapters
end

return Content
