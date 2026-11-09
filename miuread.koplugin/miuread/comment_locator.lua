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
Locator.VERSION = "b3-1"

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
function Locator.chapterBounds(ui,record,uid)
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
        return {single=true},nil
    end
    local toc=ui.toc
    if #readable==0 or not toc or type(toc.getTocIndexByPage)~="function" then
        return nil,"chapter_bounds_unavailable"
    end
    if type(toc.fillToc)=="function" then pcall(toc.fillToc,toc) end
    if type(toc.toc)~="table" then return nil,"toc_unavailable" end
    local current_xp=ui.rolling and ui.rolling.xpointer
    if not valid(document,current_xp) and type(document.getXPointer)=="function" then
        local ok,xp=pcall(document.getXPointer,document)
        if ok then current_xp=xp end
    end
    if not valid(document,current_xp) then return nil,"current_position_unavailable" end
    local ok,index=pcall(toc.getTocIndexByPage,toc,current_xp)
    index=ok and tonumber(index) or nil
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
    return {start=start,ending=ending},nil
end

local function in_bounds(document,start,ending,bounds)
    if bounds.single then return true end
    if type(document.compareXPointers)~="function" then return false end
    local ok1,a=pcall(document.compareXPointers,document,bounds.start,start)
    if not ok1 or a==-1 then return false end
    if bounds.ending then
        local ok2,b=pcall(document.compareXPointers,document,ending,bounds.ending)
        if not ok2 or b~=1 then return false end
    end
    return true
end

function Locator.quoteFor(group,underlines,raw_map)
    local range=tostring(group and group.range or "")
    local remote
    for _,row in ipairs(underlines or {}) do
        if tostring(row.range or row.markRange or row.bookmarkRange or "")==range then
            remote=row; break
        end
    end
    local from_remote=remote and tostring(remote.markText or remote.bookmarkText or remote.rangeText or "") or ""
    local from_source=""
    if raw_map then
        local resolved=Coord.resolveRangeOnMap(raw_map,range)
        if resolved and not resolved.point then from_source=tostring(resolved.text or "") end
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

function Locator.resolve(store,reader,ui,book_id,uid,record,groups)
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
    local snapshot=ThoughtDatabase.load_checkpoint(store,book_id,uid)
    local underlines=type(snapshot)=="table" and snapshot.underlines or nil
    -- Offline only. Missing source is not a reason to trigger a network request.
    local raw=Source.readCachedChapter(store,book_id,uid)
    local raw_map=raw and Coord.build(raw) or nil
    local locations
    if type(record)=="table" and record.local_document==true then
        locations=type(record.location_get)=="function" and record.location_get() or {}
    else
        locations=ThoughtDatabase.load_locations(store,book_id,uid) or {}
    end
    local written,records,stats={}, {},{matched=0,unmatched=0}
    for _,group in ipairs(groups or {}) do
        local range=tostring(group.range or "")
        local _,_,point=Range.parse(range)
        if range~="" and #(group.texts or {})>0 and point~=true then
            local quote,origin=Locator.quoteFor(group,underlines,raw_map)
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
                    chapter_uid=uid,range=range,quote=quote}
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
