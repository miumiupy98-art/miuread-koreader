local DataStorage = require("datastorage")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local NetworkHealth = require("miuread.network_health")

local HomeData = {}
local stats_cache
local device_cache

local function clamp_number(value, minimum, maximum)
    value = tonumber(value) or 0
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

function HomeData.format_duration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then return tostring(hours) .. " 小时 " .. tostring(minutes) .. " 分" end
    return tostring(minutes) .. " 分钟"
end

local function local_midnight(stamp)
    local d = os.date("*t", stamp)
    return os.time{year=d.year, month=d.month, day=d.day, hour=0, min=0, sec=0}
end

local function month_start(stamp)
    local d = os.date("*t", stamp)
    return os.time{year=d.year, month=d.month, day=1, hour=0, min=0, sec=0}
end

local function year_start(stamp)
    local d = os.date("*t", stamp)
    return os.time{year=d.year, month=1, day=1, hour=0, min=0, sec=0}
end

local function next_month_start(stamp)
    local d = os.date("*t", stamp)
    return os.time{year=d.year, month=d.month+1, day=1, hour=0, min=0, sec=0}
end

local function next_year_start(stamp)
    local d = os.date("*t", stamp)
    return os.time{year=d.year+1, month=1, day=1, hour=0, min=0, sec=0}
end

local function natural_days_elapsed(start_stamp, end_stamp, now)
    local last = math.min(tonumber(now) or os.time(), (tonumber(end_stamp) or 0) - 1)
    if last < start_stamp then return 0 end
    return math.max(1, math.floor((local_midnight(last) - local_midnight(start_stamp)) / 86400) + 1)
end

