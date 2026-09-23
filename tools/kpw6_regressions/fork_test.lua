require('setupkoenv')
local candidate=arg[1] or 'plugins/miuread.koplugin'
package.path=candidate..'/?.lua;plugins/miuread.koplugin/?.lua;'..package.path
local socket=require('socket')
local H=require('miuread.subprocess_hygiene')
local F=require('ffi/util')
local listener=assert(socket.tcp());assert(listener:bind('127.0.0.1',0));assert(listener:listen(1))
assert(socket.dns.toip('weread.qq.com'))
local path='/tmp/miuread-resolver-child-test'
os.remove(path)
local pid=assert(F.runInSubProcess(function()
 assert(H.close_inherited_sockets())
 local f=assert(io.open(path,'w'))
 local ok=socket.dns.toip('weread.qq.com')
 assert(ok)
 assert(f:write('CHILD_DNS_AND_REUSED_FD_OK'));assert(f:close())
end,false,false))
for i=1,80 do if F.isSubProcessDone(pid,false) then break end socket.sleep(.1) end
local f=assert(io.open(path));assert(f:read('*a')=='CHILD_DNS_AND_REUSED_FD_OK');f:close();os.remove(path)
assert(listener:getsockname());listener:close()
assert(socket.dns.toip('weread.qq.com'))
print('FORK_RESOLVER_PARENT_SOCKET_AND_CHILD_FILE_OK')
