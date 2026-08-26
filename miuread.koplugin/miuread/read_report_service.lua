local Json = require("miuread.json")
local U = require("miuread.util")
local Adapter = require("miuread.legacy_adapter_worker")
local Config = require("miuread.config")

local Service = {}

local MIN_FINAL_SECONDS = 10

local function sleep(seconds)
    local ok, socket = pcall(require, "socket")
    if ok and socket and type(socket.sleep) == "function" then
        socket.sleep(seconds)
        return
    end
    os.execute("sleep " .. tostring(math.max(1, math.floor(seconds or 1))))
end

local function process_helpers()
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil end
    pcall(function()
        ffi.cdef[[
            int getpid(void);
            int setpriority(int which, int who, int prio);
            int kill(int pid, int sig);
        ]]
    end)
    return ffi
end

local ffi = process_helpers()

local function lower_priority()
    if not ffi then return end
    pcall(function() ffi.C.setpriority(0, ffi.C.getpid(), 19) end)
end

local function own_pid()
    if not ffi then return nil end
    local ok, pid = pcall(function() return tonumber(ffi.C.getpid()) end)
    return ok and pid or nil
end

local function remove_lock_dir(path)
    if not path then return end
    local ok, lfs = pcall(require, "lfs")
    if ok and lfs and type(lfs.rmdir) == "function" then pcall(lfs.rmdir, path) end
end

local function parent_alive(pid)
    pid = tonumber(pid)
    if not pid or pid <= 1 or not ffi then return true end
    local ok, result = pcall(function() return ffi.C.kill(pid, 0) end)
    return not ok or result == 0
end

local function read_json(path)
    local raw = U.read_file(path, true)
    if not raw then return nil end
    local ok, value = pcall(Json.decode, raw)
    if ok and type(value) == "table" then return value end
end

local function write_status(path, value)
    value = value or {}
    value.written_at = os.time()
    return U.atomic_write(path, Json.encode(value), true)
end

local function classify_error(kind,value)
    kind=tostring(kind or "")
    local text=tostring(value or ""):lower()
    if kind=="authentication" or kind=="context" or kind=="transport" or kind=="server" then
        return kind
    end
    if text:find("login",1,true) or text:find("authentication",1,true)
        or text:find("登录",1,true) or text:find("用户不存在",1,true) then
        return "authentication"
    end
    if text:find("context",1,true) or text:find("chapter",1,true)
        or text:find("章节",1,true) then return "context" end
    if text:find("network",1,true) or text:find("timeout",1,true)
        or text:find("connection",1,true) then return "transport" end
    return "server"
end

