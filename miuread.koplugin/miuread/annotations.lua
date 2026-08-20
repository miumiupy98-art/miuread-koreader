local logger = require("logger")
local Thoughts = require("miuread.thoughts")
local Http = require("miuread.http")
local U = require("miuread.util")
local AnnotationCoord = require("miuread.annotation_coord")
local PosMap = require("miuread.annotations.posmap")
local Range = require("miuread.annotations.range")
local ok_socket, socket = pcall(require, "socket")

local Annotations = {}
Annotations.__index = Annotations

local AnnotationStyle = require("miuread.annotation_style")
local CSS = AnnotationStyle.CSS

local function pause(seconds)
    if ok_socket and socket and type(socket.sleep) == "function" then socket.sleep(seconds) end
end

local function is_network_failure(value)
    local text=tostring(value or ""):lower()
    return text:find("network request failed",1,true)~=nil
        or text:find("timeout",1,true)~=nil
        or text:find("connection refused",1,true)~=nil
        or text:find("network is unreachable",1,true)~=nil
end

local function call_with_retry(label, fn)
    local last
    for attempt = 1, 2 do
        local ok, value = pcall(fn)
        if ok and type(value) == "table" then return true, value, false end
        last = ok and (label .. " returned invalid data") or tostring(value)
        if Http.is_auth_error(last) then return false,last,false,"authentication" end
        if Http.is_rate_limit_error(last) then return false,last,false,"rate_limit" end
        if Http.is_forbidden_error(last) then return false,last,false,"forbidden" end
        local network_down=is_network_failure(last)
        if network_down and attempt == 1 then
            logger.warn("[MiuRead][Annotations] network retry", "label=", label, "error=", tostring(last))
            pause(2.0)
        else
            return false,last,network_down,nil
        end
    end
    return false,last,is_network_failure(last),nil
end


local function is_data_specific_failure(value)
    local text=tostring(value or ""):lower()
    return text:find("params error",1,true)~=nil
        or text:find("invalid range",1,true)~=nil
        or text:find("invalid parameter",1,true)~=nil
        or text:find("range error",1,true)~=nil
end

local function str(v) return v == nil and "" or tostring(v) end
local function scalar_str(v)
    local kind=type(v)
    if kind=="string" or kind=="number" then return tostring(v) end
    return ""
end

local function range_key(v)
    if type(v) ~= "table" then return "" end
    return scalar_str(rawget(v,"range") or rawget(v,"markRange") or rawget(v,"bookmarkRange"))
end

local function array_from(data, names)
    if type(data) ~= "table" then return {} end
    for _, name in ipairs(names) do if type(data[name]) == "table" then return data[name] end end
    if #data > 0 then return data end
    return {}
end

