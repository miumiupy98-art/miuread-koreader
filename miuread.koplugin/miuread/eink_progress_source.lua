local U=require("miuread.util")
local Source={}
local LIMIT=2*1024*1024
local MAX_VISIBLE=80000

local entities={amp="&",lt="<",gt=">",quot='"',apos="'",nbsp=" ",ensp=" ",emsp=" ",thinsp=" ",
    lsquo="‘",rsquo="’",ldquo="“",rdquo="”",hellip="…",mdash="—",ndash="–",middot="·",
    copy="©",reg="®",trade="™",times="×",bull="•"}

local function decode_entity(name)
    if entities[name] then return entities[name] end
    local n=tonumber(name:match("^#(%d+)$")) or tonumber(name:match("^#[xX]([%da-fA-F]+)$") or "",16)
    if not n or n<1 or n>0x10ffff or (n>=0xd800 and n<=0xdfff) then return nil end
    if n<128 then return string.char(n) end
    if n<2048 then return string.char(192+math.floor(n/64),128+n%64) end
    if n<65536 then return string.char(224+math.floor(n/4096),128+math.floor(n/64)%64,128+n%64) end
    return string.char(240+math.floor(n/262144),128+math.floor(n/4096)%64,128+math.floor(n/64)%64,128+n%64)
end

local function space(c)
    return c:match("^%s$") or c==" " or c=="　" or c==" " or c==" " or c==" " or c==" "
end

local function normalize(text)
    if type(text)~="string" then return "" end
    return (text:gsub("[%s%c]+",""):gsub(" ",""):gsub("　",""):gsub(" ",""):gsub(" ","")
        :gsub(" ",""):gsub(" ",""))
end

local function units(text)
    local _,supplementary=text:gsub("[\240-\244]","")
    return U.utf8_len(text)+supplementary
end

local block={p=true,div=true,section=true,br=true,li=true,blockquote=true,tr=true,
    h1=true,h2=true,h3=true,h4=true,h5=true,h6=true}

