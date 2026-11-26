-- Offline verification of PR #187 long-session batching and durable overlap
-- quarantine. Uses the real outbox implementation and an in-memory SQL stub;
-- no KOReader network credentials or server requests are involved.
local TOOL_DIR=tostring(arg and arg[0] or ""):gsub("\\","/"):match("^(.*)/[^/]+$") or "."
package.path=TOOL_DIR.."/../miuread.koplugin/?.lua;"..package.path
local function clone(value,seen)
    if type(value)~="table" then return value end
    seen=seen or {}
    if seen[value] then return seen[value] end
    local out={};seen[value]=out
    for k,v in pairs(value) do out[clone(k,seen)]=clone(v,seen) end
    return out
end
package.preload["miuread.util"]=function() return {copy=clone} end
package.preload["miuread.readtime_clock"]=function() return {} end
package.preload["bit"]=function() return bit32 or {bor=function(a,b) return a+b end} end
local database={}
package.preload["miuread.sqlite_store"]=function()
    return {
        with_connection=function(path,read_only,cb) return cb({path=path,exec=function() return true end}) end,
        get_json=function(conn,key) return clone(database[conn.path..":"..key]) end,
        set_json=function(conn,key,value) database[conn.path..":"..key]=clone(value);return true end,
        transaction=function(conn,cb) return cb() end,
    }
end
local Queue=require("miuread.readtime_outbox")
local function make(account,rows)
    local queue=Queue.new({data_dir="test/"..account})
    local data={version=3,sequence=0,windows={},seen={},aliases={},items={}}
    for i,row in ipairs(rows) do
        data.items[tostring(i)]={id=tostring(i),window="w",book_id=row.book_id or "book",
            start_time=row.start_time,duration=row.duration,time_zone=row.time_zone or "+09:00",
            book_version=row.book_version or 1,book_version_source="test",risk=0,
            state="pending",created_at=0,retry_at=0,attempts=0}
    end
    database[queue.path..":account:"..account]=clone(data)
    return queue
