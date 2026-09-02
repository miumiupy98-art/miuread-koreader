local AnnotationCoord=require("miuread.annotation_coord")
local CommentDB=require("miuread.comment_download_database")
local DownloadDatabase=require("miuread.download_database")
local SourcePosition=require("miuread.source_position")
local Thoughts=require("miuread.thoughts")
local U=require("miuread.util")
local logger=require("logger")

local Service={}
Service.__index=Service

local function uid_of(chapter)
    return tostring(type(chapter)=="table" and (chapter.uid or chapter.chapterUid or chapter.chapter_uid) or "")
end
local function counts(store,book_id,uid)
    local groups=Thoughts.load(store,book_id,uid)
    if type(groups)~="table" then return 0,0 end
    local group_count,comment_count=0,0
    for _,group in ipairs(groups) do
        local n=type(group)=="table" and #(group.texts or {}) or 0
        if n>0 then group_count=group_count+1; comment_count=comment_count+n end
    end
    return group_count,comment_count
end
local function result_counts(groups)
    local g,c=0,0
    for _,group in ipairs(type(groups)=="table" and groups or {}) do
        local n=type(group)=="table" and #(group.texts or {}) or 0
        if n>0 then g=g+1; c=c+n end
    end
    return g,c
end

function Service:new(annotations,reader,store)
    return setmetatable({annotations=annotations,reader=reader,store=store},self)
end

function Service:_source_ready(book,chapter)
    local uid=uid_of(chapter)
    if uid=="" then return false,"chapter_uid_missing" end
    local source,_,err=SourcePosition.chapterSource(self.reader,book.bookId or book.book_id,uid,
        book.version or book.bookVersion or 0,{
            cache_only=false,
            chapter_index=tonumber(chapter.index or chapter.chapterIdx or chapter.chapter_index) or 0,
            chapter_title=tostring(chapter.title or ""),
            book_title=tostring(book.title or ""),book_author=tostring(book.author or ""),
        })
    if type(source)~="string" or source=="" then return false,tostring(err or "source_missing") end
    local ok,map=pcall(AnnotationCoord.build,source)
    if not ok or type(map)~="table" then return false,"source_map_invalid:"..tostring(map) end
    return true,nil
end

