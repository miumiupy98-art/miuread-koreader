-- MiuRead beta.12: legacy installed EPUB Web-source readiness.
-- Never touches progress positions, readtime workers, EPUB bytes or POST APIs.
-- One chapter per isolated background worker; only trusted MiuRead EPUBs.
local U=require("miuread.util")
local Installer=require("miuread.epub_installer")
local Source=require("miuread.source_position")
local M={}
local KEY="legacy_web_coordinate_jobs_v1"
local MAX_JOBS=256
local ok_lfs,lfs=pcall(require,"libs/libkoreader-lfs")
local function modified(path)
    if ok_lfs and lfs and lfs.attributes then
        return tonumber(lfs.attributes(path,"modification")) or 0
    end
    return 0
end

local function get(store)
    local value=store:get(KEY,{})
    return type(value)=="table" and value or {}
end
local function put(store,rows)
    return store:set(KEY,rows)
end
local function identify(job)
    return table.concat({tostring(job.book_id or ""),tostring(job.variant or ""),
        tostring(job.file or "")},"|")
end
local function files_for_book(store,book)
    local files={}
    local function append(v)
        if type(v)~="table" then return end
        local path=tostring(v.file or "")
        if path:lower():match("%.epub$") and U.file_exists(path) and v.pending_install~=true then
            local ready=v.progress_source_complete==true
            if ready then
                local chapters=type(v.chapter_map)=="table" and v.chapter_map or {}
                local version=tonumber(v.progress_source_book_version or book.version or 0) or 0
                local id=tostring(book.book_id or book.bookId or "")
                local sample={chapters[1],chapters[#chapters]}
                if #chapters==0 or version<=0 then ready=false end
                if ready then
                    local root=store:book_dir(id).."/progress-source-position/"
                    for _,ch in ipairs(sample) do
                        local uid=tostring(ch and (ch.uid or ch.chapter_uid or ch.chapterUid) or "")
                        local path=root..U.id_name(uid).."-v"..U.id_name(tostring(version))..".xhtml"
                        if uid=="" or not U.file_exists(path) then ready=false;break end
                    end
                end
            end
            files[#files+1]={book_id=tostring(book.book_id or book.bookId or ""),
                file=path,variant=tostring(v.variant or "clean"),
                version=tonumber(v.progress_source_book_version or book.version or 0) or 0,
                title=tostring(book.title or v.title or ""),
                already_ready=ready,
                chapter_count=tonumber(v.progress_source_chapter_count or v.chapter_count or 0) or 0,
                size=U.file_size(path) or 0,mtime=modified(path)}
        end
    end
    for _,v in pairs(book.variants or {}) do append(v) end
    for _,row in pairs(book.chapters or {}) do
        if type(row)=="table" then
            for _,v in pairs(row) do append(v) end
        end
    end
    return files
end

function M.discover(store,only_book,only_file)
    local result,seen={},{}
    for _,book in ipairs(store:all_books() or {}) do
        if not only_book or tostring(book.book_id or book.bookId)==tostring(only_book) then
            for _,job in ipairs(files_for_book(store,book)) do
                local key=identify(job)
                if not seen[key] and (not only_file or job.file==only_file)
                    and (only_book or not job.already_ready) then
                    seen[key]=true
                    job.key=key
                    result[#result+1]=job
                end
                if #result>=MAX_JOBS then return result end
            end
        end
    end
    return result
end

function M.enqueue(store,job,vid,session,manual)
    if type(job)~="table" or not job.file or tostring(job.book_id or "")==""
        or tostring(vid or "")=="" or tostring(session or "")=="" then return nil,"identity_missing" end
    local rows=get(store)
    job.key=job.key or identify(job)
    local existing
    for _,row in ipairs(rows) do if row.key==job.key then existing=row;break end end
    if existing and existing.vid==tostring(vid) and existing.session==tostring(session)
        and existing.size==job.size and existing.mtime==job.mtime
        and existing.version==job.version then
        if manual then
            existing.status="pending";existing.next_at=0;existing.failures=0
            existing.next_index=1;existing.error=nil
            return put(store,rows)==true
        end
        return existing.status=="pending" or existing.status=="complete"
    end
    if existing then
        -- A changed EPUB, version or account invalidates prior verification.
        for i,row in ipairs(rows) do if row.key==job.key then table.remove(rows,i);break end end
    end
    if #rows>=MAX_JOBS then return nil,"queue_full" end
    if job.already_ready and not manual and job.chapter_count>0 and job.version>0 then
        -- Already validated at download time; does not need legacy repair.
        return true
    end
    local entry={key=job.key,book_id=job.book_id,file=job.file,variant=job.variant,
        title=job.title,version=job.version,size=job.size,mtime=job.mtime,
        vid=tostring(vid),session=tostring(session),status="pending",
        next_at=0,next_index=1,verified=0,total=0,failures=0}
    rows[#rows+1]=entry
    return put(store,rows)==true
end

-- Bulk automatic discovery avoids one database flush per library book.
function M.seed(store,candidates,vid,session)
    if tostring(vid or "")=="" or tostring(session or "")=="" then return 0 end
    local rows=get(store)
    local by_key={}
    for i,row in ipairs(rows) do by_key[row.key]=i end
    local added,changed=0,false
    for _,job in ipairs(candidates or {}) do
        if #rows>=MAX_JOBS then break end
        local key=job.key or identify(job)
        if key~="" and job.file and job.already_ready~=true then
            local old_index=by_key[key]
            local old=old_index and rows[old_index]
            local current=old and old.vid==tostring(vid) and old.session==tostring(session)
                and old.version==job.version and old.size==job.size and old.mtime==job.mtime
            if not current then
                local row={key=key,book_id=job.book_id,file=job.file,variant=job.variant,
                    title=job.title,version=job.version,size=job.size,mtime=job.mtime,
                    vid=tostring(vid),session=tostring(session),status="pending",
                    next_at=0,next_index=1,verified=0,total=0,failures=0}
                if old_index then rows[old_index]=row else
                    rows[#rows+1]=row;by_key[key]=#rows end
                added=added+1;changed=true
            end
        end
    end
    if changed then put(store,rows) end
    return added
end

function M.select(store,now,vid,session)
    now=tonumber(now) or os.time()
    for _,row in ipairs(get(store)) do
        if row.status=="pending" and tonumber(row.next_at or 0)<=now
            and row.vid==tostring(vid or "") and row.session==tostring(session or "") then
            return U.copy(row)
        end
    end
    return nil
end

function M.set_status(store,book_id,status)
    if status~="paused" and status~="pending" and status~="cancel" then return false end
    local rows=get(store)
    local changed=false
    for _,row in ipairs(rows) do
        if row.book_id==tostring(book_id or "") then
            if status=="cancel" then
                -- Retain a cancelled tombstone: automatic discovery must not
                -- silently start the task again at the next idle scan.
                row.status="cancelled";row.next_at=0
            elseif row.status~="complete" then
                row.status=status
                if status=="pending" then row.next_at=0;row.failures=0 end
            end
            changed=true
        end
    end
    return changed and put(store,rows)==true
end

function M.next_delay(store,now,vid,session)
    now=tonumber(now) or os.time()
    local earliest
    for _,row in ipairs(get(store)) do
        if row.status=="pending" and row.vid==tostring(vid or "")
            and row.session==tostring(session or "") then
            local seconds=math.max(0,(tonumber(row.next_at) or now)-now)
            earliest=math.min(earliest or seconds,seconds)
        end
    end
    return earliest
end

function M.summary(store,book_id)
    local total,done,pending,attention,cancelled=0,0,0,0,0
    for _,row in ipairs(get(store)) do
        if not book_id or row.book_id==tostring(book_id) then
            total=total+1
            if row.status=="complete" then done=done+1
            elseif row.status=="needs_attention" then attention=attention+1
            elseif row.status=="cancelled" then cancelled=cancelled+1
            else pending=pending+1 end
        end
    end
    return {total=total,complete=done,pending=pending,needs_attention=attention,cancelled=cancelled}
end

local function normalized_meta(meta,record,index)
    local chapter=type(meta.chapters)=="table" and meta.chapters[index] or nil
    if type(chapter)~="table" then
        return nil,"chapter_metadata_missing"
    end
    local uid=tostring(chapter.uid or chapter.chapter_uid or chapter.chapterUid or "")
    if uid=="" then return nil,"chapter_uid_missing" end
    if chapter.structural==true then return {uid=uid,structural=true} end
    return {uid=uid,title=tostring(chapter.title or ""),
        index=tonumber(chapter.index or chapter.chapterIdx) or index}
end

function M.perform(job,reader)
    if type(job)~="table" or not reader then return {ok=false,reason="job_invalid"} end
    local path=tostring(job.file or "")
    if not U.file_exists(path) or U.file_size(path)~=tonumber(job.size)
        or (tonumber(job.mtime or 0)>0 and modified(path)~=tonumber(job.mtime)) then
        return {ok=false,reason="file_changed",permanent=true}
    end
    local meta,entries=Installer.inspect(path)
    if not meta then return {ok=false,reason="epub_inspect:"..tostring(entries),permanent=true} end
    if tostring(meta.book_id or "")~=tostring(job.book_id or "") then
        return {ok=false,reason="epub_book_id_mismatch",permanent=true}
    end
    if type(meta.chapters)~="table" or #meta.chapters~=(tonumber(meta._chapter_count) or 0) then
        return {ok=false,reason="chapter_catalog_unverifiable",permanent=true}
    end
    local version=tonumber(meta.progress_source_book_version) or 0
    if version<=0 then version=tonumber(job.version) or 0 end
    if version<=0 then return {ok=false,reason="web_version_unknown",permanent=true} end
    local idx=math.max(1,math.floor(tonumber(job.next_index) or 1))
    if idx>meta._chapter_count then return {ok=true,complete=true,total=meta._chapter_count} end
    local html,chapter,err=Installer.read_chapter_text(path,idx,meta,entries)
    if not html then return {ok=false,reason="epub_chapter_unreadable:"..tostring(err),permanent=true} end
    chapter,err=normalized_meta(meta,job,idx)
    if not chapter then return {ok=false,reason=err,permanent=true} end
    if chapter.structural then
        return {ok=true,index=idx,uid=chapter.uid,skipped=true,total=meta._chapter_count}
    end
    -- Never use a native E-Ink chapter as authoritative Web co basis.
    local web=Source.readExactChapter(reader,job.book_id,chapter.uid,version)
    local mapped=web and Source.validateDownloadChapter(html,web) or nil
    if not mapped then
        local book={bookId=tostring(job.book_id),title=tostring(job.title or ""),version=version}
        local ch={uid=chapter.uid,chapterUid=chapter.uid,
            chapterIdx=chapter.index,title=chapter.title}
        local called,body,_,_,state=pcall(reader.chapter,reader,book,ch,"epub",
            {images=false,fresh_context=true,keepalive=true,rate_limit_fail_fast=true})
        if type(reader.cleanup_transient_images)=="function" then
            pcall(reader.cleanup_transient_images,reader)
        end
        if not called then return {ok=false,reason="web_fetch:"..tostring(body)} end
        if type(state)~="table" or state.coordinate_source_authoritative==false
            or state.source_channel=="eink" then
            return {ok=false,reason="web_source_not_authoritative",permanent=true}
        end
        web=tostring(state.coord_html or "")
        if web=="" then web=tostring(body or "") end
        mapped,err=Source.validateDownloadChapter(html,web)
        if not mapped then return {ok=false,reason="anchor_mismatch:"..tostring(err),permanent=true} end
        local saved,why=Source.cacheChapter(reader,job.book_id,chapter.uid,version,web)
        if not saved then return {ok=false,reason="cache_failed:"..tostring(why)} end
    end
    return {ok=true,index=idx,uid=chapter.uid,anchors=mapped.anchors,total=meta._chapter_count}
end

function M.commit(store,job,result,now)
    now=tonumber(now) or os.time()
    local rows=get(store)
    for _,row in ipairs(rows) do
        if row.key==job.key and row.vid==job.vid and row.session==job.session
            and row.next_index==job.next_index and row.status=="pending" then
            result=type(result)=="table" and result or {ok=false,reason="worker_unavailable"}
            if result.ok==true then
                row.failures=0;row.error=nil
                row.next_index=math.max(1,tonumber(row.next_index) or 1)+1
                if result.skipped~=true then row.verified=(tonumber(row.verified) or 0)+1 end
                row.total=math.max(tonumber(row.total) or 0,tonumber(result.total) or 0)
                if result.complete==true or row.next_index>row.total then
                    row.status="complete";row.completed_at=now
                else row.next_at=now+4 end
            else
                row.failures=(tonumber(row.failures) or 0)+1
                row.error=tostring(result.reason or "failed"):sub(1,180)
                local permanent=result.permanent==true or row.error:find("anchor_mismatch",1,true)
                    or row.error:find("source_not_authoritative",1,true)
                if permanent or row.failures>=4 then
                    row.status="needs_attention";row.next_at=0
                else
                    row.next_at=now+math.min(3600,45*3^(row.failures-1))
                end
            end
            row.updated_at=now
            return put(store,rows)==true
        end
    end
    return false
end

return M
