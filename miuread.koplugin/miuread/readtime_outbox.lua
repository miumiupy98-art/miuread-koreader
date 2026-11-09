-- Small, transactional ledger, separate from the full miuread settings file.
-- Watermarks and queued seconds commit together. Uncertain writes never replay.
local SQL=require("miuread.sqlite_store")
local U=require("miuread.util")
local Clock=require("miuread.readtime_clock")
local bit=require("bit")
local M={}; M.__index=M
local MAX_ROWS=50000
-- Conservative resource budgets, not server-side protocol limits.  The first
-- full hour is preferred; an unusually fragmented single hour may be split
-- to keep the worker bounded.  The 3690s/123-row #184 case fits in one batch.
local MAX_BATCH_ROWS=512
local MAX_BATCH_HOUR_GROUPS=12
local MAX_BATCH_SPAN_SECONDS=24*3600
local MAX_QUARANTINE_PER_PASS=256

local function row_id(row)
    return tonumber(row.id) or 0
end

-- Identify deterministic overlaps ONLY for hours whose aggregate would be
-- rejected by readtime_protocol.hours (>3600s).  Never guess that other
-- apparently duplicated readings are unsafe, and never alter sent/unknown rows.
local function overflow_overlap_rows(rows)
    local hours={}
    for _,row in ipairs(rows) do
        local start=tonumber(row.start_time)
        local left=tonumber(row.duration)
        local zone=tostring(row.time_zone or "")
        if start and start%1==0 and start>0 and left and left%1==0 and left>0
            and left<=86400 and zone:match("^[+-]%d%d:%d%d$") then
            local at=start
            while left>0 do
                local hour=at-at%3600
                local seconds=math.min(left,hour+3600-at)
                local key=tostring(hour)..":"..zone
                local bucket=hours[key]
                if not bucket then
                    bucket={seconds=0,segments={}}
                    hours[key]=bucket
                end
                bucket.seconds=bucket.seconds+seconds
                bucket.segments[#bucket.segments+1]={start=at,finish=at+seconds,row=row}
                at=at+seconds
                left=left-seconds
            end
        end
    end
    local overlaps={}
    for _,bucket in pairs(hours) do
        if bucket.seconds>3600 then
            table.sort(bucket.segments,function(a,b)
                if a.start==b.start then return row_id(a.row)<row_id(b.row) end
                return a.start<b.start
            end)
            local covered_until=-math.huge
            for _,segment in ipairs(bucket.segments) do
                if segment.start<covered_until then
                    overlaps[segment.row.id]=segment.row
                elseif not overlaps[segment.row.id] then
                    covered_until=math.max(covered_until,segment.finish)
                end
            end
        end
    end
    return overlaps
end
function M.new(store)
    return setmetatable({path=assert(store.data_dir).."/readtime-outbox.sqlite3"},M)
end
local function empty()
    return {version=1,sequence=0,windows={},seen={},aliases={},items={}}
end
local function prune(data)
    local referenced={}
    for _,row in pairs(data.items) do referenced[row.window]=true end
    local prefixes={}
    for id,window in pairs(data.windows) do
        if window.closed then
            prefixes[#prefixes+1]=id..":"
            if not referenced[id] then data.windows[id]=nil end
        end
    end
    for _,field in ipairs({"seen","aliases"}) do
        for key in pairs(data[field]) do
            for _,prefix in ipairs(prefixes) do
                if key:sub(1,#prefix)==prefix then data[field][key]=nil; break end
            end
        end
    end
end
function M:_access(account,change,read_only)
    account=tostring(account or "")
    if account=="" then return nil,"missing_account" end
    local ok,value=pcall(SQL.with_connection,self.path,read_only==true,function(conn)
        local function access()
            local data,err=SQL.get_json(conn,"account:"..account,nil)
            if err then error("invalid reading-time ledger") end
            data=data or empty()
            if (data.version~=1 and data.version~=2 and data.version~=3) or type(data.items)~="table" or type(data.windows)~="table"
                or type(data.seen)~="table" then error("invalid reading-time ledger") end
            data.aliases=data.aliases or {}
            data.control=data.control or {}
            local result,dirty=change(data)
            if dirty then
                data.version=3
                prune(data)
                if SQL.set_json(conn,"account:"..account,data)~=true then error("reading-time save failed") end
            end
            return result
        end
        if read_only then return access() end
        conn:exec("PRAGMA synchronous=FULL;")
        return SQL.transaction(conn,access)
    end)
    if not ok then return nil,tostring(value):find("ledger_full",1,true) and "ledger_full" or "ledger_failed" end
    return value
end
function M:observe(account,sample,window_id)
    return self:_access(account,function(data)
        local state,result=Clock.observe(data.clock,sample)
        if not data.clock or not data.clock.last_wall then
            -- Older ledgers have no clock observations. Preserve any known
            -- future prefix as a capture floor, without inventing risk bits.
            for _,row in pairs(data.items) do
                local endpoint=row.start_time+row.duration
                if endpoint>sample.wall then state.capture_floor=math.max(state.capture_floor or 0,endpoint) end
            end
            result.capture_floor=state.capture_floor
        end
        data.clock=state
        local window=window_id and data.windows[window_id]
        if window and not window.closed then
            window.risk=bit.bor(window.risk or 0,result.risk)
            -- A preflight may have copied these rows already. claim checks the
            -- metadata again, so an older signature cannot dispatch them.
            if result.risk~=0 then
                for _,row in pairs(data.items) do
                    if row.window==window_id and row.state=="pending" then
                        row.risk=bit.bor(row.risk or 0,result.risk)
                    end
                end
            end
        end
        return result,true
    end)
end
function M:server_clock(account,stamp,limit,wall)
    return self:_access(account,function(data)
        local state,different=Clock.server(data.clock,stamp,limit,wall)
        if not state then return {observed=false},false end
        data.clock=state
        return {observed=true,different=different},true
    end)
end
function M:begin(account,window,unique)
    return self:_access(account,function(data)
        if unique then
            -- Persistent allocation also survives a same-second process restart
            -- with the same PRNG seed; completed windows may already be pruned.
            data.window_sequence=(tonumber(data.window_sequence) or 0)+1
            window=U.copy(window)
            window.id=window.id..":"..tostring(data.window_sequence)
        end
        if data.windows[window.id] then return U.copy(data.windows[window.id]),false end
        local saved=U.copy(window)
        saved.last_seen=saved.start_time
        data.windows[saved.id]=saved
        return U.copy(saved),true
    end)
end
function M:collect(account,window_id,spans,now,close)
    return self:_access(account,function(data)
        local window=data.windows[window_id]
        if not window or window.closed then return {seconds=0,rows=0},false end
        local size=0
        for _ in pairs(data.items) do size=size+1 end
        local seconds,rows=0,0
        for _,span in ipairs(spans) do
            local start=tonumber(span.start_time)
            local duration=tonumber(span.duration)
            if start and duration and duration>0 and duration<=86400 and duration%1==0
                and start>0 and start%1==0 then
                local raw_key=window_id..":"..tostring(span.page)..":"..tostring(start)
                local origin=tonumber(span.source_start) or start
                local key=data.aliases[raw_key] or (window_id..":"..tostring(span.page)..":"..tostring(origin))
                data.aliases[raw_key]=key
                local seen=data.seen[key]
                local floor=math.max(window.start_time,tonumber(window.capture_not_before) or 0)
                local skip=type(seen)=="table" and seen.skip or math.max(0,floor-origin)
                local previous=type(seen)=="table" and seen.seconds or 0
                local eligible=math.max(0,math.min(duration,now-start)-skip)
                local delta=eligible-previous
                if delta>0 then
                    local at,left=start+skip+previous,delta
                    while left>0 do
                        if size+rows>=MAX_ROWS then error("ledger_full") end
                        local part=math.min(left,60)
                        data.sequence=data.sequence+1
                        local id=tostring(data.sequence)
                        data.items[id]={id=id,window=window_id,book_id=window.book_id,
                            start_time=at,duration=part,time_zone=window.time_zone,
                            book_version=window.book_version,book_version_source=window.book_version_source,
                            risk=window.risk or 0,
                            state="pending",created_at=now,retry_at=0,attempts=0}
                        at,left=at+part,left-part
                        rows=rows+1
                    end
                    data.seen[key]={seconds=eligible,skip=skip}
                    seconds=seconds+delta
                end
            end
        end
        local changed=seconds>0 or window.last_seen~=now or close==true
        window.last_seen=now
        if close then
            window.closed=true; window.end_time=now
            -- A closed window is immutable. Keep its small tombstone but drop
            -- tuple watermarks so the ledger does not grow with every page read.
            local prefix=window_id..":"
            for key in pairs(data.seen) do if key:sub(1,#prefix)==prefix then data.seen[key]=nil end end
            for key in pairs(data.aliases) do if key:sub(1,#prefix)==prefix then data.aliases[key]=nil end end
        end
        return {seconds=seconds,rows=rows},changed
    end)
end
function M:pending(account,now,eligible)
    return self:_access(account,function(data)
        local items={}
        for _,row in pairs(data.items) do
            if row.state=="pending" and (tonumber(row.retry_at) or 0)<=now
                and (not eligible or eligible(row)) then items[#items+1]=row end
        end
        table.sort(items,function(a,b) return row_id(a)<row_id(b) end)
        local batch={rows={},seconds=0,invalid_rows={}}
        if #items==0 then return batch,false end
        batch.book_id=items[1].book_id
        batch.book_version=items[1].book_version or 0
        local selected={}
        for _,row in ipairs(items) do
            if row.book_id==batch.book_id and (row.book_version or 0)==batch.book_version then
                selected[#selected+1]=row
            end
        end
        local overlapping=overflow_overlap_rows(selected)
        local invalid={}
        for _,row in ipairs(selected) do
            if overlapping[row.id] then invalid[#invalid+1]=row end
        end
        for i=1,math.min(#invalid,MAX_QUARANTINE_PER_PASS) do
            batch.invalid_rows[#batch.invalid_rows+1]=U.copy(invalid[i])
        end
        -- A batch containing an identifiable anomaly must not be sent until
        -- the anomaly has been durably isolated in a separate transaction.
        if #batch.invalid_rows>0 then return batch,false end

        -- Group ready rows by starting hour and time zone, preferring complete
        -- hours over an arbitrary split.  A single oversized hour is allowed
        -- to split at the row limit so that it cannot stall all other books.
        local groups,order={},{}
        for _,row in ipairs(selected) do
            local start=tonumber(row.start_time) or 0
            local key=tostring(math.floor(start/3600))..":"..tostring(row.time_zone or "")
            local group=groups[key]
            if not group then
                group={rows={},first=start,last=start}
                groups[key]=group
                order[#order+1]=group
            end
            group.rows[#group.rows+1]=row
            group.first=math.min(group.first,start)
            group.last=math.max(group.last,start+(tonumber(row.duration) or 0))
        end
        local first,last
        for _,group in ipairs(order) do
            local count=#batch.rows
            local span_first=math.min(first or group.first,group.first)
            local span_last=math.max(last or group.last,group.last)
            if count>0 and (#batch.rows+#group.rows>MAX_BATCH_ROWS
                or (span_last-span_first)>MAX_BATCH_SPAN_SECONDS) then break end
            if count>0 and (batch.hour_groups or 0)>=MAX_BATCH_HOUR_GROUPS then break end
            local take=math.min(#group.rows,MAX_BATCH_ROWS-count)
            for i=1,take do
                local row=group.rows[i]
                batch.rows[#batch.rows+1]=U.copy(row)
                batch.seconds=batch.seconds+(tonumber(row.duration) or 0)
            end
            batch.hour_groups=(batch.hour_groups or 0)+1
            first,last=span_first,span_last
            if take<#group.rows or #batch.rows>=MAX_BATCH_ROWS then break end
        end
        batch.hour_groups=nil  -- internal selection detail, not upload metadata
        return batch,false
    end,true)
end

-- Quarantine only deterministic unsent overlaps.  An isolated record stays in
-- the SQLite ledger for diagnosis and must never be treated as an unknown POST
-- receipt or silently deleted.  Do not change a row whose state/identity moved
-- since the read-only selection: that could race with another worker.
function M:quarantine(account,rows,reason)
    if type(rows)~="table" or #rows==0 then return {rows=0,seconds=0} end
    return self:_access(account,function(data)
        for _,row in ipairs(rows) do
            local saved=data.items[row.id]
            if not saved or saved.state~="pending" or saved.book_id~=row.book_id
                or (saved.book_version or 0)~=(row.book_version or 0)
                or saved.start_time~=row.start_time or saved.duration~=row.duration
                or saved.time_zone~=row.time_zone or (saved.risk or 0)~=(row.risk or 0) then
                return false,false
            end
        end
        local seconds=0
        for _,row in ipairs(rows) do
            local saved=data.items[row.id]
            saved.state="quarantined"
            saved.reason=reason or "overlapping_reading_time_hour"
            saved.quarantined_at=os.time()
            seconds=seconds+saved.duration
        end
        return {rows=#rows,seconds=seconds},true
    end)
end

-- Defensive fallback if a protocol preflight rejects a batch despite the
-- queue-side check.  The caller may continue with other rows only if at least
-- one specific overlapping record is identified and quarantined.
function M:quarantine_overlap_batch(account,rows)
    local overlaps=overflow_overlap_rows(rows or {})
    local bad={}
    for _,row in ipairs(rows or {}) do
        if overlaps[row.id] then bad[#bad+1]=row end
    end
    if #bad>MAX_QUARANTINE_PER_PASS then
        local first={}
        for i=1,MAX_QUARANTINE_PER_PASS do first[i]=bad[i] end
        bad=first
    end
    return self:quarantine(account,bad,"overlapping_reading_time_hour")
end
function M:claim(account,batch,attempt)
    return self:_access(account,function(data)
        if #batch.rows==0 then return false,false end
        for _,row in ipairs(batch.rows) do
            local saved=data.items[row.id]
            if not saved or saved.state~="pending" or saved.duration~=row.duration
                or saved.book_id~=row.book_id or saved.start_time~=row.start_time or saved.time_zone~=row.time_zone
                or (saved.book_version or 0)~=(row.book_version or 0) or (saved.risk or 0)~=(row.risk or 0) then
                return false,false
            end
        end
        for _,row in ipairs(batch.rows) do
            local saved=data.items[row.id]
            saved.state,saved.attempt="in_flight",attempt
            saved.attempts=(tonumber(saved.attempts) or 0)+1
        end
        return true,true
    end)
end
function M:finish(account,batch,attempt,state,now,reason)
    return self:_access(account,function(data)
        local changed=false
        for _,row in ipairs(batch.rows) do
            local saved=data.items[row.id]
            if saved and saved.state=="in_flight" and saved.attempt==attempt then
                if state=="confirmed" then
                    data.confirmed_seconds=(tonumber(data.confirmed_seconds) or 0)+saved.duration
                    data.last_success_at=now
                    data.items[row.id]=nil
                else
                    saved.state=state=="pending" and "pending" or "unknown"
                    saved.reason=reason
                    saved.retry_at=now+math.min(1800,60*2^math.min(5,(saved.attempts or 1)-1))
                end
                changed=true
            end
        end
        return true,changed
    end)
end
function M:recover(account)
    return self:_access(account,function(data)
        local count=0
        for _,row in pairs(data.items) do
            if row.state=="in_flight" then row.state="unknown"; row.reason="interrupted"; count=count+1 end
        end
        for _,window in pairs(data.windows) do
            if not window.closed then window.closed=true; window.end_time=window.last_seen; count=count+1 end
        end
        return count,true
    end)
end
function M:summary(account)
    return self:_access(account,function(data)
        local result={pending=0,unknown=0,in_flight=0,rows=0,blocked=data.blocked,
            blocked_book=data.blocked_book,control=U.copy(data.control),
            confirmed_seconds=data.confirmed_seconds or 0,last_success_at=data.last_success_at}
        for _,row in pairs(data.items) do
            result[row.state]=(result[row.state] or 0)+row.duration
            result.rows=result.rows+1
        end
        return result,false
    end,true)
end
function M:window_summary(account,window_id)
    return self:_access(account,function(data)
        local result={pending=0,unknown=0,in_flight=0,rows=0,confirmed_seconds=data.confirmed_seconds or 0}
        for _,row in pairs(data.items) do
            if row.window==window_id then
                result[row.state]=(result[row.state] or 0)+row.duration
                result.rows=result.rows+1
            end
        end
        return result,false
    end,true)
end
function M:block(account,reason,book_id)
    return self:_access(account,function(data)
        data.blocked,data.blocked_book=reason,book_id
        return true,true
    end)
end
function M:resume(account,book_id)
    return self:_access(account,function(data)
        if data.blocked_book and data.blocked_book~=book_id then return false,false end
        data.blocked,data.blocked_book=nil,nil
        return true,true
    end)
end
function M:defer(account,now,reason,wait,state)
    return self:_access(account,function(data)
        local previous=data.control
        local failures=state=="confirmed" and 0 or (tonumber(previous.failures) or 0)+1
        local delay=state=="confirmed" and 10 or math.min(1800,60*2^math.min(5,failures-1))
        data.control={failures=failures,next_send=now+math.max(delay,tonumber(wait) or 0),reason=reason,last_attempt_at=now}
        return U.copy(data.control),true
    end)
end
-- Only an explicit QR authorization success may release this specific
-- account's authentication cooldown. Other errors/rate limits remain intact.
function M:clear_auth_retry(account,now)
    return self:_access(account,function(data)
        local control=data.control or {}
        local changed=false
        if control.reason=="authentication" then
            data.control={failures=0,next_send=tonumber(now) or os.time(),reason=nil,
                last_attempt_at=control.last_attempt_at}
            changed=true
        end
        -- Re-enable only authentication-denied rows not currently dispatched.
        -- Unknown, rate-limited, network and position-protected rows keep
        -- their original retry/state and are never silently replayed.
        for _,row in pairs(data.items) do
            if row.state=="pending" and row.reason=="authentication"
                and (tonumber(row.retry_at) or 0)>(tonumber(now) or os.time()) then
                row.retry_at=tonumber(now) or os.time()
                row.reason=nil
                changed=true
            end
        end
        return true,changed
    end)
end
function M:unknown(account)
    return self:_access(account,function(data)
        local groups={}
        for _,row in pairs(data.items) do
            if row.state=="unknown" then
                local key=row.attempt or ("row:"..row.id)
                local group=groups[key] or {id=key,book_id=row.book_id,seconds=0,ids={},
                    start_time=row.start_time,end_time=row.start_time+row.duration,reason=row.reason}
                groups[key]=group
                group.seconds=group.seconds+row.duration
                group.start_time=math.min(group.start_time,row.start_time)
                group.end_time=math.max(group.end_time,row.start_time+row.duration)
                group.ids[#group.ids+1]=row.id
            end
        end
        local result={}
        for _,group in pairs(groups) do result[#result+1]=group end
        table.sort(result,function(a,b) return a.start_time<b.start_time end)
        return result,false
    end,true)
end
function M:ignore(account,group)
    return self:_access(account,function(data)
        local seconds=0
        for _,id in ipairs(group.ids or {}) do
            local row=data.items[id]
            if row and row.state=="unknown" and (row.attempt or ("row:"..row.id))==group.id then
                seconds=seconds+row.duration
                data.items[id]=nil
            end
        end
        return seconds,true
    end)
end
return M
