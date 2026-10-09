-- Journal file names in Logseq's `:journal/file-name-format` syntax (yyyy, MM, dd).
local M = {}

M.LOGSEQ_DEFAULT = "yyyy_MM_dd"
-- formats also recognised when reading, so journals written under another setting still index
M.KNOWN = { "yyyy_MM_dd", "yyyy-MM-dd", "yyyyMMdd", "yyyy.MM.dd" }

local TOKENS = { yyyy = { "%Y", "(%d%d%d%d)", "y" }, MM = { "%m", "(%d%d)", "m" }, dd = { "%d", "(%d%d)", "d" } }

local cache = {}

local function compile(fmt)
  if cache[fmt] then
    return cache[fmt]
  end
  local strf, pat, order = "", "^", {}
  local i = 1
  while i <= #fmt do
    local tok
    for _, t in ipairs({ "yyyy", "MM", "dd" }) do
      if fmt:sub(i, i + #t - 1) == t then
        tok = t
        break
      end
    end
    if tok then
      strf = strf .. TOKENS[tok][1]
      pat = pat .. TOKENS[tok][2]
      order[#order + 1] = TOKENS[tok][3]
      i = i + #tok
    else
      local c = fmt:sub(i, i)
      if c:match("%a") then
        return nil, ("unsupported token at '%s' (supported: yyyy, MM, dd)"):format(fmt:sub(i))
      end
      strf = strf .. (c == "%" and "%%" or c)
      pat = pat .. vim.pesc(c)
      i = i + 1
    end
  end
  local seen = {}
  for _, k in ipairs(order) do
    seen[k] = true
  end
  if not (seen.y and seen.m and seen.d) or #order ~= 3 then
    return nil, "format must contain yyyy, MM and dd exactly once"
  end
  if fmt:find("/", 1, true) then
    return nil, "'/' would put journals in sub-folders; not supported"
  end
  cache[fmt] = { strf = strf, pat = pat .. "$", order = order }
  return cache[fmt]
end

function M.validate(fmt)
  local c, err = compile(fmt)
  return c ~= nil, err
end

--- time (os.time) -> file stem
function M.format(fmt, time)
  return os.date(assert(compile(fmt)).strf, time)
end

--- file stem -> "YYYYMMDD" sort key, or nil
function M.parse(fmt, stem)
  local c = compile(fmt)
  if not c then
    return nil
  end
  local caps = { stem:match(c.pat) }
  if #caps ~= 3 then
    return nil
  end
  local v = {}
  for i, k in ipairs(c.order) do
    v[k] = caps[i]
  end
  local m, d = tonumber(v.m), tonumber(v.d)
  if m < 1 or m > 12 or d < 1 or d > 31 then
    return nil
  end
  return v.y .. v.m .. v.d
end

--- Try the configured format first, then the other well-known ones.
function M.parse_any(fmt, stem)
  local key = M.parse(fmt, stem)
  if key then
    return key
  end
  for _, f in ipairs(M.KNOWN) do
    key = M.parse(f, stem)
    if key then
      return key
    end
  end
end

-- task dates: `DEADLINE: <2026-10-15 Thu>` ------------------------------------------------

-- Logseq always writes English day names, whatever the locale
local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function noon(t)
  return os.time({ year = t.year, month = t.month, day = t.day, hour = 12 })
end

--- time -> `<2026-10-15 Thu>`
function M.stamp(time)
  local t = os.date("*t", time)
  return ("<%04d-%02d-%02d %s>"):format(t.year, t.month, t.day, WEEKDAYS[t.wday])
end

--- `<2026-10-15 Thu>` (a time or repeater after the day is tolerated) -> "YYYYMMDD", or nil
function M.parse_stamp(text)
  local y, m, d = text:match("<(%d%d%d%d)%-(%d%d)%-(%d%d)[^>]*>")
  return y and (y .. m .. d) or nil
end

--- "YYYYMMDD" -> time (noon of that day)
function M.key_time(key)
  return os.time({ year = tonumber(key:sub(1, 4)), month = tonumber(key:sub(5, 6)), day = tonumber(key:sub(7, 8)), hour = 12 })
end

--- whole days from `now` to the day `key` (negative: in the past)
function M.days_until(key, now)
  local today = noon(os.date("*t", now or os.time()))
  return math.floor((M.key_time(key) - today) / 86400 + 0.5)
end

--- What a person types for a date -> time. Accepts `2026-10-15`, `today`, `tomorrow`,
--- a day name (`fri`: the next one), `+3d`, `+2w`. Returns nil and a message otherwise.
function M.parse_input(text, now)
  local t = os.date("*t", now or os.time())
  local s = vim.trim(text):lower()
  local function plus(days)
    return os.time({ year = t.year, month = t.month, day = t.day + days, hour = 12 })
  end
  if s == "today" then
    return plus(0)
  elseif s == "tomorrow" then
    return plus(1)
  end
  local n, unit = s:match("^%+(%d+)([dw])$")
  if n then
    return plus(tonumber(n) * (unit == "w" and 7 or 1))
  end
  local y, m, d = s:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
  if y then
    local time = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
    local back = os.date("*t", time)
    if back.month ~= tonumber(m) or back.day ~= tonumber(d) then
      return nil, "No such date: " .. text
    end
    return time
  end
  if #s >= 3 then
    for i, name in ipairs({ "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" }) do
      if name:sub(1, #s) == s then
        local ahead = (i - t.wday) % 7
        return plus(ahead == 0 and 7 or ahead)
      end
    end
  end
  return nil, "Use 2026-10-15, today, tomorrow, a day name, +3d or +2w"
end

--- Most common known format among the files of a journals directory.
function M.detect(dir)
  local counts, best, best_n = {}, nil, 0
  local handle = vim.uv.fs_scandir(dir)
  while handle do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local stem = name:match("^(.*)%.md$")
    if stem then
      for _, f in ipairs(M.KNOWN) do
        if M.parse(f, stem) then
          counts[f] = (counts[f] or 0) + 1
          if counts[f] > best_n then
            best, best_n = f, counts[f]
          end
          break
        end
      end
    end
  end
  return best
end

return M
