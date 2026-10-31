-- 6.5.0-beta.4: non-blocking, per-chapter Web coordinate preparation.
-- A downloaded EPUB is already complete. Jobs only add trusted Web source
-- references to SourcePosition's existing sidecar cache; they never edit EPUBs.
local SourcePosition = require("miuread.source_position")
local M = {}

local function scalar(value)
    return (type(value)=="string" or type(value)=="number") and tostring(value) or ""
end

function M.queue(store, record, previous, login_session_id)
    record=type(record)=="table" and record or {}
    local id=scalar(record.book_id or record.bookId)
    local rows=type(record.chapter_map)=="table" and record.chapter_map or {}
    local version=tonumber(record.progress_source_book_version or record.book_version or record.version) or 0
    if id=="" or #rows==0 then return nil,"catalog_missing" end
    local jobs={}
    local seen={}
    local old=type(previous)=="table" and previous or {}
    local same_generation=tonumber(old.version)==version
        and scalar(old.core_map_hash)==scalar(record.core_map_hash)
        and scalar(old.login_session_id)==scalar(login_session_id)
    local old_by_uid={}
    if same_generation then
        for _,job in ipairs(old.jobs or {}) do
            if type(job)=="table" then old_by_uid[scalar(job.uid)]=job end
        end
    end
    for index,chapter in ipairs(rows) do
        local uid=scalar(chapter.uid or chapter.chapterUid)
        if uid~="" and not seen[uid] and chapter.structural~=true then
            seen[uid]=true
            if not SourcePosition.cachedChapterExists(store,id,uid,version) then
                local prior=old_by_uid[uid] or {}
                jobs[#jobs+1]={uid=uid,index=tonumber(chapter.index) or index,
                    title=scalar(chapter.title),attempts=tonumber(prior.attempts) or 0,
                    retry_at=tonumber(prior.retry_at) or 0,
                    blocked=prior.blocked==true or nil}
            end
        end
    end
    return {version=version,core_map_hash=scalar(record.core_map_hash),
        login_session_id=scalar(login_session_id),book_id=id,jobs=jobs,
        total=#rows,updated_at=os.time()},nil
end

function M.next_job(queue,now)
    queue=type(queue)=="table" and queue or {}
    now=tonumber(now) or os.time()
    local pending_due=nil
    for index,job in ipairs(queue.jobs or {}) do
        if type(job)=="table" and job.blocked~=true then
            local retry_at=tonumber(job.retry_at) or 0
            if retry_at<=now then return index,job,nil end
            pending_due=math.min(pending_due or retry_at,retry_at)
        end
    end
    return nil,nil,pending_due
end

function M.finish(queue,index,success,error,now,wait_seconds)
    if type(queue)~="table" or type(queue.jobs)~="table" then return false end
    local job=queue.jobs[index]
    if type(job)~="table" then return false end
    if success then
        table.remove(queue.jobs,index)
    else
        local attempts=(tonumber(job.attempts) or 0)+1
        job.attempts=attempts
        local message=scalar(error)
        job.error=message:sub(1,140)
        -- Back off exponentially without scheduling any tight HTTP retry loop.
        local backoff=math.min(3600,60*2^math.min(6,attempts-1))
        job.retry_at=(tonumber(now) or os.time())+math.max(backoff,tonumber(wait_seconds) or 0)
        -- Keep permanent access errors visible, but don't hit the endpoint again.
        if message:find("access_denied",1,true) or message:find("forbidden",1,true)
            or message:find("chapter_uid_missing",1,true)
            or message:find("web_structure_placeholder",1,true)
            or message:find("web_source_not_authoritative",1,true)
            or attempts>=6 then
            job.blocked=true
        end
    end
    queue.updated_at=tonumber(now) or os.time()
    return true
end

return M
