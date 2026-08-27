local function preload(name,value)
    package.preload[name]=function() return value end
end

local fixture_exists=true
local fixture_mime="image/jpeg"
local download_mode="ok"

preload("miuread.json",{})
preload("miuread.protocol",{})
preload("miuread.cookies",{})
preload("miuread.http",{is_auth_error=function(value) return tostring(value):find("AUTH",1,true)~=nil end})
preload("miuread.codec",{
    media_file=function() return ".jpg",fixture_mime end,
    body=function(html) return tostring(html):match("<body[^>]*>(.*)</body>") or html end,
})
preload("miuread.annotation_coord",{})
preload("miuread.util",{
    file_exists=function() return fixture_exists end,
    redact_url=function(value) return value end,
    xml=function(value) return value end,
})
preload("logger",{warn=function() end,info=function() end,dbg=function() end})

local reader_path=assert(arg[1],"reader.lua path required")
local Reader=assert(loadfile(reader_path))()
local fixture="/tmp/fixture.jpg"
local requested={}
local stub={
    store={temp_dir="/tmp"},
    http={
        download_to_file=function(_,url)
            requested[#requested+1]=url
            if download_mode=="auth" then error("AUTH") end
            return fixture
        end,
    },
}
local base_state={
    image_work_root="/tmp",
    url="https://weread.qq.com/web/reader/test",
    image_resource_book_id="CB_26713355",
}

local function localize(xhtml,css,assets,source_map,state)
    requested={}
    return Reader._localize_epub_images(stub,xhtml,assets or {},source_map or {},state or base_state,css or {},{})
end

local function assert_not_image_page(body)
    assert(not body:find("miu%-image%-only%-page"),body)
end

local page='<html><body class="copyright-basemap3"><h1 title="第一部分">　　　</h1></body></html>'
local css=[[
/* .copyright-basemap3 { background-image: url('../Images/wrong.jpg'); } */
.copyright-basemap3 { background-image: url('../Images/chapter1.jpg'); }
]]
local body,assets,summary=localize(page,css)
assert(requested[1]=="https://res.weread.qq.com/wrepub/web/CB_26713355/chapter1.jpg","initial request="..tostring(requested[1]))
assert(#requested==1 and #assets==1)
assert(body:find('../images/remote%-0001%.jpg')~=nil,body)
assert(body:find('miu%-image%-only%-title%-marker')~=nil,body)
assert(not body:find('miu%-chapter%-title'),body)
assert(summary.required_localized==1 and summary.required_missing==0)
local image_body=body

body,assets,summary=localize(page,[[.copyright-basemap3 { background-image: url('../Images/parts/chapter 1.jpg'); }]])
assert(requested[1]=="https://res.weread.qq.com/wrepub/web/CB_26713355/parts/chapter%201.jpg","nested request="..tostring(requested[1]))
assert(#assets==1 and summary.required_localized==1)

local numeric_state={image_work_root="/tmp",url=base_state.url,image_resource_book_id="26713355"}
body,assets,summary=localize(page,[[.copyright-basemap3 { background-image: url('../Images/chapter1.jpg'); }]],nil,nil,numeric_state)
assert(requested[1]=="https://res.weread.qq.com/wrepub/web/26713355/chapter1.jpg","numeric request="..tostring(requested[1]))
assert(#assets==1 and summary.required_localized==1)

body,assets,summary=localize('<html><body class="part"><h1>序</h1></body></html>',[[.part { background-image: url('../Images/decor.jpg'); }]])
assert(#requested==0)
assert_not_image_page(body)

body,assets,summary=localize('<html><body class="part alternate"><h1 title="第一部分">　</h1></body></html>',[[
.part { background-image: url('../Images/one.jpg'); }
.alternate { background-image: url('../Images/two.jpg'); }
]])
assert(#requested==0)
assert_not_image_page(body)

body,assets,summary=localize(page,[[.copyright-basemap3 { background-image: url('../Images/one.jpg'), url('../Images/two.jpg'); }]])
assert(#requested==0)
assert_not_image_page(body)

body,assets,summary=localize(page,[[.copyright-basemap3 { background: center / cover url('../Images/chapter1.jpg'); }]])
assert(#requested==0)
assert_not_image_page(body)

body,assets,summary=localize(page,[[.copyright-basemap3 { background-image: linear-gradient(#fff,#000), url('../Images/chapter1.jpg'); }]])
assert(#requested==0)
assert_not_image_page(body)

body,assets,summary=localize('<html><body class="part"><h1>&copy;</h1></body></html>',[[.part { background-image: url('../Images/decor.jpg'); }]])
assert(#requested==0)
assert_not_image_page(body)

body,assets,summary=localize(page,[[.copyright-basemap3 { background-image: url('https://example.test/decor.jpg'); }]])
assert(#requested==0 and #assets==0)
assert(summary.required_missing==1)

local ambiguous_state={image_work_root="/tmp",url=base_state.url}
body,assets,summary=localize(page,css,nil,nil,ambiguous_state)
assert(#requested==0 and #assets==0)
assert(summary.required_missing==1)

body,assets,summary=localize('<html><body class="copyright-basemap3"><div>　</div></body></html>',css)
assert(#requested==0)
assert_not_image_page(body)

for _,bad in ipairs({
    "../Images/../secret.jpg",
    "../Images/parts\\secret.jpg",
    "../Images/parts%5Csecret.jpg",
    "../Images/chapter%ZZ.jpg",
    "../Images/parts//chapter.jpg",
}) do
    body,assets,summary=localize(page,".copyright-basemap3 { background-image: url('"..bad.."'); }")
    assert(#requested==0,bad)
    assert(#assets==0,bad)
    assert(summary.required_missing==1,bad.." missing="..tostring(summary.required_missing))
end

fixture_exists=false
body,assets,summary=localize(page,css)
assert(#requested==1 and #assets==0)
assert(summary.required_missing==1)
fixture_exists=true

fixture_mime="text/html"
body,assets,summary=localize(page,css)
assert(#requested==1 and #assets==0)
assert(summary.required_missing==1)
fixture_mime="image/jpeg"

download_mode="auth"
local ok,err=pcall(localize,page,css)
assert(not ok and tostring(err):find("AUTH",1,true),tostring(err))
download_mode="ok"

body,assets,summary=localize('<html><body><h1>正文</h1><img data-src="https://example.test/figure.jpg" /></body></html>')
assert(requested[1]=="https://example.test/figure.jpg","absolute request="..tostring(requested[1]))
assert(#assets==1 and summary.required_localized==1)

local tar_assets={{href="images/tar.jpg",data_path="/tmp/tar.jpg",mime="image/jpeg"}}
body,assets,summary=localize('<html><body><h1>正文</h1><img src="../Images/tar.jpg" /></body></html>',nil,tar_assets,{["images/tar.jpg"]="../images/tar.jpg"})
assert(#requested==0)
assert(body:find('../images/tar%.jpg')~=nil,body)
assert(summary.required_localized==1)

body,assets,summary=localize('<html><body><h1>正文</h1><p style="background-image:url(\'../Images/decor.jpg\')">正文</p></body></html>')
assert(#requested==0)
assert(body:find("正文",1,true),body)

print("reader background regression: ok")

for _,name in ipairs({
    "miuread.config","miuread.footnotes","miuread.resource_refs","miuread.internal_links",
    "miuread.thoughts","miuread.epub","miuread.download_plan","miuread.download_database",
    "miuread.epub_installer","miuread.book_integrity","miuread.source_position",
}) do preload(name,{}) end
local downloader_path=assert(arg[2],"downloader.lua path required")
local Downloader=assert(loadfile(downloader_path))()

local namespace,ambiguous=Downloader._catalog_resource_namespace({
    {tar=""},
    {tar="https://res.weread.qq.com/wrco/tar_CB_26713355_7"},
    {tar="https://res.weread.qq.com/wrco/tar_CB_26713355_24"},
},"26713355")
assert(namespace=="CB_26713355" and ambiguous==false,tostring(namespace))

namespace,ambiguous=Downloader._catalog_resource_namespace({},"26713355")
assert(namespace=="26713355" and ambiguous==false)
namespace,ambiguous=Downloader._catalog_resource_namespace({{tar="https://res.weread.qq.com/wrco/tar_26713355_1"}},"26713355")
assert(namespace=="26713355" and ambiguous==false)
namespace,ambiguous=Downloader._catalog_resource_namespace({
    {tar="https://res.weread.qq.com/wrco/tar_CB_26713355_1"},
    {tar="https://res.weread.qq.com/wrco/tar_ALT_26713355_2"},
},"26713355")
assert(namespace==nil and ambiguous==true)
namespace,ambiguous=Downloader._catalog_resource_namespace({{tar="https://res.weread.qq.com/wrco/tar_CB_126713355_1"}},"26713355")
assert(namespace==nil and ambiguous==true)

local prepared=Downloader._prepare_chapter_body(image_body,"第一部分",2)
assert(prepared:find('miu%-image%-only%-title%-marker')~=nil,prepared)
assert(prepared:find('miu%-chapter%-title')==nil,prepared)
print("catalog resource namespace regression: ok")
