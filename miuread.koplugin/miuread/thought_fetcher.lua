local logger = require("logger")
local Http = require("miuread.http")

local Fetcher = {}

local function scalar(value)
    local kind=type(value)
    if kind=="string" or kind=="number" then return tostring(value) end
    if kind=="table" then
        for _,name in ipairs({"value","stringValue","text","id"}) do
            local v=rawget(value,name)
            if type(v)=="string" or type(v)=="number" then return tostring(v) end
        end
    end
    return ""
end

local function range_key(row)
    if type(row)~="table" then return scalar(row) end
    return scalar(rawget(row,"range") or rawget(row,"reviewRange")
        or rawget(row,"rangeKey") or rawget(row,"rangeValue")
        or rawget(row,"markRange") or rawget(row,"bookmarkRange"))
end

local function response_rows(value)
    if type(value)~="table" then return nil end
    if type(rawget(value,"reviews"))=="table" then return rawget(value,"reviews") end
    if type(rawget(value,"updated"))=="table" then return rawget(value,"updated") end
    if #value>0 then return value end
    return nil
end

local function request_map(batch)
    local out={}
    for _,request in ipairs(type(batch)=="table" and batch or {}) do
        local key=range_key(request)
        if key~="" then out[key]=request end
    end
    return out
end

local function returned_requested_count(rows,batch)
    local wanted=request_map(batch)
    local seen={}
    local count=0
    for _,group in ipairs(type(rows)=="table" and rows or {}) do
        local key=range_key(group)
        if key~="" and wanted[key] and not seen[key] then
            seen[key]=true
            count=count+1
        end
    end
    return count
end

local function is_data_specific_failure(value)
    local text=tostring(value or ""):lower()
    return text:find("params error",1,true)~=nil
        or text:find("invalid range",1,true)~=nil
        or text:find("invalid parameter",1,true)~=nil
        or text:find("range error",1,true)~=nil
end

local function error_kind(value)
    local text=tostring(value or "")
    if Http.is_auth_error(text) then return "authentication" end
    if Http.is_rate_limit_error(text) then return "rate_limit" end
    if Http.is_forbidden_error(text) then return "forbidden" end
    local lower=text:lower()
    if lower:find("timeout",1,true)
        or lower:find("network request failed",1,true)
        or lower:find("connection refused",1,true)
        or lower:find("network is unreachable",1,true) then
        return "network"
    end
    return "server"
end

