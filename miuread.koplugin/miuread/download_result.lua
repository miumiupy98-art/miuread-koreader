local Result = {}

function Result.failed_chapter(err)
    local line=tostring(err or ""):match("\n•%s*([^\r\n]+)")
    if not line then return nil end
    local separator=line:find("：",1,true)
    if separator then return line:sub(1,separator-1) end
end

function Result.failure_kind(err)
    err=tostring(err or "")
    if err:find("[MiuReadImageMissing]",1,true) or err:find("[MiuReadImageExternal]",1,true)
        or err:find("E-Ink 正文图片未完整获取",1,true) then return "image_missing" end
    if err:find("E-Ink 目录未确认章节免费或已购买",1,true)
        or err:find("E-Ink 书籍没有可离线下载的阅读权益",1,true)
        or err:find("未确认本章离线下载权限",1,true)
        or err:find("未确认本章在线阅读权限",1,true) then return "chapter_access" end
end

function Result.failure_label(state)
    local kind=Result.failure_kind(state.error) or state.error_kind
    if state.auth_required then return "等待登录恢复" end
    if kind=="image_missing" then return "插图加载失败" end
    if kind=="chapter_access" then return "未确认下载权限" end
    if kind=="network" then return "网络中断" end
    if kind=="rate_limit" then return "请求受限" end
    if kind=="validation" then return "文件校验失败" end
    return "下载未完成"
end

function Result.retry_options(state)
    local options=state.options or {}
    local open_after=state.open_after
    if open_after==nil then open_after=options.read_online==true end
    return options,open_after
end

local function annotation_kind(record)
    if type(record) ~= "table" then return "" end
    return tostring(record.annotation_error_kind or ((record.annotation_summary or {}).error_kind) or "")
end

function Result.annotation_unresolved(record)
    if type(record) ~= "table" or record.eink_content_mode or record.annotation_pending ~= true then return false end
    local kind=annotation_kind(record)
    -- These failures are tied to the returned annotation data itself. Retrying
    -- the whole book indefinitely does not make them safer to place.
    return kind=="data" or kind=="forbidden" or kind=="unrecoverable"
end

function Result.annotation_pending(record)
    return type(record) == "table" and not record.eink_content_mode and record.annotation_pending == true
        and not Result.annotation_unresolved(record)
end

function Result.annotation_fallback(record)
    return type(record) == "table" and not record.eink_content_mode and record.annotation_fallback == true
end

function Result.variant_label(label, record)
    return tostring(label or "")
end

function Result.aggregate(records)
    local result={annotation_pending=false,annotation_fallback=false,annotation_unresolved=false}
    for _,record in ipairs(records or {}) do
        if Result.annotation_pending(record) then result.annotation_pending=true end
        if Result.annotation_fallback(record) then result.annotation_fallback=true end
        if Result.annotation_unresolved(record) then result.annotation_unresolved=true end
    end
    return result
end

function Result.state(record, pending_install)
    if pending_install == true then return "pending_install" end
    if Result.annotation_pending(record) then return "annotation_pending" end
    return "completed"
end

function Result.shelf_status(record, pending_install)
    if pending_install == true and record and record.translation_mode then return "译文待应用" end
    if pending_install == true then return "等待关闭后更新" end
    if Result.annotation_pending(record) then return "批注待修复" end
    return "已生成"
end

function Result.notice(title, record, pending_install)
    title = tostring(title or "未命名")
    if pending_install == true and record and record.translation_mode then
        return title .. "译文已就绪，可在翻译设置中应用"
    end
    if pending_install == true then
        return title .. "新版本已下载，关闭当前书籍后更新"
    end
    if Result.annotation_pending(record) then
        return title .. "正文下载完成，划线与想法待修复"
    end
    return title .. "下载完成"
end

function Result.summary_note(record)
    if Result.annotation_pending(record) then
        return "正文已生成；划线与想法暂未完整，可使用检查与修复补全。"
    end
    if Result.annotation_unresolved(record) then
        return "正文与书籍文件完整；少量旧批注无法可靠恢复，已保留现状且不会反复要求修复。"
    end
    return nil
end

return Result
