local Protocol=require("miuread.protocol")
local M={}
local function get(http,url)
    return http:get_json(url,{auth=false,retries=0,timeout={4,8}})
end
local conditions={
    [0]="晴",[1]="晴间多云",[2]="局部多云",[3]="阴",
    [45]="雾",[48]="雾凇",[51]="小毛毛雨",[53]="毛毛雨",[55]="强毛毛雨",
    [56]="冻毛毛雨",[57]="强冻毛毛雨",[61]="小雨",[63]="中雨",[65]="大雨",
    [66]="冻雨",[67]="强冻雨",[71]="小雪",[73]="中雪",[75]="大雪",[77]="雪粒",
    [80]="小阵雨",[81]="阵雨",[82]="强阵雨",[85]="阵雪",[86]="强阵雪",
    [95]="雷雨",[96]="雷雨伴冰雹",[99]="强雷雨伴冰雹",
}

function M.cities(http,name)
    local value=get(http,"https://geocoding-api.open-meteo.com/v1/search?count=8&language=zh&name="
        ..Protocol.escape(name))
    local cities={}
    for _,entry in ipairs(type(value.results)=="table" and value.results or {}) do
        local lat,lon=tonumber(entry.latitude),tonumber(entry.longitude)
        if type(entry.name)=="string" and lat and lon and math.abs(lat)<=90 and math.abs(lon)<=180 then
            local detail={}
            if entry.admin1 and entry.admin1~=entry.name then detail[#detail+1]=entry.admin1 end
            if entry.country then detail[#detail+1]=entry.country end
            cities[#cities+1]={name=entry.name,detail=table.concat(detail," · "),latitude=lat,longitude=lon}
        end
    end
    return cities
end

function M.current(http,city)
    local url=string.format("https://api.open-meteo.com/v1/forecast?latitude=%.5f&longitude=%.5f",
        city.latitude,city.longitude).."&current=temperature_2m,weather_code&timezone=auto"
    local value=get(http,url)
    local current=type(value.current)=="table" and value.current or {}
    local temperature,code=tonumber(current.temperature_2m),tonumber(current.weather_code)
    if not temperature or not conditions[code] then error("天气数据暂未取得",0) end
    return {text=string.format("%.0f°C · %s",temperature,conditions[code]),updated_at=os.time()}
end

return M
