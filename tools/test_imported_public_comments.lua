-- Read-only, mocked regression for user-imported WeRead books.
-- No account, network request, EPUB modification or app-runtime dependency.
local tool_dir = tostring(arg and arg[0] or ''):gsub('\\', '/'):match('^(.*)/[^/]+$') or '.'
local root = tool_dir..'/../miuread.koplugin'
package.path = root..'/?.lua;'..package.path

package.preload['logger'] = function()
    return {info=function() end,warn=function() end,dbg=function() end,err=function() end}
end
package.preload['miuread.thoughts'] = function() return {} end
package.preload['miuread.http'] = function()
    return {is_auth_error=function() return false end,
        is_rate_limit_error=function() return false end,
        is_forbidden_error=function() return false end}
end
package.preload['miuread.util'] = function()
    return {first_line=function(value) return tostring(value or ''):match('^[^\n]*') end}
end
package.preload['miuread.annotation_coord'] = function() return {} end
package.preload['miuread.annotations.posmap'] = function() return {} end
package.preload['miuread.annotations.range'] = function() return {} end
local Annotations = require('miuread.annotations')

-- The current protocol discovers bounded E-Ink hot-mark ranges, then fetches
-- reviews using the normal range RPC. A bounded sample is not complete history.
local function create_api(underlines, marks)
    local calls = {underlines=0,marks=0,reviews=0}
    local api = {}
    function api:underlines(book_id, uid)
        calls.underlines=calls.underlines+1
        assert(book_id=='uploaded-book' and uid=='42')
        return {underlines=underlines}
    end
    function api:best_bookmarks(book_id)
        calls.marks=calls.marks+1
        assert(book_id=='uploaded-book')
        if marks=='error' then error('temporary hot-mark failure') end
        return marks or {rows={}}
    end
    function api:review_batches(ranges)
        local batch={}
        for _,range in ipairs(ranges) do batch[#batch+1]={range=range,maxIdx=0,count=30} end
        return {batch}
    end
    function api:readreviews(book_id, uid, batch)
        assert(book_id=='uploaded-book' and uid=='42')
        calls.reviews=calls.reviews+1
        local reviews={}
        for _,item in ipairs(batch) do
            if #underlines==0 then assert(item.count==5 and item.maxIdx==nil)
            else assert(item.count==30 and item.maxIdx==0) end
            local review={reviewId='review-'..item.range,review={content='来自划线范围的想法',
                abstract='原文摘录',author={nick='读者甲'},range=item.range}}
            reviews[#reviews+1]={range=item.range,pageReviews={review,review}}
        end
        return {reviews=reviews}
    end
    return api, calls
end
local example={rows={
    {chapter_uid='42',range='100-110',text='一段原文摘录'},
    {chapter_uid='42',range='100-110',text='重复划线'},
    {chapter_uid='42',range='200-210',text='第二段原文'},
    {chapter_uid='43',range='300-310',text='其他章节'},
}}
local options={probe_empty_underlines=true}
-- Keep only current-chapter ranges, deduplicate, and mark discovery as bounded.
do
    local api,calls=create_api({},example)
    local result=Annotations:new(api):fetch_chapter('uploaded-book','42',nil,options)
    assert(result.complete==false and result.underline_request_ok==true)
    assert(result.discovery_limited==true and result.review_complete==true)
    assert(result.thought_count==2 and result.thought_entry_count==2)
    assert(#result.review_groups==2 and #result.underlines==2)
    assert(result.review_groups[1].range=='100-110')
    assert(result.review_groups[1].texts[1].content=='来自划线范围的想法')
    assert(calls.underlines==1 and calls.marks==1 and calls.reviews==1)
end
-- No optional discovery without explicit opt-in.
do
    local api,calls=create_api({},example)
    local result=Annotations:new(api):fetch_chapter('uploaded-book','42')
    assert(result.complete==true and result.thought_entry_count==0)
    assert(calls.marks==0 and calls.reviews==0)
end
-- Failure must remain incomplete and must not invent ranges or reviews.
do
    local api,calls=create_api({},'error')
    local result=Annotations:new(api):fetch_chapter('uploaded-book','42',nil,options)
    assert(result.complete==false and result.discovery_limited==true)
    assert(result.underline_request_ok==true and result.thought_entry_count==0 and #result.errors>0)
    assert(calls.marks==1 and calls.reviews==0)
end
-- Ordinary ranges retain the normal request size and complete status.
do
    local api,calls=create_api({{range='20-30'}},example)
    local result=Annotations:new(api):fetch_chapter('uploaded-book','42',nil,options)
    assert(result.complete==true and result.thought_entry_count==1)
    assert(calls.reviews==1 and calls.marks==0)
end
-- Verify the unified API and native backend expose the current discovery RPC.
local function source(path)
    local f=assert(io.open(root..'/miuread/'..path,'rb'))
    local body=f:read('*a');f:close();return body
end
assert(source('api.lua'):find('best_bookmarks={phase="annotations"}',1,true))
assert(source('eink_client.lua'):find('function M:best_bookmarks(',1,true))
assert(source('eink_client.lua'):find('/book/bestbookmarks',1,true))
print('test_imported_public_comments: PASS (bounded discovery, dedupe, errors, normal ranges, native API)')
