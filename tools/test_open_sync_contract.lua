local f=assert(io.open("miuread.koplugin/main.lua","rb")); local s=f:read("*a"); f:close()
for _,needle in ipairs{
    "[MiuRead][OpenSync] soft timeout; reconciliation continues in background", "OPEN_SYNC_SOFT_TIMEOUT_SECONDS", "LATE_REMOTE_APPLY_WINDOW_SECONDS",
    "_show_position_undo", "_G.__MIUREAD_POSITION_RESOLUTION.decide",
    "self._progress_write_fences", "remote_newer_pending", "remote_exact_unresolved",
    "text_anchor_rescue", "bounded percent fallback", "未覆盖云端",
} do assert(s:find(needle,1,true),needle) end
assert(not s:find("exact_cached_alignment",1,true),"an old cached alignment must not replace fresh Web fetch")
assert(not s:find("progress_write_blocked=true",1,true),"write fence must not be persisted")
assert(not s:find("automatic_check_after_user_interaction",1,true),"user interaction must not force local wins")
assert(not s:find("late_remote_after_user_interaction",1,true),"late interaction must not force local wins")
assert(not s:find('text="使用云端位置"',1,true),"old local/cloud choice must be gone")
assert(not s:find('text="使用本机位置并上传"',1,true),"old local/cloud choice must be gone")
print("open sync contract: PASS")
