-- Response normalization shared by the bookstore UI and background workers.
local U = require("miuread.util")
local M = {PAGE_SIZE=20, CACHE_TTL=15*60, CACHE_LIMIT=24}

local function number(value)
    local n=tonumber(value)
    if n and n==n and n~=math.huge and n~=-math.huge then return n end
end

local function text(value)
    return (type(value)=="string" or type(value)=="number") and tostring(value) or ""
end

local function category_title(row,id)
    for _,key in ipairs({"title","name"}) do
        local title=U.trim(text(row[key]))
        if title~="" and title:lower()~=id:lower() then return title end
    end
end

function M.book(row)
    if type(row)~="table" then return nil end
    local b=row
    for _=1,4 do
        if type(b.bookInfo)=="table" then b=b.bookInfo
        elseif type(b.book)=="table" then b=b.book
        else break end
    end
    local id=text(b.bookId or b.book_id or row.bookId)
    if id=="" then return nil end
    return {
        bookId=id, title=text(b.title)~="" and text(b.title) or "未命名",
        author=text(b.author), cover=text(b.cover), category=text(b.category),
        intro=U.utf8_truncate(text(b.intro or b.description),600,"…"),
        reason=U.utf8_truncate(text(row.reason or b.reason),100,"…"),
        newRating=number(b.newRating or row.newRating),
        readingCount=number(b.readingCount or row.readingCount),
        searchIdx=number(row.searchIdx or row.idx or b.searchIdx or b.idx),
    }
end

