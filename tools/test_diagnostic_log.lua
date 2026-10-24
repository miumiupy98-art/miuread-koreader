package.path='miuread.koplugin/?.lua;'..package.path
local files,events={},{}
local open,rename,remove=io.open,os.rename,os.remove
local unavailable=false
io.open=function(path,mode)
    if unavailable then error('storage unavailable') end
    if mode=='rb' and not files[path] then return nil end
    files[path]=files[path] or ''
    local position=0
    return {
        seek=function(_,kind,offset)
            position=kind=='end' and #files[path] or offset or 0
            return position
        end,
        read=function() return files[path]:sub(position+1) end,
        write=function(_,value) files[path]=files[path]..value; return true end,
        close=function() return true end,
    }
end
os.remove=function(path) files[path]=nil; return true end
os.rename=function(source,target)
    if not files[source] then return nil end
    files[target],files[source]=files[source],nil
    return true
end
package.preload['logger']=function() return {
    info=function(_,line) events[#events+1]=line end,
    warn=function(_,line) events[#events+1]=line end,
} end
package.preload['miuread.util']=function() return {atomic_write=function(path,data)
    files[path]=data; return true
end} end
local Log=require('miuread.diagnostic_log')
local store={data_dir='/settings/miuread',books_root=function() return '/downloads' end}
assert(not Log.export(store),'empty logs were exported')
Log.MAX_BYTES=260
for _=1,12 do
    Log.record(store,{operation='search',channel='eink',outcome='success',elapsed_ms=7})
end
local path=store.data_dir..'/miuread.log'
assert(files[path] and files[path..'.1'] and #files[path]<=Log.MAX_BYTES and #files[path..'.1']<=Log.MAX_BYTES)
Log.record(store,{operation='chapter',outcome='error',code=499,
    request_body='private-body',accessToken='private-token',url='https://private.example',
    reason='HTTP 499 private-response'})
local exported=assert(Log.export(store))
local contents=files[exported]
assert(exported:find('/downloads/miuread-diagnostics-',1,true) and #contents<=2*Log.MAX_BYTES)
assert(contents:find('operation=chapter',1,true) and contents:find('code=499',1,true))
assert(not contents:find('private',1,true) and not contents:find('https:',1,true),
    'request contents or credentials entered the exported log')
assert(#events==13,'the system logger did not receive the same operation events')
unavailable=true
assert(pcall(Log.record,store,{operation='download',outcome='error'}),'log failure escaped into the operation')
io.open,os.rename,os.remove=open,rename,remove
print('diagnostic log: bounded rotation, safe export and write-failure isolation PASS')
