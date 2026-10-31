-- MiuRead 6.5.0-beta.16: EPUB-first, same-task Web source acquisition.
-- This module owns download-only checkpoints. No progress/readtime/POST APIs.
-- Web source caching is independent of strict EPUB text correspondence.
local U=require("miuread.util")
local Json=require("miuread.json")
local Installer=require("miuread.epub_installer")
local Legacy=require("miuread.legacy_coordinate_backfill")
local logger=require("logger")
local lfs=require("libs/libkoreader-lfs")

local M={}
local function mtime(path)
    local ok,value=pcall(lfs.attributes,path,"modification")
    return ok and (tonumber(value) or 0) or 0
end
local function same_account(store,account)
    local auth=store:auth() or {}
    local current=tostring(((auth.account or {}).vid) or "").."|"..tostring(auth.login_session_id or "")
    return current~="|" and current==tostring(account or "")
end
local function account_key(store)
    local auth=store:auth() or {}
    return tostring(((auth.account or {}).vid) or "").."|"..tostring(auth.login_session_id or "")
end
local function state_path(store,book,options)
    local task=tostring(options.download_run_id or "")
    if task=="" or tostring(book.bookId or "")=="" then return nil end
    return store:book_dir(book.bookId).."/post-install-web-"..U.id_name(task)..".json"
end
local function save(path,state)
    local ok,encoded=pcall(Json.encode,state)
    if not ok then return nil,"json:"..tostring(encoded) end
    return U.atomic_write(path,encoded,true)
end
local function load(path)
    local raw=path and U.read_file(path,true)
    if not raw then return nil end
    local ok,value=pcall(Json.decode,raw)
    return ok and type(value)=="table" and value or nil
end
local function identity_ok(state,store,book,opt)
    if not state or not same_account(store,state.account) then return false end
    local rec=state.record or {}
    if tostring(state.task_id or "")~=tostring(opt.download_run_id or "")
        or tostring(rec.book_id or "")~=tostring(book.bookId or "")
        or rec.pending_install==true or not U.file_exists(rec.file or "")
        or tonumber(state.size or -1)~=tonumber(U.file_size(rec.file) or -2)
        or tonumber(state.mtime or -1)~=mtime(rec.file) then return false end
    local ok,meta=pcall(Installer.inspect,rec.file)
    return ok and type(meta)=="table" and tostring(meta.book_id or "")==tostring(rec.book_id or "")
        and tostring(meta.task_id or "")==tostring(state.task_id or "")
        and (tonumber(meta._chapter_count) or -1)==(tonumber(rec.chapter_count) or -2)
end
function M.begin(store,record,book,opt)
    local path=state_path(store,book,opt)
    if not path then return nil,"task_identity_missing" end
    if record.pending_install==true or not U.file_exists(record.file or "") then return nil,"epub_not_installed" end
    local state={schema=1,task_id=tostring(opt.download_run_id),account=account_key(store),
        size=U.file_size(record.file),mtime=mtime(record.file),record=record,
        next_index=1,cached=0,verified=0,unmapped=0,skipped=0,failed=0,
        failed_uids={},mapping_diagnostics={},
        status="pending",updated_at=os.time()}
    if not identity_ok(state,store,book,opt) then return nil,"installed_epub_identity_mismatch" end
    return save(path,state)
end
function M.resume(store,book,opt)
    local path=state_path(store,book,opt)
    local state=load(path)
    if not identity_ok(state,store,book,opt) then return nil end
    if state.status=="complete" then return nil end
    return U.copy(state.record)