function M.page(kind,data,cursor,count)
    if type(data)~="table" then error("bookstore response is not an object") end
    local container=kind=="similar" and data.booksimilar or data
    if type(container)~="table" or type(container.books)~="table" then
        error("bookstore response is missing its book list")
    end
    cursor=number(cursor) or 0
    local books,seen,last={}, {},cursor
    for _,row in ipairs(container.books) do
        local b=M.book(row)
        local idx=type(row)=="table" and number(row.searchIdx or row.idx) or nil
        idx=idx or (b and b.searchIdx)
        if idx then last=math.max(last,idx) end
        if b and not seen[b.bookId] then
            seen[b.bookId]=true
            books[#books+1]=b
        end
    end
    local more=container.hasMore
    if more==nil then more=#container.books>=(number(count) or M.PAGE_SIZE) end
    return {
        books=books, next_cursor=last,channel=data._api_channel,
        has_more=(more==true or tonumber(more)==1) and last>cursor,
        session_id=text(container.sessionId), total=number(container.totalCount),
    }
end

-- /web/categories groups rankings and publication categories in data[].
-- Retain the supplied subcategory hierarchy rather than flattening it.
function M.categories(data)
    if type(data)~="table" or type(data.data)~="table" then
        error("bookstore categories response is missing its category list")
    end
    local ranks,categories,seen,visited={},{},{},{}
    local function parse(row,depth)
        if type(row)~="table" or depth>8 or visited[row] then return nil end
        visited[row]=true
        local id=text(row.CategoryId or row.categoryId)
        if id=="" or not id:match("^[%w_%-]+$") then return nil end
        if row.type~=nil and tonumber(row.type)~=0 then return nil end
        local title=category_title(row,id)
        if not title then return nil end
        local out={id=id,title=title,rank=not id:match("^%d+$"),children={},channel=data._api_channel}
        for _,child in ipairs(type(row.sublist)=="table" and row.sublist or {}) do
            local entry=parse(child,depth+1)
            if entry then out.children[#out.children+1]=entry end
        end
        return out
    end
    local function visit(rows,depth)
        if type(rows)~="table" or depth>8 then return end
        for _,row in ipairs(rows) do
            if type(row)=="table" then
                if type(row.categories)=="table" then visit(row.categories,depth+1)
                else
                    local entry=parse(row,0)
                    if entry and not seen[entry.id] then
                        seen[entry.id]=true
                        local list=entry.rank and ranks or categories
                        list[#list+1]=entry
                    end
                end
            end
        end
    end
    visit(data.data,0)
    return {ranks=ranks,categories=categories}
end

local function home_categories(rows,rank,depth)
    local categories={}
    if type(rows)~="table" or depth>8 then return categories end
    for _,row in ipairs(rows) do
        if type(row)=="table" then
            local id=text(row.CategoryId or row.categoryId)
            local title=category_title(row,id)
            if id:match("^[%w_%-]+$") and title then
                local covers={}
                for _,cover in ipairs(type(row.covers)=="table" and row.covers or {}) do
                    if type(cover)=="string" and cover~="" then covers[#covers+1]=cover end
                end
                categories[#categories+1]={id=id,title=title,rank=rank,covers=covers,channel="eink",
                    children=home_categories(row.sublist,rank,depth+1)}
            end
        end
    end
    return categories
end

function M.home(data)
    if type(data)~="table" or (type(data.data)~="table" and type(data.updated)~="table") then
        error("微信读书书城首页响应不完整")
    end
    local order,by_type={},{}
    for _,key in ipairs({"data","updated"}) do
        for _,row in ipairs(type(data[key])=="table" and data[key] or {}) do
            local kind=type(row)=="table" and tonumber(row.type)
            if kind and (kind==12 or kind==23 or kind==40 or kind==41
                or (kind>=101 and kind<200) or (kind>=1001 and kind<1100)) then
                if not by_type[kind] then order[#order+1]=kind end
                by_type[kind]=row
            end
        end
    end
    local sections={}
    for _,kind in ipairs(order) do
        local row=by_type[kind]
        local rank=kind>=1001
        local books,seen={},{}
        local function add_books(list)
            for _,entry in ipairs(type(list)=="table" and list or {}) do
                local book=M.book(entry)
                local info=book and (entry.bookInfo or entry.book or entry)
                if type(info)=="table" and not seen[book.bookId] then
                    local paid=info.paid==true or tonumber(info.paid)==1
                    local paper_trial=math.floor((tonumber(info.payType) or 0)/524288)%2==1 and not paid
                    if tonumber(info.ispub)~=2 and ((tonumber(info.soldout) or 0)==0 or paper_trial) then
                        books[#books+1]=book
                        seen[book.bookId]=true
                    end
                end
            end
        end
        if rank and type(row.categories)=="table" then
            for _,category in ipairs(row.categories) do
                if type(category)=="table" then
                    add_books(category.lectureBooks or category.books)
                    if #books>0 then break end
                end
            end
        end
        if #books==0 then add_books(row.books) end
        local categories=home_categories(row.categories,rank,0)
        local title=text(row.name)
        for _,category in ipairs(categories) do
            if title:lower()==category.id:lower() then title=category.title; break end
        end
        if title~="" and (#books>0 or #categories>0) then
            sections[#sections+1]={kind=kind,title=title,books=books,categories=categories}
        end
    end
    local hint=type(data.search)=="table" and text(data.search.text) or ""
    return {sections=sections,search_hint=hint}
end

function M.shelf_state(data,id,full_shelf)
    if type(data)~="table" then return nil end
    local rows=full_shelf and data.books or data.data
    if type(rows)~="table" then return nil end
    for _,row in ipairs(rows) do
        local b=M.book(row)
        if b and b.bookId==tostring(id) then
            if full_shelf then return true end
            if row.onShelf==true or tonumber(row.onShelf)==1 then return true end
            if row.onShelf==false or tonumber(row.onShelf)==0 then return false end
            return nil
        end
    end
    -- A complete shelf is authoritative for absence. A partial membership
    -- response without the requested row is not.
    if full_shelf then return false end
end

function M.recent_books(data)
    if type(data)~="table" or type(data.items)~="table" then
        error("微信读书最近阅读列表不完整")
    end
    -- An empty feed means retain the last accepted list.
    if next(data.items)==nil then return {unchanged=true,books={}} end
    if #data.items==0 then error("微信读书最近阅读列表格式无效") end
    local books,seen={},{}
    local function flagged(value) return value==true or value=="true" or tonumber(value)==1 end
    local timestamp=require("miuread.shelf_progress").timestamp
    for _,entry in ipairs(data.items) do
        if type(entry)=="table" and type(entry.book)=="table" and not flagged(entry.isTTS)
            and not flagged(entry.isRecommend) and (tonumber(entry.book.type) or 0)==0 then
            local book=M.book(entry.book)
            if book and not seen[book.bookId] then
                seen[book.bookId]=true
                book.last_opened=timestamp(entry.readUpdateTime or entry.readTime or entry.updateTime
                    or entry.book.readUpdateTime or entry.book.lastReadTime)
                book.cloud_recent_order=#books+1
                books[#books+1]=book
                if #books==8 then break end
            end
        end
    end
    return {books=books}
end

function M.key(spec)
    return table.concat({tostring(spec.kind),tostring(spec.category_id or spec.book_id or ""),
        tostring(spec.cursor or 0),tostring(spec.session_id or ""),tostring(spec.channel or "")}, ":")
end

return M
