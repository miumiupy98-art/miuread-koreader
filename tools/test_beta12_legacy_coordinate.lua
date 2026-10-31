-- Runs the REAL legacy coordinator with controlled book/source/EPUB fixtures.
package.preload['miuread.util']=function() return {
 copy=function(value)
   if type(value)~='table' then return value end
   local out={};for k,v in pairs(value) do out[k]=v end;return out
 end,
 file_exists=function(path) return path=='/books/old.epub' end,
 file_size=function(path) return path=='/books/old.epub' and 2000 or nil end,
} end
local source={};local cache={}
function source.readExactChapter(reader,id,uid,version) return cache[id..':'..uid..':'..version] end
function source.validateDownloadChapter(a,b)
 if a=='local:'..b then return {anchors=3} end
 return nil,'source_anchor_missing'
end
function source.cacheChapter(reader,id,uid,ver,web) cache[id..':'..uid..':'..ver]=web;return true end
package.preload['miuread.source_position']=function() return source end
local fixture={book_id='123',progress_source_book_version=8,_chapter_count=2,
 chapters={{uid='a',title='A'},{uid='b',title='B'}}}
local installer={}
function installer.inspect(path)
 assert(path=='/books/old.epub');return fixture,{test=true}
end
function installer.read_chapter_text(path,idx)
 assert(idx==1 or idx==2)
 return idx==1 and 'local:web-a' or 'local:web-b',fixture.chapters[idx]
end
package.preload['miuread.epub_installer']=function() return installer end
package.path='./miuread.koplugin/?.lua;./miuread.koplugin/?/init.lua;'..package.path
local legacy=require('miuread.legacy_coordinate_backfill')
local store={value={}}
function store:get(k,d) return self.value[k] or d end
function store:set(k,v) self.value[k]=v;return true end
function store:all_books() return {{book_id='123',title='old',version=8,variants={clean={file='/books/old.epub',variant='clean',progress_source_complete=false}}}} end
local candidates=legacy.discover(store)
assert(#candidates==1 and candidates[1].book_id=='123')
assert(legacy.enqueue(store,candidates[1],'user-a','session-a',false))
assert(not legacy.select(store,0,'user-b','session-a'),'account isolation')
local job=assert(legacy.select(store,0,'user-a','session-a'))
local called=0
local reader={chapter=function(self,book,ch)
 called=called+1
 return 'body',nil,nil,{coordinate_source_authoritative=true,source_channel='web',coord_html='web-'..ch.uid}
end}
local r=legacy.perform(job,reader)
assert(r.ok and r.index==1 and r.uid=='a' and r.anchors==3)
assert(legacy.commit(store,job,r,1))
job=assert(legacy.select(store,100,'user-a','session-a'))
assert(job.next_index==2)
r=legacy.perform(job,reader)
assert(r.ok and r.uid=='b' and called==2)
assert(legacy.commit(store,job,r,101))
assert(not legacy.select(store,200,'user-a','session-a'))
assert(legacy.summary(store,'123').complete==1)
-- Rechecking uses existing exact-version caches without a network call.
assert(legacy.enqueue(store,candidates[1],'user-a','session-a',true))
job=assert(legacy.select(store,200,'user-a','session-a'))
r=legacy.perform(job,reader)
assert(r.ok and called==2)
-- Nonmatching web source must not populate the next index as complete.
cache['123:a:8']=nil
assert(legacy.commit(store,job,r,201))
job=assert(legacy.select(store,300,'user-a','session-a'))
assert(job.next_index==2)
-- Pending callback from old sequence cannot overwrite the new state.
assert(not legacy.commit(store,{key=job.key,vid=job.vid,session=job.session,next_index=1},r,301))
-- Change the account identity; pending old-account tasks are not selected.
assert(not legacy.select(store,301,'user-b','session-b'))
print('PASS beta12 legacy source backfill queue, web validation, account guard, replay guard')