-- Use the original Java string's UTF-16 boundaries, including tags and entity
-- spellings, while aligning the same visible text in the KOReader document.
local function stream(html,plain)
    if type(html)~="string" or #html==0 or #html>LIMIT or not U.is_valid_utf8(html) then return nil end
    local out={rows={},visible={}}
    local text={}
    local i,co,byte=1,0,1
    local hidden
    local function append(c,last,raw_end)
        if space(c) or c=="﻿" then
            if #out.visible>0 and out.visible[#out.visible]~=" " then out.visible[#out.visible+1]=" " end
            return
        end
        out.visible[#out.visible+1]=c
        out.rows[#out.rows+1]={first=co,last=last,byte=byte,visible=#out.visible,raw_first=i,raw_end=raw_end}
        text[#text+1]=c
        byte=byte+#c
    end
    while i<=#html do
        local c=html:sub(i,i)
        local next_i
        if c=="<" and not plain then
            if html:sub(i,i+3)=="<!--" then
                local ending=html:find("-->",i+4,true)
                if not ending then return nil end
                next_i=ending+3
            else
                local ending,quote=i+1
                while ending<=#html do
                    local token=html:sub(ending,ending)
                    if quote then
                        if token==quote then quote=nil end
                    elseif token=="'" or token=='"' then quote=token
                    elseif token==">" then break end
                    ending=ending+1
                end
                if ending>#html then return nil end
                next_i=ending+1
                local close,tag=html:sub(i+1,ending-1):match("^%s*(/?)%s*([%w:_-]+)")
                tag=tag and tag:lower()
                if hidden then
                    if close=="/" and tag==hidden then hidden=nil end
                elseif close=="" and (tag=="head" or tag=="script" or tag=="style") then
                    hidden=tag
                elseif block[tag] then
                    append(" ",co)
                end
            end
        else
            local n=html:byte(i)
            local width=n<128 and 1 or (n<224 and 2 or (n<240 and 3 or 4))
            c=html:sub(i,i+width-1)
            next_i=i+width
            if c=="&" and not plain then
                local name=html:sub(i+1,i+24):match("^([#%w]+);")
                local decoded=name and decode_entity(name)
                if decoded then c,next_i=decoded,i+#name+2 end
            end
            if not hidden then
                if #out.rows>=MAX_VISIBLE then return nil end
                append(c,co+units(html:sub(i,next_i-1)),next_i)
            end
        end
        co=co+units(html:sub(i,next_i-1))
        i=next_i
    end
    out.text,out.units=table.concat(text),co
    return out
end

function Source.plain_text(raw)
    return stream(raw,true)
end

function Source.compact_text(text)
    return normalize(text)
end

local function identity(record,uid)
    local row=record and record.record or {}
    if row.eink_content_mode~="eink-offline" and row.eink_content_mode~="eink-online" then return nil end
    if row.translation_mode or row.annotation_requested or row.variant=="notes" then return nil end
    local id=tostring((record.book or {}).book_id or "")
    local version=tonumber(row.progress_source_book_version)
    local file=tostring(record.path or row.file or "")
    if id=="" or not tostring(uid or ""):match("^%d+$") or not version or version<=0 or not file:match("%.epub$") then return nil end
    return id,version,file
end

local function cache_path(store,id,uid,version)
    return store:book_cache_path(id).."/eink-progress-"..require("miuread.download_database").account_key(store)
        .."-"..U.id_name(uid).."-v"..tostring(version)..".xhtml"
end

function Source.seed(store,id,uid,version,raw)
    version=tonumber(version)
    if not version or version<=0 or type(raw)~="string" or #raw==0 or #raw>LIMIT or not U.is_valid_utf8(raw) then return false end
    store:book_dir(id)
    return U.atomic_write(cache_path(store,id,uid,version),raw,true)
end

function Source.align(raw,html)
    local source=stream(raw)
    if not source or #source.rows<12 then return nil,"eink_source_invalid" end
    for _,body in ipairs(require("miuread.eink_comment_source").rendered_bodies(html)) do
        local rendered=stream(body)
        if rendered and rendered.text==source.text and #rendered.rows==#source.rows then return source,rendered end
    end
    return nil,"eink_progress_chapter_text_differs"
end

local function load_map(reader,record,uid,allow_fetch)
    local id,version,file=identity(record,uid)
    if not id then return nil,"eink_progress_format_unavailable" end
    local store=reader.store
    local raw=U.read_file(cache_path(store,id,uid,version),true)
    local fetched=not raw
    local limited
    if not raw and not allow_fetch then return nil,"source_cache_missing" end
    if not raw then
        local ok,kind,returned_version
        ok,raw,kind,returned_version,limited=pcall(reader.eink_comment_source,reader,id,uid)
        if not ok then return nil,raw end
        if kind~="html" or tonumber(returned_version)~=version then return nil,"eink_progress_book_version_changed" end
    end
    local html,err=require("miuread.epub_installer").read_chapter_text_by_uid(file,id,uid)
    if not html then return nil,err end
    local source,rendered=Source.align(raw,html)
    if not source then return nil,rendered end
    if fetched and not limited then Source.seed(store,id,uid,version,raw) end
    return {source=source,rendered=rendered,id=id,version=version,raw=raw}
end

function Source.has_cache(store,record,uid)
    local id,version=identity(record,uid)
    if not id then return nil end
    return U.file_exists(cache_path(store,id,uid,version))
end

function Source.prepare(reader,record,uid)
    local map,err=load_map(reader,record,uid,true)
    return map~=nil and Source.has_cache(reader.store,record,uid)==true,err
end

local function row_for_byte(rows,byte)
    local lo,hi=1,#rows
    while lo<=hi do
        local mid=math.floor((lo+hi)/2)
        if rows[mid].byte==byte then return mid end
        if rows[mid].byte<byte then lo=mid+1 else hi=mid-1 end
    end
end

function Source.annotation_alignment(reader,record,uid,version,allow_fetch)
    local map,err=load_map(reader,record,uid,allow_fetch~=false)
    if not map then return nil,err end
    if map.version~=version then return nil,"eink_book_version_changed" end
    return map
end

function Source.annotation_selection(map,quote,context_before,context_after)
    local text,rows=map.rendered.text,map.rendered.rows
    local needle,before,after=normalize(quote),normalize(context_before),normalize(context_after)
    if needle=="" then return nil,"eink_source_selection_missing" end
    local first,last
    local hit=text:find(needle,1,true)
    while hit do
        local stop=hit+#needle
        if (before=="" or (hit>#before and text:sub(hit-#before,hit-1)==before))
            and (after=="" or text:sub(stop,stop+#after-1)==after) then
            local a=row_for_byte(rows,hit)
            local following=stop<=#text and row_for_byte(rows,stop) or (stop==#text+1 and #rows+1)
            if a and following then
                if first then return nil,"eink_source_selection_ambiguous" end
                first,last=a,following-1
            end
        end
        hit=text:find(needle,hit+1,true)
    end
    if not first then return nil,"eink_source_selection_missing" end
    return first,last
end

function Source.find_local(map,anchor)
    local text,rows=map.rendered.text,map.rendered.rows
    local agreed,had_ambiguity
    for _,candidate in ipairs(anchor.anchor_candidates or {anchor}) do
        local quote=normalize(candidate.anchor_text)
        if #quote>=12 and not candidate.anchor_cross_chapter and not candidate.anchor_contains_chapter_title
            and (candidate.point_side=="start" or candidate.point_side=="end") then
            local before,after=normalize(candidate.context_before),normalize(candidate.context_after)
            local hit=text:find(quote,1,true)
            local only,ambiguous
            while hit do
                local stop=hit+#quote
                if (before=="" or text:sub(math.max(1,hit-#before),hit-1)==before)
                    and (after=="" or text:sub(stop,stop+#after-1)==after) then
                    local row=row_for_byte(rows,candidate.point_side=="end" and stop or hit)
                    if row then
                        if only and only~=row then ambiguous=true; break end
                        only=row
                    end
                end
                hit=text:find(quote,hit+1,true)
            end
            had_ambiguity=had_ambiguity or ambiguous
            if only and not ambiguous then
                if agreed and agreed~=only then return nil,"eink_progress_anchor_conflict" end
                agreed=only
            end
        end
    end
    if not agreed then return nil,had_ambiguity and "eink_progress_anchor_ambiguous" or "eink_progress_anchor_not_found" end
    return map.source.rows[agreed].first,agreed
end

function Source.local_position(reader,record,anchor,allow_fetch)
    local map,err=load_map(reader,record,anchor.chapter_uid,allow_fetch)
    if not map then return nil,err end
    if tonumber(anchor.book_version)~=map.version then return nil,"eink_progress_book_version_changed" end
    local co,index
    if anchor.at_chapter_start==true then co,index=0,1
    else co,index=Source.find_local(map,anchor) end
    if co==nil then return nil,index end
    local chapter_index=tonumber(anchor.chapter_index)
    if not chapter_index then return nil,"eink_progress_chapter_index_missing" end
    local ratio=(index-1)/#map.source.rows
    local percent=tonumber(anchor.display_progress)
    local total=tonumber(anchor.total_word_count)
    if total and total>0 and not anchor.catalog_pending then
        percent=100*((tonumber(anchor.words_before) or 0)+(tonumber(anchor.chapter_word_count) or 0)*ratio)/total
    end
    local render_row=map.rendered.rows[index]
    local summary=U.trim(table.concat(map.rendered.visible,"",render_row.visible,math.min(#map.rendered.visible,render_row.visible+38)))
    return {book_id=map.id,book_version=map.version,chapter_uid=tostring(anchor.chapter_uid),
        chapter_index=chapter_index,chapter_idx=chapter_index,offset=co,chapter_offset=co,canonical_offset=co,
        progress=percent,chapter_ratio=ratio,summary=summary,source="eink_epub_source",
        offset_basis="wr_data_co",position_basis="wr_data_co",native_offset=true,eink_coordinate=true,
        safe=true,precise=true,source_xpointer=anchor.xpointer}
end

local function first_row_after(rows,offset)
    local lo,hi=1,#rows
    while lo<=hi do
        local mid=math.floor((lo+hi)/2)
        if rows[mid].last<=offset then lo=mid+1 else hi=mid-1 end
    end
    return lo
end

function Source.annotation_range(map,range)
    local first,last,point=require("miuread.annotations.range").parse(range)
    if not first or first<1 or last-1>map.source.units or first%1~=0 or last%1~=0 then return nil end
    local rows=map.source.rows
    local start=first_row_after(rows,first-1)
    if not rows[start] then return nil end
    local stop=point and start+1 or first_row_after(rows,last-1)
    if stop<=start or (not point and rows[start].first>=last-1) then return nil end
    local text,rendered=map.rendered.text,map.rendered.rows
    return rendered[start].byte-1,rendered[stop] and rendered[stop].byte-1 or #text
end

function Source.remote_anchor(source,rendered,co)
    if not co or co<0 or co>source.units or co%1~=0 then return nil end
    local lo=first_row_after(source.rows,co)
    local rendered_start=rendered.rows[lo]
    if not rendered_start then return nil end
    local first=rendered_start.visible
    for _,width in ipairs({22,36,54}) do
        local query=U.trim(table.concat(rendered.visible,"",first,math.min(#rendered.visible,first+width-1)))
        local compact=normalize(query)
        local found=rendered.text:find(compact,1,true)
        if #compact>=12 and found==rendered_start.byte and not rendered.text:find(compact,found+1,true) then
            return query,(lo-1)/#rendered.rows
        end
    end
end

function Source.remote_position(reader,record,remote)
    local map,err=load_map(reader,record,remote.chapter_uid,true)
    if not map then return nil,err end
    if remote.version and tonumber(remote.version)~=map.version then return nil,"eink_progress_book_version_changed" end
    local co=tonumber(remote.offset or remote.chapter_offset)
    local resolved=U.copy(remote)
    if co==0 then
        resolved.eink_chapter_start,resolved.chapter_ratio=true,0
        return resolved
    end
    local query,ratio=Source.remote_anchor(map.source,map.rendered,co)
    if not query then return nil,"eink_progress_remote_anchor_unavailable" end
    resolved.search_anchor_text,resolved.chapter_ratio,resolved.eink_source_anchor=query,ratio,true
    return resolved
end

return Source
