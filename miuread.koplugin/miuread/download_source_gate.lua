-- MiuRead 6.5.0-beta.10: download-time Web source readiness gate.
-- Runs inside the existing download worker, BEFORE EPUB packaging/installation.
-- This module is deliberately unrelated to progress POST, pending transaction,
-- ReadReport and ProgressFence. Never change reader position from here.
local U=require("miuread.util")
local Http=require("miuread.http")
local SourcePosition=require("miuread.source_position")
local logger=require("logger")

local Gate={}

local function local_coordinate_html(cache, chapter, entry)
    -- Use the actual chapter checkpoint, not an unrelated global cached uid.
    local path=type(entry)=="table" and tostring(entry.coord_file or "") or ""
    if path~="" then
        if path:sub(1,1)~="/" then path=cache.root.."/"..path end
        local value=U.read_file(path,true)
        if type(value)=="string" and value~="" then return value end
    end
    -- Some legacy chapters do not have coord.xhtml. Validate the final XHTML
    -- only as a fallback; never accept missing content as coordinate-ready.
    if type(chapter.body)=="string" and chapter.body~="" then return chapter.body end
    if type(chapter.body_path)=="string" and chapter.body_path~="" then
        return U.read_file(chapter.body_path,true)
    end
    return nil
end

function Gate.prepare(args)
    args=type(args)=="table" and args or {}
    local book=args.book or {}
    local chapters=args.chapters or {}
    local manifest=args.cache and args.cache.manifest or {}
    local records=type(manifest.chapters)=="table" and manifest.chapters or {}
    local reader=args.reader
    local cache=args.cache
    local version=tonumber(book.version) or 0
    local expected,verified=0,0
    for _,chapter in ipairs(chapters) do
        if chapter.structural~=true then expected=expected+1 end
    end
    if expected==0 then
        return nil,"no_readable_coordinate_chapters",{expected=0,verified=0}
    end

    for _,chapter in ipairs(chapters) do
        if chapter.structural~=true then
            local uid=tostring(chapter.uid or chapter.chapterUid or "")
            local entry=records[uid]
            if uid=="" or type(entry)~="table" or entry.complete~=true then
                return nil,"local_chapter_checkpoint_missing:"..uid,{expected=expected,verified=verified}
            end
            if type(args.checkpoint)=="function" then args.checkpoint("coordinate") end
            if type(args.progress)=="function" then
                args.progress("coordinate",verified,expected,chapter.title,{message=
                    "正在验证 Web 定位 · "..tostring(verified+1).."/"..tostring(expected),
                    activity="web_coordinate_verify",coordinate_verified=verified,
                    coordinate_total=expected})
            end
            local local_html=local_coordinate_html(cache,chapter,entry)
            if type(local_html)~="string" or local_html=="" then
                return nil,"local_coordinate_html_missing:"..uid,{expected=expected,verified=verified}
            end
            local web_html=SourcePosition.readExactChapter(reader,book.bookId,uid,version)
            local result,error_reason
            if web_html then result,error_reason=SourcePosition.validateDownloadChapter(local_html,web_html) end
            if not result then
                -- A prior cache file may contain an incomplete placeholder; do
                -- not trust it. Fetch exactly this chapter through Web Reader.
                if type(args.checkpoint)=="function" then args.checkpoint("coordinate_fetch") end
                local requested={uid=uid,chapterUid=uid,
                    chapterIdx=tonumber(chapter.index or entry.index) or 0,
                    title=tostring(chapter.title or entry.title or "")}
                local format=args.format=="txt" and "txt" or "epub"
                local ok,downloaded,_,_,state=pcall(reader.chapter,reader,book,requested,format,
                    {images=false,fresh_context=true,keepalive=true})
                if type(reader.cleanup_transient_images)=="function" then
                    pcall(reader.cleanup_transient_images,reader)
                end
                if not ok then
                    if Http.is_rate_limit_error(downloaded) or Http.is_auth_error(downloaded)
                        or Http.is_network_error(downloaded) then error(downloaded,0) end
                    return nil,"web_chapter_fetch_failed:"..uid..":"..tostring(downloaded),
                        {expected=expected,verified=verified}
                end
                if type(state)~="table" or state.coordinate_source_authoritative==false
                    or state.source_channel=="eink" then
                    return nil,"web_source_not_authoritative:"..uid,{expected=expected,verified=verified}
                end
                web_html=type(state)=="table" and tostring(state.coord_html or "") or ""
                if web_html=="" then web_html=tostring(downloaded or "") end
                result,error_reason=SourcePosition.validateDownloadChapter(local_html,web_html)
                if not result then
                    entry.source_verified=false
                    entry.source_verification_error=tostring(error_reason or "source_mismatch")
                    if type(args.save_checkpoint)=="function" then args.save_checkpoint() end
                    return nil,"web_source_validation_failed:"..uid..":"..tostring(error_reason),
                        {expected=expected,verified=verified}
                end
                local saved,save_err=SourcePosition.cacheChapter(reader,book.bookId,uid,version,web_html)
                if not saved then return nil,"web_source_cache_write_failed:"..uid..":"..tostring(save_err),
                    {expected=expected,verified=verified} end
            end
            -- A source_cache_done flag on its own is not proof. Mark only after
            -- both independent local and authoritative Web anchors were checked.
            entry.source_cache_done=true
            entry.source_cache_version=version
            entry.source_verified=true
            entry.source_verified_version=version
            entry.source_verification_error=nil
            entry.source_verification_anchors=result.anchors
            if type(args.save_checkpoint)=="function" then args.save_checkpoint() end
            verified=verified+1
            logger.info("[MiuRead][WebCoordinateGate] chapter verified",
                "book=",tostring(book.bookId),"uid=",uid,
                "verified=",tostring(verified),"expected=",tostring(expected),
                "anchors=",tostring(result.anchors))
            -- Do not keep 500 large chapter maps and HTML strings in memory.
            web_html,local_html,result=nil,nil,nil
            if verified%6==0 then collectgarbage("collect") end
        end
    end
    if type(args.progress)=="function" then
        args.progress("coordinate",expected,expected,book.title,{message="Web 定位全部验证完成",
            activity="web_coordinate_complete",coordinate_verified=expected,coordinate_total=expected})
    end
    return {complete=true,expected=expected,verified=verified,version=version}
end

return Gate
