local M={}

local function active(value)
    return value==true or tonumber(value)==1
end

function M.account_status(response,now)
    local expires=tonumber(response.expiredTime)
    local remaining=tonumber(response.remainTime)
    if not expires or not remaining or response.expired==nil then return nil end
    if active(response.expired) or remaining<=0 or expires<=now then
        return {observed_at=now,member_until=0,paid_until=0}
    end
    local member_until=math.floor(math.min(expires,now+remaining))
    local paying=active(response.paying) or active(response.isPaying)
    local paid_remaining=tonumber(response.payingRemainTime) or 0
    return {observed_at=now,member_until=member_until,
        paid_until=paying and paid_remaining>0 and math.floor(math.min(member_until,now+paid_remaining)) or 0}
end

function M.active_for(record,grant,snapshot,owner,when)
    if not record.entitlement_owner then return true end
    if record.entitlement_owner~=owner or type(grant)~="table" then return nil end
    if grant.kind=="owned" then return true end
    local expires=tonumber(grant.expires_at)
    if not expires then return nil end
    if grant.kind~="loan" and type(snapshot)=="table" and snapshot.owner==owner
        and tonumber(snapshot.observed_at or 0)>=(tonumber(grant.checked_at) or 0)
        and tonumber(snapshot.observed_at or 0)<=when then
        local key=grant.kind=="paid" and "paid_until" or "member_until"
        expires=tonumber(snapshot[key]) or expires
    end
    return expires>when,expires
end

function M.by_uid(record,uid)
    uid=tostring(uid or "")
    for _,chapter in ipairs(record.chapter_map or {}) do
        if tostring(chapter.uid or chapter.chapterUid or "")==uid then return chapter.entitlement end
    end
end

-- A generated EPUB has one DocFragment per chapter in spine order.
local function fragment(xpointer)
    return type(xpointer)=="string" and tonumber(xpointer:match("/DocFragment%[(%d+)%]")) or nil
end

function M.page_grants(record,document,page,xpointer)
    local chapters=record.chapter_map or {}
    if record.document_format=="txt" then
        -- TXT has no persistent chapter anchors in CRE. A page mapped by
        -- percentage may straddle chapters, so use every applicable boundary.
        return chapters
    end
    local first=fragment(xpointer)
    local function at(index)
        if not index or not document.getPageXPointer then return nil end
        local ok,value=pcall(document.getPageXPointer,document,index)
        return ok and fragment(value) or nil
    end
    first=first or at(page)
    if not first or not chapters[first] then return {} end
    local last=not xpointer and page and at(page+1)
    last=last and math.min(math.max(last,first),#chapters) or first
    local rows={}
    for index=first,last do rows[#rows+1]=chapters[index] end
    return rows
end

function M.window_end(record,chapters,snapshot,owner,when)
    if #chapters==0 then return nil end
    local valid,first_expiry=true,nil
    for _,chapter in ipairs(chapters) do
        local allowed,expires=M.active_for(record,chapter.entitlement,snapshot,owner,when)
        if allowed==nil then return nil end
        if allowed==false then valid=false end
        if expires then first_expiry=math.min(first_expiry or expires,expires) end
    end
    return valid,first_expiry
end

function M.clip_span(span,expires)
    if not expires then return span end
    local start,duration=tonumber(span.start_time),tonumber(span.duration)
    if not start or not duration or start>=expires then return nil end
    if start+duration<=expires then return span end
    return {page=span.page,start_time=start,source_start=span.source_start,duration=expires-start}
end

function M.reminder_due(choice,now)
    return choice~="never" and (tonumber(choice) or 0)<=now
end

return M
