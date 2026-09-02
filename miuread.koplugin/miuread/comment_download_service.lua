local AnnotationCoord = require("miuread.annotation_coord")
local DownloadDatabase = require("miuread.download_database")
local SourcePosition = require("miuread.source_position")
local ThoughtDatabase = require("miuread.thought_database")
local Thoughts = require("miuread.thoughts")
local U = require("miuread.util")

local Service = {}
Service.__index = Service

local function chapter_uid(chapter)
    return tostring(type(chapter)=="table" and (chapter.uid or chapter.chapterUid or chapter.chapter_uid) or "")
end

local function checkpoint_root(store, book_id)
    local root = store:book_dir(book_id) .. "/comments"
    U.mkdir(root)
    return root
end

local function current_counts(store, book_id, uid)
    local value = ThoughtDatabase.chapter_counts(store, book_id, uid)
    return tonumber(value.groups or 0) or 0, tonumber(value.comments or 0) or 0
end

function Service:new(annotations, reader, store)
    return setmetatable({annotations=annotations,reader=reader,store=store},self)
end

function Service:_source_ready(book, chapter)
    local uid=chapter_uid(chapter)
    if uid=="" then return false,"chapter_uid_missing" end
    local source,_,err=SourcePosition.chapterSource(self.reader,book.bookId or book.book_id,uid,book.version or book.bookVersion or 0,{
        cache_only=false,
        chapter_index=tonumber(chapter.index or chapter.chapterIdx or chapter.chapter_index) or 0,
        chapter_title=tostring(chapter.title or ""),
        book_title=tostring(book.title or ""),
        book_author=tostring(book.author or ""),
    })
    if type(source)~="string" or source=="" then return false,tostring(err or "source_missing") end
    -- Build once here so a corrupt source is caught during the explicit download
    -- operation instead of surfacing later as a mysterious reader-only failure.
    local ok,map=pcall(AnnotationCoord.build,source)
    if not ok or type(map)~="table" then return false,"source_map_invalid:"..tostring(map) end
    return true,nil
end

