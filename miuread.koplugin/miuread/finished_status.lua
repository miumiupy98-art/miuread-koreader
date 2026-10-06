local U = require("miuread.util")
local ShelfProgress = require("miuread.shelf_progress")
local Protocol = require("miuread.protocol")

local FinishedStatus = {}
FinishedStatus.__index = FinishedStatus
local owners = setmetatable({}, {__mode="k"})
local KEY = "finished_status"

local function account(store)
    local auth = store:get("auth",nil) or store:auth() or {}
    local vid=tostring((auth.account or {}).vid or "")
    return vid~="" and vid or tostring((auth.cookies or {}).wr_vid or "")
end

function FinishedStatus:new(store,worker)
    -- ReaderUI and FileManager share one durable queue and one writer.
    local owner = owners[store]
    if not owner then
        owner = setmetatable({store=store,generation=0},self)
        owners[store] = owner
    end
    if not owner.worker then owner.worker = worker end
    return owner
end

function FinishedStatus:entry(id)
    local row = self.store:get(KEY,{})[tostring(id or "")]
    if type(row)=="table" and row.account==account(self.store) and row.account~="" then return row end
end

function FinishedStatus:snapshot()
    return U.copy(self.store:get(KEY,{}))
end

function FinishedStatus:_save_all(all)
    local old = self.store:get(KEY,{})
    local saved = self.store:set(KEY,all)
    if saved~=true then
        -- Store:set updates live settings before flushing. Roll back that
        -- memory change too: an unpersisted intent must never reach the server.
        self.store:set_deferred(KEY,old)
        return false
    end
    return true
end

function FinishedStatus:_save(id,row)
    local all = U.copy(self.store:get(KEY,{}))
    all[id] = row
    return self:_save_all(all)
end

function FinishedStatus:request(id,finished)
    id = tostring(id or "")
    local vid = account(self.store)
    if id=="" or vid=="" or type(finished)~="boolean" or Protocol.is_mp(id) or Protocol.is_mp_account(id) then
        return false
    end
    local old = self:entry(id) or {}
    return self:_save(id,{account=vid,desired=finished,sequence=(tonumber(old.sequence) or 0)+1,
        phase="queued",requested_at=os.time(),retry_at=0})
end

function FinishedStatus:overlay(row)
    local entry = self:entry(row.bookId or row.book_id)
    row.finished_pending = nil
    if entry then
        if entry.phase=="verified" then row.cloud_finished = entry.desired
        elseif entry.phase~="observed" then row.finished_pending = entry.desired
        elseif row.cloud_finished==nil then row.cloud_finished = entry.observed end
    end
    row.finished = nil
    row.finished = ShelfProgress.is_finished(row)
    return row
end

function FinishedStatus:reconcile(rows,snapshot)
    local updates
    for _,row in ipairs(rows) do
        local id = tostring(row.bookId or row.book_id or "")
        local entry = self:entry(id)
        local started = type(snapshot)=="table" and snapshot[id] or nil
        -- A shelf request started before this write cannot undo its confirmation.
        if entry and entry.phase=="verified" and row.cloud_finished~=nil
            and (snapshot==nil or (started and started.sequence==entry.sequence and started.phase=="verified")) then
            updates = updates or U.copy(self.store:get(KEY,{}))
            local observed = U.copy(entry)
            observed.phase,observed.observed = "observed",row.cloud_finished
            updates[id] = observed
        end
    end
    -- Retire confirmed intents once per shelf snapshot, rather than flushing
    -- the complete settings file for each book on the UI thread.
    if updates then self:_save_all(updates) end
    for _,row in ipairs(rows) do self:overlay(row) end
    return rows
end

function FinishedStatus:_cache(id)
    local cache = self.store:shelf_cache()
    local changed=false
    for _,rows in ipairs({cache.raw_books or {},cache.books or {}}) do
        for _,row in ipairs(rows) do
            if tostring(row.bookId or row.book_id or "")==id then self:overlay(row); changed=true end
        end
    end
    if changed then self.store:save_shelf_cache(cache) end
end