local function fetch_raw(api,book_id,chapter_uid,batch)
    local web_ok,web_value=pcall(api._web_readreviews,api,book_id,chapter_uid,batch)
    if web_ok and type(web_value)=="table" then
        local rows=response_rows(web_value)
        if rows then
            local returned=returned_requested_count(rows,batch)
            logger.info("[MiuRead][CommentFetch] transport",
                "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
                "source=web","requested=",tostring(#batch),
                "returned_ranges=",tostring(returned),"groups=",tostring(#rows))
            if #batch==0 or returned>0 then
                web_value._annotation_source="web"
                return web_value,"web"
            end
            logger.warn("[MiuRead][CommentFetch] web returned no requested range; fallback",
                "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
                "requested=",tostring(#batch),"groups=",tostring(#rows))
        end
    end

    local agent_ok,agent_value=pcall(api._agent_readreviews,api,book_id,chapter_uid,batch)
    if agent_ok and type(agent_value)=="table" then
        local rows=response_rows(agent_value)
        if rows then
            local returned=returned_requested_count(rows,batch)
            logger.info("[MiuRead][CommentFetch] transport",
                "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
                "source=agent_fallback","requested=",tostring(#batch),
                "returned_ranges=",tostring(returned),"groups=",tostring(#rows))
            agent_value._annotation_source="agent_fallback"
            return agent_value,"agent_fallback"
        end
    end

    local err=agent_ok and "Gateway returned invalid review data" or tostring(agent_value)
    if not web_ok and tostring(web_value or "")~="" then
        err=tostring(web_value).." | "..err
    end
    return nil,nil,err
end

local function comment_identity(item)
    local id=tostring(item.review_id or "")
    if id~="" then return "id:"..id end
    return "text:"..tostring(item.content or "").."\0"..tostring(item.author or "")
end

local function parse_comment(wrapper)
    if type(wrapper)~="table" then return nil end
    local nested=rawget(wrapper,"review")
    local row=type(nested)=="table" and nested or wrapper
    if type(row)~="table" then return nil end

    local content=scalar(rawget(row,"content") or rawget(row,"review") or rawget(row,"text"))
    if content=="" then return nil end

    local author=type(rawget(row,"author"))=="table" and rawget(row,"author") or {}
    return {
        content=content,
        abstract=scalar(rawget(row,"abstract") or rawget(row,"contextAbstract") or rawget(row,"markText")),
        author=scalar(rawget(author,"nick") or rawget(author,"name") or rawget(row,"authorName")),
        likes=tonumber(rawget(wrapper,"likesCount") or rawget(row,"likesCount") or 0) or 0,
        created=tonumber(rawget(row,"createTime") or rawget(row,"createdAt") or 0) or 0,
        review_id=scalar(rawget(row,"reviewId") or rawget(row,"id")),
    }
end

local REVIEW_LIST_FIELDS={
    "pageReviews","reviews","updated","reviewList","items","list","comments",
}

local function collect_comments(group)
    local out,seen={},{}
    local recognized=false
    local malformed=0

    local function add(value)
        local item=parse_comment(value)
        if item then
            local key=comment_identity(item)
            if not seen[key] then
                seen[key]=true
                out[#out+1]=item
            end
            return true
        end
        return false
    end

    for _,name in ipairs(REVIEW_LIST_FIELDS) do
        local value=rawget(group,name)
        if type(value)=="table" then
            recognized=true
            for _,entry in ipairs(value) do
                if type(entry)=="table" then
                    if not add(entry) then
                        -- Some gateway versions add one extra wrapper layer.
                        local nested=rawget(entry,"data") or rawget(entry,"item")
                        if type(nested)=="table" and not add(nested) then
                            malformed=malformed+1
                        elseif type(nested)~="table" then
                            malformed=malformed+1
                        end
                    end
                else
                    malformed=malformed+1
                end
            end
        end
    end

    -- Compatibility fallback for responses whose comment rows are placed
    -- directly in the returned range group.
    if #out==0 then add(group) end

    table.sort(out,function(a,b)
        local ac,bc=tonumber(a.created or 0) or 0,tonumber(b.created or 0) or 0
        if ac==bc then return comment_identity(a)<comment_identity(b) end
        return ac<bc
    end)
    return out,recognized,malformed
end

local function explicit_empty(group,recognized,malformed)
    if type(group)~="table" or malformed>0 then return false end
    local total=tonumber(rawget(group,"totalCount") or rawget(group,"reviewCount") or rawget(group,"total"))
    if total==0 then return true end
    if not recognized then return false end

    local has_container=false
    local every_empty=true
    for _,name in ipairs(REVIEW_LIST_FIELDS) do
        local value=rawget(group,name)
        if type(value)=="table" then
            has_container=true
            if next(value)~=nil then every_empty=false end
        end
    end
    if not has_container or not every_empty then return false end
    return rawget(group,"isEnd")==true
        or rawget(group,"hasMore")==false
        or rawget(group,"hasNext")==false
end

local function next_page_request(group,request,page_no)
    if type(group)~="table" or type(request)~="table" then return nil end
    page_no=tonumber(page_no) or 0
    if page_no>=20 then return nil end

    local current=tonumber(request.maxIdx or 0) or 0
    local count=math.max(1,tonumber(request.count or 30) or 30)
    local total=tonumber(rawget(group,"totalCount") or rawget(group,"reviewCount") or rawget(group,"total"))
    local more=rawget(group,"hasMore")==true
        or rawget(group,"hasNext")==true
        or rawget(group,"isEnd")==false
        or (total and total>current+count)
    if not more then return nil end

    local next_idx=tonumber(rawget(group,"nextMaxIdx") or rawget(group,"maxIdx") or rawget(group,"maxIndex"))
    if not next_idx or next_idx<=current then next_idx=current+count end
    if total and next_idx>=total then return nil end

    return {
        range=tostring(request.range or ""),
        maxIdx=next_idx,
        count=count,
        synckey=tonumber(rawget(group,"synckey") or rawget(group,"syncKey")
            or request.synckey or 0) or 0,
    }
end

local function split_batch(batch)
    local middle=math.floor(#batch/2)
    local left,right={},{}
    for index,item in ipairs(batch) do
        if index<=middle then left[#left+1]=item else right[#right+1]=item end
    end
    return left,right
end

function Fetcher.fetch(api,book_id,chapter_uid,ranges,progress)
    progress=type(progress)=="function" and progress or function() end
    ranges=type(ranges)=="table" and ranges or {}

    local batches
    if type(api.review_batches)=="function" then
        batches=api:review_batches(ranges,30)
    else
        batches={}
        for first=1,#ranges,30 do
            local batch={}
            for index=first,math.min(first+29,#ranges) do
                batch[#batch+1]={range=tostring(ranges[index] or ""),maxIdx=0,count=30,synckey=0}
            end
            batches[#batches+1]=batch
        end
    end

    local pending,completed,empty={},{},{}
    local by_range,seen_by_range={},{}
    local page_count={}
    local errors={}
    local source_counts={web=0,agent_fallback=0}
    local last_error_kind

    for _,range in ipairs(ranges) do
        range=tostring(range or "")
        if range~="" then pending[range]=true end
    end

    local function merge_comments(key,comments)
        by_range[key]=by_range[key] or {}
        seen_by_range[key]=seen_by_range[key] or {}
        local seen=seen_by_range[key]
        for _,item in ipairs(comments or {}) do
            local identity=comment_identity(item)
            if not seen[identity] then
                seen[identity]=true
                by_range[key][#by_range[key]+1]=item
            end
        end
    end

    local function process_batch(batch,label,depth)
        depth=tonumber(depth) or 0
        local response,source,err=fetch_raw(api,book_id,chapter_uid,batch)
        if not response then
            if is_data_specific_failure(err) and #batch>1 and depth<6 then
                local left,right=split_batch(batch)
                local a=process_batch(left,label..".1",depth+1)
                local b=process_batch(right,label..".2",depth+1)
                return a and b
            end
            errors[#errors+1]=tostring(label)..": "..tostring(err or "unknown error")
            last_error_kind=error_kind(err)
            return false
        end

        source_counts[source]=(source_counts[source] or 0)+1
        local rows=response_rows(response) or {}
        local wanted=request_map(batch)
        local returned={}
        local next_requests={}

        for _,group in ipairs(rows) do
            local key=range_key(group)
            local request=wanted[key]
            if request then
                returned[key]=true
                local comments,recognized,malformed=collect_comments(group)
                merge_comments(key,comments)

                page_count[key]=(page_count[key] or 0)+1
                local next_request=next_page_request(group,request,page_count[key])
                if next_request then
                    next_requests[#next_requests+1]=next_request
                elseif #(by_range[key] or {})>0 then
                    pending[key]=nil
                    completed[key]=true
                    empty[key]=nil
                elseif explicit_empty(group,recognized,malformed) then
                    pending[key]=nil
                    completed[key]=true
                    empty[key]=true
                else
                    -- Returned but not parsable: keep pending. Never convert this
                    -- into a successful zero.
                    errors[#errors+1]="range "..key.." returned without confirmed comments"
                end
            end
        end

        local missing=0
        for _,request in ipairs(batch) do
            local key=range_key(request)
            if key~="" and not returned[key] then
                missing=missing+1
            end
        end

        local comment_total=0
        for _,items in pairs(by_range) do comment_total=comment_total+#items end
        logger.info("[MiuRead][CommentFetch] batch",
            "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
            "label=",tostring(label),"source=",tostring(source),
            "requested=",tostring(#batch),"returned=",tostring(#batch-missing),
            "comments=",tostring(comment_total),"missing=",tostring(missing),
            "next=",tostring(#next_requests))

        if #next_requests>0 then
            return process_batch(next_requests,label..".next",depth+1)
        end
        return true
    end

    for index,batch in ipairs(batches) do
        progress("thoughts",index,#batches,"")
        process_batch(batch,"comments batch "..tostring(index),0)
    end

    local groups={}
    local comment_count=0
    for key,items in pairs(by_range) do
        if #items>0 then
            table.sort(items,function(a,b)
                local ac,bc=tonumber(a.created or 0) or 0,tonumber(b.created or 0) or 0
                if ac==bc then return comment_identity(a)<comment_identity(b) end
                return ac<bc
            end)
            groups[#groups+1]={range=key,texts=items}
            comment_count=comment_count+#items
        end
    end
    table.sort(groups,function(a,b) return tostring(a.range)<tostring(b.range) end)

    local pending_ranges,completed_ranges,empty_ranges={},{},{}
    for key in pairs(pending) do pending_ranges[#pending_ranges+1]=key end
    for key in pairs(completed) do completed_ranges[#completed_ranges+1]=key end
    for key in pairs(empty) do empty_ranges[#empty_ranges+1]=key end
    table.sort(pending_ranges)
    table.sort(completed_ranges)
    table.sort(empty_ranges)

    local complete=#pending_ranges==0
    local empty_confirmed=complete and comment_count==0
        and #ranges>0 and #empty_ranges==#ranges

    logger.info("[MiuRead][CommentFetch] chapter finished",
        "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
        "ranges=",tostring(#ranges),"comments=",tostring(comment_count),
        "completed=",tostring(#completed_ranges),"pending=",tostring(#pending_ranges),
        "empty=",tostring(#empty_ranges),"complete=",tostring(complete),
        "web_batches=",tostring(source_counts.web or 0),
        "agent_batches=",tostring(source_counts.agent_fallback or 0))

    return {
        groups=groups,
        comments=comment_count,
        completed_ranges=completed_ranges,
        pending_ranges=pending_ranges,
        empty_ranges=empty_ranges,
        complete=complete,
        empty_confirmed=empty_confirmed,
        errors=errors,
        error_kind=last_error_kind,
        source_counts=source_counts,
    }
end

return Fetcher