function Service:_fetch_chapter(book,chapter,options)
    options=type(options)=="table" and options or {}
    local book_id=tostring(book.bookId or book.book_id or "")
    local uid=chapter_uid(chapter)
    local account_key=DownloadDatabase.account_key(self.store)
    local current_version=tonumber(book.version or book.bookVersion) or 0
    local stable_state=ThoughtDatabase.fetch_state(self.store,book_id,uid)
    local root=checkpoint_root(self.store,book_id)
    local previous=DownloadDatabase.load_annotation_data(root,uid,account_key,self.annotations)
    local function persist(snapshot)
        local merged=self.annotations:merge(previous,snapshot)
        merged.saved_at=os.time()
        local saved,err=DownloadDatabase.save_annotation_data(root,uid,account_key,self.annotations,merged)
        if not saved then error("评论断点保存失败："..tostring(err or "unknown")) end
        previous=DownloadDatabase.load_annotation_data(root,uid,account_key,self.annotations) or merged
        return previous
    end

    ThoughtDatabase.save_fetch_state(self.store,book_id,uid,{
        status="fetching",account_key=account_key,
        started_at=os.time(),updated_at=os.time(),last_error="",
    })

    local ok,result=pcall(self.annotations.fetch_chapter,self.annotations,book_id,uid,nil,{
        previous=previous,
        force_refresh=options.force_refresh==true,
        checkpoint=persist,
    })
    if not ok or type(result)~="table" then
        local err=tostring(result or "invalid_comment_result")
        ThoughtDatabase.save_fetch_state(self.store,book_id,uid,{
            status="failed",account_key=account_key,updated_at=os.time(),last_error=err,
        })
        return nil,err
    end

    local merged=self.annotations:merge(previous,result)
    merged.saved_at=os.time()
    DownloadDatabase.save_annotation_data(root,uid,account_key,self.annotations,merged)

    local old_groups,old_comments=current_counts(self.store,book_id,uid)
    local complete=merged.complete==true and merged.review_complete==true and merged.underline_request_ok==true
    local status
    local source_ready,source_error=nil,nil
    local stable_commit=false
    if complete then
        local groups=type(merged.review_groups)=="table" and merged.review_groups or {}
        local new_group_count,new_comment_count=0,0
        for _,group in ipairs(groups) do
            local count=type(group)=="table" and #(group.texts or {}) or 0
            if count>0 then new_group_count=new_group_count+1; new_comment_count=new_comment_count+count end
        end
        -- Never allow one suspicious empty server response to erase a known-good
        -- local comment snapshot. The user can retry; preserving stale comments is
        -- safer than destructive false-empty reconciliation in a beta migration.
        if old_comments>0 and new_comment_count==0 then
            status="suspicious_zero"
        else
            local saved,save_err=Thoughts.save(self.store,book_id,uid,groups)
            if saved==nil then
                status="failed"
                result.error_kind="storage"
                result.errors=result.errors or {}
                result.errors[#result.errors+1]=tostring(save_err or "comment_save_failed")
            elseif new_comment_count==0 then
                -- Empty chapters need no text anchor; the verified empty result is
                -- already a complete independent-comment snapshot.
                status="empty"
                stable_commit=true
                source_ready=false
            else
                source_ready,source_error=self:_source_ready(book,chapter)
                if source_ready then
                    status="complete"
                    stable_commit=true
                else
                    -- Comments are safely stored, but a clean EPUB cannot display
                    -- them until the immutable source-coordinate cache is available.
                    status="partial"
                end
            end
        end
    else
        status=tostring(merged.error_kind or "")
        if status=="rate_limit" then status="rate_limited"
        elseif status=="authentication" then status="auth_required"
        else status="partial" end
    end

    local groups,comments=current_counts(self.store,book_id,uid)
    local state_patch={
        status=status,account_key=account_key,
        fetched_at=stable_commit and os.time() or nil,updated_at=os.time(),
        range_count=tonumber(merged.underline_count or 0) or 0,
        group_count=groups,comment_count=comments,pending_count=#(merged.pending_ranges or {}),
        last_error=tostring(source_error or table.concat(merged.errors or {},"; ")),
    }
    -- book_version/source_ready describe the last display-safe snapshot, not the
    -- latest failed attempt. This keeps known-good comments usable after a
    -- transient refresh failure, while a changed book version cannot reuse them.
    if stable_commit then
        state_patch.book_version=current_version
        state_patch.source_ready=source_ready==true
    elseif status=="suspicious_zero" and type(stable_state)=="table" then
        state_patch.book_version=tonumber(stable_state.book_version) or 0
        state_patch.source_ready=stable_state.source_ready==true
    end
    ThoughtDatabase.save_fetch_state(self.store,book_id,uid,state_patch)

    return {
        chapter_uid=uid,status=status,groups=groups,comments=comments,
        ranges=tonumber(merged.underline_count or 0) or 0,pending=#(merged.pending_ranges or {}),
        source_ready=source_ready==true,error=source_error,
    }
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
        local uid=chapter_uid(chapter)
        if uid~="" then
            local previous=ThoughtDatabase.fetch_state(self.store,book_id,uid)
            local version=tonumber(book.version or book.bookVersion) or 0
            local reusable=options.force_refresh~=true and type(previous)=="table"
                and (previous.status=="complete" or previous.status=="empty")
                and (tonumber(previous.book_version) or 0)==version
            if reusable then
                summary.skipped=summary.skipped+1
            else
                local value,err=self:_fetch_chapter(book,chapter,options)
                local status=value and value.status or "failed"
                if status=="complete" then summary.complete=summary.complete+1
                elseif status=="empty" then summary.empty=summary.empty+1
                elseif status=="suspicious_zero" then summary.suspicious=summary.suspicious+1
                elseif status=="partial" or status=="rate_limited" or status=="auth_required" then summary.partial=summary.partial+1
                else summary.failed=summary.failed+1 end
                if value then summary.comments=summary.comments+(tonumber(value.comments) or 0) end
                if not value and options.stop_on_error==true then error(tostring(err or "comment_fetch_failed")) end
            end
        end
        summary.processed=index
        ThoughtDatabase.save_job_state(self.store,book_id,{
            status="active",mode=options.force_refresh==true and "refresh" or "missing",
            total=total,processed=index,updated_at=os.time(),started_at=tonumber(options.started_at) or os.time(),
            title=tostring(book.title or ""),
        })
    end
    summary.status=(summary.failed>0 or summary.partial>0 or summary.suspicious>0) and "partial" or "completed"
    ThoughtDatabase.save_job_state(self.store,book_id,{
        status=summary.status,total=total,processed=total,updated_at=os.time(),completed_at=os.time(),
        title=tostring(book.title or ""),complete=summary.complete,empty=summary.empty,partial=summary.partial,
        failed=summary.failed,suspicious=summary.suspicious,
    })
    return summary
end

function Service:runtime_marks(book,chapter)
    book=type(book)=="table" and book or {}
    chapter=type(chapter)=="table" and chapter or {}
    local book_id=tostring(book.bookId or book.book_id or "")
    local uid=chapter_uid(chapter)
    if book_id=="" or uid=="" then return nil,"scope_missing" end
    local state=ThoughtDatabase.fetch_state(self.store,book_id,uid)
    if type(state)~="table" then return nil,"independent_comments_not_downloaded" end
    local current_version=tonumber(book.version or book.bookVersion) or 0
    if (tonumber(state.book_version) or 0)~=current_version then return nil,"comment_book_version_stale" end
    if state.source_ready~=true then return nil,"comment_source_not_ready" end
    local usable_status={complete=true,fetching=true,partial=true,failed=true,rate_limited=true,auth_required=true,suspicious_zero=true}
    if usable_status[tostring(state.status or "")]~=true or (tonumber(state.comment_count) or 0)<=0 then
        return nil,"comment_snapshot_not_ready"
    end
    local groups,load_error=Thoughts.load(self.store,book_id,uid)
    if type(groups)~="table" then return nil,tostring(load_error or "comments_missing") end
    local source,_,source_error=SourcePosition.chapterSource(self.reader,book_id,uid,book.version or book.bookVersion or 0,{
        cache_only=true,
        chapter_index=tonumber(chapter.index or chapter.chapterIdx or chapter.chapter_index) or 0,
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
