local Pdf = {}

function Pdf.is_book(book)
    if type(book)~="table" then return false end
    local details=book.bookInfo or book.book or book
    if type(details)~="table" then details=book end
    return tostring(details.format or book.format or ""):lower()=="pdf"
        or tonumber(details.type or details.book_type or book.type or book.book_type)==11
end

function Pdf.progress(response,id)
    local row=type(response)=="table" and response.book
    if row==nil then return nil,"pdf_progress_missing" end
    local Json=require("miuread.json")
    if Json.is_null(row) then return {source="eink",empty=true,percent=0,updated_at=0} end
    if type(row)~="table" or (row.bookId~=nil and tostring(row.bookId)~=tostring(id))
        or (row.otherType~=nil and not Json.is_null(row.otherType)) then return nil,"pdf_progress_other_format" end
    local page=tonumber(row.chapterUid)
    if page==nil or page<0 then return {source="eink",empty=true,percent=0,updated_at=0} end
    local index,offset=tonumber(row.chapterIdx),tonumber(row.chapterOffset)
    if page%1~=0 or page>=100000 or (row.chapterOffset~=nil and offset~=0)
        or (row.chapterIdx~=nil and index~=page) then return nil,"pdf_progress_invalid" end
    local timestamp=row.updateTime or row.updatedAt
    local updated=require("miuread.shelf_progress").timestamp(timestamp)
    if updated==0 then updated=require("miuread.timezone").parse_iso_timestamp(timestamp) or 0 end
    if updated<=0 then return nil,"pdf_progress_time_missing" end
    return {source="eink",document_format="pdf",chapter_uid=tostring(page),chapter_idx=page,offset=0,
        chapter_offset=0,updated_at=updated,version=tonumber(row.bookVersion) or 0,
        app_id=row.appId,install_id=row.installId,device_id=row.deviceId,
        percent=tonumber(row.progress or row.currentProgress),offset_basis="wr_data_co",native_offset=true}
end

function Pdf.capture(record,book_page,total_pages)
    local data=record and record.record or {}
    local version=tonumber(data.pdf_book_version)
    local page,total=tonumber(book_page),tonumber(total_pages)
    if version==nil or not page or not total or page%1~=0 or total%1~=0 or page<1 or page>total or total>100000 then
        return nil,"pdf_local_page_unavailable"
    end
    local zero_page=page-1
    return {document_format="pdf",book_id=tostring((record.book or {}).book_id or ""),book_version=version,
        chapter_uid=tostring(zero_page),chapter_index=zero_page,chapter_idx=zero_page,chapter_offset=0,offset=0,
        canonical_offset=0,progress=page==total and 100 or math.floor(zero_page*100/total),
        summary="",eink_coordinate=true,native_offset=true,safe=true,precise=true,
        offset_basis="wr_data_co",position_basis="wr_data_co",captured_at=os.time()}
end

function Pdf.validate(path,options)
    local file=io.open(path,"rb")
    if not file then return nil,"PDF 文件不存在" end
    local size=file:seek("end") or 0
    local expected=tonumber(options and options.document_size)
    if size<32 or (expected and size~=expected) then
        file:close()
        return nil,"PDF 文件大小不一致"
    end
    file:seek("set",0)
    local header=file:read(8) or ""
    file:seek("set",math.max(0,size-4096))
    local tail=file:read("*a") or ""
    file:close()
    if not header:match("^%%PDF%-%d%.%d") or not tail:match("startxref%s+%d+%s%%%%EOF%s*$") then
        return nil,"PDF 文件损坏或下载不完整"
    end
    return true,{size=size}
end

return Pdf
