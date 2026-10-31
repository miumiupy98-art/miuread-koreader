-- Real 6.5.0-beta.10 Lua gate with isolated mock Web and download checkpoints.
local root=(arg[0] or ''):gsub('tools/test_650_beta10_coordinate_gate.lua$','')
package.path=root..'miuread.koplugin/?.lua;'..root..'miuread.koplugin/?/init.lua;'..package.path
local saved,localfiles,calls={}, {}, 0
package.preload['miuread.util']=function()
    return {read_file=function(path) return localfiles[path] end}
end
package.preload['miuread.http']=function()
    return {is_rate_limit_error=function(s)return tostring(s):find('429',1,true)~=nil end,
        is_auth_error=function(s)return tostring(s):find('401',1,true)~=nil end,
        is_network_error=function(s)return tostring(s):find('offline',1,true)~=nil end}
end
package.preload['logger']=function()
    return {info=function() end,warn=function() end}
end
package.preload['miuread.source_position']=function()
    return {
        readExactChapter=function(_,id,uid,version) return saved[uid..':'..version] end,
        validateDownloadChapter=function(local_html,web_html)
            if local_html==web_html and #local_html>=12 then return {ready=true,anchors=3} end
            return nil,'anchor_mismatch'
        end,
        cacheChapter=function(_,id,uid,version,html) saved[uid..':'..version]=html;return true end,
    }
end
local Gate=require('miuread.download_source_gate')
local checkpoints=0
local catalog={
  {uid='10',title='Chapter 10',index=10,structural=false},
  {uid='11',title='Chapter 11',index=11,structural=false},
  {uid='contents',title='Contents',structural=true},
}
localfiles['/checkpoint/a']='A sentence from local and remote chapter 10'
localfiles['/checkpoint/b']='Another unique chapter with real text at 11'
local manifest={chapters={
   ['10']={complete=true,coord_file='a'},
   ['11']={complete=true,coord_file='b'},
}}
local remote_b=localfiles['/checkpoint/b']
local reader={}
function reader:chapter(book,ch,format,opt)
    calls=calls+1
    assert(opt.fresh_context==true and opt.images==false)
    assert(format=='epub')
    if ch.uid=='10' then return localfiles['/checkpoint/a'],nil,nil,{coord_html=localfiles['/checkpoint/a'],source_channel='web'} end
    return remote_b,nil,nil,{coord_html=remote_b,source_channel='web'}
end
local function run()
  return Gate.prepare({book={bookId='b',version=3},chapters=catalog,format='epub',
   cache={root='/checkpoint',manifest=manifest},reader=reader,
   save_checkpoint=function() checkpoints=checkpoints+1 end,
   checkpoint=function() end,progress=function()end})
end
local result,err=run()
assert(result and result.complete and result.verified==2 and result.expected==2,tostring(err))
assert(calls==2 and checkpoints==2)
assert(manifest.chapters['10'].source_verified and manifest.chapters['11'].source_verified)
result,err=run()
assert(result and result.complete and calls==2,'cached exact Web source should avoid refetch')
localfiles['/checkpoint/b']='changed native content that cannot align'
local failed,reason=run()
assert(not failed and reason:find('web_source_validation_failed',1,true),'mismatch must block install')
assert(manifest.chapters['11'].source_verified==false,'mismatch not verified')
assert(calls==3,'must fetch authoritative Web again after mismatch')
-- No chapter in the manifest may count as ready merely because it has source_cache_done.
manifest.chapters['10'].complete=false
failed,reason=run()
assert(not failed and reason:find('checkpoint_missing',1,true))
print('beta10 source gate Lua scenarios PASS')
