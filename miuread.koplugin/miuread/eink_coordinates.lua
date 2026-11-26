-- Resolve local quotations against the E-Ink chapter search response.
local U=require("miuread.util")
local M={}

local function units(text)
    if not U.is_valid_utf8(text) then return nil end
    local _, supplementary=text:gsub("[\240-\244]","")
    return U.utf8_len(text)+supplementary
end

local function offset(value)
    local n=tonumber(value)
    if n and n>=0 and n<2147483648 and n%1==0 then return n end
end

function M.locate(response,uid,quote)
    if type(response)~="table" or type(response.result)~="table" or #response.result~=1
        or tonumber(response.totalCount)~=1
        or (response.hasMore~=nil and response.hasMore~=false and tonumber(response.hasMore)~=0)
        or response.continueFlag==true or tonumber(response.continueFlag)==1 then
        return nil,"eink_search_not_unique"
    end
    local hit=response.result[1]
    if type(hit)~="table" or tostring(hit.chapterUid or "")~=tostring(uid)
        or type(hit.abstract)~="string" or type(quote)~="string" or quote=="" then
        return nil,"eink_search_chapter_mismatch"
    end
    local text=hit.abstract:gsub("</?em[^>]*>",""):gsub("</?b[^>]*>","")
    local found=text:find(quote,1,true)
    if not found or text:find(quote,found+1,true) then return nil,"eink_search_quote_mismatch" end
    local lead,width=units(text:sub(1,found-1)),units(quote)
    local first,last=offset(hit.absStart),offset(hit.absEnd)
    local reported=offset(hit.keywordStart)
    if not lead or not width or not first or not last or not reported then
        return nil,"eink_search_offsets_missing"
    end
    local start=first+lead
    if start+width>last or (reported~=start and reported~=lead) then
        return nil,"eink_search_offsets_disagree"
    end
    return start,start+width
end

function M.lookup(native,book_id,uid,quote)
    if type(quote)~="string" or quote=="" or #quote>255 or U.trim(quote)~=quote
        or quote:find("[%c]") or not U.is_valid_utf8(quote) then
        return nil,"eink_search_quote_unavailable"
    end
    local value=native:request("GET","/book/search",{bookId=tostring(book_id),keyword=quote,
        maxIdx=0,count=10,fragmentSize=100},"coordinates")
    if type(value)=="table" and value.bookId~=nil and tostring(value.bookId)~=tostring(book_id) then
        return nil,"eink_search_book_mismatch"
    end
    return M.locate(value,uid,quote)
end

local function review_range(Source,aligned,groups,first,last,quote)
    local selected_start,selected_end=aligned.source.rows[first].first,aligned.source.rows[last].last
    local compact_quote=Source.compact_text(quote)
    local basis,exact,left,right
    for _,group in ipairs(groups or {}) do
        local a,b=tostring(group.range or ""):match("^(%d+)%-(%d+)$")
        a,b=offset(a),offset(b)
        if a and b and a<b and b>=selected_start-4096 and a<=selected_end+4096 then
            for _,item in ipairs(group.texts or {}) do
                local abstract=tostring(item.abstract or "")
                local ar,br=Source.annotation_selection(aligned,abstract)
                if ar then
                    local source=aligned.source.rows
                    local bias=a-source[ar].first
                    if (bias==0 or bias==1) and b==source[br].last+bias then
                        if basis~=nil and basis~=bias then return nil end
                        basis=bias
                        if ar==first and br==last and Source.compact_text(abstract)==compact_quote then
                            exact=true
                        elseif b<=selected_start+bias then
                            left=true
                        elseif a>=selected_end+bias then
                            right=true
                        end
                    end
                end
            end
        end
    end
    if basis~=nil and (exact or (left and right)) then
        return selected_start+basis,selected_end+basis
    end
end

function M.annotation_range(native,reader,book_id,uid,version,record,row,quote,groups)
    local Source=require("miuread.eink_progress_source")
    local aligned,err=Source.annotation_alignment(reader,record,uid,version)
    if not aligned then return nil,err end
    local first,last=Source.annotation_selection(aligned,quote,row.context_before,row.context_after)
    if not first then return nil,last end
    local start,stop=review_range(Source,aligned,groups,first,last,quote)
    if start~=nil then return start,stop,"eink_chapter_review_range" end
    local source=aligned.source.rows
    local checked={}
    local attempts=0
    for _,window in ipairs({{-12,22},{0,32},{-32,0},{5,37},{-6,12},{-17,-1}}) do
        local a=source[math.max(1,first+window[1])]
        local b=source[math.min(#source,first+window[2])]
        if a and b and a.raw_first<b.raw_end then
            local text=aligned.raw:sub(a.raw_first,b.raw_end-1)
            if #text>=12 and #text<=160 and not text:find("[<>&%c]") and not checked[text] then
                checked[text]=true
                local start,stop=M.lookup(native,book_id,uid,text)
                attempts=attempts+1
                if start~=nil then
                    local bias=start-a.first
                    if (bias==0 or bias==1) and stop==b.last+bias then
                        return source[first].first+bias,source[last].last+bias,"eink_chapter_search"
                    end
                end
                if attempts>=3 then break end
            end
        end
    end
    return nil,"eink_source_search_anchor_unconfirmed"
end

function M.position(native,record,anchor,display_progress)
    local book_id=tostring((record.book or {}).book_id or "")
    local uid=tostring(anchor.chapter_uid or "")
    local index=tonumber(anchor.chapter_index)
    if book_id=="" or uid=="" or index==nil or index<0 then return nil,"eink_chapter_identity_missing" end
    local book=native:book(book_id)
    local version=tonumber(book.version or book.bookVersion)
    if tostring(book.format):lower()=="txt" then version=0 end
    if version==nil or tonumber(anchor.book_version)~=version then return nil,"eink_book_version_changed" end
    local candidates=anchor.anchor_candidates or {anchor}
    local attempts=0
    for _,candidate in ipairs(candidates) do
        if candidate.point_side=="start" and not candidate.anchor_cross_chapter and not candidate.anchor_contains_chapter_title
            and type(candidate.anchor_text)=="string" and #candidate.anchor_text>=12 then
            local quote=candidate.anchor_text
            local start=M.lookup(native,book_id,uid,quote)
            attempts=attempts+1
            if start~=nil then
                return {book_id=book_id,book_version=version,chapter_uid=uid,chapter_index=index,chapter_idx=index,
                    offset=start,chapter_offset=start,canonical_offset=start,summary=quote,
                    progress=display_progress,chapter_ratio=anchor.chapter_ratio,
                    source="eink_chapter_search",eink_coordinate=true,
                    offset_basis="wr_data_co",position_basis="wr_data_co",native_offset=true,safe=true,
                    source_xpointer=anchor.xpointer,catalog_pending=display_progress==nil,precise=true}
            end
            if attempts>=3 then break end
        end
    end
    return nil,"eink_exact_text_anchor_unavailable"
end

return M
