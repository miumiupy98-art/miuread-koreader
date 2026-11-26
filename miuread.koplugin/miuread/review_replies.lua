-- Read-only replies for an individual public thought.
local U=require("miuread.util")
local Json=require("miuread.json")
local M={}
local TTL=30*60
local function clean(value)
    return tostring(value or ""):gsub("[%z\1-\8\11\12\14-\31]","")
end
function M.normalize(payload,id)
    if type(payload)~="table" then return nil,"invalid response" end
    if tonumber(payload.errCode or 0)~=0 then return nil,tostring(payload.errMsg or "server error") end
    local data=type(payload.data)=="table" and payload.data or payload
    -- Real /web/review/single: a thought with no replies can contain only
    -- review metadata and omit the comments key altogether.
    local raw=data.comments or (type(data.review)=="table" and data.review.comments)
        or payload.comments or (type(payload.review)=="table" and payload.review.comments)
    if raw==nil and (type(data.review)=="table" or type(payload.review)=="table") then raw={} end
    if type(raw)~="table" then return nil,"comments missing" end
    local out={}
    for _,item in ipairs(raw) do
        if type(item)=="table" then
            local person=type(item.user)=="table" and item.user or
                type(item.author)=="table" and item.author or {}
            local content=clean(item.content or item.text or item.htmlContent)
            if content~="" then
                out[#out+1]={review_id=tostring(item.commentId or item.reviewId or item.id or ""),
                    author=clean(person.name or person.nick or person.nickname or item.nickName
                        or (type(item.author)=="string" and item.author) or "微信读书用户"),
                    reply_to=type(item.replyUser)=="table" and clean(item.replyUser.name) or nil,
                    content=content,likes=math.max(0,tonumber(item.likesCount or item.likeCount or item.likes) or 0)}
            end
        end
    end
    local count=tonumber(data.commentsCount or data.totalCount or data.total
        or (type(data.review)=="table" and data.review.commentsCount)
        or payload.commentsCount or #out) or #out
    return {id=tostring(id),items=out,total=math.max(#out,count),fetched_at=os.time(),
        truncated=count>#out}
end
local function matches(value,expected)
    return value==nil or (Json.is_null and Json.is_null(value))
        or expected==nil or tostring(expected)=="" or tostring(value)==tostring(expected)
end

function M.normalize_native(payload,id,context,cursor)
    if type(payload)~="table" then return nil,"E-Ink 回复响应无效" end
    local data=type(payload.data)=="table" and payload.data or payload
    local wrap=type(data.review)=="table" and data.review or data
    local review=type(wrap.review)=="table" and wrap.review or wrap
    local code=tonumber(payload.errCode or payload.errcode or data.errCode or data.errcode or 0)
    if code~=0 or not matches(review.reviewId or data.reviewId,id)
        or not matches(review.bookId or data.bookId,context.book_id)
        or not matches(review.chapterUid or data.chapterUid,context.chapter_uid) then
        return nil,"E-Ink 回复数据与当前想法不匹配"
    end
    local raw=data.comments
    if (raw==nil and (review.reviewId~=nil or type(data.review)=="table"))
        or (Json.is_null and Json.is_null(raw)) then raw={} end
    if type(raw)~="table" or #raw>20 then return nil,"E-Ink 回复列表不完整" end
    local offset=cursor and cursor.offset or 0
    local count=tonumber(data.commentsCount or wrap.commentsCount or review.commentsCount)
    if count and (count<0 or count%1~=0) then count=nil end
    local result=M.normalize({comments=raw,commentsCount=count},id)
    local next_offset=offset+#raw
    result.total=count and math.max(next_offset,count) or next_offset
    if #raw>0 and ((count and next_offset<count) or (not count and #raw==20)) then
        result.cursor={offset=next_offset,synckey=tonumber(data.synckey) or (cursor and cursor.synckey) or 0}
    end
    result.truncated=result.cursor~=nil
    return result
end

function M.merge_native(previous,page)
    if not previous then return page end
    local seen={}
    local rows={}
    for _,items in ipairs({previous.items,page.items}) do
        for _,item in ipairs(items) do
            local key=item.review_id~="" and item.review_id or (item.author.."\n"..item.content)
            if not seen[key] then rows[#rows+1]=item; seen[key]=true end
        end
    end
    if #rows==#previous.items then page.cursor=nil; page.truncated=false end
    page.items=rows
    page.total=math.max(#rows,page.total,previous.total)
    return page
end

local function cache_key(id,account)
    return account and ("eink:"..tostring(#account)..":"..account..":"..id) or id
end
local function path(store,book_id)
    local root=book_id and book_id~="" and store:book_cache_path(book_id) or tostring(store.data_dir or "")
    return root.."/review_replies_cache.json"
end

local function read_db(filename)
    local body=U.read_file(filename,true)
    if not body then return {} end
    local ok,db=pcall(Json.decode,body)
    return ok and type(db)=="table" and db or {}
end

function M.load(store,id,allow_expired,account,book_id)
    id=tostring(id or "")
    if id=="" then return nil end
    local key=cache_key(id,account)
    local row=read_db(path(store,book_id))[key]
    if row==nil and book_id and book_id~="" then row=read_db(path(store))[key] end
    if type(row)~="table" or type(row.items)~="table" then return nil end
    if allow_expired~=true and os.time()-(tonumber(row.fetched_at) or 0)>TTL then return nil end
    return row
end

function M.legacy_ids_for_book(store,book_id)
    local ids={}
    for _,row in pairs(read_db(path(store))) do
        if type(row)=="table" and tostring(row.id or "")~="" then ids[#ids+1]=tostring(row.id) end
    end
    if #ids==0 then return {} end
    return require("miuread.thought_database").match_review_ids(store,book_id,ids)
end

function M.prune_legacy(store,ids)
    if not ids or next(ids)==nil then return true end
    local filename=path(store)
    local db=read_db(filename)
    local changed=false
    for key,row in pairs(db) do
        if type(row)=="table" and ids[tostring(row.id or "")] then db[key]=nil;changed=true end
    end
    if not changed then return true end
    local ok,encoded=pcall(Json.encode,db)
    if not ok then return nil,encoded end
    return U.atomic_write(filename,encoded,true)
end

function M.save(store,result,account,book_id)
    if type(result)~="table" or tostring(result.id or "")=="" then return false end
    local filename=path(store,book_id)
    if book_id and book_id~="" then store:book_dir(book_id) end
    local db=read_db(filename)
    db[cache_key(result.id,account)]=result
    local keys={}
    for key in pairs(db) do keys[#keys+1]=key end
    if #keys>128 then
        table.sort(keys,function(a,b)
            return (tonumber((db[a] or {}).fetched_at) or 0)>(tonumber((db[b] or {}).fetched_at) or 0)
        end)
        for i=129,#keys do db[keys[i]]=nil end
    end
    local ok,encoded=pcall(Json.encode,db)
    if not ok then return false,encoded end
    return U.atomic_write(filename,encoded,true)
end
return M
