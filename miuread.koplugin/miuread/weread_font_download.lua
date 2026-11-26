local U=require("miuread.util")
local catalog=require("miuread.weread_font_catalog")
local M={catalog=catalog}
local FONT_LIMIT=24*1024*1024
local plugin_directory=debug.getinfo(1,"S").source:sub(2)
    :gsub("\\","/"):match("^(.*)/miuread/weread_font_download%.lua$")

function M.directory()
    return require("fontlist").fontdir.."/weread"
end

function M.refresh_registry(path)
    local fontlist=require("fontlist")
    fontlist.fontlist={}
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

function M.read_archive(path,font)
    local archive=require("ffi/archiver").Reader:new()
    local ok,result=pcall(function()
        if not archive:open(path) then error("字体下载包无法打开",0) end
        local exact,only,count
        for entry in archive:iterate(true) do
            if entry.index>120 then error("字体下载包条目过多",0) end
            local name=tostring(entry.path or ""):match("([^/\\]+)$") or ""
            if entry.mode=="file" and name:lower():match("%.[ot]tf$") then
                local size=tonumber(entry.size) or 0
                if size<12 or size>FONT_LIMIT then error("字体文件大小异常",0) end
                local candidate={index=entry.index,size=size}
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
        local data=archive:extractToMemory(wanted.index)
        if type(data)~="string" or #data~=wanted.size or not valid_header(data) then
            error("字体文件校验失败",0)
        end
        return data
    end)
    archive:close()
    if not ok then error(result,0) end
    return result
end

function M.install(http,index)
    local font=catalog[index]
    if not font or index==1 then error("请选择可安装的字体",0) end
    local directory=M.directory()
    if not U.mkdir(directory) then error("无法创建 KOReader 字体目录",0) end
    local filename=directory.."/"..font.file
    if U.file_exists(filename) then return filename end
    local free=U.free_space(directory)
    if free and free<48*1024*1024 then error("剩余空间不足，无法安装字体",0) end
    local stem=directory.."/.miuread-"..tostring(os.time()).."-"..tostring(math.random(100000,999999))
    local packed,stage=stem..".zip.part",stem..".font.part"
    local ok,err=pcall(function()
        local data
        if font.url then
            http:download_to_file(font.url,packed,{auth=false,require_verified_tls=true,redirects=0,retries=1,timeout={8,40},
                max_response_bytes=40*1024*1024})
            data=M.read_archive(packed,font)
        else
            data=plugin_directory and U.read_file(plugin_directory.."/resources/weread-reader-serif.otf",true)
        end
        if not valid_header(data) or #data>FONT_LIMIT or not U.atomic_write(stage,data,true) then
            error("无法保存有效的字体文件",0)
        end
        local loaded,face=pcall(require("ffi/freetype").newFaceSize,stage,16,0)
        if not loaded or not face then error("KOReader 无法读取这份字体",0) end
        if not U.file_exists(filename) and not os.rename(stage,filename) then error("无法安装字体",0) end
    end)
    os.remove(packed)
    os.remove(stage)
    if not ok then error(err,0) end
    return filename
end

return M
