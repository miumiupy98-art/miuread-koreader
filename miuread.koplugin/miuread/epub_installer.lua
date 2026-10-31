local Json = require("miuread.json")
local U = require("miuread.util")
local ResourceRefs = require("miuread.resource_refs")
local lfs = require("libs/libkoreader-lfs")

local Installer = {}

local function le16(data,position)
    local a,b=data:byte(position,position+1)
    if not a or not b then return nil end
    return a+b*256
end
local function le32(data,position)
    local a,b,c,d=data:byte(position,position+3)
    if not a or not b or not c or not d then return nil end
    return a+b*256+c*65536+d*16777216
end

local function directory(path)
    local file,err=io.open(path,"rb")
    if not file then return nil,err or "EPUB 文件不存在" end
    local size=file:seek("end") or 0
    if size<512 then file:close(); return nil,"EPUB 文件为空或过小" end
    local tail_size=math.min(size,65558)
    file:seek("set",size-tail_size)
    local tail=file:read(tail_size) or ""
    local marker,at=nil,1
    while true do
        local found=tail:find("PK\005\006",at,true)
        if not found then break end
        marker=found; at=found+1
    end
    if not marker then file:close(); return nil,"EPUB ZIP 目录结束标记缺失" end
    local count=le16(tail,marker+10)
    local central_size=le32(tail,marker+12)
    local central_offset=le32(tail,marker+16)
    if not count or not central_size or not central_offset or central_offset+central_size>size then
        file:close(); return nil,"EPUB ZIP 中央目录无效"
    end
    file:seek("set",central_offset)
    local entries={}
    for _=1,count do
        local header=file:read(46)
        if not header or #header~=46 or header:sub(1,4)~="PK\001\002" then
            file:close(); return nil,"EPUB ZIP 中央目录条目损坏"
        end
        local method=le16(header,11) or -1
        local compressed=le32(header,21) or 0
        local uncompressed=le32(header,25) or 0
        local name_length=le16(header,29) or 0
        local extra_length=le16(header,31) or 0
        local comment_length=le16(header,33) or 0
        local local_offset=le32(header,43)
        local name=file:read(name_length)
        if not name or not local_offset then file:close(); return nil,"EPUB ZIP 条目信息损坏" end
        entries[name]={method=method,compressed=compressed,uncompressed=uncompressed,offset=local_offset}
        if extra_length+comment_length>0 then file:seek("cur",extra_length+comment_length) end
    end
    file:close()
    return entries,size
end

local function read_entry(path,entry)
    if not entry or entry.method~=0 then return nil,"EPUB 元数据条目不是未压缩格式" end
    local file,err=io.open(path,"rb")
    if not file then return nil,err end
    file:seek("set",entry.offset)
    local header=file:read(30)
    if not header or #header~=30 or header:sub(1,4)~="PK\003\004" then file:close(); return nil,"EPUB 本地条目损坏" end
    local name_length=le16(header,27) or 0
    local extra_length=le16(header,29) or 0
    file:seek("cur",name_length+extra_length)
    local data=file:read(entry.uncompressed)
    file:close()
    if not data or #data~=entry.uncompressed then return nil,"EPUB 元数据读取不完整" end
    return data
end


