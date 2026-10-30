-- E-Ink 2.1.2 ReportService: hour buckets and time-only BaseBookReadPostBody.
-- Endpoint/auth reference: teng-lin/weread-omni 88bd2e095d7d7ee423eaadf8f40653e72c5be6d4 (MIT).
-- Signature transform adapted from AnkioTomas/moon 43b2181da6eb5285b62114da85e1413d2f8464e4,
-- book.koplugin/source/wechat/app.lua; changed 2026-10-25 for Native batch DTOs
-- (GPL-3.0); see licenses/moon-GPL-3.0.txt and THIRD_PARTY_NOTICES.
local Digest = require("miuread.digests")
local bit = require("bit")
local M = {}
-- E-Ink 2.1.2 classes5.dex: FeatureGuestTokenWrapper passes this public
-- client default to StringFeatureWrapper. Encrypt's empty-feature branch
-- resolves FeatureGuestToken instead of refusing the report. This is a
-- protocol constant, never an account credential or a replacement auth token.
local DEFAULT_GUEST_TOKEN="5ecdcfd7f"

function M.guest_token(feature)
    local map=feature and feature.feature
    if map~=nil and type(map)~="table" then error("reading-time signature feature invalid",0) end
    local value=map and map.guest_token
    if value~=nil and type(value)~="string" then error("reading-time signature token invalid",0) end
    if value and value~="" then return value,"remote" end
    return DEFAULT_GUEST_TOKEN,"client_default"
end

local REMAP = {
    52,202,85,64,29,182,147,198,49,48,41,53,50,167,184,17,
    194,181,22,250,139,177,36,164,16,144,4,233,8,248,59,138,
    156,140,68,249,188,92,105,226,161,218,210,211,117,137,247,30,
    45,80,86,215,114,83,191,34,251,32,15,1,46,69,135,110,
    102,72,242,224,205,254,103,169,67,244,148,81,206,165,74,238,
    19,38,142,204,170,51,20,93,14,57,187,207,145,43,129,77,
    234,153,236,26,44,133,197,217,54,116,75,24,225,241,61,157,
    65,159,180,23,13,214,76,190,220,175,151,40,119,240,98,255,
    113,193,200,39,143,108,104,168,155,230,89,28,27,18,9,152,
    78,63,6,55,0,186,31,10,25,47,201,213,208,87,73,111,
    253,37,228,97,12,66,203,150,100,95,219,173,96,35,141,154,
    109,195,196,94,62,185,146,106,189,91,7,127,118,149,237,79,
    171,132,122,128,231,120,199,229,235,115,131,107,252,56,70,125,
    71,101,179,82,99,58,5,209,239,163,166,222,158,60,2,174,
    178,123,160,246,243,42,192,172,134,3,90,84,11,245,130,212,
    126,227,223,176,216,221,33,232,124,136,162,121,88,112,183,21,
}
local function integer(value, minimum, maximum)
    local n=tonumber(value)
    if not n or n~=n or n%1~=0 or n<minimum or n>maximum then error("invalid reading-time value",0) end
    return n
