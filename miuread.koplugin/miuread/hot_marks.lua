local Json=require("miuread.json")
local M={LIMIT=500}

local function scalar(value)
    if type(value)=="string" or type(value)=="number" then return tostring(value) end
    return ""
end

local function integer(value)
    local n=tonumber(value)
    if n and n>=0 and n%1==0 then return n end
end

local function present(value)
    return value~=nil and not Json.is_null(value)
end

function M.normalize(payload,book_id)
    if type(payload)~="table" then return nil,"热门划线响应无效" end
    local code=tonumber(payload.errcode or payload.errCode or 0)
    if code~=0 then return nil,"热门划线请求失败" end
    if present(payload.bookId) and scalar(payload.bookId)~=book_id then
        return nil,"热门划线响应与当前书籍不匹配"
    end
    local result={rows={},partial=payload.hasMore==true or tonumber(payload.hasMore)==1}
    local chapters={}
    for _,row in ipairs(type(payload.chapters)=="table" and payload.chapters or {}) do
        if type(row)=="table" and integer(row.chapterUid) then chapters[tostring(integer(row.chapterUid))]=row end
    end
    local by_range,by_id={},{}
    local saw_list=false
    for _,key in ipairs({"data","updated"}) do
        local list=payload[key]
        if list~=nil then saw_list=true end
        if present(list) then
            if type(list)~="table" then return nil,"热门划线列表无效" end
            if #list>M.LIMIT then result.partial=true end
            for i=1,math.min(#list,M.LIMIT) do
                local row=list[i]
                if type(row)=="table" and present(row.bookId) and scalar(row.bookId)~=book_id then
                    return nil,"热门划线响应包含其他书籍"
                end
                local uid=type(row)=="table" and integer(row.chapterUid)
                local first,last
                if uid then first,last=scalar(row.range):match("^(%d+)%-(%d+)$") end
                first,last=integer(first),integer(last)
                if uid and first and last and last>first and type(row.markText)=="string" and row.markText~="" then
                    uid=tostring(uid)
                    local chapter=chapters[uid] or {}
                    local id=scalar(row.bestMarkContentId or row.bookmarkId)
                    local range=string.format("%.0f-%.0f",first,last)
                    local range_key=uid..":"..range
                    local slot=by_range[range_key] or (id~="" and by_id[id]) or #result.rows+1
                    if slot<=M.LIMIT then
                        local title=scalar(row.title)
                        result.rows[slot]={id=id,chapter_uid=uid,
                            chapter_index=integer(row.chapterIdx) or integer(chapter.chapterIdx) or 0,
                            chapter_title=title~="" and title or scalar(chapter.title),
                            range=range,first=first,last=last,text=row.markText,count=integer(row.totalCount) or 0}
                        by_range[range_key]=slot
                        if id~="" then by_id[id]=slot end
                    else result.partial=true end
                else result.partial=true end
            end
        end
    end
    if not saw_list then return nil,"热门划线响应缺少列表" end
    result.total=math.max(#result.rows,integer(payload.totalCount) or 0)
    result.partial=result.partial or result.total>#result.rows
    table.sort(result.rows,function(a,b)
        if a.chapter_index~=b.chapter_index then return a.chapter_index<b.chapter_index end
        if a.chapter_uid~=b.chapter_uid then return tonumber(a.chapter_uid)<tonumber(b.chapter_uid) end
        if a.first~=b.first then return a.first<b.first end
        return a.last<b.last
    end)
    return result
end
return M
