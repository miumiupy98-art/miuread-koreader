-- Real Lua regression tests of the beta.11 durable coordinate retry policy.
package.path = './miuread.koplugin/?.lua;./miuread.koplugin/?/init.lua;'..package.path
package.loaded['miuread.util']={}
local Retry=require('miuread.download_coordinate_retry')
local function store()
    local values={}
    return {get=function(self,k,d) return values[k] or d end,
        set=function(self,k,v) values[k]=v return true end}
end
local s=store()
local book={bookId=123,title='Test',version=3}
local opt={annotations=false,images=true,chapter_uid='c1',wr_skey='SHOULD_NOT_PERSIST'}
local now=100000
local row,err=Retry.record(s,book,opt,'vid1','session1','temporary network error',now)
assert(row and not err and row.status=='pending')
assert(row.attempt==1 and row.next_at==now+45)
assert(Retry.select(s,now,'vid1','session1')==nil)
assert(Retry.select(s,now+45,'vid1','session1').key==row.key)
assert(Retry.select(s,now+100,'vid2','session2')==nil)
assert(#Retry.load(s)==1)
assert(Retry.load(s)[1].options.wr_skey==nil,'credentials leaked into retry record')
assert(Retry.defer(s,row.key,now,200))
assert(Retry.select(s,now+45,'vid1','session1')==nil)
row=Retry.record(s,book,opt,'vid1','session1','temporary network error',now+250)
assert(row and row.attempt==2 and row.next_at==now+250+135)
assert(#Retry.load(s)==1,'repeated failures must deduplicate by key')
assert(Retry.delay(20,'transient')==3600)
assert(Retry.delay(20,'rate_limit')==3600)
local mapping=Retry.record(s,{bookId=456}, {}, 'vid1','session1','web_source_validation_failed:46:anchor_mismatch',now)
assert(mapping and mapping.kind=='mapping' and mapping.status=='pending')
mapping=Retry.record(s,{bookId=456}, {}, 'vid1','session1','web_source_validation_failed:46:anchor_mismatch',now+600)
assert(mapping and mapping.status=='needs_attention')
assert(Retry.select(s,now+100000,'vid1','session1').key==row.key,'deterministic mismatch should be held')
assert(Retry.remove(s,row.key))
assert(Retry.select(s,now+100000,'vid1','session1')==nil)
assert(not Retry.has(s,row.key))
assert(Retry.record(s,{bookId=789},{},'', 'session1','network',now)==nil)
local s2=store()
local old=Retry.record(s2,{bookId=11},{},'vid1','session1','network',now)
local changed=Retry.record(s2,{bookId=11},{},'vid2','session2','network',now)
assert(changed.attempt==1 and changed.account_vid=='vid2')
assert(Retry.select(s2,now+50,'vid1','session1')==nil)
assert(Retry.select(s2,now+50,'vid2','session2')~=nil)
print('beta11 coordinate retry policy: PASS')
