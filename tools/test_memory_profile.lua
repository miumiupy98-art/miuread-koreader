-- MemTotal-scaled heavy-guard profile contract (small-memory download fix).
-- Mirrors tools/verify_memory_profile.py for environments with a Lua runtime.
-- Small-RAM devices (a 256 MiB KPW2) could never present the absolute 96/72
-- MiB free the old thresholds demanded, so thresholds are now
-- clamp(MemTotal * ratio, floor, cap) with the historical absolutes as caps.
local script=arg and arg[0] or ""
local root=script:match("^(.*)/tools/[^/]+$") or "."
local function read(path)
    local f=assert(io.open(root.."/"..path,"rb")); local s=f:read("*a"); f:close(); return s
end
local config=read("miuread.koplugin/miuread/config.lua")
local runtime_pressure=read("miuread.koplugin/miuread/runtime_pressure.lua")
local download_task=read("miuread.koplugin/miuread/download_task.lua")
local main_lua=read("miuread.koplugin/main.lua")

local function config_number(key)
    local raw=config:match("\n%s*"..key.."%s*=%s*([%d][%d%.%*%s]-),")
    if not raw then return nil end
    local loader=(loadstring or load)("return "..raw)
    if not loader then return nil end
    local ok,value=pcall(loader)
    if not ok then return nil end
    return value
end

local SPECS={
    start_min={"HEAVY_DOWNLOAD_START_RATIO","HEAVY_DOWNLOAD_START_FLOOR_KB","HEAVY_DOWNLOAD_START_MIN_KB",96*1024},
    resume_min={"HEAVY_DOWNLOAD_RESUME_RATIO","HEAVY_DOWNLOAD_RESUME_FLOOR_KB","HEAVY_DOWNLOAD_RESUME_MIN_KB",96*1024},
    running_min={"HEAVY_DOWNLOAD_RUNNING_RATIO","HEAVY_DOWNLOAD_RUNNING_FLOOR_KB","HEAVY_DOWNLOAD_RUNNING_MIN_KB",72*1024},
    native_hibernate={"HEAVY_NATIVE_HIBERNATE_RATIO","HEAVY_NATIVE_HIBERNATE_FLOOR_KB","HEAVY_NATIVE_HIBERNATE_KB",96*1024},
    native_critical={"HEAVY_NATIVE_CRITICAL_RATIO","HEAVY_NATIVE_CRITICAL_FLOOR_KB","HEAVY_NATIVE_CRITICAL_KB",64*1024},
    cover_coexist={"DOWNLOAD_COEXIST_RATIO","DOWNLOAD_COEXIST_FLOOR_KB","DOWNLOAD_COVER_COEXIST_MIN_KB",80*1024},
    typography_hibernate={"TYPOGRAPHY_HIBERNATE_RATIO","TYPOGRAPHY_HIBERNATE_FLOOR_KB","TYPOGRAPHY_HIBERNATE_MEMORY_KB",72*1024},
    typography_critical={"TYPOGRAPHY_CRITICAL_RATIO","TYPOGRAPHY_CRITICAL_FLOOR_KB","TYPOGRAPHY_CRITICAL_MEMORY_KB",48*1024},
    soft={"BACKGROUND_MEMORY_SOFT_RATIO","BACKGROUND_MEMORY_SOFT_FLOOR_KB","BACKGROUND_MEMORY_SOFT_MAX_KB",128*1024},
    critical={"BACKGROUND_MEMORY_CRITICAL_RATIO","BACKGROUND_MEMORY_CRITICAL_FLOOR_KB","BACKGROUND_MEMORY_CRITICAL_MAX_KB",80*1024},
}
local EXPECTED={
    [256*1024]={start_min=52429,resume_min=49807,running_min=41943,native_hibernate=62915,
        native_critical=36864,cover_coexist=65536,typography_hibernate=52429,typography_critical=32768,
        soft=65536,critical=40960},
    [512*1024]={start_min=98304,resume_min=98304,running_min=73728,native_hibernate=98304,
        native_critical=65536,cover_coexist=81920,typography_hibernate=73728,typography_critical=49152,
        soft=65536,critical=41943},
    [1024*1024]={start_min=98304,resume_min=98304,running_min=73728,native_hibernate=98304,
        native_critical=65536,cover_coexist=81920,typography_hibernate=73728,typography_critical=49152,
        soft=125829,critical=81920},
}

local function clamp(total,ratio,floor,cap)
    if not total then return cap end
    return math.max(floor,math.min(cap,math.floor(total*ratio+.5)))
end

for name,spec in pairs(SPECS) do
    local ratio=config_number(spec[1])
    local floor=config_number(spec[2])
    local cap=config_number(spec[3]) or spec[4]
    assert(ratio and floor and cap,name.." config keys missing")
    assert(cap==spec[4],name.." cap must keep the historical absolute")
    for total,want in pairs(EXPECTED) do
        assert(clamp(total,ratio,floor,cap)==want[name],
            name.."(total="..total..") profile drifted")
    end
    assert(clamp(nil,ratio,floor,cap)==cap,name.." /proc-less fallback must equal the cap")
