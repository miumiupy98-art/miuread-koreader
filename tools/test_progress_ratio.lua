-- percent (0-100) vs ratio (0-1) must not collapse at value==1.
local function normalize_progress_ratio(value)
    value = tonumber(value)
    if not value then return nil end
    if value > 1 then value = value / 100 end
    if value < 0 then return 0 elseif value > 1 then return 1 end
    return value
end

local function percent_to_ratio(value)
    value = tonumber(value)
    if not value then return nil end
    return math.max(0, math.min(1, value / 100))
end

local function native_progress_percent(value)
    local ratio = normalize_progress_ratio(value) or 0
    return math.floor(math.max(0, math.min(1, ratio)) * 100)
end

-- 1% stored as WeRead percent must stay 1%, not become 100%.
assert(percent_to_ratio(1)==0.01,'1 percent must be 1%')
assert(percent_to_ratio(100)==1,'100 percent must be 100%')
assert(percent_to_ratio(50)==0.5,'50 percent must be 50%')
assert(percent_to_ratio(0)==0,'0 percent must be 0%')

-- Ratio inputs remain valid (job.progress_ratio / report_ratio_from_position).
assert(normalize_progress_ratio(0.01)==0.01,'ratio 0.01 must stay 1%')
assert(normalize_progress_ratio(1)==1,'ratio 1 must stay 100%')
assert(normalize_progress_ratio(50)==0.5,'percent-like 50 becomes 50%')

assert(native_progress_percent(0.01)==1,'ratio 0.01 floors to 1%')
assert(native_progress_percent(1)==100,'ratio 1 floors to 100%')
assert(native_progress_percent(50)==50,'percent 50 floors to 50%')
assert(native_progress_percent(1.5)==1,'percent 1.5 floors to 1%')

print('progress ratio: PASS')
