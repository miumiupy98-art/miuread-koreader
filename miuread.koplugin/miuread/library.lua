local Protocol=require("miuread.protocol")
local Codec=require("miuread.codec")
local U=require("miuread.util")
local Library={}; Library.__index=Library
function Library:new(api,http,store) return setmetatable({api=api,http=http,store=store},self) end
local function book(row)
    local b=row.bookInfo or row.book or row
    return {bookId=tostring(b.bookId or row.bookId or ""),title=b.title or row.title or "未命名",author=b.author or row.author or "",cover=b.cover or b.coverUrl or row.cover,category=b.category or row.category,updateTime=tonumber(row.updateTime or b.updateTime or row.bookUpdateTime or 0) or 0,progress=tonumber(row.progress or row.readingProgress or b.progress or 0) or 0,finished=(row.finished==true or tonumber(row.progress or 0)>=100),raw=row}
end
function Library:normalize(data)
    local books,mp={},{}
    local src=data.books or data.bookList or data.updated or {}
    for _,r in ipairs(src) do local b=book(r); if b.bookId~="" then if Protocol.is_mp(b.bookId) then mp[#mp+1]=b else books[#books+1]=b end end end
    local extras={data.mp,data.mpBook,data.officialAccounts}; for _,x in ipairs(extras) do if type(x)=="table" then if x[1] then for _,r in ipairs(x) do mp[#mp+1]=book(r) end else local b=book(x); if b.bookId~="" then mp[#mp+1]=b end end end end
    return books,mp
end
function Library:refresh()
    local data=self.api:shelf(); local books,mp=self:normalize(data); self.store:save_shelf_cache({books=books,mp=mp,updated_at=os.time()}); return books,mp
end
function Library:cached() local c=self.store:shelf_cache(); return c.books or {},c.mp or {},c.updated_at end
function Library:is_downloaded(id, library_snapshot)
    local source = library_snapshot or self.store:library()
    local b = source and source[tostring(id)]
    if not b then return false end
    for _,r in pairs(b.variants or {}) do if r.file and U.file_exists(r.file) then return true end end
    for _,row in pairs(b.chapters or {}) do for _,r in pairs(row) do if r.file and U.file_exists(r.file) then return true end end end
    return false
end

function Library:local_books(library_snapshot)
    local source = library_snapshot or self.store:library()
    local books, mp = {}, {}
    for id, row in pairs(source or {}) do
        local b = {
            bookId=tostring(row.book_id or id or ""),
            title=row.title or "未命名",
            author=row.author or "",
            cover=row.cover,
            category=row.category,
            updateTime=tonumber(row.updated_at or row.downloaded_at or 0) or 0,
            progress=tonumber(row.progress or 0) or 0,
            local_only=true,
        }
        if b.bookId ~= "" then
            if Protocol.is_mp(b.bookId) then mp[#mp+1]=b else books[#books+1]=b end
        end
    end
    return books, mp
end
function Library:sort_filter(rows, library_snapshot)
    local p=self.store:preferences(); local filters=p.shelf_filters or {}; local out={}
    for _,b in ipairs(rows or {}) do
        local pass=true; local prog=tonumber(b.progress or 0) or 0
        if filters.downloaded and not self:is_downloaded(b.bookId, library_snapshot) then pass=false end
        if filters.unread and prog>0 then pass=false end
        if filters.reading and (prog<=0 or prog>=100) then pass=false end
        if filters.finished and prog<100 then pass=false end
        if pass then out[#out+1]=b end
    end
    local key=p.shelf_sort or "update"
    table.sort(out,function(a,b)
        if key=="title" then return tostring(a.title)<tostring(b.title) elseif key=="author" then return tostring(a.author)<tostring(b.author) elseif key=="progress" then return (a.progress or 0)>(b.progress or 0) end
        return (a.updateTime or 0)>(b.updateTime or 0)
    end); return out
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
    -- Obfuscated reader IDs cannot be reversed. Plain bookId links remain supported.
    if id:match("^%d+$") or id:match("^MP_WXS_") then return id end
    return nil
end
return Library