local function table_entries(data)
    local rows, invalid = {}, 0
    if type(data) ~= "table" then return rows, invalid end
    for _, value in ipairs(data) do
        if type(value) == "table" then
            rows[#rows + 1] = value
        else
            invalid = invalid + 1
        end
    end
    return rows, invalid
end

local function legacy_parse_range(value)
    local a, b = str(value):match("^(%d+)%-(%d+)$")
    a, b = tonumber(a), tonumber(b)
    if not a or not b or b <= a then return nil end
    return a, b
end

local function review_rows_from_response(data)
    if type(data) ~= "table" then return {} end
    local raw
    for _, name in ipairs({"reviews", "updated", "reviewList", "items"}) do
        if type(data[name]) == "table" then raw = data[name]; break end
    end
    if not raw and #data > 0 then raw = data end
    if type(raw) ~= "table" then return {} end

    local rows = {}
    if #raw > 0 then
        for _, item in ipairs(raw) do
            if type(item) == "table" then rows[#rows + 1] = item end
        end
        return rows
    end
    for key, item in pairs(raw) do
        if type(item) == "table" then
            local row = item
            local range = range_key(row)
            if range == "" and tostring(key):match("^%d+%-%d+$") then
                row = U.copy(item)
                row.range = tostring(key)
            end
            rows[#rows + 1] = row
        end
    end
    return rows
end

local function collect_review_pages(group)
    local pages, seen = {}, {}
    local queue = { group }
    local cursor = 1
    local scanned = 0
    local function push(page)
        if type(page) ~= "table" or seen[page] then return end
        seen[page] = true
        pages[#pages + 1] = page
    end
    while cursor <= #queue and scanned < 256 do
        local node = queue[cursor]
        cursor = cursor + 1
        scanned = scanned + 1
        if type(node) == "table" then
            local direct = array_from(node, {"pageReviews", "reviews", "updated", "reviewList", "items", "list"})
            for _, item in ipairs(direct or {}) do
                if type(item) == "table" then push(item) end
            end
            if rawget(node, "review") ~= nil or rawget(node, "content") ~= nil
                or rawget(node, "abstract") ~= nil or rawget(node, "text") ~= nil then
                push(node)
            end
            for _, nested in pairs(node) do
                if type(nested) == "table" and not seen[nested] and #queue < 384 then
                    queue[#queue + 1] = nested
                end
            end
        end
    end
    return pages
end

local function review_texts(group,yield_check)
    local rows, seen, invalid = {}, {}, 0
    local pages = collect_review_pages(group)
    for page_index, page in ipairs(pages) do
        if yield_check and page_index%64==0 then yield_check() end
        ingest_page(page)
    end
    return rows, invalid
end

function Annotations:new(api) return setmetatable({api = api}, self) end

function Annotations:fetch_chapter(book_id, uid, progress, options)
    options=type(options)=="table" and options or {}
    local previous=type(options.previous)=="table" and options.previous or nil
    local checkpoint=type(options.checkpoint)=="function" and options.checkpoint or nil
    progress=progress or function() end

    if previous and previous.complete==true and options.force_refresh~=true then
        previous.cached=true
        return previous
    end

    local result={book_id=str(book_id),chapter_uid=str(uid),underlines={},review_map={},review_groups={},
        underline_count=0,thought_count=0,thought_entry_count=0,errors={},underline_request_ok=false,
        underlines_partial=false,completed_ranges={},pending_ranges={},review_complete=false,complete=false}

    local reuse_pending=previous and previous.underline_request_ok==true
        and previous.underlines_partial~=true and #(previous.underlines or {})>0
        and #(previous.pending_ranges or {})>0
    if reuse_pending then
        result.underlines=previous.underlines
        result.underline_count=#result.underlines
        result.underline_request_ok=true
        progress("underlines",result.underline_count,result.underline_count,"继续未完成的想法")
    else
        local ok,data,network_down,error_kind=call_with_retry("underlines",function()
            return self.api:underlines(book_id,uid)
        end)
        if not ok then
            local err=str(data)
            result.errors[#result.errors+1]=err
            result.auth_required=error_kind=="authentication"
            result.forbidden=error_kind=="forbidden"
            result.rate_limited=error_kind=="rate_limit"
            result.error_kind=error_kind or (network_down and "network") or "server"
            logger.warn("[MiuRead][Annotations] underlines failed","book=",result.book_id,
                "chapter=",result.chapter_uid,"kind=",tostring(result.error_kind),"error=",err)
            return result
        end

        result.underline_request_ok=true
        local invalid_underlines
        result.underlines,invalid_underlines=table_entries(array_from(data,{"underlines","updated","bookmarks"}))
        result.underline_count=#result.underlines
        if invalid_underlines>0 then
            result.underlines_partial=true
            result.error_kind=result.error_kind or "data"
            result.errors[#result.errors+1]="underline response contained invalid entries"
            logger.warn("[MiuRead][Annotations] ignored invalid underline entries",
                "book=",result.book_id,"chapter=",result.chapter_uid,"count=",tostring(invalid_underlines))
        end
        progress("underlines",result.underline_count,result.underline_count,"")
    end

    local active_ranges,active_seen={},{ }
    for _,row in ipairs(result.underlines) do
        local key=range_key(row)
        if key~="" and not active_seen[key] then active_seen[key]=true; active_ranges[#active_ranges+1]=key end
    end
    if #active_ranges==0 then
        result.review_complete=true
        result.complete=result.underline_request_ok and result.underlines_partial~=true
        return result
    end

    local target_ranges={}
    if reuse_pending then
        for _,key in ipairs(previous.pending_ranges or {}) do
            key=tostring(key or "")
            if key~="" and active_seen[key] then target_ranges[#target_ranges+1]=key end
        end
    else
        target_ranges=active_ranges
    end
    if #target_ranges==0 then
        result.review_complete=true
        result.complete=result.underline_request_ok and result.underlines_partial~=true
        return result
    end

    local review_batch_size=math.max(1,math.min(30,tonumber(options.review_batch_size) or 5))
    local batches=self.api:review_batches(target_ranges,review_batch_size)
    local completed,pending={},{}
    local review_map={}
    local group_count,entry_count,invalid_review_count=0,0,0
    for _,key in ipairs(target_ranges) do pending[tostring(key)]=true end

    local function mark_batch_completed(batch)
        for _,item in ipairs(batch or {}) do
            local key=range_key(item)
            if key~="" then pending[key]=nil; completed[key]=true end
        end
    end
    local active_batch_index=0
    local function merge_review_rows(rows, batch)
        local new_invalid=0
        local new_entries=0
        for group_index,group in ipairs(rows or {}) do
            if group_index%8==0 then progress("thoughts",active_batch_index,#batches,"整理想法") end
            local key=range_key(group)
            if key=="" and type(batch)=="table" then
                local hint=batch[group_index]
                key=range_key(hint) or scalar_str(hint and hint.range)
                if key~="" and type(group)=="table" then group.range=key end
            end
            if key~="" then
                local texts,invalid=review_texts(group,function()
                    progress("thoughts",active_batch_index,#batches,"整理想法")
                end)
                new_invalid=new_invalid+invalid
                if #texts>0 then
                    if not review_map[key] then review_map[key]={}; group_count=group_count+1 end
                    for _,item in ipairs(texts) do review_map[key][#review_map[key]+1]=item end
                    entry_count=entry_count+#texts
                    new_entries=new_entries+#texts
                end
            else
                new_invalid=new_invalid+1
            end
        end
        invalid_review_count=invalid_review_count+new_invalid
        return new_invalid,new_entries
    end
    local function rebuild_state()
        result.review_map=review_map
        result.review_groups={}
        for key,texts in pairs(review_map) do result.review_groups[#result.review_groups+1]={range=key,texts=texts} end
        table.sort(result.review_groups,function(a,b) return tostring(a.range)<tostring(b.range) end)
        result.thought_count=group_count
        result.thought_entry_count=entry_count
        result.completed_ranges={}
        result.pending_ranges={}
        for key in pairs(completed) do result.completed_ranges[#result.completed_ranges+1]=key end
        for key in pairs(pending) do result.pending_ranges[#result.pending_ranges+1]=key end
        table.sort(result.completed_ranges)
        table.sort(result.pending_ranges)
        result.review_complete=#result.pending_ranges==0
        result.complete=result.underline_request_ok and result.underlines_partial~=true and result.review_complete
        result.invalid_review_count=invalid_review_count
    end
    local function save_checkpoint()
        rebuild_state()
        if checkpoint then
            local ok,err=pcall(checkpoint,result)
            if not ok then error("无法保存批注断点："..tostring(err)) end
        end
    end

    local function accept_response(batch,response,label)
        local rows = review_rows_from_response(response)
        local invalid = 0
        local entry_invalid,new_entries=merge_review_rows(rows, batch)
        logger.warn("[MiuRead][Annotations] readreviews payload",
            "book=",result.book_id,"chapter=",result.chapter_uid,
            "batch=",tostring(active_batch_index),"/",tostring(#batches),
            "ranges=",tostring(#(batch or {})),
            "rows=",tostring(#rows),
            "entries=",tostring(new_entries),
            "invalid=",tostring(invalid+entry_invalid),
            "source=",tostring(response and response._annotation_source or "unknown"))
        if new_entries == 0 and #rows > 0 and type(rows[1]) == "table" then
            local keys = {}
            for key in pairs(rows[1]) do keys[#keys + 1] = tostring(key) end
            table.sort(keys)
            logger.warn("[MiuRead][Annotations] readreviews row shape",
                "book=", result.book_id, "chapter=", result.chapter_uid,
                "keys=", table.concat(keys, ","),
                "pageReviews=", tostring(type(rows[1].pageReviews) == "table" and #rows[1].pageReviews or 0))
        end
        if #rows==0 and #(batch or {})>0 then
            logger.warn("[MiuRead][Annotations] readreviews empty payload",
                "book=",result.book_id,"chapter=",result.chapter_uid,
                "batch=",tostring(#batch),"label=",tostring(label or ""))
        end
        local skipped = entry_invalid
        if skipped > 0 then
            result.error_kind = result.error_kind or "data"
            result.errors[#result.errors + 1] = tostring(label) .. " skipped malformed review entries"
            invalid_review_count = invalid_review_count + entry_invalid
        end
        -- A successful response is complete even when a malformed optional
        -- review entry was skipped. Keeping the whole range pending caused
        -- the same data to be fetched and normalized indefinitely.
        mark_batch_completed(batch)
        save_checkpoint()
    end

    local function split_batch(batch)
        local middle=math.floor(#batch/2)
        local left,right={},{}
        for index,item in ipairs(batch) do
            if index<=middle then left[#left+1]=item else right[#right+1]=item end
        end
        return left,right
    end

    local function fetch_adaptive(batch,label,depth)
        depth=tonumber(depth) or 0
        progress("thoughts",active_batch_index,#batches,
            depth>0 and ("缩小想法批次至 "..tostring(#batch)) or "")
        local good,response,network_down,error_kind=call_with_retry(label,function()
            return self.api:readreviews(book_id,uid,batch)
        end)
        if good then
            accept_response(batch,response,label)
            return true,false
        end

        if is_data_specific_failure(response) and #batch>1 then
            local left,right=split_batch(batch)
            logger.warn("[MiuRead][Annotations] thoughts batch rejected; reducing size",
                "book=",result.book_id,"chapter=",result.chapter_uid,
                "from=",tostring(#batch),"left=",tostring(#left),"right=",tostring(#right))
            local left_ok,left_stop=fetch_adaptive(left,label..".1",depth+1)
            if left_stop then return false,true end
            local right_ok,right_stop=fetch_adaptive(right,label..".2",depth+1)
            return left_ok and right_ok,right_stop
        end

        result.errors[#result.errors+1]=tostring(label)..": "..str(response)
        if is_data_specific_failure(response) then
            result.error_kind=result.error_kind or "data"
            save_checkpoint()
            return false,false
        end

        if error_kind=="rate_limit" and depth<4 then
            local wait=6.0+depth*4
            logger.warn("[MiuRead][Annotations] thoughts batch rate limited; retrying",
                "book=",result.book_id,"chapter=",result.chapter_uid,
                "batch=",tostring(#batch),"wait_s=",tostring(wait))
            pause(wait)
            return fetch_adaptive(batch,label,depth+1)
        end

        result.error_kind=error_kind or (network_down and "network") or "server"
        result.auth_required=error_kind=="authentication"
        result.forbidden=error_kind=="forbidden"
        result.rate_limited=error_kind=="rate_limit"
        logger.warn("[MiuRead][Annotations] thoughts batch deferred","book=",result.book_id,
            "chapter=",result.chapter_uid,"batch=",tostring(active_batch_index),"/",tostring(#batches),
            "ranges=",tostring(#batch),"kind=",tostring(result.error_kind))
        save_checkpoint()
        return false,true
    end

    for index,batch in ipairs(batches) do
        active_batch_index=index
        progress("thoughts",index,#batches,"")
        local _,stop=fetch_adaptive(batch,"thoughts batch "..tostring(index),0)
        if stop then break end
    end

    rebuild_state()
    if invalid_review_count>0 then
        logger.warn("[MiuRead][Annotations] malformed review entries skipped",
            "book=",result.book_id,"chapter=",result.chapter_uid,"count=",tostring(invalid_review_count))
    end
    logger.warn("[MiuRead][Annotations] chapter fetched","book=",result.book_id,"chapter=",result.chapter_uid,
        "underlines=",result.underline_count,"thought_groups=",result.thought_count,
        "thought_entries=",result.thought_entry_count,"pending_ranges=",#result.pending_ranges)
    return result
end

local function utf8_len_at(text, i)
    local c = text:byte(i)
    if not c or c < 0x80 then return 1 end
    if c < 0xE0 then return 2 end
    if c < 0xF0 then return 3 end
    return 4
end

local NAMED_ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
    nbsp = " ", ensp = " ", emsp = " ", thinsp = " ",
    hellip = "…", mdash = "—", ndash = "–",
    lsquo = "‘", rsquo = "’", ldquo = "“", rdquo = "”",
    zwnj = "", zwj = "",
}

local function utf8_encode(codepoint)
    codepoint = tonumber(codepoint)
    if not codepoint or codepoint < 0 or codepoint > 0x10FFFF
        or (codepoint >= 0xD800 and codepoint <= 0xDFFF) then
        return nil
    end
    if codepoint < 0x80 then
        return string.char(codepoint)
    elseif codepoint < 0x800 then
        return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + (codepoint % 0x40))
    elseif codepoint < 0x10000 then
        return string.char(
            0xE0 + math.floor(codepoint / 0x1000),
            0x80 + (math.floor(codepoint / 0x40) % 0x40),
            0x80 + (codepoint % 0x40)
        )
    end
    return string.char(
        0xF0 + math.floor(codepoint / 0x40000),
        0x80 + (math.floor(codepoint / 0x1000) % 0x40),
        0x80 + (math.floor(codepoint / 0x40) % 0x40),
        0x80 + (codepoint % 0x40)
    )
end

local function decode_html_unit(unit)
    unit = tostring(unit or "")
    local decimal = unit:match("^&#(%d+);$")
    if decimal then return utf8_encode(tonumber(decimal, 10)) or unit end
    local hexadecimal = unit:match("^&#[xX]([%x]+);$")
    if hexadecimal then return utf8_encode(tonumber(hexadecimal, 16)) or unit end
    local named = unit:match("^&([%w]+);$")
    if named and NAMED_ENTITIES[named] ~= nil then return NAMED_ENTITIES[named] end
    return unit
end

local function split_units(raw)
    local units, p = {}, 1
    while p <= #raw do
        local entity = raw:sub(p):match("^&[#%w]+;")
        if entity then
            units[#units + 1] = entity
            p = p + #entity
        else
            local n = utf8_len_at(raw, p)
            units[#units + 1] = raw:sub(p, p + n - 1)
            p = p + n
        end
    end
    return units
end

local function is_ignorable_text(value)
    if value == nil or value == "" then return true end
    if value:match("^%s+$") then return true end
    return value == "\194\160"       -- non-breaking space
        or value == "\227\128\128" -- ideographic space
        or value == "\226\128\139" -- zero-width space
        or value == "\226\128\140" -- zero-width non-joiner
        or value == "\226\128\141" -- zero-width joiner
        or value == "\239\187\191" -- UTF-8 BOM
end

local SKIP_TEXT_TAGS = {
    script = true, style = true, noscript = true, template = true, svg = true,
}

local function tag_info(raw)
    local slash, name = tostring(raw or ""):match("^<%s*(/?)%s*([%w:_%-]+)")
    if not name then return false, "", false end
    return slash == "/", name:lower(), tostring(raw):match("/%s*>$") ~= nil
end

local function tokenize(html)
    local tokens, visible = {}, 0
    local i, skip_depth, anchor_depth = 1, 0, 0
    while i <= #html do
        if html:sub(i, i) == "<" then
            local j = html:find(">", i + 1, true)
            if not j then
                local raw = html:sub(i)
                tokens[#tokens + 1] = {
                    kind="text", raw=raw, units=split_units(raw), start=visible,
                    skip=skip_depth > 0, inside_anchor=anchor_depth > 0,
                }
                if skip_depth == 0 then visible = visible + #tokens[#tokens].units end
                break
            end
            local raw = html:sub(i, j)
            local closing, name, self_closing = tag_info(raw)
            if closing and name == "a" then anchor_depth = math.max(0, anchor_depth - 1) end
            tokens[#tokens + 1] = {kind="tag", raw=raw}
            if closing and SKIP_TEXT_TAGS[name] then
                skip_depth = math.max(0, skip_depth - 1)
            elseif not closing and not self_closing and SKIP_TEXT_TAGS[name] then
                skip_depth = skip_depth + 1
            end
            if not closing and not self_closing and name == "a" then anchor_depth = anchor_depth + 1 end
            i = j + 1
        else
            local j = html:find("<", i, true) or (#html + 1)
            local raw = html:sub(i, j - 1)
            local units = split_units(raw)
            local skipped = skip_depth > 0
            tokens[#tokens + 1] = {
                kind="text", raw=raw, units=units, start=visible,
                stop=skipped and visible or (visible + #units), skip=skipped,
                inside_anchor=anchor_depth > 0,
            }
            if not skipped then visible = visible + #units end
            i = j
        end
    end
    return tokens, visible
end

local function utf16_width(value)
    local first = tostring(value or ""):byte(1) or 0
    return first >= 0xF0 and 2 or 1
end

local function build_text_index(tokens)
    local pieces, starts, ends, ordinals = {}, {}, {}, {}
    local compact_bounds, utf16_bounds = {}, {}
    local byte_pos, compact_count, utf16_count = 1, 0, 0

    for _, token in ipairs(tokens or {}) do
        if token.kind == "text" and not token.skip then
            for index, unit in ipairs(token.units or {}) do
                local raw_pos = token.start + index - 1
                local decoded = decode_html_unit(unit)

                if utf16_bounds[utf16_count] == nil then utf16_bounds[utf16_count] = raw_pos end
                local width = utf16_width(decoded)
                if width > 1 then
                    for extra = 1, width - 1 do utf16_bounds[utf16_count + extra] = raw_pos end
                end
                utf16_count = utf16_count + width
                utf16_bounds[utf16_count] = raw_pos + 1

                if not is_ignorable_text(decoded) then
                    compact_bounds[compact_count] = compact_bounds[compact_count] or raw_pos
                    pieces[#pieces + 1] = decoded
                    starts[byte_pos] = raw_pos
                    ordinals[byte_pos] = compact_count
                    local end_byte = byte_pos + #decoded - 1
                    ends[end_byte] = raw_pos + 1
                    byte_pos = end_byte + 1
                    compact_count = compact_count + 1
                    compact_bounds[compact_count] = raw_pos + 1
                end
            end
        end
    end

    return {
        text = table.concat(pieces), starts = starts, ends = ends, ordinals = ordinals,
        compact_bounds = compact_bounds, compact_count = compact_count,
        utf16_bounds = utf16_bounds, utf16_count = utf16_count,
    }
end

local function normalize_text(value)
    local raw = tostring(value or ""):gsub("<[^>]+>", "")
    local out, count = {}, 0
    for _, unit in ipairs(split_units(raw)) do
        local decoded = decode_html_unit(unit)
        if not is_ignorable_text(decoded) then
            out[#out + 1] = decoded
            count = count + 1
        end
    end
    return table.concat(out), count
end

local function quote_candidates(row, data)
    local values, seen = {}, {}
    local function add(value)
        local normalized, count = normalize_text(value)
        if count >= 2 and count <= 800 and normalized ~= "" and not seen[normalized] then
            seen[normalized] = true
            values[#values + 1] = normalized
        end
    end

    row = type(row) == "table" and row or {}
    for _, key in ipairs({"markText", "bookmarkText", "rangeText", "abstract", "text", "content"}) do
        add(row[key])
    end
    local reviews = data and data.review_map and data.review_map[range_key(row)] or nil
    for _, review in ipairs(reviews or {}) do add(review.abstract) end
    return values
end

local function locate_quote(index, needle, expected)
    if not index or tostring(index.text or "") == "" or tostring(needle or "") == "" then return nil end
    local best_a, best_b, best_score
    local from = 1
    while true do
        local first, last = index.text:find(needle, from, true)
        if not first then break end
        local a, b = index.starts[first], index.ends[last]
        if a ~= nil and b ~= nil and b > a then
            local compact_a = index.ordinals[first] or a
            local score = math.min(math.abs(a - expected), math.abs(compact_a - expected))
            if best_score == nil or score < best_score then
                best_a, best_b, best_score = a, b, score
            end
        end
        from = first + 1
    end
    return best_a, best_b
end

local function official_interval(row, data, index, coord_map)
    if not coord_map then return nil, nil, "coord_missing" end
    local key = range_key(row)
    local resolved, resolve_error = AnnotationCoord.resolveRangeOnMap(coord_map, key)
    if not resolved then return nil, nil, resolve_error end
    -- /web/book/underlines may contain ordinary page bookmarks. A single-point
    -- range is valid server data, but it must never be rendered as an underline.
    if resolved.point then return nil, nil, "point_range" end

    local normalized, count = normalize_text(resolved.text)
    if count <= 0 or normalized == "" then return nil, nil, "empty_range_text" end

    -- coord_html and render_html differ in tags/resource URLs only. Locate the
    -- official range's text in the render stream instead of applying raw HTML
    -- offsets to already rewritten markup.
    local a, b = locate_quote(index, normalized, math.max(0, resolved.text_start - 1))
    if not a then return nil, nil, "render_bridge_failed" end

    local quotes = quote_candidates(row, data)
    local verified = #quotes == 0
    for _, quote in ipairs(quotes) do
        if quote == normalized then verified = true; break end
    end
    -- Phase 1 must not regress existing cloud annotations. When the server gives
    -- us markText/abstract, require the new coordinate path to agree with it; if
    -- it does not, fall back to the proven read-only legacy locator below.
    if #quotes > 0 and not verified then
        return nil, nil, "quote_mismatch"
    end

    -- A range -> text -> range diagnostic is intentionally non-fatal here.
    -- Download/render remains backward-compatible; upload will use this as a
    -- hard safety gate in the next phase.
    local before, after = AnnotationCoord.contextForSpan(
        coord_map, resolved.text_start, resolved.text_end_pos, 24)
    local roundtrip = PosMap.locate(coord_map, resolved.text, {
        context_before = before,
        context_after = after,
    })

    return a, b, nil, {
        verified = verified,
        roundtrip = roundtrip == key,
        text = resolved.text,
    }
end

local function numeric_interval(a, b, visible_count, index)
    -- WeRead ranges are generated by JavaScript and may use UTF-16 offsets.
    -- Mapping through decoded text preserves positions after emoji/non-BMP text.
    local mapped_a = index and index.utf16_bounds and index.utf16_bounds[a]
    local mapped_b = index and index.utf16_bounds and index.utf16_bounds[b]
    if mapped_a ~= nil and mapped_b ~= nil and mapped_b > mapped_a then
        return mapped_a, mapped_b
    end
    a, b = math.max(0, a), math.min(visible_count, b)
    if b > a then return a, b end
end

local function intervals(data, visible_count, index, coord_html)
    local out, unresolved, unresolved_seen = {}, {}, {}
    local stats = {
        official=0, official_verified=0, official_roundtrip=0, official_failed=0,
        quote_aligned=0, numeric=0, dropped=0, fallback=0,
    }
    local coord_map
    if tostring(coord_html or "") ~= "" then
        local ok, value = pcall(AnnotationCoord.build, coord_html)
        if ok and type(value) == "table" then coord_map = value
        else logger.warn("[MiuRead][Annotations] coord map build failed", tostring(value)) end
    end

    local function unresolved_item(row, reason)
        row = type(row) == "table" and row or {}
        local key = range_key(row)
        local dedupe = key ~= "" and ("range:" .. key) or ("row:" .. tostring(row))
        if unresolved_seen[dedupe] then return end
        unresolved_seen[dedupe] = true
        local quotes = quote_candidates(row, data)
        unresolved[#unresolved + 1] = {
            key=key,
            quote=quotes[1] or "",
            thought=key ~= "" and #(data.review_map[key] or {}) > 0,
            reason=reason,
        }
        stats.dropped = stats.dropped + 1
        stats.fallback = stats.fallback + 1
    end

    for _, row in ipairs(data.underlines or {}) do
        local key = range_key(row)
        local a, b
        local official_reason, official_meta
        if key ~= "" and coord_map then
            a, b, official_reason, official_meta = official_interval(row, data, index, coord_map)
            if a then
                stats.official = stats.official + 1
                if official_meta and official_meta.verified then
                    stats.official_verified = stats.official_verified + 1
                end
                if official_meta and official_meta.roundtrip then
                    stats.official_roundtrip = stats.official_roundtrip + 1
                end
            else
                stats.official_failed = stats.official_failed + 1
            end
        end

        -- Compatibility fallback for old cached books and server variants whose
        -- coord source is unavailable. It remains read-only and is never used to
        -- manufacture upload ranges.
        if not a and official_reason ~= "point_range" then
            local raw_a, raw_b = legacy_parse_range(key)
            if raw_a then
                for _, quote in ipairs(quote_candidates(row, data)) do
                    a, b = locate_quote(index, quote, raw_a)
                    if a then break end
                end
                if a then
                    stats.quote_aligned = stats.quote_aligned + 1
                    stats.fallback = stats.fallback + 1
                else
                    a, b = numeric_interval(raw_a, raw_b, visible_count, index)
                    if a then
                        stats.numeric = stats.numeric + 1
                        stats.fallback = stats.fallback + 1
                    end
                end
            end
        end

        if a and b and b > a then
            out[#out + 1] = {
                a=a, b=b, key=key, row=row,
                thought=#(data.review_map[key] or {}) > 0,
            }
        elseif official_reason ~= "point_range" then
            unresolved_item(row, official_reason or "position")
        end
    end
    table.sort(out, function(x,y) if x.a==y.a then return x.b<y.b end return x.a<y.a end)
    local clean, cursor = {}, -1
    for _, it in ipairs(out) do
        if it.a >= cursor then
            it.row = nil
            clean[#clean + 1] = it
            cursor = it.b
        else
            unresolved_item(it.row, "overlap")
        end
    end
    return clean, stats, unresolved
end

local function render_text_token(token, marks, data)
    if token.skip or not token.units or #token.units == 0 then return token.raw end
    local out, pos = {}, token.start
    local active, thought_link_open = nil, false
    local function close_active()
        if not active then return end
        out[#out + 1] = "</span>"
        if thought_link_open then out[#out + 1] = "</a>" end
        active = nil
        thought_link_open = false
    end
    for _, unit in ipairs(token.units) do
        local mark
        for _, it in ipairs(marks) do if pos >= it.a and pos < it.b then mark = it; break end end
        if mark ~= active then
            close_active()
            active = mark
            if active then
                -- HTML does not allow links inside links. When an underline overlaps
                -- an existing footnote/noteref link, preserve the underline style but
                -- leave the original link as the only clickable target.
                if active.thought and not token.inside_anchor then
                    local anchor = Thoughts.anchor(data.book_id, data.chapter_uid, active.key)
                    local href = Thoughts.href(data.book_id, data.chapter_uid, active.key)
                    out[#out + 1] = '<a class="miu-thought-link" id="' .. anchor .. '" href="' .. href .. '">'
                    thought_link_open = true
                end
                local mark_class = Thoughts.mark_class(active.key)
                local display_class = active.thought and "miu-thought-mark" or "miu-inline-mark"
                out[#out + 1] = '<span class="' .. display_class .. ' ' .. mark_class .. '" data-miu-range="' .. active.key .. '">'
            end
        end
        out[#out + 1] = unit
        pos = pos + 1
        if active and pos >= active.b then close_active() end
    end
    close_active()
    return table.concat(out)
end

local function inject(html, data, coord_html)
    local tokens, visible_count = tokenize(html)
    local index = build_text_index(tokens)
    local marks, stats = intervals(data, visible_count, index, coord_html)
    local rendered = tostring(html or "")
    if #marks > 0 then
        local out = {}
        for _, token in ipairs(tokens) do
            if token.kind == "text" then out[#out + 1] = render_text_token(token, marks, data)
            else out[#out + 1] = token.raw end
        end
        rendered = table.concat(out)
    end
    -- Unlocated marks remain in the annotation cache and diagnostic counters.
    -- They are deliberately omitted from the EPUB instead of being appended to
    -- the chapter, so generated books contain only content placed in context.
    return rendered, stats
end

function Annotations:apply(html, data, coord_html)
    if not data or data.underline_count == 0 then return html, "", {underlines=0,thoughts=0} end
    local rendered, alignment = inject(html, data, coord_html)
    logger.info("[MiuRead][Annotations] alignment",
        "book=", tostring(data.book_id or ""), "chapter=", tostring(data.chapter_uid or ""),
        "official=", tostring(alignment and alignment.official or 0),
        "verified=", tostring(alignment and alignment.official_verified or 0),
        "roundtrip=", tostring(alignment and alignment.official_roundtrip or 0),
        "official_failed=", tostring(alignment and alignment.official_failed or 0),
        "quote=", tostring(alignment and alignment.quote_aligned or 0),
        "numeric=", tostring(alignment and alignment.numeric or 0),
        "dropped=", tostring(alignment and alignment.dropped or 0),
        "fallback=", tostring(alignment and alignment.fallback or 0))
    return rendered, CSS, {
        underlines=data.underline_count, thoughts=data.thought_count,
        thought_entries=data.thought_entry_count or 0, errors=#(data.errors or {}),
        official=alignment and alignment.official or 0,
        official_verified=alignment and alignment.official_verified or 0,
        official_roundtrip=alignment and alignment.official_roundtrip or 0,
        official_failed=alignment and alignment.official_failed or 0,
        quote_aligned=alignment and alignment.quote_aligned or 0,
        dropped=alignment and alignment.dropped or 0,
        fallback=alignment and alignment.fallback or 0,
    }
end

local CACHE_UNDERLINE_FIELDS={"range","markRange","bookmarkRange","markText","bookmarkText","rangeText","abstract","text","content"}
local CACHE_REVIEW_FIELDS={"content","abstract","created","author","likes","review_id"}

local function safe_scalar_copy(source,fields)
    local out={}
    source=type(source)=="table" and source or {}
    for _,key in ipairs(fields) do
        local value=rawget(source,key)
        if type(value)=="string" or type(value)=="number" or type(value)=="boolean" then out[key]=value end
    end
    return out
end

local function cached_groups(groups)
    local out={}
    for _,group in ipairs(groups or {}) do
        local key=tostring(group.range or "")
        if key~="" then
            local texts={}
            for _,review in ipairs(group.texts or {}) do
                local item=safe_scalar_copy(review,CACHE_REVIEW_FIELDS)
                if tostring(item.content or "")~="" then texts[#texts+1]=item end
            end
            out[#out+1]={range=key,texts=texts}
        end
    end
    table.sort(out,function(a,b) return tostring(a.range)<tostring(b.range) end)
    return out
end

function Annotations:to_cache(data)
    data=type(data)=="table" and data or {}
    local underlines={}
    for _,row in ipairs(data.underlines or {}) do underlines[#underlines+1]=safe_scalar_copy(row,CACHE_UNDERLINE_FIELDS) end
    return {
        schema=1,book_id=str(data.book_id),chapter_uid=str(data.chapter_uid),underlines=underlines,
        review_groups=cached_groups(data.review_groups),completed_ranges=data.completed_ranges or {},
        pending_ranges=data.pending_ranges or {},underline_request_ok=data.underline_request_ok==true,
        underlines_partial=data.underlines_partial==true,review_complete=data.review_complete==true,
        complete=data.complete==true,error_kind=data.error_kind,
    }
end

function Annotations:from_cache(value)
    value=type(value)=="table" and value or {}
    local groups=cached_groups(value.review_groups)
    local map,group_count,entry_count={},0,0
    for _,group in ipairs(groups) do
        map[group.range]=group.texts
        if #group.texts>0 then group_count=group_count+1; entry_count=entry_count+#group.texts end
    end
    local underlines={}
    for _,row in ipairs(value.underlines or {}) do underlines[#underlines+1]=safe_scalar_copy(row,CACHE_UNDERLINE_FIELDS) end
    return {book_id=str(value.book_id),chapter_uid=str(value.chapter_uid),underlines=underlines,
        review_map=map,review_groups=groups,underline_count=#underlines,thought_count=group_count,
        thought_entry_count=entry_count,errors={},completed_ranges=value.completed_ranges or {},
        pending_ranges=value.pending_ranges or {},underline_request_ok=value.underline_request_ok==true,
        underlines_partial=value.underlines_partial==true,review_complete=value.review_complete==true,
        complete=value.complete==true,error_kind=value.error_kind,
        cached=true}
end

local function merge_review_lists(old_rows,new_rows)
    local out,positions={},{}
    local function add(rows,replace)
        for _,item in ipairs(rows or {}) do
            local key=tostring(item.review_id or "")
            if key=="" then key=tostring(item.content or "").."\0"..tostring(item.author or "") end
            if key~="" then
                local index=positions[key]
                if index and replace then out[index]=item
                elseif not index then positions[key]=#out+1; out[#out+1]=item end
            end
        end
    end
    add(old_rows,false)
    add(new_rows,true)
    table.sort(out,function(a,b)
        local ac,bc=tonumber(a.created or 0) or 0,tonumber(b.created or 0) or 0
        if ac==bc then return tostring(a.review_id or a.content or "")<tostring(b.review_id or b.content or "") end
        return ac<bc
    end)
    return out
end

local function merge_underlines(old_rows,new_rows)
    local out,positions={},{}
    local function add(rows,replace)
        for _,row in ipairs(rows or {}) do
            local key=range_key(row)
            if key~="" then
                local index=positions[key]
                if index and replace then out[index]=row
                elseif not index then positions[key]=#out+1; out[#out+1]=row end
            end
        end
    end
    add(old_rows,false)
    add(new_rows,true)
    return out
end

function Annotations:merge(previous,current)
    previous=type(previous)=="table" and previous or nil
    current=type(current)=="table" and current or {}
    if current.underline_request_ok~=true then
        if previous then
            previous.errors=current.errors or {}
            previous.error_kind=current.error_kind
            previous.auth_required=current.auth_required
            previous.forbidden=current.forbidden
            previous.rate_limited=current.rate_limited
            previous.complete=false
            previous.review_complete=false
            return previous
        end
        current.complete=false
        current.review_complete=false
        return current
    end

    if current.underlines_partial==true and previous then
        current.underlines=merge_underlines(previous.underlines,current.underlines)
    end

    local completed,pending={},{}
    for _,key in ipairs(current.completed_ranges or {}) do completed[tostring(key)]=true end
    for _,key in ipairs(current.pending_ranges or {}) do pending[tostring(key)]=true end
    local old_map=previous and previous.review_map or {}
    local new_map=current.review_map or {}
    local active,groups={},{}
    for _,row in ipairs(current.underlines or {}) do
        local key=range_key(row)
        if key~="" then active[key]=true end
    end
    for key in pairs(active) do
        local texts
        if completed[key] then texts=new_map[key] or {}
        elseif pending[key] then texts=merge_review_lists(old_map[key],new_map[key])
        else texts=merge_review_lists(old_map[key],new_map[key]) end
        groups[#groups+1]={range=key,texts=texts}
    end
    table.sort(groups,function(a,b) return tostring(a.range)<tostring(b.range) end)
    current.review_groups=cached_groups(groups)
    current.review_map={}
    current.thought_count=0
    current.thought_entry_count=0
    for _,group in ipairs(current.review_groups) do
        current.review_map[group.range]=group.texts
        if #group.texts>0 then
            current.thought_count=current.thought_count+1
            current.thought_entry_count=current.thought_entry_count+#group.texts
        end
    end
    current.underline_count=#(current.underlines or {})
    current.review_complete=#(current.pending_ranges or {})==0
    current.complete=current.underline_request_ok and current.underlines_partial~=true and current.review_complete
    return current
end

return Annotations
