-- Execute production source_position.lua validation in an isolated Lua runtime.
local root=(arg[0] or ''):gsub('tools/test_650_beta10_source_map.lua$','')
package.path=root..'miuread.koplugin/?.lua;'..package.path
package.preload['miuread.util']=function()
    return {trim=function(s)return tostring(s or ''):match('^%s*(.-)%s*$') end}
end
package.preload['miuread.annotations.posmap']=function()
    return {build=function(html)
      local chars,indices={},{}
      local text=tostring(html or ''):gsub('<[^>]*>','')
      for k=1,#text do
         local c=text:sub(k,k)
         chars[k]=c
         if not c:match('%s') then indices[#indices+1]=k end
      end
      local norm={}
      for _,i in ipairs(indices) do norm[#norm+1]=chars[i] end
      return {text_runes=chars,norm_map=indices,norm_text=table.concat(norm)}
    end}
end
package.preload['miuread.wr_co']=function() return {} end
package.preload['logger']=function() return {info=function()end,warn=function()end} end
package.preload['libs/libkoreader-lfs']=function() return {} end
local sp=require('miuread.source_position')
local parts={}
for i=1,130 do parts[#parts+1]=string.format('token%04dZ',i) end
local body=table.concat(parts,' ')
local result,err=sp.validateDownloadChapter('<article><p>'..body..'</p></article>','<div>'..body..'</div>')
assert(result and result.anchors==3,tostring(err))
local changed=body:gsub('token0065Z','differentX')
result,err=sp.validateDownloadChapter('<p>'..body..'</p>','<div>'..changed..'</div>')
assert(not result and tostring(err):find('source_full_text_mismatch',1,true),tostring(err))
result,err=sp.validateDownloadChapter('<p>short</p>','<p>short</p>')
assert(not result and err=='source_text_too_short_or_image_only')
local dup=string.rep('duplicateword ',50)
result,err=sp.validateDownloadChapter('<p>'..dup..'</p>','<div>'..dup..'</div>')
assert(result and result.mode=='full_text_equal',tostring(err))
local corrupted=dup:sub(1,100)..'BROKEN'..dup:sub(101)
result,err=sp.validateDownloadChapter('<p>'..dup..'</p>','<p>'..corrupted..'</p>')
assert(not result and err=='source_full_text_mismatch',tostring(err))
local wrapped='HEADWRAPPER12345'..dup..'ENDWRAPPER12345'
result,err=sp.validateDownloadChapter('<p>'..dup..'</p>','<p>'..wrapped..'</p>')
assert(result and result.mode=='unique_contiguous_span',tostring(err))
result,err=sp.validateDownloadChapter('<p>'..dup..'</p>','<p>'..dup..dup..'</p>')
assert(not result and err=='source_full_text_mismatch',tostring(err))
print('beta10 source mapping Lua scenarios PASS')
