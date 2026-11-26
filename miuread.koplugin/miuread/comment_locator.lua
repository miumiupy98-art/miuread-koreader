-- B3: conservative, offline, non-mutating XPointer projection of cached comments.
-- A server range is never interpreted as an EPUB character offset. Every
-- candidate must be checked against rendered text and chapter boundaries.
local U = require("miuread.util")
local Coord = require("miuread.annotation_coord")
local ThoughtDatabase = require("miuread.thought_database")
local Source = require("miuread.source_position")
local Range = require("miuread.annotations.range")
local lfs = require("libs/libkoreader-lfs")

local Locator = {}
Locator.VERSION = "b3-3"

local function compact(s)
    s=tostring(s or "")
    s=s:gsub("%s+", ""):gsub("\194\160", ""):gsub("\227\128\128", "")
    s=s:gsub("\226\128[\139-\141]", ""):gsub("\239\187\191", "")
    return s
end

local function signature(s)
    local hash=5381
    for i=1,#s do hash=(hash*33+s:byte(i))%4294967296 end
    return string.format("%08x",hash)
end

function Locator.documentFingerprint(path)
    if type(path)~="string" or path=="" then return nil end
    local st=lfs.attributes(path)
    if type(st)~="table" or st.mode~="file" then return nil end
    return table.concat({Locator.VERSION,path,tostring(st.size or 0),
        tostring(st.modification or 0)},"|")
end

local function valid(document,xp)
    if type(xp)~="string" or xp=="" then return false end
    if type(document.isXPointerInDocument)=="function" then
        local ok,result=pcall(document.isXPointerInDocument,document,xp)
        return ok and result==true
    end
    return true
end

