local logger = require("logger")
local U = require("miuread.util")
local Http = require("miuread.http")
local Range = require("miuread.annotations.range")
local LocalDB = require("miuread.local_annotation_database")
local ThoughtDatabase = require("miuread.thought_database")
local Json = require("miuread.json")
local bit = require("bit")

local AnnotationSync = {}
AnnotationSync.__index = AnnotationSync

local COORD_VERSION = 3
local COORD_SOURCE = "raw_xhtml"

local function scalar(value)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then return tostring(value) end
    return ""
end

-- `plain` marks text from a raw TXT chapter, where ideographic spaces are
-- paragraph indentation rather than content.
local PROTECTED_SYNC_STATES = {
    unknown=true, delete_pending=true, delete_unknown=true, synced=true,
}

local function effective_sync_kind(row)
    if type(row) ~= "table" then return nil end
    local persisted = tostring(row.sync_kind or "")
    if persisted == "bookmark" or persisted == "highlight" or persisted == "thought" then
        return persisted
    end
    if tostring(row.remote_id or "") ~= "" or PROTECTED_SYNC_STATES[tostring(row.sync_state or "")] then
        return tostring(row.kind or "")
    end

    local pos0 = tostring(row.pos0 or "")
    local pos1 = tostring(row.pos1 or "")
    local has_range_signal = U.trim(tostring(row.drawer or "")) ~= ""
        or (pos0 ~= "" and pos1 ~= "" and pos0 ~= pos1)
    local selected = U.trim(tostring(row.selected_text or row.text or ""))
    if has_range_signal and selected ~= "" then
        if U.trim(tostring(row.note or "")) ~= "" then return "thought" end
        return "highlight"
    end
    return tostring(row.kind or "")
end

