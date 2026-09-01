local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local HomeData = require("miuread.home_data")
local TransientGuard = require("miuread.transient_guard")
local Skin = require("miuread.reader_skin")
local Ui = require("miuread.ui_components")

local Screen = Device.screen
local live_dialog
local WEEKDAY = {"一", "二", "三", "四", "五", "六", "日"}

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local TapBox = InputContainer:extend{dimen=nil, callback=nil, enabled=true, _tap_block_until=0}
function TapBox:init()
    self.dimen=self.dimen or Geom:new{w=1,h=1}
    self.ges_events={TapSelect={GestureRange:new{ges="tap",range=self.dimen}}}
end
function TapBox:getSize() return Geom:new{w=self.dimen.w,h=self.dimen.h} end
function TapBox:paintTo(bb,x,y)
    self.dimen.x,self.dimen.y=x,y
    if self[1] then self[1]:paintTo(bb,x,y) end
end
function TapBox:onTapSelect()
    if self.enabled==false then return true end
    local now=os.clock()
    if now<(tonumber(self._tap_block_until) or 0) then return true end
    self._tap_block_until=now+.18
    if self.callback then self.callback(self.dimen and self.dimen:copy() or nil) end
    return true
end
function TapBox:handleEvent(event) return InputContainer.handleEvent(self,event) end

local function resolved(data)
    if type(data)=="function" then
        local ok,value=pcall(data)
        if ok and type(value)=="table" then return value end
        return {}
    end
    return type(data)=="table" and data or {}
end

local function duration(seconds)
    return HomeData.format_duration(math.max(0,tonumber(seconds) or 0))
end

local function short_duration(seconds)
    seconds=math.max(0,math.floor(tonumber(seconds) or 0))
    local h=math.floor(seconds/3600)
    local m=math.floor((seconds%3600)/60)
    if h>0 then return tostring(h).."小时"..tostring(m).."分" end
    return tostring(m).."分钟"
end

local function period_title(key)
    if key=="weekly" then return "本周阅读" end
    if key=="monthly" then return "本月阅读" end
    if key=="annually" then return "本年阅读" end
    return "累计阅读"
end

local function compare_text(value)
    value=tonumber(value)
    if not value then return nil end
    local pct=math.floor(math.abs(value)*100+.5)
    if pct==0 then return "与上期持平" end
    return value>0 and ("较上期 ↑"..tostring(pct).."%") or ("较上期 ↓"..tostring(pct).."%")
end

local function weread_period(source,key)
    local data=resolved(source)
    return type(data[key])=="table" and data[key] or nil
end

local function local_period(source,key)
    local data=resolved(source)
    local periods=type(data.periods)=="table" and data.periods or {}
    if type(periods[key])=="table" then return periods[key] end
    if key=="weekly" then
        return {
            label="本周",is_current=true,total_seconds=data.week_seconds,
            read_days=data.read_days,day_average_seconds=data.day_average_seconds,
            daily=data.daily,pages=data.today_pages,rank={},
        }
    end
    return nil
end

local function get_period(kind,source,key)
    return kind=="weread" and weread_period(source,key) or local_period(source,key)
end

local function card(width,height,content,padding)
    return Skin.frame(width,height,{
        bordersize=Skin.line("thin"),padding=padding or Skin.dp(8,6,12),
        radius=Skin.radius(8,6,13),background=Blitbuffer.COLOR_WHITE,color=Blitbuffer.COLOR_GRAY,
    },content)
end

local function metric_block(label,value,width,height)
    local label_h=math.max(1,math.floor(height*.42))
    return VerticalGroup:new{align="center",
        Ui.textbox(tostring(value or "--"),width,math.max(1,height-label_h),Skin.face("cfont",11.3,15.2,9.5),{
            bold=true,alignment="center",halign="center",fgcolor=Blitbuffer.COLOR_BLACK,
            height_overflow_show_ellipsis=true,
        }),
        Ui.textbox(tostring(label or ""),width,label_h,Skin.face("smallinfofont",8.6,11.4,7.2),{
            bold=true,alignment="center",halign="center",fgcolor=Blitbuffer.COLOR_BLACK,
            height_overflow_show_ellipsis=true,
        }),
    }
