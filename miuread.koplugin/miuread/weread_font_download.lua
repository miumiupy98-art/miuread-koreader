local U=require("miuread.util")
local catalog=require("miuread.weread_font_catalog")
local M={catalog=catalog}
local FONT_LIMIT=64*1024*1024
local plugin_directory=debug.getinfo(1,"S").source:sub(2)
    :gsub("\\","/"):match("^(.*)/miuread/weread_font_download%.lua$")

function M.directory()
    return require("fontlist").fontdir.."/weread"
end

function M.preview_path(index)
    if plugin_directory and catalog[index] and index~=1 then
        return plugin_directory.."/resources/weread-font-previews/"..index..".png"
    end
end

function M.face_name(path)
    local fontlist=require("fontlist")
    fontlist:getFontList()
    local files=fontlist.fontinfo or {}
    local relative=path:gsub("^%./","")
    local faces=files[path] or files[relative] or files["./"..relative]
    return faces and faces[1] and faces[1].name
end

function M.refresh_registry(path)
    local fontlist=require("fontlist")
    fontlist.fontlist={}
    fontlist.fontnames={}
    fontlist:getFontList()
    local running=package.loaded["libs/libkoreader-cre"]
    local engine=require("document/credocument"):engineInit()
    if not engine or (running and engine.registerFont(path)==false) then
        error("KOReader 暂未重新加载字体",0)
    end
    local faces=package.loaded["miuread.thought_face_factory"]
    if faces then faces:clearCache() end
end

local function valid_header(value)
    local tag=value and value:sub(1,4)
    return tag=="OTTO" or tag=="\000\001\000\000" or tag=="ttcf" or tag=="true"
end

function M.extract_archive(path,font,stage)
    local archive=require("ffi/archiver").Reader:new()
    local ok,result=pcall(function()
        if not archive:open(path) then error("字体下载包无法打开",0) end
        local exact,only,count
        for entry in archive:iterate(true) do
            if entry.index>120 then error("字体下载包条目过多",0) end
            local name=tostring(entry.path or ""):match("([^/\\]+)$") or ""
            if entry.mode=="file" and name:sub(1,2)~="._" and name:lower():match("%.[ot]tf$") then
                local candidate={index=entry.index,size=tonumber(entry.size) or 0}
                if name:lower()==font.file:lower() then
                    if exact then error("字体下载包有重复文件",0) end
                    exact=candidate
                end
                only=candidate
                count=(count or 0)+1
            end
        end
        if archive.err then error("字体下载包读取失败",0) end
        local wanted=exact or (count==1 and only)
        if not wanted then error("字体下载包缺少对应字体",0) end
        if wanted.size<12 or wanted.size>FONT_LIMIT then error("字体文件大小异常",0) end
        local free=U.free_space(M.directory())
        if free and free<wanted.size then error("剩余空间不足，无法解包字体",0) end
        if not archive:extractToPath(wanted.index,stage) or U.file_size(stage)~=wanted.size then
            error("字体解包失败",0)
        end
    end)
    archive:close()
    if not ok then error(result,0) end
end

function M.temporary_stem()
    return M.directory().."/.miuread-"..os.time().."-"..math.random(100000,999999)
end

function M.clear_temporary(stem)
    if not stem then return end
    os.remove(stem..".zip.part")
    os.remove(stem..".font.part")
end

function M.install(http,index,stem)
    local font=catalog[index]
    if not font or index==1 then error("请选择可安装的字体",0) end
    local directory=M.directory()
    if not U.mkdir(directory) then error("无法创建 KOReader 字体目录",0) end
    local filename=directory.."/"..font.file
    if U.file_exists(filename) then return filename end
    stem=stem or M.temporary_stem()
    local packed,stage=stem..".zip.part",stem..".font.part"
    local ok,err=pcall(function()
        if font.url then
            http:download_to_file(font.url,packed,{auth=false,require_verified_tls=true,redirects=0,retries=1,
                timeout={15,120},max_response_bytes=40*1024*1024,integrity_attempts=1})
            M.extract_archive(packed,font,stage)
        elseif not plugin_directory or not U.copy_file(plugin_directory.."/resources/weread-reader-serif.otf",stage) then
            error("无法保存内置字体",0)
        end
        local file=io.open(stage,"rb")
        local header=file and file:read(4)
        if file then file:close() end
        if not valid_header(header) then error("字体文件校验失败",0) end
        local loaded,face=pcall(require("ffi/freetype").newFaceSize,stage,16,0)
        if not loaded or not face then error("KOReader 无法读取这份字体",0) end
        if not U.file_exists(filename) and not os.rename(stage,filename) then error("无法安装字体",0) end
    end)
    M.clear_temporary(stem)
    if not ok then error(err,0) end
    return filename
end

return M
