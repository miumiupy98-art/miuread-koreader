local Protocol=require("miuread.protocol")
local Codec=require("miuread.codec")
local U=require("miuread.util")
local DownloadResult=require("miuread.download_result")
local logger=require("logger")
local Library={}; Library.__index=Library
function Library:new(api,http,store)
    return setmetatable({api=api,http=http,store=store,_sort_cache={}},self)
end

local COVER_MAX_BYTES=12*1024*1024
local COVER_EXTENSIONS={
    [".png"]=true,[".jpg"]=true,[".gif"]=true,[".webp"]=true,
    [".svg"]=true,
}

local function cover_download_url(url)
    url=tostring(url or "")
    if url=="" then return url end
    -- WeRead CDN cover URLs encode image size in the /tN_ token. t9 keeps a
    -- noticeably cleaner source for e-ink downscaling without downloading
    -- full-resolution artwork. Non-WeRead URLs are left untouched.
    return url:gsub("/t%d+_", "/t9_")
end

local function truthy(value)
    if value==true then return true end
    if tonumber(value)==1 then return true end
    local text=tostring(value or ""):lower()
    return text=="true" or text=="yes"
end

local function first_number(...)
    for i=1,select("#",...) do
        local value=tonumber(select(i,...))
        if value~=nil then return value end
    end
    return nil
end

