-- Logseq task keywords drawn as checkbox icons. The file text stays `- TODO ...`.
local M = {}
local ns = vim.api.nvim_create_namespace("logseq_tasks")

local HL = {
  TODO = "LogseqTodo",
  LATER = "LogseqTodo",
  DOING = "LogseqDoing",
  NOW = "LogseqDoing",
  WAITING = "LogseqDoing",
  DONE = "LogseqDone",
  CANCELLED = "LogseqCancelled",
  CANCELED = "LogseqCancelled",
}
local CLOSED = { DONE = true, CANCELLED = true, CANCELED = true }

-- same order Logseq cycles through for each `:preferred-workflow`
local CYCLES = {
  todo = { "TODO", "DOING", "DONE" },
  now = { "LATER", "NOW", "DONE" },
}

local function opts()
  return require("logseq.config").options
end

--- keyword on a bullet line, plus the text before and after it
function M.parse(line)
  local pre, kw, rest = line:match("^(%s*%- )(%u+)%f[%A](.*)$")
  if kw and HL[kw] then
    return pre, kw, rest
  end
end

--- `DEADLINE:` / `SCHEDULED:` lines of the task at `lnum`: the non-bullet lines right
--- under it. Returns { deadline = { lnum, date = "YYYYMMDD" }, scheduled = ... }.
function M.planning(lines, lnum)
  local out = {}
  for i = lnum + 1, #lines do
    local l = lines[i]
    if l:match("^%s*$") or l:match("^%s*%-%s") or l:match("^%s*%-$") then
      break
    end
    local kind, stamp = l:match("^%s*(%u+): (<.->)")
    local date = stamp and require("logseq.dates").parse_stamp(stamp)
    if date and (kind == "DEADLINE" or kind == "SCHEDULED") and not out[kind:lower()] then
      out[kind:lower()] = { lnum = i, date = date }
    end
  end
  return out
end

--- How pressing a date of a task is: a level and its highlight group. `kind` is "deadline"
--- or "scheduled"; only a deadline can be overdue, a scheduled date that has passed counts
--- as today's work.
function M.urgency(date, kind, closed, now)
  if closed then
    return "closed", "LogseqPlanned"
  end
  local days = require("logseq.dates").days_until(date, now)
  if days < 0 and kind == "deadline" then
    return "overdue", "LogseqOverdue"
  elseif days <= 0 then
    return "today", "LogseqDue"
  elseif days <= opts().tasks.due_days then
    return "soon", "LogseqSoon"
  end
  return "later", "LogseqLater"
end

function M.refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local icons = opts().icons
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    local pre, kw = M.parse(line)
    if kw then
      for kind, p in pairs(M.planning(lines, i)) do
        local l = lines[p.lnum]
        local _, hl = M.urgency(p.date, kind, CLOSED[kw])
        vim.api.nvim_buf_set_extmark(buf, ns, p.lnum - 1, #l:match("^%s*"), {
          end_col = #l,
          hl_group = hl,
        })
      end
      local icon = icons[kw]
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, #pre, {
        end_col = #pre + #kw,
        conceal = (icon and icon ~= "") and icon or nil,
        hl_group = HL[kw],
      })
      if CLOSED[kw] then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, #pre + #kw, { end_col = #line, hl_group = "LogseqDoneText" })
      end
    end
  end
end

--- (none) -> TODO -> DOING -> DONE -> (none), or the LATER/NOW variant.
--- Returns the rewritten line, or nil when the line is not a bullet.
function M.next_line(line)
  local cycle = CYCLES[opts().workflow] or CYCLES.todo
  local pre, kw, rest = M.parse(line)
  if kw then
    local nxt
    for i, k in ipairs(cycle) do
      if k == kw then
        nxt = cycle[i + 1]
      end
    end
    -- a keyword from the other workflow (or WAITING/CANCELLED) just clears
    rest = rest:gsub("^ ", "")
    return nxt and (pre .. nxt .. " " .. rest) or (pre .. rest)
  end
  local p, text = line:match("^(%s*%- ?)(.*)$")
  if not p then
    return nil
  end
  if p:sub(-1) ~= " " then
    p = p .. " "
  end
  return p .. cycle[1] .. " " .. text
