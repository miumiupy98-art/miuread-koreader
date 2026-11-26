-- Run the production checkpoint path against a saved chapter, then damage
-- only the generated files to model an interrupted EPUB build.
local main=assert(io.open("miuread.koplugin/miuread/downloader.lua","rb"))
local source=main:read("*a")
main:close()
local function extract(first,last)
    local start=assert(source:find(first,1,true))
    local finish=assert(source:find(last,start+1,true))
    return source:sub(start,finish-1)
end

local files,assets={},{}
local resets=0
local U={
    id_name=tostring,
    mkdir=function() return true end,
    file_size=function(path) return files[path] and #files[path] end,
    read_file=function(path) return files[path] end,
    atomic_write=function(path,value) files[path]=value; return true end,
    remove_tree=function(root)
        resets=resets+1
        for path in pairs(files) do
            if path:sub(1,#root+1)==root.."/" then files[path]=nil end
        end
    end,
}
local logger={warn=function() end,info=function() end}
local DownloadDatabase={
    save_manifest=function() return true end,
    save_assets=function(_,uid,items) assets[uid]=items; return true end,
    load_assets=function(_,uid) return assets[uid] end,
}
local env=setmetatable({U=U,logger=logger,DownloadDatabase=DownloadDatabase,
    IMAGE_TRANSFORM_VERSION=1,CONTENT_TRANSFORM_VERSION=1,TITLE_TRANSFORM_VERSION=1,
    FOOTNOTE_TRANSFORM_VERSION=1,LEGACY_CONTENT_TRANSFORM_VERSION=1,
    validate_body_fragment=function(body) return body and body~="" end,
    Footnotes={validate=function(body) return body~="<p>bad final</p>" end},
},{__index=_G})
local code=extract("local function relative(","local function cache_root(")
    ..extract("local function cache_reset_entry(","function Downloader:new(")
local start=assert(source:find("    local function process_one(",1,true))
local finish=assert(source:find('        if not body then\n',assert(source:find(
    'logger.warn("[MiuRead][Download] content checkpoint invalid"',start,true)),true))
local run=source:sub(start,finish-1)
local context=[[
local function process(cache,chapter)
    local opt,transport={}, {eink_only=true}
    local self,expected={},1
    local failure_map,restricted_map={},{}
    local chapters_from_checkpoint=0
    local function respect_reader_priority() end
    local function progress() end
]]
local exposed=context..run..[[
        return body,style,entry
    end
    return process_one(chapter,1,0)
end
return cache_save_base,cache_save_final,process
]]
local base,final,process=setfenv(assert(loadstring(code..exposed)),env)()
local cache={root="/fixture",manifest={chapters={}}}
local chapter={chapterUid=1,title="Fixture",wordCount=10}
local images={{data="image payload",href="img.png",mime="image/png"}}
local entry=base(cache,chapter,nil,"<p>base</p>","base stylesheet",images,{source_channel="eink"},{done=true})
final(cache,chapter,"<p>final</p>",nil,"final stylesheet")
assert(process(cache,chapter)==true)
local old_resets=resets
local final_file=cache.root.."/"..entry.final_file
files[final_file]="<p>bad final</p>"
local body,style,saved=process(cache,chapter)
assert(body=="<p>base</p>" and style=="base stylesheet" and saved==entry)
assert(resets==old_resets and not entry.complete)
final(cache,chapter,"<p>final</p>",nil,"rebuilt stylesheet")
assert(process(cache,chapter)==true)
files[cache.root.."/"..assets["1"][1].file]="truncated"
assert(not process(cache,chapter) and cache.manifest.chapters["1"]==nil and resets==old_resets+1)
print("Interrupted or damaged final XHTML rebuilds from the verified base, while truncated images invalidate only their chapter")