local function read_entry_prefix(path,entry,limit)
    if not entry or entry.method~=0 then return nil,"EPUB 资源条目不是未压缩格式" end
    local file,err=io.open(path,"rb")
    if not file then return nil,err end
    file:seek("set",entry.offset)
    local header=file:read(30)
    if not header or #header~=30 or header:sub(1,4)~="PK\003\004" then file:close(); return nil,"EPUB 本地资源条目损坏" end
    local name_length=le16(header,27) or 0
    local extra_length=le16(header,29) or 0
    file:seek("cur",name_length+extra_length)
    local length=math.min(tonumber(limit) or 64,tonumber(entry.uncompressed) or 0)
    local data=file:read(length)
    file:close()
    if length>0 and (not data or #data~=length) then return nil,"EPUB 资源读取不完整" end
    return data or ""
end

local function decode_entities(value)
    return tostring(value or "")
        :gsub("&amp;","&")
        :gsub("&quot;",'"')
        :gsub("&#39;","'")
        :gsub("&lt;","<")
        :gsub("&gt;",">")
end

local function url_decode(value)
    return tostring(value or ""):gsub("%%(%x%x)",function(hex)
        return string.char(tonumber(hex,16))
    end)
end

local function normalize_path(path)
    path=url_decode(decode_entities(path)):gsub("\\","/")
    path=path:gsub("[?#].*$","")
    local parts={}
    for part in path:gmatch("[^/]+") do
        if part==".." then
            if #parts>0 then table.remove(parts) end
        elseif part~="." and part~="" then
            parts[#parts+1]=part
        end
    end
    return table.concat(parts,"/")
end

local function image_signature_ok(mime,data)
    mime=tostring(mime or ""):lower()
    data=tostring(data or "")
    if mime=="image/jpeg" or mime=="image/jpg" then return data:sub(1,3)=="\255\216\255" end
    if mime=="image/png" then return data:sub(1,8)=="\137PNG\r\n\26\n" end
    if mime=="image/gif" then return data:sub(1,4)=="GIF8" end
    if mime=="image/webp" then return data:sub(1,4)=="RIFF" and data:sub(9,12)=="WEBP" end
    if mime=="image/svg+xml" then return data:lower():find("<svg",1,true)~=nil end
    -- AVIF and future formats are accepted when non-empty; KOReader support
    -- depends on the bundled image library, but the EPUB itself is coherent.
    return mime:match("^image/")~=nil and #data>0
end

local function validate_resources(path,entries,opt)
    local opf,opf_error=read_entry(path,entries["OEBPS/package.opf"])
    if not opf then return nil,opf_error end
    local manifest={}
    local image_assets=0
    for item in opf:gmatch("<[iI][tT][eE][mM][^>]*>") do
        local href=item:match('[hH][rR][eE][fF]%s*=%s*"([^"]+)"')
            or item:match("[hH][rR][eE][fF]%s*=%s*'([^']+)'")
        local mime=item:match('[mM][eE][dD][iI][aA]%-[tT][yY][pP][eE]%s*=%s*"([^"]+)"')
            or item:match("[mM][eE][dD][iI][aA]%-[tT][yY][pP][eE]%s*=%s*'([^']+)'")
        if href then
            local full=normalize_path("OEBPS/"..href)
            manifest[full]=tostring(mime or "")
            local is_cover=item:lower():find("cover%-image")~=nil
            if tostring(mime or ""):lower():match("^image/") and not is_cover then image_assets=image_assets+1 end
        end
    end

    local referenced={}
    local external=0
    local broken={}
    local function inspect_document(name)
        local raw,err=read_entry(path,entries[name])
        if not raw then broken[#broken+1]=name.."（"..tostring(err).."）"; return end
        for _,item in ipairs(ResourceRefs.collect(raw,{css=name=="OEBPS/style.css"})) do
            local target,kind=ResourceRefs.resolve(name,item.value)
            local relevant=item.kind=="image" or (target and tostring(manifest[target] or ""):lower():match("^image/"))
                or ResourceRefs.looks_like_image(item.value)
            if kind=="external" and relevant then
                external=external+1
                if #broken<6 then broken[#broken+1]=name.." 仍引用网络图片："..tostring(item.value) end
            elseif target and relevant and not referenced[target] then
                referenced[target]=true
                local entry=entries[target]
                local mime=manifest[target]
                if not entry then
                    if #broken<6 then broken[#broken+1]=name.." 引用不存在的资源："..target end
                elseif not mime or not tostring(mime):lower():match("^image/") then
                    if #broken<6 then broken[#broken+1]=target.." 未正确登记为图片" end
                elseif tonumber(entry.uncompressed or 0)<=0 then
                    if #broken<6 then broken[#broken+1]=target.." 是空文件" end
                else
                    local prefix,prefix_error=read_entry_prefix(path,entry,256)
                    if not prefix or not image_signature_ok(mime,prefix) then
                        if #broken<6 then broken[#broken+1]=target.." 图片格式无效"..(prefix_error and "："..prefix_error or "") end
                    end
                end
            end
        end
    end

    local documents={}
    for name in pairs(entries) do
        if name:match("^OEBPS/text/.+%.xhtml$") or name=="OEBPS/style.css" then
            documents[#documents+1]=name
        end
    end
    table.sort(documents)
    local total_documents=math.max(1,#documents)
    for index,name in ipairs(documents) do
        inspect_document(name)
        if type(opt and opt.on_progress)=="function" then
            opt.on_progress({phase="validate",current=index,total=total_documents,entry=name})
        end
    end

    local ref_count=0
    for _ in pairs(referenced) do ref_count=ref_count+1 end
    local summary=type(opt and opt.image_summary)=="table" and opt.image_summary or {}
    local missing=tonumber(summary.required_missing)
    if missing==nil then missing=tonumber(summary.missing or 0) or 0 end
    if external>0 then return nil,"EPUB 正文仍包含网络图片引用；"..table.concat(broken,"；") end
    if #broken>0 then return nil,"EPUB 图片引用或文件无效；"..table.concat(broken,"；") end
    if missing>0 then return nil,"EPUB 仍有 "..tostring(missing).." 个必需正文图片资源缺失" end
    -- Zero final image references is valid for text-only books and for books
    -- whose optional footnote/decorative image markers were converted to text.
    -- The downloader prunes orphan assets before building the OPF; validation
    -- only checks resources that the final document actually references.
    return {references=ref_count,assets=image_assets,external=external,broken=0,
        orphans=math.max(0,image_assets-ref_count)}
end

local function uid_set(chapters)
    local set={}
    for _,chapter in ipairs(chapters or {}) do
        if chapter.structural~=true then
            local uid=tostring(chapter.uid or chapter.chapter_uid or "")
            if uid~="" then set[uid]=true end
        end
    end
    return set
end

function Installer.inspect(path)
    local entries,size=directory(path)
    if not entries then return nil,size end
    local required={"mimetype","META-INF/container.xml","OEBPS/package.opf","OEBPS/nav.xhtml","OEBPS/toc.ncx","OEBPS/style.css","OEBPS/miuread.json"}
    for _,name in ipairs(required) do if not entries[name] then return nil,"EPUB 缺少必要文件："..name end end
    local mimetype_entry=entries["mimetype"]
    if mimetype_entry.offset~=0 or mimetype_entry.method~=0 then return nil,"EPUB mimetype 条目无效" end
    local mimetype,mimetype_error=read_entry(path,mimetype_entry)
    if not mimetype or mimetype~="application/epub+zip" then
        return nil,mimetype_error or "EPUB mimetype 内容无效"
    end
    local raw,read_error=read_entry(path,entries["OEBPS/miuread.json"])
    if not raw then return nil,read_error end
    local ok,meta=pcall(Json.decode,raw)
    if not ok or type(meta)~="table" then return nil,"EPUB 书籍信息损坏" end
    local chapter_count=0
    while entries[string.format("OEBPS/text/chapter-%04d.xhtml",chapter_count+1)] do chapter_count=chapter_count+1 end
    if chapter_count<=0 then return nil,"EPUB 没有正文页面" end
    if type(meta.chapters)=="table" then
        if #meta.chapters~=chapter_count then return nil,"EPUB 元数据章节数量不一致" end
        for index=1,#meta.chapters do
            if not entries[string.format("OEBPS/text/chapter-%04d.xhtml",index)] then
                return nil,"EPUB 正文章节文件不完整"
            end
        end
    end
    meta._chapter_count=chapter_count
    meta._file_size=size
    return meta,entries
end

-- Public bounded one-chapter extractor for pre-existing generated MiuRead
-- EPUBs. No write path, no extraction of the whole archive.
function Installer.read_chapter_text(path,index,meta,entries)
    if not meta or not entries then
        meta,entries=Installer.inspect(path)
        if not meta then return nil,nil,entries end
    end
    index=math.floor(tonumber(index) or 0)
    if index<1 or index>meta._chapter_count then return nil,nil,"chapter_out_of_range" end
    local entry=entries[string.format("OEBPS/text/chapter-%04d.xhtml",index)]
    if not entry or entry.method~=0 or entry.uncompressed>2*1024*1024 then
        return nil,nil,"chapter_too_large_or_compressed"
    end
    local html,err=read_entry(path,entry)
    if not html then return nil,nil,err end
    return html,(meta.chapters or {})[index] or {}
end

-- Read generated chapter text one chapter at a time. Translation display
-- inspection must not extract images, rewrite the archive or retain a whole
-- book in memory. Older MiuRead EPUBs use the same stored ZIP entry format.
function Installer.visit_chapter_text(path, callback)
    local meta, entries = Installer.inspect(path)
    if not meta then return nil, entries end
    local bytes = 0
    for index = 1, meta._chapter_count do
        local entry = entries[string.format("OEBPS/text/chapter-%04d.xhtml", index)]
        bytes = bytes + entry.uncompressed
        if entry.uncompressed > 2*1024*1024 or bytes > 64*1024*1024 then
            return nil, "translation_inspection_size_limit"
        end
        local html, err = read_entry(path, entry)
        if not html then return nil, err end
        local accepted, reason = callback(html, index, (meta.chapters or {})[index] or {})
        if not accepted then return nil, reason or "chapter_inspection_failed" end
    end
    return true, meta
end

local function contains_all(new_chapters,old_chapters)
    local new=uid_set(new_chapters)
    for uid in pairs(uid_set(old_chapters)) do if not new[uid] then return nil,uid end end
    return true
end

function Installer.validate(path,opt)
    opt=opt or {}
    local meta,entries=Installer.inspect(path)
    if not meta then return nil,entries end
    if opt.book_id and tostring(meta.book_id or "")~=tostring(opt.book_id) then return nil,"EPUB 书籍身份不一致" end
    if opt.variant and tostring(meta.variant or "")~=tostring(opt.variant) then return nil,"EPUB 版本类型不一致" end
    local expected=opt.chapters
    if type(expected)=="table" then
        if tonumber(meta._chapter_count)~=#expected then return nil,"EPUB 章节数量不一致" end
        local actual=type(meta.chapters)=="table" and meta.chapters or {}
        if #actual~=#expected then return nil,"EPUB 章节清单不完整" end
        for index,chapter in ipairs(expected) do
            if tostring(actual[index] and actual[index].uid or "")~=tostring(chapter.uid or chapter.chapter_uid or "") then
                return nil,"EPUB 章节顺序或身份不一致"
            end
        end
    end
    local previous=opt.previous_chapters
    if type(previous)=="table" and #previous>0 then
        local ok,missing=contains_all(type(meta.chapters)=="table" and meta.chapters or {},previous)
        if not ok then return nil,"新 EPUB 缺少旧版本章节："..tostring(missing) end
    end
    local resource_stats,resource_error=validate_resources(path,entries,opt)
    if not resource_stats then return nil,resource_error end
    meta._image_references=resource_stats.references
    meta._image_assets=resource_stats.assets
    return true,meta
end

local function split_path(path)
    local dir,name=tostring(path or ""):match("^(.*)/([^/]+)$")
    if not dir or dir=="" then return ".",tostring(path or "") end
    return dir,name
end

local function backup_candidates(target)
    local dir,name=split_path(target)
    local out={}
    if lfs and lfs.attributes(dir,"mode")=="directory" then
        local escaped=name:gsub("([^%w])","%%%1")
        local listed,iter,state=pcall(lfs.dir,dir)
        if listed and type(iter)=="function" then
            for item in iter,state do
                if item:match("^"..escaped.."%.miuread%-backup%-%d+%-%d+$")
                    or item:match("^"..escaped.."%.miuread%-old%-%d+%-%d+$") then
                    local path=dir.."/"..item
                    out[#out+1]={path=path,modified=tonumber(lfs.attributes(path,"modification") or 0) or 0}
                end
            end
        end
    end
    table.sort(out,function(a,b) return a.modified>b.modified end)
    return out
end

local function recover_backup(target)
    if U.file_exists(target) then return true end
    for _,candidate in ipairs(backup_candidates(target)) do
        local valid=Installer.inspect(candidate.path)
        if type(valid)=="table" then
            local restored=os.rename(candidate.path,target)
            if restored then return true end
        end
    end
    return false
end

local function unique_backup(target)
    return target..".miuread-backup-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))
end

function Installer.install(source,target,opt)
    opt=opt or {}
    recover_backup(target)
    local valid,meta=Installer.validate(source,opt)
    if not valid then return nil,meta end
    local previous=opt.previous_chapters
    if U.file_exists(target) then
        local old_meta=Installer.inspect(target)
        if type(old_meta)=="table" and tostring(old_meta.book_id or "")~=tostring(meta.book_id or "") then
            return nil,"目标文件属于另一部书"
        end
        if type(old_meta)=="table" and tostring(old_meta.variant or "")~=""
            and tostring(old_meta.variant or "")~=tostring(meta.variant or "") then
            return nil,"目标文件属于另一种下载版本"
        end
        if type(previous)~="table" and type(old_meta)=="table" then previous=old_meta.chapters end
        if type(previous)=="table" and #previous>0 then
            local ok,missing=contains_all(meta.chapters or {},previous)
            if not ok then return nil,"新 EPUB 缺少旧版本章节："..tostring(missing) end
        end
    end
    local backup
    if U.file_exists(target) then
        backup=unique_backup(target)
        local ok,err=os.rename(target,backup)
        if not ok then return nil,"无法保护原 EPUB："..tostring(err) end
    end
    local installed,mode_or_error=U.move_file_safe(source,target,function(candidate)
        return Installer.validate(candidate,opt)
    end)
    if not installed then
        if backup and U.file_exists(backup) then os.rename(backup,target) end
        return nil,mode_or_error
    end
    local checked,check_error=Installer.validate(target,opt)
    if not checked then
        os.remove(target)
        if backup and U.file_exists(backup) then os.rename(backup,target) end
        return nil,"安装后验证失败："..tostring(check_error)
    end
    if backup then os.remove(backup) end
    for _,candidate in ipairs(backup_candidates(target)) do os.remove(candidate.path) end
    return true,mode_or_error
end

function Installer.stage(source,pending,opt)
    opt=opt or {}
    local valid,err=Installer.validate(source,opt)
    if not valid then return nil,err end
    return U.move_file_safe(source,pending,function(candidate) return Installer.validate(candidate,opt) end)
end

return Installer
