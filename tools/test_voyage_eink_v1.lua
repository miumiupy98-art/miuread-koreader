-- Exercise the production route with a local shelf, a simulated HTTP origin
-- and KOReader archive entries. The final EPUB uses the real MiuRead builder.
local root=assert(arg[1],"output directory required")
local fixture=assert(arg[2],"PNG fixture required")
package.path="./miuread.koplugin/?.lua;"..package.path

local function bytes(path)
    local file=assert(io.open(path,"rb"))
    local data=file:read("*a")
    file:close()
    return data
end
local image=bytes(fixture)
local function write(path,data)
    local file=assert(io.open(path,"wb"))
    assert(file:write(data))
    assert(file:close())
end
local function xml(value)
    return (tostring(value or ""):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;"))
end
local make_dir=assert(TEST_MKDIR)
package.loaded["miuread.util"]={
    mkdir=make_dir,remove_tree=function() end,xml=xml,redact_url=tostring,
    copy=function(input) local output={} for key,value in pairs(input) do output[key]=value end return output end,
    id_name=function(s) return (tostring(s):gsub("[^%w_.%-]","_")) end,
    file_size=function(path) if path then local f=io.open(path,"rb"); if f then local n=f:seek("end"); f:close(); return n end end end,
}
package.loaded["logger"]={warn=function() end,info=function() end}
local encoded={}
package.loaded["miuread.json"]={
    encode=function(value) encoded[#encoded+1]=value; return tostring(#encoded) end,
    decode=function(key) return assert(encoded[tonumber(key)]) end,
}
package.loaded["libs/libkoreader-lfs"]={}
package.loaded["miuread.protocol"]={
    escape=tostring,reader_url=function() return "https://weread.qq.com/web/reader/fixture" end,
    is_mp=function() return false end,
}
package.loaded["miuread.cookies"]={}
package.loaded["miuread.codec"]={
    media_file=function(path) if bytes(path)==image then return ".png","image/png" end end,
    body=function(value) return value end,
}
package.loaded["miuread.annotation_coord"]={fromDownloadedXhtml=function(s) return s end}
package.loaded["miuread.readtime_protocol"]={}
local image_failure
package.loaded["miuread.diagnostic_log"]={now=os.clock,record=function(_,entry)
    if entry.operation=="chapter_images" then image_failure=entry end
end}
local Http={
    auth_error_message=function(code) return "[MiuReadAuth] error_code="..tostring(code) end,
    is_auth_error=function(value) return tostring(value):find("[MiuReadAuth]",1,true)~=nil end,
    is_rate_limit_error=function(value) return tostring(value):find("[MiuReadRateLimit]",1,true)~=nil end,
    rate_limit_details=function() return nil end,
}
package.loaded["miuread.http"]=Http
local fixture_auth={vid="fixture",accessToken="test-credential"}
local renewed=0
package.loaded["miuread.shelf_client"]={
    credentials=function() return fixture_auth end,
    request_options=function(credentials) return {auth=false,headers={accessToken=credentials.accessToken}} end,
    refresh=function() renewed=renewed+1; return {vid="fixture",accessToken="test-renewed"} end,
}

local chapter={chapterUid=7,chapterIdx=1,price=100,tar="http://res.weread.qq.com/wrepub/chapter.tar"}
local book={bookId="sample",title="Fixture",author="Fixture"}
local catalog={book={bookId="sample",format="epub",version=4},synckey=4,updated={chapter}}
local chapter_xhtml='<p>Fixture text <img src="https://res.weread.qq.com/wrepub/cover.png" alt="illustration"/></p>'
package.loaded["miuread.eink_archive"]={
    MAX_ARCHIVE_BYTES=32*1024*1024,
    read=function() return chapter_xhtml,"p { margin: 0; }",{} end,
}
local requests,downloaded,info_requests={},0,0
local download_error
local book_info={bookId="sample",version=4,paid=1}
local http={
    download_to_file=function(_,url,path,opt)
        if download_error then error(download_error,0) end
        downloaded=downloaded+1
        assert(opt.max_response_bytes==32*1024*1024)
        requests[#requests+1]={url=url,opt=opt}
        return path,{encryptkey="fixture"}
    end,
}
local store={temp_dir=root,auth=function() return {login_session_id="s",account={vid="fixture"}} end}
local Native=require("miuread.eink_client")
local native=Native.new(http,store)
function native:catalog(id) assert(id=="sample"); return catalog end
function native:request(method,path,parameters)
    info_requests=info_requests+1
    assert(method=="GET" and path=="/book/info" and parameters.bookId=="sample" and parameters.myzy==1)
    return book_info
end
local _,_,_,meta=native:download(book,chapter,root.."/unused",{})
assert(meta.tar==chapter.tar and meta.version=="4" and info_requests==1)
assert(requests[1].url:find("offline=1",1,true) and requests[1].url:find("stopAutoPayWhenBNE=1",1,true))
native:download(book,chapter,root.."/unused",{read_online=true})
assert(requests[2].url:find("offline=0",1,true) and info_requests==1)
local rejected=downloaded
native.book_access={}
book_info={bookId="other",paid=1}
assert(not pcall(native.download,native,book,chapter,root.."/unused",{}))
assert(downloaded==rejected)
book_info={bookId="sample",version=4,payType=4096}
assert(not pcall(native.download,native,book,chapter,root.."/unused",{read_online=true}))
assert(downloaded==rejected)
local original_request=native.request
local now=os.time()
local member_summary={expired=0,expiredTime=now+3600,remainTime=1200,payingRemainTime=0,isPaying=0}
function native:request(method,path,parameters)
    if path=="/pay/memberCardSummary" then
        assert(parameters.source=="reader")
        return member_summary
    end
    return original_request(self,method,path,parameters)
end
native.book_access={}
local online=assert(native:online_chapter_access(book,7))
assert(not online.durable and online.expires>now and online.expires<=now+1205)
store.limited_online_dir=root.."/session-only"
assert(not pcall(native.download,native,book,chapter,root.."/export.zip",{read_online=true,limited_online=true}))
local _,_,_,granted=native:download(book,chapter,store.limited_online_dir.."/unused",{read_online=true,limited_online=true})
assert(granted.online_expires==online.expires and requests[#requests].url:find("offline=0",1,true))
rejected=downloaded
assert(not pcall(native.download,native,book,chapter,root.."/unused",{limited_online=true}))
assert(downloaded==rejected)
native.online_grants={}
member_summary.expired=1
local server_only=assert(native:online_chapter_access(book,7))
assert(server_only.server_confirmation and server_only.session_only and not server_only.expires)
assert(not pcall(native.download,native,book,chapter,store.limited_online_dir.."/unused",{read_online=true,limited_online=true}))
assert(downloaded==rejected)
local _,_,_,server_response=native:download(book,chapter,store.limited_online_dir.."/unused",
    {read_online=true,limited_online=true,online_server_only=true})
assert(server_response.online_server_only and not server_response.online_expires)
assert(requests[#requests].url:find("offline=0",1,true))
assert(not pcall(native.download,native,book,chapter,store.limited_online_dir.."/unused",
    {limited_online=true,online_server_only=true}))

local Result=require("miuread.download_result")
assert(Result.failure_kind("微信读书未确认本章离线下载权限")=="chapter_access")
download_error="download HTTP 402"
local opened,locked=pcall(native.download,native,book,chapter,store.limited_online_dir.."/unused",
    {read_online=true,limited_online=true,online_server_only=true})
assert(not opened and Result.chapter_access(locked)=="locked")
download_error="download HTTP 403"
opened,locked=pcall(native.download,native,book,chapter,store.limited_online_dir.."/unused",
    {read_online=true,limited_online=true,online_server_only=true})
assert(not opened and Result.chapter_access(locked)==nil)
download_error=nil
native.request=original_request
chapter.price=0
native:download(book,chapter,root.."/unused",{})

local Resource=require("miuread.eink_resources")
local called={}
local blocked=false
local archive_failure_status
local expire_once=true
function http:request(opt)
    called[#called+1]=opt
    assert(opt.redirects==0 and opt.auth==false and opt.max_response_bytes==8*1024*1024)
    if opt.url=="https://res.weread.qq.com/wrepub/chapter.tar" then
        assert(opt.headers and opt.headers.accessToken)
        if expire_once then expire_once=false; return "",401,{} end
        return "",302,{Location=blocked and "https://res.weread.qq.com.bad.invalid/a"
            or "https://static.qpic.cn/fixture.tar"}
    end
    if opt.url=="https://static.qpic.cn/fixture.tar" then
        assert(not opt.headers)
        return "",302,{Location="archives/fixture.tar?rev=4"}
    end
    assert(opt.url=="https://static.qpic.cn/archives/fixture.tar?rev=4" and not opt.headers)
    if archive_failure_status then return "",archive_failure_status,{} end
    write(opt.sink_path,"mock archive")
    return "",200,{["Content-Length"]=tostring(#"mock archive")}
end
local resource_path=root.."/mock.archive"
assert(Resource.download(native,chapter.tar,resource_path,{})==resource_path)
assert(#called==4 and renewed==1 and called[2].headers.accessToken=="test-renewed")
blocked=true
assert(not pcall(Resource.download,native,chapter.tar,resource_path,{}))
assert(#called==5)
blocked=false

local mode,entry_size="file",#image
local archive_paths={"images/cover.png"}
local archive_reads,archive_closes=0,0
package.loaded["ffi/archiver"]={Reader={new=function()
    return {open=function() return true end,
        close=function() archive_closes=archive_closes+1 end,
        iterate=function()
            local index=0
            return function()
                index=index+1
                if archive_paths[index] then return {index=index,mode=mode,path=archive_paths[index],size=entry_size} end
            end
        end,
        extractToMemory=function(_,index) assert(archive_paths[index]); archive_reads=archive_reads+1; return image end}
end}}
mode="link"
assert(not pcall(Resource.read,resource_path,root,{}))
assert(archive_reads==0 and archive_closes==1)
mode,entry_size="file",9*1024*1024
assert(not pcall(Resource.read,resource_path,root,{}))
assert(archive_reads==0 and archive_closes==2)
entry_size=#image

local Reader=require("miuread.reader")
local reader=Reader:new(http,store)
reader._eink_client=native
local Transport=require("miuread.download_transport")
assert(Transport.content_mode({})=="eink-offline")
assert(Transport.content_mode({prefetch_hidden=true})=="eink-online")
assert(Transport.content_mode({generate_translation_uid="7"})=="eink-translation")
local route=Transport.new(reader,{channel="web"})
route:restore({selected="web",reason="eink_failed"})
local web_calls=0
reader.web_chapter=function() web_calls=web_calls+1; return "legacy content" end
local function web_catalog() web_calls=web_calls+1; return {} end
local ok,err=pcall(route.invoke,route,"catalog",function() error("E-Ink catalog fixture failed",0) end,web_catalog)
assert(not ok and err=="E-Ink catalog fixture failed" and web_calls==0 and route.selected=="eink")
ok,err=pcall(route.chapter,route,book,chapter,"epub",{fresh_context=true})
assert(not ok and err:find("Web 阅读上下文",1,true) and web_calls==0)
local notes_route=Transport.new(reader,{channel="web",annotations=true,fresh_context=true})
assert(notes_route.content_mode=="eink-offline" and notes_route.selected=="eink")
notes_route:restore({selected="web",reason="eink_failed"})
local failing_web={underlines=function() web_calls=web_calls+1; return {underlines={}} end}
local notes_api=notes_route:service(failing_web)
local before_request=native.request
native.request=function(_,method,path)
    assert(method=="GET" and path=="/book/underlines")
    return {} -- malformed native reply must never be replaced with a Web success
end
local notes_ok,notes_error=pcall(notes_api.underlines,notes_api,book.bookId,chapter.chapterUid)
assert(not notes_ok and tostring(notes_error):find("E-Ink 划线响应不完整",1,true) and web_calls==0)
native.request=before_request
assert(notes_route:result().api_counts.web.annotations==nil and notes_route.selected=="eink")
local html,css,assets,state=route:chapter(book,chapter,"epub",{read_online=true})
assert(web_calls==0 and route.eink_chapters==1)
assert(state.image_archive_ok and state.image_archive_expected and state.book_version=="4")
assert(state.raw_xhtml==chapter_xhtml and state.coord_html==chapter_xhtml and state.coordinate_source_authoritative==false)
assert(#assets==1 and bytes(assets[1].data_path)==image)
assert(html:find("../images/eink-resource-1.png",1,true) and not html:find("https://res.weread",1,true))
local Epub=require("miuread.epub")
Epub.build(root.."/eink-fixture.epub",book,{{uid="7",index=1,title="Fixture chapter",body=html}},css,assets,nil,{})

local original_archive_read=package.loaded["miuread.eink_archive"].read
package.loaded["miuread.eink_archive"].read=function()
    return '<p><img src="//res.weread.qq.com/wrepub/%63over.png?key=fixture"/></p>',css,{
        {href="images/shadow.png",source="misc/cover.png",data_path=fixture,mime="image/png"},
    }
end
local prioritized=route:chapter(book,chapter,"epub",{read_online=true})
assert(prioritized:find("../images/eink-resource-1.png",1,true))
assert(not prioritized:find("../images/shadow.png",1,true))
local bad_name,is_key=Resource.archive_image_name("https://res.weread.qq.com/wrepub/%2Fsecret.png")
assert(not bad_name and is_key)
package.loaded["miuread.eink_archive"].read=function() return chapter_xhtml,"",{} end
book.version=4
local _,same_css=route:chapter(book,chapter,"epub",{})
assert(same_css==css and not requests[#requests].url:find("chapters=0,",1,true))
reader._eink_styles=nil
reader.chapter_state=function() web_calls=web_calls+1; error("legacy Web reader") end
ok,err=pcall(route.chapter,route,book,chapter,"epub",{})
assert(not ok and err:find("E-Ink 章节包缺少书籍样式",1,true) and web_calls==0)
package.loaded["miuread.eink_archive"].read=function()
    return '<p>Fixture text <img src="https://weread.qq.com/web/reader/legacy-image.png"/></p>',css,{}
end
local network_calls_before=downloaded
ok,err=pcall(route.chapter,route,book,chapter,"epub",{})
assert(not ok and err:find("E-Ink 正文图片未完整获取",1,true) and web_calls==0)
assert(downloaded==network_calls_before+1)
assert(image_failure.reason=="referenced_image_missing" and image_failure.missing_images==1)

local prose=("A verified paragraph stays readable when a single illustration is missing. "):rep(3)
local missing_src="https://res.weread.qq.com/wrepub/unavailable.png"
package.loaded["miuread.eink_archive"].read=function()
    return '<p>'..prose..'<img src="'..missing_src..'"/><img src="https://res.weread.qq.com/wrepub/cover.png"/></p>',
        "p {background:url('"..missing_src.."');}",{}
end
local partial,partial_css,partial_assets,partial_state=route:chapter(book,chapter,"epub",{read_online=true})
assert(partial:find(prose,1,true) and not partial:find(missing_src,1,true))
assert(partial_state.image_summary.required_missing==2 and partial_state.raw_xhtml:find(missing_src,1,true))
assert(partial:find("#miuread-image-1#",1,true) and partial_css:find("#miuread-image-1#",1,true))
assert(image_failure.archive_name_missing==2 and #partial_state.image_repair.items==1)
assert(web_calls==0)
ok,err=pcall(route.chapter,route,book,chapter,"epub",{})
assert(not ok and err:find("[MiuReadImageMissing]",1,true))

local record={file=root.."/partial.epub",task_id="image-fixture",image_repair=partial_state.image_repair}
local chapters={{uid="7",index=1,title="Fixture chapter",body=partial}}
partial_state.image_summary.assets=#partial_assets
Epub.build(record.file,book,chapters,partial_css,partial_assets,nil,
    {book_id="sample",variant="online",task_id=record.task_id,chapters={{uid="7"}},images=partial_state.image_summary})
local Repair=require("miuread.online_image_repair")
local original_count=downloaded
local base_reads=archive_reads
archive_paths={"images/cover.png","images/%75navailable.png","other/unavailable.png"}
local result,why,stats=Repair.prepare(native,book,"7",record,root.."/ambiguous")
assert(not result and why=="no_missing_images_recovered" and stats.archive_name_ambiguous==1)
assert(archive_reads==base_reads+2 and downloaded==original_count)
archive_paths[3]=nil
result=assert(Repair.prepare(native,book,"7",record,root.."/repaired"))
assert(result.remaining==0 and result.used["1"]==2 and result.images.assets==2)
assert(archive_reads==base_reads+3 and downloaded==original_count)
local Installer=require("miuread.epub_installer")
local function verify(path,variant,allow_deferred)
    return Installer.validate(path,{book_id="sample",variant=variant,chapters={{uid="7"}},
        image_summary={required_missing=2},allow_deferred_online_images=allow_deferred})
end
assert(not verify(record.file,"online",false))
assert(verify(record.file,"online",true))
local offline_file=root.."/offline.epub"
Epub.build(offline_file,book,chapters,partial_css,partial_assets,nil,{book_id="sample",variant="clean",chapters={{uid="7"}}})
assert(not verify(offline_file,"clean",true))
local broken_path=root.."/broken-online.epub"
Epub.build(broken_path,book,chapters,partial_css,{},nil,{book_id="sample",variant="online",chapters={{uid="7"}}})
assert(not verify(broken_path,"online",true))

-- A previous revision misclassified an imported font stylesheet and shared
-- frontmatter backgrounds as required chapter illustrations. Reuse its cache.
local refs=require("miuread.resource_refs")
local marker=partial:match('src="(data:[^"]+)"')
local shared_css="@import url('"..marker.."');\n/* frontmatter */ body.intro { background:url('"..marker.."'); }\n"
local complex_css="body.keep, body.other {background:url('../keep.png');} @media screen {body.intro {background:url('../nested.png');}}"
local styled,style_stats,remaining=refs.prepare_online_chapter_style(shared_css..complex_css,{body=partial},
    {required_missing=3,missing=3},partial_state.image_repair)
assert(style_stats.required_missing==1 and remaining.items[1].key=="1")
assert(not styled:find("@import",1,true) and not styled:find("frontmatter",1,true))
assert(styled:find("../keep.png",1,true) and styled:find("../nested.png",1,true))
local active=refs.prune_online_chapter_style("body.intro { background:url('../intro.png'); }",'<body class="intro">')
assert(active:find("intro.png",1,true))

-- Exercise the same package and install boundary reached by the online reader.
local script=bytes("miuread.koplugin/miuread/downloader.lua")
local save_start=assert(script:find("function Downloader:_save(",1,true))
local save_stop=assert(script:find("local function append_entry(",save_start,true))
local SaveFixture={}
local util=package.loaded["miuread.util"]
util.safe_name=function(value) return value end
util.free_space=function() return 100*1024*1024 end
util.file_exists=function(path) return util.file_size(path)~=nil end
util.read_file=bytes
util.move_file_safe=function(source,target,validate)
    local moved,err=os.rename(source,target)
    if not moved then return nil,err end
    local valid,why=validate(target)
    if not valid then return nil,why end
    return true,"rename"
end
package.loaded["libs/libkoreader-lfs"].attributes=function() return nil end
package.loaded["miuread.runtime_pressure"]={thresholds=function() return {package_abort=32} end,
    memory_snapshot=function() return {available_kb=100000} end}
setfenv(assert(loadstring(script:sub(save_start,save_stop-1))),setmetatable({Downloader=SaveFixture,
    U=util,Epub=Epub,ResourceRefs=refs,EpubInstaller=Installer,logger=package.loaded["logger"],
    BookIntegrity={core_map_hash=function() return "catalog" end},repair_internal_links=function() return {} end,
},{__index=_G}))()
local finished_record
local destination=root.."/7-online.epub"
local packager=setmetatable({store={prefetch_root=function() return root end,epub_root=function() return root end,
    hidden_prefetch_path=function() return destination end,chapter_variant=function() end,save_book=function() end,
    save_chapter_variant=function(_,_,uid,kind,value) assert(uid=="7" and kind=="online"); finished_record=value end,
}},{__index=SaveFixture})
local ready=packager:_save(book,chapters,partial_assets,shared_css..partial_css,nil,
    {chapter_uid="7",eink_content_mode="eink-online",image_summary={required_missing=4,missing=4},
        image_repair=partial_state.image_repair,expected_chapter_count=1,download_run_id="online-fixture"},{})
assert(ready==finished_record and ready.file==destination and ready.image_summary.required_missing==2)
assert(ready.image_repair and bytes(ready.file):find(prose,1,true))

util.copy_file_stream=function(source,target) write(target,bytes(source)); return true end
local shared_root=root.."/shared-eink-images"
local following={chapterUid=8,chapterIdx=2,price=0}
local original_tar=chapter.tar
chapter.tar=nil
catalog.updated[2]=following
native.resources={}
local saved_read=package.loaded["miuread.eink_archive"].read
package.loaded["miuread.eink_archive"].read=function(_,_,_,_,options)
    if tostring(options.chapter_uid)=="7" then
        return '<p>'..prose..'</p>','.copyright-basemap { background-image: url("bq.jpg"); }',{
            {href="images/native-1.png",source="bq.jpg",data_path=fixture,mime="image/png"},
        }
    end
    return '<p>'..prose..'</p>',"",{}
end
local _,style1,assets1=route:chapter(book,chapter,"epub",{shared_image_root=shared_root})
assert(requests[#requests].url:find("chapters=0,7",1,true) and assets1[1].eink_shared)
reader:cleanup_transient_images()
local _,style2,assets2,status2=route:chapter(book,following,"epub",{shared_image_root=shared_root})
assert(requests[#requests].url:find("chapters=8&",1,true) and not requests[#requests].url:find("chapters=0,",1,true))
assert(style1==style2 and #assets2==1 and assets1[1].data_path==assets2[1].data_path
    and status2.image_summary.required_missing==0 and bytes(assets2[1].data_path)==image)

-- Exercise the whole-book worker's checkpoint writer with a real shared image.
local checkpoint_start=assert(script:find("local function cache_save_assets(",1,true))
local checkpoint_end=assert(script:find("local function cache_load_assets(",checkpoint_start,true))
local shared_checkpoint
local save_assets_factory=assert(loadstring(script:sub(checkpoint_start,checkpoint_end-1).."\nreturn cache_save_assets"))
setfenv(save_assets_factory,setmetatable({
    U=util,
    chapter_paths=function(cache,uid) return {asset_dir=cache.root.."/assets-"..uid} end,
    relative=function(base,path) return path:sub(#base+2) end,
    DownloadDatabase={save_assets=function(_,uid,metadata)
        shared_checkpoint={uid=uid,assets=metadata}
        return true
    end},
},{__index=_G}))
local save_assets=save_assets_factory()
save_assets({root=root},"7",assets1)
assert(shared_checkpoint.uid=="7" and shared_checkpoint.assets[1].file:find("shared-eink-images/",1,true)==1)
save_assets({root=root},"8",assets2)
assert(shared_checkpoint.uid=="8" and root.."/"..shared_checkpoint.assets[1].file==assets1[1].data_path)
local bad_assets={{eink_shared=true,data_path=shared_root.."/missing.png"}}
local checkpoint_ok,checkpoint_err=pcall(save_assets,{root=root},"9",bad_assets)
assert(not checkpoint_ok and tostring(checkpoint_err):find("共享图片文件缺失或为空",1,true))
assert(shared_checkpoint.uid=="8")

local pdf_bytes="%PDF-1.4\n"
local offsets={}
for index,content in ipairs({
    "<</Type/Catalog/Pages 2 0 R>>",
    "<</Type/Pages/Count 1/Kids[3 0 R]>>",
    "<</Type/Page/Parent 2 0 R/MediaBox[0 0 72 72]/Resources<<>>>>",
}) do
    offsets[index]=#pdf_bytes
    pdf_bytes=pdf_bytes..index.." 0 obj\n"..content.."\nendobj\n"
end
local xref=#pdf_bytes
pdf_bytes=pdf_bytes.."xref\n0 4\n0000000000 65535 f \n"
for _,offset in ipairs(offsets) do pdf_bytes=pdf_bytes..string.format("%010d 00000 n \n",offset) end
pdf_bytes=pdf_bytes.."trailer\n<</Root 1 0 R/Size 4>>\nstartxref\n"..xref.."\n%%EOF\n"
local pdf_info={bookId="CB_pdf_test",title="PDF fixture",type=11,paid=1}
local pdf_transfer_count=0
local pdf_response=pdf_bytes
local pdf_http={download_to_file=function(_,url,path,options)
    assert(url=="https://res.weread.qq.com/wrco/pdf_CB_pdf_test")
    assert(options.redirects==nil or options.redirects==0)
    assert(options.headers["Accept-Encoding"]=="identity")
    pdf_transfer_count=pdf_transfer_count+1
    if options.on_chunk then options.on_chunk(#pdf_response) end
    write(path,pdf_response)
    return path,{},200,{preview=pdf_response}
end}
local pdf_native=Native.new(pdf_http,store)
pdf_native.book=function(_,id,details)
    assert(id==pdf_info.bookId and details==true)
    return pdf_info
end
local pdf_worker={}
local pdf_start=assert(script:find("function Downloader:_download_pdf(",1,true))
local pdf_end=assert(script:find("function Downloader:_book_once(",pdf_start,true))
setfenv(assert(loadstring(script:sub(pdf_start,pdf_end-1))),setmetatable({
    Downloader=pdf_worker,U=util,EpubInstaller=Installer,
},{__index=_G}))()
local pdf_records={}
pdf_worker.store={temp_dir=root,auth=store.auth,
    epub_root=function() local dir=root.."/pdf"; make_dir(dir); return dir end,
    prefetch_root=function() local dir=root.."/pdf-cache"; make_dir(dir); return dir end,
    variant=function(_,_,kind) return pdf_records[kind] end,
    save_variant=function(_,_,kind,record) pdf_records[kind]=record end,
}
local noop=function() end
local saved_pdf=pdf_worker:_download_pdf(pdf_info,{},noop,noop,pdf_native)
assert(saved_pdf.complete and saved_pdf.document_format=="pdf" and saved_pdf.variant=="clean")
assert(saved_pdf.file:match("/pdf/.*%.pdf$") and bytes(saved_pdf.file)==pdf_bytes)
local hidden_pdf=pdf_worker:_download_pdf(pdf_info,{read_online=true},noop,noop,pdf_native)
assert(pdf_transfer_count==2 and hidden_pdf.file==root.."/pdf-cache/document-online.pdf"
    and hidden_pdf.pdf_login_session=="s" and bytes(hidden_pdf.file)==pdf_bytes)
pdf_info.paid=0
local access_ok,pdf_error=pcall(pdf_worker._download_pdf,pdf_worker,pdf_info,{},noop,noop,pdf_native)
assert(not access_ok and tostring(pdf_error):find("整书下载权限",1,true) and pdf_transfer_count==2)
pdf_info.paid=1
pdf_response=pdf_bytes:gsub("%%%%EOF\n$","")
local truncated_ok=pcall(pdf_worker._download_pdf,pdf_worker,pdf_info,{},noop,noop,pdf_native)
assert(not truncated_ok and bytes(saved_pdf.file)==pdf_bytes and pdf_records.clean==saved_pdf)

package.loaded["miuread.eink_archive"].read=saved_read
catalog.updated[2]=nil
chapter.tar=original_tar
local repaired_html=assert(Installer.read_chapter_text_by_uid(root.."/repaired/repaired.epub","sample","7"))
assert(repaired_html:find(prose,1,true) and repaired_html:find("../images/eink-repair-1.png",1,true))
assert(repaired_html:find("../images/eink-resource-1.png",1,true) and not repaired_html:find("#miuread-image-",1,true))
assert(bytes(record.file):find("#miuread-image-1#",1,true))
archive_paths={"images/cover.png"}

archive_failure_status=404
package.loaded["miuread.eink_archive"].read=function() return "<body></body>",css,{} end
ok,err=pcall(route.chapter,route,book,chapter,"epub",{read_online=true})
assert(not ok and err:find("[MiuReadImageMissing]",1,true) and web_calls==0)
assert(image_failure.reason=="archive_download_failed" and image_failure.status==404)
archive_failure_status=nil
package.loaded["miuread.eink_archive"].read=original_archive_read
local annotated=Transport.new(reader,{annotations=true,channel="web"})
local _,_,_,annotated_state=annotated:chapter(book,chapter,"epub",{})
assert(annotated_state.source_channel=="eink" and web_calls==0)
local DownloadResult=require("miuread.download_result")
local notes_completed={eink_content_mode="eink-offline",annotation_pending=true,
    annotation_fallback=true,annotation_error_kind="alignment"}
assert(DownloadResult.state(notes_completed,false)=="completed")
assert(DownloadResult.state(notes_completed,true)=="pending_install")
assert(DownloadResult.shelf_status(notes_completed,false)=="已生成")
assert(DownloadResult.notice("Fixture",notes_completed,false)=="Fixture下载完成")
assert(DownloadResult.summary_note(notes_completed)==nil)
assert(not DownloadResult.aggregate({notes_completed}).annotation_fallback)
notes_completed.annotation_error_kind="forbidden"
assert(not DownloadResult.annotation_unresolved(notes_completed))
assert(DownloadResult.summary_note(notes_completed)==nil)

-- Original E-Ink TXT responses do not require an EPUB encryption header.
local text_format="txt"
local text_id="CB_uploaded_example"
local text_book={bookId=text_id,title="TXT fixture"}
local text_chapter={chapterUid=7,chapterIdx=1,price=0}
local text_catalog={book={bookId=text_id,format=text_format,version=9},synckey=9,updated={text_chapter}}
local text_http={download_to_file=function(_,url,filename)
    assert(url:find("bookType=txt",1,true) and url:find("bookVersion=9",1,true))
    assert(url:find("chapters=7&",1,true) and not url:find("chapters=0,",1,true))
    write(filename,"test TAR")
    return filename,{},200,{}
end}
local text_reader=Reader:new(text_http,store)
text_reader._eink_client=Native.new(text_http,store,text_reader)
text_reader._eink_client.catalog=function() return text_catalog end
local csv_name=text_id.."_7_9.txt"
local text_contents="\255\254\45\78\253\86\10\0A\0"
package.loaded["ffi/archiver"].Reader.new=function()
    return {open=function(_,path) assert(bytes(path)=="test TAR"); return true end,close=function() end,
        iterate=function()
            local i=0
            return function()
                i=i+1
                if i==1 then return {mode="file",index=i,path="info.txt",size=2} end
                if i==2 then return {mode="file",index=i,path=csv_name,size=#text_contents} end
            end
        end,extractToMemory=function(_,index) assert(index==2); return text_contents end}
end
package.loaded["miuread.codec"].text_xhtml=function(value) return '<p>'..xml(value)..'</p>' end
local _,_,_,txt_state=text_reader:eink_chapter(text_book,text_chapter,"txt",{eink_only=true,read_online=true})
assert(txt_state.native_text=="中国\nA" and txt_state.source_channel=="eink")
csv_name="CB_other_book_7_9.txt"
assert(not pcall(text_reader.eink_chapter,text_reader,text_book,text_chapter,"txt",{eink_only=true}))
local txt_first,txt_second=root.."/one.txt",root.."/two.txt"
write(txt_first,txt_state.native_text)
write(txt_second,"第二章正文")
local plain={
    {uid="7",index=1,title="First",body="<p>中国</p>",text_path=txt_first},
    {uid="8",index=2,title="Second",body="<p>第二章正文</p>",text_path=txt_second},
}
packager.store.variant=function() end
packager.store.epub_path=function(_,filename) return root.."/"..filename end
packager.store.save_variant=function(_,_,kind,value) assert(kind=="clean"); finished_record=value end
local text_record=packager:_save(text_book,plain,{},"",nil,
    {eink_content_mode="eink-offline",output_format="txt",expected_chapter_count=2,download_run_id="text-fixture"},{})
assert(text_record==finished_record and text_record.file:match("%.txt$") and text_record.document_format=="txt")
assert(bytes(text_record.file)==txt_state.native_text.."\n\n第二章正文")
assert(text_record.chapter_map[1].text_offset==0 and text_record.chapter_map[2].text_offset==#txt_state.native_text+2)

local ReadTime=require("miuread.eink_readtime")
local function result(value,raises,claims)
    local sender={post_json=function(_,_,_,opt)
        assert(opt.before_dispatch()==claims)
        if raises then error(value,0) end
        return value
    end}
    return ReadTime.send(sender,{credentials=fixture_auth,body={}},function() return claims end)
end
assert(result({succ=1},false,true).state=="confirmed")
local expired=result("[MiuReadAuth] error_code=-2012",true,true)
assert(expired.state=="pending" and expired.error=="authentication")
assert(result("response lost",true,true).state=="unknown")
assert(result({succ=0},false,true).state=="unknown")
assert(result("not sent",true,false).state=="pending")
print("E-Ink route, rights, auth renewal, strict transport, EPUB generation and read-time receipts passed")
