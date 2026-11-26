-- B2: on-demand public comment retrieval. This module has no EPUB write path.
-- A single book's chapter reviews, checkpoint and status all live in thoughts.sqlite3.
local Annotations = require("miuread.annotations")
local ThoughtDatabase = require("miuread.thought_database")
local Thoughts = require("miuread.thoughts")
local Json = require("miuread.json")
local U = require("miuread.util")
local Range = require("miuread.annotations.range")

local CommentSync = {}
CommentSync.__index = CommentSync

function CommentSync:new(api, store, annotations)
    return setmetatable({api=api, store=store, annotations=annotations or Annotations:new(api), running=false}, self)
end

local function marks_path(store,book_id,uid)
    return store:book_cache_path(book_id).."/comment-marks-"..U.id_name(uid)..".json"
end

function CommentSync:load_marks(book_id,uid)
    local body=U.read_file(marks_path(self.store,book_id,uid),true)
    if not body then return nil end
    local ok,data=pcall(Json.decode,body)
    if ok and type(data)=="table" and data.book_id==tostring(book_id)
        and data.chapter_uid==tostring(uid) and type(data.underlines)=="table" then
        return data
    end
end

function CommentSync:fetch_marks(book_id,uid,source_context)
    local cached=source_context and self:load_marks(book_id,uid)
    if cached and os.time()-(tonumber(cached.updated_at) or 0)<1800 then
        self:_prepare_native_source(book_id,uid,source_context,cached)
        return cached
    end
    local ok,value=pcall(self.api.underlines,self.api,book_id,uid)
    if not ok then return nil,tostring(value) end
    if type(value)~="table" or (value.bookId~=nil and tostring(value.bookId)~=tostring(book_id))
        or (value.chapterUid~=nil and tostring(value.chapterUid)~=tostring(uid))
        or type(value.underlines)~="table" or Json.is_null(value.underlines) then
        return nil,"评论位置响应与当前章节不匹配"
    end
    local rows,seen={},{}
    for _,entry in ipairs(value.underlines) do
        local range=type(entry)=="table" and entry.range
        if type(range)=="string" and not seen[range] then
            local first,last,point=Range.parse(range)
            if first and last and last>first and not point then
                local quote=type(entry.markText)=="string" and entry.markText or
                    (type(entry.bookmarkText)=="string" and entry.bookmarkText or "")
                rows[#rows+1]={range=range,markText=quote}
                seen[range]=true
            end
        end
    end
    if #value.underlines>0 and #rows==0 then return nil,"评论位置响应无法解析" end
    self.store:book_dir(book_id)
    local data={book_id=tostring(book_id),chapter_uid=tostring(uid),underlines=rows,updated_at=os.time()}
    local saved,err=U.atomic_write(marks_path(self.store,book_id,uid),Json.encode(data),true)
    if not saved then return nil,err or "评论位置保存失败" end
    self:_prepare_native_source(book_id,uid,source_context,data)
    return data
end

function CommentSync:_prepare_native_source(book_id,uid,context,marks)
    if type(context)~="table" or type(context.file)~="string" or not context.reader then return end
    for _,row in ipairs(marks.underlines or {}) do
        if row.markText=="" then
            local Native=require("miuread.eink_comment_source")
            local ok,ready,reason=pcall(Native.ensure,context.reader,self.store,book_id,uid,context.file)
            if not (ok and ready) then
                require("logger").warn("[MiuRead][Comments] native coordinate source unavailable",
                    U.first_line(tostring(ok and reason or ready),100))
            end
            return
        end
    end
end

local function account_id(store)
    local auth=type(store.auth)=="function" and store:auth() or {}
    return tostring((auth.account or {}).vid or (auth.cookies or {}).wr_vid or "")
end

function CommentSync:range_has_more(book_id,uid,range)
    local first,last,point=Range.parse(range)
    return first~=nil and last>first and not point
        and ThoughtDatabase.range_cursor(self.store,book_id,uid,range,account_id(self.store))~=0
end

function CommentSync:fetch_range(book_id,uid,range,more)
    local viewer=account_id(self.store)
    if viewer=="" then return nil,"请先登录微信读书" end
    local expected=ThoughtDatabase.range_cursor(self.store,book_id,uid,range,viewer)
    if expected==0 or (more~=true and expected~=nil) then
        return {range=range,texts={},known_end=expected==0}
    end
    local result,err,kind=self.annotations:fetch_range(book_id,uid,range,viewer,expected)
    if not result then return nil,err,kind end
    local saved,save_error=ThoughtDatabase.save_range_page(self.store,book_id,uid,range,viewer,expected,result)
    if saved==nil then return nil,save_error end
    return {range=range,texts=result.texts,known_end=result.cursor==0,superseded=saved==false}
end

function CommentSync:status(book_id, chapter_uid)
    local state=ThoughtDatabase.sync_state(self.store, book_id, chapter_uid)
    local readable,rows=pcall(Thoughts.load,self.store,book_id,chapter_uid)
    if not readable then return {status="error",comments=0,groups=0,has_cache=false,
        last_error="评论数据库读取失败："..tostring(rows)} end
    if type(rows)~="table" then return {status=state and state.status or "not_fetched",
        comments=0, groups=0, has_cache=false, last_error=state and state.last_error or ""} end
    local count=0
    for _,group in ipairs(rows) do count=count+#(group.texts or {}) end
    local has_cache=not (state and state.status=="error" and
        (tonumber(state.last_success_at or 0) or 0)==0 and count==0)
    return {status=state and state.status or "legacy", comments=count, groups=#rows,
        has_cache=has_cache, last_success_at=state and state.last_success_at or 0,
        last_attempt_at=state and state.last_attempt_at or 0,
        last_error=state and state.last_error or ""}
end

function CommentSync:load(book_id, chapter_uid)
    local ok,rows,err=pcall(Thoughts.load,self.store,book_id,chapter_uid)
    if not ok then return nil,tostring(rows) end
    return rows,err
end

-- force=true starts a fresh range request, but never replaces saved reviews.
-- force=false resumes an incomplete range checkpoint, if present.
function CommentSync:fetch(book_id, chapter_uid, options)
    options=type(options)=="table" and options or {}
    book_id=tostring(book_id or "")
    chapter_uid=tostring(chapter_uid or "")
    if book_id=="" or chapter_uid=="" then return nil,"无法确定当前书籍或章节" end
    if self.running then return nil,"已有评论获取任务正在进行" end
    local old_state=self:status(book_id,chapter_uid)
    local job_id=options.job_id
    local snapshot
    if options.force~=true or job_id then
        snapshot=ThoughtDatabase.load_checkpoint(self.store,book_id,chapter_uid)
        if type(snapshot)~="table" or snapshot.book_id~=book_id or snapshot.chapter_uid~=chapter_uid then
            snapshot=nil
        end
    end
    local same_job=snapshot and job_id~=nil and snapshot.job_id==job_id
    local force_refresh=options.force==true and not same_job
    if old_state.has_cache and not force_refresh and old_state.status~="partial" and old_state.status~="error"
        and (old_state.status~="empty" or same_job) then
        return {cached=true, status=old_state.status, comments=old_state.comments,
            groups=old_state.groups, complete=true}
    end
    local previous
    if snapshot and not force_refresh then
        previous=self.annotations:from_cache(snapshot)
        local rows=Thoughts.load(self.store,book_id,chapter_uid)
        if type(rows)=="table" then
            previous.review_groups=rows
            previous.review_map={}
            for _,group in ipairs(rows) do previous.review_map[group.range]=group.texts end
        end
    end
    -- A failed refresh may retain an older *complete* checkpoint. A new
    -- explicit retry must contact the server, not silently reuse that old
    -- completion bit as proof the failed refresh was already done.
    local retry_full=(old_state.status=="error" or old_state.status=="empty")
        and previous and previous.complete==true
    self.running=true
    local function persist(snapshot)
        if snapshot.underline_request_ok~=true then
            -- No confirmed remote content: preserve the checkpoint and all
            -- previously cached comments; record the failed attempt only.
            local reason=table.concat(snapshot.errors or {},"; ")
            local saved,err=ThoughtDatabase.record_error(self.store,book_id,chapter_uid,reason)
            if not saved then error("无法保存评论错误状态："..tostring(err)) end
            return self.annotations:merge(previous,snapshot)
        end
        local joined=self.annotations:merge(previous,snapshot)
        local checkpoint=self.annotations:to_cache(joined)
        checkpoint.job_id=job_id
        -- Review bodies already exist in the groups table. Only store the
        -- underlines and remaining range IDs in the resumable checkpoint.
        checkpoint.review_groups={}
        local saved,err=ThoughtDatabase.record_fetch(self.store,book_id,chapter_uid,
            joined.review_groups,checkpoint,{
                partial=joined.complete~=true,
                succeeded=snapshot.underline_request_ok==true,
                empty=joined.complete==true and (joined.thought_entry_count or 0)==0,
                error=table.concat(joined.errors or {},"; "),
            })
        if not saved then error("评论保存失败："..tostring(err)) end
        Thoughts.clear_memory_cache()
        previous=joined
        return joined
    end
    local ok,result=xpcall(function()
        local fetched=self.annotations:fetch_chapter(book_id,chapter_uid,
            options.progress or function() end,{
                previous=previous,force_refresh=force_refresh or retry_full,
                checkpoint=persist,
                -- Comment fetches are explicit reader actions (or user-enabled
                -- preloads); use E-Ink best bookmarks when there are no ranges.
                probe_empty_underlines=true,
            })
        return persist(fetched)
    end,debug.traceback)
    self.running=false
    if not ok then
        ThoughtDatabase.record_error(self.store,book_id,chapter_uid,tostring(result))
        return nil,tostring(result)
    end
    local fresh=self:status(book_id,chapter_uid)
    if fresh.status=="error" then
        return nil, fresh.last_error~="" and fresh.last_error or "本章评论获取失败"
    end
    return {status=fresh.status,comments=fresh.comments,groups=fresh.groups,
        partial=fresh.status=="partial", cached=false,
        error=table.concat(result.errors or {},"; "),
        -- WeRead's currently verified request obtains at most the first 30
        -- reviews of each range; 'complete' describes range-batch transport
        -- only, not exhaustive server history.
        coverage="first_page_per_range",complete=result.complete==true}
end

return CommentSync
