package.path="./miuread.koplugin/?.lua;"..package.path
package.loaded["libs/libkoreader-lfs"]={}
package.loaded["util"]={}
package.loaded["miuread.json"]={}
local U=require("miuread.util")
local Source=require("miuread.eink_progress_source")

local phrase="A bright morning brought two new visitors."
local prefix='<html><head><style>hidden CSS</style></head><body><p data-test="a>b">🌕 &amp; '
local raw=prefix..phrase..'</p><p>Another bright paragraph.</p></body></html>'
local document='<body><h1 class="miu-chapter-title">Added title</h1><div>🌕 &amp; '
    ..phrase..'</div><p>Another bright paragraph.</p></body>'
local native,rendered=assert(Source.align(raw,document))
assert(native.text=="🌕&"..phrase:gsub("%s","").."Anotherbrightparagraph.")
local map={source=native,rendered=rendered}
local actual=assert(Source.find_local(map,{anchor_text=phrase,point_side="start",context_before="🌕 &",
    context_after="Another bright paragraph."}))
local expected=U.utf8_len(prefix)+1
assert(actual==expected,"offset must include markup, encoded entities, and the supplementary character")
local quote=assert(Source.remote_anchor(native,rendered,expected))
assert(Source.find_local(map,{anchor_text=quote,point_side="start"})==expected)
assert(Source.find_local(map,{anchor_text=phrase,point_side="end"})>expected)
assert(not Source.align(raw,document:gsub("two","three")))
assert(not Source.remote_anchor(native,rendered,native.units+1))

local duplicate="<p>"..phrase.."</p><p>Between.</p><p>"..phrase.."</p>"
local one,two=assert(Source.align(duplicate,duplicate))
local duplicated_map={source=one,rendered=two}
assert(not Source.find_local(duplicated_map,{anchor_text=phrase,point_side="start"}))
assert(Source.find_local(duplicated_map,{anchor_text=phrase,point_side="start",context_before="Between."})>0)

local saved,fetches,installed={},0,document
local limited=false
U.file_exists=function(path) return saved[path]~=nil end
U.read_file=function(path) return saved[path] end
U.atomic_write=function(path,data) saved[path]=data; return true end
package.loaded["miuread.epub_installer"]={read_chapter_text_by_uid=function(path,id,uid)
    assert(path=="/finished.epub" and id=="fixture" and tostring(uid)=="40")
    return installed
end}
local account="first"
package.loaded["miuread.download_database"]={account_key=function() return account end}
local reader={store={
    book_dir=function() end,
    book_cache_path=function() return "/private" end,
},eink_comment_source=function(_,id,uid)
    assert(id=="fixture" and tostring(uid)=="40")
    fetches=fetches+1
    return raw,"html",17,limited
end}
local record={path="/finished.epub",book={book_id="fixture"},
    record={eink_content_mode="eink-offline",progress_source_book_version=17}}
local anchor={chapter_uid="40",chapter_index=7,book_version=17,anchor_text=phrase,point_side="start",
    display_progress=24,xpointer="/body/p[1]/text().4"}
