package.path="./miuread.koplugin/?.lua;"..package.path

local Geometry=require("miuread.modal_geometry")
local geom={}
local rect_methods={}
function geom:new(rect) return setmetatable(rect,{__index=rect_methods}) end
function rect_methods:copy() return geom:new{x=self.x,y=self.y,w=self.w,h=self.h} end
function rect_methods:combine(other) return geom:new(Geometry.union(self,other)) end
local screen={getWidth=function() return 758 end,getHeight=function() return 1024 end}
function screen:getSize() return geom:new{x=0,y=0,w=self:getWidth(),h=self:getHeight()} end
function screen:scaleBySize(value) return value end
local tasks,refreshes={},{}
local ui={_window_stack={}}
function ui:nextTick(fn) tasks[#tasks+1]=fn end
function ui:scheduleIn(_,fn) self:nextTick(fn) end
function ui:unschedule(fn)
    for i=#tasks,1,-1 do if tasks[i]==fn then table.remove(tasks,i) end end
end
function ui:setDirty(widget,mode,region)
    refreshes[#refreshes+1]={widget=widget,mode=mode,region=region}
end
function ui:isWidgetShown(widget)
    for _,window in ipairs(self._window_stack) do if window.widget==widget then return true end end
    return false
end
function ui:show(widget,mode)
    assert(mode==nil,"small download window must not request an unbounded refresh")
    self._window_stack[#self._window_stack+1]={widget=widget}
end
function ui:close(widget,mode,region)
    assert(mode=="ui" and region and region.w<screen:getWidth() and region.h<screen:getHeight())
    widget:onCloseWidget()
    table.remove(self._window_stack)
end
local function tick()
    assert(table.remove(tasks,1))()
end
package.loaded["ui/uimanager"]=ui
package.loaded["ui/geometry"]=geom
package.loaded.device={screen=screen}
package.loaded.logger={warn=function(_,_,err) error(err) end}
local Transition=require("miuread.dialog_transition")

local home_class={}
local file=assert(io.open("miuread.koplugin/miuread/home_view.lua","rb"))
local text=file:read("*a")
file:close()
local left=assert(text:find("local function foreground_over_home(",1,true))
local right=assert(text:find("function HomeWidget:_mark_dirty(",left+1,true))
setfenv(assert(loadstring(text:sub(left,right-1))),setmetatable({HomeWidget=home_class,UIManager=ui}, {__index=_G}))()
local home=setmetatable({},{__index=home_class})
local modal={modal=true,frame={dimen=geom:new{x=20,y=10,w=200,h=160}}}
ui._window_stack={{widget=home},{widget=modal}}
assert(not home:_paint_region(geom:new{x=10,y=50,w=50,h=15},"ui"))
assert(not home:_paint_region(geom:new{x=50,y=70,w=30,h=35},"full"))
assert(#tasks==1 and #refreshes==0)
tick()
assert(#tasks==1 and #refreshes==0)
ui._window_stack={{widget=home}}
tick()
assert(#tasks==0 and #refreshes==1)
assert(refreshes[1].mode=="ui" and refreshes[1].region.w==70 and refreshes[1].region.h==55)

refreshes={}
Transition.after_close(geom:new{x=0,y=20,w=50,h=50},function()
    ui._window_stack[#ui._window_stack+1]={widget=modal}
end,"test")
tick()
assert(refreshes[1].widget=="all" and refreshes[1].region.x==0 and refreshes[1].region.w==56-3)
tick()
tick()
-- Native movable/frame geometry becomes accurate during the repaint itself.
modal.frame.dimen=geom:new{x=80,y=125,w=180,h=200}
local mode,region=refreshes[2].mode()
assert(mode=="ui" and region.x==0 and region.y==17 and region.w==263 and region.h==311)

local widget={}
function widget:extend(fields) return setmetatable(fields or {},{__index=self}) end
function widget:new(fields)
    local obj=self:extend(fields)
    if obj.init then obj:init() end
    return obj
end
for _,name in ipairs({"ui/widget/buttontable","ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer","ui/widget/container/inputcontainer","ui/widget/overlapgroup",
    "ui/widget/linewidget","ui/widget/progresswidget","ui/widget/textboxwidget","ui/widget/verticalgroup",
    "ui/widget/verticalspan"}) do package.loaded[name]=widget end
package.loaded["ui/font"]={getFace=function() return {} end}
package.loaded["ui/size"]={padding={large=4,small=2},margin={tiny=1},border={window=2},radius={window=3}}
package.loaded["ffi/blitbuffer"]={COLOR_WHITE=1,COLOR_BLACK=0}
package.loaded["miuread.gesture_bridge"]={}
package.loaded["libs/libkoreader-lfs"]={}
local DownloadProgress=require("miuread.download_progress")
local progress=DownloadProgress:new{}
local opaque=DownloadProgress:new{comment_opaque=true}
assert(progress.covers_fullscreen==false and opaque.covers_fullscreen==true)
progress.frame.dimen=geom:new{x=160,y=130,w=400,h=320}
progress:show()
refreshes={}
progress:close("test")
assert(#refreshes==0)
tick()
assert(refreshes[1].widget=="all" and refreshes[1].region.w==406 and not ui:isWidgetShown(progress))
print("Native modal overlap, post-paint frame union, and bounded download window repaint passed")
