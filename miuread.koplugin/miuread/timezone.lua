local logger = require("logger")

local TimeZone = {}

-- MiuRead formats its own clock instead of mutating the Kindle/KOReader process
-- timezone. Kindle firmware may restore or ignore TZ between screens, which made
-- the old "selected Tokyo but still shows Beijing" behaviour possible.
local ZONES = {
    {id="Asia/Shanghai", label="中国 · 北京", offset=480},
    {id="Asia/Hong_Kong", label="中国 · 香港", offset=480},
    {id="Asia/Macau", label="中国 · 澳门", offset=480},
    {id="Asia/Taipei", label="中国 · 台北", offset=480},
    {id="Asia/Tokyo", label="日本 · 东京", offset=540},
    {id="Asia/Seoul", label="韩国 · 首尔", offset=540},
    {id="Asia/Singapore", label="新加坡", offset=480},
    {id="Europe/Berlin", label="德国 · 柏林", offset=60, dst_offset=120, rule="eu"},
    {id="Europe/London", label="英国 · 伦敦", offset=0, dst_offset=60, rule="eu"},
    {id="Europe/Helsinki", label="芬兰 · 赫尔辛基", offset=120, dst_offset=180, rule="eu"},
    {id="America/New_York", label="美国 · 纽约", offset=-300, dst_offset=-240, rule="us"},
    {id="America/Chicago", label="美国 · 芝加哥", offset=-360, dst_offset=-300, rule="us"},
    {id="America/Denver", label="美国 · 丹佛", offset=-420, dst_offset=-360, rule="us"},
    {id="America/Los_Angeles", label="美国 · 洛杉矶", offset=-480, dst_offset=-420, rule="us"},
}

local by_id = {}
for _, row in ipairs(ZONES) do by_id[row.id] = row end

-- Gregorian calendar helpers. These are independent of the device timezone.
local function days_from_civil(year, month, day)
    year = tonumber(year) or 1970
    month = tonumber(month) or 1
    day = tonumber(day) or 1
    year = year - (month <= 2 and 1 or 0)
    local era = math.floor(year / 400)
    local yoe = year - era * 400
    local mp = month + (month > 2 and -3 or 9)
    local doy = math.floor((153 * mp + 2) / 5) + day - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function epoch_utc(year, month, day, hour, minute, second)
    return days_from_civil(year, month, day) * 86400
        + (tonumber(hour) or 0) * 3600
        + (tonumber(minute) or 0) * 60
        + (tonumber(second) or 0)
end

-- Sunday=0, Monday=1 ... Saturday=6.
local function weekday(year, month, day)
    return (days_from_civil(year, month, day) + 4) % 7
end

