-- Run from the repository root: lua5.1 tools/test_store_shared.lua
-- Exercise the real Store against temporary Lua settings, without KOReader UI.
local TOOL_DIR=tostring(arg and arg[0] or ''):match('^(.*)/[^/]+$') or '.'
local ROOT=TOOL_DIR..'/../miuread.koplugin/'
package.path=ROOT..'?.lua;'..package.path
local unique=os.tmpname()
os.remove(unique)
local TMP=(os.getenv('TMPDIR') or '/tmp')..'/miuread-store-'..unique:match('([^/]+)$')
local function quote(value) return "'"..tostring(value):gsub("'", "'\\''").."'" end
local function mkdir(path) os.execute('mkdir -p '..quote(path)); return true end
mkdir(TMP)

local function copy(value)
    if type(value)~='table' then return value end
    local out={}; for k,v in pairs(value) do out[k]=copy(v) end; return out
end
local function merge(a,b)
    local out=copy(a or {})
    for k,v in pairs(b or {}) do
        if type(v)=='table' and type(out[k])=='table' then out[k]=merge(out[k],v)
        else out[k]=copy(v) end
    end
    return out
end
local function dump(value)
    if type(value)=='string' then return string.format('%q',value) end
    if type(value)~='table' then return tostring(value) end
    local out={'{'}
    for k,v in pairs(value) do out[#out+1]='['..dump(k)..']='..dump(v)..',' end
    out[#out+1]='}'; return table.concat(out)
end
local function read(path)
    local f=io.open(path,'rb'); if not f then return nil end
    local data=f:read('*a'); f:close(); return data
end
local fail_write=false
local write_count=0
local function write(path,data)
    if fail_write then return false,'simulated write failure' end
    write_count=write_count+1
    local f=assert(io.open(path,'wb')); f:write(data); f:close(); return true
end
local function attributes(path,what)
    local ok=os.execute('[ -d '..quote(path)..' ]')
    local attr
    if ok==true or ok==0 then attr={mode='directory',modification=1}
    else local data=read(path); if data then attr={mode='file',size=#data,modification=1} end end
    return attr and (what and attr[what] or attr)
end
package.preload['datastorage']=function()
    return {getFullDataDir=function() return TMP end,getSettingsDir=function() return TMP end,getDataDir=function() return TMP end}
end
package.preload['libs/libkoreader-lfs']=function() return {attributes=attributes} end
package.preload['luasettings']=function()
    local Settings={}
    function Settings:open(path)
        local chunk=loadfile(path)
        local obj={data=chunk and chunk() or {}}
        function obj:readSetting(k,d) local v=self.data[k]; if v==nil then return d end; return v end
        function obj:saveSetting(k,v) self.data[k]=v end
        function obj:delSetting(k) self.data[k]=nil end
        return obj
    end
    return Settings
end
package.preload['dump']=function() return dump end
package.preload['miuread.json']=function() return {} end
package.preload['miuread.download_database']=function()
    return {runtime_path=function(path) return path..'/runtime' end}
end
package.preload['miuread.cookies']=function() return {} end
package.preload['logger']=function() return {info=function() end,warn=function() end,err=function() end} end
package.preload['miuread.util']=function()
    return {copy=copy,merge=merge,mkdir=mkdir,atomic_write=write,
        copy_file=function(a,b) local data=read(a); return data and write(b,data) or false end,
        file_size=function(path) local data=read(path); return data and #data end,
        trim=function(v) return tostring(v or ''):match('^%s*(.-)%s*$') end,
    }
end

local function run()
    local Config=require('miuread.config')
    local path=TMP..'/miuread.lua'
    assert(write(path,'return '..dump({schema=Config.SCHEMA,preferences={home_ui={
        local_entry_root='',local_entry_user_set=false,local_entry_version=2,
    }}})))
    local Store=require('miuread.store')
    local options={settings_path=path,data_dir=TMP..'/data'}
    -- Reader and the concealed FileManager each initialize the plugin before
    -- the user confirms a local-library root in one of their menus. Reusing a
    -- live Store must still repair runtime directories if one disappeared.
    local reader=Store:new(options)
    os.execute('rm -rf '..quote(options.data_dir..'/prefetch'))
    local home=Store:new(options)
    assert(reader==home,'Reader and Home did not reuse the live Store')
    assert(attributes(options.data_dir..'/prefetch','mode')=='directory',
        'shared Store reuse skipped runtime directory repair')
    local prefs=reader:preferences()
    prefs.home_ui.local_entry_root='/mnt/us/documents'
    prefs.home_ui.local_entry_user_set=true
    assert(reader:save_preferences(prefs))
    assert(loadfile(path)().preferences.home_ui.local_entry_root=='/mnt/us/documents')
    -- A scan result / deferred Home write must not serialize an older root.
    assert(home:set('home_local_directory_cache_v5',{version=5,dirs={
        ['/mnt/us/documents']={books={{file='/mnt/us/documents/example.mobi'}}},
    }}))
    assert(loadfile(path)().preferences.home_ui.local_entry_root=='/mnt/us/documents',
        'a stale Home Store erased the selected local-library root')
    assert(home:preferences().home_ui.local_entry_user_set==true,
        'Home cannot see the confirmed directory without restarting')
    assert(reader:get('home_local_directory_cache_v5').dirs['/mnt/us/documents'],
        'Reader cannot see the completed Home scan')

    prefs=home:preferences(); prefs.home_ui.local_entry_root='/mnt/us/Books'
    home:save_preferences_deferred(prefs)
    local reopened=Store:new(options)
    assert(reopened:preferences().home_ui.local_entry_root=='/mnt/us/Books',
        'creating another plugin instance discarded an unflushed preference')
    assert(reopened:flush())
    local persisted=loadfile(path)()
    persisted.preferences.home_ui.local_entry_root='/mnt/us/Other'
    assert(write(path,'return '..dump(persisted)))
    reader:reload()
    assert(home:preferences().home_ui.local_entry_root=='/mnt/us/Other',
        'reload left another plugin instance on stale settings')

    -- Navigation can remain pending while downloads/MP callbacks reload disk.
    prefs=home:preferences()
    prefs.home_ui.active_section='recent'
    prefs.home_ui.page_by_section={recent=3}
    home:save_preferences_deferred(prefs,true)
    local downloaded=loadfile(path)()
    downloaded.library['external-download']={title='New download'}
    downloaded.preferences.home_ui.display_size='large'
    assert(write(path,'return '..dump(downloaded)))
    local reload_writes=write_count
    reader:reload()
    assert(write_count==reload_writes+1,'reload added a foreground settings save')
    assert(home:preferences().home_ui.active_section=='recent',
        'background reload discarded pending navigation')
    assert(home:preferences().home_ui.page_by_section.recent==3)
    assert(home:preferences().home_ui.display_size=='large','navigation hid a disk preference update')
    assert(home:book('external-download').title=='New download','navigation hid a download result')
    assert(home:flush())
    downloaded=loadfile(path)()
    assert(downloaded.preferences.home_ui.active_section=='recent')
    downloaded.preferences.home_ui.active_section='device'
    assert(write(path,'return '..dump(downloaded)))
    home:reload()
    assert(home:preferences().home_ui.active_section=='device','saved navigation remained pinned')
    prefs=home:preferences(); prefs.home_ui.active_section='recent'
    home:save_preferences_deferred(prefs,true)
    fail_write=true
    assert(home:flush()==false)
    fail_write=false
    assert(home:preferences().home_ui.active_section=='recent','failed save discarded navigation')
    home:reload()
    assert(home:preferences().home_ui.active_section=='recent','failed navigation could not survive reload')
    assert(home:flush())
    home:save_preferences_deferred(home:preferences(),true)
    assert(home:flush()) -- unchanged flush must also release the pending overlay
    downloaded=loadfile(path)(); downloaded.preferences.home_ui.active_section='shelf'
    assert(write(path,'return '..dump(downloaded)))
    home:reload()
    assert(home:preferences().home_ui.active_section=='shelf','unchanged save retained stale navigation')

    -- A newer verified progress state written to disk must beat an older live
    -- pending snapshot when Home later flushes an unrelated preference.
    reader:set_deferred('sessions',{['book-progress']={
        pending_progress={progress_sequence=7},
        progress_latest_sequence=7,progress_verified_sequence=0,
        progress_upload_state='submitted',progress_upload_pending_at=100,
    }})
    local external=loadfile(path)()
    external.sessions={['book-progress']={
        pending_progress=false,progress_latest_sequence=7,
        progress_verified_sequence=7,progress_upload_state='verified',
        progress_upload_verified_at=200,
    }}
    assert(write(path,'return '..dump(external)))
    prefs=home:preferences()
    prefs.home_ui.more_expanded=not prefs.home_ui.more_expanded
    assert(home:save_preferences(prefs))
    local progress_saved=loadfile(path)().sessions['book-progress']
    assert(progress_saved.progress_verified_sequence==7,
        'Home preference flush rolled verified progress back to an older state')
    assert(progress_saved.progress_upload_state=='verified',
        'Home preference flush lost the verified progress terminal state')
    assert(progress_saved.pending_progress==false,
        'Home preference flush resurrected an already verified pending upload')

    local before_writes=write_count
    assert(home:flush('duplicate_close'))
    assert(write_count==before_writes,'unchanged close rewrote settings/backups')
    home.db.data.return_fraction=1/3
    assert(home:flush())
    before_writes=write_count
    assert(home:flush('same_fraction'))
    assert(write_count==before_writes,'serialized progress fraction caused another full save')
    home.db.data.return_fraction=nil
    assert(home:flush())
    -- Nested in-place changes and deletions must still be durable immediately.
    home.db.data.return_test={nested={value='new',remove=true},flag=false}
    assert(home:flush())
    assert(loadfile(path)().return_test.nested.value=='new')
    home.db.data.return_test.nested.remove=nil
    home.db.data.return_test.nested.value='changed'
    assert(home:flush())
    local changed=loadfile(path)().return_test
    assert(changed.nested.remove==nil and changed.nested.value=='changed' and changed.flag==false)
    home.db.data.return_test=nil
    assert(home:flush())
    assert(loadfile(path)().return_test==nil,'deleted table remained on disk')
    assert(write(path,'invalid settings chunk'))
    assert(home:flush(),'invalid disk must be repaired, not treated as unchanged')
    assert(loadfile(path)().preferences.home_ui.local_entry_root=='/mnt/us/Other')

    local isolated_options={settings_path=path,data_dir=options.data_dir,isolated=true}
    local isolated=Store:new(isolated_options)
    isolated:set_deferred('test_isolated',true)
    assert(home:get('test_isolated')==nil,'isolated worker modified the live Store')
    assert(Store:new(isolated_options):get('test_isolated')==nil,
        'isolated workers reused another worker in-memory state')
    local other=Store:new{settings_path=TMP..'/other.lua',data_dir=options.data_dir}
    assert(other:preferences().home_ui.local_entry_root=='','different settings paths share state')

    prefs=home:preferences(); prefs.home_ui.local_entry_root='/mnt/us/Unsaved'
    fail_write=true
    assert(home:save_preferences(prefs)==false,'simulated write unexpectedly succeeded')
    fail_write=false
    assert(reader:preferences().home_ui.local_entry_root=='/mnt/us/Other',
        'failed-write recovery did not reach all plugin instances')
    print('shared Store: local root, directory repair, scan visibility, progress freshness, deferred save, reload, isolation and recovery: PASS')
end
local ok,err=xpcall(run,debug.traceback)
os.execute('rm -rf '..quote(TMP))
if not ok then error(err) end
