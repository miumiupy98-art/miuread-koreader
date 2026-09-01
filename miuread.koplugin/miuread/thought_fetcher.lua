local logger = require("logger")
local Http = require("miuread.http")

local Fetcher = {}

local function scalar_str(value)
    local kind=type(value)
    if kind=="string" or kind=="number" then return tostring(value) end
    return ""
end

local function range_key(value)
    if type(value)~="table" then return "" end
    return scalar_str(rawget(value,"range")
        or rawget(value,"reviewRange")
        or rawget(value,"rangeKey")
        or rawget(value,"rangeValue")
        or rawget(value,"markRange")
        or rawget(value,"bookmarkRange"))
end

local function array_from(data,names)
    if type(data)~="table" then return {},nil end
    for _,name in ipairs(names or {}) do
        if type(rawget(data,name))=="table" then return rawget(data,name),name end
    end
    if #data>0 then return data,"array" end
    return {},nil
end

local function table_entries(data)
    local rows,invalid={},0
    if type(data)~="table" then return rows,invalid,"none" end

    -- This is the v5.3 behavior: ordinary JSON arrays are consumed with ipairs.
    for _,value in ipairs(data) do
        if type(value)=="table" then rows[#rows+1]=value else invalid=invalid+1 end
    end
    if #rows>0 or #data>0 then return rows,invalid,"array" end

    -- Diagnostic compatibility only: some gateways decode object-shaped lists
    -- as keyed Lua tables. Accept table values without guessing scalar content.
    local keyed=0
    for _,value in pairs(data) do
        if type(value)=="table" then rows[#rows+1]=value; keyed=keyed+1 end
    end
    if keyed>0 then return rows,invalid,"map" end
    return rows,invalid,"empty"
end

local function sorted_keys(value,limit)
    local keys={}
    if type(value)=="table" then
        for key in pairs(value) do
            if type(key)=="string" then keys[#keys+1]=key end
        end
    end
    table.sort(keys)
    limit=tonumber(limit) or 12
    while #keys>limit do table.remove(keys) end
    return table.concat(keys,",")
end

local function review_texts_v53(group)
    local rows,seen,invalid={}, {},0
    local pages,container=array_from(group,{"pageReviews","reviews","updated"})
    local page_rows,skipped,shape=table_entries(pages)
    invalid=invalid+skipped
    local nested_count=0

    for _,page in ipairs(page_rows) do
        local ok,item=pcall(function()
            if type(page)~="table" then return nil end
            local nested=rawget(page,"review")
            local row=type(nested)=="table" and nested or page
            if type(nested)=="table" then nested_count=nested_count+1 end
            if type(row)~="table" then return nil end

            local content=scalar_str(rawget(row,"content")
                or rawget(row,"review")
                or rawget(row,"text"))
            if content=="" then return nil end

            local author=type(rawget(row,"author"))=="table" and rawget(row,"author") or {}
            local author_name=scalar_str(rawget(author,"nick")
                or rawget(author,"name")
                or rawget(row,"authorName"))
            local key=scalar_str(rawget(row,"reviewId") or rawget(row,"id"))
            if key=="" then key=content.."\0"..author_name end

            return {
                key=key,
                content=content,
                abstract=scalar_str(rawget(row,"abstract")
                    or rawget(row,"contextAbstract")
                    or rawget(row,"markText")),
                created=tonumber(rawget(row,"createTime") or rawget(row,"createdAt") or 0) or 0,
                author=author_name,
                likes=tonumber(rawget(page,"likesCount") or rawget(row,"likesCount") or 0) or 0,
                review_id=scalar_str(rawget(row,"reviewId") or rawget(row,"id")),
            }
        end)

        if ok and item and not seen[item.key] then
            seen[item.key]=true
            item.key=nil
            rows[#rows+1]=item
        elseif not ok or item==nil then
            invalid=invalid+1
        end
    end

    return rows,{
        container=tostring(container or "none"),
        shape=tostring(shape or "none"),
        page_count=#page_rows,
        nested_count=nested_count,
        invalid=invalid,
        keys=sorted_keys(group,12),
        total_count=tonumber(rawget(group,"totalCount") or rawget(group,"reviewCount") or rawget(group,"total")),
        bookmark_count=tonumber(rawget(group,"bookMarkCount") or rawget(group,"bookmarkCount")),
        max_idx=tonumber(rawget(group,"maxIdx") or rawget(group,"maxIndex")),
        synckey=tonumber(rawget(group,"synckey") or rawget(group,"syncKey")),
        has_more=rawget(group,"hasMore"),
        has_next=rawget(group,"hasNext"),
        is_end=rawget(group,"isEnd"),
    }
end

local function response_rows(value)
    local container,name=array_from(value,{"reviews","updated"})
    local rows,invalid,shape=table_entries(container)
    return rows,{
        container=tostring(name or "none"),
        shape=tostring(shape or "none"),
        invalid=invalid,
        keys=sorted_keys(value,12),
    }
end


local function bool_text(value)
    if value==true then return "true" end
    if value==false then return "false" end
    return ""
end

local function range_fingerprint(value)
    local text=tostring(value or "")
    local hash=5381
    for index=1,#text do
        hash=(hash*33+text:byte(index))%4294967291
    end
    return string.format("%08x",hash)
end

local function request_fingerprint(book_id,chapter_uid,range)
    return range_fingerprint(
        tostring(book_id or "").."|"..tostring(chapter_uid or "").."|"..
        tostring(range or "").."|0|30|0")
end

local function underline_source_text(row)
    if type(row)~="table" then return "" end
    for _,name in ipairs({"markText","bookmarkText","rangeText","abstract","text","content"}) do
        local value=scalar_str(rawget(row,name))
        if value~="" then return value end
    end
    return ""
end

local function fresh_underlines(api,book_id,chapter_uid)
    local ok,value=pcall(api.underlines,api,book_id,chapter_uid)
    if not ok or type(value)~="table" then
        return nil,ok and "underlines returned invalid data" or tostring(value)
    end
    local container,name=array_from(value,{"underlines","updated","bookmarks"})
    local rows,invalid,shape=table_entries(container)
    return rows,nil,{
        container=tostring(name or "none"),
        shape=tostring(shape or "none"),
        invalid=invalid,
        count=#rows,
        source=tostring(value._annotation_source or ""),
    }
end

local function locator_for_range(locators,target)
    for _,row in ipairs(type(locators)=="table" and locators or {}) do
        local key=tostring(row.range or row.range_key or "")
        if key==target then return row end
    end
    return nil
end

local function fresh_match(locator,fresh_rows,target)
    -- Strongest comparison: the exact WeRead range still exists.
    for index,row in ipairs(fresh_rows or {}) do
        if range_key(row)==target then
            return row,"exact",true,index
        end
    end

    if type(locator)~="table" then return nil,"none",false,nil end
    local source=tostring(locator.source_text or "")
    local ordinal=tonumber(locator.ordinal or 0) or 0

    -- If source_text uniquely identifies the same underline, this is strong
    -- enough to diagnose a changed range and safely map recovered comments.
    if source~="" then
        local found,found_index
        for index,row in ipairs(fresh_rows or {}) do
            if underline_source_text(row)==source then
                if found then
                    found=nil
                    found_index=nil
                    break
                end
                found=row
                found_index=index
            end
        end
        if found then return found,"source_text",true,found_index end
    end

    -- Ordinal alone is useful diagnostic evidence but not strong enough to
    -- rewrite/store comments under a different range.
    if ordinal>=1 and type(fresh_rows[ordinal])=="table" then
        local row=fresh_rows[ordinal]
        local fresh_text=underline_source_text(row)
        if source~="" and fresh_text==source then
            return row,"ordinal+text",true,ordinal
        end
        return row,"ordinal_only",false,ordinal
    end
    return nil,"none",false,nil
end

local function rekey_parsed(parsed,from_key,to_key)
    if type(parsed)~="table" or from_key==to_key then return parsed end
    local items=parsed.comments_by_range and parsed.comments_by_range[from_key]
    if type(items)~="table" or #items==0 then return parsed end
    parsed.comments_by_range[to_key]=items
    parsed.comments_by_range[from_key]=nil
    if parsed.diagnostics then
        parsed.diagnostics[to_key]=parsed.diagnostics[from_key]
        parsed.diagnostics[from_key]=nil
    end
    parsed.returned[to_key]=true
    return parsed
end

local function request_map(batch)
    local out={}
    for _,request in ipairs(type(batch)=="table" and batch or {}) do
        local key=range_key(request)
        if key~="" then out[key]=request end
    end
    return out
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

local function comment_identity(item)
    local id=tostring(item.review_id or "")
    if id~="" then return "id:"..id end
    return "text:"..tostring(item.content or "").."\0"..tostring(item.author or "")
end

local function merge_items(target,seen,items)
    for _,item in ipairs(items or {}) do
        local identity=comment_identity(item)
        if not seen[identity] then
            seen[identity]=true
            target[#target+1]=item
        end
    end
end

local function parse_transport(value,batch,source,book_id,chapter_uid)
    local rows,response_shape=response_rows(value)
    local wanted=request_map(batch)
    local result={
        source=source,
        rows=rows,
        returned={},
        comments_by_range={},
        diagnostics={},
        comment_count=0,
        missing={},
        invalid=tonumber(response_shape.invalid or 0) or 0,
    }

    for index,group in ipairs(rows) do
        local key=range_key(group)
        if key~="" and wanted[key] then
            result.returned[key]=true
            local comments,diag=review_texts_v53(group)
            result.diagnostics[key]=diag
            if #comments>0 then
                result.comments_by_range[key]=comments
                result.comment_count=result.comment_count+#comments
            end
            result.invalid=result.invalid+(tonumber(diag.invalid or 0) or 0)

            -- Safe structural diagnostic: keys/counts only, never comment text,
            -- author, cookie or token.
            if index<=3 or #comments>0 then
                logger.info("[MiuRead][CommentParse]",
                    "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
                    "source=",tostring(source),"range_index=",tostring(index),
                    "group_keys=",tostring(diag.keys),
                    "container=",tostring(diag.container),
                    "shape=",tostring(diag.shape),
                    "pages=",tostring(diag.page_count),
                    "nested_review=",tostring(diag.nested_count),
                    "parsed=",tostring(#comments),
                    "totalCount=",tostring(diag.total_count or ""),
                    "bookMarkCount=",tostring(diag.bookmark_count or ""),
                    "maxIdx=",tostring(diag.max_idx or ""),
                    "synckey=",tostring(diag.synckey or ""),
                    "hasMore=",bool_text(diag.has_more),
                    "hasNext=",bool_text(diag.has_next),
                    "isEnd=",bool_text(diag.is_end),
                    "invalid=",tostring(diag.invalid))
            end
        end
    end

    for _,request in ipairs(batch or {}) do
        local key=range_key(request)
        if key~="" and not result.returned[key] then result.missing[#result.missing+1]=key end
    end

    logger.info("[MiuRead][CommentParse] response",
        "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
        "source=",tostring(source),
        "response_keys=",tostring(response_shape.keys),
        "container=",tostring(response_shape.container),
        "shape=",tostring(response_shape.shape),
        "requested=",tostring(#(batch or {})),
        "groups=",tostring(#rows),
        "returned=",tostring(#(batch or {})-#result.missing),
        "comments=",tostring(result.comment_count),
        "missing=",tostring(#result.missing),
        "invalid=",tostring(result.invalid))

    return result
end

local function request_web(api,book_id,chapter_uid,batch)
    local ok,value=pcall(api._web_readreviews,api,book_id,chapter_uid,batch)
    if ok and type(value)=="table" then
        value._annotation_source="web"
        return value
    end
    return nil,ok and "web readReviews returned invalid data" or tostring(value)
end

local function request_agent(api,book_id,chapter_uid,batch)
    local ok,value=pcall(api._agent_readreviews,api,book_id,chapter_uid,batch)
    if ok and type(value)=="table" then
        value._annotation_source="agent_fallback"
        return value
    end
    return nil,ok and "Gateway returned invalid review data" or tostring(value)
end

local function split_batch(batch)
    local middle=math.floor(#batch/2)
    local left,right={},{}
    for index,item in ipairs(batch) do
        if index<=middle then left[#left+1]=item else right[#right+1]=item end
    end
    return left,right
end

local function batch_for_keys(batch,wanted)
    local out={}
    for _,request in ipairs(batch or {}) do
        local key=range_key(request)
        if key~="" and wanted[key] then out[#out+1]=request end
    end
    return out
end

local function unresolved_keys(batch,parsed)
    local unresolved={}
    for _,request in ipairs(batch or {}) do
        local key=range_key(request)
        if key~="" then
            local comments=parsed.comments_by_range[key]
            if type(comments)~="table" or #comments==0 then unresolved[key]=true end
        end
    end
    return unresolved
end

function Fetcher.fetch(api,book_id,chapter_uid,ranges,progress,options)
    progress=type(progress)=="function" and progress or function() end
    ranges=type(ranges)=="table" and ranges or {}
    options=type(options)=="table" and options or {}

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

    local by_range,seen_by_range={},{}
    local completed,pending={},{}
    local errors={}
    local last_error_kind
    local source_counts={web=0,agent_fallback=0,fresh_web=0,fresh_agent=0}
    local diagnostic_by_range={}
    local ab_diagnostic=nil
    for _,range in ipairs(ranges) do
        range=tostring(range or "")
        if range~="" then pending[range]=true end
    end

    local function merge_parsed(parsed)
        for key,diag in pairs(type(parsed.diagnostics)=="table" and parsed.diagnostics or {}) do
            diagnostic_by_range[key]=diag
        end
        for key,items in pairs(parsed.comments_by_range or {}) do
            by_range[key]=by_range[key] or {}
            seen_by_range[key]=seen_by_range[key] or {}
            merge_items(by_range[key],seen_by_range[key],items)
            if #by_range[key]>0 then
                completed[key]=true
                pending[key]=nil
            end
        end
    end

    local function process_batch(batch,label,depth)
        depth=tonumber(depth) or 0
        progress("thoughts",0,0,label)

        local web_value,web_error=request_web(api,book_id,chapter_uid,batch)
        local web_parsed
        if web_value then
            source_counts.web=source_counts.web+1
            web_parsed=parse_transport(web_value,batch,"web",book_id,chapter_uid)
            merge_parsed(web_parsed)
        elseif is_data_specific_failure(web_error) and #batch>1 and depth<6 then
            local left,right=split_batch(batch)
            logger.warn("[MiuRead][CommentFetch] web batch rejected; reducing size",
                "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
                "from=",tostring(#batch),"left=",tostring(#left),"right=",tostring(#right))
            local a=process_batch(left,label..".1",depth+1)
            local b=process_batch(right,label..".2",depth+1)
            return a and b
        else
            errors[#errors+1]="web: "..tostring(web_error)
            last_error_kind=error_kind(web_error)
        end

        -- beta.1 showed the exact failure we care about: Web returned every
        -- requested range but parsed zero real comments. In beta.2, zero parsed
        -- content is never accepted as "empty". Retry only unresolved ranges
        -- through the proven Gateway transport and run the same v5.3 parser.
        local unresolved={}
        if web_parsed then unresolved=unresolved_keys(batch,web_parsed)
        else
            for _,request in ipairs(batch) do
                local key=range_key(request)
                if key~="" then unresolved[key]=true end
            end
        end
        local agent_batch=batch_for_keys(batch,unresolved)

        if #agent_batch>0 then
            logger.warn("[MiuRead][CommentFetch] unresolved web ranges; trying Gateway",
                "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
                "ranges=",tostring(#agent_batch),
                "web_comments=",tostring(web_parsed and web_parsed.comment_count or 0))
            local agent_value,agent_error=request_agent(api,book_id,chapter_uid,agent_batch)
            if agent_value then
                source_counts.agent_fallback=source_counts.agent_fallback+1
                local agent_parsed=parse_transport(
                    agent_value,agent_batch,"agent_fallback",book_id,chapter_uid)
                merge_parsed(agent_parsed)
                if agent_parsed.comment_count==0 then
                    errors[#errors+1]="Gateway returned ranges but no comment rows"
                    last_error_kind=last_error_kind or "parser_unknown"
                end
            else
                errors[#errors+1]="agent: "..tostring(agent_error)
                last_error_kind=last_error_kind or error_kind(agent_error)
            end
        end

        return true
    end

    for index,batch in ipairs(batches) do
        progress("thoughts",index,#batches,"")
        process_batch(batch,"comments batch "..tostring(index),0)
    end


    -- 5.5.0-beta.3 A/B diagnosis:
    -- Only one unresolved range per chapter is tested. The ordinary A path has
    -- already used the same raw _web_readreviews request construction as v5.3.
    -- B asks underlines again immediately, compares the fresh WeRead range with
    -- the persisted locator, then issues that same raw request once more.
    if options.ab_diagnostic~=false then
        local target
        local pending_keys={}
        for key in pairs(pending) do pending_keys[#pending_keys+1]=key end
        table.sort(pending_keys)
        target=pending_keys[1]

        if target then
            local locator=locator_for_range(options.locators,target)
            local a_diag=diagnostic_by_range[target] or {}
            ab_diagnostic={
                target_range_fp=range_fingerprint(target),
                request_fp=request_fingerprint(book_id,chapter_uid,target),
                a_comments=type(by_range[target])=="table" and #by_range[target] or 0,
                a_total_count=a_diag.total_count,
                a_bookmark_count=a_diag.bookmark_count,
                a_max_idx=a_diag.max_idx,
                a_synckey=a_diag.synckey,
                a_has_more=a_diag.has_more,
                result="not_run",
            }

            logger.info("[MiuRead][ReviewAB] A",
                "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
                "range_fp=",ab_diagnostic.target_range_fp,
                "request_fp=",ab_diagnostic.request_fp,
                "comments=",tostring(ab_diagnostic.a_comments),
                "totalCount=",tostring(a_diag.total_count or ""),
                "bookMarkCount=",tostring(a_diag.bookmark_count or ""),
                "maxIdx=",tostring(a_diag.max_idx or ""),
                "synckey=",tostring(a_diag.synckey or ""),
                "hasMore=",bool_text(a_diag.has_more))

            progress("thoughts",0,0,"A/B：重新读取划线")
            local fresh_rows,fresh_error,fresh_shape=fresh_underlines(
                api,book_id,chapter_uid)

            if type(fresh_rows)~="table" then
                ab_diagnostic.result="fresh_underlines_failed"
                ab_diagnostic.error=tostring(fresh_error or "")
                logger.warn("[MiuRead][ReviewAB] fresh underlines failed",
                    "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
                    "error=",tostring(fresh_error))
            else
                local fresh_row,method,safe_map,fresh_index=
                    fresh_match(locator,fresh_rows,target)
                local fresh_key=range_key(fresh_row)
                local same=fresh_key~="" and fresh_key==target

                ab_diagnostic.fresh_underlines=#fresh_rows
                ab_diagnostic.fresh_invalid=fresh_shape and fresh_shape.invalid or 0
                ab_diagnostic.match_method=method
                ab_diagnostic.same_range=same
                ab_diagnostic.fresh_range_fp=fresh_key~="" and range_fingerprint(fresh_key) or ""
                ab_diagnostic.fresh_index=fresh_index
                ab_diagnostic.safe_map=safe_map==true

                logger.info("[MiuRead][ReviewAB] range compare",
                    "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
                    "locator_fp=",range_fingerprint(target),
                    "fresh_fp=",fresh_key~="" and range_fingerprint(fresh_key) or "",
                    "same=",tostring(same),
                    "method=",tostring(method),
                    "safe_map=",tostring(safe_map==true),
                    "fresh_underlines=",tostring(#fresh_rows),
                    "fresh_source=",tostring(fresh_shape and fresh_shape.source or ""),
                    "fresh_invalid=",tostring(fresh_shape and fresh_shape.invalid or 0))

                if fresh_key=="" then
                    ab_diagnostic.result="fresh_range_unmatched"
                else
                    local one={{range=fresh_key,maxIdx=0,count=30,synckey=0}}
                    progress("thoughts",0,0,"A/B：fresh range 请求评论")

                    local b_value,b_error=request_web(api,book_id,chapter_uid,one)
                    local b_parsed
                    if b_value then
                        source_counts.fresh_web=source_counts.fresh_web+1
                        b_parsed=parse_transport(
                            b_value,one,"fresh_web",book_id,chapter_uid)
                    end

                    if not b_parsed or b_parsed.comment_count==0 then
                        local agent_value,agent_error=request_agent(
                            api,book_id,chapter_uid,one)
                        if agent_value then
                            source_counts.fresh_agent=source_counts.fresh_agent+1
                            local agent_parsed=parse_transport(
                                agent_value,one,"fresh_agent",book_id,chapter_uid)
                            if not b_parsed or agent_parsed.comment_count>0 then
                                b_parsed=agent_parsed
                            end
                        elseif not b_parsed then
                            b_error=agent_error or b_error
                        end
                    end

                    local b_comments=b_parsed and
                        tonumber(b_parsed.comment_count or 0) or 0
                    local b_diag=b_parsed and
                        b_parsed.diagnostics and
                        b_parsed.diagnostics[fresh_key] or {}

                    ab_diagnostic.b_comments=b_comments
                    ab_diagnostic.b_total_count=b_diag and b_diag.total_count or nil
                    ab_diagnostic.b_bookmark_count=b_diag and b_diag.bookmark_count or nil
                    ab_diagnostic.b_max_idx=b_diag and b_diag.max_idx or nil
                    ab_diagnostic.b_synckey=b_diag and b_diag.synckey or nil
                    ab_diagnostic.b_has_more=b_diag and b_diag.has_more or nil

                    logger.info("[MiuRead][ReviewAB] B",
                        "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
                        "range_fp=",range_fingerprint(fresh_key),
                        "same=",tostring(same),
                        "method=",tostring(method),
                        "comments=",tostring(b_comments),
                        "totalCount=",tostring(b_diag and b_diag.total_count or ""),
                        "bookMarkCount=",tostring(b_diag and b_diag.bookmark_count or ""),
                        "maxIdx=",tostring(b_diag and b_diag.max_idx or ""),
                        "synckey=",tostring(b_diag and b_diag.synckey or ""),
                        "hasMore=",bool_text(b_diag and b_diag.has_more))

                    if b_comments>0 then
                        if same then
                            merge_parsed(b_parsed)
                            ab_diagnostic.result="fresh_context_success"
                            if last_error_kind=="parser_unknown"
                                or last_error_kind=="review_empty_response" then
                                last_error_kind=nil
                            end
                        elseif safe_map==true then
                            rekey_parsed(b_parsed,fresh_key,target)
                            merge_parsed(b_parsed)
                            ab_diagnostic.result="locator_range_mismatch_confirmed"
                            if last_error_kind=="parser_unknown"
                                or last_error_kind=="review_empty_response" then
                                last_error_kind=nil
                            end
                        else
                            ab_diagnostic.result="fresh_comments_unmapped"
                        end
                    elseif same then
                        ab_diagnostic.result="same_range_still_empty"
                    else
                        ab_diagnostic.result="range_mismatch_fresh_empty"
                    end

                    if b_error and b_comments==0 then
                        ab_diagnostic.error=tostring(b_error)
                    end
                end

                logger.info("[MiuRead][ReviewAB] result",
                    "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
                    "result=",tostring(ab_diagnostic.result),
                    "same=",tostring(ab_diagnostic.same_range),
                    "method=",tostring(ab_diagnostic.match_method or ""),
                    "a_comments=",tostring(ab_diagnostic.a_comments or 0),
                    "b_comments=",tostring(ab_diagnostic.b_comments or 0))
            end
        end
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

    local pending_ranges,completed_ranges={},{}
    for key in pairs(pending) do pending_ranges[#pending_ranges+1]=key end
    for key in pairs(completed) do completed_ranges[#completed_ranges+1]=key end
    table.sort(pending_ranges)
    table.sort(completed_ranges)

    -- beta.2 deliberately has NO automatic zero-comment completion.
    -- A chapter is complete only when every requested range produced at least
    -- one real parsed comment. This is intentionally conservative for one beta.
    local complete=#ranges>0 and #pending_ranges==0 and comment_count>0
    if comment_count==0 and not last_error_kind then last_error_kind="review_empty_response" end

    logger.info("[MiuRead][CommentFetch] chapter finished",
        "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
        "ranges=",tostring(#ranges),
        "comments=",tostring(comment_count),
        "completed=",tostring(#completed_ranges),
        "pending=",tostring(#pending_ranges),
        "complete=",tostring(complete),
        "web_batches=",tostring(source_counts.web or 0),
        "agent_batches=",tostring(source_counts.agent_fallback or 0),
        "fresh_web=",tostring(source_counts.fresh_web or 0),
        "fresh_agent=",tostring(source_counts.fresh_agent or 0),
        "ab_result=",tostring(ab_diagnostic and ab_diagnostic.result or ""))

    return {
        groups=groups,
        comments=comment_count,
        completed_ranges=completed_ranges,
        pending_ranges=pending_ranges,
        empty_ranges={},
        complete=complete,
        empty_confirmed=false,
        errors=errors,
        error_kind=last_error_kind,
        source_counts=source_counts,
        ab_diagnostic=ab_diagnostic,
    }
end

return Fetcher
