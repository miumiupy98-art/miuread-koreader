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
    local function fail(message,kind,detail)
        -- A refresh failure must never destroy a previously usable cache. Keep
        -- the old completeness bit while recording the most recent transport
        -- error, so the reader can continue showing the cached comments.
        ThoughtDatabase.set_fetch_state(self.store,book_id,chapter_uid,"error",previous_state.complete==true,
            tostring(kind or message or "error"))
        return nil,tostring(message or "评论获取失败"),detail
    end

    local result=self.annotations:fetch_chapter(book_id,chapter_uid,progress,{
        force_refresh=options.force_refresh==true,
    })
    if type(result)~="table" then
        return fail("评论接口返回无效数据","invalid result")
    end
    if result.auth_required==true then return fail("登录状态已失效","authentication",result) end
    if result.forbidden==true then return fail("当前账号暂时无法获取本章评论","forbidden",result) end
    if result.rate_limited==true then return fail("评论请求过于频繁，请稍后再试","rate_limit",result) end

    -- If the underline request itself failed, review_groups is not an
    -- authoritative replacement. In particular, never replace a good cache
    -- with an empty table after a transient network/server error.
    if result.underline_request_ok~=true and result.complete~=true then
        local kind=tostring(result.error_kind or "server")
        local message=(kind=="network" and "网络不可用，已保留原评论缓存")
            or (kind=="server" and "评论服务暂时不可用，已保留原评论缓存")
            or "本章评论暂时无法获取，已保留原评论缓存"
        return fail(message,kind,result)
    end

    local groups=type(result.review_groups)=="table" and result.review_groups or {}
    local complete=result.complete==true
    if not complete then
        -- Partial responses are additive. Replacing the chapter here would
        -- discard ranges fetched by an earlier attempt, making retries move
        -- backwards. Merge by range and only use replacement semantics after
        -- the annotation pipeline reports a complete chapter.
        local previous=select(1,Thoughts.load(self.store,book_id,chapter_uid))
        groups=merged_groups(previous,groups)
    end

    local saved,save_err=Thoughts.save(self.store,book_id,chapter_uid,groups)
    if not saved then return fail(tostring(save_err or "评论缓存写入失败"),"save failed",result) end

    ThoughtDatabase.set_fetch_state(self.store,book_id,chapter_uid,complete and "ready" or "partial",complete,
        complete and "" or table.concat(result.errors or {}," | "))
    local counts=ThoughtDatabase.chapter_counts(self.store,book_id,chapter_uid)
    return {
        book_id=tostring(book_id or ""),chapter_uid=tostring(chapter_uid or ""),
        groups=tonumber(counts.groups or 0) or 0,comments=tonumber(counts.comments or 0) or 0,
        complete=complete,error_kind=result.error_kind,
    }
end

function ThoughtService:chapter_status(book_id,chapter_uid)
    return ThoughtDatabase.chapter_status(self.store,book_id,chapter_uid)
end

function ThoughtService:book_status(book_id,chapter_uids)
    return ThoughtDatabase.book_status(self.store,book_id,chapter_uids)
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
