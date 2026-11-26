-- Per-book, account-scoped chapter queue. The comments themselves remain in
-- ThoughtDatabase so interruption cannot discard a committed chapter batch.
local Digests=require("miuread.digests")
local Json=require("miuread.json")
local U=require("miuread.util")
local Job={}
local valid={pending=true,cached=true,reused=true,partial=true,failed=true}
local VERSION=1

local function account(store)
    local auth=store:auth()
    return tostring((auth.account or {}).vid or (auth.cookies or {}).wr_vid or "")
end

local function path(store,book_id,owner)
    return store:book_cache_path(book_id).."/comment-job-"..Digests.sha256(owner)..".json"
end

function Job.new(store,book_id,rows,first,last,refresh)
    local owner=account(store)
    if owner=="" then return nil,"请先登录微信读书" end
    local chapters={}
    for index=first,last do
        local row=rows[index] or {}
        chapters[#chapters+1]={uid=tostring(row.chapterUid or row.uid or row.chapter_uid or ""),
            title=tostring(row.title or ""),state="pending",comments=0}
    end
    local id=tostring(os.time()).."-"..tostring(math.random(100000000,999999999))
    return {schema=VERSION,id=id,owner=owner,book_id=book_id,refresh=refresh==true,chapters=chapters}
end

function Job.load(store,book_id)
    local owner=account(store)
    if not book_id or book_id=="" or owner=="" then return nil end
    local raw=U.read_file(path(store,book_id,owner),true)
    if not raw then return nil end
    local ok,job=pcall(Json.decode,raw)
    if not ok or type(job)~="table" or job.schema~=VERSION or job.owner~=owner or type(job.id)~="string"
        or job.book_id~=book_id or type(job.chapters)~="table" or #job.chapters==0 then return nil end
    for _,chapter in ipairs(job.chapters) do
        if type(chapter)~="table" or type(chapter.uid)~="string" or not valid[chapter.state] then return nil end
    end
    return job
end

function Job.save(store,job)
    if job.owner~=account(store) then return nil,"登录账号已变更" end
    store:book_dir(job.book_id)
    local ok,encoded=pcall(Json.encode,job)
    if not ok then return nil,"评论任务无法序列化" end
    return U.atomic_write(path(store,job.book_id,job.owner),encoded,true)
end

function Job.clear(store,job)
    local target=path(store,job.book_id,job.owner)
    if not U.file_exists(target) then return true end
    return os.remove(target)
end

function Job.summary(job)
    local result={total=#job.chapters,pending=0,cached=0,reused=0,partial=0,failed=0,comments=0}
    for _,chapter in ipairs(job.chapters) do
        result[chapter.state]=result[chapter.state]+1
        result.comments=result.comments+(tonumber(chapter.comments) or 0)
    end
    result.current=result.total-result.pending
    return result
end

function Job.next(job,start)
    for i=start or 1,#job.chapters do
        if job.chapters[i].state=="pending" then return job.chapters[i],i end
    end
end

function Job.retry(job)
    for _,chapter in ipairs(job.chapters) do
        if chapter.state=="failed" or chapter.state=="partial" then chapter.state="pending" end
    end
end

return Job