end

function M.cycle()
  local line = M.next_line(vim.api.nvim_get_current_line())
  if not line then
    return
  end
  vim.api.nvim_set_current_line(line)
  M.refresh(vim.api.nvim_get_current_buf()) -- don't wait for TextChanged
end

--- Set (`time`) or remove (`time == nil`) the DEADLINE/SCHEDULED line of the task at
--- `lnum`. Only that one line is added, replaced or removed.
function M.apply_date(buf, lnum, kind, time)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local pre, kw = M.parse(lines[lnum] or "")
  if not kw then
    return false, "Not a task: put the cursor on a TODO line"
  end
  local existing = M.planning(lines, lnum)[kind:lower()]
  if existing then
    local indent = lines[existing.lnum]:match("^%s*")
    local repl = time and { indent .. kind .. ": " .. require("logseq.dates").stamp(time) } or {}
    vim.api.nvim_buf_set_lines(buf, existing.lnum - 1, existing.lnum, false, repl)
  elseif time then
    local indent = pre:match("^%s*") .. "  "
    vim.api.nvim_buf_set_lines(buf, lnum, lnum, false, { indent .. kind .. ": " .. require("logseq.dates").stamp(time) })
  end
  M.refresh(buf)
  return true
end

--- Ask for a date and set it on the task under the cursor. kind: "DEADLINE" | "SCHEDULED"
function M.set_date(kind)
  local dates = require("logseq.dates")
  local buf = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if not select(2, M.parse(lines[lnum] or "")) then
    return vim.notify("Not a task: put the cursor on a TODO line", vim.log.levels.WARN, { title = "Logseq" })
  end
  local existing = M.planning(lines, lnum)[kind:lower()]
  local default = existing and os.date("%Y-%m-%d", dates.key_time(existing.date)) or ""
  local label = kind == "DEADLINE" and "Due" or "Scheduled"
  vim.ui.input({ prompt = label .. " (date, fri, +3d; empty removes): ", default = default }, function(text)
    if text == nil then
      return
    end
    local time, err
    if vim.trim(text) ~= "" then
      time, err = dates.parse_input(text)
      if not time then
        return vim.notify(err, vim.log.levels.WARN, { title = "Logseq" })
      end
    end
    M.apply_date(buf, lnum, kind, time)
  end)
end

-- all tasks of the graph ----------------------------------------------------------------

local RANK = { DOING = 1, NOW = 1, TODO = 2, LATER = 2, WAITING = 3, DONE = 4, CANCELLED = 5, CANCELED = 5 }

local function real(path)
  path = vim.fs.normalize(path)
  return vim.uv.fs_realpath(path) or path
end

--- loaded buffers by real file path
local function loaded_buffers()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        out[real(name)] = b
      end
    end
  end
  return out
end

