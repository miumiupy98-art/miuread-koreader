-- Small, transactional ledger, separate from the full miuread settings file.
-- Watermarks and queued seconds commit together. Uncertain writes never replay.
local SQL=require("miuread.sqlite_store")
local U=require("miuread.util")
local Clock=require("miuread.readtime_clock")
local bit=require("bit")
local M={}; M.__index=M
local MAX_ROWS=50000
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
function M:pending(account,now,eligible,max_seconds)
    local limit=math.min(600,math.max(60,tonumber(max_seconds) or 600))
    return self:_access(account,function(data)
        local items={}
        for _,row in pairs(data.items) do
            if row.state=="pending" and (tonumber(row.retry_at) or 0)<=now
                and (not eligible or eligible(row)) then items[#items+1]=U.copy(row) end
        end
        table.sort(items,function(a,b) return tonumber(a.id)<tonumber(b.id) end)
        local batch={rows={},seconds=0}
        for _,row in ipairs(items) do
            if not batch.book_id then batch.book_id=row.book_id; batch.book_version=row.book_version or 0 end
            if row.book_id==batch.book_id then
                if (row.book_version or 0)~=batch.book_version then break end
                if #batch.rows>=100 or batch.seconds+row.duration>limit then break end
                batch.rows[#batch.rows+1]=row
                batch.seconds=batch.seconds+row.duration
            end
        end
        return batch,false
    end,true)
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
