local U=require("miuread.util")
local lfs=require("libs/libkoreader-lfs")

local Cache={}
local online_sessions={}
local FINISHED_TTL=48*60*60

local function normalized(path)
    return tostring(path or ""):gsub("\\","/"):gsub("/+$","")
end

local function chapter_path(store,id,uid,kind,format)
    return normalized(store:prefetch_book_path(id)).."/"..U.id_name(uid).."-"..U.safe_name(kind,"clean")
        ..(format=="txt" and ".txt" or ".epub")
end

local function in_root(path,root)
    path,root=normalized(path),normalized(root)
    local ext=path:sub(#root+2):match("^[^/]+/[^/]+%-online%.([a-z]+)$")
    return root~="" and path:sub(1,#root+1)==root.."/" and (ext=="epub" or ext=="txt")
end

function Cache.is_limited_file(store,path)
    return in_root(path,store.limited_online_dir)
end

function Cache.is_online_file(store,path)
    return in_root(path,store.prefetch_dir) or Cache.is_limited_file(store,path)
end

function Cache.matches(store,id,uid,path)
    local file=normalized(path)
    local format=file:match("%.txt$") and "txt" or nil
    if Cache.is_limited_file(store,file) then
        return file==normalized(store:limited_online_path(id,uid,format))
    end
    return file==chapter_path(store,id,uid,"online",format)
end

function Cache.allowed_to_open(store,path,now)
    if not Cache.is_limited_file(store,path) then return true end
    local _,record=store:file_record_fast(path,false)
    local login=tostring((store:auth() or {}).login_session_id or "")
    if not record or login=="" or record.online_login~=login then return false end
    if record.online_server_only==true then return online_sessions[normalized(path)]==login end
    return (tonumber(record.online_expires) or 0)>(now or os.time())
end

function Cache.allow_session(store,record)
    if record.online_server_only~=true or not Cache.is_limited_file(store,record.file) then return end
    local login=tostring((store:auth() or {}).login_session_id or "")
    if login~="" and login==record.online_login then online_sessions[normalized(record.file)]=login end
end

function Cache.close_session(path)
    if path then online_sessions[normalized(path)]=nil end
end

function Cache.reusable(record)
    return type(record)=="table" and not record.online_expires and not record.online_server_only
        and record.file and U.file_exists(record.file)
end

local function finished_marker(file)
    return file..".miuread-eof"
end

local function finished_at(file,attr)
    local text=U.read_file(finished_marker(file),true) or ""
    local timestamp,modified,size=text:match("^(%d+) ([%-%.%d]+) (%d+)$")
    if tonumber(modified)==attr.modification and tonumber(size)==attr.size then return tonumber(timestamp) end
end

function Cache.mark_finished(store,id,uid,path,now)
    if not Cache.matches(store,id,uid,path) then return false end
    local attr=lfs.attributes(path)
    if not attr or attr.mode~="file" or finished_at(path,attr) then return false end
    local stamp=("%d %s %d"):format(now or os.time(),tostring(attr.modification),attr.size)
    return U.atomic_write(finished_marker(path),stamp,true)
end

function Cache.finished_at(path)
    local attr=lfs.attributes(path)
    return attr and finished_at(path,attr)
end

-- Walk only managed chapter EPUBs. KOReader sidecars and databases retain
-- reading positions and annotations independently of the temporary body.
function Cache.inspect(store,options)
    options=options or {}
    local now=options.now or os.time()
    local protected=options.protected or {}
    local library=store:library()
    local prefetch=store:get("prefetch_cache",{})
    local whole={}
    local rows={}
    local count,bytes=0,0
    local function add(id,uid,kind,record,variants,source)
        if options.book_id and tostring(id)~=tostring(options.book_id) then return end
        if type(record)~="table" then return end
        local limited=source=="read" and Cache.is_limited_file(store,record.file)
        local format=record.document_format
        local file=limited and store:limited_online_path(id,uid,format) or chapter_path(store,id,uid,kind,format)
        if not file or normalized(record.file)~=file then return end
        local attr=lfs.attributes(file)
        if not attr or attr.mode~="file" then return end
        count=count+1
        bytes=bytes+(tonumber(attr.size) or 0)
        if options.measure_only or protected[file] or record.pending_install==true then return end
        if whole[id]==nil then whole[id]=options.complete and options.complete(id)==true or false end
        local finished=source=="read" and finished_at(file,attr)
        if limited or options.manual or whole[id] or (finished and now-finished>=FINISHED_TTL) then
            rows[#rows+1]={file=file,variants=variants,kind=kind,source=source}
        end
    end
    for id,book in pairs(library) do
        for uid,variants in pairs(book.chapters or {}) do
            add(id,uid,"online",variants.online,variants,"read")
        end
    end
    for id,chapters in pairs(prefetch) do
        for uid,variants in pairs(chapters) do
            for kind,record in pairs(variants) do
                add(id,uid,kind,record,variants,"prefetch")
            end
        end
    end
    return {rows=rows,count=count,bytes=bytes,library=library,prefetch=prefetch}
end

function Cache.prune(store,options)
    local result=Cache.inspect(store,options)
    local removed,read_changed,prefetch_changed=0,false,false
    for _,row in ipairs(result.rows) do
        if os.remove(row.file) then
            if row.source=="read" then os.remove(finished_marker(row.file)) end
            row.variants[row.kind]=nil
            removed=removed+1
            if row.source=="read" then read_changed=true else prefetch_changed=true end
        end
    end
    if read_changed then
        for _,book in pairs(result.library) do
            for uid,variants in pairs(book.chapters or {}) do
                if next(variants)==nil then book.chapters[uid]=nil end
            end
        end
        store:set("library",result.library)
    end
    if prefetch_changed then
        for id,chapters in pairs(result.prefetch) do
            for uid,variants in pairs(chapters) do
                if next(variants)==nil then chapters[uid]=nil end
            end
            if next(chapters)==nil then result.prefetch[id]=nil end
        end
        store:set("prefetch_cache",result.prefetch)
    end
    return removed,#result.rows
end

return Cache
