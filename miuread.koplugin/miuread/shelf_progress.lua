local M = {}

local function number(value)
    local n = tonumber(value)
    if n and n == n and n ~= math.huge and n ~= -math.huge then return n end
end

function M.percent(value)
    local n = number(value)
    if not n then return nil end
    -- Shelf and getProgress fields are percentages, including values below 1%.
    return math.max(0, math.min(100, n))
end

function M.timestamp(value)
    local n = number(value) or 0
    if n > 100000000000 then n = math.floor(n / 1000) end
    return n
end

function M.finished_flag(row)
    if type(row) ~= "table" then return nil end
    local value = row.finishReading
    if value == nil then value = row.finished end
    if value == nil then return nil end
    return value == true or tonumber(value) == 1 or value == "true"
end

function M.is_finished(row)
    if row.finished_pending ~= nil then return row.finished_pending == true end
    if row.cloud_finished ~= nil then return row.cloud_finished == true end
    return row.finished == true or row.resolved_finished == true or (number(row.progress) or 0) >= 100
end

function M.display(row, session, resolution)
    session = type(session) == "table" and session or {}
    local verified = number(session.progress_verified_sequence) or 0
    local epoch = number(session.progress_epoch) or 1
    local pending = false
    local pending_percent
    for _, key in ipairs({"pending_progress", "pending_progress_coordinate"}) do
        local snapshot = session[key]
        if type(snapshot) == "table"
            and (number(snapshot.progress_epoch) or epoch) == epoch
            and ((number(snapshot.progress_sequence) or 0) == 0 or (number(snapshot.progress_sequence) or 0) > verified) then
            pending = true
            pending_percent = number(snapshot.progress) or number(snapshot.percent) or pending_percent
        end
    end
    -- Sequence counters survive resets and remote-position selection. Only a
    -- current pending snapshot represents an outstanding local write.
    local snapshot = type(session.local_position_snapshot) == "table" and session.local_position_snapshot or {}
    local local_percent = pending_percent or number(session.progress_local_percent)
        or (snapshot.safe == true and number(snapshot.progress) or nil) or number(session.verified_local_percent)
    local cloud = number(row.cloud_progress)
    local resolver = rawget(_G, "__MIUREAD_POSITION_RESOLUTION")
    if resolver and type(resolver.decide) == "function" then
        local state = type(session.position_state) == "table" and session.position_state or {}
        local local_position = type(state.local_position) == "table" and state.local_position or snapshot
        local remote_position = {}
        for key, value in pairs(type(state.remote_position) == "table" and state.remote_position or {}) do
            remote_position[key] = value
        end
        local remote_percent = cloud or number(row.remote_progress) or number(remote_position.progress)
        local remote_at = math.max(number(row.progress_updated_at) or 0, number(row.cloudUpdatedAt) or 0,
            number(row.readUpdateTime) or 0, number(remote_position.updated_at or remote_position.updated) or 0)
        remote_position.progress, remote_position.updated_at = remote_percent, remote_at
        resolution = resolution or resolver.decide{
            local_position = local_position, remote_position = remote_position,
            verified_anchor = resolver.trusted_verified_anchor(session, state),
            local_seq = number(session.progress_latest_sequence) or 0, verified_seq = verified,
            local_updated_at = number(local_position.updated_at) or 0, remote_updated_at = remote_at,
        }
        local exact_percent = number(session.progress_local_percent) or number(local_position.progress)
            or number(session.verified_local_percent)
        local display_percent = number(session.local_display_progress)
        local display_at = number(session.local_display_progress_at) or 0
        local value, source
        if display_percent and display_at > 0 and display_at >= remote_at then
            value, source = display_percent, "local_display"
        elseif resolution.winner == "local" and exact_percent then
            value, source = exact_percent, "local_exact"
        elseif remote_percent then
            value, source = remote_percent, "remote"
        elseif exact_percent then
            value, source = exact_percent, "local_exact"
        end
        row.progress = value and math.max(0, math.min(100, value)) or nil
        row.progress_known = row.progress ~= nil
        row.display_progress_source = source or "unknown"
        row.resolved_position_source = resolution.winner
    elseif local_percent and (pending or cloud == nil) then
        row.progress = math.max(0, math.min(100, local_percent))
    elseif cloud ~= nil then
        row.progress = cloud
    end
    row.finished = nil
    row.finished = M.is_finished(row)
    return row
end

function M.verification_key(session)
    session = type(session) == "table" and session or {}
    return table.concat({tostring(session.progress_epoch or 1),
        tostring(session.progress_verified_sequence or 0), tostring(session.verified_at or 0),
        tostring(session.progress_upload_verified_at or 0)}, ":")
end

local CHILDREN = {"book", "data", "result", "reader", "progressInfo", "bookProgress", "payload", "books", "bookList", "progresses"}

function M.parse(data, book_id)
    local queue, seen, index = {data}, {}, 1
    while index <= #queue and index <= 32 do
        local node = queue[index]
        index = index + 1
        if type(node) == "table" and not seen[node] then
            seen[node] = true
            local id = node.bookId or node.book_id
            -- Reject a different book, including its nested payload.
            if id == nil or tostring(id) == tostring(book_id) then
                local percent = M.percent(node.progress or node.readingProgress or node.progressPercent or node.bookProgress)
                if percent ~= nil then
                    return {percent = percent, updated_at = M.timestamp(node.updateTime or node.updatedAt or node.readUpdateTime)}
                end
                for _, key in ipairs(CHILDREN) do
                    if type(node[key]) == "table" and #queue < 32 then queue[#queue + 1] = node[key] end
                end
                for i = 1, math.min(#node, 20) do
                    if type(node[i]) == "table" and #queue < 32 then queue[#queue + 1] = node[i] end
                end
            end
        end
    end
end

function M.fetch(api, book_id)
    local options = {retries = 0, timeout = {3, 5}, no_auth_recovery = true}
    -- These are presentation reads only: no chapter downloads or session writes.
    for _, method in ipairs({"web_progress", "progress"}) do
        if type(api[method]) == "function" then
            local ok, data = pcall(api[method], api, book_id, options)
            local parsed = ok and M.parse(data, book_id) or nil
            if parsed then return parsed end
        end
    end
end

return M
