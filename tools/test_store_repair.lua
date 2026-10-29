local TOOL_DIR=tostring(arg and arg[0] or ''):match('^(.*)/[^/]+$') or '.'
local SRC_ROOT=TOOL_DIR..'/..'
local ROOT=SRC_ROOT..'/miuread.koplugin/'
local TMP=(os.getenv('TMPDIR') or '/tmp')..'/miuread-beta13-store-repair'
package.path=ROOT..'?.lua;'..package.path
os.execute('rm -rf '..string.format('%q',TMP)); os.execute('mkdir -p '..string.format('%q',TMP))

local function copy(v,seen)
    if type(v)~='table' then return v end
    seen=seen or {}; if seen[v] then return seen[v] end
    local out={}; seen[v]=out
    for k,x in pairs(v) do out[copy(k,seen)]=copy(x,seen) end
    return out
end
local function merge(a,b)
    local out=copy(a or {})
    for k,v in pairs(b or {}) do
        if type(v)=='table' and type(out[k])=='table' then out[k]=merge(out[k],v) else out[k]=copy(v) end
    end
    return out
end
local function quote(s) return string.format('%q',s) end
local function dump_table(v,seen)
    local t=type(v)
    if t=='nil' then return 'nil' elseif t=='boolean' or t=='number' then return tostring(v)
    elseif t=='string' then return quote(v) elseif t~='table' then return 'nil' end
    seen=seen or {}; if seen[v] then error('cycle') end; seen[v]=true
    local parts={'{'}
    for k,x in pairs(v) do parts[#parts+1]='['..dump_table(k,seen)..']='..dump_table(x,seen)..',' end
    parts[#parts+1]='}'; seen[v]=nil; return table.concat(parts)
end

package.preload['datastorage']=function()
    return {getFullDataDir=function() return TMP end,getSettingsDir=function() return TMP end,getDataDir=function() return TMP end}
end
package.preload['libs/libkoreader-lfs']=function()
    return {attributes=function(path,what)
        local f=io.open(path,'rb'); if f then local n=f:seek('end'); f:close(); if what=='mode' then return 'file' end; return {mode='file',size=n,modification=os.time()} end
        local ok=os.execute('[ -d '..string.format('%q',path)..' ]')
        if ok==true or ok==0 then if what=='mode' then return 'directory' end; return {mode='directory',size=0,modification=os.time()} end
    end}
end
local SEED={}
package.preload['luasettings']=function()
    local L={}
    function L:open(path)
        local o={data=copy(SEED)}
        function o:readSetting(k,d) local v=self.data[k]; if v==nil then return d end; return v end
        function o:saveSetting(k,v) self.data[k]=v end
        function o:delSetting(k) self.data[k]=nil end
        return o
    end
    return L
end
package.preload['dump']=function() return function(v) return dump_table(v) end end
package.preload['miuread.config']=function()
    return {SCHEMA=135,MIN_SUPPORTED_SCHEMA=130,DATA_DIR='miuread-test',VERSION='5.8.0-beta.21',
        UPDATE_MANIFEST='',AUTO_UPDATE_INTERVAL=1,READ_INTERVAL=60,IDLE_TIMEOUT=60,REMOTE_THRESHOLD=3}
end
package.preload['miuread.json']=function() return {encode=function() return '{}' end,decode=function() return {} end} end

package.preload['miuread.book_integrity']=function()
    return {core_map_hash=function(book_id,map)
        local parts={tostring(book_id or '')}
        for _,row in ipairs(type(map)=='table' and map or {}) do
            parts[#parts+1]=table.concat({tostring(row.uid or row.chapterUid or row.chapter_uid or ''),tostring(row.index or row.chapterIdx or row.chapter_idx or ''),tostring(row.word_count or row.wordCount or 0)},':')
        end
        return table.concat(parts,'|')
    end}
end
package.preload['miuread.download_database']=function()
    return {runtime_path=function(d) return d..'/download-runtime.json' end,get_download_state=function() return nil end,
        clear_download_state=function() return true end,set_download_state=function() return true end,get_download_queue=function() return {} end,set_download_queue=function() return true end}
end
package.preload['miuread.cookies']=function() return {} end
package.preload['logger']=function() return {info=function() end,warn=function() end,err=function() end} end
package.preload['miuread.util']=function()
    return {
        copy=copy,merge=merge,trim=function(v) return tostring(v or ''):match('^%s*(.-)%s*$') end,
        mkdir=function(p) os.execute('mkdir -p '..string.format('%q',p)); return true end,
        remove_tree=function(p) os.execute('rm -rf '..string.format('%q',p)); return true end,
        atomic_write=function(path,data) local f=assert(io.open(path,'wb')); f:write(data); f:close(); return true end,
        copy_file=function(a,b) local f=io.open(a,'rb'); if not f then return false end; local d=f:read('*a'); f:close(); local o=assert(io.open(b,'wb')); o:write(d); o:close(); return true end,
        file_exists=function(path) local f=io.open(path,'rb'); if f then f:close(); return true end; return false end,
        file_size=function(path) local f=io.open(path,'rb'); if not f then return nil end; local n=f:seek('end'); f:close(); return n end,
        id_name=function(v) return tostring(v or ''):gsub('[^%w%-_%.]','_') end,
        safe_name=function(v) return tostring(v or '') end,shell_quote=function(v) return quote(tostring(v or '')) end,
        clamp=function(v,a,b) v=tonumber(v) or a; if v<a then return a elseif v>b then return b end; return v end,
    }
end

-- Simulate the #91 pattern: the same 320-chapter catalog is duplicated in the
-- durable library and in multiple session/report contexts, alongside a deeply
-- nested diagnostic object that should never be persisted as report context.
local chapters={}
for i=1,320 do chapters[i]={uid='u'..i,index=i,title='chapter '..i,word_count=2000+i} end
local deep={leaf=true}; for i=1,260 do deep={next=deep} end
SEED={
    schema=130,
    preferences={shelf_filter={enabled=true,archives={},archive_keys={}}},
    shelf_cache={
        raw_books={{bookId='w1',title='one'},{bookId='w2',title='two'}},raw_mp={},books={},mp={},
        groups={authoritative=true,list={},book_groups={}},
        effective_scope={mode='selected',fingerprint='selected||',updated_at=1},updated_at=1,
    },
    library={
        book1={book_id='book1',catalog=copy(chapters),catalog_complete=true,variants={}},
        book2={book_id='book2',catalog={{uid='a',index=1,word_count=1000},{uid='b',index=2,word_count=2000}},catalog_complete=false,
            core_catalog_hash='book2|a:1:1000|b:2:2000',variants={clean={partial_range=true,sync_enabled=true,progress_sync_enabled=true,read_report_enabled=false,chapter_map={{uid='b',index=2,word_count=2000}}}}},
    },
    sessions={
        book1={
            chapters=copy(chapters),psvts='p',token='t',pending_progress={chapter_uid='u8',canonical_offset=33,progress=5,safe=true},
            legacy_report_context={book_id='book1',catalog_complete=true,chapters=copy(chapters),psvts='p',token='t',junk=deep},
            report_context={book_id='book1',catalog_complete=true,chapters=copy(chapters),reader_url='https://example',junk=deep},
            remote={progress=5,chapter_uid='u8',sources={web={progress=5,sources={web={progress=5}}},agent={progress=4}}},
            remote_sources={web={progress=5,sources={web={progress=5}}},agent={progress=4,sources={agent={progress=4}}}},
        },
        book2={progress_upload_state='unconfirmed',progress_upload_at=os.time()-5,pending_progress={chapter_uid='b',canonical_offset=100,progress=75,safe=true},pending_report_seconds=50},
    },
}

local Store=require('miuread.store')
local st=Store:new{isolated=true,data_dir=TMP..'/data',settings_path=TMP..'/settings.lua'}
local prefs=st:preferences()
assert(type(prefs.thoughts)=='table' and prefs.thoughts.online_likes==false,'beta21 online likes default is not safely disabled')
local row=assert(st:session('book1'))
assert(row.chapters==nil,'top-level duplicate chapter catalog survived migration')
assert(type(row.legacy_report_context)=='table' and row.legacy_report_context.chapters==nil,'legacy context chapters survived migration')
assert(row.legacy_report_context.junk==nil,'deep legacy diagnostic survived compaction')
assert(type(row.report_context)=='table' and row.report_context.junk==nil,'deep report diagnostic survived compaction')
assert(row.psvts=='p' and row.token=='t','required scalar session context was lost')
assert(type(row.pending_progress)=='table' and row.pending_progress.chapter_uid=='u8','pending exact progress was lost')
assert(type(row.remote)=='table' and row.remote.sources==nil and row.remote.progress==5,'schema134 did not strip historical remote.sources safely')
assert(type(row.remote_sources)=='table' and row.remote_sources.web.sources==nil and row.remote_sources.agent.sources==nil,'schema134 did not strip historical remote_sources child fan-out')
assert(#st:get('library',{}).book1.catalog==320,'canonical library catalog was damaged')

-- Future writes cannot grow the duplicate catalog back.
st:save_session('book1',{chapters=copy(chapters),legacy_report_context={book_id='book1',catalog_complete=true,chapters=copy(chapters),psvts='new',junk=deep}})
row=assert(st:session('book1'))
assert(row.chapters==nil and row.legacy_report_context.chapters==nil,'save_session reintroduced duplicate chapter catalogs')
assert(row.legacy_report_context.psvts=='new','sanitizer removed a required context field')
st:save_session('book1',{remote={progress=8,sources={web={progress=8}}},remote_sources={web={progress=8,sources={web={progress=8}}},agent={progress=7,sources={agent={progress=7}}}}},false)
row=assert(st:session('book1'))
assert(row.remote.sources==nil and row.remote.progress==8,'future save_session reintroduced remote.sources')
assert(row.remote_sources.web.sources==nil and row.remote_sources.agent.sources==nil,'future save_session reintroduced remote_sources fan-out')
local b2=assert(st:get('library',{}).book2)
assert(b2.catalog_complete==true and b2.catalog_chapter_count==2,'schema132 did not promote hash-verified partial catalog')
assert(b2.variants.clean.read_report_enabled==true,'schema132 did not re-enable safe time-only report for partial EPUB')
local s2=assert(st:session('book2'))
assert(s2.progress_upload_state=='submitted','legacy unconfirmed progress was not normalized to submitted')
assert((tonumber(s2.pending_report_seconds) or 0)==0 and s2.pending_report_safe==false,'legacy uncertain reading-time debt was replayable after migration')
local prefs=st:preferences()
assert(prefs.shelf_filter.enabled==false,'schema135 did not disable empty selected-group state')
assert(tostring(prefs.shelf_filter.recovery_notice_pending or '')=='empty_selection','schema135 recovery notice was not recorded')
local shelf=st:shelf_cache()
assert(#shelf.raw_books==2 and #shelf.books==2,'schema135 did not restore raw shelf books offline')
assert(type(prefs.shelf_group_hint)=='table' and type(prefs.shelf_group_hint.accounts)=='table','schema135 did not initialize account-scoped group hint state')

-- 5.9 beta.4: a selected remote may carry a diagnostic cycle
-- remote.sources.web -> remote. Persistence must strip that graph before U.merge.
local cyclic_remote={progress=100,percent=100,chapter_uid='40',offset=747,updated_at=123}
cyclic_remote.sources={web=cyclic_remote,agent={progress=99,chapter_uid='39',offset=500}}
st:save_session('book1',{position_state={version=1,remote_position=cyclic_remote,resolved={source='remote',reason='test',resolved_at=123}}},false)
row=assert(st:session('book1'))
assert(type(row.position_state)=='table' and type(row.position_state.remote_position)=='table','position state was lost during compaction')
assert(row.position_state.remote_position.sources==nil,'cyclic position_state.remote_position.sources survived save_session')
assert(row.position_state.remote_position.chapter_uid=='40' and row.position_state.remote_position.offset==747,'position state scalar coordinate was damaged')

-- beta.19 abandon must never reset reading time or saved Kindle position.
st:save_session('book2',{
    progress_epoch=3,progress_latest_sequence=12,progress_verified_sequence=9,
    pending_progress={progress_sequence=12,progress_epoch=3,chapter_uid='b',canonical_offset=117,safe=true},
    progress_sync_state='upload_failed',progress_upload_state='pending_send',
    pending_report_seconds=149,pending_report_safe=true,
    local_display_progress=31.5,local_read_event_at=123456,
},true)
local before=assert(st:session('book2'))
assert(type(before.pending_progress)=='table','test setup lost pending progress')
assert(st:abandon_pending_progress('book2',3,12))
local abandoned=assert(st:session('book2'))
assert(abandoned.pending_progress==nil and abandoned.progress_sync_state=='abandoned',
    'abandon did not clear the progress upload task')
assert(abandoned.progress_epoch==4 and abandoned.progress_latest_sequence==12,
    'abandon did not supersede old callbacks while retaining the sequence')
assert(abandoned.pending_report_seconds==149 and abandoned.pending_report_safe==true,
    'abandon erased unconfirmed reading-time debt')
assert(abandoned.local_display_progress==31.5 and abandoned.local_read_event_at==123456,
    'abandon erased the saved Kindle reading position')
assert(not st:abandon_pending_progress('book2',3,12),'stale epoch was allowed to reapply')
assert(not st:abandon_pending_progress('book2',4,12),'abandon operation should be idempotent')
-- A detached upload worker with an earlier epoch/sequence must not recreate
-- the old progress task after the user explicitly abandoned it.
st:save_session('book2',{progress_epoch=3,progress_latest_sequence=12,
    pending_progress={progress_sequence=12,progress_epoch=3,chapter_uid='b',canonical_offset=117},
    progress_sync_state='upload_failed',progress_upload_state='pending_send'},true)
assert(st:session('book2').pending_progress==nil and st:session('book2').progress_epoch==4,
    'late old worker resurrected a user-abandoned pending progress upload')
local durable=assert(loadfile(TMP..'/settings.lua'))()
assert(durable.sessions.book2.progress_epoch==4 and durable.sessions.book2.pending_progress==nil
    and durable.sessions.book2.pending_report_seconds==149,
    'abandoned task reappeared on disk')
-- Later reading must be able to create a new pending task in the new epoch.
st:save_session('book2',{pending_progress={progress_sequence=13,progress_epoch=4,chapter_uid='b',canonical_offset=118},
    progress_sync_state='deferred',progress_upload_state='pending_send'},true)
assert(type(st:session('book2').pending_progress)=='table',
    'abandon prevented future reading from generating a new sync task')
print('beta19 targeted progress abandonment with time-debt preservation: PASS')

local loader,err=loadfile(TMP..'/settings.lua'); assert(loader,err)
local ok,data=pcall(loader); assert(ok and type(data)=='table','compacted settings file is not valid Lua')

-- Promoting the statistics outbox must preserve either master-switch choice,
-- safe legacy carry and an existing test-version ledger without rewriting it.
local ledger=TMP..'/data/readtime-outbox.sqlite3'
local marker=assert(io.open(ledger,'wb'));marker:write('existing-ledger-fixture');marker:close()
SEED.schema=135 -- already at this fixture's current schema; no ancient reset
for _,enabled in ipairs({false,true}) do
    SEED.preferences.sync={time_enabled=enabled,offline_time_enabled=true}
    SEED.sessions.book2={pending_report_safe=true,pending_report_seconds=90}
    local upgraded=Store:new{isolated=true,data_dir=TMP..'/data',settings_path=TMP..'/upgrade.lua'}
    assert(upgraded:preferences().sync.time_enabled==enabled,'outbox promotion changed the master switch')
    assert(upgraded:preferences().sync.offline_time_enabled==nil,'obsolete experimental switch survived')
    assert(upgraded:get('readtime_outbox_v2',false)==true,'outbox migration marker missing')
    assert(upgraded:session('book2').pending_report_seconds==90 and upgraded:session('book2').pending_report_safe,
        'outbox promotion dropped safe legacy carry')
    local f=assert(io.open(ledger,'rb'));assert(f:read('*a')=='existing-ledger-fixture');f:close()
end
print('store compaction + schema134/135 shelf recovery migration: PASS')
