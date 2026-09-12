local f=assert(io.open(assert(arg[1]))); local source=f:read('*a'); f:close()
local a=assert(source:find('function Plugin:_home_full_refresh(',1,true))
local b=assert(source:find('\nfunction Plugin:',a+1,true))
local calls=0
local env={Plugin={},UIManager={setDirty=function(_,widget,kind)
    assert(widget==nil and kind=='full'); calls=calls+1
end},logger={warn=function() end}}
setmetatable(env,{__index=_G})
local chunk=assert(loadstring(source:sub(a,b-1)))
setfenv(chunk,env); chunk()
local active=nil
local stale_calls=0
local host={ui={devicelistener={onFullRefresh=function() stale_calls=stale_calls+1; error('closed document') end}},
    _active_reader_ui=function() return active end}
local refresh=env.Plugin._home_full_refresh
assert(refresh(host,true) and calls==1 and stale_calls==0,'Home used closed Reader listener')
local reader_calls=0
active={document={},devicelistener={onFullRefresh=function() reader_calls=reader_calls+1 end}}
assert(refresh(host,true) and calls==1 and reader_calls==1,'active Reader footer refresh was lost')
active.document=nil
assert(refresh(host,true) and calls==2 and reader_calls==1,'closing Reader was refreshed')
active={document={},devicelistener={onFullRefresh=function() error('listener failure') end}}
assert(refresh(host,true) and calls==3,'failed native refresh did not repaint')
active={document={}}
assert(refresh(host,true) and calls==4,'missing listener did not repaint')
print('HOME_FULL_REFRESH_LIFECYCLE_OK')
