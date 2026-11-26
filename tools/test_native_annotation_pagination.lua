package.path="./miuread.koplugin/?.lua;"..package.path
package.loaded["logger"]={info=function() end,warn=function() end}
package.loaded["libs/libkoreader-lfs"]={}
package.loaded["miuread.http"]={is_network_error=function() return false end}
package.loaded["miuread.annotation_coord"]={}
package.loaded["miuread.annotations.posmap"]={}
package.loaded["miuread.annotations.range"]={}
package.loaded["miuread.thought_database"]={}
package.loaded["miuread.eink_client"]={new=function() return {} end}
package.loaded["miuread.json"]={is_null=function() return false end}
local DB={}
package.loaded["miuread.local_annotation_database"]=DB
local AnnotationSync=require("miuread.annotation_sync")

local rows,saved,deleted,posts
function DB.pending() return rows end
function DB.summary() return {} end
function DB.mark_synced(_,_,id,remote) saved[id]=remote; return true end
function DB.mark_state(_,_,id,state) saved[id]=state; return true end
function DB.delete_row(_,_,id) deleted[id]=true; return true end

local api={}
local first_bookmark={bookmarkId="vanishing",chapterUid=40,type=0,range="4"}
local last_bookmark={bookmarkId="deep-bookmark",chapterUid=40,type=0,range="8"}
local own_review={reviewId="deep-thought",chapterUid=40,type=1,content="My text",range="10-20"}
local format
function api:bookmark_list(id,cursor)
    assert(id=="book")
    if cursor=="0" then return {data={first_bookmark},hasMore=1,synckey=42} end
    assert(cursor=="42")
    if format=="stalled" then return {updated={},hasMore=1,synckey=42} end
    if format=="foreign" then return {bookId="other",updated={}} end
    if format=="reset" then return {updated={},clearAll=true} end
    if format=="present" then return {updated={last_bookmark},removed={"vanishing"}} end
    if format=="absent" then return {updated={},removed={"vanishing"}} end
    return {updated={last_bookmark},removed={"vanishing"},continueFlag=0}
end
function api:review_list_mine(id,cursor,count)
    assert(id=="book" and count==200)
    if cursor=="0" then return {reviews={},continueFlag=1,synckey="12345678901234567"} end
    assert(cursor=="12345678901234567")
    return {reviews={{review=own_review}},continueFlag=0}
end
function api:remove_bookmark(id)
    assert(id=="deep-bookmark")
    posts=posts+1
    format=format=="present" and "present" or "absent"
    return {}
end

local pulled=AnnotationSync.cloud_thoughts(api,"book")
assert(#pulled==1 and pulled[1].content=="My text")
local snapshot=AnnotationSync.cloud_thought_snapshot({review_list_mine=function()
    return {reviews={own_review,{reviewId="retained-without-text",type=1}}}
end},"book")
assert(#snapshot.rows==1 and snapshot.present_ids["retained-without-text"])
local rejected=pcall(AnnotationSync.cloud_thoughts,{review_list_mine=function()
    return {bookId="other",reviews={}}
end},"book")
assert(not rejected)
local worker=setmetatable({api=api,reader={http={}},store={book_dir=function() return "/fixture" end},
    _book_version=function() return 1,"fixture" end},AnnotationSync)
local function run(input)
    rows,saved,deleted,posts=input,{},{},0
    return worker:sync_book({book_id="book"},{},{})
end
local function tombstone(id)
    return {kind="bookmark",local_id=id,remote_id=id,chapter_uid="40",sync_state="delete_unknown"}
end
local report=run({
    {kind="thought",local_id="thought",remote_id="",note="My text",range_key="10-20",
        chapter_uid="40",sync_state="unknown",last_stage="eink_submit"},
    tombstone("vanishing"),
    tombstone("deep-bookmark"),
})
assert(report.reconciled==1 and saved.thought=="deep-thought")
assert(report.deleted==2 and deleted.vanishing and deleted["deep-bookmark"] and posts==1)
for _,invalid in ipairs({"stalled","foreign","reset"}) do
    format=invalid
    report=run({tombstone("deep-bookmark")})
    assert(report.deleted==0 and report.unknown==1 and posts==0 and saved["deep-bookmark"]=="delete_unknown")
end
format="present"
report=run({tombstone("deep-bookmark")})
assert(report.deleted==0 and report.unknown==1 and posts==1 and not deleted["deep-bookmark"])
print("Native cursors, later-page reconciliation, tombstones, and ambiguous delete receipts passed")
