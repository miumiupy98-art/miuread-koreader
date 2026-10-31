local function shallow(v)local t={}for k,x in pairs(v)do t[k]=x end;return t end
package.preload['miuread.util']=function()return {
 copy=shallow,file_exists=function(p)return p=='/books/c.epub'end,
 file_size=function(p)return p=='/books/c.epub' and 2048 or nil end
}end
package.preload['miuread.epub_installer']=function()return {} end
package.preload['miuread.source_position']=function()return {} end
package.preload['miuread.web_source_provenance']=function()return {} end
package.preload['libs/libkoreader-lfs']=function()return {attributes=function()return 2 end}end
package.path='./miuread.koplugin/?.lua;./miuread.koplugin/?/init.lua;'..package.path
local M=require('miuread.legacy_coordinate_backfill')
local store={state={}}
function store:get(k,d)return self.state[k] or d end
function store:set(k,v)self.state[k]=v;return true end
local record={book_id='book',file='/books/c.epub',title='c',variant='clean',
 progress_source_book_version=7,chapter_count=5,
 post_install_web_status='needs_attention',post_install_web_cached=3,
 post_install_web_verified=2,post_install_web_unmapped=1,post_install_web_failed=2,
 post_install_web_failed_uids={{index=2,uid='ch-2'},{index=5,uid='ch-5'}}}
assert(M.import_post_install(store,record,'person','login'))
local row=M.progress_rows(store,'person','login')[1]
assert(row.cached==3 and row.verified==2 and row.total==5)
local job={book_id='book',file='/books/c.epub',variant='clean',version=7,size=2048,mtime=2}
assert(M.enqueue(store,job,'person','login',true))
local j=assert(M.select(store,0,'person','login'));assert(j.next_index==2)
assert(M.commit(store,j,{ok=true,uid='ch-2',total=5,mapping_verified=false,mapping_error='short'},1))
j=assert(M.select(store,100,'person','login'));assert(j.next_index==5)
assert(M.commit(store,j,{ok=true,uid='ch-5',total=5,mapping_verified=true},101))
assert(M.summary(store,'book').complete==1)
local final=M.progress_rows(store,'person','login')[1]
assert(final.cached==5 and final.verified==3 and final.unmapped==2)
print('PASS beta16 manual retry only originally failed indices')
