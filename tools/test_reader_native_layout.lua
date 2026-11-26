local plugin,recorded={},{}
local U={copy=function(value)
    if type(value)~="table" then return value end
    return {unpack(value)}
end}
local env=setmetatable({Plugin=plugin,U=U,logger={warn=function() error("unexpected error") end}},{__index=_G})
local main=assert(io.open("miuread.koplugin/main.lua","rb"))
local source=main:read("*a")
main:close()
local function extract(text,first,last)
    local start=assert(text:find(first,1,true))
    local finish=assert(text:find(last,start+1,true))
    setfenv(assert(loadstring(text:sub(start,finish-1))),env)()
end
extract(source,"function Plugin:_reader_adjust_font_size","function Plugin:_reader_goto_percent")
extract(source,"function Plugin:_show_reader_native_layout","function Plugin:_show_reader_current_book_panel")
extract(source,"function Plugin:_inherit_chapter_layout","function Plugin:_switch_single_chapter_file")
function plugin:_reader_font_size_value() return 80 end
function plugin:_mark_reader_busy() end
function plugin:_reader_queue_typography(key,value) recorded[key]=value; return true end
function plugin:_reader_open_native_page(_,opener) return opener() end
function plugin:_show_koreader_reader_menu() error("native layout took the generic menu path") end
plugin.ui={document={configurable={font_size=80.5,line_spacing=135,rotation_mode=1}},
    font={font_face="Native fixture"},
    config={options={prefix="copt",{options={{name="font_size"},{name="line_spacing"},{name="rotation_mode"}}}},
        onShowConfigMenu=function() recorded.native_config=true; return true end}}
assert(plugin:_reader_adjust_font_size(.5) and recorded.font_size==80.5)
assert(plugin:_show_reader_native_layout() and recorded.native_config)
package.loaded.docsettings={open=function(_,path)
    assert(path=="/next.epub")
    return {saveSetting=function(_,key,value) recorded[key]=value end,
        flush=function() recorded.flushed=true end}
end}
plugin:_inherit_chapter_layout("/next.epub")
assert(recorded.flushed and recorded.copt_font_size==80.5 and recorded.copt_line_spacing==135
    and recorded.font_face=="Native fixture" and not recorded.copt_rotation_mode)
recorded.flushed=false
plugin:_inherit_chapter_layout("/next.pdf")
assert(not recorded.flushed)

local toolbar_source=assert(io.open("miuread.koplugin/miuread/reader_toolbar.lua","rb"))
local toolbar=toolbar_source:read("*a")
toolbar_source:close()
env.Toolbar={_device_row=function(_,_,actions)
    assert(actions[1].label=="fixed native controls")
    recorded.fixed=true
end}
extract(toolbar,"function Toolbar:_typeset_row","function Toolbar:_light_row")
env.Toolbar:_typeset_row({}, {fixed_actions={{label="fixed native controls"}}},0,0,600,60)
assert(recorded.fixed)
print("Native KOReader layout entry, untruncated sizes, per-chapter settings, and fixed-page controls passed")
