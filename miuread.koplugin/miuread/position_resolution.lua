-- 5.9.0: deterministic latest-wins resolution for local/cloud reading positions.
-- Progress magnitude never determines freshness. Percent is presentation/navigation only.
local M = {}

local function number(v, fallback)
    v=tonumber(v)
    if v==nil then return fallback end
    return v
end

local function uid(p)
    p=type(p)=="table" and p or {}
    return tostring(p.chapter_uid or p.chapterUid or "")
end

local function offset(p)
    p=type(p)=="table" and p or {}
    return tonumber(p.canonical_offset or p.chapter_offset or p.offset or p.chapterOffset)
end

local function basis(p)
    p=type(p)=="table" and p or {}
    return tostring(p.offset_basis or p.position_basis or "")
end

local function tolerance(a,b)
    local ba,bb=basis(a),basis(b)
    if ba=="wr_data_co" or bb=="wr_data_co" or ba=="native_wr_data_co" or bb=="native_wr_data_co" then
        return 16
    end
    return 12
end

function M.same_position(a,b)
    local au,bu=uid(a),uid(b)
    local ao,bo=offset(a),offset(b)
    if au=="" or bu=="" or ao==nil or bo==nil or au~=bu then return false end
    return math.abs(ao-bo)<=tolerance(a,b)
end

local function anchor_position(anchor)
    anchor=type(anchor)=="table" and anchor or {}
    if tostring(anchor.chapter_uid or "")=="" or tonumber(anchor.chapter_offset)==nil then return nil end
    return {
        chapter_uid=anchor.chapter_uid,
        chapter_offset=anchor.chapter_offset,
        offset_basis=anchor.offset_basis or anchor.position_basis,
    }
end

local function changed_from_anchor(position, anchor)
    local ap=anchor_position(anchor)
    if not ap then return nil end
    return not M.same_position(position,ap)
end

-- input:
-- local_position, remote_position, verified_anchor,
-- local_seq, verified_seq, local_updated_at, remote_updated_at,
-- clock_skew_grace (seconds, default 30)
function M.decide(input)
    input=type(input)=="table" and input or {}
    local lp=type(input.local_position)=="table" and input.local_position or nil
    local rp=type(input.remote_position)=="table" and input.remote_position or nil
    if not lp and rp then return {winner="remote",reason="local_missing"} end
    if lp and not rp then return {winner="local",reason="remote_missing"} end
    if not lp and not rp then return {winner="local",reason="positions_missing"} end
    if M.same_position(lp,rp) then return {winner="aligned",reason="exact_position_equal"} end

    local local_seq=number(input.local_seq,0) or 0
    local verified_seq=number(input.verified_seq,0) or 0
    local seq_local_changed=local_seq>verified_seq
    local local_anchor_changed=changed_from_anchor(lp,input.verified_anchor)
    local remote_anchor_changed=changed_from_anchor(rp,input.verified_anchor)
    local local_changed=seq_local_changed or local_anchor_changed==true
    local remote_changed=remote_anchor_changed==true

    -- Verified common anchor is stronger than a server write timestamp.
    -- A Web report can update the server clock without a human page turn.
    if local_changed and remote_anchor_changed==false then
        return {winner="local",reason=seq_local_changed and "local_sequence_after_anchor" or "local_changed_after_anchor"}
    end
    if remote_changed and local_anchor_changed==false and not seq_local_changed then
        return {winner="remote",reason="remote_changed_after_anchor"}
    end

    local lt=number(input.local_updated_at,0) or 0
    local rt=number(input.remote_updated_at,0) or 0
    if lt>0 and rt>0 and lt~=rt then
        if lt>rt then return {winner="local",reason="local_newer_read_event",delta=lt-rt} end
        return {winner="remote",reason="remote_newer_read_event",delta=rt-lt}
    end
    if lt>0 and rt<=0 then return {winner="local",reason="local_timestamp_only"} end
    if rt>0 and lt<=0 then
        if seq_local_changed then return {winner="local",reason="durable_unsent_local_event"} end
        return {winner="remote",reason="remote_timestamp_only"}
    end
    if seq_local_changed then
        return {winner="local",reason="local_unsent_sequence_tiebreak"}
    end
    -- Identical or unknown times without a new local event: retain cloud
    -- authority on genuine reopen. No ambiguous-clock conflict dialog.
    return {winner="remote",reason=(lt>0 and rt>0) and "remote_equal_time_tiebreak" or "initial_cloud_authority"}

end


