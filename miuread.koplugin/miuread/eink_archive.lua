-- Read one native chapter ZIP from disk, with bounded allocations, traditional
-- ZIP decryption and CRC verification. Archive names never become disk paths.
local bit = require("bit")
local Crypto = require("miuread.eink_crypto")
local Codec = require("miuread.codec")
local Json = require("miuread.json")
local U = require("miuread.util")
local M = {}
local MAX_ENTRY, MAX_ARCHIVE = 8*1024*1024, 32*1024*1024
local function le(s, p, n)
    if p < 1 or p+n-1 > #s then error("E-Ink ZIP 已截断") end
    local value = 0
    for i = n-1, 0, -1 do value = value*256+s:byte(p+i) end
    return value
end
local crc_table = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do c = bit.bxor(bit.rshift(c,1), bit.band(c,1) == 1 and 0xedb88320 or 0) end
    crc_table[i] = c
end
local function step(crc, value) return bit.bxor(bit.rshift(crc,8), crc_table[bit.band(bit.bxor(crc,value),255)]) end
local function crc32(data)
    local c = -1
    for i = 1, #data do c = step(c, data:byte(i)) end
    return bit.bnot(c)
end
local function multiply(a,b)
    local low, high = bit.band(a,65535), bit.rshift(a,16)
    return bit.tobit(low*bit.band(b,65535) + bit.lshift(bit.tobit(high*bit.band(b,65535)+low*bit.rshift(b,16)),16))
