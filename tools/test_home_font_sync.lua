package.path="./miuread.koplugin/?.lua;"..package.path
local file=assert(io.open("miuread.koplugin/main.lua","rb"))
local source=file:read("*a")
file:close()
local plugin={}
local U={trim=function(value) return (value:gsub("^%s+",""):gsub("%s+$","")) end}
local env=setmetatable({Plugin=plugin,U=U},{__index=_G})
local function load(first,last)
    local start=assert(source:find("function Plugin:"..first.."(",1,true))
    local finish=assert(source:find("function Plugin:"..last.."(",start,true))
    setfenv(assert(loadstring(source:sub(start,finish-1))),env)()
end
load("_active_reader_body_font_name","_set_home_ui_font")
local stored,writes=nil,0
plugin.store={
    get=function(_,key) assert(key=="last_reader_body_font"); return stored end,
    set=function(_,key,value) assert(key=="last_reader_body_font"); stored=value; writes=writes+1 end,
}
local home={ui_font_mode="follow"}
_G.G_reader_settings={readSetting=function() return "KOReader default" end}
assert(plugin:_home_ui_font_name(home)=="KOReader default")
plugin.ui={document={getFontFace=function() return "Document typography" end},font={font_face="Widget typography"}}
assert(plugin:_home_ui_font_name(home)=="Document typography")
plugin:_remember_home_body_font()
plugin:_remember_home_body_font()
assert(stored=="Document typography" and writes==1)
plugin.ui={document={}}
plugin:_remember_home_body_font()
assert(plugin:_home_ui_font_name(home)=="Document typography" and writes==1)
assert(plugin:_home_ui_font_name({ui_font_mode="custom",ui_font_face="Home typography"})=="Home typography")
assert(not plugin:_home_ui_font_name({ui_font_mode="default"}))

package.loaded["miuread.util"]=U
local scanned,registered,cleared=0,0,0
local fontlist={fontlist={"old"}}
function fontlist:getFontList()
    if self.fontlist[1] then return self.fontlist end
    scanned=scanned+1
    self.fontlist={"font/weread/weread.otf"}
end
package.loaded["fontlist"]=fontlist
local engine={registerFont=function(path)
    assert(path=="font/weread/weread.otf")
    registered=registered+1
end}
package.loaded["document/credocument"]={engineInit=function()
    package.loaded["libs/libkoreader-cre"]=engine
    return engine
end}
package.loaded["miuread.thought_face_factory"]={clearCache=function() cleared=cleared+1 end}
local Fonts=require("miuread.weread_font_download")
Fonts.refresh_registry("font/weread/weread.otf")
assert(scanned==1 and registered==0 and cleared==1)
Fonts.refresh_registry("font/weread/weread.otf")
assert(scanned==2 and registered==1 and cleared==2)
load("home_ui_font_menu","home_customization_menu")
load("_apply_weread_font","_show_reader_spacing_panel")
package.loaded["miuread.extension_center"]={}
package.loaded["miuread.menu_icons"]={key=function() return "font" end}
local Settings=require("miuread.plugin_settings")
local surface,shown,available
function plugin:_home_enabled() return true end
function plugin:_home_preferences() return home end
function plugin:_home_lockscreen_style_label() return "Default" end
function plugin:_reader_toolbar_setting_summary() return "Enabled" end
function plugin:_time_settings_label() return "Device" end
function plugin:_show_miuread_menu(_,items,options)
    surface,shown=options.on_home and "reader" or "home",items
end
function plugin:_show_reader_menu_table(_,items) surface,shown="reader",items end
function plugin:toast() end
local function item(rows,label)
    for _,row in ipairs(rows) do
        if row.text==label then return row end
    end
    error("missing item: "..label)
end
fontlist.fontdir="font"
local embedded=Fonts.directory().."/"..Fonts.catalog[2].file
U.file_exists=function(path) return available and path==embedded end
Fonts.install=function(http,index)
    assert(http==nil and index==2)
    available=true
    return embedded
end
Fonts.refresh_registry=function(path) assert(path==embedded) end
fontlist.fontinfo={[embedded]={{name="Source Han Serif CN"}}}
function plugin:_set_home_ui_font(mode,face)
    home.ui_font_mode,home.ui_font_face=mode,face
    return true
end
function plugin:_reader_font_label() return self.ui.font.font_face end
local interface=item(Settings.menu(plugin),"首页与界面").sub_item_table_func()
local displays=item(interface,"字体与显示").sub_item_table_func()
local font_rows=item(displays,"觅阅界面字体").sub_item_table_func()
item(font_rows,"微信读书字体").callback()
assert(surface=="home" and #shown==#Fonts.catalog)
assert(item(shown,"思源宋体").post_text_func()=="安装")
assert(item(shown,"系统字体").preview_image==nil)
for _,row in ipairs(shown) do
    if row.text~="系统字体" then
        local preview=assert(io.open(row.preview_image,"rb"))
        assert(preview:read(8)=="\137PNG\r\n\26\n")
        preview:close()
    end
end
item(shown,"思源宋体").callback()
assert(item(shown,"思源宋体").post_text_func()=="应用")
item(shown,"思源宋体").callback()
assert(home.ui_font_face=="Source Han Serif CN" and item(shown,"思源宋体").post_text_func()=="使用中")
item(shown,"系统字体").callback()
assert(home.ui_font_mode=="default" and item(shown,"思源宋体").post_text_func()=="应用")
local wenkai=item(shown,"霞鹜文楷")
assert(wenkai.post_text_func()=="下载")
plugin._interactive_network_key="weread-font:8"
assert(wenkai.post_text_func()=="下载中")
assert(item(shown,"仓耳今楷 04").post_text_func()=="下载")
plugin._interactive_network_key=nil
plugin.ui={font={face_table={{text="Native face"}},onSetFont=function(self,face) self.font_face=face end}}
plugin:_show_reader_font_face_menu(function() end)
assert(surface=="reader" and item(shown,"Native face"))
item(shown,"微信读书字体").callback()
assert(surface=="reader" and item(shown,"思源宋体").post_text_func()=="应用")
item(shown,"思源宋体").callback()
assert(home.ui_font_mode=="default" and plugin.ui.font.font_face=="Source Han Serif CN")
assert(item(shown,"思源宋体").post_text_func()=="使用中")
print("Home follows the last book font; settings and reader open the same catalog and share installed fonts")
