-- beta.16: provenance of an exact Web Reader chapter response, not a
-- claim that EPUB text or any current reader XPointer maps to an exact co.
-- Sidecars never replace the existing coordinate-source XHTML cache.
local U=require("miuread.util")
local Json=require("miuread.json")
local Digest=require("miuread.digests")
local M={}
local function account(reader)
    local store=reader and reader.store
    if not store or type(store.auth)~="function" then return nil end
    local auth=store:auth() or {}
    local vid=tostring(((auth.account or {}).vid) or "")
    local session=tostring(auth.login_session_id or "")
    if vid=="" or session=="" then return nil end
    return vid.."|"..session
end
local function path(reader,book_id,uid,version)
    local store=reader and reader.store
    if not store or type(store.book_dir)~="function" then return nil end
    if tostring(book_id or "")=="" or tostring(uid or "")=="" or tonumber(version or 0)<=0 then return nil end
    return store:book_dir(tostring(book_id)).."/progress-source-provenance/"
        ..U.id_name(tostring(uid)).."-v"..U.id_name(tostring(version))..".json"
end
function M.is_trusted(reader,book_id,uid,version,web)
    local p=path(reader,book_id,uid,version)
    local a=account(reader)
    if not p or not a or type(web)~="string" or web=="" then return false end
    local raw=U.read_file(p,true)
    if not raw then return false end
    local ok,value=pcall(Json.decode,raw)
    if not ok or type(value)~="table" or value.schema~=1 or value.account~=a
        or value.book_id~=tostring(book_id) or value.chapter_uid~=tostring(uid)
        or tonumber(value.version)~=tonumber(version) or tonumber(value.bytes)~=#web then return false end
    return value.md5==Digest.md5(web)
end
function M.mark(reader,book_id,uid,version,web)
    local p=path(reader,book_id,uid,version)
    local a=account(reader)
    if not p or not a or type(web)~="string" or web=="" then return nil,"provenance_identity_missing" end
    local root=p:match("^(.+)/[^/]+$")
    U.mkdir(root)
    local payload={schema=1,account=a,book_id=tostring(book_id),chapter_uid=tostring(uid),
        version=tonumber(version),bytes=#web,md5=Digest.md5(web),source="web_reader",created_at=os.time()}
    local ok,serialized=pcall(Json.encode,payload)
    if not ok then return nil,"provenance_json:"..tostring(serialized) end
    local wrote,why=U.atomic_write(p,serialized,true)
    if not wrote then return nil,"provenance_write:"..tostring(why) end
    return true
end
return M
