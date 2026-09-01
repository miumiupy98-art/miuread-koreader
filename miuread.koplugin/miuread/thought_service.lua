local Thoughts = require("miuread.thoughts")
local ThoughtDatabase = require("miuread.thought_database")
local ThoughtFetcher = require("miuread.thought_fetcher")
local SQLiteStore = require("miuread.sqlite_store")
local U = require("miuread.util")
local logger = require("logger")

local ThoughtService = {}
ThoughtService.__index = ThoughtService

local V55_MIGRATION_KEY = "thought_fetcher_v553_migrated"

local function ensure_v55_migration(store, book_id)
    if not ThoughtDatabase.exists(store, book_id) then return true end
    local ok, err = pcall(function()
        SQLiteStore.with_connection(ThoughtDatabase.path(store, book_id), false, function(conn)
            if tostring(SQLiteStore.get_text(conn, V55_MIGRATION_KEY) or "") == "1" then return end
            SQLiteStore.transaction(conn, function()
                -- beta.10-beta.13 may have persisted zero-comment chapters as
                -- complete. Invalidate only those legacy zero completions once;
                -- real cached comments are left untouched.
                conn:exec([[
                    UPDATE thought_fetch_state
                       SET status = 'stale_empty',
                           complete = 0,
                           last_error = '5.5.0-beta.3 A/B diagnostic migration'
                     WHERE complete = 1
                       AND NOT EXISTS (
                            SELECT 1
                              FROM thought_comments c
                             WHERE c.chapter_uid = thought_fetch_state.chapter_uid
                       );
                    DELETE FROM thought_fetch_checkpoint;
                ]])
                SQLiteStore.set_text(conn, V55_MIGRATION_KEY, "1")
            end)
        end)
    end)
    if not ok then
        logger.warn("[MiuRead][CommentFetch] v5.5 migration failed",
            "book=", tostring(book_id), "error=", tostring(err))
        return false
    end
    return true
end

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

