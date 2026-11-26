-- E-Ink comment offsets are in the original UTF-16 string. Keep that source
-- separate from Web/progress proofs and verify it against the actual EPUB.
local U=require("miuread.util")
local Json=require("miuread.json")
local Codec=require("miuread.codec")
local PosMap=require("miuread.annotations.posmap")
local Range=require("miuread.annotations.range")
local Source={}
local LIMIT=2*1024*1024

local function path(store,id,uid)
    return store:book_cache_path(id).."/eink-comment-source-"..U.id_name(uid)..".json"
end

local function load(store,id,uid)
    local body=U.read_file(path(store,id,uid),true)
    if not body or #body>LIMIT*4 then return nil end
    local ok,row=pcall(Json.decode,body)
    if not ok or type(row)~="table" or row.book_id~=tostring(id) or row.uid~=tostring(uid)
        or type(row.raw)~="string" or #row.raw>LIMIT or (row.kind~="html" and row.kind~="text") then return nil end
    return row
end

local function version_compatible(row,version)
    return row and (not version or not row.version or tonumber(row.version)==version)
end

function Source.exists(store,id,uid,version)
    return version_compatible(load(store,id,uid),version)
end

local function visual_body(html)
    return Codec.body(html)
        :gsub("<[hH]1[^>]-class%s*=%s*['\"]miu%-chapter%-title['\"][^>]*>.-</[hH]1%s*>","")
        :gsub("<script[%s%S]-</script%s*>",""):gsub("<style[%s%S]-</style%s*>","")
        :gsub("<!%-%-.-%-%->","")
end

-- The EPUB footnote converter replaces source icons with numbered links
-- and adds a KOReader footnote body at the end of the chapter. Those generated
-- nodes have no positions in the original E-Ink string.
local function without_generated_notes(html)
    local removed=0
    html=html:gsub('<aside([^>]*)>(.-)</aside%s*>',function(attrs,body)
        if attrs:find('class="footnote weread-book-footnote"',1,true)
            and attrs:find('role="doc-footnote"',1,true)
            and attrs:match('id="wt_%d+"') then
            removed=removed+1
            return ""
        end
        return "<aside"..attrs..">"..body.."</aside>"
    end)
    if removed==0 then return nil end
    return html:gsub('<span class="fn%-ref"><a([^>]*)>(.-)</a></span>',function(attrs,label)
        -- The original icon contributes no text. Anchor-style notes keep
        -- their numeric label already present in the original source.
        if attrs:find('role="doc-noteref"',1,true) and attrs:match('href="#wt_%d+"') then return label end
        return '<span class="fn-ref"><a'..attrs..">"..label.."</a></span>"
    end)
end

function Source.rendered_bodies(chapter)
    local rendered=visual_body(chapter)
    local bodies={rendered}
    local body=without_generated_notes(rendered)
    if body then
        bodies[#bodies+1]=body
        body=rendered:gsub('<span class="fn%-ref"><a epub:type="noteref" role="doc%-noteref" href="#wt_%d+" id="wtref_%d+">%[%d+%]</a></span>',"")
        bodies[#bodies+1]=without_generated_notes(body) or body
    end
    return bodies
end

local function verify(row,file,id,uid)
    if type(file)~="string" or file=="" then return nil,"epub_missing" end
    local chapter,err=require("miuread.epub_installer").read_chapter_text_by_uid(file,id,uid)
    if not chapter then return nil,err end
    local original=row.kind=="text" and Codec.text_xhtml(row.raw) or row.raw
    local validate=require("miuread.source_position").validateDownloadChapter
    local source=visual_body(original)
    local why
    for _,body in ipairs(Source.rendered_bodies(chapter)) do
        local proved,err=validate(body,source)
        if proved then return proved end
        why=why or err
    end
    return nil,why
end

function Source.ensure(reader,store,id,uid,file,expected_version)
    local cached=load(store,id,uid)
    if version_compatible(cached,expected_version) and verify(cached,file,id,uid) then return true end
    local raw,kind,version,limited=reader:eink_comment_source(id,uid)
    if expected_version and (limited or tonumber(version)~=expected_version) then
        return nil,"eink_comment_book_version_unavailable"
    end
    if (kind~="html" and kind~="text") or type(raw)~="string" or raw==""
        or #raw>LIMIT or not U.is_valid_utf8(raw) then
        return nil,"eink_source_invalid"
    end
    local row={raw=raw,kind=kind,book_id=tostring(id),uid=tostring(uid),version=tonumber(version)}
    local proved,err=verify(row,file,id,uid)
    if not proved then return nil,err end
    store:book_dir(id)
    return U.atomic_write(path(store,id,uid),Json.encode(row),true)
end

function Source.make_map(raw,kind)
    local map=PosMap.build(raw,kind=="text")
    local by_unit,units={},0
    for i,rune in ipairs(map.runes) do
        by_unit[units]=i
        units=units+(#rune==4 and 2 or 1)
    end
    by_unit[units]=#map.runes+1
    return {map=map,by_unit=by_unit}
end

-- The annotation endpoint supplies the HTML used by the original ranges.
-- A download/progress XHTML file can render the same text with different tags
-- and therefore different raw UTF-16 offsets.
function Source.personal_alignment(store,id,uid,file,version)
    local row=load(store,id,uid)
    if not version_compatible(row,version) then return nil,"source_cache_missing" end
    if row.kind~="html" then return nil,"eink_comment_source_invalid" end
    local chapter,err=require("miuread.epub_installer").read_chapter_text_by_uid(file,id,uid)
    if not chapter then return nil,err end
    local original,rendered=require("miuread.eink_progress_source").align(row.raw,chapter)
    if not original then return nil,rendered end
    return {source=original,rendered=rendered,version=tonumber(row.version)}
end

function Source.for_document(store,id,uid,file)
    local row=load(store,id,uid)
    if not row then return nil end
    local proved=verify(row,file,id,uid)
    if not proved then return nil end
    return Source.make_map(row.raw,row.kind)
end

local entities={amp="&",lt="<",gt=">",quot='"',apos="'",nbsp=" ",
    rsquo="\226\128\153",lsquo="\226\128\152",rdquo="\226\128\157",ldquo="\226\128\156",
    mdash="\226\128\148",ndash="\226\128\147",hellip="\226\128\166"}
local function entity(s)
    local code=tonumber(s:match("^#(%d+)$")) or tonumber(s:match("^#[xX]([%da-fA-F]+)$") or "",16)
    if not code or code<1 or code>0x10ffff or (code>=0xd800 and code<=0xdfff) then
        return entities[s] or "&"..s..";"
    end
    if code<128 then return string.char(code) end
    if code<2048 then return string.char(192+math.floor(code/64),128+code%64) end
    if code<65536 then return string.char(224+math.floor(code/4096),128+math.floor(code/64)%64,128+code%64) end
    return string.char(240+math.floor(code/262144),128+math.floor(code/4096)%64,128+math.floor(code/64)%64,128+code%64)
end

function Source.quote(source,range)
    local first,last,point=Range.parse(range)
    if not first or point then return nil end
    local start,ending=source.by_unit[first-1],source.by_unit[last-1]
    if not start or not ending then return nil end
    local a,b=PosMap.htmlToText(source.map,start,ending)
    if not a then return nil end
    local quote=table.concat(source.map.text_runes,"",a,b-1)
    if not source.map.plain_text then quote=quote:gsub("&([%w#]+);",entity) end
    return U.trim((quote:gsub("%s+"," ")))
end
return Source