end
local function decrypt(data, password, check)
    if #data < 12 then error("E-Ink ZIP 密码头缺失") end
    local a,b,c = 0x12345678,0x23456789,0x34567890
    local function update(value)
        a = step(a,value)
        b = bit.tobit(multiply(bit.tobit(b+bit.band(a,255)),134775813)+1)
        c = step(c,bit.rshift(b,24))
    end
    for i = 1, #password do update(password:byte(i)) end
    local chunks, chunk = {}, {}
    for i = 1, #data do
        local t = bit.bor(c,2)
        local value = bit.bxor(data:byte(i),bit.band(bit.rshift(multiply(t,bit.bxor(t,1)),8),255))
        update(value)
        if i == 12 and value ~= check then error("E-Ink ZIP 密码校验失败") end
        if i > 12 then
            chunk[#chunk+1] = string.char(value)
            if #chunk == 4096 then chunks[#chunks+1] = table.concat(chunk); chunk = {} end
        end
    end
    chunks[#chunks+1] = table.concat(chunk)
    return table.concat(chunks)
end

local function read_zip(file, password, root, opt)
    local size = file:seek("end")
    if not size or size < 22 or size > MAX_ARCHIVE then error("E-Ink 章节包大小无效") end
    local tail_size = math.min(size,65557)
    file:seek("set",size-tail_size)
    local tail, marker = file:read(tail_size), nil
    for p = tail_size-21, 1, -1 do
        if tail:sub(p,p+3) == "PK\005\006" and p+21+le(tail,p+20,2) == #tail then marker = p; break end
    end
    if not marker or le(tail,marker+4,2) ~= 0 or le(tail,marker+6,2) ~= 0 then error("E-Ink ZIP 目录无效") end
    local count, central_size, offset = le(tail,marker+10,2), le(tail,marker+12,4), le(tail,marker+16,4)
    if count < 1 or count > 2048 or le(tail,marker+8,2) ~= count or offset+central_size ~= size-tail_size+marker-1 then
        error("E-Ink ZIP 中央目录无效")
    end
    local entries, names, total = {}, {}, 0
    file:seek("set",offset)
    for _ = 1, count do
        local h = file:read(46) or ""
        if #h ~= 46 or h:sub(1,4) ~= "PK\001\002" then error("E-Ink ZIP 目录损坏") end
        local name_size, extra, comment = le(h,29,2),le(h,31,2),le(h,33,2)
        local name = file:read(name_size) or ""
        if #name ~= name_size or name == "" or name:find("[%z\\]") or name:match("^/") or name:match("^%a:")
            or ("/"..name.."/"):find("/../",1,true) or names[name] then error("E-Ink ZIP 文件名无效") end
        names[name] = true
        local entry = {name=name,flags=le(h,9,2),method=le(h,11,2),crc=le(h,17,4),
            compressed=le(h,21,4),size=le(h,25,4),offset=le(h,43,4)}
        names[name]=entry
        total = total+entry.size
        if entry.size > MAX_ENTRY or entry.compressed > MAX_ARCHIVE or total > 64*1024*1024
            or entry.offset+30+entry.compressed > offset or bit.band(entry.flags,0x40) ~= 0 then error("E-Ink ZIP 条目超限或不支持") end
        entries[#entries+1] = entry
        file:seek("cur",extra+comment)
        if file:seek() > offset+central_size then error("E-Ink ZIP 目录越界") end
    end
    if file:seek() ~= offset+central_size then error("E-Ink ZIP 目录长度不一致") end
    local function extract(entry)
        if opt and type(opt.yield) == "function" then opt.yield("images") end
        file:seek("set",entry.offset)
        local h = file:read(30) or ""
        if #h ~= 30 or h:sub(1,4) ~= "PK\003\004" or le(h,7,2) ~= entry.flags or le(h,9,2) ~= entry.method then
            error("E-Ink ZIP 本地目录无效")
        end
        local n, extra = le(h,27,2), le(h,29,2)
        if file:read(n) ~= entry.name or entry.offset+30+n+extra+entry.compressed > offset then error("E-Ink ZIP 条目越界") end
        file:seek("cur",extra)
        local data = entry.compressed > 0 and file:read(entry.compressed) or ""
        if not data or #data ~= entry.compressed then error("E-Ink ZIP 正文已截断") end
        if bit.band(entry.flags,1) ~= 0 then
            local check = bit.band(entry.flags,8) ~= 0 and math.floor(le(h,11,2)/256) or math.floor(entry.crc/16777216)
            data = decrypt(data,password,check)
        end
        if entry.method == 8 then data = Crypto.inflate(data,entry.size)
        elseif entry.method ~= 0 then error("E-Ink ZIP 压缩方式不支持") end
        if #data ~= entry.size or crc32(data) ~= bit.tobit(entry.crc) then error("E-Ink ZIP 内容校验失败") end
        return data
    end
    local bodies, styles, images, manifest = {}, {}, {}, nil
    for _, entry in ipairs(entries) do
        local name = entry.name:lower()
        local base = name:match("([^/]+)$") or ""
        if base=="info.txt" then
            if manifest then error("E-Ink 章节清单重复") end
            manifest=entry
        elseif name:match("%.x?html?$") or name:match("%.txt$") or (base ~= "" and not base:find(".",1,true)) then
            bodies[#bodies+1] = {entry=entry,text=not name:match("%.x?html?$")}
        elseif name:match("%.css$") then
            styles[#styles+1] = extract(entry)
        elseif opt.images ~= false and name:match("%.png$") then
            images[#images+1] = entry
        elseif opt.images ~= false and (name:match("%.jpe?g$") or name:match("%.gif$") or name:match("%.webp$") or name:match("%.svg$")) then
            images[#images+1] = entry
        end
    end
    local ordered
    if manifest then
        local ok,info=pcall(Json.decode,extract(manifest))
        if not ok or type(info)~="table" then error("E-Ink 章节清单无法解析") end
        if type(info.chapters)=="table" then
            local chapter
            for _,row in ipairs(info.chapters) do
                if type(row)=="table" and (tostring(row.chapterUid)==tostring(opt.chapter_uid)
                    or (opt.chapter_uid==nil and #info.chapters==1)) then
                    if chapter then error("E-Ink 章节清单重复章节") end
                    chapter=row
                end
            end
            if not chapter or type(chapter.files)~="table" or #chapter.files<1 then error("E-Ink 章节清单未返回当前章节") end
            ordered={}
            local used={}
            for _,name in ipairs(chapter.files) do
                local selected
                for _,body in ipairs(bodies) do if type(name)=="string" and body.entry==names[name] then selected=body; break end end
                if not selected or used[name] then error("E-Ink 章节清单文件缺失或重复") end
                used[name]=true
                ordered[#ordered+1]=selected
            end
        end
    end
    if not ordered then
        if #bodies==1 then ordered=bodies
        else
            -- Chapter 0 supplies shared resources. Older packages without a
            -- manifest can also include its HTML alongside the requested UID.
            for _,body in ipairs(bodies) do
                local base=body.entry.name:match("([^/]+)$") or ""
                local stem=base:gsub("%.[^.]+$","")
                if opt.chapter_uid~=nil and stem==tostring(opt.chapter_uid) then
                    if ordered then error("E-Ink 未返回唯一章节正文") end
                    ordered={body}
                end
            end
            if not ordered then error("E-Ink 未返回唯一章节正文") end
        end
    end
    local parts,total_body={},0
    for _,body in ipairs(ordered) do
        local data=extract(body.entry)
        total_body=total_body+#data
        if data=="" or total_body>MAX_ENTRY or body.text~=ordered[1].text then error("E-Ink 章节清单正文为空或超限") end
        parts[#parts+1]=data
    end
    local body=table.concat(parts,"\n")
    local assets = {}
    for i, entry in ipairs(images) do
        local data = extract(entry)
        local ext,mime = Codec.media(data,entry.name)
        if not tostring(mime):match("^image/") then error("E-Ink 图片格式无效") end
        local path = root.."/native-image-"..i..ext
        local ok = U.atomic_write(path,data,true)
        if not ok then error("无法保存 E-Ink 章节图片") end
        assets[#assets+1] = {href="images/native-"..i..ext,data_path=path,mime=mime,source=entry.name,_temporary_root=root}
    end
    return ordered[1].text and Codec.text_xhtml(body) or body, table.concat(styles,"\n"), assets
end

function M.read(path, envelope, vid, root, opt)
    local password = Crypto.password(envelope,vid)
    local file = assert(io.open(path,"rb"),"无法读取 E-Ink 章节包")
    local ok,a,b,c = pcall(read_zip,file,password,root,opt or {})
    file:close()
    if not ok then error(a,0) end
    return a,b,c
end
return M
