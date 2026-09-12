require('setupkoenv')
local candidate=arg[1] or 'plugins/miuread.koplugin'
package.path=candidate..'/?.lua;plugins/miuread.koplugin/?.lua;'..package.path
local real_os_time=os.time
local now=1000
os.time=function() return now end
local resets,reports,statuses={},{},{}
local job={generation=1,book_id='test',core_map_hash='map',record_generation=1,book_path='test.epub',reading_time_session_id='session',reading_time_segment_id='one',interval=60,first_delay=15,time_only=true,book={},auth={}}
local control={generation=1,book_id='test',core_map_hash='map',record_generation=1,active=true,time_only=true,last_activity=1000}
local files={job=job,control=control}
local function copy(v) if type(v)~='table' then return v end local r={} for k,w in pairs(v) do r[k]=copy(w) end return r end
package.loaded['miuread.json']={decode=function(v) return copy(v) end,encode=function(v) return copy(v) end}
package.loaded['miuread.util']={copy=copy,read_file=function(p) return files[p] end,atomic_write=function(p,v) files[p]=copy(v);if p=='status' then statuses[#statuses+1]=copy(v) end return true end,file_exists=function() return now>5200 end}
package.loaded['miuread.subprocess_hygiene']={reset_resolver=function() resets[#resets+1]=now;return true end}
package.loaded['miuread.legacy_adapter_worker']={run=function(v)
 reports[#reports+1]={at=now,elapsed=v.elapsed_seconds}
 if #reports==1 then return {accepted=false,error_kind='transport',error='network timeout'} end
 if #reports==2 then error('connection timeout') end
 return {accepted=true}
end}
package.loaded.socket={sleep=function()
 now=now+1
 if now==1008 then job=copy(job);job.generation=2;files.job=job;control.generation=2 end
 if now==1250 then control.active=false end
 if now==1300 then now=4900 end -- one hour asleep
 if now==5000 then job=copy(job);job.generation=3;job.reading_time_segment_id='two';files.job=job;control.generation=3;control.active=true;control.last_activity=now end
end}
local Service=require('miuread.read_report_service')
assert(Service.run{job_path='job',control_path='control',status_path='status',context_path='context',stop_path='stop'})
assert(resets[1]==1000 and resets[2]==1015,'metadata refresh must preserve first report clock')
assert(reports[1].at==1015 and reports[1].elapsed==15)
assert(reports[2].at>=1075,'transport must keep retry backoff')
assert(resets[3]==reports[2].at,'raised transport failures reset too')
assert(resets[4]==5000 and #resets==4,'one reset at resume, none for successful periodic reports')
local resumed=false
for _,r in ipairs(reports) do
 assert(r.elapsed<=60,'no accumulated/suspended-time replay')
 assert(not(r.at>=1250 and r.at<5000),'must not report while suspended')
 if r.at==5015 then assert(r.elapsed==15);resumed=true end
end
assert(resumed)
os.time=real_os_time
print('SERVICE_CLOCK_RETRY_SUSPEND_OK',#reports,'reports',#resets,'resets')
