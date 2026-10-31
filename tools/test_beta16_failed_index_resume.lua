-- beta.16 retry only previously failed UID, without repeating the whole EPUB
local files,serialized={},{}
local function deep(v) if type(v)~='table' then return v end local r={};for k,w in pairs(v) do r[k]=deep(w) end;return r end
package.preload['miuread.util']=function() return {
 id_name=function(s)return tostring(s):gsub('[^%w%-]','-') end,
 copy=deep,read_file=function(p) return files[p] end,
 atomic_write=function(p,data) files[p]=data;return true end,
 file_exists=function(p)return p=='/books/test.epub' end,
 file_size=function(p)return p=='/books/test.epub' and 4300 or nil end
} end
local count=0
package.preload['miuread.json']=function() return {
 encode=function(x)count=count+1;local key='json:'..count;serialized[key]=deep(x);return key end,
 decode=function(x)return deep(assert(serialized[x])) end,
} end
package.preload['libs/libkoreader-lfs']=function() return {attributes=function(p,what) return 1666 end} end
local meta={book_id='123',task_id='same-download-task',_chapter_count=3,chapters={
 {uid='a',title='A'},{uid='b',title='B'},{uid='c',title='C'}}}
package.preload['miuread.epub_installer']=function()return {inspect=function(path)
 assert(path=='/books/test.epub');return meta,{stub=true} end} end
local calls={}
package.preload['miuread.legacy_coordinate_backfill']=function() return {
 perform=function(job,reader)
  calls[#calls+1]=job.next_index
  if job.next_index==2 and not _G.retry_pass then return {ok=false,reason='web_fetch:HTTP 403'} end
  return {ok=true,index=job.next_index,total=3,uid=meta.chapters[job.next_index].uid,mapping_verified=true}
 end
} end
package.preload['logger']=function()return {info=function()end,warn=function()end}end
package.path='./miuread.koplugin/?.lua;./miuread.koplugin/?/init.lua;'..package.path
local Post=require('miuread.post_install_web')
local store={auth=function()return {account={vid='user'},login_session_id='session'}end,
 book_dir=function()return '/state' end}
local book={bookId='123',title='test',version=7}
local options={download_run_id='same-download-task'}
local record={book_id='123',title='test',file='/books/test.epub',chapter_count=3,
 variant='clean',task_id='same-download-task',progress_source_book_version=7}
assert(Post.begin(store,record,book,options))
local once=0
local ok,err=pcall(Post.run,store,record,book,{},options,function(stage,current,total)
 assert(stage=='coordinate'); assert(total==3)
end,function(stage) once=once+1;if once==2 then error('__MIUREAD_HIBERNATE__') end end)
assert(not ok and tostring(err):find('__MIUREAD_HIBERNATE__'))
local resumed=assert(Post.resume(store,book,options))
assert(resumed.file==record.file)
assert(Post.run(store,resumed,book,{},options))
assert(resumed.post_install_web_status=='needs_attention')
assert(resumed.post_install_web_verified==2)
assert(resumed.post_install_web_failed==1)
assert(resumed.post_install_web_total==3)
assert(table.concat(calls,',')=='1,2,3',table.concat(calls,','))
_G.retry_pass=true
local again=assert(Post.resume(store,book,options))
assert(Post.run(store,again,book,{},options))
assert(table.concat(calls,',')=='1,2,3,2','unexpected full-book re-fetch')
assert(again.post_install_web_status=='complete')
assert(again.post_install_web_verified==3 and again.post_install_web_cached==3)
assert(again.post_install_web_failed==0)
-- After completed pass, same task has no retry to perform.
-- Replacing EPUB byte-size invalidates the snapshot.
store.auth=function()return {account={vid='other'},login_session_id='session'}end
assert(Post.resume(store,book,options)==nil)
print('PASS beta16 same-task failed-index recovery, no repeated successful chapters')
