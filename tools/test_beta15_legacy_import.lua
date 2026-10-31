local store={value={}}
function store:get(k,default)return self.value[k] or default end
function store:set(k,v)self.value[k]=v;return true end
package.preload['miuread.util']=function()return {file_exists=function(p)return p=='/test/book.epub'end,
 file_size=function()return 3012 end,copy=function(v)return v end}end
package.preload['miuread.epub_installer']=function()return {} end
package.preload['miuread.source_position']=function()return {} end
package.preload['libs/libkoreader-lfs']=function()return {attributes=function()return 12345 end}end
package.path='./miuread.koplugin/?.lua;'..package.path
local M=require('miuread.legacy_coordinate_backfill')
local rec={book_id='b',file='/test/book.epub',variant='clean',title='Book',chapter_count=35,
  progress_source_book_version=10,post_install_web_status='needs_attention',
  post_install_web_verified=33,post_install_web_skipped=1,post_install_web_failed=1,
  post_install_web_next_index=36,post_install_web_error='anchor_mismatch:short'}
assert(M.import_post_install(store,rec,'user','session'))
local rows=M.progress_rows(store,'user','session')
assert(#rows==1 and rows[1].verified==33 and rows[1].total==35 and rows[1].status=='needs_attention')
assert(rows[1].error=='anchor_mismatch:short')
assert(M.select(store,os.time(),'user','session')==nil,'no silent background after post-install')
rec.post_install_web_status='complete';rec.post_install_web_verified=34;rec.post_install_web_failed=0
assert(M.import_post_install(store,rec,'user','session'))
rows=M.progress_rows(store,'user','session')
assert(#rows==1 and rows[1].status=='complete')
assert(rows[1].verified==34 and rows[1].skipped==1)
assert(M.select(store,os.time(),'user','session')==nil)
print('PASS beta15 imported post-install status without a background job')
