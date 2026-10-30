local root='miuread.koplugin'
package.path=root..'/?.lua;'..root..'/?/init.lua;'..package.path
local function cls(name,base)
 local C={name=name}
 C.__index=C
 setmetatable(C,{__index=base})
 function C:extend(x)
  local child=x or {} child.__index=child
  setmetatable(child,{__index=self})
  return child
 end
 function C:new(x)
  local o=x or {} setmetatable(o,{__index=self})
  if o.init then o:init() end
  return o
 end
 function C:getSize()
  if self.dimen then return self.dimen end
  local content=self[1]
  local size=content and content:getSize() or {w=0,h=0}
  if self.name=='HorizontalGroup' then
   local w,h=0,0
   for _,ch in ipairs(self) do local s=ch:getSize();w=w+s.w;h=math.max(h,s.h) end
   return {w=w,h=h}
  end
  if self.name=='VerticalGroup' then
   local w,h=0,0
   for _,ch in ipairs(self) do local s=ch:getSize();w=math.max(w,s.w);h=h+s.h end
   return {w=w,h=h}
  end
  if self.name=='FrameContainer' then
   local inset=2*((self.padding or 0)+(self.bordersize or 0))
   return {w=size.w+inset,h=size.h+inset}
  end
  return size
 end
 function C:setText(s) self.text=s end
 function C:setPercentage(p) self.percentage=p end
 function C:paintTo(bb,x,y)
  if self.dimen then self.dimen.x=x;self.dimen.y=y end
  if self[1] then self[1]:paintTo(bb,x,y) end
 end
 return C
end
local base=cls('Widget')
local function supply(name,T)package.preload[name]=function()return T end end
local color={COLOR_WHITE=1,COLOR_BLACK=0}
supply('ffi/blitbuffer',color)
local geom={new=function(_,v)return setmetatable(v,{__index={copy=function(self) return {x=self.x,y=self.y,w=self.w,h=self.h} end}}) end}
supply('ui/geometry',geom)
local sw,sh=600,800
local screen={getWidth=function()return sw end,getHeight=function()return sh end,getSize=function()return geom:new{w=sw,h=sh} end,scaleBySize=function(_,v)return v end}
supply('device',{screen=screen})
supply('ui/font',{getFace=function(_,_)return {} end})
for _,n in ipairs({'centercontainer','framecontainer','horizontalgroup','horizontalspan','inputcontainer','overlapgroup','progresswidget','textwidget','verticalgroup','verticalspan'}) do
 local C=base:extend({name=({centercontainer='CenterContainer',framecontainer='FrameContainer',horizontalgroup='HorizontalGroup',verticalgroup='VerticalGroup',inputcontainer='InputContainer',overlapgroup='OverlapGroup',progresswidget='ProgressWidget',textwidget='TextWidget',verticalgroup='VerticalGroup',verticalspan='VerticalSpan'})[n]})
 if n=='horizontalspan' or n=='verticalspan' then
  function C:getSize()return {w=self.width or 0,h=self.width or 0} end
 elseif n=='textwidget' then
  function C:getSize()return {w=math.min(self.max_width or 200,#(self.text or '')*12),h=18} end
 elseif n=='progresswidget' then
  function C:getSize()return {w=self.width,h=self.height} end
 end
 supply('ui/widget/'..n,C)
 if n=='centercontainer' or n=='framecontainer' or n=='inputcontainer' then supply('ui/widget/container/'..n,C) end
end
supply('ui/gesturerange',{new=function(_,v)return v end})
local shows={}
local ui={}
function ui:show(w,_)shows[w]=true;w:onShow() end
function ui:isWidgetShown(w)return shows[w] or false end
function ui:setDirty(w,mode,region) assert(region==nil or (region.w and region.h)) end
function ui:close(w,mode,region) shows[w]=false;w:onCloseWidget() end
function ui:nextTick(cb)cb() end
supply('ui/uimanager',ui)
supply('logger',{warn=function()end})
supply('miuread.ui_components',{icon=function(_,w,h) return base:new{dimen={w=w,h=h}} end,align=function(widget,w,h)return base:new{dimen={w=w,h=h},widget}end})
local Progress=require('miuread.comment_progress')
local events={}
local dialog=Progress:new{
 on_pause=function(v)events[#events+1]=v and 'pause' or 'resume' end,
 on_background=function()events[#events+1]='background' end,
 on_cancel=function()events[#events+1]='cancel' end,
}
assert(dialog.popup_dimen.h>20 and dialog.popup_dimen.h<130,'not compact '..tostring(dialog.popup_dimen.h))
assert(dialog.popup_dimen.w<600)
assert(dialog:show())
dialog:set_state{current=3,total=10,paused=false}
assert(dialog.progress.percentage==0.3)
assert(dialog.count_label.text:find('3/10',1,true))
local function collect(node,out)
 if node.callback and node.onTapSelect then out[#out+1]=node end
 for _,child in ipairs(node) do if type(child)=='table' then collect(child,out) end end
end
local buttons={};collect(dialog,buttons)
assert(#buttons==3,'buttons '..#buttons)
buttons[2]:onTapSelect();assert(events[1]=='pause')
dialog:set_state{current=3,total=10,paused=true}
buttons={};collect(dialog,buttons);assert(#buttons==3)
buttons[2]:onTapSelect();assert(events[2]=='resume')
buttons[1]:onTapSelect();assert(events[3]=='background')
buttons[3]:onTapSelect();assert(events[4]=='cancel')
dialog:close('test')
assert(dialog.closed==true)
-- Both portrait and landscape must remain contained, without fullscreen ink.
sw,sh=800,600
local landscape=Progress:new{}
assert(landscape.popup_dimen.w<sw and landscape.popup_dimen.h<120)
assert(landscape.popup_dimen.x>=0 and landscape.popup_dimen.y>=0)
assert(landscape.popup_dimen.y+landscape.popup_dimen.h<=sh)
print('6.3 flat compact UI mocked runtime PASS, portrait height='..dialog.popup_dimen.h..'px, landscape height='..landscape.popup_dimen.h..'px')