function Service:_fetch_chapter(book,chapter,options)
    options=type(options)=="table" and options or {}
    local book_id=tostring(book.bookId or book.book_id or "")
    local uid=uid_of(chapter)
    if book_id=="" or uid=="" then return nil,"scope_missing" end
    local account_key=DownloadDatabase.account_key(self.store)
    local version=tonumber(book.version or book.bookVersion) or 0
    local stable=CommentDB.state(self.store,book_id,uid)
    local previous=CommentDB.load_checkpoint(self.store,book_id,uid,account_key,self.annotations)
    -- A user-requested full refresh must rebuild the server snapshot from scratch.
    -- Reusing a partial checkpoint here would make “更新本书全部评论” only resume
    -- its old pending ranges, and merging old completed groups would keep comments
    -- that the server has since removed. Missing/continue mode still reuses the
    -- checkpoint below for true breakpoint recovery.
    if options.force_refresh==true then previous=nil end

    local function checkpoint(snapshot)
        local merged=self.annotations:merge(previous,snapshot)
        merged.saved_at=os.time()
        local saved,err=CommentDB.save_checkpoint(self.store,book_id,uid,account_key,self.annotations,merged)
        if saved~=true then error("评论断点保存失败："..tostring(err or "unknown")) end
        previous=CommentDB.load_checkpoint(self.store,book_id,uid,account_key,self.annotations) or merged
        return previous
    end

    CommentDB.save_state(self.store,book_id,uid,{
        status="fetching",account_key=account_key,started_at=os.time(),updated_at=os.time(),last_error="",
    })

    local ok,current=pcall(self.annotations.fetch_chapter,self.annotations,book_id,uid,
        options.progress,{previous=previous,force_refresh=options.force_refresh==true,checkpoint=checkpoint})
    if not ok or type(current)~="table" then
        local err=tostring(current or "invalid_comment_result")
        CommentDB.save_state(self.store,book_id,uid,{status="failed",account_key=account_key,updated_at=os.time(),last_error=err})
        return nil,err
    end

    local merged=(current==previous) and current or self.annotations:merge(previous,current)
    merged.saved_at=os.time()
    CommentDB.save_checkpoint(self.store,book_id,uid,account_key,self.annotations,merged)

    local old_groups,old_comments=counts(self.store,book_id,uid)
    local complete=merged.complete==true and merged.review_complete==true and merged.underline_request_ok==true
    local status,source_ready,source_error,stable_commit
    stable_commit=false
    if complete then
        local new_groups,new_comments=result_counts(merged.review_groups)
        if old_comments>0 and new_comments==0 then
            status="suspicious_zero"
        else
            local saved,save_err=Thoughts.save(self.store,book_id,uid,merged.review_groups or {})
            if saved==nil then
                status="failed"
                source_error=tostring(save_err or "comment_save_failed")
            elseif new_comments==0 then
                status="empty"; source_ready=false; stable_commit=true
            else
                source_ready,source_error=self:_source_ready(book,chapter)
                if source_ready then status="complete"; stable_commit=true else status="partial" end
            end
        end
    else
        local kind=tostring(merged.error_kind or "")
        if merged.rate_limited==true or kind=="rate_limit" then status="rate_limited"
        elseif merged.auth_required==true or kind=="authentication" then status="auth_required"
        elseif merged.forbidden==true or kind=="forbidden" then status="auth_required"
        else status="partial" end
    end

    local group_count,comment_count=counts(self.store,book_id,uid)
    local patch={
        status=status,account_key=account_key,updated_at=os.time(),
        fetched_at=stable_commit and os.time() or nil,
        range_count=tonumber(merged.underline_count or 0) or 0,
        group_count=group_count,comment_count=comment_count,
        pending_count=#(merged.pending_ranges or {}),
        last_error=tostring(source_error or table.concat(merged.errors or {},"; ")),
    }
    if stable_commit then
        patch.book_version=version; patch.source_ready=source_ready==true
    elseif type(stable)=="table" and (status=="suspicious_zero" or comment_count>0) then
        patch.book_version=tonumber(stable.book_version) or 0
        patch.source_ready=stable.source_ready==true
    end
    CommentDB.save_state(self.store,book_id,uid,patch)

    logger.info("[MiuRead][CommentDownload] chapter",
        "book=",book_id,"chapter=",uid,"status=",tostring(status),
        "ranges=",tostring(merged.underline_count or 0),"groups=",tostring(group_count),
        "comments=",tostring(comment_count),"old_comments=",tostring(old_comments))
    return {chapter_uid=uid,status=status,groups=group_count,comments=comment_count,
        ranges=tonumber(merged.underline_count or 0) or 0,pending=#(merged.pending_ranges or {}),
        source_ready=source_ready==true,error=source_error,error_kind=tostring(merged.error_kind or "")}
end

