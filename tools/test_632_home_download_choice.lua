-- Reproduce the Home More -> notes download-choice flow without KOReader UI.
-- Run with Lua 5.1 / LuaJIT / texlua from the repository root.
local path="miuread.koplugin/main.lua"
local f=assert(io.open(path,"rb"));local source=f:read("*a");f:close()
local first=assert(source:find("function Plugin:choose_download_mode(",1,true))
local last=assert(source:find("\nfunction Plugin:choose_download(",first,true))
local snippet=source:sub(first,last-1)
local exposed={}
local shown={}
local actions={}
local ActionSheet={show=function(o) actions[#actions+1]=o;return o end}
local ButtonDialog={new=function(_,o) return o end}
local UIManager={
  show=function(_,d) shown[#shown+1]=d end,
  close=function() end,
  scheduleIn=function(_,_,cb) cb() end,
}
local function copy(v)
  if type(v)~="table" then return v end
  local result={}
  for k,x in pairs(v) do result[k]=copy(x) end
  return result
end
local U={copy=copy}
local function b4_content_only_options(input)
  local options=copy(type(input)=="table" and input or {})
  options.annotations=options.annotations==true
  return options
end
local Plugin={}
local chunk=assert((loadstring or load)(snippet.."\nreturn Plugin"))
-- The extracted method intentionally uses the test scope's dependencies.
if setfenv then
  local env=setmetatable({Plugin=Plugin,ActionSheet=ActionSheet,ButtonDialog=ButtonDialog,
    UIManager=UIManager,b4_content_only_options=b4_content_only_options,U=U},{__index=_G})
  setfenv(chunk,env)
else
  -- Lua 5.2+ has lexical _ENV; use a lexical wrapper for this simulation.
  local wrapper=assert(load("local Plugin,ActionSheet,ButtonDialog,UIManager,b4_content_only_options,U=...\n"..snippet.."\nreturn Plugin"))
  chunk=function() return wrapper(Plugin,ActionSheet,ButtonDialog,UIManager,b4_content_only_options,U) end
end
local P=chunk()
local book={bookId="demo123",title="测试书"}
local function instance()
  return setmetatable({
    _download_preflight=function(_,fn) fn(); return true end,
    _active_reader_ui=function() return nil end,
    status_toast=function() end,
    download=function(self,b,opt,after,_,background) exposed[#exposed+1]={b=b,opt=opt,background=background,after=after} end,
  },{__index=P})
end
local home=instance()
home:choose_download_mode(book,{annotations=true,range_start_index=2,range_end_index=5},false,{home_sheet=true})
assert(#actions==1 and #shown==0,"Home must never open the affected native ButtonDialog")
local ui=actions[1]
assert(ui.columns==1 and #ui.actions==3 and ui.title:find("公开想法",1,true),"Home options not visible as three rows")
assert(ui.actions[1].icon=="cloud" and ui.actions[2].icon=="download" and ui.actions[3].icon=="close")
assert(ui.actions[1].label=="后台下载" and ui.actions[2].label=="留在当前页面下载" and ui.actions[3].label=="取消")
ui.actions[1].callback()
assert(#exposed==1 and exposed[1].background==true and exposed[1].opt.annotations==true)
assert(exposed[1].opt.range_end_index==5,"Notes edition and range must remain intact")
local home2=instance()
home2:choose_download_mode(book,{annotations=false},false,{home_sheet=true})
assert(actions[2].title:find("正文",1,true))
actions[2].actions[2].callback()
assert(#exposed==2 and exposed[2].background==false and exposed[2].opt.annotations==false)
actions[2].actions[3].callback()
assert(#exposed==2,"Cancel must not launch a task")
local reader=instance()
reader:choose_download_mode(book,{annotations=false},false)
assert(#shown==0 and #actions==3 and #actions[3].actions==3,
  "Reader download must use the same ActionSheet surface")
print("PASS: Home/Reader notes and clean choices use visible ActionSheet rows; buttons preserve behavior")
