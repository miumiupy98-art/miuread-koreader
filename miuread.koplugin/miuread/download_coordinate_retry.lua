-- 6.5.0-beta.11: durable, low-priority retry of PRE-INSTALL Web coordinate
-- validation. This queue contains NO reading-progress data and NO credentials.
-- A new book/EPUB is never published by this module; only Downloader's gate
-- can authorize installation after complete, authoritative Web validation.
local U=require("miuread.util")
local M={}
local KEY="download_coordinate_retry_v1"
local LIMIT=12
local ALLOWED_OPTIONS={
    annotations=true,images=true,limit=true,chapter_uid=true,
    range_start_index=true,range_end_index=true,range_start_uid=true,range_end_uid=true,
    content_only=true,kind=true,edition=true,generate_translation_uid=true,
    translation_mode=true,generate_translation=true,network_mode=true,
}
local function identifier(book,opt)
    local id=tostring(book and (book.bookId or book.book_id) or "")
    if id=="" then return nil end
    opt=type(opt)=="table" and opt or {}
    return table.concat({id,opt.annotations==true and "notes" or "clean",
        tostring(opt.chapter_uid or "all"),tostring(opt.limit or "all"),
        tostring(opt.range_start_index or ""),tostring(opt.range_end_index or ""),
        tostring(opt.generate_translation_uid or "")},":")
end
M.key=identifier
local function clean_book(book)
    if type(book)~="table" then return nil end
    local safe={}
    for _,name in ipairs({"bookId","book_id","title","author","cover","version","content_type","publisher","type"}) do
        local v=book[name]
        if type(v)=="string" or type(v)=="number" or type(v)=="boolean" then safe[name]=v end
    end
    if safe.bookId==nil then safe.bookId=safe.book_id end
    return safe.bookId and safe or nil
end
local function clean_options(opt)
    local result={}
    for k,v in pairs(type(opt)=="table" and opt or {}) do
        if ALLOWED_OPTIONS[k] and (type(v)=="string" or type(v)=="number" or type(v)=="boolean") then
            result[k]=v
        end
    end
    result._from_checkpoint=true
    result._coordinate_auto_retry=true
    return result
end
local function load(store)
    local rows=store:get(KEY,{})
    if type(rows)~="table" then return {} end
    local result={}
    for _,row in ipairs(rows) do
        if type(row)=="table" and tostring(row.key or "")~=""
            and type(row.book)=="table" and type(row.options)=="table" then
            result[#result+1]=row
        end
        if #result>=LIMIT then break end
    end
    return result
end
M.load=load
local function save(store,rows)
    return store:set(KEY,rows)
end
function M.reason_kind(reason)
    local s=tostring(reason or ""):lower()
    if s:find("web_source_validation_failed:",1,true)
        or s:find("anchor_mismatch",1,true)
        or s:find("ambiguous",1,true)
        or s:find("source_mismatch",1,true)
        or s:find("local_coordinate_html_missing",1,true)
        or s:find("local_chapter_checkpoint_missing",1,true)
        or s:find("web_source_not_authoritative",1,true) then return "mapping" end
    if s:find("rate_limit",1,true) or s:find("429",1,true) then return "rate_limit" end
    if s:find("auth",1,true) or s:find("login",1,true) or s:find("ticket",1,true) then return "auth" end
    return "transient"
end
function M.delay(attempt,kind)
    local n=math.max(1,math.floor(tonumber(attempt) or 1))
    if kind=="mapping" then return 600 end
    if kind=="rate_limit" then return math.min(3600,600 * 2^(math.min(3,n-1))) end
    if kind=="auth" then return 300 end
    return math.min(3600,45 * 3^(math.min(4,n-1)))
end
function M.record(store,book,opt,account_vid,session_id,reason,now)
    now=tonumber(now) or os.time()
    local key=identifier(book,opt)
    if not key or tostring(account_vid or "")=="" or tostring(session_id or "")=="" then return nil,"identity_missing" end
    local rows=load(store)
    local found,found_index=nil,nil
    for i,existing in ipairs(rows) do
        if existing.key==key then found,found_index=existing,i;break end
    end
    local kind=M.reason_kind(reason)
    local row=found or {key=key,book=clean_book(book),options=clean_options(opt),
        account_vid=tostring(account_vid),session_id=tostring(session_id),created_at=now,attempt=0}
    if row.account_vid~=tostring(account_vid) or row.session_id~=tostring(session_id) then
        -- A new login must never inherit an old account's pending download.
        row={key=key,book=clean_book(book),options=clean_options(opt),
            account_vid=tostring(account_vid),session_id=tostring(session_id),created_at=now,attempt=0}
        rows[found_index]=row
    end
    if not row.book then return nil,"book_missing" end
    row.attempt=math.max(0,tonumber(row.attempt) or 0)+1
    row.kind=kind
    row.last_error=tostring(reason or ""):sub(1,220)
    row.last_failed_at=now
    -- The gate already refetched the Web source and rejected its content.
    -- Repeat once after a meaningful delay, then hold for manual/source changes.
    if kind=="mapping" and row.attempt>=2 then
        row.status="needs_attention"
        row.next_at=0
    else
        row.status="pending"
        row.next_at=now+M.delay(row.attempt,kind)
    end
    if not found then
        if #rows>=LIMIT then return nil,"queue_full" end
        rows[#rows+1]=row
    end
    local ok,err=save(store,rows)
    if ok~=true then return nil,err or "write_failed" end
    return row
end
function M.remove(store,key)
    if not key then return false end
    local rows=load(store)
    local changed=false
    for i=#rows,1,-1 do
        if rows[i].key==key then table.remove(rows,i);changed=true end
    end
    if not changed then return false end
    return save(store,rows)==true
end
function M.has(store,key)
    if not key then return false end
    for _,r in ipairs(load(store)) do if r.key==key then return true end end
    return false
end
function M.select(store,now,vid,session)
    now=tonumber(now) or os.time()
    local chosen=nil
    for _,row in ipairs(load(store)) do
        if row.status=="pending" and tonumber(row.next_at or 0)<=now
            and tostring(row.account_vid or "")==tostring(vid or "")
            and tostring(row.session_id or "")==tostring(session or "") then
            if not chosen or tonumber(row.next_at or 0)<tonumber(chosen.next_at or 0) then chosen=row end
        end
    end
    return chosen
end
function M.next_delay(store,now,vid,session)
    now=tonumber(now) or os.time()
    local soon=nil
    for _,row in ipairs(load(store)) do
        if row.status=="pending" and tostring(row.account_vid or "")==tostring(vid or "")
            and tostring(row.session_id or "")==tostring(session or "") then
            local seconds=math.max(0,(tonumber(row.next_at) or now)-now)
            soon=math.min(soon or seconds,seconds)
        end
    end
    return soon
end
function M.defer(store,key,now,seconds)
    local rows=load(store)
    for _,row in ipairs(rows) do
        if row.key==key and row.status=="pending" then
            row.next_at=math.max(tonumber(row.next_at) or 0,(tonumber(now) or os.time())+math.max(10,tonumber(seconds) or 90))
            return save(store,rows)==true
        end
    end
    return false
end
return M
