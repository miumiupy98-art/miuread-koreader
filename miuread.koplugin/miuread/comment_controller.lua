local Async=require("miuread.async")
local CommentDB=require("miuread.comment_download_database")
local CommentService=require("miuread.comment_download_service")
local ThoughtRuntime=require("miuread.thought_runtime")
local Thoughts=require("miuread.thoughts")
local HomeView=require("miuread.home_view")
local U=require("miuread.util")
local UIManager=require("ui/uimanager")
local ButtonDialog=require("ui/widget/buttondialog")
local ConfirmBox=require("ui/widget/confirmbox")
local logger=require("logger")

local Controller={}
Controller.__index=Controller

local function uid_of(chapter)
    return tostring(type(chapter)=="table" and (chapter.uid or chapter.chapterUid or chapter.chapter_uid) or "")
end
local function is_file(path)
    return tostring(path or "")~="" and U.file_exists(path)
end

function Controller:new(host)
    local obj=setmetatable({
        host=host,
        store=host.store,
        service=CommentService:new(host.annotations,host.reader,host.store),
        runtime=ThoughtRuntime:new(host),
        async=Async:new(host.store,{poll_interval=.35,allow_android=true,disable_fallback=true}),
        job=nil,job_generation=0,job_poll_task=nil,
        runtime_task=nil,runtime_generation=0,runtime_scope_key=nil,
    },self)
    local shared=rawget(_G,"__MIUREAD_COMMENT_DOWNLOAD_SHARED_V3")
    if type(shared)~="table" then
        shared={owner=nil,job=nil}
        rawset(_G,"__MIUREAD_COMMENT_DOWNLOAD_SHARED_V3",shared)
    end
    obj.shared=shared
    UIManager:scheduleIn(2.8,function()
        if obj.host and obj.host.store then obj:start_next() end
    end)
    return obj
end

function Controller:is_clean_record(record,variant)
    if type(record)~="table" then return false end
    local kind=tostring(variant or record.variant or record.base_variant or record.download_variant or "")
    if record.annotation_requested==true or kind:find("notes",1,true) then return false end
    return true
end

function Controller:local_chapters(book_id,preferred_record)
    book_id=tostring(book_id or "")
    local stored=self.store:book(book_id) or {}
    local out,seen={},{}
    local function add(ch,index)
        if type(ch)~="table" then return end
        local uid=uid_of(ch)
        if uid=="" or seen[uid] then return end
        seen[uid]=true
        out[#out+1]={
            uid=uid,chapterUid=uid,title=tostring(ch.title or ch.name or ""),
            index=tonumber(ch.index or ch.chapterIdx or ch.chapter_index) or tonumber(index) or 0,
            word_count=tonumber(ch.word_count or ch.wordCount) or 0,
        }
    end
    local function add_record(record,kind)
        if not self:is_clean_record(record,kind) or not is_file(record.file) then return end
        if type(record.chapter_map)=="table" and #record.chapter_map>0 then
            for index,ch in ipairs(record.chapter_map) do add(ch,index) end
        elseif tostring(record.chapter_uid or record.chapterUid or "")~="" then
            add({uid=record.chapter_uid or record.chapterUid,title=record.title,index=record.chapter_index or record.chapterIdx},record.chapter_index)
        end
    end
    if type(preferred_record)=="table" and self:is_clean_record(preferred_record) then
        add_record(preferred_record,preferred_record.variant)
    else
        for kind,record in pairs(stored.variants or {}) do
            if tostring(kind):find("clean",1,true) then add_record(record,kind) end
        end
        for uid,row in pairs(stored.chapters or {}) do
            for kind,record in pairs(row or {}) do
                if tostring(kind):find("clean",1,true) and type(record)=="table" then
                    local copy=U.copy(record)
                    if not copy.chapter_uid and not copy.chapterUid then copy.chapter_uid=uid end
                    add_record(copy,kind)
                end
            end
        end
    end
    local order={}
    for index,ch in ipairs(stored.catalog or {}) do order[uid_of(ch)]=index end
    table.sort(out,function(a,b)
        local ai=order[a.uid] or (tonumber(a.index) or 999999)
        local bi=order[b.uid] or (tonumber(b.index) or 999999)
        if ai~=bi then return ai<bi end
        return tostring(a.uid)<tostring(b.uid)
    end)
    return out
