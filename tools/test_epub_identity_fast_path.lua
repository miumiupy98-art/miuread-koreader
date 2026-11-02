local TOOL_DIR=tostring(arg and arg[0] or ""):match("^(.*)/[^/]+$") or "."
local SRC_ROOT=TOOL_DIR.."/.."
local ROOT=SRC_ROOT.."/miuread.koplugin/"
local TMP=(os.getenv("TMPDIR") or "/tmp").."/miuread-test-epub-identity-fast-path"
package.path=ROOT.."?.lua;"..package.path
os.execute("rm -rf "..string.format("%q",TMP))
os.execute("mkdir -p "..string.format("%q",TMP))

local function copy(v,seen)
    if type(v)~="table" then return v end
    seen=seen or {}
    if seen[v] then return seen[v] end
    local out={}
    seen[v]=out
    for k,x in pairs(v) do out[copy(k,seen)]=copy(x,seen) end
    return out
end

local function quote(s) return string.format("%q",s) end
local function dump_table(v,seen)
    local t=type(v)
    if t=="nil" then return "nil"
    elseif t=="boolean" or t=="number" then return tostring(v)
    elseif t=="string" then return quote(v)
    elseif t~="table" then return "nil" end
    seen=seen or {}
    if seen[v] then error("cycle") end
    seen[v]=true
    local parts={"{"}
    for k,x in pairs(v) do parts[#parts+1]="["..dump_table(k,seen).."]="..dump_table(x,seen).."," end
    parts[#parts+1]="}"
    seen[v]=nil
    return table.concat(parts)
end

package.preload["datastorage"]=function()
    return {
        getFullDataDir=function() return TMP end,
        getSettingsDir=function() return TMP end,
        getDataDir=function() return TMP end,
    }
end
package.preload["libs/libkoreader-lfs"]=function()
    return {
        mkdir=function(p)
            os.execute("mkdir -p "..string.format("%q",p))
            return true
        end,
        attributes=function(path,what)
            local f=io.open(path,"rb")
            if f then
                local n=f:seek("end")
                f:close()
                if what=="mode" then return "file" end
                return {mode="file",size=n,modification=os.time()}
            end
            local ok=os.execute("[ -d "..string.format("%q",path).." ]")
            if ok==true or ok==0 then
                if what=="mode" then return "directory" end
                return {mode="directory",size=0,modification=os.time()}
            end
            return nil
        end,
    }
end
local SEED={
    schema=135,
    library={
        legacy_book={
            book_id="legacy_book",
            title="Ordinary Book",
            author="Author Name",
            variants={},
            chapters={},
            catalog={},
        },
    },
    sessions={},
}
package.preload["luasettings"]=function()
    local L={}
    function L:open()
        local o={data=copy(SEED)}
        function o:readSetting(k,d)
            local v=self.data[k]
            if v==nil then return d end
            return v
        end
        function o:saveSetting(k,v) self.data[k]=v end
        function o:delSetting(k) self.data[k]=nil end
        function o:flush() return true end
        return o
    end
    return L
end
package.preload["dump"]=function() return function(v) return dump_table(v) end end
package.preload["logger"]=function()
    return {info=function() end,warn=function() end,err=function() end,dbg=function() end}
end
local function json_encode(value)
    if type(value)=="string" then
        return '"'..value:gsub('[\\"%c]',function(c) return string.format("\\u%04x",c:byte()) end)..'"'
    end
    if type(value)=="number" or type(value)=="boolean" then return tostring(value) end
    if type(value)~="table" then return "null" end
    local parts={}
    if #value>0 then
        for _,item in ipairs(value) do parts[#parts+1]=json_encode(item) end
        return "["..table.concat(parts,",").."]"
    end
    local keys={}
    for key in pairs(value) do keys[#keys+1]=key end
    table.sort(keys)
    for _,key in ipairs(keys) do parts[#parts+1]=json_encode(key)..":"..json_encode(value[key]) end
    return "{"..table.concat(parts,",").."}"
end
local function json_decode(text)
    local pos=1
    local function skip() pos=text:find("[^ \t\r\n]",pos) or (#text+1) end
    local value
    local function str()
        pos=pos+1
        local out={}
        while true do
            local c=text:sub(pos,pos)
            if c=="" or c=='"' then pos=pos+1 break end
            if c=="\\" then out[#out+1]=text:sub(pos+1,pos+1); pos=pos+2
            else out[#out+1]=c; pos=pos+1 end
        end
        return table.concat(out)
    end
    function value()
        skip()
        local c=text:sub(pos,pos)
        if c=="{" or c=="[" then
            local object=c=="{"
            local out={}
            pos=pos+1; skip()
            if text:sub(pos,pos)==(object and "}" or "]") then pos=pos+1 return out end
            while true do
                if object then
                    skip()
                    local key=str()
                    skip(); pos=pos+1
                    out[key]=value()
                else
                    out[#out+1]=value()
                end
                skip()
                local separator=text:sub(pos,pos); pos=pos+1
                if separator~="," then break end
            end
            return out
        elseif c=='"' then return str()
        elseif text:sub(pos,pos+3)=="true" then pos=pos+4 return true
        elseif text:sub(pos,pos+4)=="false" then pos=pos+5 return false
        elseif text:sub(pos,pos+3)=="null" then pos=pos+4 return nil
        end
        local literal=text:match("^%-?%d+%.?%d*",pos) or ""
        pos=pos+#literal
        return tonumber(literal)
    end
    return value()
end
package.preload["json"]=function()
    return {encode=json_encode,decode=json_decode}
end

local Store=require("miuread.store")
local Epub=require("miuread.epub")
local LocalLibrary=require("miuread.local_library")

local store=Store:new()

local popen_calls=0
local original_popen=io.popen
io.popen=function(...)
    popen_calls=popen_calls+1
    return original_popen(...)
end

-- Test 1: Real MiuRead EPUB built via Epub.build(...)
local miuread_epub=TMP.."/miuread_book.epub"
Epub.build(
    miuread_epub,
    {bookId="3300012345",title="MiuRead Test Book",author="Tester"},
    {{uid="c1",index=1,title="Chapter 1",body="<p>Hello MiuRead</p>"}},
    nil,
    {},
    nil,
    {
        book_id="3300012345",
        variant="clean",
        content_type="epub",
        chapters={{uid="c1",index=1,title="Chapter 1",word_count=1200}},
        progress_source_complete=true,
        progress_source_chapter_count=1,
    }
)

popen_calls=0
local light_id=store:epub_identity_light(miuread_epub,true)
assert(type(light_id)=="table" and light_id.book_id=="3300012345","epub_identity_light failed on real MiuRead EPUB")
assert(light_id.variant=="clean","epub_identity_light missed variant")
assert(light_id.title=="MiuRead Test Book","epub_identity_light missed title")
assert(popen_calls==0,"epub_identity_light spawned subprocess")

local full_id=store:epub_identity(miuread_epub,true)
assert(type(full_id)=="table" and full_id.book_id=="3300012345","epub_identity failed on real MiuRead EPUB")
assert(type(full_id.chapters)=="table" and #full_id.chapters==1,"epub_identity missed decoded chapters from miuread.json")
assert(popen_calls==0,"epub_identity spawned subprocess on real MiuRead EPUB")

assert(LocalLibrary.is_miuread_generated_epub(miuread_epub)==true,"LocalLibrary.is_miuread_generated_epub failed on real MiuRead EPUB")
assert(popen_calls==0,"is_miuread_generated_epub spawned subprocess")

local rec_book,rec_record,rec_kind,rec_source=store:recover_miuread_file(miuread_epub,true)
assert(rec_book and rec_book.book_id=="3300012345","recover_miuread_file failed on real MiuRead EPUB")
assert(rec_record and rec_kind=="clean" and rec_source=="embedded_book_id","recover_miuread_file unexpected result")
assert(popen_calls==0,"recover_miuread_file spawned subprocess on real MiuRead EPUB")

-- Test 2: Ordinary ZIP .epub (without OEBPS/miuread.json or miuread://book/)
local ordinary_epub=TMP.."/ordinary_book.epub"
Epub._stream_zip(ordinary_epub,{
    {name="mimetype",source="application/epub+zip"},
    {
        name="META-INF/container.xml",
        source='<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
    },
    {
        name="OEBPS/package.opf",
        source='<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Ordinary Book</dc:title><dc:creator>Author Name</dc:creator></metadata><manifest><item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>',
    },
    {
        name="OEBPS/text/ch1.xhtml",
        source='<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><body><p>'..string.rep("Ordinary text ",512)..'</p></body></html>',
    },
})

popen_calls=0
assert(store:epub_identity_light(ordinary_epub,true)==nil,"ordinary EPUB must return nil when require_book_id=true")
assert(store:recover_miuread_file(ordinary_epub,true)==nil,"recover_miuread_file must return nil on ordinary EPUB")
assert(LocalLibrary.is_miuread_generated_epub(ordinary_epub)==false,"ordinary EPUB must not be classified as MiuRead EPUB")
assert(popen_calls==0,"ordinary EPUB check spawned unzip subprocess")

local title_meta=store:epub_identity_light(ordinary_epub,false)
assert(type(title_meta)=="table" and title_meta.title=="Ordinary Book","ordinary EPUB title extraction failed")
local leg_book=store:identify_file(ordinary_epub,false)
assert(leg_book and leg_book.book_id=="legacy_book","identify_file failed to match legacy library book by title")
assert(popen_calls==0,"identify_file on stored OPF spawned unzip subprocess")

-- Test 3: Non-ZIP synthetic .epub file still works via fallback
local synthetic_epub=TMP.."/synthetic_nonzip.epub"
local sf=assert(io.open(synthetic_epub,"wb"))
sf:write('{"book_id":"990001","variant":"notes"}\n<dc:title>Synthetic Book</dc:title><dc:source>miuread://book/990001</dc:source>')
sf:close()

local syn_light=store:epub_identity_light(synthetic_epub,true)
assert(type(syn_light)=="table" and syn_light.book_id=="990001","non-ZIP synthetic fallback failed in epub_identity_light")
local syn_full=store:epub_identity(synthetic_epub,true)
assert(type(syn_full)=="table" and syn_full.book_id=="990001","non-ZIP synthetic fallback failed in epub_identity")
assert(LocalLibrary.is_miuread_generated_epub(synthetic_epub)==true,"non-ZIP synthetic fallback failed in LocalLibrary")

io.popen=original_popen
os.execute("rm -rf "..string.format("%q",TMP))
print("test_epub_identity_fast_path: PASS")