end
local function segments(start,total,step)
    local rows={}
    local at=start
    while total>0 do
        local dur=math.min(step,total)
        rows[#rows+1]={start_time=at,duration=dur}
        at=at+dur;total=total-dur
    end
    return rows
end
local HOUR=3600*500000
local function confirmed(queue,account,batch,id)
    assert(#batch.rows>0 and #(batch.invalid_rows or {})==0)
    local claimed,claim_error=queue:claim(account,batch,id); assert(claimed==true,"claim failed "..tostring(claim_error))
    assert(queue:finish(account,batch,id,"confirmed",HOUR+90000)==true)
end

-- One uninterrupted 3690-second reading represented by 123 x 30-second
-- entries must not return to the obsolete 600-second/100-row batching.
do
    local queue=make("long",segments(HOUR,3690,30))
    local batch=assert(queue:pending("long",HOUR+90000))
    assert(#batch.rows==123 and batch.seconds==3690,"#184 batching regression")
    confirmed(queue,"long",batch,"long-1")
    local status=assert(queue:summary("long"))
    assert(status.confirmed_seconds==3690 and status.pending==0 and status.unknown==0)
end

-- A heavily fragmented hour is resource-bounded, without discarding or
-- permanently marking its legitimate remainder as unknown.
do
    local queue=make("fragments",segments(HOUR,1200,1))
    local sums,parts=0,0
    while true do
        local batch=assert(queue:pending("fragments",HOUR+90000))
        if #batch.rows==0 then break end
        assert(#batch.rows<=512 and #(batch.invalid_rows or {})==0)
        sums=sums+batch.seconds; parts=parts+1
        confirmed(queue,"fragments",batch,"frag-"..parts)
    end
    assert(parts==3 and sums==1200,"fragment count / seconds incorrect")
    local status=assert(queue:summary("fragments"))
    assert(status.confirmed_seconds==1200 and status.unknown==0)
end

-- Reject deterministic overlaps only when the hour would exceed 3600s.
-- Preserve every isolated record (and its original timestamp) in SQLite.
do
    local rows=segments(HOUR,3600,60)
    for i=1,3 do rows[#rows+1]={start_time=HOUR+(i-1)*60,duration=60} end
    local queue=make("overlap",rows)
    local first=assert(queue:pending("overlap",HOUR+90000))
    assert(#first.invalid_rows==3 and #first.rows==0,"overlap must be isolated before dispatch")
    local quarantined=assert(queue:quarantine("overlap",first.invalid_rows,"overlapping_reading_time_hour"))
    assert(quarantined.rows==3 and quarantined.seconds==180)
    assert(queue:claim("overlap",first,"never")~=true,"quarantined batch must never dispatch")
    local next_batch=assert(queue:pending("overlap",HOUR+90000))
    assert(#next_batch.rows==60 and next_batch.seconds==3600 and #next_batch.invalid_rows==0)
    confirmed(queue,"overlap",next_batch,"valid-1")
    local status=assert(queue:summary("overlap"))
    assert(status.confirmed_seconds==3600 and status.quarantined==180)
    assert(status.pending==0 and status.unknown==0)
    local state=database[queue.path..":account:overlap"]
    for i=61,63 do
        local row=state.items[tostring(i)]
        assert(row and row.state=="quarantined" and row.reason=="overlapping_reading_time_hour")
        assert(row.duration==60 and row.start_time==HOUR+(i-61)*60)
    end
end

-- A small overlap that does NOT exceed 3600s is outside this fix's scope;
-- do not rewrite or drop previously accepted accounting semantics.
do
    local queue=make("small-overlap",{{start_time=HOUR,duration=60},{start_time=HOUR+10,duration=20}})
    local batch=assert(queue:pending("small-overlap",HOUR+90000))
    assert(#batch.rows==2 and #batch.invalid_rows==0)
end

-- An uncertain request can never be automatically replayed or quarantined by
-- cleanup; the new state is distinct from sent/unknown receipts.
do
    local queue=make("uncertain",segments(HOUR,120,60))
    local batch=assert(queue:pending("uncertain",HOUR+90000))
    assert(queue:claim("uncertain",batch,"unconfirmed"))
    assert(queue:finish("uncertain",batch,"unconfirmed","unknown",HOUR+90000,"interrupted"))
    assert(queue:recover("uncertain")~=nil)
    local after=assert(queue:pending("uncertain",HOUR+100000))
    assert(#after.rows==0 and #after.invalid_rows==0)
    local summary=queue:summary("uncertain")
    assert(summary.unknown==0 and summary.rows==0 and summary.confirmed_seconds==0)
    assert(summary.unverified_seconds==120 and summary.unverified_batches==1)
    local history=assert(queue:unverified_history("uncertain"))
    assert(#history.batches==1 and history.batches[1].rows==2)
end

-- Opening a v3 ledger migrates the real seven-row batch shape, plus a
-- crash-recovered in-flight fragment of that same upload, without making
-- the account lose new unsent time or credit old time as an accepted result.
do
    local rows=segments(HOUR,58,9)
    rows[#rows+1]={start_time=HOUR+70,duration=8,book_id="new-book"}
    local queue=make("legacy",rows)
    local batch=assert(queue:pending("legacy",HOUR+60))
    assert(batch.seconds==58 and #batch.rows==7)
    assert(queue:claim("legacy",batch,"legacy-58"))
    local data=database[queue.path..":account:legacy"]
    for i=1,6 do
        local item=data.items[tostring(i)]
        item.state,item.reason="unknown","interrupted"
    end
    assert(queue:recover("legacy")~=nil)
    assert(queue:recover("legacy")~=nil,"migration must be idempotent")
    local summary=assert(queue:summary("legacy"))
    assert(summary.rows==1 and summary.pending==8 and summary.unknown==0 and summary.confirmed_seconds==0)
    assert(summary.unverified_seconds==58 and summary.unverified_batches==1)
    local history=assert(queue:unverified_history("legacy"))
    assert(#history.batches==1 and history.batches[1].id=="legacy-58" and history.batches[1].rows==7)
    local later=assert(queue:pending("legacy",HOUR+100))
    assert(later.seconds==8 and later.book_id=="new-book")
    confirmed(queue,"legacy",later,"new-accepted")
    assert(queue:summary("legacy").confirmed_seconds==8)
    assert(queue:summary("legacy").unverified_seconds==58)
end

-- Keep every batch inside the time window, even beyond one UI page.
-- Archived seconds never enter the queue or cloud-confirmed count.
do
    local rows={}
    for i=1,53 do rows[i]={start_time=HOUR+i,duration=1,book_id="batch"..i} end
    local queue=make("history",rows)
    for i=1,53 do
        local batch=assert(queue:pending("history",HOUR+100))
        local attempt="attempt"..i
        assert(queue:claim("history",batch,attempt))
        assert(queue:finish("history",batch,attempt,"unknown",HOUR+100,"request_failed"))
    end
    local result=assert(queue:unverified_history("history"))
    assert(result.batch_count==53 and result.seconds==53 and #result.batches==53)
    assert(result.batches[1].book_id=="batch53" and result.batches[53].book_id=="batch1")
    local summary=assert(queue:summary("history"))
    assert(summary.rows==0 and summary.pending==0 and summary.confirmed_seconds==0)
end

-- An old waiting-to-send entry and the confirmed balance survive expiry.
-- A v3 archive's undated aggregate cannot leak into the five-day total.
do
    local original_time=os.time
    local now=HOUR+5*86400+90
    os.time=function() return now end
    local queue=make("history-expiry",{{start_time=HOUR,duration=15}})
    local key=queue.path..":account:history-expiry"
    database[key].confirmed_seconds=137
    database[key].unverified={batch_count=5,seconds=180,batches={
        {id="recent",seconds=8,start_time=HOUR+83,end_time=HOUR+91},
        {id="exact-limit",seconds=9,start_time=HOUR+81,end_time=HOUR+90},
        {id="expired",seconds=10,start_time=HOUR+79,end_time=HOUR+89},
    }}
    local history=assert(queue:unverified_history("history-expiry"))
    assert(history.batch_count==1 and history.seconds==8 and history.batches[1].id=="recent")
    assert(database[key].unverified.batch_count==5,"read-only view must not write to SQLite")
    assert(queue:recover("history-expiry")~=nil)
    assert(database[key].unverified.batch_count==1 and database[key].unverified.seconds==8)
    local summary=assert(queue:summary("history-expiry"))
    assert(summary.pending==15 and summary.confirmed_seconds==137)
    now=now+1
    assert(queue:summary("history-expiry").unverified_batches==0)
    assert(queue:recover("history-expiry")~=nil and database[key].unverified==nil)
    assert(queue:summary("history-expiry").pending==15)
    -- Interrupted uploads that were already older than the window also
    -- leave the queue without adding history or confirmed seconds.
    local batch=assert(queue:pending("history-expiry",now))
    assert(queue:claim("history-expiry",batch,"old-interruption"))
    assert(queue:recover("history-expiry")~=nil)
    summary=assert(queue:summary("history-expiry"))
    assert(summary.unverified_batches==0 and summary.rows==0 and summary.confirmed_seconds==137)
    os.time=original_time
end

-- More bad fragments than one quarantine pass are drained in bounded
-- transactions while other records remain untouched and recoverable.
do
    local rows=segments(HOUR,3600,60)
    for i=1,570 do rows[#rows+1]={start_time=HOUR+((i-1)%60)*60,duration=60} end
    local queue=make("many-overlaps",rows)
    local isolated,passes=0,0
    while true do
        local b=assert(queue:pending("many-overlaps",HOUR+90000))
        if #b.invalid_rows==0 then break end
        passes=passes+1
        assert(#b.invalid_rows<=256 and #b.rows==0)
        local result=assert(queue:quarantine("many-overlaps",b.invalid_rows,"overlapping_reading_time_hour"))
        isolated=isolated+result.rows
    end
    assert(isolated==570 and passes==3,"quarantine throughput bound and persistence")
    local batch=assert(queue:pending("many-overlaps",HOUR+90000))
    assert(batch.seconds==3600 and #batch.rows==60)
    confirmed(queue,"many-overlaps",batch,"all-valid")
    local status=assert(queue:summary("many-overlaps"))
    assert(status.quarantined==570*60 and status.confirmed_seconds==3600)
end

-- A batch must obey both the hour-group count and the time span cap when
-- readings were captured over many days, not grow unbounded with backlog.
do
    local rows={}
    for i=0,24 do rows[#rows+1]={start_time=HOUR+i*86400,duration=60} end
    local queue=make("days",rows)
    local count,total=0,0
    while true do
        local batch=assert(queue:pending("days",HOUR+30*86400))
        if #batch.rows==0 then break end
        assert(#batch.rows<=12 and batch.seconds<=12*60)
        count=count+1; total=total+batch.seconds
        confirmed(queue,"days",batch,"days-"..count)
    end
    assert(count>1 and total==25*60,"time-span cap failed")
end
print("readtime batching, quarantine persistence, safe retry and #184 regression passed")
