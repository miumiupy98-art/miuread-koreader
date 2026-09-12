local f=assert(io.open(assert(arg[1])));local source=f:read('*a');f:close()
local a=assert(source:find('function Plugin:_thought_favorite_context(',1,true))
local b=assert(source:find('\nfunction Plugin:',a+1,true))
local fn=assert(loadstring('local U={trim=function(s) return s end};local Plugin={};'..source:sub(a,b-1)..'\nreturn Plugin._thought_favorite_context'))()
local record={path='book.epub',book={bookId='test',title='Book',author='Author',catalog={{}}},record={chapter_map={}}}
local fallback=0
local host={store={book=function() return record.book end},sync={current=record,_document_path=function() return 'book.epub' end},
_reader_session_is_weread=function() return true end,_current_book_record=function() fallback=fallback+1;return record end,
_thought_chapter_title_from_rows=function() return 'Chapter' end}
local info={book_id='test',chapter_uid='one',range='1-2'}
local value=fn(host,info);assert(fallback==0 and value.book_title=='Book' and value.chapter_title=='Chapter' and value.range_key=='1-2')
for _,path in ipairs({'other.epub',''}) do host.sync._document_path=function() return path end;fn(host,info) end
assert(fallback==2)
record.path=nil;host.sync._document_path=function() return nil end;fn(host,info);assert(fallback==3)
record.path='book.epub';host.sync.current=nil;fn(host,info);assert(fallback==4)
host.sync=nil;fn(host,info);assert(fallback==5)
host._reader_session_is_weread=function() return false end;fn(host,info);assert(fallback==6)
print('POPUP_DOCUMENT_MATCH_AND_FALLBACK_OK')
