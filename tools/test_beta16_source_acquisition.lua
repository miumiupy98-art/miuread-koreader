-- Real beta.16 backfill coordinator, mocked EPUB/Web data and provenance.
local files,webcache,marks={}, {}, {}
local function key(id,uid,ver) return tostring(id)..':'..tostring(uid)..':'..tostring(ver) end
package.preload['miuread.util']=function()return {
  copy=function(v) local t={} for k,x in pairs(v) do t[k]=x end return t end,
  file_exists=function(p)return p=='/books/old.epub' end,
  file_size=function(p)return p=='/books/old.epub' and 2000 or nil end,
}end
package.preload['libs/libkoreader-lfs']=function()return {attributes=function()return 0 end}end
local source={}
function source.readExactChapter(r,id,uid,v) return webcache[key(id,uid,v)] end
function source.cacheChapter(r,id,uid,v,web) webcache[key(id,uid,v)]=web;return true end
function source.validateDownloadChapter(local_x,web)
 if local_x=='epub:'..web then return {anchors=3} end
 return nil,'source_text_too_short_or_image_only'
end
package.preload['miuread.source_position']=function()return source end
package.preload['miuread.web_source_provenance']=function()return {
 is_trusted=function(r,id,uid,v,w) return marks[key(id,uid,v)]==w end,
 mark=function(r,id,uid,v,w) marks[key(id,uid,v)]=w;return true end
}end
package.preload['miuread.epub_installer']=function()return {
 inspect=function()return {book_id='b',progress_source_book_version=7,
   _chapter_count=3,chapters={{uid='a'},{uid='b'},{uid='c'}}},{} end,
 read_chapter_text=function(p,i)return ({'epub:x','epub:y','epub:z'})[i] end,
}end
package.path='./miuread.koplugin/?.lua;./miuread.koplugin/?/init.lua;'..package.path
local legacy=require('miuread.legacy_coordinate_backfill')
local requests=0
local reader={chapter=function(_,book,ch,fmt,opts)
 requests=requests+1
 assert(opts.fresh_context==true)
 if ch.uid=='a' then return 'x',nil,nil,{source_channel='web',coordinate_source_authoritative=true,coord_html='x'} end
 if ch.uid=='b' then return 'y',nil,nil,{source_channel='web',coordinate_source_authoritative=true,coord_html='bad-short'} end
 return 'z',nil,nil,{source_channel='eink',coordinate_source_authoritative=false,coord_html='z'}
end}
local base={book_id='b',file='/books/old.epub',version=7,size=2000,mtime=0,title='book'}
local function run(i) local t={} for k,v in pairs(base) do t[k]=v end t.next_index=i return legacy.perform(t,reader) end
local a=run(1);assert(a.ok and a.cached and a.mapping_verified and a.fetched and requests==1)
local a2=run(1);assert(a2.ok and not a2.fetched and requests==1,'Web provenance should avoid repeated network')
local b=run(2);assert(b.ok and b.cached and not b.mapping_verified and b.mapping_error and requests==2)
local b2=run(2);assert(b2.ok and not b2.fetched and requests==2,'short chapter must not refetch')
-- An old unproven cache mismatch gets exactly one authoritative refresh.
marks['b:b:7']=nil;webcache['b:b:7']='unproven-native'
local b3=run(2);assert(b3.ok and b3.fetched and requests==3)
local c=run(3);assert(not c.ok and c.reason=='web_source_not_authoritative' and requests==4)
print('PASS beta16: trusted Web cache, short chapter, no duplicate Web calls, untrusted cache, native rejected')
