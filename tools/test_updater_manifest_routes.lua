-- #127: the update manifest must only come from official URLs, even when a
-- mirror route was remembered by an older version.
local TOOL_DIR=tostring(arg and arg[0] or ''):match('^(.*)/[^/]+$') or '.'
local ROOT=TOOL_DIR..'/../miuread.koplugin/'
package.path=ROOT..'?.lua;'..package.path

local OFFICIAL='https://github.com/miumiupy98-art/miuread-koreader/releases/download/stable-channel/update.json'
local MIRROR='https://ghfast.top/'
package.preload['miuread.config']=function()
    return {
        GITHUB_MIRRORS={MIRROR,'https://gh-proxy.com/'},
        UPDATE_CHANNELS={stable={label='stable',manifest=OFFICIAL,manifests={OFFICIAL}}},
    }
end
package.preload['miuread.digests']=function() return {} end
package.preload['miuread.util']=function() return {} end
package.preload['logger']=function() return {info=function() end,warn=function() end,err=function() end} end

local Updater=require('miuread.updater')
local values={}
local store={
    get=function(_,key,default) local v=values[key]; if v==nil then return default end; return v end,
    set=function(_,key,value) values[key]=value end,
}
local updater=Updater:new(nil,store,'6.0.0','/tmp')
local checks=0
local function check(cond,msg) checks=checks+1; assert(cond,msg) end

local urls=updater:manifest_urls('stable')
check(#urls==1 and urls[1]==OFFICIAL,'manifest routes must be official only, got '..table.concat(urls,', '))

values['update_last_good_manifest_url_stable']=MIRROR..OFFICIAL
urls=updater:manifest_urls('stable')
check(#urls==1 and urls[1]==OFFICIAL,'remembered mirror route must not be used for the manifest')
check(updater:manifest_url('stable')==OFFICIAL,'manifest_url must return the official URL')

values['update_last_good_manifest_url_stable']=nil
values['update_last_good_manifest_url']=MIRROR..OFFICIAL
urls=updater:manifest_urls('stable')
check(#urls==1 and urls[1]==OFFICIAL,'legacy remembered mirror route must not be used')

values['update_last_good_manifest_url']=nil
check(updater:remember_manifest_route(MIRROR..OFFICIAL,'stable')==false,'mirror manifest route must not be remembered')
check(values['update_last_good_manifest_url_stable']==nil,'mirror manifest route was persisted')
check(updater:remember_manifest_route(OFFICIAL,'stable')==true,'official manifest route must still be remembered')
check(values['update_last_good_manifest_url_stable']==OFFICIAL,'official manifest route was not persisted')

print('test_updater_manifest_routes: '..checks..' checks passed')