function FinishedStatus:cancel(reason)
    self.generation = self.generation+1
    if self.worker then self.worker:cancel(reason) end
    -- A write was persisted as verifying before starting. After interruption
    -- it can only be read back; background recovery never sends it again.
end

function FinishedStatus.parse(data,id)
    for _=1,4 do
        if type(data)~="table" then return nil end
        local book_id = data.bookId or data.book_id
        if book_id~=nil and tostring(book_id)~=tostring(id) then return nil end
        local index = tonumber(data.finishedBookIndex)
        if index and index==index and index>=0 and index<math.huge and index%1==0 then return index>0 end
        data = data.data or data.result or data.payload
    end
end

function FinishedStatus:next_due(force)
    local selected,id
    for key in pairs(self.store:get(KEY,{})) do
        local row = self:entry(key)
        if row and (row.phase=="queued" or row.phase=="verifying" or (force==true and row.phase=="unconfirmed"))
            and (force==true or os.time()>=(tonumber(row.retry_at) or 0))
            and (not selected or row.requested_at<selected.requested_at) then selected,id=row,key end
    end
    return id,selected
end

function FinishedStatus:retry_delay()
    local delay
    for id in pairs(self.store:get(KEY,{})) do
        local row=self:entry(id)
        if row and (row.phase=="queued" or row.phase=="verifying") then
            local remaining=math.max(2,(tonumber(row.retry_at) or 0)-os.time())
            delay=delay and math.min(delay,remaining) or remaining
        end
    end
    return delay
end

function FinishedStatus:pump(make_request,on_change,apply_auth,force)
    local worker = self.worker
    if not worker or not worker:available() or worker:busy() then return false end
    local id,row = self:next_due(force)
    if not row then return false end
    return self:_run(id,U.copy(row),"read",make_request,on_change,apply_auth)
end

function FinishedStatus:_run(id,row,mode,make_request,on_change,apply_auth)
    local generation = self.generation
    local request = make_request(mode,id,row.desired)
    local started = self.worker:run("finished-status-"..mode,request,function(result)
        local current = self:entry(id)
        if generation~=self.generation or not current or current.sequence~=row.sequence or current.account~=row.account then
            if on_change then on_change(id,"superseded") end
            return
        end
        local value = result and result.ok==true and result.value or nil
        if type(value)=="table" and apply_auth then apply_auth(value) end
        local finished
        -- False is a valid cancellation result, not a missing response.
        if type(value)=="table" then finished=value.finished end
        if type(finished)=="boolean" and finished==row.desired then
            current=U.copy(current)
            current.phase,current.observed,current.retry_at = "verified",finished,0
            current.readback_attempts=nil
            if self:_save(id,current) then
                self:_cache(id)
                if on_change then on_change(id,"verified") end
                return
            end
        elseif type(finished)=="boolean" and row.phase=="queued" and mode=="read" then
            current=U.copy(current)
            current.phase,current.retry_at = "verifying",os.time()+60
            -- Commit BEFORE spawning the POST. A crash in either process must
            -- not turn a possibly successful write into a duplicate request.
            if self:_save(id,current) then
                local sent=self:_run(id,current,"write",make_request,on_change,apply_auth)
                if not sent then
                    current.phase,current.retry_at="queued",os.time()+60
                    self:_save(id,current)
                    if on_change then on_change(id,"queued") end
                end
                return
            end
        end
        current=U.copy(self:entry(id))
        if current.phase=="queued" then
            -- A failed preflight or phase flush has not sent a POST.
            current.retry_at=os.time()+60
        else
            local attempts=(tonumber(current.readback_attempts) or 0)+1
            current.readback_attempts=attempts
            current.phase=attempts>=3 and "unconfirmed" or "verifying"
            current.retry_at=os.time()+2*attempts
            current.observed=finished
            -- Bound automatic readback. Preserve unresolved intent for an
            -- explicit refresh/retry instead of polling throughout a session.
        end
        self:_save(id,current)
        if on_change then on_change(id,current.phase) end
    end,35)
    return started==true
end

return FinishedStatus
