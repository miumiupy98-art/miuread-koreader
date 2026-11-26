-- Exercise editing an existing thought, including an ambiguous write.
package.path="./miuread.koplugin/?.lua;"..package.path
package.loaded["logger"]={info=function() end,warn=function() end}
package.loaded["libs/libkoreader-lfs"]={}
package.loaded["miuread.http"]={}
package.loaded["miuread.annotation_coord"]={}
package.loaded["miuread.annotations.posmap"]={}
package.loaded["miuread.annotations.range"]={}
package.loaded["miuread.thought_database"]={}
local DB={}
package.loaded["miuread.local_annotation_database"]=DB
package.loaded["miuread.json"]={is_null=function() return false end}

local AnnotationSync=require("miuread.annotation_sync")
local store={}
local row={local_id="local-review",remote_id="cloud-review",chapter_uid="40",note="New text",sync_state="local_only"}
local review={reviewId=row.remote_id,chapterUid=40,type=1,isPrivate=true,friendship=0,
    notVisibleToFriends=1,content="Original text"}
local requests,claims,committed=0,0,0
local error_after_send,deny_before_send=false,false
function DB.begin_thought_edit(db,id,item)
    assert(db==store and id=="book" and item.sync_state=="local_only")
    claims=claims+1
    return true
end
function DB.finish_thought_edit(db,id,item,verified)
    assert(db==store and id=="book" and item.remote_id=="cloud-review")
    committed=committed+(verified and 1 or 0)
    return true
end
local api={}
function api:review_single(id)
    assert(id=="cloud-review")
    return {review=review}
end
function api:edit_review(payload)
    if deny_before_send then error("[MiuReadBeforeWrite] retryable preflight") end
    requests=requests+1
    assert(payload.reviewId=="cloud-review" and payload.type==1)
    assert(payload.isPrivate==1 and payload.friendship==0 and payload.notVisibleToFriends==1)
    if error_after_send then error("timeout") end
    review.content=payload.content
end
local worker=setmetatable({store=store,api=api},AnnotationSync)
assert(worker:_sync_review_edit("book",row))
assert(committed==1 and requests==1 and claims==1 and review.content==row.note)

row.note="Second edit"
error_after_send=true
assert(not worker:_sync_review_edit("book",row))
row.sync_state="unknown"
assert(not worker:_sync_review_edit("book",row))
assert(requests==2 and claims==2 and committed==1)
review.content=row.note
assert(worker:_sync_review_edit("book",row))
assert(committed==2 and requests==2)

row.sync_state="local_only"
row.note="Third edit"
review.pictures={"photo"}
assert(not worker:_sync_review_edit("book",row))
assert(requests==2 and claims==2)
review.pictures=nil
deny_before_send=true
assert(not worker:_sync_review_edit("book",row))
assert(requests==2 and claims==3)
row.synced_note="Earlier version"
deny_before_send=false
local ok,conflict=worker:_sync_review_edit("book",row)
assert(not ok and conflict and requests==2 and claims==3,"phone edits must not be overwritten")
print("Thought edits preserve cloud identity, conflicting drafts, privacy and ambiguous writes")