end

local function summary_card(kind,key,period,width,height)
    local pad=Skin.dp(9,7,13)
    local inner_w=math.max(1,width-pad*2)
    local inner_h=math.max(1,height-pad*2)
    local title_h=math.max(Skin.dp(22,19,30),math.floor(inner_h*.19))
    local main_h=math.max(Skin.dp(38,34,54),math.floor(inner_h*.38))
    local metric_h=math.max(1,inner_h-title_h-main_h)
    local title=period_title(key)
    local main=duration(period.total_seconds or 0)
    local metrics={}
    metrics[#metrics+1]={label="阅读天数",value=tostring(math.floor(tonumber(period.read_days) or 0)).."天"}
    metrics[#metrics+1]={label="日均阅读",value=short_duration(period.day_average_seconds or 0)}
    if kind=="local" then
        metrics[#metrics+1]={label="阅读页数",value=tostring(math.floor(tonumber(period.pages) or 0)).."页"}
    else
        local compare=compare_text(period.compare)
        if compare then metrics[#metrics+1]={label="周期变化",value=compare} end
    end
    local metric_count=math.max(1,#metrics)
    local metric_w=math.max(1,math.floor(inner_w/metric_count))
    local metric_row=HorizontalGroup:new{align="center"}
    for index,item in ipairs(metrics) do
        local actual=index==metric_count and math.max(1,inner_w-metric_w*(metric_count-1)) or metric_w
        metric_row[#metric_row+1]=metric_block(item.label,item.value,actual,metric_h)
    end
    return card(width,height,VerticalGroup:new{align="left",
        Ui.textbox(title,inner_w,title_h,Skin.face("smallinfofont",9.7,13.0,8.1),{
            bold=true,alignment="left",fgcolor=Blitbuffer.COLOR_BLACK,
        }),
        Ui.textbox(main,inner_w,main_h,Skin.face("cfont",23.0,30.0,18.5),{
            bold=true,alignment="left",fgcolor=Blitbuffer.COLOR_BLACK,
            height_overflow_show_ellipsis=true,
        }),
        metric_row,
    },pad)
end

local function check_circle(checked,size)
    if checked then
        return Skin.frame(size,size,{
            bordersize=0,padding=0,radius=math.floor(size/2),
            background=Blitbuffer.COLOR_BLACK,color=Blitbuffer.COLOR_BLACK,
        },Widget:new{dimen=Geom:new{w=1,h=1}})
    end
    return Skin.frame(size,size,{
        bordersize=math.max(1,Skin.line("thick")),padding=0,radius=math.floor(size/2),
        background=Blitbuffer.COLOR_WHITE,color=Blitbuffer.COLOR_BLACK,
    },Widget:new{dimen=Geom:new{w=1,h=1}})
end

local function weekly_visual(kind,period,width,height)
    local pad=Skin.dp(8,6,12)
    local inner_w=math.max(1,width-pad*2)
    local inner_h=math.max(1,height-pad*2)
    local title_h=math.max(Skin.dp(23,20,31),math.floor(inner_h*.15))
    local check_h=math.max(Skin.dp(46,40,60),math.floor(inner_h*.28))
    local chart_h=math.max(1,inner_h-title_h-check_h)
    local week_anchor=os.time()
    if period.is_current~=true and tonumber(period.base_time) and tonumber(period.base_time)>0 then
        week_anchor=tonumber(period.base_time)+6*86400+12*3600
    end
    local rows=HomeData.week_rows(period.daily,week_anchor)
    local max_seconds=0
    for _,row in ipairs(rows) do if not row.future then max_seconds=math.max(max_seconds,tonumber(row.seconds) or 0) end end
    local cell_w=math.max(1,math.floor(inner_w/7))
    local label_h=math.max(Skin.dp(18,16,24),math.floor(chart_h*.22))
    local bars_h=math.max(1,chart_h-label_h)
    local chart=OverlapGroup:new{dimen=Geom:new{w=inner_w,h=chart_h},allow_mirroring=false}
    chart[#chart+1]=OffsetContainer:new{x_off=0,y_off=bars_h-Skin.line("thin"),LineWidget:new{
        background=Blitbuffer.COLOR_LIGHT_GRAY,dimen=Geom:new{w=inner_w,h=Skin.line("thin")},
    }}
    for index,row in ipairs(rows) do
        local seconds=math.max(0,tonumber(row.seconds) or 0)
        local bh=max_seconds>0 and math.floor(seconds/max_seconds*math.max(1,bars_h-Skin.dp(5,4,7))+.5) or 0
        local bw=math.max(Skin.dp(9,7,13),math.floor(cell_w*.42))
        local bx=(index-1)*cell_w+math.floor((cell_w-bw)/2)
        if bh>0 then
            chart[#chart+1]=OffsetContainer:new{x_off=bx,y_off=math.max(0,bars_h-bh),LineWidget:new{
                background=Blitbuffer.COLOR_BLACK,dimen=Geom:new{w=bw,h=bh},
            }}
        end
        chart[#chart+1]=OffsetContainer:new{x_off=(index-1)*cell_w,y_off=bars_h,
            Ui.textbox(WEEKDAY[index],cell_w,label_h,Skin.face("smallinfofont",8.7,11.6,7.2),{
                bold=true,alignment="center",halign="center",fgcolor=Blitbuffer.COLOR_BLACK,
            })}
    end

    local check_box_h=math.max(1,math.floor(check_h*.58))
    local day_label_h=math.max(1,check_h-check_box_h)
    local box_size=math.max(Skin.dp(19,16,26),math.min(math.floor(cell_w*.68),check_box_h))
    local boxes=HorizontalGroup:new{align="center"}
    local labels=HorizontalGroup:new{align="center"}
    local threshold=1
    for index,row in ipairs(rows) do
        local checked=not row.future and (tonumber(row.seconds) or 0)>=threshold
        boxes[#boxes+1]=CenterContainer:new{dimen=Geom:new{w=cell_w,h=check_box_h},check_circle(checked,box_size)}
        labels[#labels+1]=Ui.textbox(row.future and "" or short_duration(row.seconds),cell_w,day_label_h,Skin.face("smallinfofont",7.6,10.2,6.2),{
            bold=true,alignment="center",halign="center",fgcolor=Blitbuffer.COLOR_BLACK,height_overflow_show_ellipsis=true,
        })
    end
    return card(width,height,VerticalGroup:new{align="left",
        Ui.textbox("阅读节奏",inner_w,title_h,Skin.face("cfont",11.8,15.8,9.8),{bold=true,alignment="left"}),
        chart,
        VerticalGroup:new{align="left",boxes,labels},
    },pad)
end

local function intensity_color(seconds,future)
    if future then return Blitbuffer.COLOR_WHITE end
    seconds=math.max(0,tonumber(seconds) or 0)
    if seconds<=0 then return Blitbuffer.COLOR_WHITE end
    if seconds<15*60 then return Blitbuffer.COLOR_GRAY end
    if seconds<45*60 then return Blitbuffer.COLOR_DARK_GRAY end
    return Blitbuffer.COLOR_BLACK
end

local function monthly_calendar(period,width,height)
    local pad=Skin.dp(8,6,12)
    local inner_w=math.max(1,width-pad*2)
    local inner_h=math.max(1,height-pad*2)
    local title_h=math.max(Skin.dp(23,20,31),math.floor(inner_h*.14))
    local weekday_h=math.max(Skin.dp(18,16,24),math.floor(inner_h*.10))
    local grid_h=math.max(1,inner_h-title_h-weekday_h)
    local rows=HomeData.month_rows(period.daily,period.base_time,os.time())
    local cell_w=math.max(1,math.floor(inner_w/7))
    local day_rows=6
    local cell_h=math.max(1,math.floor(grid_h/day_rows))
    local weekday_row=HorizontalGroup:new{align="center"}
    for i=1,7 do weekday_row[#weekday_row+1]=Ui.textbox(WEEKDAY[i],cell_w,weekday_h,Skin.face("smallinfofont",8.5,11.4,7.1),{
        bold=true,alignment="center",halign="center",fgcolor=Blitbuffer.COLOR_BLACK,
    }) end
    local grid=OverlapGroup:new{dimen=Geom:new{w=inner_w,h=grid_h},allow_mirroring=false}
    if #rows>0 then
        local first_wd=tonumber(rows[1].weekday) or 1
        local first_col=first_wd==0 and 7 or first_wd
        for index,row in ipairs(rows) do
            local linear=(first_col-1)+(index-1)
            local r=math.floor(linear/7)
            local c=linear%7
            if r<day_rows then
                local box_size=math.max(Skin.dp(18,15,24),math.min(math.floor(cell_w*.72),math.floor(cell_h*.72)))
                local bx=c*cell_w+math.floor((cell_w-box_size)/2)
                local by=r*cell_h+math.floor((cell_h-box_size)/2)
                local bg=intensity_color(row.seconds,row.future)
                local dark=bg==Blitbuffer.COLOR_DARK_GRAY or bg==Blitbuffer.COLOR_BLACK
                local day=tostring(row.date or ""):match("%-(%d%d)$") or tostring(index)
                grid[#grid+1]=OffsetContainer:new{x_off=bx,y_off=by,Skin.frame(box_size,box_size,{
                    bordersize=bg==Blitbuffer.COLOR_WHITE and Skin.line("thin") or 0,padding=0,radius=Skin.radius(3,2,5),
                    background=bg,color=Blitbuffer.COLOR_LIGHT_GRAY,
                },Ui.textbox(tostring(tonumber(day) or day),box_size,box_size,Skin.face("smallinfofont",8.1,10.9,6.8),{
                    bold=true,alignment="center",halign="center",fgcolor=dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                }))}
            end
        end
    end
    return card(width,height,VerticalGroup:new{align="left",
        Ui.textbox("阅读日历",inner_w,title_h,Skin.face("cfont",11.8,15.8,9.8),{bold=true,alignment="left"}),
        weekday_row,grid,
    },pad)
end

local function bucket_visual(period,width,height,heading)
    local pad=Skin.dp(8,6,12)
    local inner_w=math.max(1,width-pad*2)
    local inner_h=math.max(1,height-pad*2)
    local title_h=math.max(Skin.dp(23,20,31),math.floor(inner_h*.15))
    local chart_h=math.max(1,inner_h-title_h)
    local buckets=type(period.buckets)=="table" and period.buckets or type(period.daily)=="table" and period.daily or {}
    local start=1
    if #buckets>12 then start=math.max(1,#buckets-7) end
    local visible={}
    for i=start,#buckets do visible[#visible+1]=buckets[i] end
    if #visible==0 then visible={{label="",seconds=0}} end
    local max_seconds=0
    for _,item in ipairs(visible) do if not item.future then max_seconds=math.max(max_seconds,tonumber(item.seconds) or 0) end end
    local count=#visible
    local cell_w=math.max(1,math.floor(inner_w/count))
    local label_h=math.max(Skin.dp(20,17,26),math.floor(chart_h*.22))
    local bars_h=math.max(1,chart_h-label_h)
    local chart=OverlapGroup:new{dimen=Geom:new{w=inner_w,h=chart_h},allow_mirroring=false}
    chart[#chart+1]=OffsetContainer:new{x_off=0,y_off=bars_h-Skin.line("thin"),LineWidget:new{
        background=Blitbuffer.COLOR_LIGHT_GRAY,dimen=Geom:new{w=inner_w,h=Skin.line("thin")},
    }}
    for index,item in ipairs(visible) do
        local seconds=math.max(0,tonumber(item.seconds) or 0)
        local bh=max_seconds>0 and math.floor(seconds/max_seconds*math.max(1,bars_h-Skin.dp(5,4,7))+.5) or 0
        local bw=math.max(Skin.dp(8,6,12),math.floor(cell_w*.43))
        if bh>0 and not item.future then
            chart[#chart+1]=OffsetContainer:new{x_off=(index-1)*cell_w+math.floor((cell_w-bw)/2),y_off=math.max(0,bars_h-bh),LineWidget:new{
                background=Blitbuffer.COLOR_BLACK,dimen=Geom:new{w=bw,h=bh},
            }}
        end
        chart[#chart+1]=OffsetContainer:new{x_off=(index-1)*cell_w,y_off=bars_h,
            Ui.textbox(tostring(item.label or ""),cell_w,label_h,Skin.face("smallinfofont",7.9,10.6,6.5),{
                bold=true,alignment="center",halign="center",fgcolor=Blitbuffer.COLOR_BLACK,
                height_overflow_show_ellipsis=true,
            })}
    end
    return card(width,height,VerticalGroup:new{align="left",
        Ui.textbox(heading or "阅读趋势",inner_w,title_h,Skin.face("cfont",11.8,15.8,9.8),{bold=true,alignment="left"}),chart,
    },pad)
