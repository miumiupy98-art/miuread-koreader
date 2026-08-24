local M = {}

local function inherited_fd_target(ffi, fd)
    local path = "/proc/self/fd/" .. tostring(fd)
    local buffer = ffi.new("char[?]", 512)
    local ok, length = pcall(function()
        return ffi.C.readlink(path, buffer, 511)
    end)
    length = ok and tonumber(length) or nil
    if not length or length <= 0 then return nil end
    return ffi.string(buffer, length)
end

function M.close_inherited_sockets()
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi or not ffi then return false, "ffi_unavailable", 0 end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then return false, "lfs_unavailable", 0 end
    if lfs.attributes("/proc/self/fd", "mode") ~= "directory" then
        return false, "proc_fd_unavailable", 0
    end

    -- Child workers are forked from KOReader. LuaSocket descriptors do not
    -- necessarily carry close-on-exec, so the child may otherwise retain
    -- listeners such as HTTP Inspector :8080 after the parent closes them.
    -- Declare independently: one symbol may already be known to LuaJIT while
    -- the other is not; a combined cdef could otherwise fail as a whole.
    pcall(ffi.cdef, "long readlink(const char *path, char *buf, unsigned long bufsiz);")
    pcall(ffi.cdef, "int close(int fd);")

    local ok_dir, iter, state = pcall(lfs.dir, "/proc/self/fd")
    if not ok_dir or type(iter) ~= "function" then
        return false, "proc_fd_scan_failed", 0
    end

    local descriptors = {}
    for name in iter, state do
        local fd = tonumber(name)
        if fd and fd > 2 then descriptors[#descriptors + 1] = fd end
    end
    table.sort(descriptors)

    local closed = 0
    for _, fd in ipairs(descriptors) do
        local target = inherited_fd_target(ffi, fd)
        if target and target:match("^socket:%[") then
            local ok_close, result = pcall(function() return ffi.C.close(fd) end)
            if ok_close and tonumber(result) == 0 then closed = closed + 1 end
        end
    end
    return true, nil, closed
end

return M
