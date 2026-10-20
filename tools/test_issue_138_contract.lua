local script=arg and arg[0] or ""
local root=script:match("^(.*)/tools/[^/]+$") or "."
local function read(path)
    local f=assert(io.open(root.."/"..path,"rb")); local s=f:read("*a"); f:close(); return s
end
local main=read("miuread.koplugin/main.lua")

local function slice(source,a,b)
    local i=assert(source:find(a,1,true),"missing "..a)
    local j=b and source:find(b,i+1,true) or nil
    return source:sub(i,(j and j-1) or #source)
end

-- The issue list only reads annotation DBs; it must not reload the store.
local issues=slice(main,"function Plugin:show_annotation_sync_issues(book_id)","function Plugin:_schedule_home_annotation_summary_refresh")
assert(not issues:find("self.store:reload()",1,true),"annotation issue list still reloads store")

-- Do not report success while the async annotation summary is checking.
local finish=slice(main,"local function finish_all()","local function phase_annotations()")
assert(finish:find("summary.checking==true",1,true),"finish_all lacks checking guard")
assert(finish:find('result_reason="annotation_summary_pending"',1,true),"finish_all lacks pending result")
assert(finish:find('"同步状态待确认"',1,true),"finish_all lacks pending toast")
assert(finish:find('"所有可验证项目均已同步"',1,true),"finish_all lost success toast")
local checking_pos=finish:find("if summary.checking==true then",1,true)
local success_pos=finish:find('"所有可验证项目均已同步"',1,true)
assert(checking_pos and success_pos and checking_pos<success_pos,"success toast is not gated by checking")

-- Per-kind rows must not claim synced while the summary is checking.
local status=slice(main,"function Plugin:show_sync_status(detail)","function Plugin:repair_current_sync()")
assert(status:find("annotation_checking=pending.checking==true",1,true),"sync status ignores checking")
assert(status:find("annotation_text(h_count)",1,true),"highlight row ignores annotation checking")
assert(status:find("annotation_text(t_count)",1,true),"thought row ignores annotation checking")

print("issue 138 contract: PASS")
