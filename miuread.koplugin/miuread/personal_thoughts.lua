local U=require("miuread.util")
local Json=require("miuread.json")
local DownloadDatabase=require("miuread.download_database")
local M={}

local function identity(store,book)
    local account=DownloadDatabase.account_key(store)
    if account=="anonymous" or tostring(book or "")=="" then return end
    return store:book_cache_path(book).."/personal-thoughts-"..account..".json",account
end

function M.load(store,book)
    local path,account=identity(store,book)
    if not path then return end
    local raw=U.read_file(path,true)
    if not raw then return end
    local ok,data=pcall(Json.decode,raw)
    if ok and type(data)=="table" and data.account==account and data.book==tostring(book)
        and type(data.rows)=="table" and tonumber(data.checked_at) then return data end
end

function M.save(store,book,rows,checked_at,present_ids)
    local path,account=identity(store,book)
    if not path or type(rows)~="table" then return false end
    checked_at=tonumber(checked_at) or os.time()
    local previous=M.load(store,book)
    if previous and tonumber(previous.checked_at)>checked_at then return false end
    local removed_ids={}
    if previous and type(present_ids)=="table" then
        for id in pairs(previous.removed_ids or {}) do
            if not present_ids[id] then removed_ids[id]=true end
        end
        for _,row in ipairs(previous.rows) do
            local id=row.review_id
            if type(id)=="string" and id~="" and not present_ids[id] then removed_ids[id]=true end
        end
    end
    store:book_dir(book)
    return U.atomic_write(path,Json.encode{account=account,book=tostring(book),
        checked_at=checked_at,rows=rows,present_ids=present_ids,removed_ids=removed_ids},true)
end

function M.combine(local_rows,cloud)
    local merged,cloud_by_id,seen={},{},{}
    for _,row in ipairs(cloud and cloud.rows or {}) do cloud_by_id[row.review_id]=row end
    for _,row in ipairs(local_rows or {}) do
        if row.kind=="thought" or row.sync_kind=="thought" then
            local id=row.remote_id or ""
            local current=cloud_by_id[id]
            if row.present==false then
                if id~="" then seen[id]=true end
            elseif id=="" or not seen[id] then
                if id~="" then seen[id]=true end
                local vanished=id~="" and not current and row.sync_state=="synced"
                    and cloud and type(cloud.present_ids)=="table" and not cloud.present_ids[id]
                    and tonumber(cloud.checked_at)>(tonumber(row.last_attempt_at) or 0)
                if not vanished then
                    local use_cloud=current and current.content~="" and row.sync_state=="synced"
                    local cloud_position=use_cloud and current.chapter_uid and current.chapter_uid~=""
                        and current.range and current.range~=""
                    local chapter_uid,range,quote,version=row.chapter_uid,row.range_key,row.selected_text,row.book_version
                    if cloud_position then
                        local same_position=chapter_uid==current.chapter_uid and range==current.range
                        chapter_uid,range=current.chapter_uid,current.range
                        quote=current.quote and current.quote~="" and current.quote or (same_position and quote or nil)
                        version=current.book_version or (same_position and version or nil)
                    end
                    local status=row.sync_state
                    if status=="local_only" and current and row.synced_note~=nil
                        and current.content~=row.synced_note and current.content~=row.note then status="conflict" end
                    merged[#merged+1]={review_id=id,local_id=row.local_id,kind="thought",
                        content=use_cloud and current.content or row.note,
                        chapter_uid=chapter_uid,book_version=version,range=range,quote=quote,
                        chapter=use_cloud and current.chapter or "",
                        status=status,updated_at=use_cloud and current.updated_at or row.updated_at,
                        source=row,remote=current}
                end
            end
        end
    end
    for _,row in ipairs(cloud and cloud.rows or {}) do
        if not seen[row.review_id] then merged[#merged+1]=row end
    end
    table.sort(merged,function(a,b)
        local left,right=tonumber(a.updated_at) or 0,tonumber(b.updated_at) or 0
        if left~=right then return left>right end
        return tostring(a.local_id or a.review_id)<tostring(b.local_id or b.review_id)
    end)
    return merged
end

function M.popup_rows(own,public,removed)
    local rows,seen,hidden={},{},{}
    for _,note in ipairs(own or {}) do
        local id=tostring(note.review_id or "")
        rows[#rows+1]={author="我的想法",content=note.content,own=true,review_id=id,note=note}
        if id~="" then seen[id]=true end
    end
    for _,item in ipairs(public or {}) do
        local id=tostring(item.review_id or "")
        if removed and removed[id] then hidden[#hidden+1]=id
        elseif not seen[id] then rows[#rows+1]=item end
    end
    return rows,table.concat(hidden,",")
end

return M
