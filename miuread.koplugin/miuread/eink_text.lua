local U=require("miuread.util")
local M={}

local function strip_bom(text)
    if text:sub(1,3)=="\239\187\191" then return text:sub(4) end
    -- A chapter can have a UTF-16 BOM. Convert before merging chapters, since
    -- the resulting TXT file has a single encoding and a single byte index.
    local bom=text:sub(1,2)
    if bom~="\255\254" and bom~="\254\255" then return text end
    local little=bom=="\255\254"
    if #text%2~=0 then error("E-Ink TXT 的 UTF-16 数据不完整",0) end
    local parts,chunk,high={},{},nil
    for i=3,#text,2 do
        local a,b=text:byte(i,i+1)
        local value=little and (a+b*256) or (a*256+b)
        if high then
            if value<0xdc00 or value>0xdfff then error("E-Ink TXT 包含无效字符",0) end
            value=0x10000+(high-0xd800)*1024+value-0xdc00
            high=nil
            chunk[#chunk+1]=string.char(0xf0+math.floor(value/262144),
                0x80+math.floor(value/4096)%64,0x80+math.floor(value/64)%64,0x80+value%64)
        elseif value>=0xd800 and value<=0xdbff then high=value
        elseif value>=0xdc00 and value<=0xdfff then error("E-Ink TXT 包含无效字符",0)
        elseif value>=0x800 then chunk[#chunk+1]=string.char(0xe0+math.floor(value/4096),
            0x80+math.floor(value/64)%64,0x80+value%64)
        elseif value>=0x80 then chunk[#chunk+1]=string.char(0xc0+math.floor(value/64),0x80+value%64)
        else chunk[#chunk+1]=string.char(value) end
        if #chunk>=4096 then parts[#parts+1]=table.concat(chunk); chunk={} end
    end
    if high then error("E-Ink TXT 的 UTF-16 数据不完整",0) end
    parts[#parts+1]=table.concat(chunk)
    return table.concat(parts)
end

function M.read_chapter(path,book_id,uid)
    local archive=require("ffi/archiver").Reader:new()
    local ok,result=pcall(function()
        if not archive:open(path) then error("E-Ink TXT 章节包无法打开",0) end
        local prefix=tostring(book_id).."_"
        local match
        for entry in archive:iterate(true) do
            local name=entry.path
            if entry.index>256 then error("E-Ink TXT 章节包条目超限",0) end
            if entry.mode=="file" and name~="info.txt" then
                if type(name)~="string" or name:sub(1,#prefix)~=prefix or name:find("[/\\%c]") then
                    error("E-Ink TXT 章节包与书籍不匹配",0)
                end
                local chapter=name:sub(#prefix+1):match("^(%d+)")
                local suffix=chapter and name:sub(#prefix+#chapter+1) or ""
                if chapter==tostring(uid) and (suffix=="" or suffix==".txt" or suffix:sub(1,1)=="_") then
                    if match or not tonumber(entry.size) or entry.size<1 or entry.size>8*1024*1024 then
                        error("E-Ink TXT 章节内容无效",0)
                    end
                    local raw=archive:extractToMemory(entry.index)
                    if type(raw)~="string" or #raw~=entry.size then error("E-Ink TXT 章节数据不完整",0) end
                    match=strip_bom(raw)
                end
            elseif entry.mode~="directory" and entry.mode~="file" then
                error("E-Ink TXT 章节包含有无效条目",0)
            end
        end
        if archive.err or not match or not match:find("%S") or match:find("\0",1,true) then
            error("E-Ink TXT 章节正文缺失或编码无效",0)
        end
        return match
    end)
    archive:close()
    if not ok then error(result,0) end
    return result
end

function M.build(path,chapters,map,check)
    local file=assert(io.open(path,"wb"))
    local ok,result=pcall(function()
        local position=0
        for index,chapter in ipairs(chapters) do
            check()
            if index>1 then
                assert(file:write("\n\n"))
                position=position+2
            end
            local text=chapter.text_path and U.read_file(chapter.text_path,true)
            if type(text)~="string" or #text==0 then error("TXT 章节断点内容缺失",0) end
            map[index].text_offset=position
            map[index].text_bytes=#text
            assert(file:write(text))
            position=position+#text
        end
        return position
    end)
    local closed=file:close()
    if not ok or not closed then
        os.remove(path)
        error(ok and "TXT 文件无法完整写入" or result,0)
    end
    return result
end

function M.validate(path,opt)
    local size=U.file_size(path)
    if not size or size<=0 or size~=opt.text_size then return nil,"TXT 文件大小与章节索引不符" end
    local last=0
    for index,chapter in ipairs(opt.chapters or {}) do
        local offset=tonumber(chapter.text_offset)
        local bytes=tonumber(chapter.text_bytes)
        if offset~=last+(index==1 and 0 or 2) or not bytes or bytes<=0 then return nil,"TXT 章节索引无效" end
        last=offset+bytes
    end
    if last~=size then return nil,"TXT 章节索引不完整" end
    return true,{book_id=opt.book_id,variant=opt.variant,chapters=opt.chapters}
end

return M
