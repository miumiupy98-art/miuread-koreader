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

local function create_api(underlines, feed)
    local calls = {underlines=0,feed=0,reviews=0}
    local api = {}
    function api:underlines(book_id, uid)
        calls.underlines=calls.underlines+1
        assert(book_id=='uploaded-book' and uid=='42')
        return {underlines=underlines}
    end
    function api:chapter_public_reviews(book_id, uid)
        calls.feed=calls.feed+1
        assert(book_id=='uploaded-book' and uid=='42')
        if feed=='error' then error('temporary read-only feed failure') end
        return feed or {reviews={}}
    end
    function api:review_batches(ranges)
        return {{ {range=ranges[1], maxIdx=0, count=30} }}
    end
    function api:readreviews(book_id, uid, batch)
        calls.reviews=calls.reviews+1
        return {reviews={{range=batch[1].range, pageReviews={{
            reviewId='review-range', review={content='来自划线范围的想法', abstract='原文摘录',
                author={nick='读者甲'},range=batch[1].range},
        }}}}}
    end
    return api, calls
end
local example = {reviews={
    {reviewId='review-fallback',review={range='100-110',content='导入书籍的公开想法',
        abstract='一段原文摘录',author={nick='读者乙'}}},
    {reviewId='review-fallback',review={range='100-110',content='导入书籍的公开想法',
        abstract='一段原文摘录',author={nick='读者乙'}}},
    {reviewId='review-other',review={range='200-210',content='第二段想法',abstract='第二段原文'}},
    {reviewId='no-position',review={content='无法定位的整书书评'}},
}}

-- With a successful but empty underline response, a requested public-feed
-- probe recovers only anchored thoughts and deduplicates repeated review IDs.
do
    local api, calls = create_api({}, example)
    local result = Annotations:new(api):fetch_chapter('uploaded-book','42',nil,{probe_empty_underlines=true})
    assert(result.complete==true and result.underline_request_ok==true)
    assert(result.public_feed_probed==true and result.public_feed_found==2)
    assert(result.thought_count==2 and result.thought_entry_count==2)
    assert(#result.review_groups==2 and #result.underlines==2)
    assert(result.review_groups[1].range=='100-110')
    assert(result.review_groups[1].texts[1].content=='导入书籍的公开想法')
    assert(calls.underlines==1 and calls.feed==1 and calls.reviews==0)
end

-- Do not contact the optional feed unless a notes/comment operation opted in.
do
    local api,calls=create_api({},example)
    local result=Annotations:new(api):fetch_chapter('uploaded-book','42')
    assert(result.complete==true and result.thought_entry_count==0)
    assert(calls.feed==0)
end

-- Optional feed failures must not fail an otherwise valid download.
do
    local api,calls=create_api({},'error')
    local result=Annotations:new(api):fetch_chapter('uploaded-book','42',nil,{probe_empty_underlines=true})
    assert(result.complete==true and result.thought_entry_count==0)
    assert(result.public_feed_probed==true and result.public_feed_error~=nil)
    assert(calls.feed==1)
end

-- A normal chapter with ranges continues through the existing range API.
do
    local api,calls=create_api({{range='20-30'}},example)
    local result=Annotations:new(api):fetch_chapter('uploaded-book','42',nil,{probe_empty_underlines=true})
    assert(result.complete==true and result.thought_entry_count==1)
    assert(calls.reviews==1 and calls.feed==0)
end

-- The unified API must actually expose the Web-only feed. Merely defining
-- it in api_web.lua leaves the reader and downloader unable to call it.
do
    local source_file=assert(io.open(root..'/miuread/api.lua','rb'))
    local source=source_file:read('*a')
    source_file:close()
    assert(source:find('chapter_public_reviews={phase="annotations",web_only=true}',1,true))
    local web_file=assert(io.open(root..'/miuread/api_web.lua','rb'))
    local web_source=web_file:read('*a')
    web_file:close()
    assert(web_source:find('function Api:chapter_public_reviews(',1,true))
end

print('test_imported_public_comments: PASS (empty ranges, dedupe, errors, normal ranges, API dispatch)')
