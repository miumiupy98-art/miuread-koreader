-- Simulate ActionSheet build failure: must show a paginated, labeled menu,
-- never a native ButtonDialog grid with missing text.
local f=assert(io.open('miuread.koplugin/miuread/action_sheet.lua','rb'))
local source=f:read('*a');f:close()
local first=assert(source:find('local function show_fallback(opts, reason)',1,true))
local snippet=source:sub(first)
local fallback_calls,info_calls={},{}
local ReaderSettingsDialog={show=function(opts)
 fallback_calls[#fallback_calls+1]=opts
 return {name='safe_fallback'}
end}
local UIManager={show=function(_,m)info_calls[#info_calls+1]=m end,
 close=function()end}
local SheetWidget={new=function()error('invalid geometry during landscape rotation')end}
local TransientGuard={close_all=function()end}
local InfoMessage={new=function(_,arg)return arg end}
local logger={warn=function()end, info=function()end}
local MAX_PRIMARY_ACTIONS=10
local env=setmetatable({ReaderSettingsDialog=ReaderSettingsDialog,UIManager=UIManager,
 SheetWidget=SheetWidget,TransientGuard=TransientGuard,InfoMessage=InfoMessage,
 logger=logger,MAX_PRIMARY_ACTIONS=MAX_PRIMARY_ACTIONS},{__index=_G})
local chunk
if setfenv then
 chunk=assert(loadstring('local live_sheet=nil\n'..snippet));setfenv(chunk,env)
else
 local f2=assert(load('local ReaderSettingsDialog,UIManager,SheetWidget,TransientGuard,InfoMessage,logger,MAX_PRIMARY_ACTIONS=...\nlocal live_sheet=nil\n'..snippet))
 chunk=function()return f2(ReaderSettingsDialog,UIManager,SheetWidget,TransientGuard,InfoMessage,logger,MAX_PRIMARY_ACTIONS)end
end
local ActionSheet=chunk()
local actions={};for i=1,13 do actions[#actions+1]={label='项目'..i,icon='comment',callback=function()end}end
local result=ActionSheet.show{title='获取评论',subtitle='读取章节',actions=actions,
 footer_action={label='管理下载',icon='download',callback=function()end}}
assert(result.name=='safe_fallback')
assert(#fallback_calls==1)
local rows=fallback_calls[1].rows
assert(#rows==12,'bounded 10 + footer + close must be 12, got '..#rows)
assert(rows[1].label=='项目1' and rows[10].label=='项目10')
assert(rows[11].label=='管理下载' and rows[12].label=='关闭')
assert(#info_calls==0,'must not show unreadable native grid')
ReaderSettingsDialog.show=function()error('compatibility layout unavailable')end
local bad=ActionSheet.show{title='不可用',actions={{label='尝试'}}}
assert(bad.text=='菜单暂时无法显示，请返回后重试')
assert(#info_calls==1)
print('PASS beta633: failed ActionSheet renders labeled paginated fallback or explicit error')
