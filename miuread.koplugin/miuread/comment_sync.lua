-- B2: on-demand public comment retrieval. This module has no EPUB write path.
-- A single book's chapter reviews, checkpoint and status all live in thoughts.sqlite3.
local Annotations = require("miuread.annotations")
local ThoughtDatabase = require("miuread.thought_database")
local Thoughts = require("miuread.thoughts")

local CommentSync = {}
CommentSync.__index = CommentSync

function CommentSync:new(api, store, annotations)
    return setmetatable({api=api, store=store, annotations=annotations or Annotations:new(api), running=false}, self)
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
    if old_state.has_cache and old_state.status~="partial" and old_state.status~="error"
        and old_state.status~="empty" and options.force~=true then
        return {cached=true, status=old_state.status, comments=old_state.comments,
            groups=old_state.groups, complete=true}
    end
    local previous
    if options.force~=true then
        local snapshot=ThoughtDatabase.load_checkpoint(self.store,book_id,chapter_uid)
        if type(snapshot)=="table" and snapshot.book_id==book_id and snapshot.chapter_uid==chapter_uid then
            previous=self.annotations:from_cache(snapshot)
            local rows=Thoughts.load(self.store,book_id,chapter_uid)
            if type(rows)=="table" then
                previous.review_groups=rows
                previous.review_map={}
                for _,group in ipairs(rows) do previous.review_map[group.range]=group.texts end
            end
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
                previous=previous,force_refresh=options.force==true or retry_full,
                checkpoint=persist,
                -- Comment fetches are explicit reader actions (or user-enabled
                -- preloads); check the public feed when there are no ranges.
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
