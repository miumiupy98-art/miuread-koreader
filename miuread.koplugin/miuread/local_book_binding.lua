-- beta.27: local EPUB <-> WeRead catalog associations. This is *only*
-- community metadata, not a cloud reading session or a book download record.
local Json=require("miuread.json")
local U=require("miuread.util")
local lfs=require("libs/libkoreader-lfs")
local Binding={};Binding.__index=Binding
local function hash_chunk(hash,text)
    for i=1,#text do hash=(hash*33+text:byte(i))%4294967296 end
    return hash
end
function Binding.fingerprint(path)
    if type(path)~="string" or not path:lower():match("%.epub$") then return nil end
    local attr=lfs.attributes(path)
    if not attr or attr.mode~="file" then return nil end
    local file=io.open(path,"rb")
    if not file then return nil end
    local size=tonumber(attr.size) or 0
    local start=file:read(8192) or ""
    if size>8192 then file:seek("set",math.max(0,size-8192)) end
    local ending=file:read(8192) or ""
    file:close()
    local hash=hash_chunk(hash_chunk(5381,start),ending)
    return string.format("%d-%08x",size,hash)
end
function Binding:new(store)
    local root=tostring(store and store.data_dir or "")
    return setmetatable({path=root.."/local_book_bindings.json",data=nil},self)
end
function Binding:_all()
    if self.data then return self.data end
    local data={version=1,files={}}
    local file=io.open(self.path,"rb")
    if file then
        local body=file:read("*a");file:close()
        local ok,result=pcall(Json.decode,body or "")
        if ok and type(result)=="table" and type(result.files)=="table" then data=result end
    end
    self.data=data
    return data
end
function Binding:_save()
    local ok,encoded=pcall(Json.encode,self:_all())
    if not ok then return false,encoded end
    return U.atomic_write(self.path,encoded,true)
end
function Binding:for_path(path,create)
    local fp=Binding.fingerprint(path)
    if not fp then return nil,nil end
    local files=self:_all().files
    local entry=files[fp]
    if not entry and create then
        entry={books={},manual={},locations={}}
        files[fp]=entry
    end
    return entry,fp
end
function Binding:books(path)
    local entry=self:for_path(path)
    return entry and entry.books or {}
end
function Binding:bind(path,book,chapters)
    local id=tostring(book and (book.bookId or book.book_id) or "")
    if id=="" then return false,"bookId missing" end
    local entry=self:for_path(path,true)
    if not entry then return false,"invalid EPUB" end
    local result={bookId=id,title=tostring(book.title or book.name or id),author=tostring(book.author or ""),catalog={}}
    for _,ch in ipairs(chapters or {}) do
        local uid=tostring(ch.chapterUid or ch.uid or ch.chapter_uid or "")
        if uid~="" then result.catalog[#result.catalog+1]={chapterUid=uid,title=tostring(ch.title or "")} end
    end
    entry.books[id]=result
    return self:_save()
end
function Binding:unbind(path,id)
    local entry=self:for_path(path)
    if not entry then return false,"not bound" end
    id=tostring(id or "")
    entry.books[id]=nil
    for local_idx,list in pairs(entry.manual or {}) do
        for i=#list,1,-1 do if list[i].bookId==id then table.remove(list,i) end end
        if #list==0 then entry.manual[local_idx]=nil end
    end
    return self:_save()
end
function Binding:assign(path,index,book_id,uid,append)
    local entry=self:for_path(path)
    if not entry or not entry.books[tostring(book_id)] then return false,"book not bound" end
    index=tostring(math.floor(tonumber(index) or 0))
    if index=="0" or tostring(uid or "")=="" then return false,"invalid chapter" end
    local row={bookId=tostring(book_id),chapterUid=tostring(uid)}
    local assignments=append and (entry.manual[index] or {}) or {}
    for _,existing in ipairs(assignments) do
        if existing.bookId==row.bookId and existing.chapterUid==row.chapterUid then return true end
    end
    assignments[#assignments+1]=row
    entry.manual[index]=assignments
    return self:_save()
end
function Binding:clear_assignment(path,index)
    local entry=self:for_path(path)
    if not entry then return false end
    entry.manual[tostring(index)]=nil
    return self:_save()
end
-- Positions for locally-imported EPUBs never share the downloaded-book DB's
-- chapter/range key. The document fingerprint is the primary cache namespace.
function Binding:locations(path,book_id,uid,local_index)
    local entry=self:for_path(path)
    local key=tostring(book_id)..":"..tostring(uid)..":"..tostring(local_index or "")
    return entry and entry.locations and entry.locations[key] or {}
end
function Binding:save_locations(path,book_id,uid,rows,local_index)
    local entry=self:for_path(path,true)
    if not entry then return false,"invalid EPUB" end
    entry.locations=entry.locations or {}
    local key=tostring(book_id)..":"..tostring(uid)..":"..tostring(local_index or "")
    local saved=entry.locations[key] or {}
    for _,row in ipairs(rows or {}) do
        if tostring(row.range or "")~="" then saved[tostring(row.range)]=row end
    end
    entry.locations[key]=saved
    return self:_save()
end
return Binding
