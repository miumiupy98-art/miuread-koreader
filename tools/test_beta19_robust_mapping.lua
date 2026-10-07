local script=arg and arg[0] or ""
local root=script:match("^(.*)/tools/[^/]+$") or "."
local function read(path)
    local f=assert(io.open(root.."/"..path,"rb")); local s=f:read("*a"); f:close(); return s
end

local config=read("miuread.koplugin/miuread/config.lua")
local precise=read("miuread.koplugin/miuread/precise_position.lua")
local source=read("miuread.koplugin/miuread/source_position.lua")
local posmap=read("miuread.koplugin/miuread/annotations/posmap.lua")
local main=read("miuread.koplugin/main.lua")
local worker=read("miuread.koplugin/miuread/legacy/read_report_worker.lua")

assert(config:find('VERSION = ',1,true),"version identity missing while validating beta.19 mapping contract")
assert(precise:find('SOURCE_ANCHOR_WORDS = {24, 16, 12}',1,true),"multi-level source anchor sizes missing")
assert(precise:find('anchor_candidates = anchor_candidates',1,true),"captured anchor set missing")
assert(precise:find('candidate_reason = tostring(reason or "neighbor")',1,true),"bounded chapter candidate reason missing")
assert(source:find('local function anchor_variants(anchor)',1,true),"source anchor variants missing")
assert(source:find('anchor_coordinate_conflict',1,true),"conflicting exact anchors must fail closed")
assert(source:find('precision_anchor_recovered',1,true),"anchor recovery diagnostics missing")
assert(source:find('{images=false, fresh_context=true}',1,true),"beta.18 fresh progress context lost")
assert(posmap:find('function PosMap.locateSource',1,true),"source-only locator missing")
assert(posmap:find('soft hyphen',1,true) and posmap:find('zero width space',1,true),"format-only normalization contract missing")
assert(main:find('reliable_text_anchor_landing',1,true),"quiet reliable text-anchor state missing")
assert(main:find('if same_chapter and text_anchor_attempted and not reliable_text_anchor_landing',1,true),"percent fallback can still override text-anchor landing")
assert(not main:find('精确章节内位置暂未确认',1,true),"old misleading exact-position warning still present")
assert(main:find('已定位到云端章节附近',1,true),"real chapter-only fallback warning missing")
assert(worker:find('local refreshed=refresh_remote_anchor(client, book_id, book)',1,true),"ReadReport fresh GET guard lost")

-- Minimal UTF-8 splitter for Lua 5.1/5.3 test portability.
local function split_chars(s)
    local out,i={},1
    while i<=#s do
        local b=s:byte(i)
        local n=(b<0x80 and 1) or (b<0xE0 and 2) or (b<0xF0 and 3) or 4
        out[#out+1]=s:sub(i,i+n-1); i=i+n
    end
    return out
end
package.preload['util']=function()
    return {
        trim=function(s) return (tostring(s or ''):gsub('^%s+',''):gsub('%s+$','')) end,
        splitToChars=split_chars,
        splitToArray=function(s,sep)
            local out,start={},1
            while true do
                local i,j=s:find(sep,start,true)
                if not i then out[#out+1]=s:sub(start); break end
                out[#out+1]=s:sub(start,i-1); start=j+1
            end
            return out
        end,
    }
end
package.path=root.."/miuread.koplugin/?.lua;"..root.."/miuread.koplugin/?/init.lua;"..package.path
local PosMap=require('miuread.annotations.posmap')
local nbsp=string.char(194,160)
local shy=string.char(194,173)
local map=PosMap.build('<p>Hello'..nbsp..'world soft'..shy..'hyphen end</p>')
local range=PosMap.locateSource(map,'Hello world softhyphen',{context_after='end'})
assert(range,"source locator did not ignore formatting-only runes")
local ordinary=PosMap.locate(map,'Hello world softhyphen',{context_after='end'})
assert(not ordinary,"annotation locator unexpectedly inherited source-only normalization")
local ambig,ambig_err=PosMap.locateSource(PosMap.build('<p>alpha beta alpha beta</p>'),'alpha beta',{})
assert(not ambig and ambig_err=='ambiguous',"short source anchors must remain ambiguity-safe")

-- Isolate SourcePosition to verify shorter exact-anchor recovery and conflict rejection.
package.loaded['miuread.source_position']=nil
package.loaded['miuread.annotations.posmap']=nil
package.loaded['miuread.wr_co']=nil
package.loaded['miuread.util']=nil
package.loaded['logger']=nil
package.loaded['libs/libkoreader-lfs']=nil
package.preload['miuread.util']=function()
    local U={}
    function U.trim(s) return (tostring(s or ''):gsub('^%s+',''):gsub('%s+$','')) end
    function U.copy(t) local o={} for k,v in pairs(t or {}) do o[k]=v end return o end
    function U.clamp(v,a,b) if v<a then return a elseif v>b then return b else return v end end
    function U.id_name(s) return tostring(s or '') end
    function U.mkdir() return true end
    function U.file_size() return nil end
    function U.read_file() return nil end
    function U.atomic_write() return true end
    function U.first_line(s,n) s=tostring(s or ''):match('^[^\n]*') or ''; return s:sub(1,n or #s) end
    return U
end
package.preload['logger']=function() return {info=function() end,warn=function() end} end
package.preload['libs/libkoreader-lfs']=function() return {attributes=function() return nil end,dir=function() error('unused') end} end
local mode='recover'
package.preload['miuread.annotations.posmap']=function()
    local P={}
    function P.build()
        local tr,th,nm={},{},{}
        for i=1,100 do tr[i]='x'; th[i]=i; nm[i]=i end
        return {text_runes=tr,text_to_html=th,norm_map=nm}
    end
    function P.locateSource(map,text)
        if mode=='recover' then
            if text=='short-good' then return '9-19',10,20 end
            return nil,'not_found'
        end
        if text=='a' then return '9-19',10,20 end
        if text=='b' then return '29-39',30,40 end
        return nil,'not_found'
    end
    P.locate=P.locateSource
    function P.htmlToText(map,a,b) return a,b end
    return P
end
package.preload['miuread.wr_co']=function()
    return {fromMap=function(map,boundary) return {co=boundary,basis='test',rune_boundary=boundary,utf16_extra=0} end}
end
local Source=require('miuread.source_position')
local reader={chapter=function() return '<x/>',nil,nil,{coord_html='<x/>'} end}
local record={book={book_id='1',title='T'}}
local anchor={chapter_uid='10',chapter_index=1,chapter_word_count=100,total_word_count=100,words_before=0,book_version=1,
    anchor_kind='forward_24',anchor_text='long-bad',point_side='start',anchor_candidates={
        {anchor_kind='forward_24',anchor_text='long-bad',point_side='start'},
        {anchor_kind='forward_12',anchor_text='short-good',point_side='start'},
    }}
local recovered=assert(Source.locate(reader,record,anchor,{}))
assert(recovered.offset==10 and recovered.precision_anchor=='forward_12' and recovered.precision_anchor_recovered==true,
    'shorter exact anchor did not recover native coordinate')
mode='conflict'
anchor.anchor_candidates={
    {anchor_kind='forward_12',anchor_text='a',point_side='start'},
    {anchor_kind='backward_12',anchor_text='b',point_side='start'},
}
local conflict,conflict_err=Source.locate(reader,record,anchor,{})
assert(conflict==nil and conflict_err=='anchor_coordinate_conflict','conflicting exact anchors were not rejected')

print('beta19 robust exact mapping contract: PASS')
