require('setupkoenv')
local path=assert(arg[1])
local f=assert(io.open(path)); local source=f:read('*a'); f:close()
local a=assert(source:find('local function compact_settings(',1,true))
local b=assert(source:find('local function settings_payload_valid(',a,true))
local dump=require('dump')
local payload=assert(loadstring('local dump=...; '..source:sub(a,b-1)..' return settings_payload'))(dump)
local shared={text='shared'}
local data={empty={},flag=false,[false]='boolean key',[4]='sparse',[-2]='negative',fraction=1/3,
 text='中文 "quoted" \\ slash\nnext\r\t\0\255',one=shared,two=shared,nested={a={b='end ]= --'}}}
local text=payload(data,'test.lua')
local expected=assert(loadstring('return '..dump(data)))()
local restored=assert(loadstring(text))()
assert(dump(restored,nil,true)==dump(expected,nil,true),'compact roundtrip differs from native dump')
assert(#text < #('return '..dump(data)),'ordinary settings were not compacted')
local cyclic={name='cycle'}; cyclic.self=cyclic
assert(payload(cyclic,'test.lua')=='-- test.lua\nreturn '..dump(cyclic)..'\n','cycle fallback changed')
local key={name='table key'}; local unusual={[key]='value'}
assert(payload(unusual,'test.lua')=='-- test.lua\nreturn '..dump(unusual)..'\n','table-key fallback changed')
local unsupported={callback=function() end}
assert(payload(unsupported,'test.lua')=='-- test.lua\nreturn '..dump(unsupported)..'\n','unsupported value fallback changed')
print('COMPACT_SETTINGS_NATIVE_COMPATIBILITY_OK')
