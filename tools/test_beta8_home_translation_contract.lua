local script=arg and arg[0] or ""
local root=script:match("^(.*)/tools/[^/]+$") or "."
local function read(path)
    local f=assert(io.open(root.."/"..path,"rb")); local s=f:read("*a"); f:close(); return s
end
local main=read("miuread.koplugin/main.lua")
local api=read("miuread.koplugin/miuread/api_web.lua")
local gen=read("miuread.koplugin/miuread/translation_generation.lua")
local translation=read("miuread.koplugin/miuread/translation.lua")

local function slice(source,a,b)
    local i=assert(source:find(a,1,true),"missing "..a)
    local j=b and source:find(b,i+1,true) or nil
    return source:sub(i,(j and j-1) or #source)
end

local actions=slice(main,"function Plugin:_home_action_entries()","function Plugin:_home_alerts()")
assert(actions:find('refresh={icon="↻",icon_key="refresh",label="刷新",callback=function() self:_home_complete_refresh(true) end}',1,true),
    "Home Refresh is not wired to complete refresh")
assert(actions:find('if key~="refresh" then entry.hold_callback=hold_for(key,entry.label) end',1,true),
    "Refresh still owns a hold menu")
local function_actions=slice(main,"function Plugin:_home_action_function_actions","function Plugin:_home_move_enabled_action")
assert(not function_actions:find('if key=="refresh"',1,true),"legacy refresh hold actions remain")

local complete=slice(main,"function Plugin:_home_complete_refresh","function Plugin:_set_home_layout")
for _,needle in ipairs({
    'UnifiedLibrary.invalidate_external_cache()',
    'self.store:reload()',
    'self.store:prune_missing_files()',
    'self._home_recent_read_dirty=true',
    'self:_home_refresh_remote(true,false)',
    'self:_home_scan_local(true)',
    'self:_home_relink_generated_files(true)',
    'UIManager:setDirty("all","full")',
}) do assert(complete:find(needle,1,true),"complete refresh missing: "..needle) end

local candidate=slice(main,"function Plugin:_reader_translation_candidate","function Plugin:_reader_translation_profile")
assert(candidate:find('self:_reader_session_is_weread()',1,true),"translation entry lost WeRead session guard")
assert(candidate:find('self:_reader_is_reflowable()',1,true),"translation entry lost reflowable guard")
assert(candidate:find('book_id~=""',1,true),"translation entry does not require a valid book id")
assert(not candidate:find('match("^CB_")',1,true),"translation entry still rejects numeric book ids")

local webcall=slice(api,"function Api:_translation_web_call","function Api:translation_member_summary")
assert(webcall:find('if id=="" or id:match("^%s*$") then error("translation book id missing") end',1,true),"translation API missing empty-id guard")
assert(not webcall:find('translation requires an imported book',1,true),"translation API still hard-rejects non-CB books")
assert(not webcall:find('match("^CB_")',1,true),"translation API still infers support from CB_ prefix")

assert(gen:find('当前书籍暂不支持微信读书官方翻译',1,true),"unsupported official translation has no safe user-facing result")
assert(not translation:find('match("^CB_")',1,true),"local translation inspection still rejects numeric book ids")
print("beta8 home/translation contract: PASS")
