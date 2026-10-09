-- Navigation: follow links, find pages, journals, new page, rename, search.
local idx = require("logseq.index")
local M = {}

local function opts()
  return require("logseq.config").options
end

local function root()
  return opts().root
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Logseq" })
end

local function new_page_lines(title)
  return { "title:: " .. title, "", "- " }
end

--- Open a page by title/alias/slug. A missing page opens as an unsaved buffer
--- (nothing is written to disk until you :w).
function M.open(name)
  local e = idx.resolve(name)
  if e then
    vim.cmd.edit(vim.fn.fnameescape(e.file))
    return
  end
  local path = ("%s/%s/%s.md"):format(root(), opts().pages_dir, idx.slugify(name))
  vim.cmd.edit(vim.fn.fnameescape(path))
  if vim.api.nvim_buf_line_count(0) == 1 and vim.api.nvim_get_current_line() == "" then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, new_page_lines(name))
    vim.api.nvim_win_set_cursor(0, { 3, 2 })
  end
end

--- `[[Title]]`, `#[[Title]]` or `#tag` under the cursor
function M.link_at_cursor()
  local ref = require("logseq.links").at(vim.api.nvim_get_current_line(), vim.api.nvim_win_get_cursor(0)[2] + 1)
  return ref and ref.name
end

function M.follow()
  local name = M.link_at_cursor()
  if name then
    M.open(name)
  else
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "n", false)
  end
end

local function pick_items()
  local items = {}
  for _, e in ipairs(idx.list()) do
    local text = e.title
    if #e.aliases > 0 then
      text = text .. "  (" .. table.concat(e.aliases, ", ") .. ")"
    end
    items[#items + 1] = { text = text, file = e.file, title = e.title, kind = e.kind }
  end
  return items
end

function M.find()
  local items = pick_items()
  -- pages that are only referenced so far: listed like Logseq does, created on first save
  for _, r in ipairs(idx.referenced()) do
    items[#items + 1] = {
      text = r.title,
      title = r.title,
      virtual = true,
      note = ("  (no page yet, %d ref%s)"):format(r.count, r.count == 1 and "" or "s"),
    }
  end
  Snacks.picker.pick({
    title = "Notes",
    items = items,
    format = function(item)
      if item.virtual then
        return { { item.text, "Comment" }, { item.note, "NonText" } }
      end
      return { { item.text, item.kind == "journal" and "Comment" or nil } }
    end,
    preview = function(ctx)
      if ctx.item.virtual then
        ctx.preview:reset()
        ctx.preview:set_title(ctx.item.title)
        ctx.preview:set_lines({ "No page file yet.", "", "Enter opens it with its linked references;", "the file is created when you save." })
        return
      end
      return Snacks.picker.preview.file(ctx)
    end,
    confirm = function(picker, item)
      if item and item.virtual then
        picker:close()
        -- after the picker is gone, so the new buffer gets its filetype like any other
        vim.schedule(function()
          M.open(item.title)
        end)
      else
        picker:action("jump")
      end
    end,
  })
end

function M.search()
  Snacks.picker.grep({
    title = "Search notes",
    cwd = root(),
    dirs = { root() .. "/" .. opts().pages_dir, root() .. "/" .. opts().journals_dir },
  })
end

function M.tags()
  local items = {}
  for tag, n in pairs(idx.get().tags) do
    items[#items + 1] = { text = ("%s  (%d)"):format(tag, n), tag = tag }
  end
  table.sort(items, function(a, b)
    return a.text:lower() < b.text:lower()
  end)
  Snacks.picker.pick({
    title = "Tags",
    items = items,
    format = function(item)
      return { { item.text } }
    end,
    preview = false,
    confirm = function(picker, item)
      picker:close()
      if item then
        require("logseq.backlinks").picker_for({ item.tag }, nil, "References to " .. item.tag)
      end
    end,
  })
end

function M.new()
  vim.ui.input({ prompt = "New page title: " }, function(title)
    if title and vim.trim(title) ~= "" then
      M.open(vim.trim(title))
    end
  end)
end

-- journals --------------------------------------------------------------------

--- Path of the journal `offset` days from today, named with the configured
--- `journal_file_format`. An existing journal for that day in another known format wins,
--- so a day never ends up with two files.
function M.journal_path(offset)
  local dates = require("logseq.dates")
  local t = os.date("*t")
  t.day = t.day + offset
  t.hour = 12
  local time = os.time(t)
  local key = os.date("%Y%m%d", time)
  for _, e in ipairs(idx.list()) do
    if e.kind == "journal" and e.date == key then
      return e.file
    end
  end
  return ("%s/%s/%s.md"):format(root(), opts().journals_dir, dates.format(opts().journal_file_format, time))
end

function M.journal(offset)
  local path = M.journal_path(offset)
  vim.cmd.edit(vim.fn.fnameescape(path))
  if vim.api.nvim_buf_line_count(0) == 1 and vim.api.nvim_get_current_line() == "" then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "- " })
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
  end
