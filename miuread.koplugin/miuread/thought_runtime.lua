local Blitbuffer = require("ffi/blitbuffer")
local Widget = require("ui/widget/widget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Thoughts = require("miuread.thoughts")
local U = require("miuread.util")

local Runtime = {}
Runtime.__index = Runtime

local Overlay = Widget:extend{}
function Overlay:paintTo(bb,x,y)
    local runtime=self.runtime
    if not runtime or runtime.enabled~=true then return end
    local doc=runtime.ui and runtime.ui.document
    if not doc or type(doc.getScreenBoxesFromPositions)~="function" then return end
    local hits={}
    local thickness=math.max(1,tonumber(runtime.line_width) or 2)
    for _,entry in ipairs(runtime.entries or {}) do
        local ok,boxes=pcall(doc.getScreenBoxesFromPositions,doc,entry.pos0,entry.pos1,true)
        if ok and type(boxes)=="table" then
            for _,box in ipairs(boxes) do
                local bx,by,bw,bh=tonumber(box.x),tonumber(box.y),tonumber(box.w),tonumber(box.h)
                if bx and by and bw and bh and bw>0 and bh>0 then
                    local sx,sy=x+bx,y+by
                    local ly=sy+bh-thickness
                    local dash=math.max(3,thickness*4)
                    local gap=math.max(2,thickness*3)
                    local dx=0
                    while dx<bw do
                        bb:paintRect(sx+dx,ly,math.min(dash,bw-dx),thickness,Blitbuffer.COLOR_BLACK)
                        dx=dx+dash+gap
                    end
                    -- Hit testing uses the exact screen coordinates we paint.
                    hits[#hits+1]={x=sx,y=sy,w=bw,h=bh,info=entry.info}
                end
            end
        end
    end
    runtime.hit_boxes=hits
end

function Runtime:new(host)
    return setmetatable({host=host,ui=nil,overlay=nil,entries={},hit_boxes={},enabled=false,
        key="",scope_key="",generation=0,line_width=1},self)
end

function Runtime:install(ui)
    if not (ui and ui.view and type(ui.view.registerViewModule)=="function") then return false end
    if self.ui==ui and self.overlay then return true end
    self:clear(false)
    self.ui=ui
    self.overlay=Overlay:new{runtime=self}
    ui.view:registerViewModule("miuread_thought_runtime",self.overlay)
    return true
end

function Runtime:clear(redraw)
    self.entries={}
    self.hit_boxes={}
    self.key=""
    self.scope_key=""
    self.enabled=false
    self.generation=(tonumber(self.generation) or 0)+1
    if redraw~=false and self.ui then UIManager:setDirty(self.ui,"ui") end
end


function Runtime:is_scope(book_id,chapter_uid)
    return self.enabled==true and self.scope_key==tostring(book_id or "").."|"..tostring(chapter_uid or "")
end

local function current_toc_index(ui)
    local toc=ui and ui.toc
    local doc=ui and ui.document
    if not toc or not doc or type(toc.getTocIndexByPage)~="function" then return nil end
    if type(toc.fillToc)=="function" then pcall(toc.fillToc,toc) end
    local page=type(doc.getCurrentPage)=="function" and doc:getCurrentPage() or nil
    if not page then return nil end
    local ok,index=pcall(toc.getTocIndexByPage,toc,page)
    return ok and tonumber(index) or nil
end

local function result_in_current_chapter(ui,result,wanted_toc)
    if not wanted_toc then return true end
    local toc=ui and ui.toc
    local doc=ui and ui.document
    if not (toc and doc and type(toc.getTocIndexByPage)=="function" and type(doc.getPageFromXPointer)=="function") then return false end
    local ok_page,page=pcall(doc.getPageFromXPointer,doc,result.start)
    if not ok_page or not page then return false end
    local ok_idx,index=pcall(toc.getTocIndexByPage,toc,page)
    return ok_idx and tonumber(index)==wanted_toc
end

local function normalized_search_key(value)
    return U.trim(tostring(value or "")):gsub("%s+"," "):lower()
end

local function regex_literal(value)
    value=tostring(value or "")
    -- Escape ECMAScript metacharacters while leaving ordinary UTF-8 bytes as-is.
    return (value:gsub("([\\%^%$%.%|%?%*%+%(%)%[%]%{%}])","\\%1"))
end

local function match_source_key(matched,sources)
    local key=normalized_search_key(matched)
    if sources[key] then return key end
    -- Search flags may fold whitespace or compatibility characters. If the
    -- returned text only differs by this folding, accept a single containment
    -- relationship; anything ambiguous is deliberately discarded.
    local found
    for source_key in pairs(sources) do
        if key~="" and (source_key:find(key,1,true) or key:find(source_key,1,true)) then
            if found and found~=source_key then return nil end
            found=source_key
        end
    end
    return found
end

function Runtime:map_current(book_id,chapter_uid,groups,options)
    options=type(options)=="table" and options or {}
    local ui=self.host and self.host.ui or self.ui
    local doc=ui and ui.document
    if not (doc and type(doc.findAllText)=="function" and type(doc.getScreenBoxesFromPositions)=="function") then
        self:clear(false)
        return nil,"runtime mapping unavailable"
    end
    if not self:install(ui) then return nil,"runtime overlay unavailable" end
    self.generation=(tonumber(self.generation) or 0)+1
    local generation=self.generation
    local wanted_toc=current_toc_index(ui)
    local entries,ambiguous,missing={},{},{}
    local max_groups=math.max(1,math.min(120,tonumber(options.max_groups) or 80))

    -- Build one search identity per source excerpt. Duplicate excerpts cannot be
    -- mapped safely to separate WeRead ranges, so we reject them before asking
    -- crengine to search. This follows the beta.9 rule: omit rather than misplace.
    local rows,source_counts,sources={},{},{}
    for index,group in ipairs(type(groups)=="table" and groups or {}) do
        if index>max_groups then break end
        local source=U.trim(tostring(Thoughts.group_abstract(group) or ""))
        if source~="" and U.utf8_len(source)>=4 then
            source=U.utf8_truncate(source,120,"")
            local key=normalized_search_key(source)
            if key~="" then
                rows[#rows+1]={group=group,source=source,key=key}
                source_counts[key]=(source_counts[key] or 0)+1
                sources[key]=source
            end
        else
            missing[#missing+1]=tostring(group and group.range or "")
        end
    end

    local unique={}
    for _,row in ipairs(rows) do
        if source_counts[row.key]==1 then unique[#unique+1]=row
        else ambiguous[#ambiguous+1]=tostring(row.group.range or "") end
    end

    -- Searching the whole document once per comment is prohibitively expensive
    -- on Kindle. Batch literal excerpts into a small regex alternation instead:
    -- at most eight crengine searches for a 120-group chapter, while retaining
    -- the same exact/unique-match safety rule.
    local BATCH_SIZE=16
    local MAX_HITS=256
    local buckets={}
    for first=1,#unique,BATCH_SIZE do
        if generation~=self.generation then break end
        local last=math.min(#unique,first+BATCH_SIZE-1)
        local parts,batch_sources={},{}
        for index=first,last do
            local row=unique[index]
            parts[#parts+1]="(?:"..regex_literal(row.source)..")"
            batch_sources[row.key]=row.source
        end
        local pattern=table.concat(parts,"|")
        local ok,results=pcall(doc.findAllText,doc,pattern,true,0,MAX_HITS,true,0x00FF)
        if ok and type(results)=="table" then
            for _,result in ipairs(results) do
                if type(result)=="table" and result.start and result["end"]
                    and result_in_current_chapter(ui,result,wanted_toc) then
                    local key=match_source_key(result.matched_text or "",batch_sources)
                    if key then
                        buckets[key]=buckets[key] or {}
                        buckets[key][#buckets[key]+1]=result
                    end
                end
            end
        end
    end

    for _,row in ipairs(unique) do
        local candidates=buckets[row.key] or {}
        if #candidates==1 then
            entries[#entries+1]={pos0=candidates[1].start,pos1=candidates[1]["end"],
                info={book_id=tostring(book_id or ""),chapter_uid=tostring(chapter_uid or ""),range=tostring(row.group.range or "")}}
        elseif #candidates>1 then
            ambiguous[#ambiguous+1]=tostring(row.group.range or "")
        else
            missing[#missing+1]=tostring(row.group.range or "")
        end
    end

    self.entries=entries
    self.hit_boxes={}
    self.scope_key=tostring(book_id or "").."|"..tostring(chapter_uid or "")
    self.key=self.scope_key
    self.enabled=true
    UIManager:setDirty(ui,"ui")
    logger.info("[MiuRead][ThoughtRuntime] mapped",
        "book=",tostring(book_id),"chapter=",tostring(chapter_uid),
        "mapped=",tostring(#entries),"ambiguous=",tostring(#ambiguous),"missing=",tostring(#missing),
        "searched=",tostring(#unique))
    return {mapped=#entries,ambiguous=#ambiguous,missing=#missing,searched=#unique}
end

function Runtime:hit_test(pos)
    if self.enabled~=true or type(pos)~="table" then return nil end
    local x,y=tonumber(pos.x),tonumber(pos.y)
    if not x or not y then return nil end
    for i=#(self.hit_boxes or {}),1,-1 do
        local box=self.hit_boxes[i]
        if x>=box.x and y>=box.y and x<=box.x+box.w and y<=box.y+box.h then return box.info end
    end
end

return Runtime