function HomeData.reading_stats(force, detail)
    local now = os.time()
    local cache_key = detail == true and "detail" or "home"
    if not force and stats_cache and stats_cache[cache_key] and now - stats_cache[cache_key].at < (detail and 120 or 30) then
        return stats_cache[cache_key].value
    end

    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(path, "mode") ~= "file" then
        stats_cache = stats_cache or {}
        stats_cache[cache_key] = {at = now, value = nil}
        return nil
    end

    local ok, value = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(path, "ro")
        local result
        local query_ok, query_error = pcall(function()
            conn:exec("PRAGMA busy_timeout=180;")
            local day_start = local_midnight(now)
            local date = os.date("*t", now)
            local week_start = day_start - ((date.wday + 5) % 7) * 86400
            local week_end = week_start + 7 * 86400
            local current_month_start = month_start(now)
            local current_month_end = next_month_start(now)
            local current_year_start = year_start(now)
            local current_year_end = next_year_start(now)

            local total_stmt = conn:prepare([[
                SELECT COALESCE(SUM(duration), 0)
                  FROM page_stat_data
                 WHERE start_time >= ? AND start_time < ?
            ]])
            local function total_between(first, last)
                local row = total_stmt:bind(first, last):step()
                local seconds = tonumber(row and row[1]) or 0
                total_stmt:clearbind():reset()
                return math.max(0, seconds)
            end

            local days_stmt = conn:prepare([[
                SELECT COUNT(DISTINCT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime'))
                  FROM page_stat_data
                 WHERE start_time >= ? AND start_time < ? AND duration > 0
            ]])
            local function read_days_between(first, last)
                local row = days_stmt:bind(first, last):step()
                local count = tonumber(row and row[1]) or 0
                days_stmt:clearbind():reset()
                return math.max(0, count)
            end

            local pages_stmt = conn:prepare([[
                SELECT COUNT(DISTINCT (id_book || ':' || page))
                  FROM page_stat_data
                 WHERE start_time >= ? AND start_time < ? AND duration > 0
            ]])
            local function pages_between(first, last)
                local row = pages_stmt:bind(first, last):step()
                local count = tonumber(row and row[1]) or 0
                pages_stmt:clearbind():reset()
                return math.max(0, count)
            end

            local function daily_between(first, day_count)
                local grouped = {}
                local stmt = conn:prepare([[
                    SELECT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime') AS day,
                           COALESCE(SUM(duration), 0)
                      FROM page_stat_data
                     WHERE start_time >= ? AND start_time < ?
                     GROUP BY day
                ]])
                stmt:reset():bind(first, first + day_count * 86400)
                local row={}
                while stmt:step(row) do
                    grouped[tostring(row[1] or "")] = math.max(0, tonumber(row[2]) or 0)
                end
                stmt:close()
                local rows = {}
                for index=0,day_count-1 do
                    local stamp = first + index * 86400
                    local key = os.date("%Y-%m-%d", stamp)
                    rows[#rows+1] = {
                        stamp=stamp,
                        date=os.date("%m-%d", stamp),
                        weekday=os.date("%w", stamp),
                        seconds=grouped[key] or 0,
                        future=stamp > day_start,
                    }
                end
                return rows
            end

            local function ranked_between(first, last)
                local rows = {}
                local stmt = conn:prepare([[
                    SELECT COALESCE(NULLIF(TRIM(b.title), ''), '未命名'),
                           COALESCE(NULLIF(TRIM(b.authors), ''), ''),
                           COALESCE(SUM(p.duration), 0)
                      FROM page_stat_data p
                      JOIN book b ON b.id = p.id_book
                     WHERE p.start_time >= ? AND p.start_time < ? AND p.duration > 0
                     GROUP BY p.id_book
                     ORDER BY SUM(p.duration) DESC
                     LIMIT 10
                ]])
                stmt:reset():bind(first, last)
                local row={}
                while stmt:step(row) do
                    rows[#rows+1] = {title=tostring(row[1] or "未命名"), author=tostring(row[2] or ""), seconds=math.max(0, tonumber(row[3]) or 0)}
                end
                stmt:close()
                return rows
            end

            local today_seconds = total_between(day_start, day_start + 86400)
            local week_seconds = total_between(week_start, week_end)
            local month_seconds = total_between(current_month_start, current_month_end)
            local weekly_daily = daily_between(week_start, 7)

            result = {
                today_seconds = today_seconds,
                today_pages = pages_between(day_start, day_start + 86400),
                week_seconds = week_seconds,
                month_seconds = month_seconds,
                read_days = read_days_between(week_start, week_end),
                day_average_seconds = math.floor(week_seconds / math.max(1, natural_days_elapsed(week_start, week_end, now))),
                daily = weekly_daily,
                updated_at = now,
            }

            if detail == true then
                local first_stamp = tonumber(conn:rowexec("SELECT MIN(start_time) FROM page_stat_data WHERE duration > 0;")) or current_year_start
                local all_start = first_stamp > 0 and local_midnight(first_stamp) or current_year_start
                local all_end = day_start + 86400
                local month_days = math.max(1, math.floor((current_month_end - current_month_start) / 86400))

                local annual_buckets = {}
                local annual_stmt = conn:prepare([[
                    SELECT CAST(strftime('%m', start_time, 'unixepoch', 'localtime') AS INTEGER), COALESCE(SUM(duration),0)
                      FROM page_stat_data
                     WHERE start_time >= ? AND start_time < ?
                     GROUP BY 1 ORDER BY 1
                ]])
                local annual_map = {}
                annual_stmt:reset():bind(current_year_start, current_year_end)
                local annual_row={}
                while annual_stmt:step(annual_row) do annual_map[tonumber(annual_row[1]) or 0]=math.max(0,tonumber(annual_row[2]) or 0) end
                annual_stmt:close()
                for month=1,12 do annual_buckets[#annual_buckets+1]={label=string.format("%02d月",month),seconds=annual_map[month] or 0,future=month>date.month} end

                local yearly_buckets = {}
                local yearly_stmt = conn:prepare([[
                    SELECT strftime('%Y', start_time, 'unixepoch', 'localtime'), COALESCE(SUM(duration),0)
                      FROM page_stat_data
                     WHERE start_time >= ? AND start_time < ?
                     GROUP BY 1 ORDER BY 1
                ]])
                yearly_stmt:reset():bind(all_start, all_end)
                local yearly_row={}
                while yearly_stmt:step(yearly_row) do yearly_buckets[#yearly_buckets+1]={label=tostring(yearly_row[1] or ""),seconds=math.max(0,tonumber(yearly_row[2]) or 0)} end
                yearly_stmt:close()

                result.periods = {
                    weekly = {
                        base_time=week_start,is_current=true,
                        total_seconds=week_seconds, read_days=read_days_between(week_start,week_end),
                        day_average_seconds=math.floor(week_seconds/math.max(1,natural_days_elapsed(week_start,week_end,now))),
                        pages=pages_between(week_start,week_end), daily=weekly_daily, rank=ranked_between(week_start,week_end),
                        label="本周",
                    },
                    monthly = {
                        base_time=current_month_start,is_current=true,
                        total_seconds=month_seconds, read_days=read_days_between(current_month_start,current_month_end),
                        day_average_seconds=math.floor(month_seconds/math.max(1,natural_days_elapsed(current_month_start,current_month_end,now))),
                        pages=pages_between(current_month_start,current_month_end), daily=daily_between(current_month_start,month_days),
                        rank=ranked_between(current_month_start,current_month_end), label=os.date("%Y-%m",now),
                    },
                    annually = {
                        base_time=current_year_start,is_current=true,
                        total_seconds=total_between(current_year_start,current_year_end), read_days=read_days_between(current_year_start,current_year_end),
                        day_average_seconds=math.floor(total_between(current_year_start,current_year_end)/math.max(1,natural_days_elapsed(current_year_start,current_year_end,now))),
                        pages=pages_between(current_year_start,current_year_end), buckets=annual_buckets,
                        rank=ranked_between(current_year_start,current_year_end), label=os.date("%Y",now).." 年",
                    },
                    overall = {
                        base_time=0,is_current=true,
                        total_seconds=total_between(all_start,all_end), read_days=read_days_between(all_start,all_end),
                        pages=pages_between(all_start,all_end), buckets=yearly_buckets, rank=ranked_between(all_start,all_end), label="全部",
                    },
                }
            end

            total_stmt:close()
            days_stmt:close()
            pages_stmt:close()
        end)
        conn:close()
        if not query_ok then error(query_error) end
        return result
    end)

    if not ok then
        logger.warn("[MiuRead][Home] reading statistics unavailable", tostring(value))
        value = nil
    end
    stats_cache = stats_cache or {}
    stats_cache[cache_key] = {at = now, value = value}
    return value
end


function HomeData.reading_stats_period(mode, base_time)
    mode=tostring(mode or "weekly")
    if mode=="overall" then
        local all=HomeData.reading_stats(true,true)
        return all and type(all.periods)=="table" and all.periods.overall or nil
    end
    if mode~="weekly" and mode~="monthly" and mode~="annually" then return nil end
    local now=os.time()
    local anchor=tonumber(base_time) or now
    if anchor<=0 then anchor=now end
    local day=local_midnight(anchor)
    local d=os.date("*t",anchor)
    local first,last,label
    if mode=="weekly" then
        first=day-((d.wday+5)%7)*86400
        last=first+7*86400
        label=os.date("%m-%d",first).." ~ "..os.date("%m-%d",last-1)
    elseif mode=="monthly" then
        first=month_start(anchor); last=next_month_start(anchor); label=os.date("%Y-%m",first)
    else
        first=year_start(anchor); last=next_year_start(anchor); label=os.date("%Y",first).." 年"
    end
    local current_anchor=mode=="weekly" and (local_midnight(now)-((os.date("*t",now).wday+5)%7)*86400)
        or (mode=="monthly" and month_start(now) or year_start(now))
    if first>current_anchor then return nil end
    local path=DataStorage:getSettingsDir().."/statistics.sqlite3"
    if lfs.attributes(path,"mode")~="file" then return nil end
    local ok,value=pcall(function()
        local SQ3=require("lua-ljsqlite3/init")
        local conn=SQ3.open(path,"ro")
        conn:exec("PRAGMA busy_timeout=180;")
        local function total(a,b)
            local stmt=conn:prepare("SELECT COALESCE(SUM(duration),0) FROM page_stat_data WHERE start_time>=? AND start_time<?;")
            local row=stmt:bind(a,b):step(); local v=math.max(0,tonumber(row and row[1]) or 0); stmt:close(); return v
        end
        local function days(a,b)
            local stmt=conn:prepare([[SELECT COUNT(*) FROM (SELECT strftime('%Y-%m-%d',start_time,'unixepoch','localtime') d FROM page_stat_data WHERE start_time>=? AND start_time<? AND duration>0 GROUP BY d);]])
            local row=stmt:bind(a,b):step(); local v=math.max(0,tonumber(row and row[1]) or 0); stmt:close(); return v
        end
        local function pages(a,b)
            local stmt=conn:prepare("SELECT COUNT(DISTINCT (id_book || ':' || page)) FROM page_stat_data WHERE start_time>=? AND start_time<? AND duration>0;")
            local row=stmt:bind(a,b):step(); local v=math.max(0,tonumber(row and row[1]) or 0); stmt:close(); return v
        end
        local function rank(a,b)
            local stmt=conn:prepare([[SELECT COALESCE(NULLIF(TRIM(b.title),''),'未命名'),COALESCE(NULLIF(TRIM(b.authors),''),''),COALESCE(SUM(p.duration),0) FROM page_stat_data p JOIN book b ON b.id=p.id_book WHERE p.start_time>=? AND p.start_time<? AND p.duration>0 GROUP BY p.id_book ORDER BY SUM(p.duration) DESC LIMIT 10;]])
            stmt:reset():bind(a,b)
            local out,row={},{}
            while stmt:step(row) do out[#out+1]={title=tostring(row[1] or "未命名"),author=tostring(row[2] or ""),seconds=math.max(0,tonumber(row[3]) or 0)} end
            stmt:close(); return out
        end
        local period={base_time=first,label=label,total_seconds=total(first,last),read_days=days(first,last),pages=pages(first,last),rank=rank(first,last),is_current=first==current_anchor}
        period.day_average_seconds=math.floor(period.total_seconds/math.max(1,natural_days_elapsed(first,last,period.is_current and now or (last-1))))
        if mode=="weekly" or mode=="monthly" then
            local count=math.max(1,math.floor((last-first)/86400))
            local grouped={}
            local stmt=conn:prepare([[SELECT strftime('%Y-%m-%d',start_time,'unixepoch','localtime'),COALESCE(SUM(duration),0) FROM page_stat_data WHERE start_time>=? AND start_time<? GROUP BY 1;]])
            stmt:reset():bind(first,last); local row={}
            while stmt:step(row) do grouped[tostring(row[1] or "")]=math.max(0,tonumber(row[2]) or 0) end
            stmt:close(); period.daily={}
            local today=local_midnight(now)
            for index=0,count-1 do local stamp=first+index*86400; period.daily[#period.daily+1]={stamp=stamp,date=os.date("%m-%d",stamp),weekday=os.date("%w",stamp),seconds=grouped[os.date("%Y-%m-%d",stamp)] or 0,future=stamp>today} end
        else
            period.buckets={}; local by_month={}
            local stmt=conn:prepare([[SELECT CAST(strftime('%m',start_time,'unixepoch','localtime') AS INTEGER),COALESCE(SUM(duration),0) FROM page_stat_data WHERE start_time>=? AND start_time<? GROUP BY 1 ORDER BY 1;]])
            stmt:reset():bind(first,last); local row={}
            while stmt:step(row) do by_month[tonumber(row[1]) or 0]=math.max(0,tonumber(row[2]) or 0) end
            stmt:close(); local cur=os.date("*t",now)
            for m=1,12 do period.buckets[#period.buckets+1]={label=string.format("%02d月",m),seconds=by_month[m] or 0,future=period.is_current and m>cur.month} end
        end
        conn:close(); return period
    end)
    if not ok then logger.warn("[MiuRead][Home] period statistics unavailable",tostring(value)); return nil end
    return value
end

local function normalized_timestamp(value)
    local stamp = tonumber(value)
    if not stamp then return nil end
    if stamp > 100000000000 then stamp = math.floor(stamp / 1000) end
    return stamp
end

local function weread_bucket_seconds(read_times, target_date)
    if type(read_times) ~= "table" then return 0 end
    for key, value in pairs(read_times) do
        local stamp = normalized_timestamp(key)
        if stamp and os.date("%Y-%m-%d", stamp) == target_date then
            return math.max(0, tonumber(value) or 0)
        end
    end
    return 0
end

local function normalized_bucket_rows(read_times)
    local rows = {}
    for key, value in pairs(type(read_times)=="table" and read_times or {}) do
        local stamp = normalized_timestamp(key)
        if stamp then
            rows[#rows + 1] = {
                stamp = stamp,
                date = os.date("%m-%d", stamp),
                weekday = os.date("%w", stamp),
                seconds = math.max(0, tonumber(value) or 0),
            }
        end
    end
    table.sort(rows, function(a, b) return (a.stamp or 0) < (b.stamp or 0) end)
    return rows
end

function HomeData.week_rows(rows, now)
    now = tonumber(now) or os.time()
    local today = local_midnight(now)
    local d = os.date("*t", now)
    local first = today - ((d.wday + 5) % 7) * 86400
    local by_date = {}
    for _, row in ipairs(type(rows)=="table" and rows or {}) do
        local stamp = normalized_timestamp(row.stamp)
        if stamp then by_date[os.date("%Y-%m-%d", stamp)] = math.max(0, tonumber(row.seconds) or 0) end
    end
    local out = {}
    for index=0,6 do
        local stamp = first + index * 86400
        out[#out+1] = {
            stamp=stamp,
            date=os.date("%m-%d", stamp),
            weekday=os.date("%w", stamp),
            seconds=by_date[os.date("%Y-%m-%d", stamp)] or 0,
            future=stamp > today,
            today=stamp == today,
        }
    end
    return out
end


function HomeData.month_rows(rows, base_time, now)
    now=tonumber(now) or os.time()
    base_time=normalized_timestamp(base_time) or now
    local first=month_start(base_time)
    local last=next_month_start(base_time)
    local today=local_midnight(now)
    local by_date={}
    for _,row in ipairs(type(rows)=="table" and rows or {}) do
        local stamp=normalized_timestamp(row.stamp)
        if stamp then by_date[os.date("%Y-%m-%d",stamp)]=math.max(0,tonumber(row.seconds) or 0) end
    end
    local out={}
    local count=math.max(1,math.floor((last-first)/86400))
    for index=0,count-1 do
        local stamp=first+index*86400
        out[#out+1]={
            stamp=stamp,date=os.date("%m-%d",stamp),weekday=os.date("%w",stamp),
            seconds=by_date[os.date("%Y-%m-%d",stamp)] or 0,
            future=stamp>today,
            today=stamp==today,
        }
    end
    return out
end

local function weread_rank(rows)
    local out = {}
    for _, item in ipairs(type(rows)=="table" and rows or {}) do
        local book = type(item.book)=="table" and item.book or nil
        local album = type(item.albumInfo)=="table" and item.albumInfo or nil
        local source = book or album or {}
        local title = tostring(source.title or source.name or source.albumTitle or "")
        if title ~= "" then
            out[#out+1] = {
                title=title,
                author=tostring(source.author or source.authorName or ""),
                seconds=math.max(0, tonumber(item.readTime) or 0),
                tags=type(item.tags)=="table" and item.tags or {},
            }
        end
    end
    return out
end

function HomeData.weread_summary(data, now, mode)
    data = type(data) == "table" and data or {}
    now = tonumber(now) or os.time()
    mode = tostring(mode or data.mode or "")
    local read_times = type(data.readTimes) == "table" and data.readTimes or {}
    local buckets = normalized_bucket_rows(read_times)
    if mode=="annually" then
        for _,row in ipairs(buckets) do row.label=os.date("%m月",row.stamp) end
    elseif mode=="overall" then
        for _,row in ipairs(buckets) do row.label=os.date("%Y",row.stamp) end
    end
    local daily_detail = normalized_bucket_rows(data.dailyReadTimes)
    local base_stamp=normalized_timestamp(data.baseTime) or 0
    local current_start=0
    local period_label=""
    if mode=="weekly" then
        local today=local_midnight(now); local td=os.date("*t",now)
        current_start=today-((td.wday+5)%7)*86400
        local b=base_stamp>0 and base_stamp or current_start
        period_label=os.date("%m-%d",b).." ~ "..os.date("%m-%d",b+6*86400)
    elseif mode=="monthly" then
        current_start=month_start(now); local b=base_stamp>0 and base_stamp or current_start
        period_label=os.date("%Y-%m",b)
    elseif mode=="annually" then
        current_start=year_start(now); local b=base_stamp>0 and base_stamp or current_start
        period_label=os.date("%Y",b).." 年"
    elseif mode=="overall" then period_label="全部" end
    return {
        mode = mode,
        label = period_label,
        is_current = mode=="overall" or base_stamp==0 or base_stamp==current_start,
        today_seconds = weread_bucket_seconds(read_times, os.date("%Y-%m-%d", now)),
        total_seconds = math.max(0, tonumber(data.totalReadTime) or 0),
        read_days = math.max(0, tonumber(data.readDays) or 0),
        day_average_seconds = math.max(0, tonumber(data.dayAverageReadTime) or 0),
        compare = tonumber(data.compare),
        daily = buckets,
        daily_detail = daily_detail,
        rank = weread_rank(data.readLongest),
        read_stat = type(data.readStat)=="table" and data.readStat or {},
        prefer_category = type(data.preferCategory)=="table" and data.preferCategory or {},
        prefer_category_word = tostring(data.preferCategoryWord or ""),
        prefer_time = type(data.preferTime)=="table" and data.preferTime or {},
        prefer_time_word = tostring(data.preferTimeWord or ""),
        prefer_author = type(data.preferAuthor)=="table" and data.preferAuthor or {},
        prefer_publisher = type(data.preferPublisher)=="table" and data.preferPublisher or {},
        read_rate = tonumber(data.readRate),
        wr_read_time = tonumber(data.wrReadTime),
        wr_listen_time = tonumber(data.wrListenTime),
        rank_text = type(data.rank)=="table" and tostring(data.rank.text or "") or "",
        regist_time = normalized_timestamp(data.registTime),
        year_report = type(data.yearReport)=="table" and data.yearReport or {},
        base_time = base_stamp,
        fetched_at = now,
    }
end

function HomeData.invalidate_device_state()
    device_cache = nil
end

function HomeData.cached_device_state()
    return device_cache and device_cache.value or nil
end

function HomeData.set_cached_device_state(value)
    if type(value)~="table" then return false end
    local now=os.time()
    local state={}
    for key,item in pairs(value) do state[key]=item end
    device_cache={at=now,power_at=now,value=state}
    return true
end

local function read_power_state()
    local result={battery=nil,charging=false}
    local ok_power,power=pcall(Device.getPowerDevice,Device)
    if ok_power and power then
        if type(power.getCapacity)=="function" then
            local ok,capacity=pcall(power.getCapacity,power)
            if ok and tonumber(capacity) then result.battery=clamp_number(capacity,0,100) end
        end
        if type(power.isCharging)=="function" then
            local ok,charging=pcall(power.isCharging,power)
            if ok then result.charging=charging==true end
        end
    end
    return result
end

-- Refresh battery/charging without touching Wi-Fi, storage or shelf state.
-- Home's minute clock uses this path so an e-ink device can keep a truthful
-- battery number without rebuilding the page or polling the network.
function HomeData.quick_power_state(force)
    local now=os.time()
    if not force and device_cache and tonumber(device_cache.power_at)
        and now-tonumber(device_cache.power_at)<60 then
        local cached=device_cache.value or {}
        return {battery=cached.battery,charging=cached.charging==true}
    end
    local power=read_power_state()
    local state={}
    for key,value in pairs(device_cache and device_cache.value or {}) do state[key]=value end
    state.battery=power.battery
    state.charging=power.charging==true
    device_cache={
        at=device_cache and tonumber(device_cache.at) or 0,
        power_at=now,
        value=state,
    }
    return power
end

function HomeData.quick_device_state(force)
    local now = os.time()
    if not force and device_cache and now - device_cache.at < 60 then
        return device_cache.value
    end
    local state = {online = nil, wifi_on = nil, connected = nil, wifi_name = nil, network_phase = nil, battery = nil, charging = false}
    local power=read_power_state()
    state.battery=power.battery
    state.charging=power.charging==true
    local ok_network, network = pcall(require, "ui/network/manager")
    if ok_network and network then
        if type(network.queryNetworkState) == "function" then pcall(network.queryNetworkState, network) end
        if type(network.isWifiOn) == "function" then
            local ok, value = pcall(network.isWifiOn, network)
            if ok then state.wifi_on = value == true end
        end
        if state.wifi_on == false then
            state.connected = false
        elseif type(network.isConnected) == "function" then
            local ok, value = pcall(network.isConnected, network)
            if ok then state.connected = value == true end
        end
        if state.connected ~= false and type(network.isOnline) == "function" then
            local ok, online = pcall(network.isOnline, network)
            if ok then state.online = online == true end
        elseif state.connected == false then
            state.online = false
        end
        if state.wifi_on == true and state.connected ~= false and type(network.getCurrentNetwork) == "function" then
            local ok, current = pcall(network.getCurrentNetwork, network)
            if ok and type(current) == "table" then
                local ssid = tostring(current.ssid or current.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if ssid ~= "" then state.wifi_name = ssid end
            end
        end
    end

    local health = NetworkHealth.snapshot()
    if state.wifi_on == false then
        state.network_phase = "off"
    else
        local is_kindle = false
        if type(Device.isKindle) == "function" then
            local ok, value = pcall(Device.isKindle, Device)
            is_kindle = ok and value == true
        end
        local manager_ready = state.connected == true and state.online == true
            and (not is_kindle or tostring(state.wifi_name or "") ~= "")
        if health.state == "recovering" and health.age <= 50 then
            -- During resume do not trust the manager's cached connected bit by
            -- itself. A real HTTP response (recorded by network_health) clears
            -- this state immediately; otherwise we keep showing recovery until
            -- the grace window expires.
            state.network_phase = "recovering"
        elseif manager_ready then
            NetworkHealth.note_success("network-manager")
            state.network_phase = "connected"
        elseif health.state == "down" and health.age <= 20 then
            state.network_phase = "unavailable"
        elseif state.wifi_on == true then
            state.network_phase = "connecting"
        else
            state.network_phase = "unknown"
        end
    end
    device_cache = {at = now, power_at=now, value = state}
    return state
end

function HomeData.device_state(force)
    local now = os.time()
    local base = HomeData.quick_device_state(force)
    if not force and device_cache and device_cache.value.storage_checked_at
        and now - device_cache.value.storage_checked_at < 60 then
        return device_cache.value
    end

    local state = {}
    for key, value in pairs(base or {}) do state[key] = value end
    state.storage_free = state.storage_free
    state.storage_total = state.storage_total
    local ok_util, util = pcall(require, "util")
    if ok_util and util and type(util.diskUsage) == "function" then
        local drive = Device.home_dir or DataStorage:getDataDir() or "/"
        local ok, usage = pcall(util.diskUsage, drive)
        if ok and type(usage) == "table" then
            state.storage_free = tonumber(usage.available)
            state.storage_total = tonumber(usage.total)
        end
    end
    state.storage_checked_at = now
    device_cache = {at = now, value = state}
    return state
end

function HomeData.format_bytes(bytes)
    bytes = tonumber(bytes)
    if not bytes or bytes < 0 then return "未知" end
    local gib = bytes / 1024 / 1024 / 1024
    if gib >= 1 then return string.format("%.1f GB", gib) end
    return string.format("%.0f MB", bytes / 1024 / 1024)
end

return HomeData