-- Keep a previously observed cloud position when a delayed response is
-- provably older by server timestamp. This only resolves out-of-order
-- observations; timestamp-less responses are never rejected here because
-- their freshness cannot be proven.
function M.prefer_nonstale_remote(incoming, stored, clock_skew_grace)
    incoming=type(incoming)=="table" and incoming or nil
    stored=type(stored)=="table" and stored or nil
    if not incoming then return stored,"incoming_missing" end
    if not stored then return incoming,"stored_missing" end
    if M.same_position(incoming,stored) then return incoming,"same_position" end
    local it=number(incoming.updated_at or incoming.updated,0) or 0
    local st=number(stored.updated_at or stored.updated,0) or 0
    if it>0 and st>0 and st>it then
        return stored,"stored_remote_newer"
    end
    return incoming,"incoming_not_proven_stale"
end


local POSITION_SNAPSHOT_FIELDS = {
    "progress","percent","raw_progress","raw_percent","protocol_progress","display_progress",
    "chapter_uid","chapterUid","chapter_idx","chapter_index","chapterIdx",
    "canonical_offset","chapter_offset","offset","chapterOffset","offset_basis","position_basis",
    "native_offset","chapter_word_count","total_word_count","words_before","chapter_percent","chapter_ratio",
    "summary","safe","precise","standalone","source","selection_reason","conflict",
    "updated_at","updated","fetched_at","captured_at","submitted_at","server_updated","saved_at",
    "progress_sequence","progress_epoch","display_progress_quality","display_catalog_source","display_page_token",
    "precision_ms","precision_anchor","precision_anchor_chars","precision_chapter_chars","precision_cache_hit",
    "inverse_chapter_uid","inverse_chapter_offset","mapping_error","pending_reason","coordinate_captured_at",
}

-- Durable position state must remain scalar-only. Runtime remote-progress objects
-- may contain a diagnostic `sources` graph where sources.web points back to the
-- selected remote table itself. Persisting that graph creates cycles and can make
-- Store's deep merge recurse until LuaJIT overflows the stack.
function M.snapshot(value)
    if type(value)~="table" then return nil end
    local out={}
    for _,key in ipairs(POSITION_SNAPSHOT_FIELDS) do
        local item=rawget(value,key)
        local kind=type(item)
        if kind=="string" or kind=="number" or kind=="boolean" then out[key]=item end
    end
    return out
end

local function scalar_table(value, fields)
    if type(value)~="table" then return nil end
    local out={}
    for _,key in ipairs(fields) do
        local item=rawget(value,key)
        local kind=type(item)
        if kind=="string" or kind=="number" or kind=="boolean" then out[key]=item end
    end
    return next(out) and out or nil
end

function M.state_snapshot(state)
    state=type(state)=="table" and state or {}
    local out={version=tonumber(rawget(state,"version")) or 1}
    out.local_position=M.snapshot(rawget(state,"local_position"))
    out.remote_position=M.snapshot(rawget(state,"remote_position"))
    out.verified_anchor=M.snapshot(rawget(state,"verified_anchor"))
    out.resolved=scalar_table(rawget(state,"resolved"),{"source","reason","resolved_at"})
    out.finished=scalar_table(rawget(state,"finished"),{"local_finished","remote_finished","resolved_finished","source","resolved_at"})
    return out
end

-- A cloud observation is not a verified common anchor. Trust only a position
-- that has durable verification metadata (or an already-resolved aligned state).
-- This prevents the freshly fetched remote position from being mistaken for the
-- historical common point during first reconciliation.
function M.trusted_verified_anchor(session,state)
    session=type(session)=="table" and session or {}
    state=type(state)=="table" and state or {}
    local uid=tostring(session.verified_chapter_uid or "")
    local co=tonumber(session.verified_chapter_offset)
    if uid~="" and co~=nil then
        local base=M.snapshot(state.verified_anchor) or {}
        base.chapter_uid=uid
        base.chapter_offset=co
        base.canonical_offset=co
        base.offset=co
        base.progress=tonumber(base.progress or session.verified_local_percent or session.verified_remote_percent)
        return base
    end
    local resolved=type(state.resolved)=="table" and state.resolved or {}
    local anchor=M.snapshot(state.verified_anchor)
    if anchor and tostring(anchor.chapter_uid or "")~=""
        and tonumber(anchor.chapter_offset or anchor.canonical_offset or anchor.offset)~=nil
        and (session.remote_verified==true or (tonumber(session.verified_at or 0) or 0)>0
            or (tostring(resolved.source or "")=="aligned" and (tonumber(resolved.resolved_at or 0) or 0)>0)) then
        return anchor
    end
    return nil
end

function M.resolved_finished(winner, local_finished, remote_finished)
    -- beta.5: terminal completion is an explicit, independently verified state.
    -- A whole-book percent (especially server raw 100) cannot create it.
    if winner=="remote" then return remote_finished==true end
    if winner=="aligned" then return local_finished==true or remote_finished==true end
    return local_finished==true
end

return M
