local Thoughts = require("miuread.thoughts")
local ThoughtDatabase = require("miuread.thought_database")
local U = require("miuread.util")

local ThoughtService = {}
ThoughtService.__index = ThoughtService

local function merged_groups(previous, current)
    local ordered, by_range = {}, {}
    local function put(group)
        if type(group) ~= "table" then return end
        local range = tostring(group.range or "")
        if range == "" then return end
        if not by_range[range] then ordered[#ordered + 1] = range end
        by_range[range] = group
    end
    for _, group in ipairs(type(previous) == "table" and previous or {}) do put(group) end
    for _, group in ipairs(type(current) == "table" and current or {}) do put(group) end
    local out = {}
    for _, range in ipairs(ordered) do out[#out + 1] = by_range[range] end
    return out
end

function ThoughtService:new(annotations, store)
    return setmetatable({annotations=annotations, store=store}, self)
end

function ThoughtService:fetch_chapter(book_id, chapter_uid, options)
    options=type(options)=="table" and options or {}
    local progress=type(options.progress)=="function" and options.progress or function() end
    local previous_state=ThoughtDatabase.chapter_status(self.store,book_id,chapter_uid)
    local previous_groups=select(1,Thoughts.load(self.store,book_id,chapter_uid))
    if type(previous_groups)~="table" then previous_groups={} end

    local previous_checkpoint
    if options.force_refresh~=true then
        local raw_checkpoint=ThoughtDatabase.load_checkpoint(self.store,book_id,chapter_uid)
        if type(raw_checkpoint)=="table" then
            local ok,value=pcall(self.annotations.from_cache,self.annotations,raw_checkpoint)
            if ok and type(value)=="table" then previous_checkpoint=value end
        end
    else
        ThoughtDatabase.clear_checkpoint(self.store,book_id,chapter_uid)
    end

    local function fail(message,kind,detail)
        ThoughtDatabase.set_fetch_state(self.store,book_id,chapter_uid,"error",false,
            tostring(kind or message or "error"))
        return nil,tostring(message or "评论获取失败"),detail
    end

    local checkpoint_state=previous_checkpoint
    local function persist_checkpoint(snapshot)
        local merged=self.annotations:merge(checkpoint_state,snapshot)
        local cache=self.annotations:to_cache(merged)
        local saved_checkpoint,checkpoint_err=ThoughtDatabase.save_checkpoint(self.store,book_id,chapter_uid,cache)
        if not saved_checkpoint then error("评论断点保存失败："..tostring(checkpoint_err)) end
        checkpoint_state=merged
        -- Do not replace an already complete, usable cache while a forced or
        -- interrupted refresh is still in progress. New books can expose the
        -- partial data immediately; existing complete books keep the old view.
        if previous_state.complete~=true then
            local combined=merged_groups(previous_groups,merged.review_groups or {})
            local saved,save_err=Thoughts.save(self.store,book_id,chapter_uid,combined)
            if not saved then error(tostring(save_err or "评论缓存写入失败")) end
        end
        ThoughtDatabase.set_fetch_state(self.store,book_id,chapter_uid,"partial",false,
            table.concat(merged.errors or {}," | "))
        return merged
    end

    local result=self.annotations:fetch_chapter(book_id,chapter_uid,progress,{
        force_refresh=options.force_refresh==true,
        previous=previous_checkpoint,
        checkpoint=persist_checkpoint,
    })
    if type(result)~="table" then
        return fail("评论接口返回无效数据","invalid result")
    end
    if result.auth_required==true then return fail("登录状态已失效","authentication",result) end
    if result.forbidden==true then return fail("当前账号暂时无法获取本章评论","forbidden",result) end
    if result.rate_limited==true then return fail("评论请求过于频繁，请稍后再试","rate_limit",result) end

    if result.underline_request_ok~=true and result.complete~=true then
        local kind=tostring(result.error_kind or "server")
        local message=(kind=="network" and "网络不可用，已保留原评论缓存")
            or (kind=="server" and "评论服务暂时不可用，已保留原评论缓存")
            or "本章评论暂时无法获取，已保留原评论缓存"
        return fail(message,kind,result)
    end

    local merged=self.annotations:merge(previous_checkpoint,result)
    local groups=type(merged.review_groups)=="table" and merged.review_groups or {}
    if merged.complete~=true then
        groups=merged_groups(previous_groups,groups)
    end

    local incoming_comments=tonumber(merged.thought_entry_count or 0) or 0
    local previous_comments=tonumber(previous_state.comments or 0) or 0
    if merged.suspicious_empty==true then
        local combined=merged_groups(previous_groups,groups)
        local saved,save_err=Thoughts.save(self.store,book_id,chapter_uid,combined)
        if not saved then return fail(tostring(save_err or "评论缓存写入失败"),"save failed",result) end
        local counts=ThoughtDatabase.chapter_counts(self.store,book_id,chapter_uid)
        ThoughtDatabase.set_fetch_state(self.store,book_id,chapter_uid,"suspicious_empty",false,
            table.concat(merged.errors or {}," | "))
        ThoughtDatabase.save_checkpoint(self.store,book_id,chapter_uid,self.annotations:to_cache(merged))
        return {
            book_id=tostring(book_id or ""),chapter_uid=tostring(chapter_uid or ""),
            groups=tonumber(counts.groups or 0) or 0,comments=tonumber(counts.comments or 0) or 0,
            server_comments=incoming_comments,saved_comments=tonumber(counts.comments or 0) or 0,
            complete=false,status="suspicious_empty",protected=previous_comments>0,
            error_kind="suspicious_empty",underlines=tonumber(merged.underline_count or 0) or 0,
            pending_ranges=#(merged.pending_ranges or {}),
        }
    end
    if merged.complete==true and incoming_comments==0 and previous_comments>0 then
        -- A chapter that used to contain valid comments must never be erased by
        -- a transient empty readReviews response. Keep the old cache and make
        -- the anomaly visible so a later retry can re-check it.
        ThoughtDatabase.clear_checkpoint(self.store,book_id,chapter_uid)
        ThoughtDatabase.set_fetch_state(self.store,book_id,chapter_uid,"suspicious_empty",false,
            "empty refresh rejected; previous comments="..tostring(previous_comments))
        return {
            book_id=tostring(book_id or ""),chapter_uid=tostring(chapter_uid or ""),
            groups=tonumber(previous_state.groups or 0) or 0,comments=previous_comments,
            server_comments=0,saved_comments=previous_comments,complete=false,
            status="suspicious_empty",protected=true,error_kind="suspicious_empty",
            underlines=tonumber(merged.underline_count or 0) or 0,
        }
    end

    local saved,save_err=Thoughts.save(self.store,book_id,chapter_uid,groups)
    if not saved then return fail(tostring(save_err or "评论缓存写入失败"),"save failed",result) end

    local complete=merged.complete==true
    local counts=ThoughtDatabase.chapter_counts(self.store,book_id,chapter_uid)
    local status=complete and ((tonumber(counts.comments or 0) or 0)>0 and "ready" or "empty") or "partial"
    ThoughtDatabase.set_fetch_state(self.store,book_id,chapter_uid,status,complete,
        complete and "" or table.concat(merged.errors or {}," | "))
    if complete then ThoughtDatabase.clear_checkpoint(self.store,book_id,chapter_uid)
    else ThoughtDatabase.save_checkpoint(self.store,book_id,chapter_uid,self.annotations:to_cache(merged)) end

    return {
        book_id=tostring(book_id or ""),chapter_uid=tostring(chapter_uid or ""),
        groups=tonumber(counts.groups or 0) or 0,comments=tonumber(counts.comments or 0) or 0,
        server_comments=incoming_comments,saved_comments=tonumber(counts.comments or 0) or 0,
        complete=complete,status=status,error_kind=merged.error_kind,
        underlines=tonumber(merged.underline_count or 0) or 0,
        pending_ranges=#(merged.pending_ranges or {}),
    }
end

function ThoughtService:chapter_status(book_id,chapter_uid)
    return ThoughtDatabase.chapter_status(self.store,book_id,chapter_uid)
end

function ThoughtService:book_status(book_id,chapter_uids)
    return ThoughtDatabase.book_status(self.store,book_id,chapter_uids)
end

function ThoughtService:cached_chapters(book_id)
    return ThoughtDatabase.cached_chapters(self.store,book_id)
end

function ThoughtService:delete_chapters(book_id,chapter_uids)
    local ok,count_or_err=ThoughtDatabase.delete_chapters(self.store,book_id,chapter_uids)
    if not ok then return nil,count_or_err end
    for _,chapter_uid in ipairs(chapter_uids or {}) do
        local legacy=self.store:book_dir(book_id).."/thoughts/"..U.id_name(tostring(chapter_uid or ""))..".json"
        os.remove(legacy)
    end
    return true,count_or_err
end

function ThoughtService:delete_chapter(book_id,chapter_uid)
    local ok,err=ThoughtDatabase.delete_chapter(self.store,book_id,chapter_uid)
    if not ok then return nil,err end
    -- beta.9 still keeps legacy JSON reading as an upgrade fallback. Remove the
    -- matching old file too, otherwise a user-deleted cache could immediately
    -- reappear through Thoughts.load()'s legacy fallback.
    local legacy=self.store:book_dir(book_id).."/thoughts/"..U.id_name(tostring(chapter_uid or ""))..".json"
    os.remove(legacy)
    return true
end

function ThoughtService:delete_book(book_id)
    ThoughtDatabase.remove(self.store,book_id)
    local root=self.store:book_dir(book_id)
    for _,name in ipairs({"thoughts","thought-index","legacy-json-backup"}) do
        pcall(U.remove_tree,root.."/"..name)
    end
    return true
end

return ThoughtService
