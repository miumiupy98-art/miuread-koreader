-- 6.3.0-beta.3: end-to-end mocked choice/preflight, not just source text.
local path="miuread.koplugin/main.lua"
local file=assert(io.open(path,"rb")); local source=file:read("*a");file:close()
local function extract(left,right)
 local a=assert(source:find(left,1,true));local b=assert(source:find(right,a+#left,1,true))
 return source:sub(a,b-1)
end
local defs=extract('function Plugin:_download_preflight(', '\n-- Preserve explicit edition choice.')
  ..'\n'..extract('function Plugin:choose_download_mode(', '\nfunction Plugin:choose_download(')
local choices, launched, notices, queued, downloads={},{},{},{},{}
local ActionSheet={show=function(opts) choices[#choices+1]=opts;return opts end}
local UIManager={scheduleIn=function(_,_,fn)fn()end}
local HomeData={device_state=function()return _G.test_device_state end}
local function copied(v)
 if type(v)~='table' then return v end
 local o={}; for k,x in pairs(v) do o[k]=copied(x) end;return o
end
local U={copy=copied}
local b4_content_only_options=function(opts)return copied(opts)end
local Plugin={}
local env=setmetatable({Plugin=Plugin,ActionSheet=ActionSheet,UIManager=UIManager,
 HomeData=HomeData,b4_content_only_options=b4_content_only_options,U=U},{__index=_G})
local chunk
if setfenv then
 chunk=assert(loadstring(defs..'\nreturn Plugin'));setfenv(chunk,env)
else
 chunk=assert(load('local Plugin,ActionSheet,UIManager,HomeData,b4_content_only_options,U=...\n'..defs..'\nreturn Plugin'))
 local f=chunk;chunk=function()return f(Plugin,ActionSheet,UIManager,HomeData,b4_content_only_options,U)end
end
local P=chunk()
local book={title='sample'}
local function instance()
 return setmetatable({
 _download_preflight=P._download_preflight,
 _notice_enabled=function()return true end,
 _set_notice_enabled=function(_,key,value)notices[#notices+1]={key,value}end,
 _active_reader_ui=function()return _G.test_reader and {} or nil end,
 store={preferences=function()return {download_reader_policy='ask'}end},
 _queue_download=function(_,b,o,after,flags)queued[#queued+1]=flags end,
 download=function(_,b,o,after,_,bg)launched[#launched+1]={options=o,background=bg}end,
 status_toast=function()end,toast=function()end,info=function(_,t)notices[#notices+1]=t end,
 show_downloads=function()downloads[#downloads+1]=true end,
 },{__index=P})
end
local p=instance()
_G.test_reader=false;_G.test_device_state={battery=80,charging=false,storage_free=1000000000}
p:choose_download_mode(book,{annotations=true,range_start_index=2,range_end_index=7},false)
assert(#choices==1 and #choices[1].actions==3)
choices[1].actions[1].callback()
assert(#launched==1 and launched[1].background==true and launched[1].options.range_end_index==7)
_G.test_reader=true
p._download_launch_pending=nil
p:choose_download_mode(book,{annotations=false},false)
choices[#choices].actions[2].callback()
assert(#choices==3 and choices[3].title=='阅读中下载')
choices[3].actions[2].callback()
assert(#queued==1 and queued[1].defer_until_reader_closed==true)
_G.test_reader=false
_G.test_device_state={battery=11,charging=false,storage_free=200*1024*1024}
p:choose_download_mode(book,{},false)
choices[#choices].actions[1].callback()
assert(choices[#choices].title=='存储空间提醒')
choices[#choices].actions[3].callback()
assert(choices[#choices].title=='低电量提醒')
choices[#choices].actions[2].callback()
assert(#notices==2 and notices[1][1]=='low_storage' and notices[2][1]=='low_battery')
assert(#launched==2 and launched[2].background==true)
_G.test_device_state={battery=80,storage_free=30*1024*1024}
local before=#choices
local ok=p:_download_preflight(function()error('should not download')end)
assert(ok==false and #choices==before,'unsafe disk must block startup')
print('PASS beta633: shared download choices, deferred reader, safety notices, opt-out and hard storage stop')
