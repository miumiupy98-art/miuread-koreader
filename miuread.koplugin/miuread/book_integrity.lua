local Digests=require("miuread.digests")
local EpubInstaller=require("miuread.epub_installer")
local DownloadDatabase=require("miuread.download_database")
local DownloadResult=require("miuread.download_result")
local U=require("miuread.util")

local M={}

local function uid(chapter)
    return tostring(chapter and (chapter.uid or chapter.chapterUid or chapter.chapter_uid) or "")
end

local function idx(chapter,fallback)
    return tonumber(chapter and (chapter.index or chapter.chapterIdx or chapter.chapter_index or chapter.chapter_idx))
        or tonumber(fallback or 0) or 0
end

local function words(chapter)
    return math.max(0,tonumber(chapter and (chapter.word_count or chapter.wordCount) or 0) or 0)
end

local function structural(chapter)
    return chapter and chapter.structural==true
end

local function map_signature(map)
    local out={}
    for index,chapter in ipairs(type(map)=="table" and map or {}) do
        out[#out+1]=table.concat({
            uid(chapter),
            tostring(idx(chapter,index)),
            tostring(words(chapter)),
            structural(chapter) and "1" or "0",
        },":")
    end
    return table.concat(out,"|")
end

function M.core_map_hash(book_id,full_map,local_map)
    local full=map_signature(full_map)
    local local_sig=map_signature(local_map)
    if full=="" and local_sig=="" then return "" end
    return Digests.sha256(table.concat({
        "miuread-core-map-v1",
        tostring(book_id or ""),
        full,
        local_sig,
    },"\n"))
end

function M.record_hash(book,record)
    if type(record)=="table" and tostring(record.core_map_hash or "")~="" then
        return tostring(record.core_map_hash)
    end
    local book_id=tostring((book and (book.book_id or book.bookId)) or (record and record.book_id) or "")
    local full_map=type(book)=="table" and book.catalog or nil
    local local_map=type(record)=="table" and record.chapter_map or nil
    return M.core_map_hash(book_id,full_map,local_map)
end

function M.maps_equivalent(a,b)
    return map_signature(a)==map_signature(b) and map_signature(a)~=""
end