end

function Controller:book_context(book_id,preferred_record)
    book_id=tostring(book_id or "")
    local stored=self.store:book(book_id) or {}
    local current=self.host:_current_book_record()
    local current_matches=current and current.book
        and tostring(current.book.book_id or current.book.bookId or "")==book_id
    local source=current_matches and current.book or stored
    local version=tonumber(source.version or source.bookVersion
        or (type(preferred_record)=="table" and (preferred_record.book_version or preferred_record.bookVersion))
        or stored.version or stored.bookVersion) or 0
    local book={
        bookId=book_id,book_id=book_id,title=tostring(source.title or stored.title or ""),
        author=tostring(source.author or stored.author or ""),cover=source.cover or stored.cover,
        version=version,bookVersion=version,
    }
    return book,self:local_chapters(book_id,preferred_record)
end

function Controller:status(book_id,chapters,book_version)
    chapters=type(chapters)=="table" and chapters or {}
    local states=CommentDB.states(self.store,book_id,chapters)
    local expected=tonumber(book_version) or 0
    local out={total=#chapters,ready=0,complete=0,empty=0,partial=0,failed=0,suspicious=0,stale=0,never=0,comments=0}
    for _,chapter in ipairs(chapters) do
        local row=states[uid_of(chapter)]
        if type(row)~="table" then out.never=out.never+1 else
            local status=tostring(row.status or "never")
            local row_version=tonumber(row.book_version) or 0
            out.comments=out.comments+(tonumber(row.comment_count) or 0)
            if expected>0 and row_version~=expected and (status=="complete" or status=="empty") then
                out.stale=out.stale+1
            elseif status=="complete" then out.complete=out.complete+1; out.ready=out.ready+1
            elseif status=="empty" then out.empty=out.empty+1; out.ready=out.ready+1
            elseif status=="suspicious_zero" then out.suspicious=out.suspicious+1
            elseif status=="failed" then out.failed=out.failed+1
            elseif status=="partial" or status=="rate_limited" or status=="auth_required" or status=="fetching" then out.partial=out.partial+1
            else out.never=out.never+1 end
        end
    end
    return out
end

function Controller:status_label(book_id,chapters,book_version)
    local state=self:status(book_id,chapters,book_version)
    if state.total==0 then return "尚无可绑定的纯净版章节" end
    local text=tostring(state.ready).."/"..tostring(state.total).."章"
    if state.comments>0 then text=text.." · "..tostring(state.comments).."条" end
    if state.stale>0 then text=text.." · "..tostring(state.stale).."章需更新"
    elseif state.suspicious>0 then text=text.." · "..tostring(state.suspicious).."章待确认"
    elseif state.partial>0 then text=text.." · "..tostring(state.partial).."章待继续"
    elseif state.failed>0 then text=text.." · "..tostring(state.failed).."章失败"
    elseif state.never>0 then text=text.." · "..tostring(state.never).."章未下载" end
    return text
end

function Controller:current_job()
    if type(self.shared)=="table" and type(self.shared.job)=="table" then return self.shared.job end
    return self.job
end
function Controller:queue()
    return CommentDB.queue(self.store)
end
function Controller:_save_queue(queue)
    return CommentDB.save_queue(self.store,queue)
end

function Controller:queue_download(book,chapters,options)
    options=type(options)=="table" and options or {}
    chapters=type(chapters)=="table" and chapters or {}
    if #chapters==0 then self.host:toast("没有可绑定的纯净版章节",3); return false end
    local book_id=tostring(book and (book.bookId or book.book_id) or "")
    if book_id=="" then return false end
    local mode=options.force_refresh==true and "refresh" or "missing"
    local fp={}
    for _,ch in ipairs(chapters) do fp[#fp+1]=uid_of(ch) end
    local key=book_id.."|"..mode.."|"..table.concat(fp,",")
    local current=self:current_job()
    if current and type(current.request)=="table" and tostring(current.request.key or "")==key then
        self.host:toast("这项评论下载正在进行中",2); return true
    end
    local queue=self:queue()
    for _,row in ipairs(queue) do
        if tostring(row.key or "")==key then self.host:toast("评论下载已经在等待队列中",2); return true end
    end
    queue[#queue+1]={
        key=key,book=U.copy(book),chapters=U.copy(chapters),mode=mode,
        force_refresh=options.force_refresh==true,queued_at=os.time(),
    }
    self:_save_queue(queue)
    self.host:status_toast("评论下载",tostring(book.title or "本书").."已加入评论下载队列",3)
    self:start_next()
    return true
end

function Controller:_stop_poll()
    if self.job_poll_task then UIManager:unschedule(self.job_poll_task); self.job_poll_task=nil end
end

function Controller:_home_update(book_id,job)
    book_id=tostring(book_id or "")
    if book_id=="" then return false end
    job=type(job)=="table" and job or {}
    local total=math.max(0,tonumber(job.total) or 0)
    local processed=math.max(0,tonumber(job.processed) or 0)
    local ratio=total>0 and math.max(0,math.min(1,processed/total)) or 0
    local changed=self.host:_home_mutate_book_rows(book_id,function(book)
        book.comment_active=tostring(job.status or "")=="active"
        book.comment_progress=book.comment_active and ratio or nil
        if book.comment_active then book.comment_status="评论 "..tostring(math.floor(ratio*100+.5)).."%"
        elseif tostring(job.status or "")=="partial" then book.comment_status="评论待继续"
        elseif tostring(job.status or "")=="completed" then book.comment_status="评论已缓存"
        else book.comment_status=nil end
        book.status_text=self.host:_shelf_status_text(book)
    end)
    if changed and HomeView.is_shown() and not self.host:_active_reader_ui() then HomeView.update_book(book_id) end
    return changed
end

function Controller:decorate_home_rows(rows)
    local current=self:current_job()
    if not current then return rows end
    local job=CommentDB.job(self.store,current.book_id) or {status="active",total=current.total,processed=0}
    local total=math.max(0,tonumber(job.total) or tonumber(current.total) or 0)
    local processed=math.max(0,tonumber(job.processed) or 0)
    local ratio=total>0 and math.max(0,math.min(1,processed/total)) or 0
    for _,book in ipairs(type(rows)=="table" and rows or {}) do
        if tostring(book.bookId or book.book_id or "")==tostring(current.book_id or "") then
            book.comment_active=tostring(job.status or "")=="active"
            book.comment_progress=book.comment_active and ratio or nil
            book.comment_status=book.comment_active and ("评论 "..tostring(math.floor(ratio*100+.5)).."%") or nil
        end
    end
    return rows
end

function Controller:_schedule_poll()
    self:_stop_poll()
    if not self.job then return end
    local generation=self.job_generation
    local task
    task=function()
        if self.job_poll_task~=task or generation~=self.job_generation or not self.job then return end
        local job=CommentDB.job(self.store,self.job.book_id) or {status="active",total=self.job.total,processed=0}
        self:_home_update(self.job.book_id,job)
        UIManager:scheduleIn(1.0,task)
    end
    self.job_poll_task=task
    UIManager:scheduleIn(.7,task)
end

function Controller:start_next()
    if type(self.shared)=="table" and self.shared.owner and self.shared.owner~=self and type(self.shared.job)=="table" then return false end
    if self.job or (self.async and self.async:busy()) then return false end
    if self.host.download_task and self.host.download_task:busy() then return false end
    if #(self.host.store:download_queue() or {})>0 then return false end
    local queue=self:queue()
    local request=table.remove(queue,1)
    if type(request)~="table" then return false end
    self:_save_queue(queue)
    local book=type(request.book)=="table" and request.book or {}
    local chapters=type(request.chapters)=="table" and request.chapters or {}
    local book_id=tostring(book.bookId or book.book_id or "")
    if book_id=="" or #chapters==0 then return self:start_next() end
    if not self.host:logged_in() then
        queue=self:queue(); table.insert(queue,1,request); self:_save_queue(queue)
        self.host:status_toast("评论下载","登录后可继续下载评论",4)
        return false
    end
    self.job_generation=self.job_generation+1
    local generation=self.job_generation
    self.job={book_id=book_id,title=tostring(book.title or ""),total=#chapters,request=request}
    self.shared.owner=self; self.shared.job=self.job
    CommentDB.save_job(self.store,book_id,{
        status="active",title=tostring(book.title or ""),mode=request.mode,total=#chapters,processed=0,
        complete=0,empty=0,partial=0,failed=0,suspicious=0,started_at=os.time(),completed_at=0,last_error="",
    })
    self:_home_update(book_id,CommentDB.job(self.store,book_id))
    self:_schedule_poll()
    local service=self.service
    local started,err=self.async:run("comment-download:"..book_id,function()
        return service:download(book,chapters,{force_refresh=request.force_refresh==true,started_at=os.time()})
    end,function(result)
        if generation~=self.job_generation then return end
        self.job=nil
        if self.shared.owner==self then self.shared.owner=nil; self.shared.job=nil end
        self:_stop_poll()
        if not result or result.ok~=true then
            CommentDB.save_job(self.store,book_id,{status="partial",title=tostring(book.title or ""),total=#chapters,completed_at=os.time(),last_error=tostring(result and result.error or "unknown")})
            self:_home_update(book_id,CommentDB.job(self.store,book_id))
            logger.warn("[MiuRead][CommentDownload] stopped","book=",book_id,"error=",tostring(result and result.error or "unknown"))
            self.host:status_toast("评论下载",tostring(book.title or "本书").."评论未完成，断点已保留",4)
        else
            local value=type(result.value)=="table" and result.value or {}
            self:_home_update(book_id,CommentDB.job(self.store,book_id))
            Thoughts.clear_memory_cache()
            self.runtime_scope_key=nil
            self:schedule_runtime_refresh(.15,"comment download completed")
            if tostring(value.status or "")=="completed" then
                self.host:status_toast("评论下载",tostring(book.title or "本书").."评论下载完成",4)
            else
                self.host:status_toast("评论下载",tostring(book.title or "本书").."评论已保存，部分章节待继续",4)
            end
        end
        self:start_next()
    end,math.max(600,math.min(7200,#chapters*45)))
    if not started then
        self.job=nil
        if self.shared.owner==self then self.shared.owner=nil; self.shared.job=nil end
        self:_stop_poll()
        queue=self:queue(); table.insert(queue,1,request); self:_save_queue(queue)
        CommentDB.save_job(self.store,book_id,{status="partial",updated_at=os.time(),last_error=tostring(err or "worker_unavailable")})
        self.host:status_toast("评论下载","评论任务暂时无法启动",4)
        return false
    end
    logger.info("[MiuRead][CommentDownload] started","book=",book_id,"chapters=",tostring(#chapters),"mode=",tostring(request.mode))
    return true
end

function Controller:cancel(reason,requeue)
    if not self.job and self.shared.owner and self.shared.owner~=self and type(self.shared.owner.cancel)=="function" then
        return self.shared.owner:cancel(reason,requeue)
    end
    local job=self.job
    if not job then return false end
    self.job_generation=self.job_generation+1
    if self.async and self.async:busy() then self.async:cancel(reason or "comment download cancelled") end
    self:_stop_poll(); self.job=nil
    if self.shared.owner==self then self.shared.owner=nil; self.shared.job=nil end
    if requeue~=false and type(job.request)=="table" then
        local queue=self:queue(); table.insert(queue,1,job.request); self:_save_queue(queue)
    end
    CommentDB.save_job(self.store,job.book_id,{status="partial",completed_at=os.time(),last_error=tostring(reason or "paused")})
    self:_home_update(job.book_id,CommentDB.job(self.store,job.book_id))
    return true
end

function Controller:forget_book(book_id)
    book_id=tostring(book_id or "")
    if book_id=="" then return false end
    local current=self:current_job()
    if current and tostring(current.book_id or "")==book_id then
        self:cancel("book deleted",false)
    end
    local kept={}
    for _,row in ipairs(self:queue()) do
        local row_id=tostring(row.book and (row.book.bookId or row.book.book_id) or "")
        if row_id~=book_id then kept[#kept+1]=row end
    end
    self:_save_queue(kept)
    CommentDB.reset_book(self.store,book_id,{})
    local scope=self:runtime_scope()
    if scope and tostring(scope.book_id or "")==book_id then self:clear_runtime("book deleted") end
    return true
end

function Controller:yield_to_content_download()
    if self:current_job() then
        logger.info("[MiuRead][CommentDownload] yielding to content download")
        return self:cancel("content download priority",true)
    end
    return false
end

function Controller:runtime_scope()
    if not self.host:_reader_session_is_weread() then return nil end
    local current=self.host:_current_book_record()
    if not (current and current.book and current.record) then return nil end
    if not self:is_clean_record(current.record,current.variant) then return nil end
    local scope=self.host:_current_thought_favorite_scope()
    local book_id=tostring(scope.book_id or current.book.book_id or current.book.bookId or "")
    local chapter_uid=tostring(scope.chapter_uid or current.record.chapter_uid or "")
    if book_id=="" or chapter_uid=="" then return nil end
    local book,chapters=self:book_context(book_id,current.record)
    for _,chapter in ipairs(chapters) do
        if uid_of(chapter)==chapter_uid then return {book_id=book_id,chapter_uid=chapter_uid,book=book,chapter=chapter,record=current.record} end
    end
    return nil
end

function Controller:clear_runtime(reason)
    self.runtime_generation=self.runtime_generation+1
    if self.runtime_task then UIManager:unschedule(self.runtime_task); self.runtime_task=nil end
    self.runtime_scope_key=nil
    if self.runtime then self.runtime:clear(false) end
    if reason then logger.dbg("[MiuRead][ThoughtRuntime] cancelled",tostring(reason)) end
end

function Controller:schedule_runtime_refresh(delay,reason)
    self.runtime_generation=self.runtime_generation+1
    local generation=self.runtime_generation
    if self.runtime_task then UIManager:unschedule(self.runtime_task) end
    local task
    task=function()
        if self.runtime_task~=task or generation~=self.runtime_generation then return end
        self.runtime_task=nil
        if self.host:_thoughts_enabled()~=true then self:clear_runtime("display off"); return end
        local scope=self:runtime_scope()
        if not scope then self:clear_runtime("not clean runtime scope"); return end
        local key=scope.book_id.."|"..scope.chapter_uid
        if self.runtime_scope_key==key and self.runtime and self.runtime:is_scope(scope.book_id,scope.chapter_uid) then return end
        local marks,err=self.service:runtime_marks(scope.book,scope.chapter)
        if type(marks)~="table" or #marks==0 then
            self.runtime_scope_key=key
            if self.runtime then self.runtime:clear(false) end
            logger.dbg("[MiuRead][ThoughtRuntime] no local comments","book=",scope.book_id,"chapter=",scope.chapter_uid,"reason=",tostring(err or "empty"))
            return
        end
        local mapped,map_err=self.runtime:map_current(scope.book_id,scope.chapter_uid,marks,{max_marks=300})
        self.runtime_scope_key=key
        if not mapped then logger.warn("[MiuRead][ThoughtRuntime] map failed",tostring(map_err or "unknown")) end
    end
    self.runtime_task=task
    UIManager:scheduleIn(math.max(.02,tonumber(delay) or .25),task)
end

function Controller:on_display_switch(enabled)
    if enabled~=true then
        self:clear_runtime("comments disabled")
        local ui=self.host and self.host.ui or nil
        if ui then UIManager:setDirty(ui.dialog or ui,"ui") end
        return true
    end
    local scope=self:runtime_scope()
    if scope then self.host:_setup_thought_tap(); self:schedule_runtime_refresh(.08,"comments enabled") end
    return true
end

function Controller:on_sync_record_ready(current)
    if not (current and current.book and current.record) then self:clear_runtime("no sync record"); return false end
    if self:is_clean_record(current.record,current.variant) and self.host:_thoughts_enabled() then
        self.host:_setup_thought_tap()
        self.runtime_scope_key=nil
        self:schedule_runtime_refresh(.28,"sync record ready")
        return true
    end
    self:clear_runtime("non-clean record")
    return false
end
function Controller:on_page_update()
    if self.host:_thoughts_enabled() and self:runtime_scope() then self:schedule_runtime_refresh(.45,"page update") end
end
function Controller:on_suspend()
    self:clear_runtime("suspend")
    if self:current_job() then self:cancel("suspend",true) end
end
function Controller:on_resume()
    UIManager:scheduleIn(1.2,function()
        if self.host and self.host.ui and self.host.ui.document and self.host:_thoughts_enabled() then self:schedule_runtime_refresh(.25,"resume") end
    end)
    UIManager:scheduleIn(2.3,function() self:start_next() end)
end

function Controller:native_hit_test(pos)
    return self.runtime and self.runtime:native_hit_test(pos) or false
end
function Controller:hit_test(pos)
    return self.runtime and self.runtime:hit_test(pos) or nil
end

function Controller:queue_current_chapter()
    local scope=self:runtime_scope()
    if not scope then self.host:toast("当前章节没有可绑定的纯净版正文",3); return false end
    return self:queue_download(scope.book,{scope.chapter},{force_refresh=true})
end
function Controller:queue_book_missing(book_id,preferred_record)
    local book,chapters=self:book_context(book_id,preferred_record)
    return self:queue_download(book,chapters,{force_refresh=false})
end
function Controller:queue_book_refresh(book_id,preferred_record)
    local book,chapters=self:book_context(book_id,preferred_record)
    return self:queue_download(book,chapters,{force_refresh=true})
end
function Controller:queue_after_download(book,record,options)
    if type(options)~="table" or options.download_comments_after~=true then return false end
    if not self:is_clean_record(record,record and record.variant) then return false end
    local context,chapters=self:book_context(book.bookId or book.book_id,record)
    if #chapters==0 then
        logger.warn("[MiuRead][CommentDownload] no local chapters after clean download","book=",tostring(book.bookId or book.book_id or ""))
        return false
    end
    return self:queue_download(context,chapters,{force_refresh=false})
end

function Controller:reader_data_rows()
    local current=self.host:_current_book_record()
    if not (current and current.book) then return {{icon="info",label="评论状态",value="当前书籍不可识别",enabled=false}} end
    local book_id=tostring(current.book.book_id or current.book.bookId or "")
    local book,chapters=self:book_context(book_id,nil)
    local status=self:status_label(book_id,chapters,book.version)
    local scope=self:runtime_scope()
    local rows={{icon="info",label="评论状态",value=status,enabled=false}}
    rows[#rows+1]={icon="comment",label="下载/更新当前章评论",value=scope and "当前章" or "当前章无纯净版正文",enabled=scope~=nil,callback=function()
        self:queue_current_chapter()
    end}
    rows[#rows+1]={icon="download",label="补全本书评论",value=#chapters>0 and "只处理缺失或未完成章节" or "暂无纯净版",enabled=#chapters>0,callback=function()
        self:queue_download(book,chapters,{force_refresh=false})
    end}
    rows[#rows+1]={icon="download",label="更新本书全部评论",value=#chapters>0 and "重新检查本地全部章节" or "暂无纯净版",enabled=#chapters>0,callback=function()
        self:queue_download(book,chapters,{force_refresh=true})
    end}
    return rows
end

function Controller:menu_rows(book,preferred_record)
    book=type(book)=="table" and book or {}
    local book_id=tostring(book.bookId or book.book_id or "")
    local context,chapters=self:book_context(book_id,preferred_record)
    local rows={{text="阅读评论",post_text=self.host:_thoughts_enabled_label(),checked_func=function() return self.host:_thoughts_enabled() end,
        callback=function() self.host:_toggle_thoughts_enabled() end},
        {text="评论状态",post_text=self:status_label(book_id,chapters,context.version),enabled=false}}
    if #chapters>0 then
        rows[#rows+1]={text="补全本书评论",post_text="只处理缺失或未完成章节",callback=function() self:queue_download(context,chapters,{force_refresh=false}) end}
        rows[#rows+1]={text="更新本书全部评论",post_text="重新检查本地全部章节",callback=function() self:queue_download(context,chapters,{force_refresh=true}) end}
        rows[#rows+1]={text="重置独立评论下载状态",post_text="保留已保存评论正文",callback=function()
            UIManager:show(ConfirmBox:new{text="重置《"..tostring(context.title or "本书").."》的独立评论下载状态？\n\n已保存评论正文不会删除。",ok_callback=function()
                CommentDB.reset_book(self.store,book_id,chapters)
                self.host:status_toast("评论数据","独立评论下载状态已重置",3)
            end})
        end}
    else
        rows[#rows+1]={text="独立评论需要纯净版正文",post_text="请先生成纯净版或纯净版 + 评论",enabled=false}
    end
    return rows
end

function Controller:show_book_menu(book,preferred_record)
    local title=tostring(book and book.title or "评论数据")
    self.host:list("评论数据 · "..title,self:menu_rows(book,preferred_record))
end

function Controller:download_menu_rows()
    local rows={}
    local job=self:current_job()
    if job then
        local state=CommentDB.job(self.store,job.book_id) or {status="active",total=job.total,processed=0}
        local total=math.max(0,tonumber(state.total) or tonumber(job.total) or 0)
        local processed=math.max(0,tonumber(state.processed) or 0)
        local percent=total>0 and math.floor(processed/total*100+.5) or 0
        rows[#rows+1]={text="评论下载：《"..U.utf8_truncate(job.title or "未命名",9).."》",post_text=tostring(percent).."%",callback=function() self:show_active_job() end}
    end
    local queue=self:queue()
    rows[#rows+1]={text="等待评论下载",post_text=tostring(#queue).." 项",callback=function() self:show_waiting() end}
    return rows
end

function Controller:show_active_job()
    local job=self:current_job()
    if not job then self.host:info("当前没有正在运行的评论下载。"); return end
    local state=CommentDB.job(self.store,job.book_id) or {}
    local total=math.max(0,tonumber(state.total) or tonumber(job.total) or 0)
    local processed=math.max(0,tonumber(state.processed) or 0)
    local dialog
    dialog=ButtonDialog:new{title="评论下载\n"..tostring(job.title or "未命名").."\n"..tostring(processed).." / "..tostring(total).." 章",title_align="center",buttons={
        {{text="暂停并保留断点",callback=function() UIManager:close(dialog); self:cancel("user paused",true); self.host:status_toast("评论下载","已暂停，断点和评论均已保留",3) end}},
        {{text="关闭",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end

function Controller:show_waiting()
    local queue=self:queue()
    if #queue==0 then self.host:info("当前没有等待中的评论下载。"); return end
    local items={}
    for index,row in ipairs(queue) do
        local i=index; local title=tostring(row.book and row.book.title or "未命名")
        items[#items+1]={text=title,post_text=tostring(#(row.chapters or {})).."章",callback=function()
            UIManager:show(ConfirmBox:new{text="从评论下载队列移除《"..title.."》？",ok_text="移除",cancel_text="保留",ok_callback=function()
                local current=self:queue(); table.remove(current,i); self:_save_queue(current); self.host:toast("已移出评论下载队列")
            end})
        end}
    end
    self.host:list("等待评论下载",items)
end

return Controller
