local BlitBuffer=require("ffi/blitbuffer")
local Widget=require("ui/widget/widget")
local UIManager=require("ui/uimanager")
local logger=require("logger")
local U=require("miuread.util")

local Runtime={}
Runtime.__index=Runtime

local function norm(value)
    return U.trim(tostring(value or "")):gsub("%s+","")
end

local function rect(row)
    if type(row)~="table" then return nil end
    local x=tonumber(row.x or row[1]); local y=tonumber(row.y or row[2])
    local w=tonumber(row.w or row.width or row[3]); local h=tonumber(row.h or row.height or row[4])
    if x and y and w and h and w>0 and h>0 then return {x=x,y=y,w=w,h=h} end
end

local function collect_rects(value,out,seen,depth)
    out=out or {}; seen=seen or {}; depth=depth or 0
    if type(value)~="table" or seen[value] or depth>5 then return out end
    seen[value]=true
    local r=rect(value); if r then out[#out+1]=r; return out end
    for _,child in pairs(value) do if type(child)=="table" then collect_rects(child,out,seen,depth+1) end end
    return out
end

local function intersects(a,b)
    return a and b and a.x < b.x+b.w and b.x < a.x+a.w and a.y < b.y+b.h and b.y < a.y+a.h
end

local function native_highlight_rects(ui)
    local view=ui and ui.view or nil
    local highlight=view and view.highlight or nil
    return collect_rects(highlight and highlight.visible_boxes or nil)
end

local function paint_dashed(bb,x,y,w,h)
    if w<=0 or h<=0 then return end
    local use_rgb=bb.getType and bb:getType()==BlitBuffer.TYPE_BBRGB32 and type(bb.paintRectRGB32)=="function"
    local color=BlitBuffer.ColorRGB32(0xFF,0x6B,0x35,0xFF)
    local function segment(px,pw)
        if use_rgb then bb:paintRectRGB32(px,y,pw,h,color)
        else bb:paintRect(px,y,pw,h,BlitBuffer.COLOR_BLACK) end
    end
    local dash=math.max(4,h*3); local gap=math.max(3,h*2); local right=x+w; local px=x
    while px<right do local pw=math.min(dash,right-px); segment(px,pw); px=px+dash+gap end
end

local Overlay=Widget:extend{}
function Overlay:paintTo(bb,x,y)
    local runtime=self.runtime
    if not runtime or runtime.enabled~=true then return end
    if runtime.host and type(runtime.host._thoughts_enabled)=="function" and runtime.host:_thoughts_enabled()~=true then
        runtime.hit_boxes={}
        return
    end
    local doc=runtime.ui and runtime.ui.document
    if not doc or type(doc.getScreenBoxesFromPositions)~="function" then return end
    local own=native_highlight_rects(runtime.ui)
    local hits={}
    for _,entry in ipairs(runtime.entries or {}) do
        local ok,boxes=pcall(doc.getScreenBoxesFromPositions,doc,entry.pos0,entry.pos1,true)
        if ok and type(boxes)=="table" then
            for _,box in ipairs(boxes) do
                local bx,by,bw,bh=tonumber(box.x),tonumber(box.y),tonumber(box.w),tonumber(box.h)
                if bx and by and bw and bh and bw>0 and bh>0 then
                    local sr={x=x+bx,y=y+by,w=bw,h=bh}
                    local blocked=false
                    for _,native in ipairs(own) do if intersects(sr,native) then blocked=true; break end end
                    if not blocked then
                        local thickness=2
                        paint_dashed(bb,sr.x,sr.y+sr.h-thickness,sr.w,thickness)
                        hits[#hits+1]={x=sr.x,y=sr.y,w=sr.w,h=sr.h,info=entry.info}
                    end
                end
            end
        end
    end
    runtime.hit_boxes=hits
end

function Runtime:new(host)
    return setmetatable({host=host,ui=nil,overlay=nil,entries={},hit_boxes={},enabled=false,scope_key="",generation=0,stats=nil},self)
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
    self.entries={}; self.hit_boxes={}; self.scope_key=""; self.enabled=false; self.stats=nil
    self.generation=(tonumber(self.generation) or 0)+1
    if redraw~=false and self.ui then UIManager:setDirty(self.ui,"ui") end
end

function Runtime:is_scope(book_id,chapter_uid)
    return self.enabled==true and self.scope_key==tostring(book_id or "").."|"..tostring(chapter_uid or "")
end

local function current_toc_index(ui)
    local toc=ui and ui.toc; local doc=ui and ui.document
    if not toc or not doc or type(toc.getTocIndexByPage)~="function" then return nil end
    if type(toc.fillToc)=="function" then pcall(toc.fillToc,toc) end
    local page=type(doc.getCurrentPage)=="function" and doc:getCurrentPage() or nil
    if not page then return nil end
    local ok,index=pcall(toc.getTocIndexByPage,toc,page)
    return ok and tonumber(index) or nil
end

local function result_in_current_chapter(ui,result,wanted_toc)
    if not wanted_toc then return true end
    local toc=ui and ui.toc; local doc=ui and ui.document
    if not (toc and doc and type(toc.getTocIndexByPage)=="function" and type(doc.getPageFromXPointer)=="function") then return false end
    local ok_page,page=pcall(doc.getPageFromXPointer,doc,result.start)
    if not ok_page or not page then return false end
    local ok_idx,index=pcall(toc.getTocIndexByPage,toc,page)
    return ok_idx and tonumber(index)==wanted_toc
end

local function escape_regex(value)
    return (tostring(value or ""):gsub("([\\%^%$%.%|%?%*%+%(%)%[%]%{%}])","\\%1"))
end

local function xpointer_context(doc,result,before_words,after_words)
    if not doc or type(doc.getTextFromXPointers)~="function" then return "","" end
    local start_xp=result.start; local end_xp=result["end"]
    local before_xp=start_xp; local after_xp=end_xp
    if type(doc.getPrevVisibleWordStart)=="function" then
        for _=1,before_words do
            local ok,xp=pcall(doc.getPrevVisibleWordStart,doc,before_xp)
            if not ok or type(xp)~="string" or xp=="" or xp==before_xp then break end
            before_xp=xp
        end
    end
    if type(doc.getNextVisibleWordEnd)=="function" then
        for _=1,after_words do
            local ok,xp=pcall(doc.getNextVisibleWordEnd,doc,after_xp)
            if not ok or type(xp)~="string" or xp=="" or xp==after_xp then break end
            after_xp=xp
        end
    end
    local before,after="",""
    local ok1,v1=pcall(doc.getTextFromXPointers,doc,before_xp,start_xp,false)
    if ok1 then if type(v1)=="table" then v1=v1.text or v1[1] end; before=tostring(v1 or "") end
    local ok2,v2=pcall(doc.getTextFromXPointers,doc,end_xp,after_xp,false)
    if ok2 then if type(v2)=="table" then v2=v2.text or v2[1] end; after=tostring(v2 or "") end
    return before,after
end

local function context_support(doc,result,row)
    local wanted_before=norm(row.context_before); local wanted_after=norm(row.context_after)
    if wanted_before=="" and wanted_after=="" then return false end
    local before,after=xpointer_context(doc,result,12,12)
    before,after=norm(before),norm(after)
    local ok_before=wanted_before=="" or (before~="" and (before:sub(-#wanted_before)==wanted_before or wanted_before:sub(-#before)==before))
    local ok_after=wanted_after=="" or (after~="" and (after:sub(1,#wanted_after)==wanted_after or wanted_after:sub(1,#after)==after))
    return ok_before and ok_after
end

function Runtime:map_current(book_id,chapter_uid,marks,options)
    options=type(options)=="table" and options or {}
    local ui=self.host and self.host.ui or self.ui; local doc=ui and ui.document
    if not (doc and type(doc.findAllText)=="function" and type(doc.getScreenBoxesFromPositions)=="function") then
        self:clear(false); return nil,"runtime_mapping_unavailable"
    end
    if self.host and type(self.host._thoughts_enabled)=="function" and self.host:_thoughts_enabled()~=true then
        self:clear(false); return {mapped=0,missing=0,ambiguous=0,total=0,disabled=true}
    end
    if not self:install(ui) then return nil,"runtime_overlay_unavailable" end
    self.generation=(tonumber(self.generation) or 0)+1; local generation=self.generation
    local wanted_toc=current_toc_index(ui)
    local entries,missing,ambiguous={},0,0
    local max_marks=math.max(1,math.min(300,tonumber(options.max_marks) or 120))
    local rows,by_key,key_sources={},{},{}
    for index,row in ipairs(type(marks)=="table" and marks or {}) do
        if index>max_marks then break end
        local source=U.trim(tostring(row.source_text or ""))
        local length=U.utf8_len(source)
        if source=="" or length<2 or length>300 then missing=missing+1 else
            local key=norm(source)
            if key=="" then missing=missing+1 else
                local item={row=row,source=source,key=key}
                rows[#rows+1]=item; by_key[key]=by_key[key] or {}; by_key[key][#by_key[key]+1]=item; key_sources[key]=source
            end
        end
    end
    local keys={}; for key in pairs(key_sources) do keys[#keys+1]=key end; table.sort(keys)
    local buckets={}; local BATCH_SIZE=12; local MAX_HITS=240
    local function pattern_for(source)
        local compact=U.trim(tostring(source or "")):gsub("%s+"," ")
        return escape_regex(compact):gsub(" ","\\s+")
    end
    for first=1,#keys,BATCH_SIZE do
        if generation~=self.generation then break end
        local last=math.min(#keys,first+BATCH_SIZE-1); local parts,batch_keys={},{}
        for i=first,last do local key=keys[i]; parts[#parts+1]="(?:"..pattern_for(key_sources[key])..")"; batch_keys[key]=true end
        local ok,results=pcall(doc.findAllText,doc,table.concat(parts,"|"),true,0,MAX_HITS,true,0x00FF)
        if ok and type(results)=="table" then
            for _,result in ipairs(results) do
                if type(result)=="table" and result.start and result["end"] and result_in_current_chapter(ui,result,wanted_toc) then
                    local key=norm(result.matched_text)
                    if batch_keys[key] then buckets[key]=buckets[key] or {}; buckets[key][#buckets[key]+1]=result end
                end
            end
        end
    end
    local used={}
    for _,item in ipairs(rows) do
        local candidates=buckets[item.key] or {}; local chosen
        if #candidates==1 and #(by_key[item.key] or {})==1 then chosen=candidates[1]
        elseif #candidates>0 then
            local supported={}
            for ci,candidate in ipairs(candidates) do
                if not used[item.key..":"..tostring(ci)] and context_support(doc,candidate,item.row) then supported[#supported+1]={candidate=candidate,index=ci} end
            end
            if #supported==1 then chosen=supported[1].candidate; used[item.key..":"..tostring(supported[1].index)]=true else ambiguous=ambiguous+1 end
        else missing=missing+1 end
        if chosen then
            entries[#entries+1]={pos0=chosen.start,pos1=chosen["end"],info={book_id=tostring(book_id or ""),chapter_uid=tostring(chapter_uid or ""),range=tostring(item.row.range or "")}}
        end
    end
    self.entries=entries; self.hit_boxes={}; self.scope_key=tostring(book_id or "").."|"..tostring(chapter_uid or ""); self.enabled=true
    self.stats={mapped=#entries,missing=missing,ambiguous=ambiguous,total=#(marks or {})}
    UIManager:setDirty(ui,"ui")
    logger.info("[MiuRead][ThoughtRuntime] mapped","book=",tostring(book_id),"chapter=",tostring(chapter_uid),"mapped=",tostring(#entries),"missing=",tostring(missing),"ambiguous=",tostring(ambiguous))
    return self.stats
end

function Runtime:native_hit_test(pos)
    if type(pos)~="table" then return false end
    local x,y=tonumber(pos.x),tonumber(pos.y); if not x or not y then return false end
    for _,b in ipairs(native_highlight_rects(self.ui)) do if x>=b.x and y>=b.y and x<=b.x+b.w and y<=b.y+b.h then return true end end
    return false
end

function Runtime:hit_test(pos)
    if self.enabled~=true or type(pos)~="table" then return nil end
    if self.host and type(self.host._thoughts_enabled)=="function" and self.host:_thoughts_enabled()~=true then return nil end
    local x,y=tonumber(pos.x),tonumber(pos.y); if not x or not y then return nil end
    for i=#(self.hit_boxes or {}),1,-1 do local b=self.hit_boxes[i]; if x>=b.x and y>=b.y and x<=b.x+b.w and y<=b.y+b.h then return b.info end end
end

return Runtime