local missing,why=Source.local_position(reader,record,anchor,false)
assert(not missing and why=="source_cache_missing" and fetches==0)
assert(Source.has_cache(reader.store,record,"40")==false)
assert(Source.prepare(reader,record,"40")==true)
assert(Source.has_cache(reader.store,record,"40")==true)
local fetched=assert(Source.local_position(reader,record,anchor,false))
assert(fetched.eink_coordinate and fetched.book_version==17 and fetched.chapter_offset==expected and fetches==1)
assert(Source.local_position(reader,record,anchor,false).chapter_offset==expected and fetches==1)
-- A search for the selected word may have no unique hit across the book.
-- Calibrate with a longer, exact passage and keep the original selected endpoints.
local Coordinates=require("miuread.eink_coordinates")
local attempts,bias=0,1
local search={request=function(_,method,path,args)
    assert(method=="GET" and path=="/book/search" and args.bookId=="fixture")
    attempts=attempts+1
    local a,b=raw:find(args.keyword,1,true)
    assert(a and #args.keyword>=12 and args.keyword:find("bright",1,true))
    local first=U.utf8_len(raw:sub(1,a-1))+1+bias
    local ending=U.utf8_len(raw:sub(1,b))+1+bias
    return {totalCount=1,result={{chapterUid=40,abstract=args.keyword,
        absStart=first,absEnd=ending,keywordStart=first}}}
end}
local selected={context_before="A",context_after="morning"}
local result_first,result_last=Coordinates.annotation_range(search,reader,"fixture","40",17,record,selected,"bright")
local bright=expected+#"A "+bias
assert(result_first==bright and result_last==bright+#"bright" and attempts==1)
bias=2
assert(not Coordinates.annotation_range(search,reader,"fixture","40",17,record,selected,"bright"))
local rejected,why=Source.annotation_selection(duplicated_map,"bright")
assert(not rejected and why=="eink_source_selection_ambiguous")
assert(Source.annotation_selection(duplicated_map,"bright","Between. A","morning"))

local function review_group(text,offset_bias)
    local a,b=assert(Source.annotation_selection(map,text))
    local start,stop=native.rows[a].first+offset_bias,native.rows[b].last+offset_bias
    return {range=("%d-%d"):format(start,stop),texts={{abstract="review body"},{abstract=text}}}
end
local unavailable={request=function() return {totalCount=0,result={}} end}
local left_review=review_group("A bright",0)
local right_review=review_group("new visitors.",0)
local a,b,verification=Coordinates.annotation_range(unavailable,reader,"fixture","40",17,
    record,{},"morning",{left_review,right_review})
local morning=expected+#"A bright "
assert(a==morning and b==morning+#"morning" and verification=="eink_chapter_review_range")
assert(Coordinates.annotation_range(unavailable,reader,"fixture","40",17,
    record,{},"A bright",{left_review})==expected)
assert(not Coordinates.annotation_range(unavailable,reader,"fixture","40",17,
    record,{},"morning",{left_review}))
assert(not Coordinates.annotation_range(unavailable,reader,"fixture","40",17,
    record,{},"morning",{left_review,review_group("new visitors.",1)}))

local cloud=assert(Source.remote_position(reader,record,{chapter_uid="40",offset=expected,version=17}))
assert(cloud.eink_source_anchor==true and cloud.search_anchor_text==quote and fetches==1)
local cloud_start=assert(Source.remote_position(reader,record,{chapter_uid="40",offset=0,version=17}))
assert(cloud_start.eink_chapter_start and cloud_start.chapter_ratio==0 and not cloud_start.search_anchor_text)
anchor.at_chapter_start=true
assert(Source.local_position(reader,record,anchor,false).chapter_offset==0)
anchor.at_chapter_start=nil
assert(not Source.remote_position(reader,record,{chapter_uid="40",offset=expected,version=18}))
account="second"
assert(not Source.local_position(reader,record,anchor,false))
assert(Source.seed(reader.store,"fixture","40",17,raw))
assert(Source.local_position(reader,record,anchor,false).chapter_offset==expected and fetches==1)
installed=document:gsub("two","three")
assert(not Source.local_position(reader,record,anchor,false))
account,installed,limited="limited",document,true
assert(Source.prepare(reader,record,"40")==false and fetches==2)
assert(Source.has_cache(reader.store,record,"40")==false,"temporary authorization must not create a persistent source")
account,installed,limited="different-text",document:gsub("two","three"),false
assert(Source.prepare(reader,record,"40")==false and fetches==3)
assert(Source.has_cache(reader.store,record,"40")==false,"unaligned source must not be cached")

local txt=require("miuread.eink_text_progress")
local path=assert(arg[1]).."/native-progress.txt"
local first_chapter="Opening chapter without any visitors."
local second_prefix="  🌕  "
local second_chapter=second_prefix..phrase.."\nAnother bright paragraph."
local text_body=first_chapter.."\n\n"..second_chapter
local txt_file=assert(io.open(path,"wb"))
assert(txt_file:write(text_body))
txt_file:close()
local text_record={path=path,book={book_id="fixture"},record={document_format="txt",complete=true,
    text_size=#text_body,chapter_map={
        {uid="7",index=1,text_offset=0,text_bytes=#first_chapter},
        {uid="8",index=2,text_offset=#first_chapter+2,text_bytes=#second_chapter},
    }}}
local local_text=assert(txt.local_position(text_record,{anchor_text=phrase,point_side="start"}))
assert(local_text.chapter_uid=="8" and local_text.chapter_offset==6 and local_text.book_version==0)
local remote_text=assert(txt.remote_position(text_record,{chapter_uid="8",offset=6,version=0}))
assert(remote_text.eink_txt_anchor and txt.local_position(text_record,{
    anchor_text=remote_text.search_anchor_text,point_side="start"}).chapter_offset==6)
assert(not txt.remote_position(text_record,{chapter_uid="8",offset=6,version=1}))
text_record.record.text_size=#text_body+1
assert(not txt.local_position(text_record,{anchor_text=phrase,point_side="start"}))
print("Native EPUB offsets, bidirectional lookup, old EPUB cache recovery and mismatch fences passed")