-- A chapter is only trusted if its local chapter_map identity agrees with
-- the current TOC interval. On unknown or inconsistent mappings, fail closed.
function Locator.chapterBounds(ui,record,uid,target)
    local document=ui and ui.document
    if not document then return nil,"no_document" end
    local entry=type(record)=="table" and record or {}
    if entry.local_document==true and type(entry.local_bounds)=="table" then
        local local_bounds=entry.local_bounds
        if valid(document,local_bounds.start)
            and (local_bounds.ending==nil or valid(document,local_bounds.ending)) then
            return {start=local_bounds.start,ending=local_bounds.ending},nil
        end
        return nil,"local_chapter_bounds_invalid"
    end
    local map=type(entry.chapter_map)=="table" and entry.chapter_map or {}
    local readable={}
    for _,chapter in ipairs(map) do
        local id=tostring(chapter.uid or chapter.chapterUid or chapter.chapter_uid or "")
        if chapter.structural~=true and id~="" then readable[#readable+1]=id end
    end
    if #readable==1 and readable[1]==uid then
        return {single=true,title=map[1] and (map[1].title or map[1].chapterTitle)},nil
    end
    local toc=ui.toc
    if #readable==0 or not toc or type(toc.getTocIndexByPage)~="function" then
        return nil,"chapter_bounds_unavailable"
    end
    if type(toc.fillToc)=="function" then pcall(toc.fillToc,toc) end
    if type(toc.toc)~="table" then return nil,"toc_unavailable" end
    local index
    if target then
        for i,chapter in ipairs(map) do
            if tostring(chapter.uid or chapter.chapterUid or chapter.chapter_uid or "")==uid then index=i; break end
        end
    else
        local current_xp=ui.rolling and ui.rolling.xpointer
        if not valid(document,current_xp) and type(document.getXPointer)=="function" then
            local ok,xp=pcall(document.getXPointer,document)
            if ok then current_xp=xp end
        end
        if not valid(document,current_xp) then return nil,"current_position_unavailable" end
        local ok,value=pcall(toc.getTocIndexByPage,toc,current_xp)
        index=ok and tonumber(value) or nil
    end
    if not index or index<1 or index>#toc.toc then return nil,"toc_index_unavailable" end
    index=math.floor(index)
    local chapter=map[index]
    local local_uid=chapter and tostring(chapter.uid or chapter.chapterUid or chapter.chapter_uid or "") or ""
    if local_uid~=uid then return nil,"toc_uid_mismatch" end
    local function item_xp(row)
        if not row then return nil end
        local xp=row.xpointer or row.xp
        if valid(document,xp) then return xp end
        local page=tonumber(row.page or row.pageno)
        if page and type(document.getPageXPointer)=="function" then
            local good,value=pcall(document.getPageXPointer,document,math.floor(page+.5))
            if good and valid(document,value) then return value end
        end
    end
    local start=item_xp(toc.toc[index]); local ending=item_xp(toc.toc[index+1])
    if not start then return nil,"chapter_start_unavailable" end
    -- Without an end boundary, the final chapter can be safely constrained
    -- only when its chapter identity is last in the local chapter_map.
    if not ending and index~=#map then return nil,"chapter_end_unavailable" end
    return {start=start,ending=ending,title=chapter.title or chapter.chapterTitle},nil
end

local function in_bounds(document,start,ending,bounds,allow_exclusive_end)
    if bounds.single then return true end
    if type(document.compareXPointers)~="function" then return false end
    local ok1,a=pcall(document.compareXPointers,document,bounds.start,start)
    if not ok1 or a==-1 then return false end
    if bounds.ending then
        local ok2,b=pcall(document.compareXPointers,document,ending,bounds.ending)
        if not ok2 or (b~=1 and not (allow_exclusive_end and b==0)) then return false end
    end
    return true
end

function Locator.quoteFor(group,underlines,raw_map,index,native_map)
    local range=tostring(group and group.range or "")
    local remote=index and index[range]
    if not index then
        for _,row in ipairs(underlines or {}) do
            if tostring(row.range or row.markRange or row.bookmarkRange or "")==range then
                remote=row; break
            end
        end
    end
    local from_remote=remote and tostring(remote.markText or remote.bookmarkText or remote.rangeText or "") or ""
    local from_source=""
    if native_map then
        from_source=require("miuread.eink_comment_source").quote(native_map,range) or ""
    elseif raw_map then
        local resolved=Coord.resolveRangeOnMap(raw_map,range)
        if resolved and not resolved.point then from_source=tostring(resolved.text or "") end
    end
    if group.personal then
        local abstract=group.texts and group.texts[1] and tostring(group.texts[1].abstract or "") or ""
        if native_map and from_source~="" then
            if abstract=="" or compact(abstract)==compact(from_source) then return from_source,"source" end
            return "","personal_source_quote_conflict"
        end
        return abstract,"personal_review_abstract"
    end
    -- The server's raw coordinate source wins over an unrelated review abstract.
    if from_source~="" and compact(from_source)~="" then
        if from_remote=="" or compact(from_remote)==compact(from_source) then return from_source,"source" end
        return "","source_quote_conflict"
    end
    if compact(from_remote)~="" then return from_remote,"underline" end
    for _,item in ipairs(group.texts or {}) do
        if compact(item.abstract)~="" then return item.abstract,"review_abstract" end
    end
    return "","quote_missing"
end

function Locator.find(document,quote,bounds)
    if type(document.findAllText)~="function" or
        type(document.getTextFromXPointers)~="function" then return nil,"document_search_unavailable" end
    local normalized=compact(quote)
    if normalized=="" or #normalized<6 then return nil,"quote_too_short" end
    -- No approximation: only a verified unique hit *inside* this chapter.
    local ok,results=pcall(document.findAllText,document,quote,true,0,32,false,0)
    if type(document.clearSelection)=="function" then pcall(document.clearSelection,document) end
    if not ok or type(results)~="table" then return nil,"search_failed" end
    if #results>=32 then return nil,"too_many_matches" end
    local found
    for _,hit in ipairs(results) do
        local start,ending=hit.start,hit["end"]
        if valid(document,start) and valid(document,ending) and in_bounds(document,start,ending,bounds) then
            local read_ok,actual=pcall(document.getTextFromXPointers,document,start,ending)
            if type(document.clearSelection)=="function" then pcall(document.clearSelection,document) end
            if read_ok and compact(actual)==normalized then
                if found then return nil,"ambiguous_quote" end
                found={start=start,ending=ending}
            end
        end
    end
    if not found then return nil,"quote_not_found_in_chapter" end
    return found
end

-- Project the verified HTML character offsets onto KOReader's DOM. Page
-- boundaries narrow the lookup; visible character traversal resolves the
-- exact XPointer without choosing a match by quotation.
local function dom_projection(document,bounds,body,compact_text)
    if not (document.getPageXPointer and document.getPageFromXPointer
        and document.getPageCount and document.getNextVisibleChar and document.getTextFromXPointers) then
        return nil
    end
    local start=bounds.start or document:getPageXPointer(1)
    if not valid(document,start) then return nil end
    local first_page=document:getPageFromXPointer(start)
    local last_page=bounds.ending and document:getPageFromXPointer(bounds.ending) or document:getPageCount()
    if not first_page or not last_page or first_page<1 or last_page<first_page then return nil end
    local title=compact_text(bounds.title)
    local prefix_cache,points={},{}
    local function text_between(a,b)
        if a==b then return "" end
        local text=document:getTextFromXPointers(a,b,false)
        if type(text)=="table" then text=text.text or text[1] end
        return type(text)=="string" and compact_text(text) or nil
    end
    local function body_offset(prefix)
        if not prefix then return nil end
        if body:sub(1,#prefix)==prefix then return #prefix end
        if title~="" then
            if title:sub(1,#prefix)==prefix then return -1 end
            if prefix:sub(1,#title)==title then
                local rest=prefix:sub(#title+1)
                if body:sub(1,#rest)==rest then return #rest end
            end
        end
    end
    local function at_offset(offset)
        if points[offset] then return points[offset] end
        local lo,hi,best=first_page+1,last_page,start
        while lo<=hi do
            local page=math.floor((lo+hi)/2)
            local point=document:getPageXPointer(page)
            if not valid(document,point) then return nil end
            local prefix=prefix_cache[point]
            if prefix==nil then prefix=text_between(start,point);prefix_cache[point]=prefix end
            local distance=body_offset(prefix)
            if distance==nil then return nil end
            if distance<offset then best=point;lo=page+1 else hi=page-1 end
        end
        local prefix=prefix_cache[best] or text_between(start,best)
        if prefix==nil then return nil end
        local p=best
        while valid(document,p) do
            local tail=text_between(best,p)
            if tail==nil then return nil end
            local distance=body_offset(prefix..tail)
            if distance==nil or distance>offset then return nil end
            if distance==offset then
                points[offset]=p
                return p
            end
            local next_point=document:getNextVisibleChar(p)
            if not next_point or next_point==p
                or not in_bounds(document,next_point,next_point,bounds,offset==#body) then return nil end
            p=next_point
        end
    end
    return function(first,last)
        local a,b=at_offset(first),at_offset(last)
        if not (a and b and in_bounds(document,a,b,bounds,last==#body)) then return nil end
        local expected=body:sub(first+1,last)
        local actual=text_between(a,b)
        if actual==expected then return a,b end
        -- The generated heading is a reader prefix, outside the source HTML.
        if first==0 and title~="" and actual==title..expected then
            local p=a
            while p and p~=b do
                local prefix=text_between(a,p)
                if prefix==title and text_between(p,b)==expected then return p,b end
                if not prefix or title:sub(1,#prefix)~=prefix then return nil end
                local next_point=document:getNextVisibleChar(p)
                if next_point==p then return nil end
                p=next_point
            end
        end
    end
end

function Locator.uses_eink_ranges(path,record)
    return type(record)=="table" and tostring(path or ""):lower():match("%.epub$")~=nil
        and (record.eink_content_mode=="eink-online" or record.eink_content_mode=="eink-offline")
end

function Locator.eink_positions(store,ui,book_id,uid,record,ranges,options)
    local result={}
    options=options or {}
    local document=ui and ui.document
    local path=document and document.file
    local version=tonumber(record.progress_source_book_version)
    if not (path and version and version>0) then return result end
    local bounds,err=Locator.chapterBounds(ui,record,uid,true)
    if not bounds then return result,err end
    local positions=require("miuread.eink_progress_source")
    local aligned,reason=require("miuread.eink_comment_source").personal_alignment(store,book_id,uid,path,version)
    if not aligned then return result,reason end
    local ready,project=pcall(dom_projection,document,bounds,aligned.rendered.text,positions.compact_text)
    if not ready or not project then return result end
    local spans={}
    for _,range in ipairs(ranges) do
        local first,last=positions.annotation_range(aligned,range)
        if first then spans[#spans+1]={range=range,first=first,last=last}
        else reason=reason or "official_range_unavailable" end
    end
    table.sort(spans,function(a,b) return a.first<b.first end)
    for _,span in ipairs(spans) do
        if options.on_group then options.on_group() end
        local range,first,last=span.range,span.first,span.last
        local selection=aligned.rendered.text:sub(first+1,last)
        local expected=options.quotes and options.quotes[range]
        local match=expected and positions.compact_text(expected)==selection
        if options.verify_quote and not match then
            reason=expected and expected~="" and "official_range_text_differs" or "official_range_quote_missing"
        elseif options.public or aligned.version==version or match then
            local ok,a,b=pcall(project,first,last)
            if ok and a and b then
                result[range]={pos0=a,pos1=b,book_id=book_id,chapter_uid=uid,range=range,
                    quote=selection,mark_only=true,source_version=version}
            else
                reason=reason or "renderer_position_unavailable"
            end
        else
            reason=reason or "source_cache_missing"
        end
    end
    return result,reason
end

function Locator.resolve(store,reader,ui,book_id,uid,record,groups,marks,on_group)
    local document=ui and ui.document
    local path=document and document.file
    if (not path or path=="") and document and type(document.getFilePath)=="function" then
        local ok,value=pcall(document.getFilePath,document)
        if ok then path=value end
    end
    local fingerprint=Locator.documentFingerprint(path)
    if not fingerprint then return {},{matched=0,unmatched=0,error="document_fingerprint_unavailable"} end
    if not document or type(document.getScreenBoxesFromPositions)~="function" then
        return {},{matched=0,unmatched=0,error="not_reflowable"}
    end
    local bounds,err=Locator.chapterBounds(ui,record,uid)
    if not bounds then return {},{matched=0,unmatched=#(groups or {}),error=err} end
    if Locator.uses_eink_ranges(path,record) then
        local ranges,records={},{}
        for _,group in ipairs(groups or {}) do
            local start,_,point=Range.parse(group.range)
            if start and not point then ranges[#ranges+1]=group.range end
        end
        local located,reason=Locator.eink_positions(store,ui,book_id,uid,record,ranges,
            {public=true,on_group=on_group})
        for _,range in ipairs(ranges) do
            if located[range] then records[#records+1]=located[range] end
        end
        return records,{matched=#records,unmatched=#ranges-#records,error=reason}
    end
    local snapshot=ThoughtDatabase.load_checkpoint(store,book_id,uid)
    local underlines=type(snapshot)=="table" and snapshot.underlines or nil
    local underline_index={}
    for _,row in ipairs(underlines or {}) do
        local range=row.range or row.markRange or row.bookmarkRange
        if range then underline_index[tostring(range)]=row end
    end
    for _,row in ipairs(marks or {}) do
        if row.markText~="" or not underline_index[row.range] then underline_index[row.range]=row end
    end
    -- Offline only. Missing source is not a reason to trigger a network request.
    local native
    for _,group in ipairs(groups or {}) do
        if group.mark_only then
            local CommentSource=require("miuread.eink_comment_source")
            native=CommentSource.for_document(store,book_id,uid,path)
            local version=type(record)=="table" and tonumber(record.progress_source_book_version)
            if not native and group.personal and version and version>0 and reader and reader.store then
                local position_source=require("miuread.eink_progress_source")
                local aligned=position_source.annotation_alignment(reader,
                    {book={book_id=book_id},path=path,record=record},uid,version,false)
                if aligned then native=CommentSource.make_map(aligned.raw,"html") end
            end
            break
        end
    end
    local raw=not native and Source.readCachedChapter(store,book_id,uid) or nil
    local raw_map=raw and Coord.build(raw) or nil
    local locations
    if type(record)=="table" and record.local_document==true then
        locations=type(record.location_get)=="function" and record.location_get() or {}
    else
        locations=ThoughtDatabase.load_locations(store,book_id,uid) or {}
    end
    local written,records,stats={}, {},{matched=0,unmatched=0}
    for _,group in ipairs(groups or {}) do
        if on_group then on_group() end
        local range=tostring(group.range or "")
        local _,_,point=Range.parse(range)
        if range~="" and (#(group.texts or {})>0 or group.mark_only==true) and point~=true then
            local quote,origin=Locator.quoteFor(group,nil,raw_map,underline_index,native)
            local key=fingerprint.."|"..signature(compact(quote))
            local previous=locations[range]
            local start,ending,status
            if previous and previous.document_fingerprint==key then
                status=previous.match_status
                if status=="matched" and valid(document,previous.xpointer_start)
                    and valid(document,previous.xpointer_end) then
                    start,ending=previous.xpointer_start,previous.xpointer_end
                end
            end
            if not start and (not previous or previous.document_fingerprint~=key or status=="matched") then
                local found,reason=Locator.find(document,quote,bounds)
                if found then start,ending,status=found.start,found.ending,"matched"
                else status=reason or origin or "unmatched" end
                written[#written+1]={range=range,document_fingerprint=key,
                    xpointer_start=start or "",xpointer_end=ending or "",match_status=status}
            end
            if start and ending and in_bounds(document,start,ending,bounds) then
                records[#records+1]={pos0=start,pos1=ending,book_id=book_id,
                    chapter_uid=uid,range=range,quote=quote,mark_only=group.mark_only==true}
                stats.matched=stats.matched+1
            else stats.unmatched=stats.unmatched+1 end
        end
    end
    if #written>0 then
        local saved,why
        if type(record)=="table" and record.local_document==true then
            saved,why=record.location_save(written)
        else
            saved,why=ThoughtDatabase.save_locations(store,book_id,uid,written)
        end
        if not saved then stats.error=tostring(why) end
    end
    return records,stats
end

return Locator
