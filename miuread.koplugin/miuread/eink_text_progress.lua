local U=require("miuread.util")
local Source=require("miuread.eink_progress_source")
local TextProgress={}
local CHAPTER_LIMIT=2*1024*1024

local function chapter(file,row)
    local offset,bytes=tonumber(row.text_offset),tonumber(row.text_bytes)
    if not offset or not bytes or offset<0 or bytes<1 or bytes>CHAPTER_LIMIT then return nil end
    if not file:seek("set",offset) then return nil end
    local text=file:read(bytes)
    if not text or #text~=bytes then return nil end
    return text
end

local function chapters(record)
    local row=record and record.record
    if type(row)~="table" or row.document_format~="txt" or row.translation_mode or row.annotation_requested
        or type(row.chapter_map)~="table" or #row.chapter_map==0 then return nil end
    return row.chapter_map
end

local function open_text(record)
    local file=io.open(record.path,"rb")
    if not file then return nil end
    local expected=tonumber(record.record.text_size or record.record.file_size)
    if expected and file:seek("end")~=expected then file:close(); return nil end
    return file
end

function TextProgress.local_position(record,anchor)
    local rows=chapters(record)
    local file=rows and open_text(record)
    if not file then return nil,"eink_txt_index_missing" end
    local total,before=0,0
    for _,row in ipairs(rows) do total=total+(tonumber(row.text_bytes) or 0) end
    local probes={}
    for _,candidate in ipairs(anchor.anchor_candidates or {anchor}) do
        local quote=Source.compact_text(candidate.anchor_text)
        if #quote>=12 then probes[#probes+1]=quote end
    end
    local found
    for _,row in ipairs(rows) do
        local raw=chapter(file,row)
        if not raw then file:close(); return nil,"eink_txt_index_invalid" end
        local compact=Source.compact_text(raw)
        local candidate_chapter=false
        for _,quote in ipairs(probes) do
            if compact:find(quote,1,true) then candidate_chapter=true; break end
        end
        if candidate_chapter then
            local map=Source.plain_text(raw)
            if not map then file:close(); return nil,"eink_txt_chapter_unavailable" end
            local offset,index=Source.find_local({source=map,rendered=map},anchor)
            if offset~=nil then
                if found then file:close(); return nil,"eink_txt_anchor_ambiguous" end
                local glyph=map.rows[index]
                local ratio=(index-1)/#map.rows
                local summary=U.trim(table.concat(map.visible,"",glyph.visible,math.min(#map.visible,glyph.visible+38)))
                local display=anchor.display_progress
                if record.record.complete==true and record.record.partial_range~=true and not record.record.chapter_uid then
                    display=(before+#raw*ratio)*100/math.max(1,total)
                end
                found={document_format="txt",book_id=tostring((record.book or {}).book_id or ""),book_version=0,
                    chapter_uid=tostring(row.uid),chapter_index=tonumber(row.index),chapter_idx=tonumber(row.index),
                    offset=offset,chapter_offset=offset,canonical_offset=offset,summary=summary,progress=display,
                    chapter_ratio=ratio,source="eink_txt_source",source_xpointer=anchor.xpointer,
                    offset_basis="wr_data_co",position_basis="wr_data_co",native_offset=true,eink_coordinate=true,
                    safe=true,precise=true}
            elseif index=="eink_progress_anchor_conflict" or index=="eink_progress_anchor_ambiguous" then
                file:close(); return nil,index
            end
        end
        before=before+#raw
    end
    file:close()
    if not found or not found.chapter_index then return nil,"eink_txt_anchor_not_found" end
    return found
end

function TextProgress.remote_position(record,remote)
    local rows=chapters(record)
    if not rows or (remote.version~=nil and tonumber(remote.version)~=0) then return nil end
    local co=tonumber(remote.offset or remote.chapter_offset)
    if co==nil then return nil end
    local file=open_text(record)
    if not file then return nil end
    local match
    for _,row in ipairs(rows) do
        if tostring(row.uid)==tostring(remote.chapter_uid) then
            local raw=chapter(file,row)
            local map=raw and Source.plain_text(raw)
            if map then
                local query=Source.remote_anchor(map,map,co)
                if query then
                    match=U.copy(remote)
                    match.search_anchor_text=query
                    match.eink_txt_anchor=true
                end
            end
            break
        end
    end
    file:close()
    return match
end

return TextProgress