local function archive_entries(data)
    local source=data.archive or data.archives or data.bookArchives or data.archiveList or {}
    if type(source)~="table" then return {} end
    if source[1] then return source end
    if source.bookIds or source.bookIdList or source.books or source.items then return {source} end
    local out={}
    for _,row in pairs(source) do
        if type(row)=="table" then out[#out+1]=row end
    end
    table.sort(out,function(a,b)
        local ao=first_number(a.order,a.sort,a.index,a.archiveIndex) or 1000000000
        local bo=first_number(b.order,b.sort,b.index,b.archiveIndex) or 1000000000
        if ao~=bo then return ao<bo end
        return tostring(a.name or a.title or "")<tostring(b.name or b.title or "")
    end)
    return out
end

local function build_archive_map(data)
    local map={}
    for archive_index,archive in ipairs(archive_entries(data or {})) do
        local ids=archive.bookIds or archive.bookIdList or archive.books or archive.items or {}
        if type(ids)=="string" then
            local parsed={}
            for id in ids:gmatch("[^,%s]+") do parsed[#parsed+1]=id end
            ids=parsed
        end
        if type(ids)=="table" then
            local archive_name=tostring(archive.name or archive.title or archive.archiveName or "分组")
            for item_index,item in ipairs(ids) do
                local id
                if type(item)=="table" then
                    id=item.bookId or item.book_id or item.id
                else
                    id=item
                end
                id=tostring(id or "")
                if id~="" then
                    local current=map[id]
                    if not current then
                        current={
                            archiveIndex=archive_index,
                            archiveItemOrder=item_index,
                            archiveName=archive_name,
                            archiveNames={},
                        }
                        map[id]=current
                    end
                    current.archiveNames[#current.archiveNames+1]=archive_name
                end
            end
        end
    end
    for _,row in pairs(map) do row.archiveNamesText=table.concat(row.archiveNames,"、") end
    return map
end

local function book(row,raw_index,archive_map)
    row=type(row)=="table" and row or {}
    local b=type(row.bookInfo)=="table" and row.bookInfo or (type(row.book)=="table" and row.book or row)
    local id=tostring(b.bookId or row.bookId or b.book_id or row.book_id or "")
    local archive=archive_map and archive_map[id] or nil
    local top_value=row.isTop
    if top_value==nil then top_value=b.isTop end
    local explicit_order=first_number(
        row.shelfOrder,row.shelfIndex,row.bookOrder,row.sortOrder,row.displayOrder,
        b.shelfOrder,b.shelfIndex,b.bookOrder,b.sortOrder,b.displayOrder
    )
    return {
        bookId=id,
        title=b.title or row.title or "未命名",
        author=b.author or row.author or "",
        cover=b.cover or b.coverUrl or row.cover,
        category=b.category or row.category,
        description=b.intro or b.description or b.summary or row.intro or row.description or row.summary,
        publisher=b.publisher or row.publisher,
        version=tonumber(b.version or b.bookVersion or b.book_version
            or row.version or row.bookVersion or row.book_version),
        updateTime=tonumber(row.updateTime or b.updateTime or row.bookUpdateTime or 0) or 0,
        progress=tonumber(row.progress or row.readingProgress or b.progress or 0) or 0,
        finished=(row.finished==true or tonumber(row.progress or row.readingProgress or 0)>=100),
        isTop=truthy(top_value),
        rawIndex=tonumber(raw_index) or 0,
        explicitOrder=explicit_order,
        cloudOrder=tonumber(row.cloudOrder or row.cloud_order),
        -- Keep the cloud reading timestamp independent from the book-content
        -- update timestamp. The old, proven shelf order uses readUpdateTime;
        -- updateTime must never be used as its fallback.
        readUpdateTime=tonumber(row.readUpdateTime or b.readUpdateTime or 0) or 0,
        cloudUpdatedAt=tonumber(row.readUpdateTime or b.readUpdateTime or 0) or 0,
        archiveIndex=archive and archive.archiveIndex or nil,
        archiveItemOrder=archive and archive.archiveItemOrder or nil,
        archiveName=archive and archive.archiveName or nil,
        archiveNames=archive and archive.archiveNamesText or nil,
        inArchive=archive~=nil,
    }
end

local function official_shelf_less(a,b)
    if a.isTop~=b.isTop then return a.isTop==true end
    local ar,br=tonumber(a.readUpdateTime or 0) or 0,tonumber(b.readUpdateTime or 0) or 0
    if ar>0 and br>0 and ar~=br then return ar>br end
    local ao,bo=tonumber(a.explicitOrder),tonumber(b.explicitOrder)
    if ao~=nil and bo~=nil and ao~=bo then return ao<bo end
    local ai,bi=tonumber(a.rawIndex) or 1000000000,tonumber(b.rawIndex) or 1000000000
    if ai~=bi then return ai<bi end
    return tostring(a.bookId or "")<tostring(b.bookId or "")
end

local function shelf_order_plan(rows)
    local count=#(rows or {})
    local read_fields,explicit_fields,top_count=0,0,0
    for _,row in ipairs(rows or {}) do
        if (tonumber(row.readUpdateTime or 0) or 0)>0 then read_fields=read_fields+1 end
        if tonumber(row.explicitOrder)~=nil then explicit_fields=explicit_fields+1 end
        if row.isTop==true then top_count=top_count+1 end
    end
    local threshold=math.max(2,math.ceil(count*0.60))
    local mode="api"
    if count>=2 and read_fields>=threshold then mode="read_time"
    elseif count>=2 and explicit_fields>=threshold then mode="explicit" end
    return {mode=mode,count=count,read_fields=read_fields,explicit_fields=explicit_fields,top_count=top_count}
end

local function planned_shelf_less(mode,a,b)
    if a.isTop~=b.isTop then return a.isTop==true end
    if mode=="read_time" then
        local ar,br=tonumber(a.readUpdateTime or 0) or 0,tonumber(b.readUpdateTime or 0) or 0
        if (ar>0)~=(br>0) then return ar>0 end
        if ar~=br then return ar>br end
    elseif mode=="explicit" then
        local ao,bo=tonumber(a.explicitOrder),tonumber(b.explicitOrder)
        if (ao~=nil)~=(bo~=nil) then return ao~=nil end
        if ao~=nil and bo~=nil and ao~=bo then return ao<bo end
    end
    local ai,bi=tonumber(a.rawIndex) or 1000000000,tonumber(b.rawIndex) or 1000000000
    if ai~=bi then return ai<bi end
    return tostring(a.bookId or "")<tostring(b.bookId or "")
end

local function order_cloud_rows(rows)
    rows=rows or {}
    local plan=shelf_order_plan(rows)
    table.sort(rows,function(a,b) return planned_shelf_less(plan.mode,a,b) end)
    for index,row in ipairs(rows) do
        row.cloudOrder=index
        row.shelfOrderMode=plan.mode
    end
    logger.info("[MiuRead][ShelfOrder] resolved",
        "mode=",plan.mode,"count=",tostring(plan.count),
        "read_fields=",tostring(plan.read_fields),
        "explicit_fields=",tostring(plan.explicit_fields),
        "top=",tostring(plan.top_count))
    return rows
end

local function archive_allowed(selected,entry)
    if not entry then return false end
    for _,name in ipairs(entry.archiveNames or {}) do
        if selected[name] then return true end
    end
    return false
end

function Library:_shelf_filter_selection(data)
    local names={}
    for _,archive in ipairs(archive_entries(data or {})) do
        local name=tostring(archive.name or archive.title or archive.archiveName or "分组")
        if name~="" then names[#names+1]=name end
    end
    if self.store and self.store.set_deferred and #names>0 then
        pcall(self.store.set_deferred,self.store,"shelf_archive_names",names)
    end
    if self.load_all_once then
        self.load_all_once=nil
        return nil
    end
    if not (self.store and self.store.preferences) then return nil end
    local ok,prefs=pcall(self.store.preferences,self.store)
    if not ok or type(prefs)~="table" then return nil end
    local filter=type(prefs.shelf_filter)=="table" and prefs.shelf_filter or {}
    local selected=type(filter.archives)=="table" and filter.archives or {}
    if filter.enabled~=true or next(selected)==nil then return nil end
    return selected
end

function Library:normalize(data)
    data=type(data)=="table" and data or {}
    local books,mp={},{}
    local seen_books,seen_mp={},{}
    local archive_map=build_archive_map(data)
    local selected_archives=self:_shelf_filter_selection(data)
    local src=data.books or data.bookList or data.updated or {}
    if type(src)~="table" then src={} end
    local raw_index=0
    local filtered_out=0
    for _,r in ipairs(src) do
        raw_index=raw_index+1
        local b=book(r,raw_index,archive_map)
        if b.bookId~="" then
            if Protocol.is_mp_account(b.bookId) then
                if not seen_mp[b.bookId] then mp[#mp+1]=b; seen_mp[b.bookId]=true end
            elseif not Protocol.is_mp(b.bookId) and not seen_books[b.bookId] then
                if selected_archives==nil or archive_allowed(selected_archives,archive_map[b.bookId]) then
                    books[#books+1]=b
                    seen_books[b.bookId]=true
                else
                    filtered_out=filtered_out+1
                end
            end
        end
    end
    if selected_archives~=nil then
        self.last_shelf_filter={kept=#books,filtered=filtered_out}
        logger.info("[MiuRead][ShelfFilter] applied","kept=",tostring(#books),"filtered=",tostring(filtered_out))
    else
        self.last_shelf_filter=nil
    end
    local extras={data.mp,data.mpBook,data.officialAccounts}
    for _,x in ipairs(extras) do
        if type(x)=="table" then
            if x[1] then
                for _,r in ipairs(x) do
                    raw_index=raw_index+1
                    local b=book(r,raw_index,archive_map)
                    if Protocol.is_mp_account(b.bookId) and not seen_mp[b.bookId] then mp[#mp+1]=b; seen_mp[b.bookId]=true end
                end
            else
                raw_index=raw_index+1
                local b=book(x,raw_index,archive_map)
                if Protocol.is_mp_account(b.bookId) and not seen_mp[b.bookId] then mp[#mp+1]=b; seen_mp[b.bookId]=true end
            end
        end
    end
    order_cloud_rows(books)
    order_cloud_rows(mp)
    return books,mp
end

local function shelf_rows_by_id(cache)
    local out={}
    cache=type(cache)=="table" and cache or {}
    for _,group in ipairs({cache.books or {},cache.mp or {}}) do
        for _,row in ipairs(group) do
            local id=tostring(type(row)=="table" and (row.bookId or row.book_id) or "")
            if id~="" then out[id]=row end
        end
    end
    return out
end

local function id_set(values)
    local out={}
    for _,value in ipairs(type(values)=="table" and values or {}) do
        local id=tostring(value or "")
        if id~="" then out[id]=true end
    end
    return out
end

function Library:_apply_stream_response(data)
    data=type(data)=="table" and data or {}
    local stream=type(data._miuread_stream)=="table" and data._miuread_stream or nil
    if stream and stream.keep_cache==true then
        local previous=self.store:shelf_cache() or {}
        local books=type(previous.books)=="table" and previous.books or {}
        local mp=type(previous.mp)=="table" and previous.mp or {}
        logger.info("[MiuRead][ShelfStream] cached shelf retained",
            "reason=",tostring(stream.reason or "stream_unavailable"),
            "books=",tostring(#books),"mp=",tostring(#mp))
        return books,mp,false,true
    end
    if not (stream and stream.enabled==true and type(stream.ids)=="table" and #stream.ids>0) then
        local books,mp=self:normalize(data)
        self.store:save_shelf_cache({
            books=books,mp=mp,updated_at=os.time(),
            stream={enabled=false,ids={},hydrated_ids={},total=#books+#mp,source=stream and stream.source or "full"},
        })
        return books,mp,false
    end

    local hydrated_books,hydrated_mp=self:normalize(data)
    local hydrated={}
    for _,row in ipairs(hydrated_books) do hydrated[tostring(row.bookId or "")]=row end
    for _,row in ipairs(hydrated_mp) do hydrated[tostring(row.bookId or "")]=row end

    local previous=self.store:shelf_cache()
    local cached=shelf_rows_by_id(previous)
    local loaded=id_set(stream.hydrated_ids)
    local books,mp={},{}
    for index,value in ipairs(stream.ids) do
        local id=tostring(value or "")
        if id~="" then
            local row=hydrated[id] and U.copy(hydrated[id]) or (cached[id] and U.copy(cached[id]) or nil)
            if not row then
                row={
                    bookId=id,title="正在加载…",author="",cover=nil,progress=0,
                    _stream_placeholder=true,
                }
            else
                row._stream_placeholder=nil
            end
            row.bookId=id
            row.rawIndex=index
            row.cloudOrder=index
            if loaded[id] then row._stream_placeholder=nil end
            if Protocol.is_mp_account(id) then mp[#mp+1]=row else books[#books+1]=row end
        end
    end
    -- onlyBookid responses are optimized for books and may omit the separate
    -- public-account directory. Preserve an existing MP cache unless the index
    -- explicitly supplied MP information; this avoids making the MP tab vanish
    -- during an otherwise successful streamed book refresh.
    local stream_has_mp=false
    for _,id in ipairs(stream.ids or {}) do
        if Protocol.is_mp_account(tostring(id or "")) then stream_has_mp=true; break end
    end
    if not stream_has_mp and data.mp==nil then
        local existing={}
        for _,row in ipairs(mp) do existing[tostring(row.bookId or "")]=true end
        for _,row in ipairs(previous.mp or {}) do
            local id=tostring(row.bookId or row.book_id or "")
            if id~="" and not existing[id] then mp[#mp+1]=U.copy(row); existing[id]=true end
        end
    end
    local stream_state={
        enabled=true,
        ids=U.copy(stream.ids),
        hydrated_ids=U.copy(stream.hydrated_ids or {}),
        total=tonumber(stream.total) or #stream.ids,
        has_more=stream.has_more==true,
        source=tostring(stream.source or "web_stream"),
        updated_at=tonumber(stream.updated_at) or os.time(),
    }
    self.store:save_shelf_cache({books=books,mp=mp,updated_at=os.time(),stream=stream_state})
    logger.info("[MiuRead][ShelfStream] index applied",
        "total=",tostring(#stream.ids),"hydrated=",tostring(#(stream.hydrated_ids or {})),
        "cached_reused=",tostring(#stream.ids-#(stream.hydrated_ids or {})))
    return books,mp,true
end

function Library:merge_stream_batch(data,requested_ids)
    local cache=self.store:shelf_cache()
    local stream=type(cache.stream)=="table" and cache.stream or {}
    if stream.enabled~=true then return false end
    local books,mp=self:normalize(type(data)=="table" and data or {})
    local fresh={}
    for _,row in ipairs(books) do fresh[tostring(row.bookId or "")]=row end
    for _,row in ipairs(mp) do fresh[tostring(row.bookId or "")]=row end
    local groups={cache.books or {},cache.mp or {}}
    local changed=0
    for _,group in ipairs(groups) do
        for index,row in ipairs(group) do
            local id=tostring(row.bookId or row.book_id or "")
            if fresh[id] then
                local replacement=U.copy(fresh[id])
                replacement.rawIndex=row.rawIndex
                replacement.cloudOrder=row.cloudOrder
                replacement._stream_placeholder=nil
                group[index]=replacement
                changed=changed+1
            end
        end
    end
    local loaded=id_set(stream.hydrated_ids)
    for _,id in ipairs(type(requested_ids)=="table" and requested_ids or {}) do
        id=tostring(id or "")
        if id~="" and fresh[id] then loaded[id]=true end
    end
    local ordered={}
    for _,id in ipairs(stream.ids or {}) do
        id=tostring(id or "")
        if loaded[id] then ordered[#ordered+1]=id end
    end
    stream.hydrated_ids=ordered
    stream.updated_at=os.time()
    cache.books,cache.mp=groups[1],groups[2]
    cache.stream=stream
    cache.updated_at=os.time()
    self.store:save_shelf_cache(cache)
    logger.info("[MiuRead][ShelfStream] batch merged",
        "requested=",tostring(#(requested_ids or {})),"changed=",tostring(changed),
        "hydrated=",tostring(#ordered),"total=",tostring(#(stream.ids or {})))
    return changed>0
end

function Library:stream_missing(first,last)
    local cache=self.store:shelf_cache()
    local stream=type(cache.stream)=="table" and cache.stream or {}
    if stream.enabled~=true then return {} end
    local by_id=shelf_rows_by_id(cache)
    first=math.max(1,tonumber(first) or 1)
    last=math.min(#(stream.ids or {}),tonumber(last) or first)
    local out={}
    for index=first,last do
        local id=tostring(stream.ids[index] or "")
        local row=by_id[id]
        if id~="" and (not row or row._stream_placeholder==true) then out[#out+1]=id end
    end
    return out
end

function Library:refresh(options)
    options=options or {}
    local data
    if options.stream==true and type(self.api.shelf_stream)=="function" then
        data=self.api:shelf_stream(options)
    else
        data=self.api:shelf(options)
    end
    local books,mp=self:_apply_stream_response(data)
    return books,mp
end
function Library:cached() local c=self.store:shelf_cache(); return c.books or {},c.mp or {},c.updated_at end
function Library:cached_stream() local c=self.store:shelf_cache(); return type(c.stream)=="table" and c.stream or {} end

local function record_state(row)
    local downloaded=false
    local partial_downloaded=false
    local has_record=false
    local latest_download=0
    local filenames={}
    local total_size=0
    local has_clean=false
    local has_notes=false
    local annotation_pending=false
    local annotation_fallback=false
    local content_type=nil
    local function scan(record,kind,is_final)
        if type(record)~="table" then return end
        local file=tostring(record.file or "")
        if file~="" then
            has_record=true
            latest_download=math.max(latest_download,tonumber(record.downloaded_at or 0) or 0)
            filenames[#filenames+1]=file:match("([^/]+)$") or file
            if U.file_exists(file) then
                if is_final then
                    downloaded=true
                    total_size=total_size+(tonumber(U.file_size(file)) or 0)
                    content_type=record.content_type or content_type
                    if kind=="clean" or kind=="range_clean" or kind=="preview_clean" then has_clean=true end
                    if kind=="notes" or kind=="range_notes" or kind=="preview_notes" then
                        has_notes=true
                        if DownloadResult.annotation_pending(record) then annotation_pending=true end
                        if record.annotation_fallback==true then annotation_fallback=true end
                    end
                else
                    partial_downloaded=true
                end
            end
        end
    end
    for kind,record in pairs((row and row.variants) or {}) do scan(record,tostring(kind),true) end
    for _,chapter in pairs((row and row.chapters) or {}) do
        for kind,record in pairs(chapter or {}) do scan(record,tostring(kind),false) end
    end
    return {
        has_record=has_record,
        downloaded=downloaded,
        partial_downloaded=partial_downloaded,
        file_missing=has_record and not downloaded and not partial_downloaded,
        downloaded_at=latest_download,
        filenames=table.concat(filenames," "),
        file_size=total_size,
        has_clean=has_clean,
        has_notes=has_notes,
        annotation_pending=annotation_pending,
        annotation_fallback=annotation_fallback,
        content_type=content_type,
    }
end

local function local_progress(session,row)
    session=type(session)=="table" and session or {}
    local pending=type(session.pending)=="table" and session.pending or {}
    return tonumber(pending.percent or session.progress_local_percent or session.verified_local_percent or row.progress or 0) or 0
end

function Library:is_downloaded(id, library_snapshot)
    local source=library_snapshot or self.store:library()
    local b=source and source[tostring(id)]
    return b and record_state(b).downloaded or false
end

local function local_book_from_row(id,row,session)
    if type(row)~="table" then return nil end
    local state=record_state(row)
    if not state.downloaded then return nil end
    session=type(session)=="table" and session or {}
    local b={
        bookId=tostring(row.book_id or id or ""),
        title=row.title or "未命名",
        author=row.author or "",
        cover=row.cover,
        category=row.category,
        updateTime=tonumber(row.updated_at or row.downloaded_at or 0) or 0,
        progress=local_progress(session,row),
        local_only=true,
        downloaded=true,
        file_missing=false,
        downloadedAt=state.downloaded_at,
        lastReadTime=tonumber(session.last_read_at or 0) or 0,
        filename_search=state.filenames,
        fileSize=state.file_size,
        hasClean=state.has_clean,
        hasNotes=state.has_notes,
        annotation_pending=state.annotation_pending,
        annotation_fallback=state.annotation_fallback,
        access=U.copy(row.access or {}),
        content_type=state.content_type or row.content_type,
        local_record=row,
    }
    return b.bookId~="" and b or nil
end

function Library:local_book(id,library_snapshot,sessions_snapshot)
    id=tostring(id or "")
    if id=="" then return nil end
    local source=library_snapshot or self.store:library()
    local row=source and source[id] or nil
    if type(row)~="table" then return nil end
    local sessions=sessions_snapshot or self.store:get("sessions",{})
    return local_book_from_row(id,row,sessions[id] or {})
end

function Library:local_books(library_snapshot,sessions_snapshot)
    local source=library_snapshot or self.store:library()
    local sessions=sessions_snapshot or self.store:get("sessions",{})
    local books,mp={},{}
    for id,row in pairs(source or {}) do
        local b=local_book_from_row(id,row,sessions[tostring(id)] or {})
        if b then
            if Protocol.is_mp_account(b.bookId) then
                mp[#mp+1]=b
            elseif not Protocol.is_mp(b.bookId) then
                books[#books+1]=b
            end
        end
    end
    return books,mp
end

local function local_index(local_rows)
    local index={}
    for _,row in ipairs(local_rows or {}) do
        local id=tostring(row.bookId or row.book_id or "")
        if id~="" then index[id]=row end
    end
    return index
end

local function merge_local_metadata(remote,local_book)
    remote.title=remote.title or local_book.title
    remote.author=remote.author or local_book.author
    remote.cover=remote.cover or local_book.cover
    remote.downloaded=local_book.downloaded==true
    remote.file_missing=local_book.file_missing==true
    remote.downloadedAt=tonumber(local_book.downloadedAt or 0) or 0
    remote.lastReadTime=tonumber(local_book.lastReadTime or 0) or 0
    remote.filename_search=local_book.filename_search
    remote.fileSize=tonumber(local_book.fileSize or 0) or 0
    remote.hasClean=local_book.hasClean==true
    remote.hasNotes=local_book.hasNotes==true
    remote.annotation_pending=local_book.annotation_pending==true
    remote.annotation_fallback=local_book.annotation_fallback==true
    remote.access=U.copy(local_book.access or {})
    remote.content_type=remote.content_type or local_book.content_type
    remote.local_record=local_book.local_record
    if (tonumber(remote.progress or 0) or 0)<=0 then remote.progress=local_book.progress end
    return remote
end

function Library:account_row(remote,local_book)
    if type(remote)~="table" then return nil end
    local b=U.copy(remote)
    local id=tostring(b.bookId or b.book_id or "")
    if id=="" then return nil end
    b.bookId=id
    b.local_only=false
    b.in_account_shelf=true
    b.remote_status_known=true
    if local_book then merge_local_metadata(b,local_book) else b.downloaded=false end
    return b
end

function Library:account_rows(remote_rows,local_rows)
    local local_by_id=local_index(local_rows)
    local out={}
    for _,remote in ipairs(remote_rows or {}) do
        local id=tostring(type(remote)=="table" and (remote.bookId or remote.book_id) or "")
        local b=self:account_row(remote,local_by_id[id])
        if b then out[#out+1]=b end
    end
    return out
end

function Library:generated_rows(remote_books,remote_mp,local_books,local_mp,remote_status_known)
    local remote_index={}
    for _,row in ipairs(remote_books or {}) do remote_index[tostring(row.bookId or "")]=row end
    for _,row in ipairs(remote_mp or {}) do remote_index[tostring(row.bookId or "")]=row end
    local out={}
    local function append(local_rows)
        for _,local_book in ipairs(local_rows or {}) do
            local b=U.copy(local_book)
            local id=tostring(b.bookId or "")
            local remote=remote_index[id]
            b.remote_status_known=remote_status_known==true
            b.in_account_shelf=remote~=nil
            b.local_only=remote==nil
            if remote then
                b.isTop=remote.isTop==true
                b.archiveName=remote.archiveName
                b.archiveNames=remote.archiveNames
                b.inArchive=remote.inArchive==true
                b.cloudOrder=remote.cloudOrder
                if (tonumber(b.progress or 0) or 0)<=0 then b.progress=remote.progress end
            end
            out[#out+1]=b
        end
    end
    append(local_books)
    append(local_mp)
    return out
end

-- Kept for older call sites and saved data. New shelf pages use account_rows and
-- generated_rows so cloud-only and generated files are never silently mixed.
function Library:merge_books(remote_rows,local_rows)
    local out=self:account_rows(remote_rows,local_rows)
    local seen={}
    for _,row in ipairs(out) do seen[tostring(row.bookId)]=true end
    for _,local_book in ipairs(local_rows or {}) do
        local id=tostring(local_book.bookId or "")
        if id~="" and not seen[id] then
            local copy=U.copy(local_book)
            copy.cloudOrder=copy.cloudOrder or (1000000+#out+1)
            out[#out+1]=copy
        end
    end
    return out
end

function Library:combined(remote_books,remote_mp,library_snapshot,sessions_snapshot)
    local local_books,local_mp=self:local_books(library_snapshot,sessions_snapshot)
    return self:merge_books(remote_books,local_books),self:merge_books(remote_mp,local_mp)
end

local function shelf_rows_fingerprint(rows,section)
    local parts={tostring(section or ""), tostring(#(rows or {}))}
    for index,row in ipairs(rows or {}) do
        parts[#parts+1]=table.concat({
            tostring(index), tostring(row.bookId or row.file or row.title or ""),
            tostring(row.title or ""), tostring(row.author or ""),
            tostring(row.file or ""), tostring(row.cover_path or row.cover or ""),
            tostring(row.cloudOrder or ""), tostring(row.readUpdateTime or ""),
            tostring(row.explicitOrder or ""), tostring(row.rawIndex or ""),
            tostring(row.downloadedAt or row.downloaded_at or ""),
            tostring(row.progress or ""), tostring(row.status_text or row.download_status or ""),
            row.isTop==true and "1" or "0",
            row.in_account_shelf==true and "1" or "0",
            row.generated==true and "1" or "0",
            row.downloaded==true and "1" or "0",
        },":")
    end
    return table.concat(parts,"|")
end

function Library:sort_filter(rows,options)
    options=options or {}
    local section=tostring(options.section or "account")
    self._sort_cache=type(self._sort_cache)=="table" and self._sort_cache or {}
    local fingerprint=shelf_rows_fingerprint(rows,section)
    local cached=self._sort_cache[section]
    if cached and cached.fingerprint==fingerprint and type(cached.rows)=="table" then
        return U.copy(cached.rows)
    end
    local out=U.copy(rows or {})
    if section=="account" then
        -- normalize() already selected the best available server ordering.
        -- Preserve that decision instead of guessing again when fields are
        -- missing on most rows.
        table.sort(out,function(a,b)
            local ao,bo=tonumber(a.cloudOrder),tonumber(b.cloudOrder)
            if ao~=nil and bo~=nil and ao~=bo then return ao<bo end
            return official_shelf_less(a,b)
        end)
    elseif section=="generated" then
        table.sort(out,function(a,b)
            local ai=a.in_account_shelf==true
            local bi=b.in_account_shelf==true
            if ai~=bi then return ai end
            if ai then
                local ao=tonumber(a.cloudOrder) or 1000000000
                local bo=tonumber(b.cloudOrder) or 1000000000
                if ao~=bo then return ao<bo end
                return official_shelf_less(a,b)
            else
                local ad=tonumber(a.downloadedAt or 0) or 0
                local bd=tonumber(b.downloadedAt or 0) or 0
                if ad~=bd then return ad>bd end
            end
            return tostring(a.bookId or "")<tostring(b.bookId or "")
        end)
    end
    self._sort_cache[section]={fingerprint=fingerprint,rows=U.copy(out)}
    logger.info("[MiuRead][ShelfOrder] prepared","count=",tostring(#out),"section=",section)
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

local function cover_header(path)
    local f=io.open(path,"rb")
    if not f then return nil end
    local data=f:read(1024) or ""
    f:close()
    return data
end

function Library:_valid_cover_path(path)
    path=tostring(path or "")
    if path=="" or not U.file_exists(path) then return false,"missing" end
    local size=tonumber(U.file_size(path) or 0) or 0
    if size<=0 then return false,"empty" end
    if size>COVER_MAX_BYTES then return false,"too_large" end
    local ext=select(1,Codec.media(cover_header(path) or ""))
    if not COVER_EXTENSIONS[ext] then return false,"unsupported" end
    return true,nil,size,ext
end

function Library:cached_cover_path(id,cover_index)
    local own_index=cover_index==nil
    local index=cover_index or self.store:get("cover_index",{})
    local key=tostring(id)
    local path=index[key]
    if not path then return nil,false end
    local valid,reason=self:_valid_cover_path(path)
    if valid then return path,false end
    logger.warn("[MiuRead][Cover] removed invalid cache","book_id=",key,"reason=",tostring(reason),"path=",tostring(path))
    os.remove(path)
    index[key]=nil
    if own_index then self.store:set("cover_index",index) end
    return nil,true
end

function Library:cache_cover(b,options)
    if not b or not b.cover or b.cover=="" then return nil end
    options=options or {}
    local persist_index=options.persist_index~=false
    local index={}
    if options.skip_index_lookup~=true then
        index=self.store:get("cover_index",{})
        local cached,removed=self:cached_cover_path(b.bookId,index)
        if cached then return cached end
        if removed and persist_index then self.store:set("cover_index",index) end
    end
    local download_url=cover_download_url(b.cover)
    local data=self.http:download(download_url,{
        auth=false,
        retries=options.retries==nil and 1 or options.retries,
        timeout=options.timeout or {8,15},
    })
    if not data or #data==0 then return nil end
    if #data>COVER_MAX_BYTES then
        logger.warn("[MiuRead][Cover] skipped oversized image","book_id=",tostring(b.bookId),"bytes=",tostring(#data))
        return nil
    end
    local ext,mime=Codec.media(data)
    if not COVER_EXTENSIONS[ext] then
        logger.warn("[MiuRead][Cover] skipped unsupported response","book_id=",tostring(b.bookId),"type=",tostring(mime),"bytes=",tostring(#data))
        return nil
    end

    local base=self.store.covers_dir.."/"..U.id_name(b.bookId)
    local suffix=tostring(options.cache_suffix or ""):gsub("[^%w_%-]","")
    if suffix~="" then base=base.."-"..suffix end
    local path=base..ext
    local written,write_error=U.atomic_write(path,data,true)
    if not written then error("cover write failed: "..tostring(write_error or "unknown")) end
    local valid,reason=self:_valid_cover_path(path)
    if not valid then
        os.remove(path)
        logger.warn("[MiuRead][Cover] downloaded image failed validation","book_id=",tostring(b.bookId),"reason=",tostring(reason))
        return nil
    end
    for old_ext in pairs(COVER_EXTENSIONS) do
        local old=base..old_ext
        if old~=path then os.remove(old) end
    end
    index[tostring(b.bookId)]=path
    if persist_index then self.store:set("cover_index",index) end
    logger.info("[MiuRead][Cover] cached","book_id=",tostring(b.bookId),"bytes=",tostring(#data),"type=",tostring(mime))
    return path
end
function Library:clear_covers() U.remove_tree(self.store.covers_dir); U.mkdir(self.store.covers_dir); self.store:set("cover_index",{}) end
function Library:reader_link(url)
    local id=tostring(url or ""):match("/web/reader/([^/?#]+)") or tostring(url or ""):match("bookId=([^&#]+)")
    if not id then return nil end
    if id:match("^%d+$") or Protocol.is_mp_account(id) then return id end
    return nil
end
return Library
