local AnnotationCoord = require("miuread.annotation_coord")
local PublicDB = require("miuread.public_annotation_database")
local SourcePosition = require("miuread.source_position")
local Thoughts = require("miuread.thoughts")
local U = require("miuread.util")

local Service = {}
Service.__index = Service

local function scalar(value)
    local kind=type(value)
    if kind=="string" or kind=="number" or kind=="boolean" then return tostring(value) end
    return ""
end

local function range_key(row)
    if type(row)~="table" then return "" end
    return scalar(row.range or row.markRange or row.bookmarkRange)
end

local function server_text(row)
    if type(row)~="table" then return "" end
    return U.trim(scalar(row.markText or row.abstract or row.contextAbstract or row.text))
end

local function merge_groups(previous,current)
    local order,by_range={},{}
    local function put(group)
        if type(group)~="table" then return end
        local range=tostring(group.range or "")
        if range=="" then return end
        if by_range[range]==nil then order[#order+1]=range end
        by_range[range]=group
    end
    for _,group in ipairs(type(previous)=="table" and previous or {}) do put(group) end
    for _,group in ipairs(type(current)=="table" and current or {}) do put(group) end
    local out={}
    for _,range in ipairs(order) do out[#out+1]=by_range[range] end
    return out
end

function Service:new(annotations, reader, store)
    return setmetatable({annotations=annotations,reader=reader,store=store},self)
end

function Service:_source(book_id,chapter_uid,book_version,scope,allow_fetch)
    local source,cache_hit,err=SourcePosition.chapterSource(self.reader,book_id,chapter_uid,book_version,{
        cache_only=allow_fetch~=true,
        chapter_index=scope and scope.chapter_index,
        chapter_title=scope and scope.chapter_title,
        book_title=scope and scope.book_title,
        book_author=scope and scope.book_author,
    })
    return source,cache_hit,err
end

function Service:_build_marks(result,coord_html)
    local map
    if tostring(coord_html or "")~="" then
        local ok,value=pcall(AnnotationCoord.build,coord_html)
        if ok and type(value)=="table" then map=value end
    end
    local completed={}
    for _,key in ipairs(type(result.completed_ranges)=="table" and result.completed_ranges or {}) do
        completed[tostring(key or "")]=true
    end
    local marks={}
    for index,row in ipairs(type(result.underlines)=="table" and result.underlines or {}) do
        local key=range_key(row)
        if key~="" then
            local source_text,before,after,locate_state="","","","source_missing"
            if map then
                local resolved,err=AnnotationCoord.resolveRangeOnMap(map,key)
                if resolved and resolved.point~=true and U.trim(tostring(resolved.text or ""))~="" then
                    source_text=tostring(resolved.text or "")
                    before,after=AnnotationCoord.contextForSpan(map,resolved.text_start,resolved.text_end_pos,32)
                    locate_state="ready"
                else
                    locate_state=tostring(err or (resolved and "point_range") or "range_unresolved")
                end
            end
            local reviews=type(result.review_map)=="table" and result.review_map[key] or nil
            local thought_state
            if type(reviews)=="table" and #reviews>0 then thought_state=1
            elseif result.review_complete==true or completed[key] then thought_state=0
            else thought_state=-1 end
            marks[#marks+1]={
                range=key,ordinal=index,source_text=source_text,
                context_before=before,context_after=after,server_text=server_text(row),
                thought_state=thought_state,locate_state=locate_state,
            }
        end
    end
    return marks
end

function Service:fetch_chapter(scope,options)
    options=type(options)=="table" and options or {}
    scope=type(scope)=="table" and scope or {}
    local book_id=tostring(scope.book_id or "")
    local chapter_uid=tostring(scope.chapter_uid or "")
    if book_id=="" or chapter_uid=="" then return nil,"scope_missing" end
    local version=tonumber(scope.book_version) or 0
    local previous_marks,previous_meta=PublicDB.load_chapter(self.store,book_id,chapter_uid)
    previous_marks=type(previous_marks)=="table" and previous_marks or {}
    previous_meta=type(previous_meta)=="table" and previous_meta or {known=false}

    local result=self.annotations:fetch_chapter(book_id,chapter_uid,nil,{force_refresh=options.force_refresh==true})
    if type(result)~="table" then
        PublicDB.set_status(self.store,book_id,chapter_uid,"error","invalid_result",previous_meta.known==true)
        return nil,"invalid_result"
    end
    if result.underline_request_ok~=true then
        local kind=tostring(result.error_kind or "server")
        PublicDB.set_status(self.store,book_id,chapter_uid,"error",kind,previous_meta.known==true)
        return nil,kind,result
    end

    local coord_html,_,coord_error=self:_source(book_id,chapter_uid,version,scope,options.allow_source_fetch==true)
    local marks=self:_build_marks(result,coord_html)
    local replace=result.underlines_partial~=true
    local saved,save_error=PublicDB.save_chapter(self.store,book_id,chapter_uid,marks,{
        underline_count=tonumber(result.underline_count) or #marks,
        thought_count=tonumber(result.thought_count) or 0,
        reviews_complete=result.review_complete==true,
        status=result.complete==true and "ready" or "partial",
        error_kind=tostring(result.error_kind or coord_error or ""),
        book_version=version,updated_at=os.time(),
    },replace)
    if not saved then return nil,tostring(save_error or "public_cache_save_failed"),result end

    local groups=type(result.review_groups)=="table" and result.review_groups or {}
    if result.complete~=true then
        local old=select(1,Thoughts.load(self.store,book_id,chapter_uid))
        groups=merge_groups(old,groups)
    end
    local thought_saved,thought_detail=Thoughts.save(self.store,book_id,chapter_uid,groups)
    if thought_saved==nil then return nil,tostring(thought_detail or "thought_cache_save_failed"),result end

    return {
        book_id=book_id,chapter_uid=chapter_uid,marks=#marks,
        underlines=tonumber(result.underline_count) or #marks,
        thoughts=tonumber(result.thought_count) or 0,
        comments=tonumber(result.thought_entry_count) or 0,
        complete=result.complete==true,reviews_complete=result.review_complete==true,
        coord_ready=coord_html~=nil,coord_error=coord_error,
    }
end

function Service:chapter(scope)
    scope=type(scope)=="table" and scope or {}
    return PublicDB.load_chapter(self.store,tostring(scope.book_id or ""),tostring(scope.chapter_uid or ""))
end

return Service
