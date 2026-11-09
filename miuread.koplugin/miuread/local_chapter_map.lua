-- beta.27: normalized TOC matching, manual mappings, and quote-based evidence.
-- Mapping is scoped to the local EPUB. Never interprets server offsets as CRe XPointer.
local M={}
function M.title_key(value)
    local text=tostring(value or ""):lower()
    text=text:gsub("^%s+",""):gsub("%s+$","")
    for _,marker in ipairs({"章","节","回","卷","篇","部"}) do
        local next_text,count=text:gsub("^第.-"..marker.."%s*", "", 1)
        if count>0 then text=next_text;break end
    end
    text=text:gsub("^chapter%s*[%d%.%-]+[%s:%.%-]*","")
    text=text:gsub("^[%d%.%-%s]+",""):gsub("^、", "")
    return text:gsub("[%s%p]",""):gsub("[。，：；！？《》【】（）]","")
end
function M.snapshot(ui)
    local toc=ui and ui.toc
    if not toc then return {} end
    if type(toc.toc)~="table" and type(toc.fillToc)=="function" then
        pcall(toc.fillToc,toc)
    end
    local rows={}
    for index,row in ipairs(toc.toc or {}) do
        rows[#rows+1]={index=index,title=tostring(row.title or row.text or ""),
            xpointer=row.xpointer or row.xp,page=row.page or row.pageno}
    end
    return rows
end
function M.current_index(ui)
    local toc=ui and ui.toc
    if not toc or type(toc.getTocIndexByPage)~="function" then return nil end
    local xp=ui.rolling and ui.rolling.xpointer
    local doc=ui.document
    if (not xp or xp=="") and doc and type(doc.getXPointer)=="function" then
        local ok,value=pcall(doc.getXPointer,doc);if ok then xp=value end
    end
    if not xp then return nil end
    local ok,index=pcall(toc.getTocIndexByPage,toc,xp)
    index=ok and tonumber(index) or nil
    if index and index>=1 then return math.floor(index) end
end
local function number_of(v) return tonumber(v or 0) or 0 end
function M.targets(entry,local_rows,index)
    if not entry then return {} end
    index=number_of(index)
    if index<1 then return {} end
    local local_row=local_rows[index]
    if not local_row then return {} end
    local manual=entry.manual and entry.manual[tostring(index)]
    if type(manual)=="table" and #manual>0 then
        local out={}
        for _,target in ipairs(manual) do
            local book=entry.books[target.bookId]
            if book then
                for _,remote in ipairs(book.catalog or {}) do
                    if tostring(remote.chapterUid)==tostring(target.chapterUid) then
                        out[#out+1]={bookId=target.bookId,book=book,chapterUid=target.chapterUid,
                            title=remote.title,manual=true,local_index=index}
                        break
                    end
                end
            end
        end
        return out
    end
    local key=M.title_key(local_row.title)
    if key=="" then return {} end
    -- A unique remote chapter title in a single bound book is sufficient.
    -- For multiple books (anthologies), each may contribute an exact title.
    local candidates={}
    for id,book in pairs(entry.books or {}) do
        local found={}
        for _,remote in ipairs(book.catalog or {}) do
            if M.title_key(remote.title)==key then found[#found+1]=remote end
        end
        if #found==1 then
            local remote=found[1]
            candidates[#candidates+1]={bookId=id,book=book,chapterUid=remote.chapterUid,
                title=remote.title,manual=false,local_index=index}
        end
    end
    table.sort(candidates,function(a,b) return a.bookId<b.bookId end)
    return candidates
end
function M.bounds(ui,local_rows,index)
    local doc=ui and ui.document
    local start=local_rows[index]
    local next_row=local_rows[index+1]
    if not start or not doc then return nil end
    local function xp(row)
        if not row then return nil end
        if row.xpointer then return row.xpointer end
        if tonumber(row.page) and type(doc.getPageXPointer)=="function" then
            local ok,value=pcall(doc.getPageXPointer,doc,tonumber(row.page))
            if ok then return value end
        end
    end
    local first=xp(start)
    if not first then return nil end
    return {start=first,ending=xp(next_row),local_index=index}
end
-- Check cached public quote snippets against the current local TOC interval.
-- This runs only on an explicit user action, not at every page turn.
function M.vote_for_current(ui,local_rows,index,remote_books,load_groups)
    local doc=ui and ui.document
    local bounds=M.bounds(ui,local_rows,index)
    if not bounds or not bounds.ending or not doc or
        type(doc.findAllText)~="function" or type(doc.compareXPointers)~="function" then
        return nil,"本地章节边界不足，无法按原文匹配"
    end
    local votes={}
    local attempts=0
    for id,book in pairs(remote_books or {}) do
        for _,chapter in ipairs(book.catalog or {}) do
            local groups=load_groups(id,chapter.chapterUid) or {}
            local score=0
            local seen_quotes={}
            for _,group in ipairs(groups) do
                for _,thought in ipairs(group.texts or {}) do
                    local quote=tostring(thought.abstract or "")
                    if #quote>=18 and #quote<=450 and attempts<60 and not seen_quotes[quote] then
                        seen_quotes[quote]=true
                        attempts=attempts+1
                        local ok,hits=pcall(doc.findAllText,doc,quote,true,0,16,false,0)
                        if ok and type(hits)=="table" then
                            for _,hit in ipairs(hits) do
                                local x0,x1=hit.start,hit["end"]
                                if x0 and x1 then
                                    local a,b=pcall(doc.compareXPointers,doc,bounds.start,x0)
                                    local c,d=pcall(doc.compareXPointers,doc,x1,bounds.ending)
                                    if a and b~=-1 and c and d==1 then score=score+1;break end
                                end
                            end
                        end
                    end
                    if score>=3 or attempts>=60 then break end
                end
                if score>=3 or attempts>=60 then break end
            end
            if score>=2 then votes[#votes+1]={bookId=id,chapterUid=chapter.chapterUid,
                title=chapter.title,score=score} end
            if attempts>=60 then break end
        end
        if attempts>=60 then break end
    end
    if type(doc.clearSelection)=="function" then pcall(doc.clearSelection,doc) end
    table.sort(votes,function(a,b) return a.score>b.score end)
    if #votes==0 then return nil,"无足够原文证据，请手动选择章节" end
    if #votes>1 and votes[1].score==votes[2].score then return nil,"多个章节同分，请手动选择" end
    return votes[1]
end
return M