end

local function rank_card(kind,key,period,width,height)
    local pad=Skin.dp(8,6,12)
    local inner_w=math.max(1,width-pad*2)
    local inner_h=math.max(1,height-pad*2)
    local title_h=math.max(Skin.dp(24,21,32),math.floor(inner_h*.12))
    local rank=type(period.rank)=="table" and period.rank or {}
    local limit=math.min(5,#rank)
    local extra_h=(kind=="weread" and (key=="annually" or key=="overall")) and math.max(Skin.dp(26,22,34),math.floor(inner_h*.12)) or 0
    local row_h=limit>0 and math.max(1,math.floor((inner_h-title_h-extra_h)/limit)) or math.max(1,inner_h-title_h-extra_h)
    local body=VerticalGroup:new{align="left"}
    body[#body+1]=Ui.textbox("读书排行",inner_w,title_h,Skin.face("cfont",11.8,15.8,9.8),{bold=true,alignment="left"})
    if limit==0 then
        body[#body+1]=Ui.textbox("当前周期暂无可用的逐书统计",inner_w,row_h,Skin.face("smallinfofont",9.4,12.6,7.9),{
            bold=true,alignment="center",halign="center",fgcolor=Blitbuffer.COLOR_BLACK,
        })
    else
        local max_seconds=0
        for i=1,limit do max_seconds=math.max(max_seconds,tonumber(rank[i].seconds) or 0) end
        for i=1,limit do
            local item=rank[i]
            local text_h=math.max(1,math.floor(row_h*.58))
            local bar_h=math.max(Skin.line("thick"),math.floor(row_h*.10))
            local left_w=math.max(1,math.floor(inner_w*.70))
            local right_w=math.max(1,inner_w-left_w)
            body[#body+1]=OverlapGroup:new{dimen=Geom:new{w=inner_w,h=row_h},allow_mirroring=false,
                OffsetContainer:new{x_off=0,y_off=0,HorizontalGroup:new{align="center",
                    Ui.textbox(tostring(i)..". "..tostring(item.title or "未命名"),left_w,text_h,Skin.face("cfont",9.6,12.8,8.0),{
                        bold=i==1,alignment="left",height_overflow_show_ellipsis=true,
                    }),
                    Ui.textbox(short_duration(item.seconds),right_w,text_h,Skin.face("smallinfofont",9.2,12.3,7.7),{
                        bold=true,alignment="right",halign="right",fgcolor=Blitbuffer.COLOR_BLACK,height_overflow_show_ellipsis=true,
                    }),
                }},
                OffsetContainer:new{x_off=0,y_off=math.max(text_h,math.floor(row_h*.72)),LineWidget:new{
                    background=Blitbuffer.COLOR_LIGHT_GRAY,dimen=Geom:new{w=inner_w,h=bar_h},
                }},
                OffsetContainer:new{x_off=0,y_off=math.max(text_h,math.floor(row_h*.72)),LineWidget:new{
                    background=Blitbuffer.COLOR_BLACK,dimen=Geom:new{
                        w=max_seconds>0 and math.max(1,math.floor(inner_w*(tonumber(item.seconds) or 0)/max_seconds+.5)) or 1,
                        h=bar_h,
                    },
                }},
            }
        end
    end
    if extra_h>0 then
        local extra=""
        if tostring(period.prefer_time_word or "")~="" then extra="常读时段："..tostring(period.prefer_time_word) end
        local cats=type(period.prefer_category)=="table" and period.prefer_category or {}
        if #cats>0 then
            local cat=tostring(cats[1].categoryTitle or cats[1].parentCategoryTitle or "")
            if cat~="" then extra=(extra~="" and (extra.."   ") or "").."阅读偏好："..cat end
        end
        if extra=="" and tonumber(period.read_rate) then extra="文字阅读占比："..tostring(math.floor(period.read_rate+.5)).."%" end
        body[#body+1]=Ui.textbox(extra,inner_w,extra_h,Skin.face("smallinfofont",8.7,11.6,7.2),{
            bold=true,alignment="left",fgcolor=Blitbuffer.COLOR_BLACK,height_overflow_show_ellipsis=true,
        })
    end
    return card(width,height,body,pad)