local function locator_ranges(rows)
    local out,seen={},{}
    for _,row in ipairs(type(rows)=="table" and rows or {}) do
        local key=tostring(row.range or row.range_key or "")
        if key~="" and not seen[key] then
            seen[key]=true
            out[#out+1]=key
        end
    end
    return out
end

function ThoughtService:new(annotations, store)
    return setmetatable({annotations=annotations, store=store}, self)
end

function ThoughtService:fetch_chapter(book_id, chapter_uid, options)
    options=type(options)=="table" and options or {}
    ensure_v55_migration(self.store,book_id)
    local progress=type(options.progress)=="function" and options.progress or function() end
    local previous_state=ThoughtDatabase.chapter_status(self.store,book_id,chapter_uid)
    local previous_groups=select(1,Thoughts.load(self.store,book_id,chapter_uid))
    if type(previous_groups)~="table" then previous_groups={} end
    local previous_comments=tonumber(previous_state.comments or 0) or 0

    -- 5.5 no longer consumes beta.10-beta.13 comment checkpoints. They describe
    -- the old empty-verification state machine and can reproduce false success.
    ThoughtDatabase.clear_checkpoint(self.store,book_id,chapter_uid)

    local function fail(message,kind,detail)
        ThoughtDatabase.set_fetch_state(self.store,book_id,chapter_uid,"error",false,
            tostring(kind or message or "error"))
        return nil,tostring(message or "评论获取失败"),detail
    end

    -- Body/locator ownership stays unchanged. Normal comment refreshes reuse the
    -- ranges persisted while the EPUB was generated. Only missing locators or an
    -- explicit force refresh ask the annotation layer for underlines, with
    -- fetch_reviews=false so the old comment state machine is completely bypassed.
    local locator_rows=ThoughtDatabase.load_locators(self.store,book_id,chapter_uid)
    if options.force_refresh==true or #locator_rows==0 then
        progress("underlines",0,0,"更新正文定位")
        local locator_result=self.annotations:fetch_chapter(book_id,chapter_uid,progress,{
            force_refresh=true,
            fetch_reviews=false,
        })
        if type(locator_result)~="table" or locator_result.underline_request_ok~=true then
            local kind=tostring(locator_result and locator_result.error_kind or "server")
            local message=(kind=="network" and "网络不可用，已保留原评论缓存")
                or (kind=="authentication" and "登录状态已失效")
                or (kind=="forbidden" and "当前账号暂时无法获取本章评论")
                or (kind=="rate_limit" and "评论请求过于频繁，请稍后再试")
                or "本章定位信息暂时无法获取，已保留原评论缓存"
            return fail(message,kind,locator_result)
        end

        local rows=self.annotations:locator_rows(locator_result,false)
        local saved,save_err=ThoughtDatabase.save_locators(
            self.store,book_id,chapter_uid,rows,"",false)
        if not saved then
            return fail("正文定位保存失败","locator_save",save_err)
        end
        locator_rows=ThoughtDatabase.load_locators(self.store,book_id,chapter_uid)
        logger.info("[MiuRead][ThoughtLocator] refreshed for comments",
            "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
            "ranges=",tostring(#locator_rows))
    end

    local ranges=locator_ranges(locator_rows)
    if #ranges==0 then
        if previous_comments>0 then
            ThoughtDatabase.set_fetch_state(self.store,book_id,chapter_uid,
                "partial",false,"locator ranges empty; protected existing comments")
            return {
                book_id=tostring(book_id or ""),chapter_uid=tostring(chapter_uid or ""),
                groups=tonumber(previous_state.groups or 0) or 0,
                comments=previous_comments,server_comments=0,saved_comments=previous_comments,
                complete=false,status="partial",protected=true,error_kind="locator_empty",
                underlines=0,pending_ranges=0,locators=0,
            }
        end
        ThoughtDatabase.set_fetch_state(self.store,book_id,chapter_uid,
            "partial",false,"no locator ranges; beta.2 does not auto-verify empty")
        return {
            book_id=tostring(book_id or ""),chapter_uid=tostring(chapter_uid or ""),
            groups=0,comments=0,server_comments=0,saved_comments=0,
            complete=false,status="partial",error_kind="no_ranges",
            underlines=0,pending_ranges=0,locators=0,
        }
    end

    local result=ThoughtFetcher.fetch(
        self.annotations.api,book_id,chapter_uid,ranges,progress,{
            locators=locator_rows,
            ab_diagnostic=options.ab_diagnostic~=false,
        })
    if type(result)~="table" then
        return fail("评论接口返回无效数据","invalid_result",result)
    end

    if result.error_kind=="authentication" then
        return fail("登录状态已失效","authentication",result)
    elseif result.error_kind=="forbidden" then
        return fail("当前账号暂时无法获取本章评论","forbidden",result)
    elseif result.error_kind=="rate_limit" then
        return fail("评论请求过于频繁，请稍后再试","rate_limit",result)
    end

    local incoming_groups=type(result.groups)=="table" and result.groups or {}
    local incoming_comments=tonumber(result.comments or 0) or 0
    local complete=result.complete==true
    -- beta.2 never treats a zero-comment response as authoritative empty.
    -- Partial/unknown results cannot erase an existing non-empty cache.
    local protected=complete~=true or incoming_comments==0

    local groups=protected and merged_groups(previous_groups,incoming_groups)
        or incoming_groups
    local saved,save_err=Thoughts.save(self.store,book_id,chapter_uid,groups)
    if not saved then
        return fail(tostring(save_err or "评论缓存写入失败"),"save failed",result)
    end

    local counts=ThoughtDatabase.chapter_counts(self.store,book_id,chapter_uid)
    local comments=tonumber(counts.comments or 0) or 0
    local status

    if protected then
        complete=false
        status="partial"
    elseif comments>0 then
        status="ready"
    else
        complete=false
        status="partial"
    end

    local last_error=table.concat(type(result.errors)=="table" and result.errors or {}," | ")
    ThoughtDatabase.set_fetch_state(self.store,book_id,chapter_uid,status,complete,
        complete and "" or last_error)

    return {
        book_id=tostring(book_id or ""),chapter_uid=tostring(chapter_uid or ""),
        groups=tonumber(counts.groups or 0) or 0,comments=comments,
        server_comments=incoming_comments,saved_comments=comments,
        complete=complete,status=status,protected=protected and previous_comments>0 or false,
        error_kind=result.error_kind,
        underlines=#ranges,pending_ranges=#(result.pending_ranges or {}),
        locators=#locator_rows,
        ab_diagnostic=result.ab_diagnostic,
    }
end

function ThoughtService:chapter_status(book_id,chapter_uid)
    ensure_v55_migration(self.store,book_id)
    return ThoughtDatabase.chapter_status(self.store,book_id,chapter_uid)
end

function ThoughtService:book_status(book_id,chapter_uids)
    ensure_v55_migration(self.store,book_id)
    return ThoughtDatabase.book_status(self.store,book_id,chapter_uids)
end

function ThoughtService:cached_chapters(book_id)
    ensure_v55_migration(self.store,book_id)
    return ThoughtDatabase.cached_chapters(self.store,book_id)
end

function ThoughtService:locators(book_id,chapter_uid)
    return ThoughtDatabase.load_locators(self.store,book_id,chapter_uid)
end

function ThoughtService:locator_chapters(book_id)
    return ThoughtDatabase.locator_chapters(self.store,book_id)
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
    local legacy=self.store:book_dir(book_id).."/thoughts/"..U.id_name(tostring(chapter_uid or ""))..".json"
    os.remove(legacy)
    return true
end

function ThoughtService:delete_book(book_id)
    local ok,err=ThoughtDatabase.delete_book_comments(self.store,book_id)
    if not ok then return nil,err end
    local root=self.store:book_dir(book_id)
    for _,name in ipairs({"thoughts","thought-index","legacy-json-backup"}) do
        pcall(U.remove_tree,root.."/"..name)
    end
    return true
end

return ThoughtService
