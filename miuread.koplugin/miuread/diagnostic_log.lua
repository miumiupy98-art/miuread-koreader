-- Bounded, shared diagnostics for foreground and background operations.
-- Callers supply classifications, never request bodies, URLs or credentials.
local logger=require("logger")
local ok_socket,socket=pcall(require,"socket")
local M={MAX_BYTES=256*1024}
local fields={"operation","phase","channel","outcome","reason","elapsed_ms","code","status",
    "wait_seconds","local_cooldown","native_stage","native_chapters","web_chapters",
    "native_annotations","web_annotations","native_translation","web_translation","failure_file","failure_line",
    "book_id","batch_id","source","seconds","rows","source_rows","hours","start_time","end_time",
    "chapter_uid","chapter_idx","chapter_offset","cloud_seconds","cloud_delta","position_unchanged",
    "token_source","feature_token_present","feature_token_type","config_token_present",
    "risk","book_version","book_version_source"}

function M.now()
    return ok_socket and type(socket.gettime)=="function" and socket.gettime() or os.time()
end
local function log_path(store)
    local root=tostring(store and store.data_dir or "")
    if root=="" then return nil end
    return root.."/miuread.log"
end
local function append(path,line)
    local file=io.open(path,"rb")
    local size=file and file:seek("end") or 0
    if file then file:close() end
    if size+#line>M.MAX_BYTES then
        os.remove(path..".1")
        if not os.rename(path,path..".1") then return end
    end
    file=io.open(path,"ab")
    if file then file:write(line); file:close() end
end
function M.record(store,value)
    local parts={os.date("%Y-%m-%dT%H:%M:%S")}
    for _,key in ipairs(fields) do
        local item=value[key]
        if type(item)=="number" and item==item and item~=math.huge and item~=-math.huge then
            parts[#parts+1]=key.."="..tostring(item)
        elseif type(item)=="boolean" then
            parts[#parts+1]=key.."="..tostring(item)
        elseif type(item)=="string" and #item<=64 and item:match("^[%w_.%-]+$") then
            parts[#parts+1]=key.."="..item
        end
    end
    local line=table.concat(parts," ")
    local write=(value.outcome=="error" or value.outcome=="rate_limited") and logger.warn or logger.info
    if type(write)=="function" then pcall(write,"[MiuRead][Operation]",line) end
    local path=log_path(store)
    if path then pcall(append,path,line.."\n") end
end
function M.export(store)
    local path=log_path(store)
    if not path then return nil,"暂无可导出的运行日志。" end
    local U=require("miuread.util")
    local parts={}
    for _,source in ipairs({path..".1",path}) do
        local file=io.open(source,"rb")
        if file then
            local size=file:seek("end") or 0
            file:seek("set",math.max(0,size-M.MAX_BYTES))
            parts[#parts+1]=file:read("*a") or ""
            file:close()
        end
    end
    if #parts==0 then return nil,"暂无可导出的运行日志，请执行相关操作后重试。" end
    local output=store:books_root().."/miuread-diagnostics-"..os.date("%Y%m%d-%H%M%S")..".log"
    local ok,err=U.atomic_write(output,table.concat(parts),true)
    if not ok then return nil,"无法导出运行日志："..tostring(err) end
    return output
end
return M