end
local function byte_less(a,b)
    for i=1,math.min(#a,#b) do
        if a:byte(i)~=b:byte(i) then return a:byte(i)<b:byte(i) end
    end
    return #a<#b
end
local function rotate(value)
    local checksum=0
    for i=1,#value do checksum=bit.bxor(checksum,value:byte(i)) end
    local offset=checksum%11
    offset=offset%#value
    return value:sub(#value-offset+1)..value:sub(1,#value-offset)
end
function M.sign(parts)
    local encoded={"5a6f1"}
    for _,part in ipairs(parts) do
        encoded[#encoded+1]=tostring(part):gsub(".",function(c) return string.char(REMAP[c:byte()+1]) end)
    end
    table.sort(encoded,byte_less)
    return Digest.sha256(rotate(Digest.sha256(rotate(table.concat(encoded)))))
end
function M.time_zone(stamp)
    stamp=stamp or os.time()
    local z=os.date("%z",stamp)
    if not z or not z:match("^[+-]%d%d%d%d$") then return nil end
    local minutes=(tonumber(z:sub(2,3))*60+tonumber(z:sub(4,5)))*(z:sub(1,1)=="-" and -1 or 1)
    -- Hour.generateCurrentTimeZone uses TimeZone.getRawOffset, without DST.
    -- Asking mktime for the same local fields with isdst=false also handles
    -- half-hour and negative DST, instead of assuming a one-hour adjustment.
    local local_time=os.date("*t",stamp)
    if local_time and local_time.isdst then
        local_time.isdst=false
        local standard=os.time(local_time)
        if not standard then return nil end
        minutes=minutes-(standard-stamp)/60
    end
    if minutes%1~=0 or math.abs(minutes)>24*60 then return nil end
    local absolute=math.abs(minutes)
    return string.format("%s%02d:%02d",minutes<0 and "-" or "+",math.floor(absolute/60),absolute%60)
end
function M.hours(rows)
    local buckets={}
    for _,row in ipairs(rows) do
        local at=integer(row.start_time,1,4102444800)
        local left=integer(row.duration,1,86400)
        local zone=tostring(row.time_zone or "")
        if not zone:match("^[+-]%d%d:%d%d$") then error("reading-time zone unavailable",0) end
        while left>0 do
            -- Native hourBeginTime uses GMT+8 hour boundaries (Unix seconds).
            local hour=at-at%3600
            local seconds=math.min(left,hour+3600-at)
            local key=tostring(hour)..zone
            local bucket=buckets[key] or {startOfHour=hour,timeZone=zone,readingTime=0,ttsTime=0}
            bucket.readingTime=bucket.readingTime+seconds
            if bucket.readingTime>3600 then error("overlapping reading-time hour",0) end
            buckets[key]=bucket
            at,left=at+seconds,left-seconds
        end
    end
    local result={}
    for _,bucket in pairs(buckets) do result[#result+1]=bucket end
    table.sort(result,function(a,b)
        return a.startOfHour==b.startOfHour and a.timeZone<b.timeZone or a.startOfHour<b.startOfHour
    end)
    return result
end
function M.book(credentials,book_id,rows,guest_token,now,random)
    local hours=M.hours(rows)
    if #hours==0 or tostring(book_id or "")=="" then error("empty reading-time batch",0) end
    local total,risk,book_version=0,0,nil
    for _,row in ipairs(rows) do
        local version=integer(row.book_version or 0,0,2147483647)
        if book_version~=nil and book_version~=version then error("mixed reading-time book versions",0) end
        book_version=version
        risk=bit.bor(risk,integer(row.risk or 0,0,2147483647))
    end
    for _,hour in ipairs(hours) do total=total+hour.readingTime end
    local zone=assert(M.time_zone(now),"reading-time zone unavailable")
    -- Match Native's BaseBookReadPostBody, selected after a newer cloud
    -- position is detected. Deliberately omit every chapter/offset coordinate.
    local body={bookId=tostring(book_id),bookVersion=book_version,appId="",deviceId=credentials.deviceId,
        installId="",summary="",progress=0,currentProgress=0,autoTime=0,isLecture=0,
        isResendReadingInfo=1,lectureTime=0,lectureTextTime=0,novalTime=0,ttsTime=0,
        -- Fastjson maps isFinish() to finish, and excludes voiceType through
        -- JSONField(serialize=false). novelTime is renamed to novalTime above.
        finish=false,risk=risk,readingTime=total,recordCreateTimeZone=zone,
        timestamp=integer(now,1,4102444800),random=integer(random,0,999),hours=hours}
    local parts={tostring(credentials.vid),body.deviceId,body.appId,body.bookId,tostring(risk),zone,tostring(total),"0"}
    for _,hour in ipairs(hours) do
        parts[#parts+1]=table.concat({hour.startOfHour,hour.timeZone,hour.readingTime,hour.ttsTime},"_")
    end
    body.signature=M.sign({guest_token,tostring(random),tostring(now),table.concat(parts,"_")})
    return body
end
function M.batch(credentials,book_id,rows,guest_token,config_token,now,random,envelope)
    if type(config_token)~="string" or config_token=="" then error("reading-time config token unavailable",0) end
    if type(guest_token)~="string" or guest_token=="" then error("reading-time signature token unavailable",0) end
    local book=M.book(credentials,book_id,rows,guest_token,now,random)
    envelope=envelope or {}
    local timestamp=integer(envelope.timestamp or now*1000,1000,4102444800999)
    local outer_random=integer(envelope.random or random,0,999)
    -- resendOfflineReadingInfos takes a separate millisecond timestamp and
    -- random draw. Its optional outer recordCreateTimeZone defaults to null
    -- and JSONEncoded omits it; the book and hours retain their own zones.
    return {books={book},timestamp=timestamp,random=outer_random,
        signature=Digest.sha256(string.format("%.0f",timestamp)..config_token..tostring(outer_random))}
end
return M