local function collect_records(value, out, seen, depth)
    out = out or {}
    seen = seen or {}
    depth = depth or 0
    if type(value) ~= "table" or seen[value] or depth > 7 then return out end
    seen[value] = true
    local has_identity = scalar(value.bookmarkId) ~= "" or scalar(value.reviewId) ~= ""
        or scalar(value.range or value.markRange or value.bookmarkRange) ~= ""
    if has_identity then out[#out + 1] = value end
    for _, child in pairs(value) do
        if type(child) == "table" then collect_records(child, out, seen, depth + 1) end
    end
    return out
end

local function record_range(row)
    return scalar(row and (row.range or row.markRange or row.bookmarkRange))
end

local function bookmark_remote_id(row)
    return scalar(row and (row.bookmarkId or row.bookMarkId or row.bookmarkID or row.id))
end

local function review_remote_id(row)
    return scalar(row and (row.reviewId or row.reviewID or row.id))
end

local function matches_chapter(row,uid)
    return tostring(uid or "")~=""
        and tostring(row.chapterUid or row.chapterId or row.chapter_uid or "")==tostring(uid)
end

local function find_bookmark_match(records, range_key, expected_type, remote_id, uid)
    range_key = tostring(range_key or "")
    remote_id = tostring(remote_id or "")
    for _, row in ipairs(records or {}) do
        local rid = bookmark_remote_id(row)
        if remote_id~="" and rid==remote_id then return row,rid end
        if remote_id=="" and rid~="" and matches_chapter(row,uid) and range_key~="" and record_range(row)==range_key
            and tonumber(row.type or row.bookmarkType or row.markType)==tonumber(expected_type) then
            return row,rid
        end
    end
end

local function find_review_match(records, range_key, content, remote_id, uid)
    range_key = tostring(range_key or "")
    remote_id = tostring(remote_id or "")
    local clean_content = U.trim(tostring(content or ""))
    for _, row in ipairs(records or {}) do
        local rid = review_remote_id(row)
        if remote_id~="" and rid==remote_id then return row,rid end
        if remote_id=="" and rid~="" and matches_chapter(row,uid) and range_key~="" and record_range(row)==range_key then
            local actual=U.trim(tostring(row.content or row.text or ""))
            if clean_content~="" and actual==clean_content then return row,rid end
        end
    end
end

local function find_number(value, keys, seen, depth)
    if type(value) ~= "table" or (depth or 0) > 6 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    for _, key in ipairs(keys) do
        local n = tonumber(value[key])
        if n then return n end
    end
    for _, child in pairs(value) do
        if type(child) == "table" then
            local n = find_number(child, keys, seen, (depth or 0) + 1)
            if n then return n end
        end
    end
end

local function positive_version(value)
    local n = tonumber(value)
    if n and n > 0 then return n end
end

local function find_book_version(value, book_id, seen, depth)
    if type(value) ~= "table" or (depth or 0) > 8 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local target = tostring(book_id or "")

    local id = tostring(value.bookId or value.book_id or "")
    if id ~= "" and id == target then
        local version = positive_version(value.bookVersion or value.book_version or value.version)
        if version then return version end
    end
    for _, key in ipairs({"bookInfo", "book"}) do
        local child = value[key]
        if type(child) == "table" then
            local child_id = tostring(child.bookId or child.book_id or target)
            if child_id == target then
                local version = positive_version(child.bookVersion or child.book_version or child.version)
                if version then return version end
            end
        end
    end
    for _, child in pairs(value) do
        if type(child) == "table" then
            local version = find_book_version(child, book_id, seen, (depth or 0) + 1)
            if version then return version end
        end
    end
end

local function find_id(value, keys, seen, depth)
    if type(value) ~= "table" or (depth or 0) > 6 then return "" end
    seen = seen or {}
    if seen[value] then return "" end
    seen[value] = true
    for _, key in ipairs(keys) do
        local v = scalar(value[key])
        if v ~= "" then return v end
    end
    for _, child in pairs(value) do
        if type(child) == "table" then
            local v = find_id(child, keys, seen, (depth or 0) + 1)
            if v ~= "" then return v end
        end
    end
    return ""
end

local function stage_log(row, stage, ok, detail)
    logger.info("[MiuRead][AnnotationSync]",
        "kind=", tostring(row and row.kind or ""),
        "local=", tostring(row and row.local_id or ""),
        "stage=", tostring(stage or ""),
        "ok=", ok and "true" or "false",
        detail and ("detail=" .. tostring(detail)) or "")
end

function AnnotationSync:_verify_coordinate_basis(_,chapter_ctx)
    local source=chapter_ctx and chapter_ctx.coord_source
    if source=="eink_chapter_search" or source=="eink_chapter_review_range" then
        return {status="official_verified",checked=1,matched=1,exact=1}
    end
    return {status="mismatch",error="eink_coordinate_basis_missing"}
end

function AnnotationSync:new(api, reader, store)
    if api and type(api.for_channel)=="function" then api=api:for_channel("eink") end
    return setmetatable({api=api, reader=reader, store=store}, self)
end

function AnnotationSync:_book_version(book_id, book, record, chapter_uid_value)
    local target = tostring(book_id or "")
    for _, pair in ipairs({{"record", record}, {"book", book}}) do
        local source = pair[2]
        if type(source) == "table" then
            local n = find_book_version(source, target)
                or positive_version(source.bookVersion or source.book_version or source.version)
            if n then return n, pair[1] end
        end
    end

    if self.store and type(self.store.book) == "function" then
        local ok, stored = pcall(self.store.book, self.store, target)
        if ok and type(stored) == "table" then
            local n = find_book_version(stored, target)
                or positive_version(stored.bookVersion or stored.book_version or stored.version)
            if n then return n, "store" end
        end
    end

    local ok, info = pcall(self.api.book, self.api, target)
    if ok and type(info) == "table" then
        local n = find_book_version(info, target)
        if n then return n, "book_info" end
    end

    if self.reader and type(self.reader.catalog) == "function" then
        local catalog_ok, catalog = pcall(self.reader.catalog, self.reader, target)
        if catalog_ok and type(catalog) == "table" then
            local n = find_book_version(catalog, target)
            if n then return n, "catalog" end
        end
    end
    return nil, "missing"
end

local function coordinate_acceptance(located, verification)
    verification = type(verification) == "table" and verification or {}
    if tostring(verification.status or "") == "mismatch" then
        return false, "mismatch", tostring(verification.error or "coord_basis_mismatch")
    end
    if tostring(located and located.local_confidence or "") == "strong" then
        if tostring(verification.status or "") == "official_verified" then
            return true, "official_verified"
        end
        return true, "local_verified"
    end
    if tostring(verification.status or "") == "official_verified" then
        return true, "official_verified"
    end
    return false, "inconclusive",
        tostring(verification.note or "coordinate_evidence_inconclusive")
end

function AnnotationSync:_locate_with_chapter_candidates(book, record, row, cache)
    if cache.eink then
        local native=cache.eink
        local book_id=tostring(book.book_id or book.bookId or row.book_id or "")
        local uid=tostring(row.chapter_uid or "")
        local quote=U.trim(tostring(row.selected_text or ""))
        if quote=="" then quote=U.trim(tostring(row.text or "")) end
        if uid=="" or book_id=="" then return nil,nil,"chapter_metadata_missing","chapter" end
        if not cache.book then
            local ok,value=pcall(native.book,native,book_id)
            if not ok then return nil,nil,tostring(value),"chapter" end
            cache.book=value
        end
        local plain=tostring(cache.book.format):lower()=="txt"
        local version=plain and 0 or positive_version(cache.book.version or cache.book.bookVersion)
        local saved_version=tonumber(row.book_version or record.book_version or book.version)
        if version==nil or (saved_version and saved_version>0 and saved_version~=version) then
            return nil,nil,"eink_book_version_changed","chapter"
        end
        local coordinates=require("miuread.eink_coordinates")
        local ok,first,last=pcall(coordinates.lookup,native,book_id,uid,quote)
        local coord_source="eink_chapter_search"
        if ok and first==nil and not plain and row.kind~="bookmark"
            and (last=="eink_search_not_unique" or last=="eink_search_quote_unavailable"
                or last=="eink_search_quote_mismatch") then
            local source_record={book={book_id=book_id},record=record,path=row.source_path}
            cache.review_groups=cache.review_groups or {}
            if not cache.review_groups[uid] then
                cache.review_groups[uid]=ThoughtDatabase.load_chapter(self.store,book_id,uid) or {}
            end
            ok,first,last,coord_source=pcall(coordinates.annotation_range,native,self.reader,
                book_id,uid,version,source_record,row,quote,cache.review_groups[uid])
        end
        if not ok then return nil,nil,tostring(first),"locate" end
        if first==nil then return nil,nil,last,"locate" end
        local range=row.kind=="bookmark" and tostring(first) or (tostring(first).."-"..tostring(last))
        local ctx={chapter_uid=uid,chapter_idx=tonumber(row.chapter_idx),book_version=version,
            book_version_source="eink_book_info",coord_source=coord_source,plain_text=plain}
        return {range=range,mark_text=quote,local_confidence="strong"},ctx
    end
    return nil,nil,"eink_client_unavailable","chapter"
end

function AnnotationSync:_visibility_fields(mode)
    mode = tostring(mode or "private")
    if mode == "public" then return {} end
    if mode == "friendship" then return {friendship=1} end
    if mode == "friends_hidden" then return {notVisibleToFriends=1} end
    if mode == "one_book" then return {onlyVisibleToOneBook=1} end
    return {isPrivate=1}
end

function AnnotationSync:_bookmark_payload(row, located, version, prefs)
    local is_bookmark = row.kind == "bookmark"
    local chapter_uid = tonumber(row.chapter_uid) or tostring(row.chapter_uid or "")
    local payload = {
        bookId=tostring(row.book_id or ""),
        -- chapterInfos/currentChapter uses a numeric chapterUid in the Web reader.
        -- Preserve a non-numeric fallback only for unusual content variants.
        chapterUid=chapter_uid,
        chapterIdx=tonumber(row.chapter_idx) or 0,
        bookVersion=tonumber(version) or 0,
        type=is_bookmark and 0 or 1,
        style=is_bookmark and 0 or tonumber(prefs.highlight_style) or 1,
        range=tostring(located.range or ""),
        -- WeRead Web passes the selected UTF-8 text verbatim into ADD_BOOKMARK.
        markText=tostring(located.mark_text or ""),
    }
    -- The Web corner-bookmark request has no colorStyle field. Highlight
    -- requests do, and their default is color 0 with underline style 1.
    if not is_bookmark then payload.colorStyle=tonumber(prefs.highlight_color) or 0 end
    return payload
end

function AnnotationSync:_review_payload(row, located, version, prefs)
    local payload = {
        type=1,
        bookId=tostring(row.book_id or ""),
        chapterUid=tostring(row.chapter_uid or ""),
        chapterIdx=tonumber(row.chapter_idx) or 0,
        bookVersion=tonumber(version) or 0,
        range=tostring(located.range or ""),
        abstract=tostring(located.mark_text or ""),
        content=tostring(row.note or ""),
    }
    for key, value in pairs(self:_visibility_fields(prefs.review_visibility)) do payload[key] = value end
    return payload
end

local function validate_payload(row, payload, plain_text)
    if tostring(payload.bookId or "") == "" then return nil, "bookId_missing" end
    if tostring(payload.chapterUid or "") == "" then return nil, "chapterUid_missing" end
    if tostring(payload.range or "") == "" then return nil, "range_missing" end
    local start, ending, point = Range.parse(tostring(payload.range))
    if not start or not ending then return nil, "range_invalid" end
    if row.kind == "bookmark" then
        if not positive_version(payload.bookVersion) and not (plain_text == true and tonumber(payload.bookVersion) == 0) then return nil, "bookVersion_missing" end
        if not point then return nil, "bookmark_range_not_point" end
        if tonumber(payload.type) ~= 0 then return nil, "bookmark_type_invalid" end
        if tostring(payload.markText or "") == "" then return nil, "bookmark_markText_missing" end
    elseif row.kind == "highlight" then
        if not positive_version(payload.bookVersion) and not (plain_text == true and tonumber(payload.bookVersion) == 0) then return nil, "bookVersion_missing" end
        if point then return nil, "highlight_range_is_point" end
        if tonumber(payload.type) ~= 1 then return nil, "highlight_type_invalid" end
        if tostring(payload.markText or "") == "" then return nil, "highlight_markText_missing" end
    elseif row.kind == "thought" then
        if point then return nil, "review_range_is_point" end
        if U.trim(tostring(payload.abstract or "")) == "" then return nil, "review_abstract_missing" end
        if U.trim(tostring(payload.content or "")) == "" then return nil, "review_content_missing" end
    else
        return nil, "annotation_kind_invalid"
    end
    return true
end

local function native_payload(payload,review)
    if review then
        payload.chapterUid=tonumber(payload.chapterUid) or payload.chapterUid
        payload.abs,payload.contextAbstract=payload.abstract,payload.abstract
        payload.isPrivate=payload.isPrivate or 0
        payload.friendship=payload.friendship or 0
        payload.notVisibleToFriends=payload.notVisibleToFriends or 0
        payload.abstract,payload.chapterIdx=nil,nil
    else
        payload.chapterIdx,payload.colorStyle=nil,nil
    end
    return payload
end

local function auth_like_error(value)
    local text = tostring(value or "")
    local lower = text:lower()
    return text:find("鉴权", 1, true) ~= nil
        or text:find("登录", 1, true) ~= nil
        or lower:find("unauthorized", 1, true) ~= nil
        or lower:find("login", 1, true) ~= nil
        or lower:find("auth", 1, true) ~= nil
        or lower:find("-2012", 1, true) ~= nil
end

local function retryable_post_error(value)
    if Http.is_network_error(value) or Http.is_rate_limit_error(value) or Http.is_auth_error(value) then return true end
    local lower=tostring(value or ""):lower()
    return lower:find("http 408",1,true)~=nil
        or lower:find("http 425",1,true)~=nil
        or lower:find("http 500",1,true)~=nil
        or lower:find("http 502",1,true)~=nil
        or lower:find("http 503",1,true)~=nil
        or lower:find("http 504",1,true)~=nil
        or lower:find("temporarily unavailable",1,true)~=nil
end

local function annotation_sync_key(value)
    if type(value)=="number" then
        if value<0 or value>9007199254740991 or value%1~=0 then return nil end
        value=string.format("%.0f",value)
    end
    if type(value)~="string" or not value:match("^%d+$") then return nil end
    local key=value:gsub("^0+","")
    return key~="" and key or "0"
end

local function annotation_flag(value)
    if value==nil or Json.is_null(value) then return false end
    if value==true or value==1 or value=="1" or value=="true" then return true end
    if value==false or value==0 or value=="0" or value=="false" then return false end
end

local function fetch_cloud_annotations(api,book_id,is_review)
    local method=is_review and api.review_list_mine or api.bookmark_list
    local id_of=is_review and review_remote_id or bookmark_remote_id
    local primary=is_review and "reviews" or "data"
    local label=is_review and "想法" or "书签"
    local invalid="E-Ink "..label.."列表尚未完整读取"
    local by_id,order,known={},{},{}
    local cursor="0"
    for page=1,12 do
        local ok,value=pcall(method,api,book_id,cursor,is_review and 200 or nil)
        if not ok then return nil,tostring(value) end
        if type(value)~="table" or (value.bookId~=nil and not Json.is_null(value.bookId)
            and scalar(value.bookId)~=tostring(book_id)) then return nil,invalid end
        local more,continue=annotation_flag(value.hasMore),annotation_flag(value.continueFlag)
        local reset=annotation_flag(value.isClearAll)
        local clear=annotation_flag(value.clearAll)
        local reset_data=annotation_flag(value.resetData)
        if more==nil or continue==nil or reset==nil or clear==nil or reset_data==nil then return nil,invalid end
        -- A reset mid-scan invalidates the earlier pages. A later run starts from zero.
        if page>1 and (reset or clear or reset_data) then return nil,invalid end

        local removed=value.removed
        if removed~=nil and not Json.is_null(removed) then
            if type(removed)~="table" then return nil,invalid end
            for index,id in pairs(removed) do
                if type(index)~="number" or index<1 or index>#removed or index%1~=0
                    or (type(id)~="string" and type(id)~="number") or scalar(id)=="" then return nil,invalid end
                by_id[scalar(id)]=nil
            end
        end

        local saw_rows=false
        for _,name in ipairs({primary,"updated"}) do
            local rows=value[name]
            if rows~=nil and not Json.is_null(rows) then
                if type(rows)~="table" then return nil,invalid end
                saw_rows=true
                for index in pairs(rows) do
                    if type(index)~="number" or index<1 or index>#rows or index%1~=0 then return nil,invalid end
                end
                for _,entry in ipairs(rows) do
                    if type(entry)~="table" then return nil,invalid end
                    local row=is_review and type(entry.review)=="table" and U.merge(entry,entry.review) or entry
                    local id=id_of(row)
                    local source_book=row.bookId or row.book_id
                    if id=="" or (source_book~=nil and scalar(source_book)~=tostring(book_id)) then return nil,invalid end
                    if not known[id] then order[#order+1]=id; known[id]=true end
                    by_id[id]=row
                end
            end
        end
        if not saw_rows then return nil,invalid end
        if not more and not continue then
            local records={}
            for _,id in ipairs(order) do
                if by_id[id] then records[#records+1]=by_id[id] end
            end
            return records
        end
        local next_cursor=annotation_sync_key(value.synckey or value.syncKey)
        if not next_cursor or #next_cursor<#cursor or (#next_cursor==#cursor and next_cursor<=cursor) then
            return nil,invalid.."（分页游标未推进）"
        end
        cursor=next_cursor
    end
    return nil,invalid.."（超过单次分页上限）"
end

function AnnotationSync.cloud_thoughts(api,book_id)
    local records,err=fetch_cloud_annotations(api,book_id,true)
    if not records then error(err,0) end
    local thoughts,present_ids={},{}
    for _,row in ipairs(records) do
        local id=review_remote_id(row)
        present_ids[id]=true
        local content=scalar(row.content or row.text)
        local quote=scalar(row.abs or row.abstract or row.contextAbstract)
        if tonumber(row.type)==1 and (U.trim(content)~="" or U.trim(quote)~="") then
            thoughts[#thoughts+1]={content=content,quote=quote,chapter=scalar(row.chapterTitle),
                review_id=id,chapter_uid=scalar(row.chapterUid or row.chapter_uid or row.chapterId),
                range=record_range(row),book_version=positive_version(row.bookVersion),
                updated_at=tonumber(row.updateTime or row.createTime) or 0,status="synced"}
        end
    end
    return thoughts,present_ids
end

function AnnotationSync.cloud_thought_snapshot(api,book_id)
    local checked_at=os.time()
    local rows,present_ids=AnnotationSync.cloud_thoughts(api,book_id)
    return {rows=rows,present_ids=present_ids,checked_at=checked_at}
end

local function editable_review(api,row)
    local value=api:review_single(row.remote_id)
    local target=find_review_match(collect_records(value),nil,nil,row.remote_id)
    if not target or not matches_chapter(target,row.chapter_uid) then return nil end
    for _,key in ipairs({"pictures","pencilNote","docInfo","topicRanges","audioId","videoInfo","htmlContent","atUserVids"}) do
        local extra=target[key]
        if extra~=nil and not Json.is_null(extra) and extra~=""
            and (type(extra)~="table" or next(extra)~=nil) then return nil end
    end
    local function flag(value)
        if value==true or tonumber(value)==1 then return 1 end
        if value==false or tonumber(value)==0 then return 0 end
    end
    local private=flag(target.isPrivate)
    local friend=flag(target.friendship)
    local hidden=flag(target.notVisibleToFriends)
    local attr=tonumber(target.intergrateAttr)
    if attr then
        if friend==nil then friend=bit.band(attr,64)~=0 and 1 or 0 end
        if hidden==nil then hidden=bit.band(attr,256)~=0 and 1 or 0 end
    end
    local kind=tonumber(target.type)
    local content=target.content or target.text
    if not (private and friend and hidden and kind and type(content)=="string") then return nil end
    return target,{
        reviewId=row.remote_id,content=row.note,isPrivate=private,friendship=friend,
        notVisibleToFriends=hidden,type=kind,
    }
end

function AnnotationSync.change_cloud_thought(api,book_id,note,action,content)
    local current=fetch_cloud_annotations(api,book_id,true)
    if not current then return nil,"无法读取云端想法" end
    local original=find_review_match(current,nil,nil,note.review_id)
    if not original then
        if action=="delete" then
            local snapshot=AnnotationSync.cloud_thought_snapshot(api,book_id)
            if not snapshot.present_ids[note.review_id] then return snapshot end
            return nil,"微信还未确认这次删除"
        end
        return nil,"这条想法已在云端删除"
    end
    if not matches_chapter(original,note.chapter_uid) or record_range(original)~=note.range
        or tostring(original.content or original.text or "")~=note.content then
        return nil,"手机上已修改这条想法，请刷新后再操作"
    end
    if action=="edit" then
        local target,payload=editable_review(api,{remote_id=note.review_id,chapter_uid=note.chapter_uid,note=content})
        if not target or record_range(target)~=note.range
            or tostring(target.content or target.text or "")~=note.content then
            return nil,"无法确认原想法内容和可见范围"
        end
        pcall(api.edit_review,api,payload)
    elseif action=="delete" then
        pcall(api.remove_review,api,{reviewId=note.review_id,bookId=book_id,
            chapterUid=note.chapter_uid,range=note.range,bookVersion=note.book_version or 0})
    else
        return nil,"未知的想法操作"
    end
    local updated=AnnotationSync.cloud_thought_snapshot(api,book_id)
    for _,row in ipairs(updated.rows) do
        if row.review_id==note.review_id then
            if action=="edit" and row.content==content and row.chapter_uid==note.chapter_uid and row.range==note.range then
                return updated
            end
            return nil,"微信还未确认这次修改"
        end
    end
    if action=="delete" and not updated.present_ids[note.review_id] then return updated end
    return nil,"微信还未确认这次修改"
end

function AnnotationSync:_sync_review_edit(book_id,row)
    local ok,target,payload=pcall(editable_review,self.api,row)
    if not ok or not target or U.trim(row.note)=="" then
        return false,"E-Ink 无法验证原想法及可见范围"
    end
    local cloud_text=U.trim(target.content or target.text)
    if cloud_text==U.trim(row.note) then
        return LocalDB.finish_thought_edit(self.store,book_id,row,true)
    end
    if row.synced_note~=nil and cloud_text~=U.trim(row.synced_note) then
        return false,"云端和本机都编辑过这条想法，本机草稿仍保留"
    end
    if row.sync_state=="unknown" then return false,"想法修改回执待确认" end
    local started=LocalDB.begin_thought_edit(self.store,book_id,row)
    if started~=true then return false,"想法已被修改，稍后重新核对" end
    local sent,value=pcall(self.api.edit_review,self.api,payload)
    if not sent and tostring(value):find("[MiuReadBeforeWrite]",1,true) then
        LocalDB.finish_thought_edit(self.store,book_id,row,false)
        return false,"想法修改尚未发送"
    end
    local checked,fresh,updated=pcall(editable_review,self.api,row)
    if checked and fresh and U.trim(fresh.content or fresh.text)==U.trim(row.note)
        and payload.isPrivate==updated.isPrivate and payload.friendship==updated.friendship
        and payload.notVisibleToFriends==updated.notVisibleToFriends and payload.type==updated.type then
        return LocalDB.finish_thought_edit(self.store,book_id,row,true)
    end
    return false,"想法修改回执待确认"
end

function AnnotationSync:sync_book(book, record, options)
    options = options or {}
    local book_id = tostring((book and (book.book_id or book.bookId)) or (record and record.book_id) or "")
    if book_id == "" then return {ok=false, error="bookId missing"} end
    local prefs = options.preferences or {}
    local rows,rows_error=LocalDB.pending(self.store,book_id,options.limit or 200,
        {upload_only=options.upload_only==true})
    if not rows then return {ok=false, error=rows_error} end
    -- B1 safety: the pre-delete path may upload local additions but may never
    -- consume deletion tombstones. Do this before collecting cloud API needs.
    if options.upload_only == true then
        local additions = {}
        for _, row in ipairs(rows) do
            if row.sync_state ~= "delete_pending" and row.sync_state ~= "delete_unknown" then
                additions[#additions + 1] = row
            end
        end
        rows = additions
    end
    local summary = LocalDB.summary(self.store, book_id) or {}
    local result = {ok=true,total=#rows,synced=0,deleted=0,failed=0,locate_failed=0,
        metadata_failed=0,coord_failed=0,unknown=0,skipped=0,reconciled=0,errors={},
        legacy_synced=tonumber(summary.legacy_synced or 0) or 0}
    if #rows == 0 then return result end

    local need_bookmarks, need_reviews = false, false
    for _, row in ipairs(rows) do
        local stored_kind = tostring(row.kind or "")
        local sync_kind = effective_sync_kind(row)
        if sync_kind ~= "" and sync_kind ~= stored_kind then
            logger.info("[MiuRead][AnnotationSync] sync kind recovered",
                "local=", tostring(row.local_id or ""),
                "stored=", stored_kind, "effective=", sync_kind)
            if tostring(row.sync_kind or "") ~= sync_kind then
                LocalDB.set_sync_kind(self.store, book_id, row.local_id, sync_kind)
                row.sync_kind = sync_kind
            end
            row.kind = sync_kind
        elseif sync_kind ~= "" then
            row.kind = sync_kind
        end
        if row.kind == "thought" then need_reviews = true else need_bookmarks = true end
    end
    local cloud_bookmarks, bookmark_error = {}, nil
    local cloud_reviews, review_error = {}, nil
    if need_bookmarks then cloud_bookmarks,bookmark_error=fetch_cloud_annotations(self.api,book_id,false) end
    if need_reviews then cloud_reviews,review_error=fetch_cloud_annotations(self.api,book_id,true) end
    if need_bookmarks and not cloud_bookmarks then bookmark_error=bookmark_error or "bookmark reconciliation failed" end
    if need_reviews and not cloud_reviews then review_error=review_error or "review reconciliation failed" end

    local version,version_source=self:_book_version(book_id,book or {},record or {},nil)
    logger.info("[MiuRead][AnnotationSync] book version preflight",
        "book=",tostring(book_id),"version=",tostring(version or 0),"source=",tostring(version_source or "missing"))
    if (need_bookmarks and auth_like_error(bookmark_error)) or (need_reviews and auth_like_error(review_error)) then
        result.ok=false
        result.auth_failed=true
        result.error="微信读书登录状态失效，本次未尝试上传本地批注"
        return result
    end
    local coord_cache={eink=require("miuread.eink_client").new(self.reader.http,self.store)}

    local function remember_error(row, state, message, stage, fields)
        fields = fields or {}
        fields.last_stage = tostring(stage or "unknown")
        fields.last_error = tostring(message or "")
        fields.last_attempt_at = os.time()
        LocalDB.mark_state(self.store, book_id, row.local_id, state, fields)
        result.failed = result.failed + 1
        if state == "locate_failed" then result.locate_failed = result.locate_failed + 1 end
        if state == "metadata_failed" then result.metadata_failed = result.metadata_failed + 1 end
        if state == "coord_failed" then result.coord_failed = result.coord_failed + 1 end
        if state == "unknown" or state == "delete_unknown" then result.unknown = result.unknown + 1 end
        if #result.errors < 12 then
            result.errors[#result.errors + 1] = {
                kind=tostring(row.kind or ""), stage=tostring(stage or "unknown"),
                error=tostring(message or state),
            }
        end
        stage_log(row, stage, false, message)
    end

    for _, row in ipairs(rows) do
        local is_review = row.kind == "thought"
        local cloud_rows = is_review and cloud_reviews or cloud_bookmarks
        local cloud_error = is_review and review_error or bookmark_error
        local expected_type = row.kind == "bookmark" and 0 or 1
        local match, matched_id
        if cloud_rows then
            if is_review then
                match, matched_id = find_review_match(cloud_rows, row.range_key, row.note, row.remote_id, row.chapter_uid)
            else
                match, matched_id = find_bookmark_match(cloud_rows, row.range_key, expected_type, row.remote_id, row.chapter_uid)
            end
        end

        if row.sync_state == "delete_pending" or row.sync_state == "delete_unknown" then
            -- A local tombstone is only removed after cloud reconciliation proves
            -- the remote item is already absent or a delete request returns
            -- successfully. Network-unknown writes remain retry-blocked until the
            -- next reconciliation pass, exactly like create writes.
            if not cloud_rows then
                remember_error(row, row.sync_state, "删除前云端对账失败：" .. tostring(cloud_error or "unknown"), "reconcile")
            elseif row.remote_id ~= "" and not match then
                LocalDB.delete_row(self.store, book_id, row.local_id)
                result.deleted = result.deleted + 1
                stage_log(row, "delete", true, "already_absent")
            else
                local remote_id = row.remote_id ~= "" and row.remote_id or matched_id
                if remote_id == "" then
                    remember_error(row, "delete_pending",
                        is_review and "缺少 reviewId，无法安全删除" or "缺少 bookmarkId，无法安全删除", "delete")
                else
                    local ok, value
                    if is_review then
                        -- WeRead's reader dispatches FETCH_BOOK_REVIEW_DELETE with
                        -- reviewId plus the current book/chapter/range context.
                        -- Keep the full context when available instead of reducing
                        -- the request to reviewId only.
                        local delete_payload = {
                            reviewId=remote_id,
                            bookId=book_id,
                            chapterUid=tostring(row.chapter_uid or ""),
                            range=tostring(row.range_key or ""),
                            bookVersion=tonumber(row.book_version) or tonumber(version) or 0,
                        }
                        stage_log(row, "delete", true, "post review/delete")
                        ok, value = pcall(self.api.remove_review, self.api, delete_payload)
                    else
                        stage_log(row, "delete", true, "post book/removeBookmark")
                        ok, value = pcall(self.api.remove_bookmark, self.api, remote_id, {
                            bookId=book_id, chapterUid=row.chapter_uid,
                        })
                    end
                    local confirmed=ok and type(value)=="table" and annotation_flag(value.succ)==true
                    if ok and not confirmed then
                        local fresh=fetch_cloud_annotations(self.api,book_id,is_review)
                        local find=is_review and review_remote_id or bookmark_remote_id
                        if fresh then
                            confirmed=true
                            for _,entry in ipairs(fresh) do
                                if find(entry)==remote_id then confirmed=false; break end
                            end
                        end
                    end
                    if confirmed then
                        LocalDB.delete_row(self.store, book_id, row.local_id)
                        result.deleted = result.deleted + 1
                        stage_log(row, "delete", true, "remote_deleted")
                    elseif ok or Http.is_network_error(value) or tostring(value):match("HTTP 5%d%d") then
                        remember_error(row, "delete_unknown", ok and "删除回执待确认" or value, "delete", {remote_id=remote_id})
                    else
                        remember_error(row, "delete_pending", value, "delete", {remote_id=remote_id})
                    end
                end
            end
        elseif is_review and row.remote_id~="" and (row.sync_state=="local_only"
            or (row.sync_state=="unknown" and row.last_stage=="eink_edit")) then
            local edited,reason=self:_sync_review_edit(book_id,row)
            if edited then
                result.synced=result.synced+1
                stage_log(row,"edit",true,"confirmed")
            else
                result.failed=result.failed+1
                if #result.errors<12 then result.errors[#result.errors+1]={kind="thought",stage="edit",error=reason} end
                stage_log(row,"edit",false,reason)
            end
        elseif row.sync_state == "unknown" then
            if cloud_rows and match then
                local rid = matched_id or (is_review and review_remote_id(match) or bookmark_remote_id(match))
                LocalDB.mark_synced(self.store, book_id, row.local_id, rid, row.range_key, version)
                result.synced = result.synced + 1
                result.reconciled = result.reconciled + 1
                stage_log(row, "reconcile", true, "existing_remote")
            else
                remember_error(row, "unknown", cloud_error and ("云端对账失败："..cloud_error)
                    or "上次请求结果未知，未自动重复上传", "reconcile")
            end
        else
            stage_log(row, "chapter", true, "resolve")
            local located, chapter_ctx, locate_error, locate_stage =
                self:_locate_with_chapter_candidates(book or {}, record or {}, row, coord_cache)
            if not located then
                local state = locate_stage == "chapter" and "metadata_failed" or "locate_failed"
                remember_error(row, state, locate_error, locate_stage or "locate")
            else
                row.chapter_uid = tostring(chapter_ctx.chapter_uid or row.chapter_uid or "")
                row.chapter_idx = tonumber(chapter_ctx.chapter_idx or row.chapter_idx)
                local write_version = positive_version(chapter_ctx.book_version)
                    or positive_version(row.book_version) or positive_version(version)
                local write_version_source = write_version and (chapter_ctx.book_version and
                    tostring(chapter_ctx.book_version_source or "reader_chapter_state")
                    or (positive_version(row.book_version) and "local_row" or tostring(version_source or "cached"))) or "missing"
                if chapter_ctx.plain_text then
                    write_version = write_version or 0
                    write_version_source = "reader_txt_state"
                end
                if not write_version then
                    local recovered, recovered_source = self:_book_version(book_id, book or {}, record or {}, row.chapter_uid)
                    write_version = positive_version(recovered)
                    write_version_source = tostring(recovered_source or "missing")
                    if write_version then
                        version, version_source = write_version, write_version_source
                    end
                end
                local verification = self:_verify_coordinate_basis(book_id, chapter_ctx)
                located.anchor_checked = tonumber(verification.checked or 0) or 0
                located.anchor_matched = tonumber(verification.matched or 0) or 0
                local accepted, effective_verify, verify_error =
                    coordinate_acceptance(located, verification)
                located.coord_verify = tostring(effective_verify or "inconclusive")
                if not accepted then
                    remember_error(row, "coord_failed", verify_error or "coordinate_evidence_inconclusive", "coord_basis", {
                        range_key=located.range, book_version=write_version or 0,
                        chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                        coord_version=COORD_VERSION, coord_source=chapter_ctx.coord_source or COORD_SOURCE,
                        coord_verify=tostring(effective_verify or "inconclusive"),
                    })
                else
                    stage_log(row, "verify", true, string.format(
                        "%s coord=%s official=%s source=%s anchors=%d/%d exact=%d contained=%d",
                        tostring(located.range), tostring(effective_verify),
                        tostring(verification.status), tostring(chapter_ctx.coord_source or COORD_SOURCE),
                        tonumber(verification.matched or 0) or 0,
                        tonumber(verification.checked or 0) or 0,
                        tonumber(verification.exact or 0) or 0,
                        tonumber(verification.contained or 0) or 0))
                    LocalDB.mark_state(self.store, book_id, row.local_id, "local_only", {
                        range_key=located.range, book_version=write_version or 0,
                        chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                        coord_version=COORD_VERSION, coord_source=chapter_ctx.coord_source or COORD_SOURCE, coord_verify=effective_verify,
                        last_stage="verify", last_error="", last_attempt_at=os.time(),
                    })
                    row.range_key = located.range
                    row.coord_version = COORD_VERSION
                    row.coord_source = chapter_ctx.coord_source or COORD_SOURCE
                    row.coord_verify = effective_verify

                    if cloud_rows then
                        if is_review then
                            match, matched_id = find_review_match(cloud_rows, located.range, row.note, row.remote_id, row.chapter_uid)
                        else
                            match, matched_id = find_bookmark_match(cloud_rows, located.range, expected_type, row.remote_id, row.chapter_uid)
                        end
                    end
                    if match then
                        local rid = matched_id or (is_review and review_remote_id(match) or bookmark_remote_id(match))
                        LocalDB.mark_synced(self.store, book_id, row.local_id, rid, located.range, write_version or 0, {
                            chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                            coord_version=COORD_VERSION, coord_source=chapter_ctx.coord_source or COORD_SOURCE, coord_verify=effective_verify,
                        })
                        result.synced = result.synced + 1
                        result.reconciled = result.reconciled + 1
                        stage_log(row, "reconcile", true, "existing_remote")
                    else
                        -- A brand-new local record has never been POSTed by MiuRead, so a
                        -- temporary failure to read the cloud list must not block its first
                        -- upload forever. We still use the list for de-duplication whenever
                        -- it is available. Only `unknown` records require reconciliation
                        -- before another POST, because their previous write may have reached
                        -- the server despite a lost response.
                        if not cloud_rows then
                            stage_log(row, "reconcile", true,
                                "preflight_unavailable_first_post:" .. tostring(cloud_error or "unknown"))
                        end
                        local payload = is_review
                            and self:_review_payload(row, located, write_version or 0, prefs)
                            or self:_bookmark_payload(row, located, write_version or 0, prefs)
                        if not is_review then
                            stage_log(row, "payload", true, string.format(
                                "book/addBookmark type=%d style=%d color=%s chapterIdx=%d bookVersion=%d markText=plain_to_base64 chars=%d",
                                tonumber(payload.type) or -1, tonumber(payload.style) or -1,
                                payload.colorStyle==nil and "none" or tostring(tonumber(payload.colorStyle) or 0),
                                tonumber(payload.chapterIdx) or -1, tonumber(payload.bookVersion) or 0,
                                U.utf8_len(tostring(payload.markText or "")))
                                .. " source=" .. tostring(write_version_source or "missing"))
                        end
                        local payload_ok, payload_error = validate_payload(row, payload, chapter_ctx.plain_text)
                        if not payload_ok then
                            remember_error(row, "metadata_failed", payload_error, "payload", {
                                range_key=located.range, book_version=write_version or 0,
                                chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                                coord_version=COORD_VERSION, coord_source=chapter_ctx.coord_source or COORD_SOURCE, coord_verify=effective_verify,
                            })
                        else
                            stage_log(row, "post", true, is_review and "review/add" or "book/addBookmark")
                            local recorded=LocalDB.mark_state(self.store,book_id,row.local_id,"unknown",{
                                last_stage="eink_submit",range_key=located.range,book_version=write_version or 0,
                                chapter_uid=row.chapter_uid,chapter_idx=row.chapter_idx,
                            })
                            local ok,value=false,"[MiuReadBeforeWrite] 无法保存批注请求状态"
                            if recorded==true then
                                ok,value=pcall(is_review and self.api.add_review or self.api.add_bookmark,
                                    self.api,native_payload(payload,is_review))
                            end
                            if ok then
                                local remote_id = is_review
                                    and find_id(value, {"reviewId", "reviewID"})
                                    or find_id(value, {"bookmarkId", "bookmarkID"})
                                local confirmed,confirmed_id
                                local fresh=fetch_cloud_annotations(self.api,book_id,is_review)
                                if is_review then
                                    confirmed,confirmed_id=find_review_match(fresh,located.range,row.note,remote_id,row.chapter_uid)
                                else
                                    confirmed,confirmed_id=find_bookmark_match(fresh,located.range,expected_type,remote_id,row.chapter_uid)
                                end
                                if not confirmed or not confirmed_id or confirmed_id==""
                                    or not matches_chapter(confirmed,row.chapter_uid) or record_range(confirmed)~=located.range then
                                    remember_error(row, "unknown", "E-Ink 尚未确认批注的位置及编号", "readback", {
                                        range_key=located.range, book_version=write_version or 0,
                                        chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                                        coord_version=COORD_VERSION, coord_source=chapter_ctx.coord_source or COORD_SOURCE, coord_verify=effective_verify,
                                    })
                                else
                                    LocalDB.mark_synced(self.store, book_id, row.local_id,
                                        confirmed_id, located.range, write_version or 0, {
                                            chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                                            coord_version=COORD_VERSION, coord_source=chapter_ctx.coord_source or COORD_SOURCE, coord_verify=effective_verify,
                                        })
                                    result.synced = result.synced + 1
                                    stage_log(row, "post", true, remote_id ~= "" and "remote_id_saved" or "review_saved")
                                end
                            elseif Http.is_network_error(value) or tostring(value):match("HTTP 5%d%d") then
                                -- A lost response may still have reached WeRead. Reconcile
                                -- before any retry so a duplicate annotation cannot be posted.
                                remember_error(row, "unknown", value, "post", {
                                    range_key=located.range, book_version=write_version or 0,
                                    chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                                    coord_version=COORD_VERSION, coord_source=chapter_ctx.coord_source or COORD_SOURCE, coord_verify=effective_verify,
                                })
                            elseif tostring(value):find("[MiuReadBeforeWrite]",1,true) and retryable_post_error(value) then
                                -- Authentication/rate-limit/5xx failures are recoverable and
                                -- remain eligible for a later manual sync attempt.
                                remember_error(row, "local_only", value, "post", {
                                    range_key=located.range, book_version=write_version or 0,
                                    chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                                    coord_version=COORD_VERSION, coord_source=chapter_ctx.coord_source or COORD_SOURCE, coord_verify=effective_verify,
                                })
                            else
                                -- Deterministic server rejection is not fixed by hammering the
                                -- same payload again. Park it in the existing action-required
                                -- state; the user can explicitly retry after metadata repair.
                                remember_error(row, "metadata_failed", value, "post_rejected", {
                                    range_key=located.range, book_version=write_version or 0,
                                    chapter_uid=row.chapter_uid, chapter_idx=row.chapter_idx,
                                    coord_version=COORD_VERSION, coord_source=chapter_ctx.coord_source or COORD_SOURCE, coord_verify=effective_verify,
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    logger.info("[MiuRead][AnnotationSync] completed",
        "book=",book_id,"total=",tostring(result.total),"synced=",tostring(result.synced),
        "deleted=",tostring(result.deleted),"locate_failed=",tostring(result.locate_failed),
        "metadata_failed=",tostring(result.metadata_failed),
        "coord_failed=",tostring(result.coord_failed),
        "legacy_synced=",tostring(result.legacy_synced),
        "unknown=",tostring(result.unknown),"failed=",tostring(result.failed))
    return result
end

return AnnotationSync
