local TOOL_DIR=tostring(arg and arg[0] or ''):match('^(.*)/[^/]+$') or '.'
local ROOT=TOOL_DIR..'/../miuread.koplugin/'
package.path=ROOT..'?.lua;'..package.path

package.preload['logger']=function() return {info=function() end,warn=function() end,err=function() end,dbg=function() end} end
package.preload['socket']=function() return {gettime=function() return os.time() end} end
package.preload['lfs']=function() return {} end
package.preload['libs/libkoreader-lfs']=function() return {attributes=function() return nil end,mkdir=function() return true end} end
package.preload['miuread.codec']=function() return {} end
-- reader.lua pulls miuread.http in only for these four classifiers; loading the
-- real module would drag the whole LuaSocket stack into this test.
package.preload['miuread.http']=function()
    return {
        is_auth_error=function(v) return tostring(v or ''):find('MiuReadAuth',1,true)~=nil end,
        is_rate_limit_error=function() return false end,
        is_network_error=function() return false end,
        auth_error_message=function(code,message)
            return '[MiuReadAuth] error_code='..tostring(code)..': '..tostring(message or '')
        end,
    }
end
package.preload['miuread.annotation_coord']=function()
    return {fromDownloadedXhtml=function(v) return tostring(v or '') end}
end

-- window.__INITIAL_STATE__ is the only reason the reader page is fetched at
-- all, so the decoder has to be real enough to reach the fields inside it.
local function json_decode(text)
    local pos=1
    local function skip() pos=text:find('[^ \t\r\n]',pos) or (#text+1) end
    local value
    local function str()
        pos=pos+1
        local out={}
        while true do
            local c=text:sub(pos,pos)
            if c=='' or c=='"' then pos=pos+1 break end
            if c=='\\' then out[#out+1]=text:sub(pos+1,pos+1); pos=pos+2
            else out[#out+1]=c; pos=pos+1 end
        end
        return table.concat(out)
    end
    function value()
        skip()
        local c=text:sub(pos,pos)
        if c=='{' or c=='[' then
            local object=c=='{'
            local out={}
            pos=pos+1; skip()
            if text:sub(pos,pos)==(object and '}' or ']') then pos=pos+1 return out end
            while true do
                if object then
                    skip()
                    local key=str()
                    skip(); pos=pos+1
                    out[key]=value()
                else
                    out[#out+1]=value()
                end
                skip()
                local separator=text:sub(pos,pos); pos=pos+1
                if separator~=',' then break end
            end
            return out
        elseif c=='"' then return str()
        elseif text:sub(pos,pos+3)=='true' then pos=pos+4 return true
        elseif text:sub(pos,pos+4)=='false' then pos=pos+5 return false
        elseif text:sub(pos,pos+3)=='null' then pos=pos+4 return nil
        end
        local literal=text:match('^%-?%d+%.?%d*',pos) or ''
        pos=pos+#literal
        return tonumber(literal)
    end
    return value()
end
package.preload['miuread.json']=function()
    return {encode=function() return '{}' end,decode=json_decode}
end

local Reader=require('miuread.reader')
local Protocol=require('miuread.protocol')

local PAGE='<html><script>window.__INITIAL_STATE__ = {"reader":{"psvts":"ps1",'
    ..'"pclts":"pc1","token":"tok1"},"bookInfo":{"bookId":"B1","version":7}}</script></html>'

local fetches
local function new_reader(body)
    fetches={}
    local http={}
    function http:download(url,opt)
        fetches[#fetches+1]={url=url,keepalive=opt and opt.keepalive}
        return body or PAGE,{},url
    end
    return Reader:new(http,{})
end

-- One reader page serves every chapter of a book.
local r=new_reader()
local first=r:chapter_state('B1','c1',true)
local second=r:chapter_state('B1','c2',true)
local third=r:chapter_state('B1','c3',true)
assert(#fetches==1,'a cached reader context still refetched the page')
assert(first.psvts=='ps1' and third.psvts=='ps1','psvts did not reach every chapter')
assert(fetches[1].keepalive==true,'the reader page stopped opting into connection reuse')
assert(third.token=='tok1' and third.pclts=='pc1','token/pclts were dropped from the cache')
assert(third.book_version==7,'book_version was dropped from the cache')

-- _epub_once and _txt_once use the state table as their per-chapter working
-- area. Sharing one table would carry a chapter's body, its coordinate source
-- and its image directory into the next chapter.
assert(second~=third,'chapters shared a single state table')
second.raw_xhtml='body'; second.coord_html='coords'; second.image_work_root='/tmp/ch2'
second.image_archive_expected=true; second.structural=true
local fourth=r:chapter_state('B1','c4',true)
assert(fourth.raw_xhtml==nil and fourth.coord_html==nil,'chapter body/coordinates leaked forward')
assert(fourth.image_work_root==nil,'image work directory leaked forward')
assert(fourth.image_archive_expected==nil and fourth.structural==nil,'chapter flags leaked forward')
assert(fourth.source==nil,'the decoded page bootstrap is pinned for the whole run')

-- The download record carries psvts to the reading-time and progress workers,
-- which decide from its timestamp whether to reload the page. A cached context
-- must report when its page loaded, never when this chapter asked for it.
local loaded_at=r._reader_context.fetched_at
r._reader_context.fetched_at=loaded_at-100
local later=r:chapter_state('B1','c5',true)
assert(#fetches==1,'the 100 s old context should still have been served')
assert(later.context_fetched_at==loaded_at-100,'a cached context claimed to be newly fetched')
r._reader_context.fetched_at=loaded_at

-- The reader URL is the image Referer, so it must name the current chapter.
assert(second.url==Protocol.reader_url('B1','c2'),'a cached url was reused for another chapter')
assert(third.url==Protocol.reader_url('B1','c3'),'the url was not rebuilt per chapter')

-- Book identity and freshness.
r:chapter_state('B2','c1',true)
assert(#fetches==2,'a different book reused another book context')
r=new_reader()
r:chapter_state('B1','c1',true)
-- The content API rejects a psvts 300 s after its page loaded, so the context
-- must be refreshed with a margin below that, never at sync.lua's 15 minutes.
r._reader_context.fetched_at=os.time()-241
r:chapter_state('B1','c2',true)
assert(#fetches==2,'an expired reader context was reused')
r._reader_context.fetched_at=os.time()-235
r:chapter_state('B1','c3',true)
assert(#fetches==2,'a fresh reader context was discarded')
r._reader_context.fetched_at=os.time()-299
r:chapter_state('B1','c4',true)
assert(#fetches==3,'a context close to the 300 s server limit was still served')

-- A page without psvts must still fail loudly rather than sign requests blank.
local blank=new_reader('<html>{"pclts":"pc1","token":"tok1"}</html>')
assert(not pcall(blank.chapter_state,blank,'B1','c1',true),'a page without psvts was accepted')

-- A renewed session invalidates the page load the psvts came from.
r=new_reader()
r.store={auth=function() return {login_session_id='s1',auth_revision=0,
    account={vid='v1'},cookies={wr_vid='v1',wr_skey='k1'}} end,save_auth=function() return true end}
function r.http:post_json() return {succ=1},{},{} end
r:chapter_state('B1','c1',true)
assert(r:_recover_login_session()==true,'the stubbed renewal did not succeed')
assert(r._reader_context==nil,'a renewed session kept the old reader context')

-- Every retry must reload the page. A stale psvts answers with an empty body,
-- and three of those make Reader:chapter convert a real chapter into a blank
-- structure page, so a retry that reuses the same context corrupts silently.
r=new_reader()
r:chapter_state('B1','c1',true)
local attempts=0
r._chapter_once=function(self)
    attempts=attempts+1
    if attempts>1 then
        assert(self._reader_context==nil,'a chapter retry reused the failed context')
    end
    self:chapter_state('B1','c1',true)
    error('decoded EPUB chapter is empty')
end
pcall(r.chapter,r,{bookId='B1'},{chapterUid='c1'},'epub',{})
assert(attempts==3,'the chapter was not retried three times')
assert(#fetches==3,'the retries did not each load their own reader page')

print('reader context reuse: PASS')