end

assert(config_number("MEMORY_SMALL_TIER_TOTAL_KB"),"small-tier boundary missing")
assert(config_number("DOWNLOAD_WORKER_OOM_SCORE_ADJ"),"worker oom_score_adj missing")
assert(config_number("DOWNLOAD_PARENT_OOM_SCORE_ADJ")~=nil,"parent oom_score_adj missing")
assert(config_number("DOWNLOAD_IDLE_PUMP_SECONDS"),"idle pump interval missing")
assert(config_number("DOWNLOAD_FUSE_COOLDOWN_SECONDS"),"fuse cooldown missing")
assert(config_number("DOWNLOAD_RESTART_BUDGET_RESET_SECONDS"),"restart budget reset missing")
assert(config_number("DOWNLOAD_MEMORY_HIBERNATE_MIN_PARK_SECONDS"),"memory-pressure min park missing")
assert(not config:find("BACKGROUND_MEMORY_SOFT_KB",1,true),"old fixed soft floor still present")
assert(not config:find("BACKGROUND_MEMORY_CRITICAL_KB",1,true),"old fixed critical floor still present")

assert(runtime_pressure:find("function RuntimePressure.compute_thresholds",1,true),"compute_thresholds missing")
assert(runtime_pressure:find("function RuntimePressure.total_kb",1,true),"total_kb missing")
assert(runtime_pressure:find("function RuntimePressure.tier",1,true),"tier missing")
assert(runtime_pressure:find("local thresholds=RuntimePressure.thresholds()",1,true),"memory_snapshot not using scaled levels")

-- download_task consumes the admission module; absolute keys survive only as caps.
assert(download_task:find("DownloadAdmission.check(memory,Config,from_checkpoint)",1,true),"start admission missing checkpoint flag")
assert(download_task:find("DownloadAdmission.check(memory,Config,true)",1,true),"resume admission missing checkpoint flag")
assert(download_task:find("RuntimePressure.thresholds().running_min",1,true),"running guard not scaled")
assert(download_task:find("RuntimePressure.thresholds().native_hibernate",1,true),"heavy watch native line not scaled")
assert(not download_task:find("Config.HEAVY_DOWNLOAD_START_MIN_KB",1,true),"start gate still uses the absolute key")
assert(download_task:find('err=="low_memory"',1,true),"machine-readable low_memory mapping missing")
local admission=assert(io.open(root.."/miuread.koplugin/miuread/download_admission.lua","rb")):read("*a")
assert(admission:find('pcall(require, "miuread.runtime_pressure")',1,true),"admission not wired to the scaled profile")
assert(admission:find("thresholds.resume_min",1,true),"admission checkpoint line missing")
assert(admission:find("thresholds.start_min",1,true),"admission fresh line missing")
assert(download_task:find("_from_checkpoint=true"),"checkpoint restart flag not wired")
assert(download_task:find("_park_after_restart_fuse"),"restart-fuse parking missing")
assert(download_task:find('reason="restart_fuse"'),"restart-fuse reason missing")
assert(download_task:find("DOWNLOAD_FUSE_COOLDOWN_SECONDS"),"fuse cooldown not applied")
assert(download_task:find(',"low_memory"',1,true),"machine-readable low_memory error code missing")
assert(download_task:find("/proc/self/oom_score_adj",1,true),"worker oom_score_adj write missing")

assert(main_lua:find("thresholds().cover_coexist",1,true),"cover coexist gate not scaled")
assert(main_lua:find("thresholds().native_critical",1,true),"native critical line not scaled")
assert(main_lua:find("native_thresholds.native_hibernate"),"native hibernate line not scaled")
assert(main_lua:find("function Plugin:_download_idle_pump_ensure"),"idle pump missing")
assert(main_lua:find("function Plugin:_download_idle_pump_stop"),"idle pump stop missing")
assert(main_lua:find("idle memory window"),"idle pump window log missing")
assert(main_lua:find("[MiuRead][MemoryProfile]",1,true),"memory profile telemetry missing")
assert(download_task:find("first_effective_progress_at"),"progress-earned restart budget missing")
assert(download_task:find("restart budget reset"),"restart budget reset log missing")
assert(main_lua:find("exit_forced_stop"),"forced-stop exit must park as hibernated")

assert(main_lua:find("thresholds().typography_critical",1,true),"typography critical line not scaled")
assert(main_lua:find("thresholds().typography_hibernate",1,true),"typography hibernate line not scaled")
local downloader=assert(io.open(root.."/miuread.koplugin/miuread/downloader.lua","rb")):read("*a")
assert(downloader:find("package aborted by hibernate marker",1,true),"package hibernate-marker guard missing")
assert(downloader:find("package aborted for memory",1,true),"package memory-floor guard missing")
assert(downloader:find("__MIUREAD_HIBERNATE__:package",1,true),"package abort sentinel missing")
assert(download_task:find("排版重整需要内存",1,true),"typography hibernate message not differentiated")
print("memory profile contract: PASS")
