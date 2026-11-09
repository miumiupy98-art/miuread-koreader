-- beta.27: read-only replies for an individual public thought.
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
                out[#out+1]={review_id=tostring(item.reviewId or item.id or ""),
                    author=clean(person.name or person.nick or person.nickname or item.nickName
                        or (type(item.author)=="string" and item.author) or "微信读书用户"),
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
local function path(store) return tostring(store.data_dir or "").."/review_replies_cache.json" end
function M.load(store,id,allow_expired)
    id=tostring(id or "")
    if id=="" then return nil end
    local file=io.open(path(store),"rb")
    if not file then return nil end
    local body=file:read("*a");file:close()
    local ok,db=pcall(Json.decode,body or "")
    if not ok or type(db)~="table" then return nil end
    local row=db[id]
    if type(row)~="table" or type(row.items)~="table" then return nil end
    if allow_expired~=true and os.time()-(tonumber(row.fetched_at) or 0)>TTL then return nil end
    return row
end
function M.save(store,result)
    if type(result)~="table" or tostring(result.id or "")=="" then return false end
    local filename=path(store)
    local file=io.open(filename,"rb")
    local db={}
    if file then
        local body=file:read("*a");file:close()
        local ok,old=pcall(Json.decode,body or "")
        if ok and type(old)=="table" then db=old end
    end
    db[result.id]=result
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