local function days_in_month(year, month)
    if month == 2 then
        local leap = (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
        return leap and 29 or 28
    end
    if month == 4 or month == 6 or month == 9 or month == 11 then return 30 end
    return 31
end

function TimeZone.parse_iso_timestamp(value)
    if type(value)~="string" then return nil end
    local y,m,d,h,minute,s,tail=value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$")
    if not y then return nil end
    y,m,d,h,minute,s=tonumber(y),tonumber(m),tonumber(d),tonumber(h),tonumber(minute),tonumber(s)
    if y<2000 or y>2200 or m<1 or m>12 or d<1 or d>days_in_month(y,m)
        or h>23 or minute>59 or s>59 then return nil end
    tail=tail:gsub("^%.%d+","")
    local offset=0
    if tail~="" and tail~="Z" then
        local sign,zh,zm=tail:match("^([+-])(%d%d):(%d%d)$")
        if not sign or tonumber(zh)>23 or tonumber(zm)>59 then return nil end
        offset=(tonumber(zh)*60+tonumber(zm))*60*(sign=="-" and -1 or 1)
    end
    return epoch_utc(y,m,d,h,minute,s)-offset
end

local function nth_sunday(year, month, n)
    local first = weekday(year, month, 1)
    local first_sunday = 1 + ((7 - first) % 7)
    return first_sunday + (math.max(1, tonumber(n) or 1) - 1) * 7
end

local function last_sunday(year, month)
    local last = days_in_month(year, month)
    return last - weekday(year, month, last)
end

local function utc_year(timestamp)
    local row = os.date("!*t", tonumber(timestamp) or os.time()) or {}
    return tonumber(row.year) or 1970
end

local function is_dst(row, timestamp)
    if not row or not row.rule or row.dst_offset == nil then return false end
    timestamp = tonumber(timestamp) or os.time()
    local year = utc_year(timestamp)
    if row.rule == "eu" then
        -- EU transition moments are 01:00 UTC on the final Sunday of March
        -- and October. This covers the European zones exposed by MiuRead.
        local start = epoch_utc(year, 3, last_sunday(year, 3), 1, 0, 0)
        local finish = epoch_utc(year, 10, last_sunday(year, 10), 1, 0, 0)
        return timestamp >= start and timestamp < finish
    end
    if row.rule == "us" then
        -- US: second Sunday in March at 02:00 local standard time, through
        -- first Sunday in November at 02:00 local daylight time.
        local start_local = epoch_utc(year, 3, nth_sunday(year, 3, 2), 2, 0, 0)
        local end_local = epoch_utc(year, 11, nth_sunday(year, 11, 1), 2, 0, 0)
        local start = start_local - (tonumber(row.offset) or 0) * 60
        local finish = end_local - (tonumber(row.dst_offset) or tonumber(row.offset) or 0) * 60
        return timestamp >= start and timestamp < finish
    end
    return false
end

local function device_offset_minutes(timestamp)
    timestamp = tonumber(timestamp) or os.time()
    local local_row = os.date("*t", timestamp)
    local utc_row = os.date("!*t", timestamp)
    if type(local_row) ~= "table" or type(utc_row) ~= "table" then return 0 end
    local local_epoch = epoch_utc(local_row.year, local_row.month, local_row.day,
        local_row.hour, local_row.min, local_row.sec)
    local utc_epoch = epoch_utc(utc_row.year, utc_row.month, utc_row.day,
        utc_row.hour, utc_row.min, utc_row.sec)
    local diff = math.floor((local_epoch - utc_epoch) / 60 + (local_epoch >= utc_epoch and .5 or -.5))
    if diff < -14 * 60 or diff > 14 * 60 then return 0 end
    return diff
end

function TimeZone.zones()
    return ZONES
end

function TimeZone.zone(id)
    return by_id[tostring(id or "")]
end

function TimeZone.normalize(settings)
    settings = type(settings) == "table" and settings or {}
    local mode = tostring(settings.mode or "device")
    if mode ~= "device" and mode ~= "zone" and mode ~= "fixed" then mode = "device" end
    local zone = tostring(settings.zone or "Asia/Shanghai")
    if not by_id[zone] then zone = "Asia/Shanghai" end
    local offset = math.max(-14 * 60, math.min(14 * 60,
        math.floor(tonumber(settings.offset_minutes) or 480)))
    return {mode=mode, zone=zone, offset_minutes=offset}
end

function TimeZone.offset_minutes(settings, timestamp)
    local normalized = TimeZone.normalize(settings)
    if normalized.mode == "device" then return device_offset_minutes(timestamp) end
    if normalized.mode == "fixed" then return normalized.offset_minutes end
    local row = by_id[normalized.zone]
    if not row then return 0 end
    if is_dst(row, timestamp) then return tonumber(row.dst_offset) or tonumber(row.offset) or 0 end
    return tonumber(row.offset) or 0
end

-- Kept for compatibility with older call sites. Formatting no longer relies on
-- changing the process TZ, so applying a MiuRead display timezone cannot alter
-- Kindle system time or be silently undone by firmware.
function TimeZone.apply(settings)
    local normalized = TimeZone.normalize(settings)
    logger.info("[MiuRead][TimeZone] display timezone selected",
        normalized.mode, normalized.zone, tostring(normalized.offset_minutes))
    return true
end

function TimeZone.date(settings, format, timestamp)
    timestamp = tonumber(timestamp) or os.time()
    format = tostring(format or "%Y-%m-%d %H:%M")
    if format:sub(1, 1) == "!" then format = format:sub(2) end
    local offset = TimeZone.offset_minutes(settings, timestamp)
    return os.date("!" .. format, timestamp + offset * 60)
end

function TimeZone.now(settings, format)
    return TimeZone.date(settings, format, os.time())
end

function TimeZone.offset_text(minutes, compact)
    minutes = math.floor(tonumber(minutes) or 0)
    local sign = minutes >= 0 and "+" or "-"
    minutes = math.abs(minutes)
    local hours, mins = math.floor(minutes / 60), minutes % 60
    if compact == true and mins == 0 then return string.format("UTC%s%d", sign, hours) end
    if compact == true then return string.format("UTC%s%d:%02d", sign, hours, mins) end
    return string.format("UTC%s%02d:%02d", sign, hours, mins)
end

function TimeZone.zone_offset_text(id, timestamp)
    local row = by_id[tostring(id or "")]
    if not row then return "UTC" end
    local offset = is_dst(row, timestamp) and (row.dst_offset or row.offset) or row.offset
    return TimeZone.offset_text(offset, true)
end

function TimeZone.label(settings)
    local normalized = TimeZone.normalize(settings)
    if normalized.mode == "device" then return "跟随设备" end
    if normalized.mode == "zone" then return by_id[normalized.zone].label end
    return TimeZone.offset_text(normalized.offset_minutes)
end

function TimeZone.parse_offset(text)
    text = tostring(text or ""):gsub("%s+", ""):upper():gsub("^UTC", "")
    local sign, hours, mins = text:match("^([+-]?)(%d%d?):(%d%d)$")
    if not hours then
        sign, hours = text:match("^([+-]?)(%d%d?)$")
        mins = "0"
    end
    if not hours then return nil end
    hours, mins = tonumber(hours), tonumber(mins or 0) or 0
    if not hours or hours > 14 or mins > 59 then return nil end
    local value = hours * 60 + mins
    if sign == "-" then value = -value end
    if value < -14 * 60 or value > 14 * 60 then return nil end
    return value
end

return TimeZone