end

function M.journal_step(dir)
  local journals = {}
  for _, e in ipairs(idx.list()) do
    if e.kind == "journal" and e.date then
      journals[#journals + 1] = e
    end
  end
  table.sort(journals, function(x, y)
    return x.date < y.date
  end)
  local me = idx.by_file(vim.api.nvim_buf_get_name(0))
  -- from a journal: its neighbour. From anywhere else: relative to today.
  local from = me and me.kind == "journal" and me.date or os.date("%Y%m%d")
  local target
  if dir > 0 then
    for _, e in ipairs(journals) do
      if e.date > from then
        target = e
        break
      end
    end
  else
    for i = #journals, 1, -1 do
      if journals[i].date < from then
        target = journals[i]
        break
      end
    end
  end
  if target then
    vim.cmd.edit(vim.fn.fnameescape(target.file))
  else
    notify("No more journals in that direction")
  end
end

-- rename ----------------------------------------------------------------------

--- Change the `title::` of the current page and (after confirmation) rewrite
--- `[[Old]]` references. The file itself is never renamed.
function M.rename()
  local buf = vim.api.nvim_get_current_buf()
  local e = idx.by_file(vim.api.nvim_buf_get_name(buf))
  if not e then
    return notify("Not a graph page", vim.log.levels.WARN)
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 20, false)
  local tline
  for i, l in ipairs(lines) do
    if l:match("^title::") then
      tline = i
      break
    end
  end
  if not tline then
    return notify("Page has no `title::` property; add one first (files are never renamed here).", vim.log.levels.WARN)
  end
  local old = e.title
  vim.ui.input({ prompt = "Rename page: ", default = old }, function(new)
    new = new and vim.trim(new)
    if not new or new == "" or new == old then
      return
    end
    vim.api.nvim_buf_set_lines(buf, tline - 1, tline, false, { "title:: " .. new })
    vim.cmd("silent write")
    idx.invalidate()
    require("logseq.backlinks").query({ old }, e.file, function(entries)
      local files = {}
      for _, en in ipairs(entries) do
        files[en.file] = true
      end
      local nfiles = vim.tbl_count(files)
      if #entries == 0 then
        return notify(("Renamed to '%s'. No references to update."):format(new))
      end
      local choice = vim.fn.confirm(
        ("Rewrite %d reference(s) to [[%s]] in %d file(s)?"):format(#entries, old, nfiles),
        "&Yes\n&No",
        2
      )
      if choice ~= 1 then
        return notify("Renamed. References left unchanged (they still point to the old title).")
      end
      local links = require("logseq.links")
      for file in pairs(files) do
        local b = vim.fn.bufadd(file)
        vim.fn.bufload(b)
        vim.bo[b].fixendofline = false
        local ls = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        for i, l in ipairs(ls) do
          ls[i] = links.rewrite(l, old, new)
        end
        vim.api.nvim_buf_set_lines(b, 0, -1, false, ls)
        vim.api.nvim_buf_call(b, function()
          vim.cmd("silent write")
        end)
      end
      idx.invalidate()
      notify(("Renamed to '%s' and updated %d file(s)."):format(new, nfiles))
    end)
  end)
end

-- keymaps -----------------------------------------------------------------------

function M.attach(buf)
  local km = opts().keymaps
  if not km.enable then
    return
  end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc })
  end
  map("<CR>", M.follow, "Follow link")
  map("gd", function()
    if M.link_at_cursor() then
      M.follow()
    else
      vim.cmd("normal! gd")
    end
  end, "Follow link")
  map("]j", function()
    M.journal_step(1)
  end, "Next journal")
  map("[j", function()
    M.journal_step(-1)
  end, "Previous journal")
  map(km.prefix .. "r", M.rename, "Rename page")
end

function M.setup_global()
  local km = opts().keymaps
  if not km.enable then
    return
  end
  local p = km.prefix
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { desc = desc })
  end
  map(p .. "f", M.find, "Find page")
  map(p .. "s", M.search, "Search notes")
  map(p .. "t", function()
    M.journal(0)
  end, "Today's journal")
  map(p .. "y", function()
    M.journal(-1)
  end, "Yesterday's journal")
  map(p .. "m", function()
    M.journal(1)
  end, "Tomorrow's journal")
  map(p .. "n", M.new, "New page")
  map(p .. "T", M.tags, "Tags")
  pcall(function()
    require("which-key").add({ { p, group = "notes" } })
  end)
end

return M
