local Protocol=require("miuread.protocol")
local Codec=require("miuread.codec")
local U=require("miuread.util")
local Library={}; Library.__index=Library
function Library:new(api,http,store) return setmetatable({api=api,http=http,store=store},self) end

local function book(row)
    local b=row.bookInfo or row.book or row
    return {
        bookId=tostring(b.bookId or row.bookId or ""),
        title=b.title or row.title or "未命名",
        author=b.author or row.author or "",
        cover=b.cover or b.coverUrl or row.cover,
        category=b.category or row.category,
        updateTime=tonumber(row.updateTime or b.updateTime or row.bookUpdateTime or 0) or 0,
        progress=tonumber(row.progress or row.readingProgress or b.progress or 0) or 0,
        finished=(row.finished==true or tonumber(row.progress or 0)>=100),
        raw=row,
    }
end

function Library:normalize(data)
    local books,mp={},{}
    local src=data.books or data.bookList or data.updated or {}
    for _,r in ipairs(src) do
        local b=book(r)
        if b.bookId~="" then
            if Protocol.is_mp(b.bookId) then mp[#mp+1]=b else books[#books+1]=b end
        end
    end
    local extras={data.mp,data.mpBook,data.officialAccounts}
    for _,x in ipairs(extras) do
        if type(x)=="table" then
            if x[1] then
                for _,r in ipairs(x) do mp[#mp+1]=book(r) end
            else
                local b=book(x); if b.bookId~="" then mp[#mp+1]=b end
            end
        end
    end
    return books,mp
end

function Library:refresh()
    local data=self.api:shelf()
    local books,mp=self:normalize(data)
    self.store:save_shelf_cache({books=books,mp=mp,updated_at=os.time()})
    return books,mp
end
function Library:cached() local c=self.store:shelf_cache(); return c.books or {},c.mp or {},c.updated_at end

local function record_state(row)
    local downloaded=false
    local has_record=false
    local latest_download=0
    local filenames={}
    local function scan(record)
        if type(record)~="table" then return end
        local file=tostring(record.file or "")
        if file~="" then
            has_record=true
            latest_download=math.max(latest_download,tonumber(record.downloaded_at or 0) or 0)
            filenames[#filenames+1]=file:match("([^/]+)$") or file
            if U.file_exists(file) then downloaded=true end
        end
    end
    for _,record in pairs((row and row.variants) or {}) do scan(record) end
    for _,chapter in pairs((row and row.chapters) or {}) do
        for _,record in pairs(chapter or {}) do scan(record) end
    end
    return {
        has_record=has_record,
        downloaded=downloaded,
        file_missing=has_record and not downloaded,
        downloaded_at=latest_download,
        filenames=table.concat(filenames," "),
    }
end

local function local_progress(session,row)
    session=type(session)=="table" and session or {}
    local pending=type(session.pending)=="table" and session.pending or {}
    return tonumber(pending.percent or session.progress_local_percent or session.verified_local_percent or row.progress or 0) or 0
end

function Library:is_downloaded(id, library_snapshot)
    local source = library_snapshot or self.store:library()
    local b = source and source[tostring(id)]
    return b and record_state(b).downloaded or false
end

function Library:local_books(library_snapshot, sessions_snapshot)
    local source = library_snapshot or self.store:library()
    local sessions = sessions_snapshot or self.store:get("sessions",{})
    local books, mp = {}, {}
    for id, row in pairs(source or {}) do
        local state=record_state(row)
        if state.downloaded then
        local session=sessions[tostring(id)] or {}
        local b = {
            bookId=tostring(row.book_id or id or ""),
            title=row.title or "未命名",
            author=row.author or "",
            cover=row.cover,
            category=row.category,
            updateTime=tonumber(row.updated_at or row.downloaded_at or 0) or 0,
            progress=local_progress(session,row),
            local_only=true,
            downloaded=state.downloaded,
            file_missing=false,
            downloadedAt=state.downloaded_at,
            lastReadTime=tonumber(session.last_read_at or 0) or 0,
            filename_search=state.filenames,
            local_record=row,
        }
        if b.bookId ~= "" then
            if Protocol.is_mp(b.bookId) then mp[#mp+1]=b else books[#books+1]=b end
        end
        end
    end
    return books, mp
end

function Library:merge_books(remote_rows, local_rows)
    local out,index={},{}
    for _,remote in ipairs(remote_rows or {}) do
        local b=U.copy(remote)
        b.bookId=tostring(b.bookId or b.book_id or "")
        if b.bookId~="" and not index[b.bookId] then
            b.local_only=false
            out[#out+1]=b
            index[b.bookId]=b
        end
    end
    for _,local_book in ipairs(local_rows or {}) do
        local id=tostring(local_book.bookId or local_book.book_id or "")
        local existing=index[id]
        if existing then
            existing.title=existing.title or local_book.title
            existing.author=existing.author or local_book.author
            existing.cover=existing.cover or local_book.cover
            existing.downloaded=local_book.downloaded==true
            existing.file_missing=local_book.file_missing==true
            existing.downloadedAt=tonumber(local_book.downloadedAt or 0) or 0
            existing.lastReadTime=tonumber(local_book.lastReadTime or 0) or 0
            existing.filename_search=local_book.filename_search
            existing.local_record=local_book.local_record
            if (tonumber(existing.progress or 0) or 0)<=0 then existing.progress=local_book.progress end
        elseif id~="" then
            local copy=U.copy(local_book)
            out[#out+1]=copy
            index[id]=copy
        end
    end
    return out
end

function Library:combined(remote_books,remote_mp,library_snapshot,sessions_snapshot)
    local local_books,local_mp=self:local_books(library_snapshot,sessions_snapshot)
    return self:merge_books(remote_books,local_books),self:merge_books(remote_mp,local_mp)
end

function Library:sort_filter(rows)
    local p=self.store:preferences()
    local scope=tostring(p.shelf_scope or "all")
    local old_filters=p.shelf_filters or {}
    local out={}
    for _,b in ipairs(rows or {}) do
        local pass=true
        local prog=tonumber(b.progress or 0) or 0
        if scope=="downloaded" and not b.downloaded then pass=false end
        if scope=="unread" and prog>0 then pass=false end
        if scope=="reading" and (prog<=0 or prog>=100) then pass=false end
        if scope=="finished" and prog<100 then pass=false end
        -- Preserve older installations' explicit filters until users select a
        -- new single shelf scope in the v1.1 controls.
        if old_filters.downloaded and not b.downloaded then pass=false end
        if old_filters.unread and prog>0 then pass=false end
        if old_filters.reading and (prog<=0 or prog>=100) then pass=false end
        if old_filters.finished and prog<100 then pass=false end
        if pass then out[#out+1]=b end
    end
    local key=tostring(p.shelf_sort or "read")
    table.sort(out,function(a,b)
        if key=="title" then return tostring(a.title)<tostring(b.title) end
        if key=="author" then return tostring(a.author)<tostring(b.author) end
        if key=="progress" then return (tonumber(a.progress) or 0)>(tonumber(b.progress) or 0) end
        if key=="download" then return (tonumber(a.downloadedAt) or 0)>(tonumber(b.downloadedAt) or 0) end
        if key=="read" then
            local ar,br=tonumber(a.lastReadTime or 0) or 0,tonumber(b.lastReadTime or 0) or 0
            if ar~=br then return ar>br end
        end
        local au,bu=tonumber(a.updateTime or 0) or 0,tonumber(b.updateTime or 0) or 0
        if au~=bu then return au>bu end
        return tostring(a.title)<tostring(b.title)
    end)
    return out
end

local function searchable(value)
    return U.trim(tostring(value or "")):lower():gsub("%s+"," ")
end

function Library:search(rows,query)
    local q=searchable(query)
    if q=="" then return U.copy(rows or {}) end
    local terms={}
    for term in q:gmatch("%S+") do terms[#terms+1]=term end
    local out={}
    for _,b in ipairs(rows or {}) do
        local hay=searchable(table.concat({b.title or "",b.author or "",b.filename_search or ""}," "))
        local pass=true
        for _,term in ipairs(terms) do
            if not hay:find(term,1,true) then pass=false; break end
        end
        if pass then out[#out+1]=b end
    end
    return out
end

function Library:cached_cover_path(id, cover_index)
    local index = cover_index or self.store:get("cover_index", {})
    local path = index[tostring(id)]
    if path and U.file_exists(path) then return path end
end

function Library:cache_cover(b)
    if not b or not b.cover or b.cover=="" then return nil end
    local index=self.store:get("cover_index",{})
    local cached=index[tostring(b.bookId)]
    if cached and U.file_exists(cached) then return cached end
    local data=self.http:download(b.cover,{auth=false}); if not data or #data==0 then return nil end
    local ext=select(1,Codec.media(data)) or ".img"
    local path=self.store.covers_dir.."/"..U.id_name(b.bookId)..ext
    U.atomic_write(path,data,true); index[tostring(b.bookId)]=path; self.store:set("cover_index",index); return path
end
function Library:clear_covers() U.remove_tree(self.store.covers_dir); U.mkdir(self.store.covers_dir); self.store:set("cover_index",{}) end
function Library:reader_link(url)
    local id=tostring(url or ""):match("/web/reader/([^/?#]+)") or tostring(url or ""):match("bookId=([^&#]+)")
    if not id then return nil end
    if id:match("^%d+$") or id:match("^MP_WXS_") then return id end
    return nil
end
return Library