end

local function loading_card(period,width,height)
    local text=period and period.loading==true and ("正在获取 "..tostring(period.label or "这一周期").."…") or "正在获取这一周期的数据…"
    return card(width,height,Ui.textbox(text,math.max(1,width-Skin.dp(20,16,28)),math.max(1,height-Skin.dp(20,16,28)),Skin.face("cfont",11.0,14.8,9.2),{
        alignment="center",halign="center",fgcolor=Blitbuffer.COLOR_BLACK,
    }),Skin.dp(10,8,14))
end

local Dialog = InputContainer:extend{
    name="miuread_reading_stats_dialog",_miuread_transient=true,_miuread_modal_surface=true,
    covers_fullscreen=true,stop_events_propagation=true,opts=nil,data=nil,kind="local",
    selected_key="weekly",closed=false,pending_action=nil,
}
function Dialog:handleEvent(event) return InputContainer.handleEvent(self,event) end

function Dialog:_close(action)
    if action and not self.pending_action then self.pending_action=action end
    if self.closed then return true end
    self.closed=true
    UIManager:close(self)
    return true
end

function Dialog:_period()
    return get_period(self.kind,self.data,self.selected_key)
end

function Dialog:_tab(label,key,width,height)
    local selected=self.selected_key==key
    local layers=OverlapGroup:new{dimen=Geom:new{w=width,h=height},allow_mirroring=false}
    layers[#layers+1]=Ui.textbox(label,width,height,Skin.face("cfont",11.2,15.0,9.4),{
        bold=true,alignment="center",halign="center",fgcolor=Blitbuffer.COLOR_BLACK,
    })
    if selected then
        local lw=math.max(Skin.dp(28,24,40),math.floor(width*.34))
        layers[#layers+1]=OffsetContainer:new{x_off=math.floor((width-lw)/2),y_off=height-Skin.line("thick"),LineWidget:new{
            background=Blitbuffer.COLOR_BLACK,dimen=Geom:new{w=lw,h=Skin.line("thick")},
        }}
    end
    local tap=TapBox:new{dimen=Geom:new{w=width,h=height},callback=function()
        if self.selected_key~=key then self.selected_key=key; self:_rebuild() end
    end}
    tap[1]=layers
    return tap