local function local_chapter_position(local_map,ratio)
    local_map=type(local_map)=="table" and local_map or {}
    ratio=U.clamp(tonumber(ratio) or 0,0,1)
    if #local_map==0 then return nil,"local_map_empty" end
    local total=0
    for _,chapter in ipairs(local_map) do
        if not structural(chapter) then total=total+words(chapter) end
    end
    if total<=0 then return nil,"local_word_counts_missing" end
    local target=ratio*total
    local before=0
    for index,chapter in ipairs(local_map) do
        if not structural(chapter) then
            local chapter_words=words(chapter)
            if chapter_words>0 and (target<=before+chapter_words or index==#local_map) then
                local offset=math.max(0,math.min(chapter_words,math.floor(target-before+.5)))
                return {
                    chapter=chapter,
                    chapter_uid=uid(chapter),
                    chapter_index=idx(chapter,index),
                    chapter_word_count=chapter_words,
                    offset=offset,
                    within=chapter_words>0 and U.clamp(offset/chapter_words,0,1) or 0,
                    local_total_word_count=total,
                }
            end
            before=before+chapter_words
        end
    end
    return nil,"local_chapter_not_found"
end

function M.position_from_maps(local_map,full_map,ratio,fallback)
    fallback=type(fallback)=="table" and fallback or {}
    local local_position,local_error=local_chapter_position(local_map,ratio)
    if not local_position then return nil,local_error end

    full_map=type(full_map)=="table" and full_map or {}
    if #full_map==0 then
        if M.maps_equivalent(local_map,full_map) then return nil,"full_map_empty" end
        return nil,"full_catalog_missing"
    end

    local wanted=local_position.chapter_uid
    if wanted=="" then return nil,"local_chapter_uid_missing" end
    local selected=nil
    local before,total=0,0
    for index,chapter in ipairs(full_map) do
        if not structural(chapter) then
            local chapter_words=words(chapter)
            if not selected and uid(chapter)==wanted then
                selected={chapter=chapter,index=index,before=before,words=chapter_words}
            end
            total=total+chapter_words
            if not selected then before=before+chapter_words end
        end
    end
    if not selected then return nil,"current_chapter_not_in_full_catalog" end
    if total<=0 then return nil,"full_catalog_word_counts_missing" end
    if selected.words<=0 then return nil,"current_chapter_word_count_missing" end

    local global_offset=math.max(0,math.min(selected.words,
        math.floor(local_position.within*selected.words+.5)))
    local progress=U.clamp(((selected.before+global_offset)/total)*100,0,100)
    return {
        progress=progress,
        chapter_uid=uid(selected.chapter),
        chapter_index=idx(selected.chapter,selected.index),
        offset=global_offset,
        chapter_offset=global_offset,
        chapter_word_count=selected.words,
        total_word_count=total,
        words_before=selected.before,
        chapter_percent=math.floor(local_position.within*100+.5),
        summary=selected.chapter.title or fallback.summary or "",
        safe=true,
        source=M.maps_equivalent(local_map,full_map) and "full_epub_catalog" or "local_to_full_catalog",
    }
end


local function partial_options(manifest)
    manifest=type(manifest)=="table" and manifest or {}
    if type(manifest.repair_options)=="table" then
        local options=U.copy(manifest.repair_options)
        options.annotations=options.annotations==true
        if options.images==nil then options.images=true end
        return options
    end
    local key=tostring(manifest.option_key or "")
    local options={
        annotations=key:match("^notes%-")~=nil,
        images=key:find("%-no%-images%-",1,false)==nil,
    }
    local entries={}
    for _,entry in pairs(type(manifest.chapters)=="table" and manifest.chapters or {}) do
        if type(entry)=="table" then entries[#entries+1]=entry end
    end
    table.sort(entries,function(a,b) return idx(a,0)<idx(b,0) end)
    if key:find("%-range$",1,false) then
        if #entries==0 then return nil,"章节范围断点缺少章节信息" end
        options.range_start_index=idx(entries[1],1)
        options.range_end_index=idx(entries[#entries],#entries)
        options.range_start_title=entries[1].title
        options.range_end_title=entries[#entries].title
    elseif key:find("%-chapter%-",1,false) then
        if #entries~=1 or uid(entries[1])=="" then return nil,"单章断点缺少章节信息" end
        options.chapter_uid=uid(entries[1])
    end
    return options
end

local function partial_record(book,manifest,options)
    if type(book)~="table" then return nil end
    local key=tostring((manifest or {}).option_key or "")
    local kind=key:match("^notes%-") and "notes" or "clean"
    if options and options.chapter_uid then
        local row=book.chapters and book.chapters[tostring(options.chapter_uid)]
        return type(row)=="table" and row[kind] or nil
    end
    if key:find("%-range$",1,false) then
        return book.variants and book.variants["range_"..kind] or nil
    end
    return book.variants and book.variants[kind] or nil
end

local function partial_manifest_pending(manifest, has_record)
    if type(manifest)~="table" then return false end
    if manifest.final_repair_required==true then return true end
    if DownloadResult.annotation_pending(manifest) then return true end
    for _,entry in pairs(type(manifest.chapters)=="table" and manifest.chapters or {}) do
        if type(entry)=="table" and (entry.complete~=true or tostring(entry.error or "")~="") then return true end
    end
    -- A fully checkpointed cache without a generated record means the chapter
    -- work completed but the final build/install did not. Keep it repairable.
    return not has_record
end

function M.partial_repairs(store,book_id)
    book_id=tostring(book_id or "")
    local book=book_id~="" and store:book(book_id) or nil
    local out={}
    for _,root in ipairs(store:partial_cache_paths(book_id)) do
        local manifest=DownloadDatabase.load_manifest(root)
        if type(manifest)=="table" then
            local key=tostring(manifest.option_key or "")
            local kind=key:match("^notes%-") and "notes" or "clean"
            local options,option_error=partial_options(manifest)
            local record=partial_record(book,manifest,options)
            if partial_manifest_pending(manifest,type(record)=="table" and record.file and U.file_exists(record.file)) then
                local complete,failed,total=0,0,0
                for _,entry in pairs(type(manifest.chapters)=="table" and manifest.chapters or {}) do
                    if type(entry)=="table" then
                        total=total+1
                        if entry.complete==true and tostring(entry.error or "")=="" then complete=complete+1 else failed=failed+1 end
                    end
                end
                out[#out+1]={
                    root=root,manifest=manifest,options=options,option_error=option_error,
                    kind=kind,label=(kind=="notes" and "划线与想法版" or "纯净版").." · 未完成缓存",
                    complete=complete,failed=failed,total=total,updated_at=tonumber(manifest.updated_at or 0) or 0,
                }
            end
        end
    end
    table.sort(out,function(a,b) return a.updated_at>b.updated_at end)
    return out
end

function M.inspect(store,book_id,record)
    book_id=tostring(book_id or (record and record.book_id) or "")
    local book=book_id~="" and store:book(book_id) or nil
    local out={
        book_id=book_id,
        file_ok=false,
        core_map_valid=false,
        annotation_pending=DownloadResult.annotation_pending(record),
        annotation_unresolved=DownloadResult.annotation_unresolved(record),
        annotation_error_kind=type(record)=="table" and record.annotation_error_kind or nil,
        repair_kind="none",
    }
    if type(record)~="table" then
        local partials=M.partial_repairs(store,book_id)
        if #partials>0 then
            out.repair_kind="partial"
            out.partial_repairs=partials
            out.error="存在可继续修复的未完成下载缓存"
        else
            out.repair_kind="missing_record"
            out.error="没有找到已下载记录"
        end
        return out
    end
    local file=tostring(record.file or "")
    if file=="" or not U.file_exists(file) then
        out.repair_kind="content"
        out.error="已下载文件不存在"
        return out
    end
    local meta,inspect_error=EpubInstaller.inspect(file)
    if not meta then
        out.repair_kind="content"
        out.error=tostring(inspect_error or "EPUB 完整性检查失败")
        return out
    end
    out.file_ok=true
    out.meta=meta
    if tostring(meta.book_id or meta.bookId or "")~="" and tostring(meta.book_id or meta.bookId)~=book_id then
        out.repair_kind="content"
        out.error="EPUB 书籍身份与下载记录不一致"
        return out
    end
    local local_map=record.chapter_map or meta.chapters or {}
    local full_map=type(book)=="table" and book.catalog or {}
    local hash=M.core_map_hash(book_id,full_map,local_map)
    out.core_map_hash=hash
    out.core_map_valid=hash~="" and #local_map>0 and #full_map>0
    out.annotation_pending=out.annotation_pending or DownloadResult.annotation_pending(meta)
    out.annotation_unresolved=out.annotation_unresolved or DownloadResult.annotation_unresolved(meta)
    if out.annotation_pending then
        out.repair_kind="annotations"
    elseif not out.core_map_valid then
        out.repair_kind="content"
        out.error="章节映射不完整"
    else
        out.repair_kind="none"
    end
    return out
end

function M.repair_options(record)
    record=type(record)=="table" and record or {}
    local variant=tostring(record.variant or "")
    local base=tostring(record.base_variant or "")
    local annotations=base=="notes" or variant=="notes" or variant=="range_notes"
    local opt={
        annotations=annotations,
        repair_only=true,
        repair_source="book_integrity",
        range_start_index=record.range_start_index,
        range_end_index=record.range_end_index,
        range_start_title=record.range_start_title,
        range_end_title=record.range_end_title,
    }
    if record.chapter_uid~=nil and tostring(record.chapter_uid)~="" then
        opt.chapter_uid=tostring(record.chapter_uid)
    end
    return opt
end

return M
