package.path="./miuread.koplugin/?.lua;"..package.path
local shown,tasks,repaints=nil,{},0
local ui={_window_stack={}}
function ui:nextTick(fn) tasks[#tasks+1]=fn end
function ui:show(dialog)
    shown=dialog
    self._window_stack={{widget=dialog}}
end
function ui:isWidgetShown(dialog) return shown==dialog end
function ui:setDirty(which,mode,rect)
    if type(mode)=="function" then mode,rect=mode() end
    assert(which=="all" and mode=="ui" and rect.w>0 and rect.h>0)
    repaints=repaints+1
end
local function drain()
    while #tasks>0 do table.remove(tasks,1)() end
end
package.loaded["ui/uimanager"]=ui
package.loaded["ui/geometry"]={new=function(_,rect) return rect end}
package.loaded.logger={warn=function(_,_,err) error(err) end}
package.loaded["ui/widget/textviewer"]={new=function(_,options)
    options.frame={dimen={x=20,y=20,w=options.width,h=options.height}}
    function options:onClose()
        assert(shown==self)
        shown=nil
        ui._window_stack={}
    end
    return options
end}

local plugin={}
local width,height=758,1024
local device={screen={getWidth=function() return width end,getHeight=function() return height end}}
package.loaded.device=device
local env=setmetatable({Plugin=plugin,UIManager=ui,Device=device},{__index=_G})
local file=assert(io.open("miuread.koplugin/main.lua","rb"))
local source=file:read("*a")
file:close()
local start=assert(source:find("function Plugin:_show_book_delete_dialog(",1,true))
local finish=assert(source:find("function Plugin:_execute_book_delete_plan(",start+1,true))
setfenv(assert(loadstring(source:sub(start,finish-1))),env)()

local deleted=0
local text=(("较长的书名和删除详情，包含本机版本、章节及不同的数据处理说明。"):rep(6).."\n"):rep(20)
local function confirm()
    return plugin:_show_book_delete_confirmation(text,function() deleted=deleted+1 end)
end
local dialog=confirm()
assert(dialog.text==text and dialog.height<height and dialog.width<width)
assert(dialog.add_default_buttons==false and dialog.buttons_table[1][1].text=="取消")
assert(dialog.buttons_table[1][2].text=="删除")
drain()
assert(repaints==1)
dialog.buttons_table[1][1].callback()
drain()
assert(shown==nil and deleted==0)

width,height=1024,758
dialog=confirm()
assert(dialog.height<height and dialog.width<width)
dialog.buttons_table[1][2].callback()
dialog.buttons_table[1][2].callback()
assert(shown==nil and deleted==0)
drain()
assert(deleted==1)

function plugin:_book_delete_pending_summary() return {total=2,progress=1,annotations=1} end
assert(plugin:_book_delete_preflight("test-book",confirm))
local preflight=shown
assert(preflight.text:find("阅读进度",1,true) and preflight.text:find("未上传的批注",1,true))
preflight.buttons_table[2][1].callback()
assert(shown==nil)
drain()
assert(shown and shown.title=="删除本机内容" and deleted==1)
shown.buttons_table[1][1].callback()
drain()
assert(deleted==1)
print("Deletion dialogs keep all content, both actions, and safe modal transitions")
