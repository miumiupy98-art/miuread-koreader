-- Targeted production Gate test: surface only authoritative mapping failures to
-- the caller's chapter-level Web rebuild; never label network/auth failures as
-- a safe content fallback. The download manager is allowed to rebuild only
-- native-origin chapters.
package.preload['miuread.util']=function()return {
 read_file=function(path) if path=='/test/chapter.xhtml' then return '<p>local-body</p>' end end,
}end
package.preload['miuread.http']=function()return {
 is_rate_limit_error=function()return false end,
 is_auth_error=function()return false end,
 is_network_error=function()return false end,
}end
local source={}
function source.readExactChapter()return nil end
function source.validateDownloadChapter()return nil,'source_full_text_mismatch' end
function source.cacheChapter()error('must not cache mismatched chapter') end
package.preload['miuread.source_position']=function()return source end
package.preload['logger']=function()return {info=function()end,warn=function()end}end
package.path='./miuread.koplugin/?.lua;'..package.path
local gate=require('miuread.download_source_gate')
local calls=0
local reader={chapter=function(self,book,chapter,format,opt)
 calls=calls+1
 assert(book.bookId=='test' and chapter.chapterUid=='1')
 return '<p>Web-body</p>',nil,nil,{coordinate_source_authoritative=true,source_channel='web',coord_html='<p>Web-body</p>'}
end}
local base={reader=reader,book={bookId='test',version=1},
 chapters={{uid='1',title='Chapter 1'}},
 cache={root='/test',manifest={chapters={['1']={complete=true,coord_file='chapter.xhtml'}}}}}
local ready,why,partial=gate.prepare(base)
assert(not ready and why=='web_source_validation_failed:1:source_full_text_mismatch',tostring(why))
assert(partial.expected==1 and partial.verified==0 and partial.fallback_uid=='1')
assert(calls==1)
reader.chapter=function()return '',nil,nil,{coordinate_source_authoritative=false,source_channel='eink'}end
ready,why,partial=gate.prepare(base)
assert(not ready and why=='web_source_not_authoritative:1',tostring(why))
assert(partial.fallback_uid==nil,'untrusted response cannot be a Web fallback')
print('PASS beta14 safe fallback classification')
