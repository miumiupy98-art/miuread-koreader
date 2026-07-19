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
function Codec.decode_parts(parts)
    local body={}; for _,v in ipairs(parts or {}) do body[#body+1]=Codec.shard_body(v) end
    local s=table.concat(body); if s=="" then return "" end
    s=s:sub(2); return Codec.b64decode(unswap(s,positions(s)))
end
function Codec.text_xhtml(text)
    local out={}
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local normalized=Util.trim(line); if normalized~="" then out[#out+1]="<p>"..Util.xml(normalized).."</p>" end
    end
    return table.concat(out,"\n")
end
function Codec.body(html)
    local s=tostring(html or "")
    local b=s:match("<body[^>]*>([%s%S]*)</body>"); return b or s
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
return Codec
