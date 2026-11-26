local U=require("miuread.util")
local M={}

local function number_id(value)
    local id=tonumber(value)
    return id and id>=0 and id<=2147483647 and id%1==0 and id or nil
end

function M.snapshot(value)
    if type(value)~="table" or type(value.archive)~="table" or type(value.books)~="table" then
        error("微信书架没有返回完整分组",0)
    end
    local groups,books,assignment={},{},{}
    for index,group in pairs(value.archive) do
        if type(index)~="number" or index<1 or index>#value.archive or index%1~=0 then
            error("微信书架没有返回完整分组",0)
        end
        local id=type(group)=="table" and number_id(group.archiveId)
        if not id or id==0 or groups[id] or type(group.name)~="string" then
            error("微信书架返回了无法确认的分组",0)
        end
        local row={id=id,name=group.name,members={}}
        groups[id]=row
        for _,entry in ipairs(group.bookIds or {}) do
            local book=type(entry)=="table" and (entry.bookId or entry.id) or entry
            if type(book)=="string" and book~="" then
                row.members[book]=true
                if assignment[book]~=nil and assignment[book]~=id then assignment[book]=false
                else assignment[book]=id end
            end
        end
    end
    for _,entry in ipairs(value.books) do
        local book=type(entry)=="table" and (entry.bookInfo or entry.book or entry)
        local id=type(book)=="table" and (book.bookId or book.book_id)
        if id then
            id=tostring(id)
            books[id]=true
            if type(entry)=="table" and assignment[id]==nil then
                local assigned=number_id(entry.archiveId or book.archiveId)
                if assigned and assigned>0 then
                    assignment[id]=assigned
                    if groups[assigned] then groups[assigned].members[id]=true end
                end
            end
        end
    end
    return {groups=groups,books=books,assignment=assignment}
end

function M.cached_snapshot(cache)
    local groups=cache and cache.groups
    if type(groups)~="table" or groups.authoritative~=true or cache.stream and cache.stream.enabled==true then return nil end
    local archive,by_id={},{}
    for _,group in ipairs(groups.list or {}) do
        local id=number_id(tostring(group.key or ""):match("^id:(%d+)$"))
        if not id or id==0 then return nil end
        local row={archiveId=id,name=group.name,bookIds={}}
        archive[#archive+1]=row
        by_id[id]=row
    end
    for book,relation in pairs(groups.book_groups or {}) do
        for _,key in ipairs(relation.keys or {}) do
            local group=by_id[number_id(tostring(key):match("^id:(%d+)$"))]
            if group then group.bookIds[#group.bookIds+1]=book end
        end
    end
    return M.snapshot({archive=archive,books=cache.raw_books or {}})
end

function M.change(api,cmd,before)
    before=before or M.snapshot(api:shelf())
    local action=cmd.action
    local id=number_id(cmd.group)
    local name=U.trim(cmd.name or "")
    local book=type(cmd.book)=="string" and cmd.book or ""
    local moving=action=="move" or action=="create"
    if action=="create" or action=="rename" then
        if name=="" or #name>255 or name:find("[%z\1-\31\127]") then error("请输入有效的分组名称",0) end
    end
    if moving and (book=="" or not before.books[book]) then error("请先把这本书加入微信书架",0) end
    if action=="create" then
        id=number_id(os.time())
        while id and before.groups[id] do id=number_id(id+1) end
    elseif action~="move" and action~="rename" and action~="delete" then
        error("无法识别分组操作",0)
    end
    local group=id and before.groups[id]
    if not id or (id==0 and action~="move") or (id>0 and action~="create" and not group) then
        error("分组已变动，请先刷新书架",0)
    end
    if action=="delete" and next(group.members) then error("请先移出组内书籍，再删除分组",0) end
    if action=="move" and before.assignment[book]~=false and (before.assignment[book] or 0)==id then return true end
    if action=="rename" and group.name==name then return true end

    local ok,value=pcall(api.write_shelf_group,api,action,id,name,moving and book or nil)
    if ok and type(value)=="table" and require("miuread.eink_client").write_succeeded(value) then return true end
    if not ok and tostring(value):find("[MiuReadBeforeWrite]",1,true) then error(value,0) end
    -- Check the full cloud snapshot after one POST, including a timed-out POST.
    local after=M.snapshot(api:shelf())
    local new_group=after.groups[id]
    if action=="delete" and not new_group then return true end
    if action=="rename" and new_group and new_group.name==name then return true end
    if moving and after.books[book] and after.assignment[book]~=false and (after.assignment[book] or 0)==id
        and (action~="create" or (new_group and new_group.name==name)) then return true end
    error("微信书架还未确认这次分组变更，请刷新后核对",0)
end

return M