--- Page names mentioned in a text as `[[X]]`, `#[[X]]` or `#tag`. An alias gives the page's
--- title, so a page is always named the same way.
function M.refs_of(text, out, seen)
  local idx = require("logseq.index")
  out, seen = out or {}, seen or {}
  local function add(name)
    name = vim.trim(name)
    if name == "" then
      return
    end
    local e = idx.resolve(name)
    local title = e and e.title or name
    if not seen[title:lower()] then
      seen[title:lower()] = true
      out[#out + 1] = title
    end
  end
  for _, r in ipairs(require("logseq.links").scan(text)) do
    add(r.name)
  end
  return out, seen
end

--- Every task in the graph (or in `o.file`), open ones only unless `o.closed`.
--- `o.page`: only tasks belonging to that page, i.e. the task, one of its parent bullets,
--- the page it is on or that page's `tags::` mention it. `o.due_within`: only tasks overdue
--- or dated within that many days. Unsaved edits in loaded buffers are taken into account.
function M.collect(o)
  o = o or {}
  local want_page
  if o.page then
    local e = require("logseq.index").resolve(o.page)
    want_page = (e and e.title or o.page):lower()
  end
  local cfg = opts()
  local idx = require("logseq.index")
  local only = o.file and real(o.file)
  local bufs = loaded_buffers()
  local hits = {} -- file -> list of line numbers

  if vim.fn.executable("rg") == 1 then
    local args = { "rg", "-n", "-H", "--no-heading", "-g", "*.md", "-e", [[^\s*- [A-Z]+\b]] }
    if only then
      args[#args + 1] = only
    else
      vim.list_extend(args, { cfg.root .. "/" .. cfg.pages_dir, cfg.root .. "/" .. cfg.journals_dir })
    end
    local res = vim.system(args, { text = true }):wait()
    for out in (res.stdout or ""):gmatch("[^\n]+") do
      local file, lnum = out:match("^(.-):(%d+):")
      if file then
        hits[file] = hits[file] or {}
        table.insert(hits[file], tonumber(lnum))
      end
    end
  elseif not M._warned then
    M._warned = true
    vim.notify("logseq.nvim: ripgrep (rg) not found; only open buffers are searched for tasks", vim.log.levels.WARN)
  end

  -- a modified buffer is ahead of the file on disk: scan it instead
  local logseq = require("logseq")
  for file, b in pairs(bufs) do
    if vim.bo[b].modified and logseq.path_in_graph(file) and (not only or file == only) then
      hits[file] = {}
      for i = 1, vim.api.nvim_buf_line_count(b) do
        hits[file][i] = i
      end
    end
  end

  local breadcrumb = require("logseq.backlinks").breadcrumb
  local items = {}
  for file, lnums in pairs(hits) do
    local b = bufs[file]
    local lines = b and vim.api.nvim_buf_get_lines(b, 0, -1, false) or vim.fn.readfile(file)
    local page = idx.by_file(file)
    for _, lnum in ipairs(lnums) do
      local line = lines[lnum]
      local _, kw, rest = M.parse(line or "")
      if kw and (o.closed or not CLOSED[kw]) then
        local plan = M.planning(lines, lnum)
        local dl, sc = plan.deadline and plan.deadline.date, plan.scheduled and plan.scheduled.date
        local crumb = breadcrumb(lines, lnum)
        local refs, seen = M.refs_of((crumb or "") .. " " .. line)
        if page and page.kind == "page" then
          M.refs_of("[[" .. page.title .. "]]", refs, seen)
          for _, tag in ipairs(page.tags) do
            M.refs_of("[[" .. tag .. "]]", refs, seen)
          end
        end
        items[#items + 1] = {
          refs = refs,
          refset = seen,
          deadline = dl,
          scheduled = sc,
          due = (dl and sc) and math.min(dl, sc) .. "" or dl or sc, -- earliest, for sorting
          file = file,
          lnum = lnum,
          line = line,
          kw = kw,
          closed = CLOSED[kw] or false,
          body = vim.trim(rest),
          crumb = crumb,
          page = page and page.title or vim.fn.fnamemodify(file, ":t:r"),
          journal = page and page.kind == "journal" or false,
          date = page and page.date or nil,
        }
      end
    end
  end
  if want_page or o.due_within then
    local dates = require("logseq.dates")
    items = vim.tbl_filter(function(t)
      if want_page and not t.refset[want_page] then
        return false
      end
      return not o.due_within or (t.due ~= nil and dates.days_until(t.due) <= o.due_within)
    end, items)
  end
  table.sort(items, function(a, b)
    if RANK[a.kw] ~= RANK[b.kw] then
      return RANK[a.kw] < RANK[b.kw]
    end
    if a.due ~= b.due then -- dated tasks first, earliest first
      if not (a.due and b.due) then
        return a.due ~= nil
      end
      return a.due < b.due
    end
    if a.journal ~= b.journal then
      return not a.journal
    end
    if a.file ~= b.file then
      if a.journal then
        return (a.date or a.page) > (b.date or b.page) -- newest first
      end
      local x, y = a.page:lower(), b.page:lower()
      if x ~= y then
        return x < y
      end
      return a.file < b.file
    end
    return a.lnum < b.lnum
  end)
  return items
end

--- Pages that open tasks belong to, most tasks first: { { title, count }, ... }
function M.pages_with_tasks()
  local counts, out = {}, {}
  for _, t in ipairs(M.collect()) do
    for _, r in ipairs(t.refs) do
      counts[r] = (counts[r] or 0) + 1
    end
  end
  for title, n in pairs(counts) do
    out[#out + 1] = { title = title, count = n }
  end
  table.sort(out, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.title:lower() < b.title:lower()
  end)
  return out
end

--- Move a collected task to its next state, in the file it lives in. Refuses when the line
--- is no longer what was listed. Only that one line changes.
function M.set_state(item)
  local b = vim.fn.bufadd(item.file)
  vim.fn.bufload(b)
  local cur = vim.api.nvim_buf_get_lines(b, item.lnum - 1, item.lnum, false)[1]
  if cur ~= item.line then
    return false, "The task changed since it was listed; refreshed"
  end
  local new = M.next_line(cur)
  if not new then
    return false, "Not a bullet"
  end
  local dirty = vim.bo[b].modified
  vim.bo[b].fixendofline = false
  vim.api.nvim_buf_set_lines(b, item.lnum - 1, item.lnum, false, { new })
  if not dirty then
    -- a buffer with other unsaved edits is left for the user to write
    vim.api.nvim_buf_call(b, function()
      vim.cmd("silent write")
    end)
  end
  if vim.b[b].logseq_attached then
    M.refresh(b)
  end
  return true
end

--- Short date label for a collected task: text and highlight group, or nil. Shows the
--- deadline once it is due, otherwise the earlier of the two dates.
function M.chip(t, now)
  if not t.due then
    return nil
  end
  local dates = require("logseq.dates")
  local date, kind = t.due, t.due == t.deadline and "deadline" or "scheduled"
  if t.deadline and dates.days_until(t.deadline, now) <= 0 then
    date, kind = t.deadline, "deadline"
  end
  local days = dates.days_until(date, now)
  local word = kind == "deadline" and "due" or "sched"
  local level, hl = M.urgency(date, kind, t.closed, now)
  if level == "overdue" then
    return ("overdue %dd"):format(-days), hl
  elseif level == "today" then
    return days == 0 and (word .. " today") or ("%s %dd ago"):format(word, -days), hl
  elseif level == "soon" then
    -- a day name is unambiguous for the coming six days only
    local when = days == 1 and "tomorrow" or days < 7 and os.date("%a", dates.key_time(date)) or ("in %dd"):format(days)
    return word .. " " .. when, hl
  end
  local day = os.date("%d %b", dates.key_time(date)):gsub("^0", "")
  return word .. " " .. day, hl
end

--- Picker over tasks. `o.page`: only tasks belonging to that page; `o.due`: only tasks
--- overdue or due soon; `o.closed`: include closed ones; `o.file`: one file only.
function M.picker(o)
  o = o or {}
  local idx = require("logseq.index")
  local state = { closed = o.closed or false, page = o.page, due = o.due or false }
  if state.page then
    local e = idx.resolve(state.page)
    state.page = e and e.title or state.page
  end
  local icons = opts().icons
  local days = opts().tasks.due_days
  local function title()
    local t = state.page and ("Tasks: " .. state.page) or "Tasks"
    return state.due and (t .. (" · next %d days"):format(days)) or t
  end
  local function keys()
    local k, out = opts().tasks.keys, {}
    local function bind(key, action, desc)
      if key then
        out[key] = { action, mode = { "n", "i" }, desc = desc }
      end
    end
    bind(k.cycle, "logseq_cycle", "Cycle task state")
    bind(k.toggle_closed, "logseq_toggle_closed", "Show/hide closed tasks")
    bind(k.filter_page, "logseq_filter_page", "Filter tasks by page")
    bind(k.filter_due, "logseq_filter_due", "Only tasks due soon")
    return out
  end
  local function reload(picker)
    picker.title = title()
    picker.list:set_target()
    picker:refresh()
  end
  Snacks.picker.pick({
    title = title(),
    finder = function()
      local items = {}
      local found = M.collect({ file = o.file, closed = state.closed, page = state.page, due_within = state.due and days or nil })
      for _, t in ipairs(found) do
        local tags = {}
        for _, r in ipairs(t.refs) do
          tags[#tags + 1] = "#" .. r
        end
        items[#items + 1] = {
          -- the #refs are not shown, but typing `#work` narrows the list
          text = ("%s %s %s %s %s"):format(t.kw, t.page, t.crumb or "", t.body, table.concat(tags, " ")),
          file = t.file,
          pos = { t.lnum, 0 },
          task = t,
        }
      end
      return items
    end,
    format = function(item)
      local t = item.task
      local icon = icons[t.kw]
      local r = {
        { ((icon and icon ~= "") and icon or t.kw) .. " ", HL[t.kw] },
        { t.page, "LogseqBacklinkPage" },
        { "  " },
      }
      if t.crumb then
        r[#r + 1] = { t.crumb .. " › ", "LogseqBacklinkCrumb" }
      end
      local chip, chip_hl = M.chip(t)
      if chip then
        r[#r + 1] = { chip .. "  ", chip_hl }
      end
      r[#r + 1] = { t.body, t.closed and "LogseqDoneText" or nil }
      return r
    end,
    preview = "file",
    actions = {
      logseq_cycle = function(picker, item)
        if not item then
          return
        end
        local ok, msg = M.set_state(item.task)
        if not ok then
          vim.notify(msg, vim.log.levels.WARN, { title = "Logseq" })
        end
        reload(picker)
      end,
      logseq_toggle_closed = function(picker)
        state.closed = not state.closed
        reload(picker)
      end,
      logseq_filter_due = function(picker)
        state.due = not state.due
        reload(picker)
      end,
      logseq_filter_page = function(picker)
        picker:close()
        M.pick_page(function(page)
          M.picker({ file = o.file, closed = state.closed, due = state.due, page = page })
        end)
      end,
    },
    win = { input = { keys = keys() }, list = { keys = keys() } },
  })
end

--- Choose one of the pages that open tasks belong to; `cb(title)`, or `cb(nil)` for all.
function M.pick_page(cb)
  local items = { { text = "All tasks", all = true } }
  for _, p in ipairs(M.pages_with_tasks()) do
    items[#items + 1] = { text = ("%s (%d)"):format(p.title, p.count), page = p.title }
  end
  Snacks.picker.pick({
    title = "Tasks for page",
    items = items,
    format = function(item)
      return { { item.text, item.all and "Comment" or nil } }
    end,
    preview = false,
    layout = { preset = "select" },
    confirm = function(picker, item)
      picker:close()
      if item then
        cb(item.page)
      end
    end,
  })
end

--- Tasks belonging to the current page: written on it or linked to it.
function M.page_picker()
  if not require("logseq").in_graph(0) then
    return vim.notify("Not a graph page", vim.log.levels.WARN, { title = "Logseq" })
  end
  M.picker({ page = (require("logseq.index").title_of(0)), closed = true })
end

function M.attach(buf)
  local km = opts().keymaps
  if km.enable then
    vim.keymap.set("n", km.prefix .. "x", M.cycle, { buffer = buf, desc = "Cycle task" })
    vim.keymap.set("n", km.prefix .. "A", M.page_picker, { buffer = buf, desc = "Tasks for this page" })
    vim.keymap.set("n", km.prefix .. "d", function()
      M.set_date("DEADLINE")
    end, { buffer = buf, desc = "Task due date" })
    vim.keymap.set("n", km.prefix .. "D", function()
      M.set_date("SCHEDULED")
    end, { buffer = buf, desc = "Task scheduled date" })
  end
end

function M.setup_global()
  local km = opts().keymaps
  if km.enable then
    vim.keymap.set("n", km.prefix .. "a", function()
      M.picker()
    end, { desc = "All tasks" })
  end
end

return M
