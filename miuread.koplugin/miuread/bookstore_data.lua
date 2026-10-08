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
        books=books, next_cursor=last,
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
        local out={id=id,title=text(row.title),rank=not id:match("^%d+$"),children={}}
        if out.title=="" then return nil end
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

function M.key(spec)
    return table.concat({tostring(spec.kind),tostring(spec.category_id or spec.book_id or ""),
        tostring(spec.cursor or 0),tostring(spec.session_id or "")}, ":")
end

return M