local function retry_delay(kind,failures,interval)
    failures=math.min(10,math.max(1,tonumber(failures) or 1))
    interval=math.max(10,tonumber(interval) or tonumber(Config.READ_INTERVAL) or 60)
    local function configured(values,fallback)
        values=type(values)=="table" and values or {}
        return tonumber(values[math.min(failures,#values)] or values[#values]) or fallback
    end
    if kind=="authentication" then
        return math.min(30*60,configured(Config.READ_REPORT_AUTH_RETRY_DELAYS,120))
    end
    if kind=="context" then
        return math.min(30*60,configured(Config.READ_REPORT_CONTEXT_RETRY_DELAYS,60))
    end
    if kind=="transport" then return math.min(30*60,math.max(interval,tonumber(Config.READ_INTERVAL) or 60)*(2^(failures-1))) end
    if kind=="server" then return math.min(30*60,math.max(120,interval*2)*(2^(failures-1))) end
    return math.max(interval,60)
end

local function public_result(result)
    result = type(result) == "table" and result or {}
    return {
        accepted = result.accepted == true,
        uncertain = result.uncertain == true,
        response = result.response or {},
        error = result.error,
        error_kind = result.error_kind,
        path = result.path,
        context_changed = result.context_changed == true,
        position = result.position,
        cookies_changed = result.cookies_changed == true,
        cookies = result.cookies_changed and result.cookies or nil,
        wr_ticket_changed = result.wr_ticket_changed == true,
        wr_ticket = result.wr_ticket_changed and result.wr_ticket or nil,
        wr_wrpa_changed = result.wr_wrpa_changed == true,
        wr_wrpa = result.wr_wrpa_changed and result.wr_wrpa or nil,
        response_summary = result.response_summary,
        attempts = result.attempts,
        payload_public = result.payload_public,
        meta = result.meta,
    }
end

function Service.run(job)
    job = job or {}
    local job_path = assert(job.job_path, "missing job path")
    local control_path = assert(job.control_path, "missing control path")
    local status_path = assert(job.status_path, "missing status path")
    local context_path = assert(job.context_path, "missing context path")
    local stop_path = assert(job.stop_path, "missing stop path")
    local owner_path = job.owner_path
    local lock_path = job.lock_path
    local reader_busy_path = tostring(job.reader_busy_path or "")
    local parent_pid = tonumber(job.parent_pid)
    local poll_interval = math.max(0.5, tonumber(job.poll_interval) or 1)

    lower_priority()

    local generation = 0
    local sequence = 0
    local current_job = nil
    local book = {}
    local auth = {}
    local next_due = 0
    local last_control_state = nil
    local last_report_at = 0
    local last_flush_seq = 0
    local consecutive_failures = 0
    local consecutive_unconfirmed = 0
    local blocked = false
    local carry_remaining = 0
    local progress_fence_seq = 0

    local function reader_busy_until()
        if reader_busy_path == "" then return 0 end
        local raw = U.read_file(reader_busy_path, true)
        return tonumber(raw or 0) or 0
    end

    local function write_service_status(value, source_job)
        value=type(value)=="table" and value or {}
        source_job=type(source_job)=="table" and source_job or current_job or {}
        if value.generation==nil then value.generation=generation end
        if value.controller_token==nil then value.controller_token=tostring(source_job.controller_token or "") end
        if value.login_session_id==nil then value.login_session_id=tostring(source_job.login_session_id or "") end
        if value.auth_revision==nil then value.auth_revision=math.max(0,tonumber(source_job.auth_revision or 0) or 0) end
        if value.account_vid==nil then value.account_vid=tostring(source_job.account_vid or "") end
        if value.book_id==nil then value.book_id=tostring(source_job.book_id or "") end
        if value.core_map_hash==nil then value.core_map_hash=tostring(source_job.core_map_hash or "") end
        if value.record_generation==nil then value.record_generation=tonumber(source_job.record_generation or 0) or 0 end
        return write_status(status_path,value)
    end

    local function write_context()
        if not current_job then return end
        return U.atomic_write(context_path,Json.encode({
            generation=generation,
            controller_token=tostring(current_job.controller_token or ""),
            login_session_id=tostring(current_job.login_session_id or ""),
            auth_revision=math.max(0,tonumber(current_job.auth_revision or 0) or 0),
            account_vid=tostring(current_job.account_vid or ""),
            book_id=tostring(current_job.book_id or ""),
            core_map_hash=tostring(current_job.core_map_hash or ""),
            record_generation=tonumber(current_job.record_generation or 0) or 0,
            context=book,
        }),true)
    end

    local function run_report(control, elapsed, final_flush, reason)
        local interval = math.max(10, tonumber(current_job.interval) or tonumber(Config.READ_INTERVAL) or 60)
        -- The service process may be reused across books, but every reporting
        -- request is bound to one generation, book and immutable core map.
        -- beta.8 automatic interval jobs are time-only. Keep the live control
        -- flag for compatibility with older job files, but never make periodic
        -- reporting depend on foreground position calculation.
        local time_only=current_job.time_only==true or control.time_only==true
        local report_mode=tostring(current_job.report_mode or (time_only and "reading_time_compat" or "progress"))
        if tostring(control.book_id or "")~=tostring(current_job.book_id or "")
            or tostring(control.core_map_hash or "")~=tostring(current_job.core_map_hash or "")
            or tonumber(control.record_generation or -1)~=tonumber(current_job.record_generation or 0)
            or (not time_only and (control.position_safe~=true
                or tostring(control.local_chapter_uid or "")=="")) then
            sequence=sequence+1
            blocked=true
            write_service_status({
                seq=sequence,state="error",accepted=false,error_kind="context",
                error="stale or unsafe book context refused before report",
                paused=true,retry_delay=0,consecutive_failures=consecutive_failures+1,
                attempted_at=os.time(),completed_at=os.time(),elapsed_seconds=0,
                final_flush=final_flush==true,flush_reason=reason,next_due=0,time_only=time_only,
                writer_barrier_seq=tonumber(control.writer_barrier_seq or 0) or 0,
            })
            consecutive_failures=consecutive_failures+1
            return 0
        end
        -- beta.24: never turn suspended/failed history into a later burst. Every
        -- request contains only the fresh interval that led to this attempt and
        -- is capped independently, even if an older service job still contains
        -- a legacy carry value after OTA.
        local maximum=math.max(10,tonumber(Config.READ_REPORT_MAX_ELAPSED_SECONDS) or 60)
        local base_elapsed=math.max(1,math.min(interval,maximum,math.floor(tonumber(elapsed) or interval)))
        local carry_used=0
        elapsed=base_elapsed
        carry_remaining=0
        sequence = sequence + 1
        local report_book=U.copy(book or {})
        report_book.book_id=tostring(current_job.book_id or "")
        report_book.core_map_hash=tostring(current_job.core_map_hash or "")
        if not time_only then
            report_book.local_chapter_uid=control.local_chapter_uid
            report_book.local_chapter_idx=tonumber(control.local_chapter_idx)
            report_book.local_chapter_offset=tonumber(control.local_chapter_offset) or 0
            report_book.local_chapter_word_count=tonumber(control.local_chapter_word_count) or 0
            report_book.local_native_chapter_offset=control.local_native_chapter_offset == true
            report_book.local_chapter_offset_basis=tostring(control.local_chapter_offset_basis or "")
            report_book.progress=(tonumber(control.progress_ratio) or 0)*100
        end
        local report_job = {
            book_id = tostring(current_job.book_id or ""),
            book_title = tostring(current_job.book_title or current_job.book_id or ""),
            book = report_book,
            core_map_hash=tostring(current_job.core_map_hash or ""),
            progress_ratio = time_only and nil or (tonumber(control.progress_ratio) or 0),
            time_only = time_only,
            report_mode = report_mode,
            cloud_anchor = time_only and {
                chapter_uid=control.cloud_anchor_chapter_uid,
                chapter_idx=control.cloud_anchor_chapter_idx,
                chapter_offset=control.cloud_anchor_chapter_offset,
                protocol_progress=control.cloud_anchor_progress,
                raw_progress=control.cloud_anchor_raw_progress,
                source=control.cloud_anchor_source,
            } or nil,
            elapsed_seconds = elapsed,
            cookies = auth.cookies or {},
            api_key = auth.api_key or "",
            wr_ticket = auth.wr_ticket or "",
            wr_wrpa = auth.wr_wrpa or "",
            allow_renewal = false,
            -- Never replay an uncertain interval. After two consecutive missing
            -- confirmations, refresh the current book context while sending the
            -- next fresh interval. This repairs stale report context without
            -- double-counting time that WeRead may already have accepted.
            force_context = consecutive_unconfirmed >= 2,
        }
        local attempted_at = os.time()
        write_service_status({
            generation=generation,seq=sequence,state="reporting",accepted=nil,
            attempted_at=attempted_at,elapsed_seconds=elapsed,final_flush=final_flush==true,
            flush_reason=reason,time_only=time_only,report_mode=report_mode,next_due=0,
            writer_barrier_seq=tonumber(control.writer_barrier_seq or 0) or 0,
        })
        local ok, result = pcall(Adapter.run, report_job)
        local completed_at = os.time()
        -- The elapsed segment ends when the request is dispatched, not when
        -- the HTTP response returns. Reading continues while the request is in
        -- flight, so that network time belongs to the next fresh segment.
        last_report_at = attempted_at

        if ok and type(result) == "table" then
            -- A candidate context only becomes authoritative after WeRead
            -- accepts this exact book/core-map request.
            if result.accepted and not time_only and type(result.legacy_context) == "table"
                and tostring(result.legacy_context.book_id or result.legacy_context.bookId or "")==tostring(current_job.book_id or "")
                and tostring(result.legacy_context.core_map_hash or "")==tostring(current_job.core_map_hash or "") then
                book = U.copy(result.legacy_context)
                if result.context_changed then write_context() end
            end
            if result.cookies_changed and type(result.cookies) == "table" then auth.cookies = U.copy(result.cookies) end
            if result.wr_ticket_changed then auth.wr_ticket = result.wr_ticket or "" end
            if result.wr_wrpa_changed then auth.wr_wrpa = result.wr_wrpa or "" end

            local out = public_result(result)
            out.time_only=time_only
            out.report_mode=report_mode
            out.writer_barrier_seq=tonumber(control.writer_barrier_seq or 0) or 0
            local uncertain = result.uncertain == true or tostring(result.error_kind or "") == "unconfirmed"
            local kind = result.accepted and nil or (uncertain and "unconfirmed" or classify_error(result.error_kind,result.error))
            if result.accepted then
                consecutive_failures = 0
                consecutive_unconfirmed = 0
                blocked = false
            elseif uncertain then
                -- Do not replay this elapsed interval: WeRead may already have
                -- accepted it. Keep the service alive and continue with the
                -- next fresh interval instead of escalating to book repair.
                consecutive_failures = 0
                consecutive_unconfirmed = consecutive_unconfirmed + 1
                blocked = false
            else
                consecutive_failures = consecutive_failures + 1
                consecutive_unconfirmed = 0
                blocked = kind == "authentication"
            end
            out.generation = generation
            out.seq = sequence
            out.state = result.accepted and "waiting" or (uncertain and "unconfirmed" or "error")
            out.uncertain = uncertain or nil
            out.error_kind = kind or result.error_kind
            out.paused = blocked
            local delay = (result.accepted or uncertain) and interval
                or retry_delay(kind, consecutive_failures, interval)
            out.consecutive_failures = consecutive_failures
            out.unconfirmed_count = consecutive_unconfirmed
            out.context_refresh_requested = report_job.force_context == true or nil
            out.attempted_at = attempted_at
            out.completed_at = completed_at
            out.elapsed_seconds = elapsed
            out.carry_elapsed = carry_used
            out.carry_consumed = carry_used > 0
            out.carry_consumed_seconds = carry_used
            out.carry_remaining = carry_remaining
            out.pending_elapsed = carry_remaining
            out.recovery_probe = false
            out.final_flush = final_flush == true
            out.flush_reason = reason
            if not final_flush and carry_remaining>0 and (result.accepted or uncertain) then
                delay=math.min(delay,10)
            end
            out.retry_delay = delay
            if final_flush then
                out.next_due=0
            elseif result.accepted or uncertain then
                -- Keep the 60 s cadence anchored to the segment boundary. A
                -- slow HTTP response must not silently erase several seconds
                -- from every reading interval.
                out.next_due=math.max(completed_at,attempted_at+delay)
            else
                out.next_due=completed_at+delay
            end
            out.book_id = tostring(current_job.book_id or "")
            out.core_map_hash=tostring(current_job.core_map_hash or "")
            out.record_generation=tonumber(current_job.record_generation or 0) or 0
            write_service_status(out)
            return out.next_due
        end

        consecutive_failures = consecutive_failures + 1
        consecutive_unconfirmed = 0
        local kind=classify_error(nil,result)
        blocked = kind == "authentication"
        local delay = retry_delay(kind, consecutive_failures, interval)
        local due = final_flush and 0 or (completed_at + delay)
        write_service_status({
            generation = generation,
            seq = sequence,
            state = "error",
            accepted = false,
            error = tostring(result or "read report service failed"),
            error_kind = kind,
            retry_delay = delay,
            consecutive_failures = consecutive_failures,
            attempted_at = attempted_at,
            completed_at = completed_at,
            elapsed_seconds = elapsed,
            carry_elapsed = carry_used,
            carry_consumed = carry_used > 0,
            carry_consumed_seconds = carry_used,
            carry_remaining = carry_remaining,
            pending_elapsed = carry_remaining,
            recovery_probe = false,
            final_flush = final_flush == true,
            flush_reason = reason,
            report_mode = report_mode,
            next_due = due,
            book_id = tostring(current_job.book_id or ""),
            core_map_hash=tostring(current_job.core_map_hash or ""),
            record_generation=tonumber(current_job.record_generation or 0) or 0,
            writer_barrier_seq=tonumber(control.writer_barrier_seq or 0) or 0,
        })
        return due
    end

    write_service_status({
        generation = 0,
        seq = 0,
        state = "service_waiting",
        started_at = os.time(),
        service_version = tonumber(job.service_version) or 0,
    })

    while true do
        if U.file_exists(stop_path) or not parent_alive(parent_pid) then break end

        local control = read_json(control_path)
        if control and tonumber(control.generation or 0) ~= generation then
            local requested = tonumber(control.generation or 0) or 0
            local loaded = read_json(job_path)
            if loaded and tonumber(loaded.generation or 0) == requested
                and tostring(control.controller_token or "")==tostring(loaded.controller_token or "")
                and tostring(control.login_session_id or "")==tostring(loaded.login_session_id or "")
                and math.max(0,tonumber(control.auth_revision or 0) or 0)==math.max(0,tonumber(loaded.auth_revision or 0) or 0)
                and tostring(control.account_vid or "")==tostring(loaded.account_vid or "")
                and (tostring(loaded.action or "")=="reset_auth" or (
                    tostring(control.book_id or "")==tostring(loaded.book_id or "")
                    and tostring(control.core_map_hash or "")~=""
                    and tostring(control.core_map_hash or "")==tostring(loaded.core_map_hash or "")
                    and tonumber(control.record_generation or -1)==tonumber(loaded.record_generation or 0))) then
                local previous_job=current_job
                local previous_next_due=next_due
                local previous_last_report_at=last_report_at
                local preserve_clock=previous_job~=nil
                    and tostring(loaded.action or "")~="reset_auth"
                    and tostring(loaded.reading_time_session_id or "")~=""
                    and tostring(loaded.reading_time_session_id or "")==tostring(previous_job.reading_time_session_id or "")
                    and tostring(loaded.reading_time_segment_id or "")~=""
                    and tostring(loaded.reading_time_segment_id or "")==tostring(previous_job.reading_time_segment_id or "")
                    and tostring(loaded.book_id or "")==tostring(previous_job.book_id or "")
                    and tostring(loaded.book_path or "")==tostring(previous_job.book_path or "")
                    and tostring(loaded.core_map_hash or "")==tostring(previous_job.core_map_hash or "")
                generation = requested
                current_job = loaded
                last_flush_seq = 0
                last_control_state = nil
                consecutive_failures = 0
                consecutive_unconfirmed = 0
                blocked = false
                if tostring(loaded.action or "")=="reset_auth" then
                    book={}
                    auth={}
                    next_due=0
                    last_report_at=os.time()
                    carry_remaining=0
                    os.remove(context_path)
                    write_service_status({
                        generation=generation,seq=sequence,state="session_reset",next_due=0,
                        service_version=tonumber(job.service_version) or 0,
                    })
                else
                    book = U.copy(loaded.book or {})
                    auth = U.copy(loaded.auth or {})
                    local interval = math.max(10, tonumber(loaded.interval) or tonumber(Config.READ_INTERVAL) or 60)
                    local first_delay = math.max(5, math.min(interval, tonumber(loaded.first_delay) or interval))
                    local now = os.time()
                    carry_remaining=0
                    if preserve_clock then
                        -- Authentication/session metadata can refresh while the
                        -- same reading segment is active. Replace credentials,
                        -- but never restart the 15/60 s clock.
                        last_report_at=previous_last_report_at>0 and previous_last_report_at or now
                        next_due=previous_next_due>0 and previous_next_due or (now+first_delay)
                    else
                        -- A real new reading segment (new book or resume after
                        -- suspend) starts a fresh clock; suspended time is never
                        -- counted or replayed.
                        next_due = now + first_delay
                        last_report_at = now
                    end
                    write_context()
                    write_service_status({
                        generation = generation,
                        seq = sequence,
                        state = "waiting",
                        next_due = next_due,
                        first_delay = first_delay,
                        clock_preserved = preserve_clock or nil,
                        reading_time_session_id=tostring(loaded.reading_time_session_id or ""),
                        reading_time_segment_id=tostring(loaded.reading_time_segment_id or ""),
                        carry_elapsed = 0,
                        carry_consumed = false,
                        carry_remaining = carry_remaining,
                        service_version = tonumber(job.service_version) or 0,
                    })
                end
            end
        end

        if current_job and control and tonumber(control.generation or 0) == generation
            and tostring(control.controller_token or "") == tostring(current_job.controller_token or "")
            and tostring(control.login_session_id or "") == tostring(current_job.login_session_id or "")
            and math.max(0,tonumber(control.auth_revision or 0) or 0)==math.max(0,tonumber(current_job.auth_revision or 0) or 0)
            and tostring(control.account_vid or "") == tostring(current_job.account_vid or "")
            and tostring(control.book_id or "") == tostring(current_job.book_id or "")
            and tostring(control.core_map_hash or "") ~= ""
            and tostring(control.core_map_hash or "") == tostring(current_job.core_map_hash or "")
            and tonumber(control.record_generation or -1) == tonumber(current_job.record_generation or 0)
        then
            local active = control.active == true
            local state_key = active and "active" or "inactive"
            local flush_seq = tonumber(control.flush_seq or 0) or 0
            local pending_flush = flush_seq > last_flush_seq

            if state_key ~= last_control_state then
                last_control_state = state_key
                if not active then
                    next_due = 0
                    if not pending_flush then
                        write_service_status({
                            generation = generation,
                            seq = sequence,
                            state = "inactive",
                            book_id = tostring(current_job.book_id or ""),
                            writer_barrier_seq=tonumber(control.writer_barrier_seq or 0) or 0,
                            writer_barrier_reason=tostring(control.writer_barrier_reason or ""),
                        })
                    end
                elseif next_due <= 0 then
                    local interval = math.max(10, tonumber(current_job.interval) or tonumber(Config.READ_INTERVAL) or 60)
                    local first_delay = math.max(5, math.min(interval, tonumber(current_job.first_delay) or interval))
                    local now = os.time()
                    last_report_at = now
                    next_due = now + first_delay
                end
            end

            local requested_fence_seq=tonumber(control.writer_barrier_seq or 0) or 0
            if control.progress_fence==true then
                -- Progress writes and reading-time writes share /web/book/read.
                -- A fence is acknowledged only after any in-flight report has
                -- returned to this loop, so foreground progress can safely write.
                if progress_fence_seq~=requested_fence_seq then
                    progress_fence_seq=requested_fence_seq
                    write_service_status({
                        generation=generation,seq=sequence,state="progress_fenced",
                        book_id=tostring(current_job.book_id or ""),next_due=next_due,
                        writer_barrier_seq=requested_fence_seq,
                        writer_barrier_reason=tostring(control.writer_barrier_reason or "progress_write_fence"),
                    })
                end
            elseif pending_flush then
                progress_fence_seq=0
                last_flush_seq = flush_seq
                local now = os.time()
                local elapsed
                if control.flush_auto==true then
                    elapsed=math.max(0,now-last_report_at)
                else
                    elapsed=tonumber(control.flush_elapsed) or math.max(0,now-last_report_at)
                end
                elapsed=math.floor(math.max(0,elapsed))
                if elapsed >= MIN_FINAL_SECONDS then
                    next_due = run_report(control, elapsed, true, tostring(control.flush_reason or "stop"))
                else
                    next_due = 0
                    write_service_status({
                        generation = generation,
                        seq = sequence,
                        state = "inactive",
                        accepted = nil,
                        final_flush = true,
                        flush_skipped = true,
                        flush_reason = tostring(control.flush_reason or "stop"),
                        elapsed_seconds = elapsed,
                        book_id = tostring(current_job.book_id or ""),
                        writer_barrier_seq=tonumber(control.writer_barrier_seq or 0) or 0,
                        writer_barrier_reason=tostring(control.writer_barrier_reason or ""),
                    })
                end
            elseif active and not blocked then
                progress_fence_seq=0
                local now = os.time()
                local interval = math.max(10, tonumber(current_job.interval) or tonumber(Config.READ_INTERVAL) or 60)
                local idle_timeout = math.max(interval, tonumber(current_job.idle_timeout) or 600)
                local last_activity = tonumber(control.last_activity) or now
                local idle = now - last_activity

                if now >= next_due then
                    local time_only=current_job.time_only==true or control.time_only==true
                    local busy_until=time_only and 0 or reader_busy_until()
                    if busy_until > now then
                        next_due = math.max(next_due, busy_until + 1)
                    elseif idle <= idle_timeout then
                        local elapsed = math.max(1, now - last_report_at)
                        next_due = run_report(control, elapsed, false, "interval")
                    else
                        next_due = now + interval
                    end
                end
            end
        end

        sleep(poll_interval)
    end

    write_service_status({
        generation = generation,
        seq = sequence,
        state = "service_stopped",
        stopped_at = os.time(),
        service_version = tonumber(job.service_version) or 0,
    })
    if owner_path then
        local owner = read_json(owner_path)
        if not owner or tonumber(owner.pid) == own_pid() then os.remove(owner_path) end
    end
    remove_lock_dir(lock_path)
    return true
end

return Service
