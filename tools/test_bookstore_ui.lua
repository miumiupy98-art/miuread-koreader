-- Exercise navigation and persisted write uncertainty with real controller code.
package.path='miuread.koplugin/?.lua;'..package.path
local function copy(value,seen)
    if type(value)~='table' then return value end
    seen=seen or {}; if seen[value] then return seen[value] end
    local out={}; seen[value]=out
    for k,v in pairs(value) do out[k]=copy(v,seen) end
    return out
end
local function merge(a,b)
    local out=copy(a or {})
    for k,v in pairs(b or {}) do
        out[k]=type(v)=='table' and type(out[k])=='table' and merge(out[k],v) or copy(v)
    end
    return out
end
package.preload['miuread.util']=function() return {
    copy=copy,merge=merge,utf8_truncate=function(s,n) return s:sub(1,n) end,
    trim=function(s) return tostring(s or ''):match('^%s*(.-)%s*$') end,
    file_exists=function() return true end,
} end
local logs={}
local function record_log(...)
    local parts={...}
    for i,v in ipairs(parts) do parts[i]=tostring(v) end
    logs[#logs+1]=table.concat(parts,' ')
end
package.preload['logger']=function() return {warn=record_log,info=record_log} end
package.preload['miuread.protocol']=function() return {escape=tostring} end
local source_file=assert(io.open('miuread.koplugin/main.lua','rb'))
local source=source_file:read('*a'); source_file:close()
local child_factory=assert(source:match('(local function interactive_child_store.-\nend)'))
local child_method=assert(source:match('function Plugin:_interactive_child_store%(auth,data_dir,temp_dir%).-\nend'))
local child_methods=assert(loadstring('local U=require("miuread.util"); local Plugin={}\n'
    ..child_factory..'\n'..child_method..'\nreturn Plugin'))()
local views={}
local dialogs={}
package.preload['ui/widget/buttondialog']=function()
    local class={}
    function class:extend(attrs)
        local subclass=setmetatable(attrs or {},{__index=self})
        return subclass
    end
    function class:new(opts) return setmetatable(opts,{__index=self}) end
    return class
end
package.preload['miuread.shelf_view']=function() return {show=function(opts)
    local view={opts=opts,page=1,_miu_closed=false}
    views[#views+1]=view
    require('ui/uimanager'):show(view)
    return view
end} end
package.preload['miuread.dialog_transition']=function() return {cancel_pending=function() end} end
package.preload['ui/uimanager']=function() return {_window_stack={},close=function(self,view)
    view._miu_closed=true
    for i=#self._window_stack,1,-1 do
        if self._window_stack[i].widget==view then table.remove(self._window_stack,i) end
    end
    if view.opts and view.opts.on_close then view.opts.on_close(view) end
    if view.close_callback then view.close_callback() end
end,show=function(self,widget)
    self._window_stack[#self._window_stack+1]={widget=widget}
    if widget.buttons then dialogs[#dialogs+1]=widget end
end,isWidgetShown=function(_,widget) return widget._miu_closed~=true end} end
local api={page_calls=0,writes=0,reads=0}
function api:category_books(id,cursor,rank)
    self.page_calls=self.page_calls+1
    self.last_category,self.last_cursor,self.last_rank=id,cursor,rank
    return {books={{bookInfo={bookId='book'..cursor,title='Title '..cursor,author='Writer',newRating=89},
        searchIdx=cursor+20}},hasMore=cursor<40 and 1 or 0}
end
function api:recommend_books(cursor,count)
    if self.refresh_auth then
        local auth=self.store:auth(); auth.api_key='renewed'
        self.store:save_auth(auth)
    end
    self.last_count=count
    return {books={{bookId='recommend',title='Recommended',searchIdx=cursor+1}},hasMore=0}
end
function api:similar_books(id,cursor,count,session)
    self.last_similar={id,cursor,count,session}
    return {booksimilar={sessionId='next-session',books={{idx=cursor+20,
        book={bookInfo={bookId='similar',title='Similar'}}}},hasMore=1}}
end
function api:store_categories()
    return {data={{categories={{CategoryId='all',title='All',type=0},
        {CategoryId='700000',title='Computing',type=0,sublist={{CategoryId='700001',title='Programming',type=0}}}}}}}
end
function api:book_on_shelf()
    self.reads=self.reads+1
    if self.fail_reads then error('read failed') end
    return self.present==true
end
function api:remove_from_shelf()
    if not self.store:auth().native_shelf then
        error('[MiuReadShelfPreflight] [MiuReadShelfAuthorization] 请先授权书架管理')
    end
    if self.block_native then
        error('[MiuReadShelfPreflight] HTTP 401: {"errcode":-2011,"accessToken":"secret-sentinel"}')
    end
    self.writes=self.writes+1
    self.last_target=false
    if self.effect~=false then self.present=false end
    if self.lose_reply then error('POST timed out') end
end
function api:add_to_shelf()
    self.last_target=true
    self.writes=self.writes+1
    if self.effect~=false then self.present=true end
    if self.lose_reply then error('POST timed out') end
end
package.preload['miuread.api']=function() return {new=function(_,http,store,reader)
    api.store,api.reader=store,reader
    return api
end} end
package.preload['miuread.http']=function() return {
    new=function() return {} end,
    auth_error_code=function(value) return tostring(value):match('error_code=(%-?%d+)') end,
    is_auth_error=function(value) return tostring(value):find('HTTP 401',1,true)~=nil end,
    is_network_error=function(value) return tostring(value):find('timed out',1,true)~=nil end,
} end
package.preload['miuread.reader']=function() return {new=function(_,http,store)
    return {http=http,store=store}
end} end
local auth_flows={}
package.preload['miuread.auth']=function() return {new=function(_,http,store,host,backend)
    local flow={host=host,backend=backend}
    function flow:start() self.started=true end
    function flow:cancel() self.cancelled=true end
    auth_flows[#auth_flows+1]=flow
    return flow
end} end
local M=require('miuread.bookstore')
local confirm_method=assert(source:match('function Plugin:_confirm_shelf_removal%(book,callback%).-\nend'))
local confirmation_methods=assert(loadstring([[
local Plugin={}
local TransientGuard=require('miuread.transient_guard')
local UIManager=require('ui/uimanager')
local ConfirmBox=require('ui/widget/buttondialog'):extend{_miuread_modal_surface=true}
]]..confirm_method..'\nreturn Plugin'))()


local home_method=assert(source:match('function Plugin:_home_hold_book%(book,anchor%).-\nend'))
local home_methods,last_home_sheet=assert(loadstring([[
local Plugin={}
local U=require('miuread.util')
local ShelfProgress=require('miuread.shelf_progress')
local Protocol={is_mp=function(id) return id:match('^MP_')~=nil end,
    is_mp_account=function(id) return id:match('^MP_WXS_')~=nil end}
local UnifiedLibrary={canonical_source=function(book) return book.unified_source or 'local' end}
local BookIntegrity={partial_repairs=function() return {} end}
local BookLocalFilesDialog={}
local LocalLibrary={normalize=tostring}
local lfs={attributes=function() return 'file' end}
local sheet
local ActionSheet={show=function(opts) sheet=opts end}
]]..home_method..'\n'..assert(source:match('(function Plugin:_finished_status_action%(book%).-\nend)'))
    ..'\n'..assert(source:match('(function Plugin:_home_action_function_actions%(key,anchor%).-\nend)'))
    ..'\nreturn Plugin,function() return sheet end'))()

local function plugin()
    local p={jobs={},info_messages={},toasts={},refreshes=0,
        auth={account={vid='alice'},cookies={wr_skey='fake'},login_session_id='one',
            native_shelf={vid='alice',accessToken='native',refreshToken='refresh',deviceId='device'}},settings={}}
    p.store={data_dir='test',temp_dir='test'}
    function p.store:auth() return copy(p.auth) end
    function p.store:get(key,default) return copy(p.settings[key] or default) end
    function p.store:set(key,value)
        p.settings[key]=copy(value)
        return p.fail_save~=true
    end
    function p.store:set_deferred(key,value) p.settings[key]=copy(value) end
    p._interactive_child_store=child_methods._interactive_child_store
    p._confirm_shelf_removal=confirmation_methods._confirm_shelf_removal
    function p.store:shelf_cache() return copy(p.settings.shelf_cache or {raw_books={}}) end
    p.library={cached_cover_path=function() return nil end}
    p.interactive_network_async={busy=function() return p.job~=nil end}
    p.cover_async={available=function() return false end}
    function p:_run_interactive_network(key,label,fn,cb,options)
        if self.fail_start then return false,'worker unavailable' end
        if self.job then self:_cancel_interactive_network('superseded') end
        local job={fn=fn,callback=cb,key=key,on_cancel=options.on_cancel}
        self.jobs[#self.jobs+1]=job; self.job=job; self._interactive_network_key=key
        return true
    end
    function p:finish(before_callback)
        local job=assert(self.job)
        self.job=nil; self._interactive_network_key=nil
        local value=job.fn()
        if before_callback then before_callback() end
        job.callback({ok=true,value=value})
    end
    function p:_cancel_interactive_network()
        self.cancelled=(self.cancelled or 0)+1
        local job=self.job
        self.job=nil; self._interactive_network_key=nil
        if job and job.on_cancel then job.on_cancel() end
    end
    function p:list(title,rows)
        require('miuread.transient_guard').close_all()
        self.menu={title=title,rows=rows,_miuread_modal_surface=true}
        require('ui/uimanager'):show(self.menu)
        return self.menu
    end
    function p:require_login() return self.logged_out~=true end
    function p:is_online() return self.offline~=true end
    function p:info(message) self.info_messages[#self.info_messages+1]=message end
    function p:toast(message) self.toasts[#self.toasts+1]=message end
    function p:_friendly_remote_error(message) return message end
    function p:_apply_interactive_auth(snapshot) self.auth=copy(snapshot.auth) end
    function p:_cancel_cover_loading() self.cover_cancels=(self.cover_cancels or 0)+1 end
    function p:_clear_cover_guard() end
    function p:_close_current_shelf() end
    function p:book_menu(book,back) self.book={value=book,back=back} end
    function p:_refresh_shelf_async(cb) self.refreshes=self.refreshes+1; cb({}, {}, nil) end
    function p:_reopen_shelf(mode,section)
        self.reopened={mode=mode,section=section}
        self._shelf_view._miu_closed=true
        self._shelf_view={_miu_closed=false}
    end
    function p:_home_enabled() return true end
    function p:_home_apply_remote_cache_snapshot() self.home_updated=true end
    return p
end

-- Exercise real preference normalization and Store defaults so an upgrade
-- cannot silently enable a seventh shortcut or overwrite a customized bar.
local store_file=assert(io.open('miuread.koplugin/miuread/store.lua','rb'))
local store_source=store_file:read('*a'); store_file:close()
local store_defaults=assert(store_source:match('(local defaults=%b{})'))
local prefs_store,default_preferences=assert(loadstring('local Store={}; local Config={}; local U=require("miuread.util")\n'
    ..store_defaults..'\n'..assert(store_source:match('(function Store:preferences%(%)[^\n]+)'))..'\n'
    ..assert(store_source:match('(function Store:save_preferences%(v%)[^\n]+)'))..'\nreturn Store,defaults.preferences'))()
local constants={}
for _,name in ipairs({'HOME_SECTION_ORDER','HOME_ACTION_ITEM_ORDER','HOME_ACTION_ITEM_DEFAULT',
    'HOME_PANEL_ITEM_ORDER','HOME_PANEL_ITEM_DEFAULT'}) do
    constants[#constants+1]=assert(source:match('(local '..name..'=%b{})'))
end
for _,name in ipairs({'HOME_ACTION_LAYOUT_VERSION','HOME_PANEL_LAYOUT_VERSION'}) do
    constants[#constants+1]=assert(source:match('(local '..name..'=%d+)'))
end
local preference_methods,preference_device=assert(loadstring([[
local Plugin={}
local U=require('miuread.util')
local Device={suspend=true,canSuspend=function(self) return self.suspend end}
local LocalLibrary={normalize=function(path) return tostring(path or '') end}
local lfs={attributes=function() return nil end}
local UiScale={setDisplayMode=function() end,setFontName=function() end}
local HomeView={is_shown=function() return false end}
]]..table.concat(constants,'\n')..'\n'
    ..assert(source:match('(function Plugin:_home_preferences%(%).-\nend)'))..'\n'
    ..assert(source:match('(function Plugin:_home_restore_all_quick_defaults%(%).-\nend)'))
    ..'\nreturn Plugin,Device'))()
local function preference_plugin(home)
    local p=plugin()
    p.settings.preferences=home and {home_ui=copy(home)} or {}
    p.store.preferences=prefs_store.preferences
    p.store.save_preferences=prefs_store.save_preferences
    p._home_preferences=preference_methods._home_preferences
    p._home_restore_all_quick_defaults=preference_methods._home_restore_all_quick_defaults
    function p:_home_ui_font_name() end
    function p:_save_home_preferences(home,preferences)
        preferences.home_ui=home; return self.store:save_preferences(preferences)
    end
    return p
end
local recommended=preference_plugin():_home_preferences()
assert(recommended.action_items.bookstore and not recommended.action_items.search)
assert(recommended.action_order[2]=='bookstore' and recommended.action_order[3]=='search')
local old=copy(default_preferences.home_ui)
old.action_layout_version=6; old.action_items.search=true; old.action_items.bookstore=nil
old.action_order={'refresh','search','downloads','sync','sleep','miuread_settings','all_books','history','file_manager','screenshot','extensions'}
local upgrade=preference_plugin(old)
local upgraded=upgrade:_home_preferences()
assert(upgraded.action_items.bookstore and not upgraded.action_items.search and upgraded.action_layout_version==7)
assert(upgraded.action_order[2]=='bookstore' and upgraded.action_order[3]=='search')
assert(table.concat(upgrade:_home_preferences().action_order,'|')==table.concat(upgraded.action_order,'|'),'layout migration repeated')
old.action_items.bookstore=false; old.action_order[#old.action_order+1]='bookstore'
assert(preference_plugin(old):_home_preferences().action_items.bookstore,'previous test-build default was not migrated')
local custom=copy(old); custom.action_items.sync=false; custom.action_items.bookstore=true
local custom_upgraded=preference_plugin(custom):_home_preferences()
assert(custom_upgraded.action_items.search and custom_upgraded.action_items.bookstore and not custom_upgraded.action_items.sync)
assert(custom_upgraded.action_order[2]=='bookstore' and custom_upgraded.action_order[3]=='search','auto-appended candidate remained at the tail')
custom.action_order={'downloads','bookstore','refresh','sync','search','sleep','miuread_settings','all_books','history','file_manager','screenshot','extensions'}
local custom_plugin=preference_plugin(custom)
custom_upgraded=custom_plugin:_home_preferences()
assert(table.concat(custom_upgraded.action_order,'|')==table.concat(custom.action_order,'|'),'explicit custom ordering was overwritten')
custom_plugin:_home_restore_all_quick_defaults()
assert(custom_plugin:_home_preferences().action_items.bookstore and not custom_plugin:_home_preferences().action_items.search)
custom=copy(old); custom.action_items.bookstore=nil; custom.action_items.refresh=false
assert(not preference_plugin(custom):_home_preferences().action_items.bookstore,'upgrade enabled a new button on a custom bar')
custom.action_layout_version=nil; custom.action_items.search=nil
local unversioned=preference_plugin(custom):_home_preferences()
assert(unversioned.action_items.search and not unversioned.action_items.bookstore,'unversioned customized preferences inherited the new defaults')
local search_actions=home_methods._home_action_function_actions({},'bookstore')
assert(#search_actions==4 and search_actions[2].label=='搜索微信读书' and search_actions[3].label=='搜索我的书架' and search_actions[4].label=='搜索批注','default bookstore hold lost search shortcuts')
preference_device.suspend=false
old.action_items.sleep=false
assert(preference_plugin(old):_home_preferences().action_items.bookstore,'device without suspend did not migrate its untouched defaults')
preference_device.suspend=true

local p=plugin()
M.open(p); assert(#p.menu.rows==5,'bookstore root entrances missing')
local root_menu=p.menu
M.browse(p,{kind='category',category_id='all',rank=true,title='All'})
assert(#views==0,'foreground request rendered before worker completed')
assert(root_menu._miu_closed,'bookstore menu remained under its loading surface')
p:finish()
assert(api.reader and api.reader.store==api.store,'bookstore worker omitted login recovery')
local first=views[#views]
assert(first.opts.books[1].bookId=='book0' and first.opts.books[1].display_title=='20. Title 0')
assert(first.opts.books[1].status_text:find('89%',1,true))
first.opts.tabs[3].callback(); p:finish()
assert(api.last_cursor==20 and first._miu_closed)
local second=views[#views]
second.opts.tabs[2].callback()
assert(not p.job and views[#views].opts.books[1].bookId=='book0','back navigation refetched a cached batch')
views[#views].opts.on_select(views[#views].opts.books[1])
assert(p.book.value.title=='Title 0' and p.book.back,'display rank polluted original book title')
p.book.back(); assert(not p.job and views[#views].opts.books[1].bookId=='book0')

-- Cached batches remain browsable offline; an explicit refresh does make a request.
p.offline=true
M.browse(p,{kind='category',category_id='all',rank=true,title='All'})
assert(not p.job)
p.offline=false
views[#views].opts.on_refresh(); assert(p.job); p:finish()

M.categories(p,false); p:finish()
local category=p.menu.rows[2]
assert(category.sub_item_table_func,'subcategory hierarchy lost')
local sub=category.sub_item_table_func()
assert(#sub==2)
sub[2].callback(); p:finish()
assert(api.last_category=='700001' and api.last_rank==false)

-- A cached list must retire any old primary menu just like a fetched list.
p:list('Old menu',{{text='old'}})
local old_menu=p.menu
M.browse(p,{kind='category',category_id='all',rank=true,title='All'})
assert(not p.job and old_menu._miu_closed,'cached page leaked a primary menu underneath')

api.refresh_auth=true
M.browse(p,{kind='recommend',title='Recommended'}); p:finish()
assert(p.auth.api_key=='renewed','child credential snapshot was not returned to the parent')
api.refresh_auth=false

M.similar(p,{bookId='original',title='Original'},function() p.returned=true end); p:finish()
views[#views].opts.tabs[3].callback(); p:finish()
assert(api.last_similar[1]=='original' and api.last_similar[2]==20 and api.last_similar[4]=='next-session')
views[#views].opts.tabs[1].callback(); assert(p.returned)

-- An obsolete page completion cannot replace a later page or cross accounts.
M.browse(p,{kind='category',category_id='rising',rank=true,title='Rising'})
local obsolete=p.job
M.browse(p,{kind='category',category_id='newbook',rank=true,title='New'})
local view_count=#views
obsolete.callback({ok=true,value=obsolete.fn()})
assert(#views==view_count)
p.auth.account.vid='bob'
p:finish(); assert(#views==view_count,'old account result displayed')
assert(dialogs[#dialogs].bookstore_done,'account switch left a loading modal behind')
M.browse(p,{kind='category',category_id='all',rank=true,title='All'})
assert(p.job,'account switch retained personalized caches'); p:finish()
local account_view=views[#views]
M.reset(p)
assert(account_view._miu_closed and p._bookstore==nil,'auth transition retained an idle account view/cache')

-- A successful readback refreshes the shelf, while ambiguous writes persist.
p=plugin(); api.present=false; api.effect=true; api.writes=0; api.reads=0
assert(M.add_to_shelf(p,{bookId='a',title='A'}))
assert(p.settings.bookstore_shelf_pending.alice.a,'write uncertainty was not persisted first')
assert(not M.add_to_shelf(p,{bookId='a',title='A'}),'double-tap spawned duplicate write')
p:finish()
assert(api.writes==1 and p.refreshes==1 and p.home_updated)
assert(not p.settings.bookstore_shelf_pending.alice)

api.present=false; api.effect=false; api.lose_reply=true
assert(M.add_to_shelf(p,{bookId='b',title='B'})); p:finish()
assert(p.settings.bookstore_shelf_pending.alice.b)
local writes=api.writes
assert(M.add_to_shelf(p,{bookId='b',title='B'})); p:finish()
assert(api.writes==writes,'uncertain write was repeated instead of verified')
assert(not p.settings.bookstore_shelf_pending.alice)

-- Cancellation/restart loses the callback but preserves verification-only state.
api.effect=true; api.lose_reply=false; api.present=false
M.add_to_shelf(p,{bookId='c',title='C'})
local interrupted=p.job
interrupted.fn() -- the server accepted the request before its parent was stopped
dialogs[#dialogs].buttons[1][1].callback()
assert(not p.job and p.settings.bookstore_shelf_pending.alice.c,'cancel discarded pending write uncertainty')
local pending_settings=copy(p.settings)
local restarted=plugin(); restarted.settings=pending_settings
writes=api.writes
M.add_to_shelf(restarted,{bookId='c',title='C'}); restarted:finish()
assert(api.writes==writes and not restarted.settings.bookstore_shelf_pending.alice)

p=plugin(); p.fail_save=true; writes=api.writes
assert(not M.add_to_shelf(p,{bookId='d',title='D'}) and not p.job and api.writes==writes)
assert(not p.settings.bookstore_shelf_pending.alice,'failed persistence left uncommitted intent in memory')
p.fail_save=false; api.present=false
assert(M.add_to_shelf(p,{bookId='d',title='D'})); p:finish()
assert(api.writes==writes+1,'failed intent persistence turned a later retry into verification-only')

-- Clearing a confirmed intent can fail after Store:set changes live settings.
-- Preserve the original pending record so a retry still only reads the server.
p=plugin(); api.present=false
M.add_to_shelf(p,{bookId='persist',title='Persist'})
p:finish(function() p.fail_save=true end)
assert(p.settings.bookstore_shelf_pending.alice.persist,'failed clear discarded durable write uncertainty')
p.fail_save=false; writes=api.writes
M.add_to_shelf(p,{bookId='persist',title='Persist'}); p:finish()
assert(api.writes==writes and not p.settings.bookstore_shelf_pending.alice,'failed-clear recovery repeated a POST')
p=plugin(); p.fail_start=true
assert(not M.add_to_shelf(p,{bookId='e',title='E'}))
assert(not p.settings.bookstore_shelf_pending.alice,'worker-start failure left a phantom pending write')
p=plugin(); p.offline=true
assert(not M.add_to_shelf(p,{bookId='f',title='F'}) and not p.settings.bookstore_shelf_pending)
p=plugin(); p.auth.cookies.wr_skey=nil
assert(not M.add_to_shelf(p,{bookId='g',title='G'}) and not p.job)

p=plugin()
M.browse(p,{kind='category',category_id='all',rank=true,title='All'})
local cancelled_page=p.job
view_count=#views
dialogs[#dialogs].buttons[1][1].callback()
assert(not p.job)
cancelled_page.callback({ok=true,value=cancelled_page.fn()})
assert(#views==view_count,'cancelled load reopened its list')

-- The known full shelf selects removal; its confirmation uses the existing
-- modal and cannot persist an intent, write, or delete local files on cancel.
local book={bookId='remove',title='Remove me'}
p=plugin(); p.settings.shelf_cache={raw_books={book}}
p.settings.downloads={remove={file='kept.epub'}}
p._shelf_view={_miu_closed=false}; p._last_shelf_mode=false; p._last_shelf_section='account'
api.present=true; api.effect=true; api.lose_reply=false; api.fail_reads=false
local action=M.shelf_action(p,book)
assert(action.text=='从微信书架移除')
p:list('Book menu',{{text='old'}})
old_menu=p.menu; writes=api.writes
action.callback()
local stack=require('ui/uimanager')._window_stack
local confirmation=stack[#stack].widget
assert(old_menu._miu_closed and confirmation.ok_text=='移除' and confirmation.cancel_text=='取消')
assert(confirmation.text:find('Remove me',1,true) and confirmation.text:find('本机已下载的文件会保留',1,true))
assert(not p.job and not p.settings.bookstore_shelf_pending and api.writes==writes)
require('ui/uimanager'):close(confirmation)
assert(not p.job and not p.settings.bookstore_shelf_pending and api.writes==writes,'cancel submitted removal')
M.remove_from_shelf(p,book)
confirmation=stack[#stack].widget
confirmation.ok_callback()
assert(p.job and p.settings.bookstore_shelf_pending.alice.remove.desired==false)
assert(not M.remove_from_shelf(p,book),'double-tap spawned duplicate removal')
p:finish()
assert(api.writes==writes+1 and api.last_target==false and not api.present and p.refreshes==1 and p.home_updated)
assert(p.reopened and p.reopened.section=='account' and p.reopened.mode==false,'visible shelf was not refreshed after removal')
assert(p.toasts[#p.toasts]=='已从微信书架移除' and p.settings.downloads.remove.file=='kept.epub')
assert(logs[#logs]:find('state= verified',1,true) and logs[#logs]:find('present= false error= none',1,true),
    'successful shelf mutation logged a phantom error')
assert(M.shelf_action(p,book).text=='加入微信书架','verified removal retained a stale shelf-cache action')

-- A stale remove menu for a book already removed on the phone needs no new
-- authorization: fresh Web membership can confirm the result directly.
p=plugin(); p.auth.native_shelf=nil; api.present=false; writes=api.writes
local no_scan_count=#auth_flows
M.remove_from_shelf(p,book); stack[#stack].widget.ok_callback(); p:finish()
assert(#auth_flows==no_scan_count and api.writes==writes and p.toasts[#p.toasts]=='已不在微信书架')

-- Web-only users get an explicit scan entrance after fresh membership proves
-- a removal is needed. Opening/cancelling/completing that scan never removes.
p=plugin(); p.auth.native_shelf=nil; api.present=true; writes=api.writes
local flow_count=#auth_flows
M.remove_from_shelf(p,book); stack[#stack].widget.ok_callback(); p:finish()
local auth_dialog=stack[#stack].widget
assert(auth_dialog.buttons[1][1].text=='微信扫码授权' and not p.job
    and not p.settings.bookstore_shelf_pending.alice and api.writes==writes)
auth_dialog.buttons[1][2].callback()
assert(#auth_flows==flow_count and api.writes==writes)
M.remove_from_shelf(p,book); stack[#stack].widget.ok_callback(); p:finish()
stack[#stack].widget.buttons[1][1].callback()
local auth_flow=auth_flows[#auth_flows]
assert(auth_flow.started and auth_flow.backend and p._bookstore_shelf_auth==auth_flow)
auth_flow.host:on_auth_success()
assert(api.writes==writes and not p.settings.bookstore_shelf_pending.alice
    and p.info_messages[#p.info_messages]:find('重新选择',1,true))
M.reset(p)
assert(auth_flow.cancelled and not p._bookstore_shelf_auth)
-- A pending task is verified through Web membership without requiring native
-- authorization; no expired client token can turn verification into a write.
p=plugin(); p.auth.native_shelf=nil
p.settings.bookstore_shelf_pending={alice={remove={desired=false,started_at=1}}}
flow_count=#auth_flows
M.remove_from_shelf(p,book); assert(p.job); p:finish()
assert(#auth_flows==flow_count and api.writes==writes and not p.settings.bookstore_shelf_pending.alice)
-- Changing accounts before opening the scan leaves both auth and shelf alone.
p=plugin(); p.auth.native_shelf=nil
M.remove_from_shelf(p,book); stack[#stack].widget.ok_callback(); p:finish()
auth_dialog=stack[#stack].widget
p.auth.account.vid='bob'; auth_dialog.buttons[1][1].callback()
assert(#auth_flows==flow_count and api.writes==writes and not p.job)

-- Both UI paths use the same action, including legacy caches whose full raw
-- snapshot is unavailable. Unrelated local/provider menus never expose it.
p=plugin(); p.settings.shelf_cache={books={book}}
assert(M.shelf_action(p,book).text=='从微信书架移除','legacy effective shelf lost the removal entrance')
p._home_hold_book=home_methods._home_hold_book
p._finished_status_action=home_methods._finished_status_action
function p:logged_in() return true end
function p:_request_finished_status(target,desired) self.finished_request={id=target.bookId,desired=desired} end
function p:_local_entry_mode() return '',nil end
function p:_home_attach_local_record() end
function p:_preferred_record() return nil end
p.book_delete_service={summary=function() return {has_local=false} end}
function p:_download_state() return {} end
function p:_home_variant_download_context() return {} end
function p:_home_variant_download_action() return {label='下载'} end
p:_home_hold_book({bookId='remove',title='Remove me',unified_source='weread'})
local home_action,finished_action
for _,row in ipairs(last_home_sheet().actions) do
    if row.label=='从微信书架移除' then home_action=row end
    if row.label=='标记为已读完' then finished_action=row end
end
assert(home_action,'Home long-press menu omitted shelf management')
assert(finished_action,'Home long-press menu omitted reading status alongside shelf management')
finished_action.callback()
assert(p.finished_request.id=='remove' and p.finished_request.desired==true)
writes=api.writes; home_action.callback()
assert(stack[#stack].widget.ok_text=='移除' and not p.job and api.writes==writes)
for _,other in ipairs({{unified_source='local'},{unified_source='zlibrary'},
    {unified_source='fanqie',external_source='fanqie'},{bookId='MP_WXS_1',unified_source='wechat_mp'}}) do
    other.bookId=other.bookId or 'remove'
    p:_home_hold_book(other)
    for _,row in ipairs(last_home_sheet().actions) do
        assert(row.label~='从微信书架移除' and row.label~='加入微信书架','another provider exposed WeRead shelf mutation')
        assert(row.label~='标记为已读完' and row.label~='取消读完标记','another provider exposed WeRead reading status')
    end
end

-- Account/session changes while the confirmation is open cannot remove a book
-- using another login, even when the new account has the same numeric vid.
for _,change in ipairs({'account','session'}) do
    p=plugin(); writes=api.writes
    M.remove_from_shelf(p,book)
    confirmation=stack[#stack].widget
    if change=='account' then p.auth.account.vid='bob' else p.auth.login_session_id='two' end
    confirmation.ok_callback()
    assert(not p.job and not p.settings.bookstore_shelf_pending and api.writes==writes)
end

-- Ambiguous removal survives cancellation/restart and opposing stale menus.
p=plugin(); api.present=true; api.effect=false; api.lose_reply=true
M.remove_from_shelf(p,book); stack[#stack].widget.ok_callback(); p:finish()
assert(p.settings.bookstore_shelf_pending.alice.remove.desired==false)
assert(M.shelf_action(p,book).text=='确认微信书架状态')
writes=api.writes
M.add_to_shelf(p,book); p:finish()
assert(api.writes==writes and api.present,'opposing stale add action replayed an uncertain removal')
assert(not p.settings.bookstore_shelf_pending.alice and M.shelf_action(p,book).text=='从微信书架移除')

api.effect=true; api.lose_reply=true
M.remove_from_shelf(p,book); stack[#stack].widget.ok_callback()
interrupted=p.job; interrupted.fn()
dialogs[#dialogs].buttons[1][1].callback()
assert(not p.job and p.settings.bookstore_shelf_pending.alice.remove.desired==false)
restarted=plugin(); restarted.settings=copy(p.settings); writes=api.writes
M.add_to_shelf(restarted,book); restarted:finish()
assert(api.writes==writes and not restarted.settings.bookstore_shelf_pending.alice and not api.present)
assert(restarted.toasts[#restarted.toasts]=='已不在微信书架')

-- Older add-only ledger entries also remain verification-only if the user
-- reaches them from a removal action after installing this version.
p=plugin(); p.settings.bookstore_shelf_pending={alice={remove={started_at=1}}}
api.present=false; writes=api.writes
M.remove_from_shelf(p,book); assert(p.job); p:finish()
assert(api.writes==writes and not p.settings.bookstore_shelf_pending.alice)
assert(M.shelf_action(p,book).text=='加入微信书架')

-- Unknown preflight and failed persistence cannot permit a removal POST.
p=plugin(); api.present=true; api.fail_reads=true; writes=api.writes
M.remove_from_shelf(p,book); stack[#stack].widget.ok_callback(); p:finish()
assert(api.writes==writes and not p.settings.bookstore_shelf_pending.alice)
assert(p.info_messages[#p.info_messages]:find('未提交移除',1,true))
-- An older uncertain write must survive the same failed membership read.
p=plugin(); p.settings.bookstore_shelf_pending={alice={remove={started_at=1,desired=false}}}
M.remove_from_shelf(p,book); p:finish()
assert(api.writes==writes and p.settings.bookstore_shelf_pending.alice.remove.desired==false)
api.fail_reads=false; api.lose_reply=false

-- Native credential rejection happened before the POST, so there is no pending
-- write or promise of automatic renewal. Logs keep only stage/class/code.
p=plugin(); api.present=true; api.block_native=true; writes=api.writes
M.remove_from_shelf(p,book); stack[#stack].widget.ok_callback(); p:finish()
assert(api.writes==writes and not p.settings.bookstore_shelf_pending.alice)
local authorization=stack[#stack].widget
local message=authorization.title
assert(message:find('书架管理需要客户端授权',1,true) and authorization.buttons[1][1].text=='微信扫码授权')
assert(message:find('-2011',1,true) and not message:find('自动尝试续期',1,true)
    and not message:find('secret-sentinel',1,true))
assert(M.shelf_action(p,book).text=='从微信书架移除' and p.refreshes==0)
assert(logs[#logs]:find('state= blocked',1,true) and logs[#logs]:find('stage= credentials',1,true)
    and logs[#logs]:find('code=-2011:http=401',1,true))
for _,line in ipairs(logs) do assert(not line:find('secret-sentinel',1,true),'credential leaked into diagnostic log') end
api.block_native=false
-- A later explicit retry performs one removal and clears the new intent.
api.effect=true
M.remove_from_shelf(p,book); stack[#stack].widget.ok_callback(); p:finish()
assert(api.writes==writes+1 and not p.settings.bookstore_shelf_pending.alice)
writes=api.writes
p=plugin(); p.fail_save=true
M.remove_from_shelf(p,book); stack[#stack].widget.ok_callback()
assert(not p.job and api.writes==writes and not p.settings.bookstore_shelf_pending.alice)

-- Exercise the shared worker's real cancellation hook, including results
-- dropped by its reader/home context guard rather than explicit cancellation.
local cancel_method=assert(source:match('function Plugin:_cancel_interactive_network%(reason%).-\nend'))
local run_method=assert(source:match('function Plugin:_run_interactive_network%(key,label,worker,callback,options%).-\nend'))
local methods=assert(loadstring([[
local Plugin={}
local logger={info=function() end}
local function monotonic_wall_time() return 0 end
local function _(text) return text end
]]..cancel_method..'\n'..run_method..'\nreturn Plugin'))()
local worker_plugin=setmetatable({valid=true,jobs={}},{__index=methods})
function worker_plugin:is_online() return true end
function worker_plugin:_interactive_network_context() return {} end
function worker_plugin:_interactive_network_context_valid() return self.valid end
function worker_plugin:info() end
function worker_plugin:toast() end
worker_plugin.interactive_network_async={
    available=function() return true end,
    busy=function() return worker_plugin.active~=nil end,
    cancel=function() worker_plugin.active=nil end,
    run=function(_,label,fn,callback)
        local job={callback=callback}
        worker_plugin.jobs[#worker_plugin.jobs+1]=job
        worker_plugin.active=job
        return true
    end,
}
local cancelled,completed=0,0
local function start(key)
    assert(worker_plugin:_run_interactive_network(key,key,function() end,
        function() completed=completed+1 end,{on_cancel=function() cancelled=cancelled+1 end}))
    return worker_plugin.active
end
local cancelled_job=start('cancel')
worker_plugin:_cancel_interactive_network('user cancelled')
worker_plugin:_cancel_interactive_network('already stopped')
cancelled_job.callback({ok=true})
assert(cancelled==1 and completed==0,'shared cancellation hook did not run exactly once')
local stale_job=start('stale')
worker_plugin.active=nil; worker_plugin.valid=false
stale_job.callback({ok=true})
assert(cancelled==2 and completed==0,'context guard left bookstore modal open')
worker_plugin.valid=true
local old_job=start('old')
local new_job=start('new')
old_job.callback({ok=true})
assert(cancelled==3 and completed==0,'superseded worker reached its callback')
worker_plugin.active=nil; new_job.callback({ok=true})
worker_plugin:_cancel_interactive_network('after completion')
assert(cancelled==3 and completed==1,'completed worker retained its cancellation hook')
print('bookstore UI navigation and shelf recovery: PASS')