end
function M.run(store,record,book,reader,opt,progress,checkpoint)
    local path=assert(state_path(store,book,opt))
    local state=load(path)
    -- Old beta.15 checkpoint: every strict success also had a cached Web source.
    if type(state)=="table" and state.cached==nil then state.cached=state.verified or 0 end
    if type(state)=="table" and state.unmapped==nil then state.unmapped=0 end
    if type(state)=="table" and type(state.mapping_diagnostics)~="table" then state.mapping_diagnostics={} end
    if not identity_ok(state,store,book,opt) then
        record.post_install_web_status="needs_attention"
        record.post_install_web_error="postinstall_checkpoint_identity_invalid"
        return record
    end
    local meta=Installer.inspect(record.file)
    if type(meta)~="table" or type(meta.chapters)~="table" then
        record.post_install_web_status="needs_attention"
        record.post_install_web_error="epub_catalog_unreadable"
        return record
    end
    local total=tonumber(meta._chapter_count) or #meta.chapters
    if #meta.chapters~=total then
        record.post_install_web_status="needs_attention"
        record.post_install_web_error="epub_chapter_catalog_incomplete"
        return record
    end
    -- No standalone worker or idle queue is involved in this pass.
    local job={book_id=record.book_id,file=record.file,version=tonumber(book.version) or
        tonumber(record.progress_source_book_version) or 0,size=state.size,mtime=state.mtime,
        title=record.title,variant=record.variant}
    local source_total=0
    for _,chapter in ipairs(meta.chapters) do if chapter.structural~=true then source_total=source_total+1 end end
    local function update(message,activity)
        record.post_install_web_status=state.status
        record.post_install_web_cached=state.cached
        record.post_install_web_verified=state.verified
        record.post_install_web_unmapped=state.unmapped
        record.post_install_web_mapping_error=state.last_mapping_error
        record.post_install_web_total=source_total
        record.post_install_web_failed=state.failed
        record.post_install_web_failed_uids=U.copy(state.failed_uids or {})
        record.post_install_web_skipped=state.skipped
        record.post_install_web_error=state.error or state.last_failure
        record.post_install_web_next_index=state.next_index
        if type(progress)=="function" then
            progress("coordinate",math.max(0,state.next_index-1),math.max(1,total),book.title,
                {message=message,activity=activity or "post_install_web",
                coordinate_verified=state.verified,coordinate_cached=state.cached,
                coordinate_unmapped=state.unmapped,coordinate_total=source_total,
                coordinate_failed=state.failed,epub_installed=true})
        end
    end
    -- If an earlier whole-book pass ended with failed fetches, a later
    -- explicit resume targets only those failed chapter indices. The durable
    -- retry cursor avoids rechecking all successful chapters after hibernation.
    if state.next_index>total and state.failed>0 and not state.retry_indices then
        local indices,seen={},{}
        for _,entry in ipairs(state.failed_uids or {}) do
            local index=tonumber(entry.index)
            if index and index>=1 and index<=total and not seen[index] then
                indices[#indices+1]=index;seen[index]=true
            end
        end
        state.retry_indices=indices
        state.retry_cursor=1
        state.failed=0
        state.failed_uids={}
        state.error=nil
        state.last_failure=nil
        local ok_retry,why_retry=save(path,state)
        if not ok_retry then
            record.post_install_web_status="needs_attention"
            record.post_install_web_error="retry_checkpoint_write_failed:"..tostring(why_retry)
            return record
        end
    end
    local retrying=type(state.retry_indices)=="table" and #state.retry_indices>0
    local indices={}
    if retrying then
        for i=math.max(1,tonumber(state.retry_cursor) or 1),#state.retry_indices do
            indices[#indices+1]=state.retry_indices[i]
        end
    else
        for i=math.max(1,tonumber(state.next_index) or 1),total do indices[#indices+1]=i end
    end
    state.status="running"
    update("EPUB 已安装，正在补齐 Web 原文","post_install_start")
    for sequence,index in ipairs(indices) do
        if type(checkpoint)=="function" then checkpoint("coordinate") end
        job.next_index=index
        local result_ok,result=pcall(Legacy.perform,job,reader)
        if not result_ok then result={ok=false,reason=tostring(result)} end
        if type(result)~="table" then result={ok=false,reason="invalid_chapter_result"} end
        -- The legacy reader fetch wraps errors in pcall. Preserve a true
        -- sleep/cancel signal rather than counting it as a failed Web chapter.
        if result.ok~=true then
            local signal=tostring(result.reason or "")
            if signal:find("__MIUREAD_HIBERNATE__",1,true) or signal:find("download cancelled",1,true) then
                error(signal,0)
            end
        end
        if result.ok then
            if result.skipped then
                state.skipped=state.skipped+1
            else
                state.cached=state.cached+1
                if result.mapping_verified==true or (result.mapping_verified==nil and result.anchors) then
                    -- Compatibility for older installed-book workers.
                    state.verified=state.verified+1
                else
                    state.unmapped=state.unmapped+1
                    state.last_mapping_error=tostring(result.mapping_error or "source_mapping_unverified"):sub(1,180)
                    state.mapping_diagnostics[#state.mapping_diagnostics+1]={index=index,
                        uid=meta.chapters[index] and meta.chapters[index].uid,
                        reason=state.last_mapping_error}
                end
            end
            state.error=nil -- Do not confuse a mapping diagnostic with a fetch error.
        else
            local why=tostring(result.reason or "unknown")
            state.failed=state.failed+1
            state.failed_uids[#state.failed_uids+1]={index=index,uid=meta.chapters[index] and meta.chapters[index].uid,reason=why:sub(1,180)}
            state.error=why:sub(1,180)
            state.last_failure=state.error
            logger.warn("[MiuRead][PostInstallWeb] chapter not verified (EPUB preserved)",
                "book=",tostring(book.bookId),"index=",tostring(index),"reason=",why)
            -- Do not hammer the remote service on a rate limit, auth loss or
            -- network failure. The installed EPUB remains usable immediately.
            local transient=why:find("429",1,true) or why:find("rate_limit",1,true)
                or why:find("auth",1,true) or why:find("network",1,true)
                or why:find("timeout",1,true) or why:find("HTTP 5",1,true)
            if transient then
                state.status="needs_attention"
                if not retrying then state.next_index=index end
                state.updated_at=os.time();save(path,state)
                update("EPUB 已安装，Web 定位因网络/认证问题暂停","post_install_waiting")
                return record
            end
        end
        if retrying then
            state.retry_cursor=math.max(1,tonumber(state.retry_cursor) or 1)+1
        else
            state.next_index=index+1
        end
        state.updated_at=os.time()
        local persisted,why=save(path,state)
        if not persisted then
            logger.warn("[MiuRead][PostInstallWeb] checkpoint write failed",tostring(why))
            state.status="needs_attention";state.error="checkpoint_write_failed"
            update("EPUB 已安装，Web 续补状态无法保存","post_install_error")
            return record
        end
        update("EPUB 已安装 · Web 来源已缓存 "..tostring(state.cached).."/"..tostring(source_total)
            .." · 正文对应已验证 "..tostring(state.verified)
            ..(state.failed>0 and (" · 获取失败 "..tostring(state.failed)) or ""))
        if index%6==0 then collectgarbage("collect") end
    end
    state.retry_indices=nil
    state.retry_cursor=nil
    state.status=state.failed==0 and "complete" or "needs_attention"
    state.updated_at=os.time()
    local persisted,why=save(path,state)
    if not persisted then state.status="needs_attention";state.error="checkpoint_write_failed:"..tostring(why) end
    -- The installed EPUB embeds the source state as of packaging (false).
    -- Keep that immutable metadata consistent; completion lives in the
    -- separately persisted, account-bound post-install status/caches.
    record.progress_source_complete=false
    record.progress_source_chapter_count=source_total
    record.progress_source_cached_count=state.cached
    record.post_install_web_status=state.status
    update(state.status=="complete" and "EPUB 已安装，Web 原文已缓存（不等于精确坐标已验证）" or
        "EPUB 已安装；Web 原文部分未取得，可在定位管理中处理",
        "post_install_finish")
    logger.info("[MiuRead][PostInstallWeb] completed", "book=",tostring(book.bookId),
        "cached=",tostring(state.cached),"mapped=",tostring(state.verified),
        "unmapped=",tostring(state.unmapped),"failed=",tostring(state.failed),
        "skipped=",tostring(state.skipped),"status=",state.status)
    return record
end
return M