function Service:download(book,chapters,options)
    options=type(options)=="table" and options or {}
    book=type(book)=="table" and book or {}
    chapters=type(chapters)=="table" and chapters or {}
    local book_id=tostring(book.bookId or book.book_id or "")
    if book_id=="" then error("book_id_missing") end
    local total=#chapters
    local summary={book_id=book_id,total=total,processed=0,skipped=0,complete=0,empty=0,partial=0,failed=0,suspicious=0,comments=0}
    for index,chapter in ipairs(chapters) do
        if options.cancelled and options.cancelled()==true then error("评论下载已取消") end
        local uid=uid_of(chapter)
        if uid~="" then
            local prior=CommentDB.state(self.store,book_id,uid)
            local version=tonumber(book.version or book.bookVersion) or 0
            local reusable=options.force_refresh~=true and type(prior)=="table"
                and (prior.status=="complete" or prior.status=="empty")
                and (tonumber(prior.book_version) or 0)==version
            if reusable then
                summary.skipped=summary.skipped+1
            else
                local value=self:_fetch_chapter(book,chapter,options)
                local status=value and value.status or "failed"
                if status=="complete" then summary.complete=summary.complete+1
                elseif status=="empty" then summary.empty=summary.empty+1
                elseif status=="suspicious_zero" then summary.suspicious=summary.suspicious+1
                elseif status=="partial" or status=="rate_limited" or status=="auth_required" then summary.partial=summary.partial+1
                else summary.failed=summary.failed+1 end
                if value then summary.comments=summary.comments+(tonumber(value.comments) or 0) end
                local error_kind=tostring(value and value.error_kind or "")
                if status=="failed" or status=="rate_limited" or status=="auth_required"
                    or (status=="partial" and (error_kind=="network" or error_kind=="server" or error_kind=="authentication" or error_kind=="forbidden")) then
                    summary.stop_reason=status~="partial" and status or error_kind
                end
            end
        end
        summary.processed=index
        CommentDB.save_job(self.store,book_id,{
            status="active",mode=options.force_refresh==true and "refresh" or "missing",
            title=tostring(book.title or ""),total=total,processed=index,
            complete=summary.complete,empty=summary.empty,partial=summary.partial,
            failed=summary.failed,suspicious=summary.suspicious,updated_at=os.time(),
            started_at=tonumber(options.started_at) or os.time(),
        })
        if summary.stop_reason then
            logger.warn("[MiuRead][CommentDownload] circuit stopped",
                "book=",book_id,"chapter=",uid_of(chapter),"reason=",tostring(summary.stop_reason))
            break
        end
    end
    summary.status=(summary.failed>0 or summary.partial>0 or summary.suspicious>0 or summary.processed<total) and "partial" or "completed"
    CommentDB.save_job(self.store,book_id,{
        status=summary.status,title=tostring(book.title or ""),total=total,processed=summary.processed,
        complete=summary.complete,empty=summary.empty,partial=summary.partial,failed=summary.failed,
        suspicious=summary.suspicious,updated_at=os.time(),completed_at=os.time(),
    })
    return summary
end

function Service:runtime_marks(book,chapter)
    book=type(book)=="table" and book or {}
    chapter=type(chapter)=="table" and chapter or {}
    local book_id=tostring(book.bookId or book.book_id or "")
    local uid=uid_of(chapter)
    if book_id=="" or uid=="" then return nil,"scope_missing" end
    local state=CommentDB.state(self.store,book_id,uid)
    if type(state)~="table" then return nil,"independent_comments_not_downloaded" end
    local version=tonumber(book.version or book.bookVersion) or 0
    if (tonumber(state.book_version) or 0)~=version then return nil,"comment_book_version_stale" end
    if state.source_ready~=true then return nil,"comment_source_not_ready" end
    local usable={complete=true,fetching=true,partial=true,failed=true,rate_limited=true,auth_required=true,suspicious_zero=true}
    if usable[tostring(state.status or "")]~=true or (tonumber(state.comment_count) or 0)<=0 then
        return nil,"comment_snapshot_not_ready"
    end
    local groups,load_error=Thoughts.load(self.store,book_id,uid)
    if type(groups)~="table" then return nil,tostring(load_error or "comments_missing") end
    local source,_,source_error=SourcePosition.chapterSource(self.reader,book_id,uid,version,{
        cache_only=true,chapter_index=tonumber(chapter.index or chapter.chapterIdx or chapter.chapter_index) or 0,
        chapter_title=tostring(chapter.title or ""),book_title=tostring(book.title or ""),book_author=tostring(book.author or ""),
    })
    if type(source)~="string" or source=="" then return nil,tostring(source_error or "source_missing") end
    local ok,map=pcall(AnnotationCoord.build,source)
    if not ok or type(map)~="table" then return nil,"source_map_invalid" end
    local marks={}
    for _,group in ipairs(groups) do
        local range=tostring(type(group)=="table" and group.range or "")
        if range~="" and #(group.texts or {})>0 then
            local resolved=AnnotationCoord.resolveRangeOnMap(map,range)
            if type(resolved)=="table" and resolved.point~=true and U.trim(tostring(resolved.text or ""))~="" then
                local before,after=AnnotationCoord.contextForSpan(map,resolved.text_start,resolved.text_end_pos,32)
                marks[#marks+1]={range=range,source_text=tostring(resolved.text or ""),context_before=before,context_after=after}
            end
        end
    end
    return marks,nil,{groups=#marks}
end

return Service
