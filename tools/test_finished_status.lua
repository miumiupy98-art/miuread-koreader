package.path="./miuread.koplugin/?.lua;"..package.path
package.loaded["miuread.protocol"]={is_mp=function() return false end,is_mp_account=function() return false end}
package.loaded["miuread.util"]={copy=function(value)
    local out={}
    for key,entry in pairs(value) do out[key]=entry end
    return out
end}
local Status=require("miuread.finished_status")
local id="42"
assert(Status.parse({finishReading=1},id)==true)
assert(Status.parse({data={bookId=id,finishReading=0}},id)==false)
assert(Status.parse({bookId="99",finishReading=1},id)==nil)
assert(Status.parse({finishedBookIndex=4,progress=100},id)==nil)
assert(Status.parse({finishReading=-1},id)==nil)
assert(Status.parse_shelf({books={{bookId="99",finishReading=1},{bookInfo={bookId=id,finishReading=0}}}},id)==false)
assert(Status.parse_shelf({books={{bookId=id,progress=100}}},id)==nil)

local auth={account={vid="original"}}
local stored={}
local store={}
function store:auth() return auth end
function store:get(key,default) return stored[key] or default end
function store:set(key,value) stored[key]=value; return true end
function store:set_deferred(key,value) stored[key]=value end
function store:shelf_cache() return {} end

local worker={calls={}}
function worker:available() return true end
function worker:busy() return self.callback~=nil end
function worker:run(label,_,done)
    assert(not self:busy())
    self.calls[#self.calls+1]=label
    self.callback=done
    return true
end
function worker:cancel() self.callback=nil end
function worker:complete(value)
    local callback=self.callback
    self.callback=nil
    callback({ok=true,value=value})
end

local status=Status:new(store,worker)
local function pump(expected)
    return status:pump(function(mode,book_id,desired)
        assert(mode==expected and book_id==id and desired==status:entry(id).desired)
        if mode=="write" then
            assert(status:entry(id).phase=="verifying","commit verifying before starting a write")
        end
        return function() end
    end,nil,nil,true)
end
assert(status:request(id,true))
assert(pump("write"))
worker:complete({finished=Status.parse({finishReading=1},id)})
assert(status:entry(id).phase=="verified" and status:overlay({bookId=id}).finished==true)

assert(status:request(id,false))
assert(pump("write"))
worker:complete({})
assert(status:entry(id).phase=="verifying")
assert(pump("read"))
worker:complete({finished=Status.parse_shelf({books={{bookId=id,finishReading=0,progress=100}}},id)})
assert(status:entry(id).phase=="verified" and status:overlay({bookId=id,progress=100}).finished==false)
assert(table.concat(worker.calls,",")=="finished-status-write,finished-status-write,finished-status-read")

assert(status:request(id,true))
assert(pump("write"))
status:cancel("suspend")
assert(pump("read"))
worker:complete({})
assert(pump("read"))
worker:complete({})
assert(pump("read"))
worker:complete({})
assert(status:entry(id).phase=="unconfirmed" and not status:next_due(false))
assert(pump("read"))
auth={account={vid="other"}}
worker:complete({finished=true})
assert(not status:entry(id))
auth={account={vid="original"}}
assert(status:entry(id).phase=="unconfirmed")

assert(status:request(id,true))
assert(pump("write"))
worker:complete({unsent=true})
assert(status:entry(id).phase=="queued")
assert(pump("write"))
worker:complete({finished=true})
assert(status:entry(id).phase=="verified")
print("Native mark/cancel receipts, recovery, bounded readback, and account fence passed")
