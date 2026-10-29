-- Read KOReader's settled tuples and its current-page estimate using exactly
-- the statistics plugin's min/max rules. Never alter its counters or database.
local M={}
function M.instance(host)
    local ui=host and host.ui
    local stats=ui and ui.statistics
    if not stats or not stats.id_curr_book or not stats.page_stat or not stats.settings then return nil end
    if type(stats.isEnabledAndNotFrozen)~="function" or not stats:isEnabledAndNotFrozen() then return nil end
    return stats
end
function M.snapshot(stats,now,sources)
    local rows={}
    local minimum=tonumber(stats.settings.min_sec) or 5
    local maximum=tonumber(stats.settings.max_sec) or 120
    if minimum<0 or maximum<minimum or maximum>86400 then return rows end
    local endpoint=math.min(now,tonumber(stats._reading_paused_ts) or now)
    for page,tuples in pairs(stats.page_stat or {}) do
        for index,tuple in ipairs(tuples) do
            local start,duration=tonumber(tuple[1]),tonumber(tuple[2])
            if start and duration then
                -- onReadingResumed shifts this same tuple's timestamp. Keep
                -- its source identity so a brief pause cannot replay its prefix.
                local origin=sources and sources[tuple] or start
                if sources then sources[tuple]=origin end
                if duration==0 and page==stats.curr_page and index==#tuples then
                    local elapsed=endpoint-start
                    duration=elapsed>=minimum and math.min(elapsed,maximum) or 0
                end
                if duration>0 then rows[#rows+1]={page=page,start_time=start,duration=duration,source_start=origin} end
            end
        end
    end
    return rows
end
function M.persisted(stats,first,last)
    local DataStorage=require("datastorage")
    local conn=require("lua-ljsqlite3/init").open(DataStorage:getSettingsDir().."/statistics.sqlite3","ro")
    local ok,rows=pcall(function()
        conn:exec("PRAGMA busy_timeout=100;")
        local stmt=conn:prepare([[SELECT page,start_time,duration FROM page_stat_data
            WHERE id_book=? AND start_time>=? AND start_time<? AND duration>0 ORDER BY start_time;]])
        local result={}
        stmt:bind(stats.id_curr_book,first-(tonumber(stats.settings.max_sec) or 120),last)
        while true do
            local row=stmt:step()
            if not row then break end
            result[#result+1]={page=tonumber(row[1]),start_time=tonumber(row[2]),duration=tonumber(row[3])}
        end
        stmt:close()
        return result
    end)
    conn:close()
    if not ok then error(rows) end
    return rows
end
return M
