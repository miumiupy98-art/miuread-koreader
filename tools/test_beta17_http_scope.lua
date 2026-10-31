-- Isolated tests of the actual Http cooldown persistence functions.
package.preload['ltn12']=function()return {}end
package.preload['socketutil']=function()return {}end
package.preload['miuread.config']=function()return {}end
package.preload['miuread.network_policy']=function()return {}end
package.preload['miuread.network_health']=function()return {}end
package.preload['miuread.cookies']=function()return {}end
package.preload['miuread.protocol']=function()return {USER_AGENT='test'}end
package.preload['logger']=function()return {warn=function()end}end
local files={}
package.preload['miuread.util']=function()return {
  read_file=function(p) return files[p] end,
  atomic_write=function(p,data)files[p]=data;return true end,
  redact_url=function(u)return u end,
}end
package.preload['miuread.json']=function()return {
  encode=function(obj) return ('%s;%s;%s'):format(obj.until_at,obj.scope,obj.code) end,
  decode=function(text)local a,b,c=text:match('^(%d+);([^;]+);([^;]+)$');return {until_at=tonumber(a),scope=b,code=c} end,
}end
package.path='./miuread.koplugin/?.lua;./miuread.koplugin/?/init.lua;'..package.path
local Http=require('miuread.http')
local h=Http:new({data_dir='/tmp/miuread-beta17-scope-test'})
local global_path=h:_rate_limit_path('global')
local google_path=h:_rate_limit_path('metadata-google')
local open_path=h:_rate_limit_path('metadata-openlibrary')
assert(global_path~=google_path and global_path~=open_path and google_path~=open_path)
h:_set_shared_rate_limit(300,429,'https://www.googleapis.com/books/v1/volumes','metadata-google')
local remaining,state=h:_shared_rate_limit('metadata-google')
assert(remaining>=290 and state.scope=='metadata-google')
assert(h:_shared_rate_limit('global')==0, 'Google 429 must not block WeRead global scope')
assert(h:_shared_rate_limit('metadata-openlibrary')==0, 'Google 429 must not block Open Library')
h:_set_shared_rate_limit(300,429,'https://openlibrary.org/isbn/xx','metadata-openlibrary')
assert(h:_shared_rate_limit('global')==0, 'Third-party 429s must not create a WeRead cooldown')
assert(h.rate_limit_until==0,'Metadata fail-fast should not set the instance pacing wait')
assert(files[global_path]==nil,'Global cooldown file must remain untouched')
print('PASS beta17 HTTP: independent provider cooldown files and global WeRead isolation')
