-- Only file-bound versions are trustworthy for historical reading. Library
-- metadata, a reader session and the latest cloud catalog may be newer.
local M={}
local function version(value)
    local n=tonumber(value)
    if n and n==n and n>0 and n<=2147483647 and n%1==0 then return n end
end
local function book_id(value)
    return tostring(type(value)=="table" and (value.book_id or value.bookId) or "")
end
function M.resolve(store,record)
    record=type(record)=="table" and record or {}
    local id=book_id(record.book)
    local file=type(record.record)=="table" and record.record or {}
    local path=tostring(record.path or "")
    if id=="" or path=="" or (book_id(file)~="" and book_id(file)~=id)
        or (file.file and tostring(file.file)~=path) then return 0,"unavailable" end
    -- A download staged for installation after the reader closes already has
    -- a NEW version in the library record, while path still contains the OLD
    -- EPUB. Only the current file's embedded identity can resolve that case.
    local pending=file.pending_install==true or (type(file.pending_file)=="string" and file.pending_file~="")
    local n=not pending and (version(file.progress_source_book_version) or version(file.book_version) or version(file.bookVersion))
    if n then return n,"file_record" end
    if type(store.epub_identity)=="function" then
        local ok,identity=pcall(store.epub_identity,store,path)
        if ok and type(identity)=="table" and book_id(identity)==id then
            n=version(identity.progress_source_book_version) or version(identity.book_version) or version(identity.bookVersion)
            if n then return n,"epub_identity" end
        end
    end
    return 0,"unavailable"
end
return M
