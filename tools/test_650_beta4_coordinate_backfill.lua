-- Download flow contracts; does not contact WeRead or touch user book files.
package.preload["miuread.source_position"]=function()
    return {cachedChapterExists=function(_,_,uid,version)
        assert(version==123)
        return tostring(uid)=="20" or tostring(uid)=="30"
    end}
end
local B=require("miuread.progress_source_backfill")
local record={book_id="book",chapter_map={
 {uid="10",title="EInk one",index=1},
 {uid="20",title="Web two",index=2},
 {uid="30",title="Web three",index=3},
 {uid="s",title="Cover",structural=true},
},progress_source_book_version=123,core_map_hash="h"}
local q=B.queue({},record,nil,"login")
assert(#q.jobs==1 and q.jobs[1].uid=="10","must only fill uncached EInk chapter")
assert(B.next_job(q,100)~=nil,"missing job not runnable")
assert(B.finish(q,1,false,"rate_limit_cooldown",100,180))
assert(B.next_job(q,200)==nil,"cooldown must pause job")
assert(B.next_job(q,281)~=nil,"cooldown did not expire")
local q2=B.queue({},record,q,"login")
assert(q2.jobs[1].attempts==1 and q2.jobs[1].retry_at==280,"same version must retain cooldown")
assert(B.finish(q2,1,true,nil,282))
assert(#q2.jobs==0,"success did not retire chapter")
local q3=B.queue({},record,q,"other-account")
assert(q3.jobs[1].attempts==0,"cross-account cooldown was reused")
print("PASS beta4: mixed EPUB only fills missing Web coordinates, persisted retry, account isolation")
