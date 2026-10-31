local blobs,stored={},{}
package.preload['miuread.util']=function()return {
 id_name=function(v)return tostring(v) end,mkdir=function()return true end,
 read_file=function(p)return blobs[p] end,
 atomic_write=function(p,v)blobs[p]=v;return true end,
}end
local counter=0
package.preload['miuread.json']=function()return {
 encode=function(t)counter=counter+1;local id='id'..counter;stored[id]=t;return id end,
 decode=function(id)return stored[id] end
}end
package.preload['miuread.digests']=function()return {md5=function(s)return tostring(#s)..':'..s end}end
package.path='./miuread.koplugin/?.lua;./miuread.koplugin/?/init.lua;'..package.path
local p=require('miuread.web_source_provenance')
local auth={account={vid='u1'},login_session_id='session-a'}
local reader={store={auth=function()return auth end,book_dir=function()return '/book' end}}
assert(not p.is_trusted(reader,'book','2',10,'web text'))
assert(p.mark(reader,'book','2',10,'web text'))
assert(p.is_trusted(reader,'book','2',10,'web text'))
assert(not p.is_trusted(reader,'book','2',10,'web Xext'))
assert(not p.is_trusted(reader,'book','3',10,'web text'))
assert(not p.is_trusted(reader,'book','2',11,'web text'))
auth.login_session_id='session-b'
assert(not p.is_trusted(reader,'book','2',10,'web text'))
print('PASS beta16 provenance: content, chapter, version, session fences')
