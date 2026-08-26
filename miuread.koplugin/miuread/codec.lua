local bit=require("bit")
local D=require("miuread.digests")
local Util=require("miuread.util")
local Codec={}
local alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function Codec.b64decode(data)
    local s=tostring(data or ""):gsub("-","+"):gsub("_","/"):gsub("[^A-Za-z0-9%+/%=]","")
    if #s % 4 ~= 0 then s = s .. string.rep("=", 4 - (#s % 4)) end
    local out={}
    local function value(ch)
        if ch == "=" or ch == "" then return 0 end
        local i=alphabet:find(ch,1,true)
        return i and (i-1) or 0
    end
    for i=1,#s,4 do
        local c1,c2,c3,c4=s:sub(i,i),s:sub(i+1,i+1),s:sub(i+2,i+2),s:sub(i+3,i+3)
        local n=value(c1)*262144+value(c2)*4096+value(c3)*64+value(c4)
        out[#out+1]=string.char(math.floor(n/65536)%256)
        if c3~="=" then out[#out+1]=string.char(math.floor(n/256)%256) end
        if c4~="=" then out[#out+1]=string.char(n%256) end
    end
    return table.concat(out)
end

function Codec.b64encode(data)
    local s = tostring(data or "")
    local out = {}
    for i = 1, #s, 3 do
        local a = s:byte(i) or 0
        local b = s:byte(i + 1) or 0
        local c = s:byte(i + 2) or 0
        local n = a * 65536 + b * 256 + c
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = alphabet:sub(c1 + 1, c1 + 1)
        out[#out + 1] = alphabet:sub(c2 + 1, c2 + 1)
        if i + 1 <= #s then
            out[#out + 1] = alphabet:sub(c3 + 1, c3 + 1)
        else
            out[#out + 1] = "="
        end
        if i + 2 <= #s then
            out[#out + 1] = alphabet:sub(c4 + 1, c4 + 1)
        else
            out[#out + 1] = "="
        end
    end
    return table.concat(out)
end

local function positions(s)
    local n=#s; if n<4 then return {} elseif n<11 then return {0,2} end
    local take=math.min(4,math.floor((n+9)/10)); local pieces={}
    for i=n,n-take+1,-1 do
        local x=s:byte(i); local b=""; repeat b=tostring(x%2)..b; x=math.floor(x/2) until x==0
        pieces[#pieces+1]=tostring(tonumber(b,4) or 0)
    end
    local t=table.concat(pieces); local mod=n-take-2; local step=#tostring(mod); local out={}; local i=1
    while #out<10 and i+step-1<#t do
        out[#out+1]=(tonumber(t:sub(i,i+step-1)) or 0)%mod
        if i+1<=#t then out[#out+1]=(tonumber(t:sub(i+1,math.min(i+step,#t))) or 0)%mod end
        i=i+step
    end
    return out
end
local function unswap(s,p)
    local c={}; for i=1,#s do c[i]=s:sub(i,i) end
    for i=#p,1,-2 do
        local a=p[i]+2; local b=p[i-1]+2; c[a],c[b]=c[b],c[a]; a=a-1; b=b-1; c[a],c[b]=c[b],c[a]
    end
    return table.concat(c)
end
function Codec.shard_body(raw)
    raw=tostring(raw or ""); if #raw<=32 then return "" end
    local sum,body=raw:sub(1,32),raw:sub(33); if D.md5(body):upper()~=sum:upper() then error("chapter checksum mismatch") end
    return body
end
local function lua_decode_parts(parts)
    local body={}
    for _,v in ipairs(parts or {}) do body[#body+1]=Codec.shard_body(v) end
    local s=table.concat(body)
    if s=="" then return "" end
    s=s:sub(2)
    return Codec.b64decode(unswap(s,positions(s)))
end

-- Native decoding is an optional accelerator only. The existing Lua path
-- remains authoritative and is used whenever the current device/library is
-- unsupported, unavailable, or fails at runtime.
local native_state={checked=false,ffi=nil,lib=nil,platform=nil,reason="not checked"}
local native_logger

local function native_log(level,...)
    if native_logger==false then return end
    if native_logger==nil then
        local ok,value=pcall(require,"logger")
        native_logger=ok and value or false
    end
    local fn=native_logger and native_logger[level]
    if type(fn)=="function" then pcall(fn,"[MiuRead][CodecNative]",...) end
end

local function device_flag(Device,name)
    local value=Device and Device[name]
    if type(value)=="function" then
        local ok,result=pcall(value,Device)
        return ok and result==true
    end
    return value==true
end

local function kindle_platform(Device)
    local ota
    if type(Device.ota_model)=="string" and Device.ota_model~="" then
        ota=Device.ota_model
    elseif type(Device.otaModel)=="function" then
        local ok,value=pcall(Device.otaModel,Device)
        if ok then ota=value end
    end
    local by_ota={
        ["kindle-legacy"]="kindle",
        ["kindle"]="kindle5",
        ["kindlepw2"]="kindlepw2",
        ["kindlehf"]="kindlehf",
    }
    if by_ota[ota] then return by_ota[ota] end

    -- Only use model fallbacks that are unambiguous. Unknown/new models stay
    -- on Lua rather than guessing an ABI.
    local model=tostring(Device.model or "")
    if model=="Kindle2" or model=="KindleDXG" or model=="Kindle3" then return "kindle" end
    if model=="Kindle4" or model=="KindleTouch" or model=="KindlePaperWhite" then return "kindle5" end
    if model=="KindlePaperWhite2" then return "kindlepw2" end
    return nil
end

local function native_platform(ffi)
    local os_name=(jit and jit.os) or ffi.os or ""
    if os_name=="OSX" then return "osx" end

    local ok,Device=pcall(require,"device")
    if not ok or not Device then return nil,"device module unavailable" end
    if device_flag(Device,"isSDL") then return nil,"desktop platform unsupported" end
    if device_flag(Device,"isKobo") then return "kobo" end
    if device_flag(Device,"isCervantes") then return "cervantes" end
    if device_flag(Device,"isKindle") then
        local platform=kindle_platform(Device)
        if platform then return platform end
        return nil,"kindle ABI could not be identified safely"
    end
    return nil,"native decoder not provided for this platform"
end

local function plugin_dir_from_source()
    local info=debug.getinfo(1,"S")
    local source=tostring(info and info.source or "")
    if source:sub(1,1)=="@" then source=source:sub(2) end
    return source:match("^(.-)/miuread/codec%.lua$")
end

local function disable_native(reason)
    native_state.lib=nil
    native_state.reason=tostring(reason or "native disabled")
    native_log("warn",native_state.reason)
end

local function ensure_native()
    if native_state.checked then return native_state.lib end
    native_state.checked=true

    local ok_ffi,ffi=pcall(require,"ffi")
    if not ok_ffi or not ffi then
        native_state.reason="ffi unavailable; using Lua"
        native_log("info",native_state.reason)
        return nil
    end
    native_state.ffi=ffi

    local ok_cdef,cdef_error=pcall(function()
        ffi.cdef[[
            char* miucodec_shard_body(const char* raw, int raw_len, int* out_len);
            char* miucodec_b64decode(const char* input, int input_len, int* out_len);
            void  miucodec_free(void* ptr);
        ]]
    end)
    if not ok_cdef then
        native_state.reason="ffi declarations unavailable: "..tostring(cdef_error)
        native_log("warn",native_state.reason)
        return nil
    end

    local platform,platform_reason=native_platform(ffi)
    native_state.platform=platform
    if not platform then
        native_state.reason=platform_reason or "unsupported platform"
        native_log("info",native_state.reason)
        return nil
    end

    local plugin_dir=plugin_dir_from_source()
    if not plugin_dir or plugin_dir=="" then
        native_state.reason="plugin directory unavailable; using Lua"
        native_log("warn",native_state.reason)
        return nil
    end
    local extension=platform=="osx" and "dylib" or "so"
    local path=plugin_dir.."/libs/"..platform.."/libmiucodec."..extension
    local probe=io.open(path,"rb")
    if not probe then
        native_state.reason="native library missing for "..platform.."; using Lua"
        native_log("info",native_state.reason)
        return nil
    end
    probe:close()

    local ok_load,lib=pcall(ffi.load,path)
    if not ok_load or not lib then
        native_state.reason="native library failed to load for "..platform..": "..tostring(lib)
        native_log("warn",native_state.reason)
        return nil
    end
    native_state.lib=lib
    native_state.reason="loaded"
    native_log("info","enabled",platform)
    return lib
end

local function native_decode_parts(parts)
    local ffi=native_state.ffi
    local lib=native_state.lib
    local body={}

    -- Keep checksum handling identical to the established Lua path, but do the
    -- expensive MD5 work in the native library. A failed native validation is
    -- handed back to Lua so the existing `chapter checksum mismatch` behavior
    -- remains unchanged.
    for i=1,#parts do
        local raw=tostring(parts[i] or "")
        if #raw<=32 then
            body[#body+1]=""
        else
            local out_len=ffi.new("int[1]")
            local ptr=lib.miucodec_shard_body(raw,#raw,out_len)
            if ptr==nil then error("native shard validation returned null") end
            local length=tonumber(out_len[0]) or 0
            if length<=0 then
                lib.miucodec_free(ptr)
                return nil,"invalid-shard"
            end
            body[#body+1]=ffi.string(ptr,length)
            lib.miucodec_free(ptr)
        end
    end

    local s=table.concat(body)
    if s=="" then return "" end
    s=s:sub(2)

    -- Reproduce the original Lua swap order exactly in a mutable FFI buffer.
    -- The PR's combined C++ decode routine has a boundary difference in its
    -- position loop, so it is intentionally not called here.
    local length=#s
    local buffer=ffi.new("char[?]",math.max(1,length))
    if length>0 then ffi.copy(buffer,s,length) end
    local p=positions(s)
    for i=#p,1,-2 do
        local a=p[i]+1
        local b=p[i-1]+1
        local tmp=buffer[a]
        buffer[a]=buffer[b]
        buffer[b]=tmp
        a=a-1
        b=b-1
        tmp=buffer[a]
        buffer[a]=buffer[b]
        buffer[b]=tmp
    end

    local decoded_len=ffi.new("int[1]")
    local decoded=lib.miucodec_b64decode(buffer,length,decoded_len)
    if decoded==nil then error("native base64 decode returned null") end
    local decoded_length=tonumber(decoded_len[0]) or 0
    if decoded_length<0 then
        lib.miucodec_free(decoded)
        error("native base64 decode returned invalid length")
    end
    local result=ffi.string(decoded,decoded_length)
    lib.miucodec_free(decoded)
    return result
end

function Codec.native_status()
    return {
        checked=native_state.checked,
        available=native_state.lib~=nil,
        platform=native_state.platform,
        reason=native_state.reason,
    }
end

function Codec.prewarm_native()
    -- Load the optional decoder while the Reader is already idle instead of
    -- paying the first ffi.load cost during a Home/close progress snapshot.
    -- This performs no chapter decode, network access or persistent write.
    local lib=ensure_native()
    return lib~=nil,Codec.native_status()
end

function Codec.decode_parts(parts)
    parts=parts or {}
    if not ensure_native() then return lua_decode_parts(parts) end

    local ok,result,detail=pcall(native_decode_parts,parts)
    if not ok then
        disable_native("runtime failure; using Lua: "..tostring(result))
        return lua_decode_parts(parts)
    end
    if result==nil and detail=="invalid-shard" then
        -- Let the existing Lua implementation make the final decision and
        -- preserve the established `chapter checksum mismatch` behavior.
        return lua_decode_parts(parts)
    end
    if result==nil then
        disable_native("native decode returned no result; using Lua")
        return lua_decode_parts(parts)
    end
    return result
end
function Codec.text_xhtml(text)
    local out={}
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local normalized=Util.trim(line); if normalized~="" then out[#out+1]="<p>"..Util.xml(normalized).."</p>" end
    end
    return table.concat(out,"\n")
end
-- WeRead EPUB chapters may decode to multiple concatenated XHTML documents.
-- Keep every body fragment in source order; the first body can be only a
-- title shell while the remaining bodies contain the actual chapter text.
function Codec.body_fragment(html)
    local source=tostring(html or "")
    local bodies={}
    local remaining=source
    while remaining~="" do
        local lower=remaining:lower()
        local body_start=lower:find("<body",1,true)
        if not body_start then break end
        local body_open_end=remaining:find(">",body_start,true)
        if not body_open_end then break end
        local body_close=lower:find("</body>",body_open_end,true)
        if not body_close then
            bodies[#bodies+1]=remaining:sub(body_open_end+1)
            break
        end
        bodies[#bodies+1]=remaining:sub(body_open_end+1,body_close-1)
        remaining=remaining:sub(body_close+7)
    end
    if #bodies>0 then return table.concat(bodies,"\n"),#bodies end
    source=source:gsub("<%?xml.-%?>","")
    source=source:gsub("<!DOCTYPE.-%>","")
    return source,0
end
function Codec.body(html)
    local fragment=Codec.body_fragment(html)
    return fragment
end
function Codec.mp_body(html)
    local s=tostring(html or ""):gsub("<script[%s%S]-</script>",""):gsub("<style[%s%S]-</style>","")
    local start=s:find('id="js_content"',1,true) or s:find("class=\"rich_media_content",1,true)
    if not start then return Codec.body(s) end
    start=s:find(">",start,true); if not start then return Codec.body(s) end
    local tail=s:sub(start+1); local stop=tail:find("</div>",1,true); return stop and tail:sub(1,stop-1) or tail
end
local function tar_text(value)
    return tostring(value or ""):match("^[^%z]*") or ""
end
local function tar_octal(value)
    value = tar_text(value):gsub("^%s+", ""):gsub("%s+$", "")
    return tonumber(value, 8) or 0
end
local function tar_pax_path(body)
    for line in tostring(body or ""):gmatch("[^\n]+") do
        local path = line:match("%d+ path=(.*)")
        if path and path ~= "" then return path end
    end
end
function Codec.tar(data)
    local out, p = {}, 1
    local long_name, pax_name
    data = tostring(data or "")
    while p + 511 <= #data do
        local h = data:sub(p, p + 511)
        if h:gsub("\0", "") == "" then break end
        local name = tar_text(h:sub(1, 100))
        local prefix = tar_text(h:sub(346, 500))
        if prefix ~= "" then name = prefix .. "/" .. name end
        local size = tar_octal(h:sub(125, 136))
        local kind = h:sub(157, 157)
        local body = data:sub(p + 512, p + 511 + size)
        if kind == "L" then
            long_name = tar_text(body)
        elseif kind == "x" then
            pax_name = tar_pax_path(body)
        elseif kind == "0" or kind == "\0" or kind == "" then
            local final_name = pax_name or long_name or name
            if final_name ~= "" and size > 0 then out[final_name] = body end
            long_name, pax_name = nil, nil
        end
        p = p + 512 + math.ceil(size / 512) * 512
    end
    return out
end
-- Stream a tar archive from disk and extract each regular entry into a
-- numbered temporary file. This keeps peak Lua memory bounded by one small
-- chunk instead of materializing both the archive and every image at once.
function Codec.tar_file(path,destination,on_progress)
    path=tostring(path or "")
    destination=tostring(destination or "")
    if path=="" or destination=="" then return nil,"tar path/destination missing" end
    if not Util.mkdir(destination) then return nil,"cannot create tar destination" end
    local input,open_error=io.open(path,"rb")
    if not input then return nil,open_error end
    local out={}
    local long_name,pax_name
    local index,total_read,completed=0,0,0
    local chunk_size=128*1024

    local function close_with_error(message)
        input:close()
        Util.remove_tree(destination)
        return nil,message,{partial=false,error=message,entries=completed,bytes=total_read}
    end
    local function close_partial(message)
        input:close()
        return out,nil,{partial=true,error=message,entries=completed,bytes=total_read}
    end
    local function truncated(message)
        -- Preserve fully extracted entries when only the tail/current entry is
        -- truncated. The caller still validates every required image reference before the
        -- chapter is accepted, so partial extraction cannot silently lose an
        -- image that is actually required.
        if completed>0 then return close_partial(message) end
        return close_with_error(message)
    end
    local function read_exact(size)
        if size<=0 then return "" end
        local data=input:read(size)
        if type(data)~="string" or #data~=size then return nil,"truncated tar entry" end
        total_read=total_read+#data
        return data
    end
    local function skip(size)
        if size<=0 then return true end
        local moved=input:seek("cur",size)
        if moved then total_read=total_read+size; return true end
        local remaining=size
        while remaining>0 do
            local data=input:read(math.min(chunk_size,remaining))
            if not data or #data==0 then return nil,"truncated tar padding" end
            remaining=remaining-#data
            total_read=total_read+#data
        end
        return true
    end
    local function report()
        if type(on_progress)=="function" then pcall(on_progress,total_read,index) end
    end

    while true do
        local header=input:read(512)
        if not header then break end
        if #header~=512 then return truncated("truncated tar header") end
        total_read=total_read+512
        if header:gsub("\0","")=="" then break end
        local name=tar_text(header:sub(1,100))
        local prefix=tar_text(header:sub(346,500))
        if prefix~="" then name=prefix.."/"..name end
        local size=tar_octal(header:sub(125,136))
        local kind=header:sub(157,157)
        local padded=math.ceil(size/512)*512

        if kind=="L" or kind=="x" then
            local body,read_error=read_exact(size)
            if not body then return truncated(read_error) end
            if kind=="L" then long_name=tar_text(body) else pax_name=tar_pax_path(body) end
            local ok,skip_error=skip(padded-size)
            if not ok then return truncated(skip_error) end
        elseif kind=="0" or kind=="\0" or kind=="" then
            local final_name=pax_name or long_name or name
            index=index+1
            local target=destination.."/entry-"..string.format("%05d",index)..".bin"
            local output,write_open_error=io.open(target,"wb")
            if not output then return close_with_error(write_open_error or "cannot create tar entry") end
            local remaining=size
            local failed
            while remaining>0 do
                local data=input:read(math.min(chunk_size,remaining))
                if not data or #data==0 then failed="truncated tar entry"; break end
                total_read=total_read+#data
                local wrote,write_error=output:write(data)
                if not wrote then failed=write_error or "tar entry write failed"; break end
                remaining=remaining-#data
                report()
            end
            local flushed,flush_error=output:flush()
            output:close()
            if not failed and flushed==nil then failed=flush_error or "tar entry flush failed" end
            if failed then os.remove(target); return truncated(failed) end
            local ok,skip_error=skip(padded-size)
            if not ok then os.remove(target); return truncated(skip_error) end
            if final_name~="" and size>0 then
                out[final_name]={path=target,size=size}
                completed=completed+1
            else
                os.remove(target)
            end
            long_name,pax_name=nil,nil
            report()
        else
            local ok,skip_error=skip(padded)
            if not ok then return truncated(skip_error) end
            report()
        end
    end
    input:close()
    return out,nil,{partial=false,entries=completed,bytes=total_read}
end

function Codec.media(data, hint)
    data = tostring(data or "")
    if data:sub(1,8)=="\137PNG\r\n\26\n" then return ".png","image/png" end
    if data:sub(1,3)=="\255\216\255" then return ".jpg","image/jpeg" end
    if data:sub(1,6)=="GIF87a" or data:sub(1,6)=="GIF89a" then return ".gif","image/gif" end
    if data:sub(1,4)=="RIFF" and data:sub(9,12)=="WEBP" then return ".webp","image/webp" end
    if data:sub(1,2)=="BM" then return ".bmp","image/bmp" end
    local head = data:sub(1,512):lower()
    if head:find("<svg", 1, true) then return ".svg","image/svg+xml" end
    if data:sub(5,12)=="ftypavif" or data:sub(5,12)=="ftypavis" then return ".avif","image/avif" end
    local clean_hint = tostring(hint or ""):lower():match("^[^%?#]+") or ""
    local ext = clean_hint:match("%.([%w]+)$")
    local by_ext = {
        png={".png","image/png"}, jpg={".jpg","image/jpeg"}, jpeg={".jpg","image/jpeg"},
        gif={".gif","image/gif"}, webp={".webp","image/webp"}, svg={".svg","image/svg+xml"},
        bmp={".bmp","image/bmp"}, avif={".avif","image/avif"},
    }
    if ext and by_ext[ext] then return by_ext[ext][1], by_ext[ext][2] end
    return ".bin","application/octet-stream"
end
function Codec.media_file(path,hint)
    local file=io.open(tostring(path or ""),"rb")
    if not file then return ".bin","application/octet-stream" end
    local head=file:read(512) or ""
    file:close()
    return Codec.media(head,hint)
end
return Codec