end

function Dialog:_period_nav(period,width,height)
    if self.selected_key=="overall" then
        return Ui.textbox("全部阅读记录",width,height,Skin.face("smallinfofont",9.4,12.6,7.9),{
            bold=true,alignment="center",halign="center",fgcolor=Blitbuffer.COLOR_BLACK,
        })
    end
    local side=math.max(Skin.dp(48,42,64),math.floor(width*.12))
    local middle=math.max(1,width-side*2)
    local left=TapBox:new{dimen=Geom:new{w=side,h=height},enabled=type(self.opts.on_shift_period)=="function",callback=function()
        self.opts.on_shift_period(self.selected_key,-1)
    end}
    left[1]=Ui.icon("back",side,height,Skin.dp(18,16,24),{face=Skin.face("cfont",16,21,13)})
    local current=period and period.is_current==true
    local right=TapBox:new{dimen=Geom:new{w=side,h=height},enabled=not current and type(self.opts.on_shift_period)=="function",callback=function()
        self.opts.on_shift_period(self.selected_key,1)
    end}
    right[1]=Ui.icon("chevron-right",side,height,Skin.dp(18,16,24),{
        face=Skin.face("cfont",16,21,13),fgcolor=(not current and type(self.opts.on_shift_period)=="function") and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
    local center=TapBox:new{dimen=Geom:new{w=middle,h=height},enabled=not current and type(self.opts.on_shift_period)=="function",callback=function()
        self.opts.on_shift_period(self.selected_key,0)
    end}
    center[1]=Ui.textbox(tostring(period and period.label or "当前周期"),middle,height,Skin.face("cfont",10.3,13.9,8.7),{
        bold=true,alignment="center",halign="center",fgcolor=Blitbuffer.COLOR_BLACK,height_overflow_show_ellipsis=true,
    })
    return HorizontalGroup:new{align="center",left,center,right}
end

function Dialog:_build_content()
    local sw,sh=Screen:getWidth(),Screen:getHeight()
    local portrait=sw<sh
    local outer=Skin.dp(7,6,12)
    local pad=Skin.dp(11,9,16)
    local panel_w=math.max(1,sw-outer*2)
    local panel_h=sh
    local content_w=math.max(1,panel_w-pad*2)
    local header_h=math.max(Skin.dp(44,39,60),math.floor(sh*(portrait and .043 or .070)))
    local subtitle_h=Skin.dp(24,21,32)
    local tab_h=math.max(Skin.dp(38,33,50),math.floor(sh*(portrait and .036 or .060)))
    local nav_h=math.max(Skin.dp(38,33,50),math.floor(sh*(portrait and .035 or .058)))
    local gap=Skin.dp(7,5,10)
    self.dimen=Geom:new{x=0,y=0,w=sw,h=sh}
    self.frame_dimen=Geom:new{x=outer,y=0,w=panel_w,h=panel_h}

    local root=OverlapGroup:new{dimen=self.dimen:copy(),allow_mirroring=false}
    root[#root+1]=OffsetContainer:new{x_off=outer,y_off=0,Skin.frame(panel_w,panel_h,{
        bordersize=0,padding=0,radius=0,background=Blitbuffer.COLOR_WHITE,color=Blitbuffer.COLOR_WHITE,
    },Widget:new{dimen=Geom:new{w=1,h=1}})}
    local y=pad
    local side=Skin.dp(44,38,58)
    local back=TapBox:new{dimen=Geom:new{w=side,h=header_h},callback=function() self:_close(self.opts.on_back) end}
    back[1]=Ui.icon("back",side,header_h,Skin.dp(21,18,28),{face=Skin.face("cfont",20,26,17)})
    local home=TapBox:new{dimen=Geom:new{w=side,h=header_h},callback=function() self:_close(self.opts.on_home) end}
    home[1]=Ui.icon("home",side,header_h,Skin.dp(20,17,27),{face=Skin.face("cfont",16,21,13.5)})
    root[#root+1]=OffsetContainer:new{x_off=outer+pad,y_off=y,HorizontalGroup:new{align="center",
        back,
        Ui.textbox(self.kind=="weread" and "微信读书阅读统计" or "本地阅读统计",math.max(1,content_w-side*2),header_h,Skin.face("cfont",16.0,20.6,13.4),{
            bold=true,alignment="center",halign="center",
        }),
        home,
    }}
    y=y+header_h
    root[#root+1]=OffsetContainer:new{x_off=outer+pad,y_off=y,
        Ui.textbox(self.kind=="weread" and "微信读书网页端数据" or "KOReader 本机阅读记录",content_w,subtitle_h,Skin.face("smallinfofont",9.0,12.0,7.5),{
            bold=true,alignment="center",halign="center",fgcolor=Blitbuffer.COLOR_BLACK,
        })}
    y=y+subtitle_h

    local tabs={{"周","weekly"},{"月","monthly"},{"年","annually"},{"总","overall"}}
    local tab_w=math.max(1,math.floor(content_w/4))
    for i,item in ipairs(tabs) do
        local x=outer+pad+(i-1)*tab_w
        local actual=i==4 and math.max(1,outer+pad+content_w-x) or tab_w
        root[#root+1]=OffsetContainer:new{x_off=x,y_off=y,self:_tab(item[1],item[2],actual,tab_h)}
    end
    y=y+tab_h

    local period=self:_period()
    root[#root+1]=OffsetContainer:new{x_off=outer+pad,y_off=y,self:_period_nav(period,content_w,nav_h)}
    y=y+nav_h+gap

    local available_h=math.max(1,sh-pad-y)
    if not period or period.loading==true then
        root[#root+1]=OffsetContainer:new{x_off=outer+pad,y_off=y,loading_card(period,content_w,math.max(Skin.dp(180,150,240),math.floor(available_h*.45)))}
    else
        local summary_h=math.max(Skin.dp(130,112,178),math.floor(available_h*.20))
        local visual_h=math.max(Skin.dp(210,178,290),math.floor(available_h*.34))
        local rank_h=math.max(1,available_h-summary_h-visual_h-gap*2)
        root[#root+1]=OffsetContainer:new{x_off=outer+pad,y_off=y,summary_card(self.kind,self.selected_key,period,content_w,summary_h)}
        y=y+summary_h+gap
        local visual
        if self.selected_key=="weekly" then visual=weekly_visual(self.kind,period,content_w,visual_h)
        elseif self.selected_key=="monthly" then visual=monthly_calendar(period,content_w,visual_h)
        elseif self.selected_key=="annually" then visual=bucket_visual(period,content_w,visual_h,"月度阅读趋势")
        else visual=bucket_visual(period,content_w,visual_h,"历年阅读趋势") end
        root[#root+1]=OffsetContainer:new{x_off=outer+pad,y_off=y,visual}
        y=y+visual_h+gap
        root[#root+1]=OffsetContainer:new{x_off=outer+pad,y_off=y,rank_card(self.kind,self.selected_key,period,content_w,rank_h)}
    end
    self[1]=root
end

function Dialog:_rebuild()
    local old=self.frame_dimen and self.frame_dimen:copy() or nil
    self:_build_content()
    local dirty=self.frame_dimen
    if old then dirty=old:combine(self.frame_dimen) end
    UIManager:setDirty(self,function() return "ui",Skin.expand_region(dirty) end)
end

function Dialog:init()
    self.opts=self.opts or {}
    self.data=self.data or {}
    self.kind=tostring(self.kind or "local")
    self.selected_key=tostring(self.opts.initial_category or "weekly")
    self:_build_content()
    self.ges_events={SwipeDismiss={GestureRange:new{ges="swipe",range=self.dimen}}}
    if Device:hasKeys() and Device.input and Device.input.group and Device.input.group.Back then
        self.key_events={Close={{Device.input.group.Back}}}
    end
end
function Dialog:onSwipeDismiss(_,ges)
    if ges and ges.direction=="south" then return self:_close(self.opts.on_back) end
    return false
end
function Dialog:onClose() return self:_close(self.opts.on_back) end
function Dialog:onShow()
    UIManager:setDirty(self,function() return "ui",Skin.expand_region(self.frame_dimen) end)
end
function Dialog:onCloseWidget()
    local region=self.frame_dimen and Skin.expand_region(self.frame_dimen) or nil
    local action=self.pending_action
    self.pending_action=nil
    self.closed=true
    if live_dialog==self then live_dialog=nil end
    if region then UIManager:setDirty(nil,function() return "ui",region end) end
    if action then UIManager:scheduleIn(.04,function()
        local ok,err=pcall(action)
        if not ok then logger.warn("[MiuRead][ReadingStats] close action failed",tostring(err)) end
    end) end
end

local M={}
function M.close()
    if live_dialog and not live_dialog.closed then live_dialog:_close(nil) end
    live_dialog=nil
end
function M.show(kind,data,options)
    TransientGuard.close_all()
    M.close()
    local ok,dialog=pcall(Dialog.new,Dialog,{kind=tostring(kind or "local"),data=data,opts=type(options)=="table" and options or {}})
    if not ok or not dialog then
        logger.warn("[MiuRead][ReadingStats] build failed",tostring(dialog))
        return nil,tostring(dialog)
    end
    live_dialog=dialog
    UIManager:show(dialog,"ui",dialog.frame_dimen)
    return dialog
end
return M
