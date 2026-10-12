-- Headless test suite. Builds a throw-away graph in a temp dir; never touches a real one.
--   nvim --headless -u NONE -l tests/run.lua
local here = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
vim.opt.rtp:prepend(here)
vim.o.swapfile = false
vim.o.virtualedit = "onemore" -- lets tests put the cursor after the last character, as in insert mode

local pass, fail = 0, {}
local function check(name, ok, extra)
  if ok then
    pass = pass + 1
  else
    fail[#fail + 1] = name .. (extra ~= nil and (" :: " .. tostring(extra)) or "")
  end
end
local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end
local function buf_text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end
local function set(lines)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end
local function snapshot(dir)
  local out = {}
  for name, t in vim.fs.dir(dir, { depth = 5 }) do
    if t == "file" then
      out[name] = table.concat(vim.fn.readfile(dir .. "/" .. name, "b"), "\n")
    end
  end
  return out
end

local function fixture(extra_edn)
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  root = vim.uv.fs_realpath(root)
  write(root .. "/logseq/config.edn", vim.list_extend({ "{:meta/version 1", ' ;; :journal/file-name-format "yyyy_MM_dd"' }, extra_edn or { " :preferred-workflow :now}" }))
  write(root .. "/pages/PUI.md", { "title:: PUI", "tags:: [[Project]], [[Work]]", "alias:: [[Provider UI]]", "", "- Overview", "  - detail #database" })
  write(root .. "/pages/go-live.md", { "title:: PUI Go Live", "", "- Roughly end of Q1 [[PUI]]" })
  write(root .. "/pages/medicine-festival.md", { "title:: Medicine Festival", "tags:: [[Project]]", "", "- TODO insurance" })
  write(root .. "/pages/playwright.md", { "- no title here, see [[Provider UI]]" })
  write(root .. "/pages/database.md", { "title:: database", "", "- x" })
  write(root .. "/journals/2026-10-06.md", { "- [[PUI]] did a thing", "  - nested mention of [[pui]] again" })
  write(root .. "/journals/2026-10-07.md", { "- parent", "  - child with [[PUI]]" })
  write(root .. "/journals/2026_07_29.md", { "- old style journal [[Medicine Festival]]" })
  write(root .. "/README.md", { "# not a page" })
  return root
end

local outside = vim.fs.normalize(vim.fn.tempname()) .. ".md"
write(outside, { "# outside", "", "- [[PUI]]" })

local ok, err = xpcall(function()
  -- dates -------------------------------------------------------------------------------
  local dates = require("logseq.dates")
  local t = os.time({ year = 2026, month = 10, day = 8, hour = 12 })
  check("format underscore", dates.format("yyyy_MM_dd", t) == "2026_10_08")
  check("format dash", dates.format("yyyy-MM-dd", t) == "2026-10-08")
  check("format reordered", dates.format("dd.MM.yyyy", t) == "08.10.2026")
  check("parse dash", dates.parse("yyyy-MM-dd", "2026-10-08") == "20261008")
  check("parse reordered", dates.parse("dd.MM.yyyy", "08.10.2026") == "20261008")
  check("parse rejects other format", dates.parse("yyyy-MM-dd", "2026_10_08") == nil)
  check("parse rejects bad month", dates.parse("yyyy-MM-dd", "2026-13-08") == nil)
  check("parse_any falls back", dates.parse_any("yyyy-MM-dd", "2026_07_29") == "20260729")
  check("validate ok", dates.validate("yyyy_MM_dd"))
  check("validate unsupported token", not dates.validate("EEE yyyy-MM-dd"))
  check("validate missing part", not dates.validate("yyyy-MM"))
  check("validate slash", not dates.validate("yyyy/MM/dd"))

  -- config ------------------------------------------------------------------------------
  local cfg = require("logseq.config")
  check("setup needs root", not pcall(cfg.setup, {}))
  local root = fixture()
  local logseq = require("logseq")
  logseq.setup({ root = root })
  local o = cfg.options
  check("format detected from files", o.journal_file_format == "yyyy-MM-dd" and o.journal_format_source == "detected", o.journal_file_format)
  check("commented edn key ignored", o.edn["journal/file-name-format"] == nil)
  check("workflow default todo", o.workflow == "todo")
  check("task picker keys default", o.tasks.keys.cycle == "<c-x>" and o.tasks.keys.toggle_closed == "<c-o>")
  local ok_keys = cfg.setup({ root = root, tasks = { keys = { toggle_closed = "<c-e>" } } }).tasks.keys
  check("task picker keys override", ok_keys.toggle_closed == "<c-e>" and ok_keys.cycle == "<c-x>")
  cfg.setup({ root = root })
  check("dirs default", o.pages_dir == "pages" and o.journals_dir == "journals")

  local r2 = fixture({ ' :journal/file-name-format "yyyy_MM_dd"', ' :pages-directory "notes"', " :preferred-workflow :todo}" })
  local o2 = cfg.setup({ root = r2, workflow = "auto" })
  check("format from config.edn", o2.journal_file_format == "yyyy_MM_dd" and o2.journal_format_source == "config.edn")
  check("pages dir from config.edn", o2.pages_dir == "notes")
  check("workflow auto reads edn", o2.workflow == "todo")
  local o3 = cfg.setup({ root = r2, journal_file_format = "dd.MM.yyyy", pages_dir = "pages" })
  check("explicit format wins", o3.journal_file_format == "dd.MM.yyyy" and o3.journal_format_source == "option")
  local o4 = cfg.setup({ root = r2, journal_file_format = "yyyy-QQ" })
  check("invalid format reported, default used", o4.journal_format_error ~= nil and o4.journal_file_format == "yyyy_MM_dd")
  local empty = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(empty .. "/journals", "p")
  check("empty graph uses Logseq default", cfg.setup({ root = empty }).journal_file_format == "yyyy_MM_dd")

  logseq.setup({ root = root })
  local before = snapshot(root)

  -- index -------------------------------------------------------------------------------
  local idx = require("logseq.index")
  idx.invalidate()
  check("resolve title", idx.resolve("PUI") ~= nil)
  check("resolve case-insensitive", idx.resolve("medicine festival") ~= nil)
  check("resolve slug", idx.resolve("go-live") ~= nil)
  check("title wins over slug", idx.resolve("PUI Go Live").slug == "go-live")
  check("resolve alias", idx.resolve("Provider UI").slug == "PUI")
  check("resolve missing", idx.resolve("Nope") == nil)
  check("page without title uses filename", idx.resolve("playwright") ~= nil)
  check("README not indexed", idx.by_file(root .. "/README.md") == nil)
  check("old-format journal dated", idx.resolve("2026_07_29").date == "20260729")

  -- filetype / isolation ----------------------------------------------------------------
  check("ft match page", vim.filetype.match({ filename = root .. "/pages/PUI.md" }) == "markdown.logseq")
  check("ft match journal", vim.filetype.match({ filename = root .. "/journals/2026-10-06.md" }) == "markdown.logseq")
  check("ft root README stays markdown", vim.filetype.match({ filename = root .. "/README.md" }) == "markdown")
  check("ft outside stays markdown", vim.filetype.match({ filename = outside }) == "markdown")
  vim.cmd("filetype on")

  local nav = require("logseq.nav")
  nav.open("PUI")
  local gbuf = vim.api.nvim_get_current_buf()
  check("open by title", vim.api.nvim_buf_get_name(gbuf):match("pages/PUI%.md$") ~= nil)
  check("graph ft", vim.bo.filetype == "markdown.logseq", vim.bo.filetype)
  check("attached", vim.b.logseq_attached == true)
  check("autoformat off", vim.b.autoformat == false)
  check("diagnostics off", not vim.diagnostic.is_enabled({ bufnr = 0 }))
  check("indent opts", vim.bo.expandtab and vim.bo.shiftwidth == 2)
  check("win opts", vim.wo.conceallevel == 2 and vim.wo.concealcursor == "nc" and vim.wo.foldmethod == "indent" and vim.wo.breakindent)
  check("graph maps", vim.fn.maparg("<Tab>", "n", false, true).buffer == 1 and vim.fn.maparg("<CR>", "i", false, true).buffer == 1)

  vim.cmd.edit(outside)
  check("outside: ft markdown", vim.bo.filetype == "markdown", vim.bo.filetype)
  check("outside: not attached", not vim.b.logseq_attached)
  check("outside: win opts restored", vim.wo.conceallevel ~= 2 or vim.w.logseq_saved == nil)
  check("outside: foldmethod restored", vim.wo.foldmethod ~= "indent", vim.wo.foldmethod)
  check("outside: no buffer maps", vim.fn.maparg("<Tab>", "n", false, true).buffer ~= 1 and vim.fn.maparg("<CR>", "i", false, true).buffer ~= 1)
  check("outside: autoformat untouched", vim.b.autoformat == nil)
  check("outside: diagnostics on", vim.diagnostic.is_enabled({ bufnr = 0 }))
  vim.cmd.edit(root .. "/README.md")
  check("graph README: not attached", not vim.b.logseq_attached and vim.bo.filetype == "markdown")

  -- links -------------------------------------------------------------------------------
  vim.cmd("enew")
  set({ "- see [[Medicine Festival]] and #database ok", "# Heading" })
  vim.api.nvim_win_set_cursor(0, { 1, 12 })
  check("link under cursor", nav.link_at_cursor() == "Medicine Festival")
  vim.api.nvim_win_set_cursor(0, { 1, 35 })
  check("tag under cursor", nav.link_at_cursor() == "database")
  vim.api.nvim_win_set_cursor(0, { 2, 3 })
  check("heading is not a tag", nav.link_at_cursor() == nil)
  vim.cmd("bwipeout!")
  nav.open("Brand New Page")
  check("new page prefilled", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "title:: Brand New Page")
  check("new page path", vim.api.nvim_buf_get_name(0):match("pages/brand%-new%-page%.md$") ~= nil)
  check("new page not written", vim.fn.filereadable(root .. "/pages/brand-new-page.md") == 0)
  vim.cmd("bwipeout!")

  -- journals ----------------------------------------------------------------------------
  local today = os.date("%Y-%m-%d")
  check("today path uses format", nav.journal_path(0) == root .. "/journals/" .. today .. ".md", nav.journal_path(0))
  vim.cmd.edit(root .. "/journals/2026-10-06.md")
  nav.journal_step(1)
  check("next journal", vim.api.nvim_buf_get_name(0):match("2026%-10%-07%.md$") ~= nil)
  nav.journal_step(-1)
  nav.journal_step(-1)
  check("prev crosses formats", vim.api.nvim_buf_get_name(0):match("2026_07_29%.md$") ~= nil, vim.api.nvim_buf_get_name(0))
  cfg.options.journal_file_format = "yyyy_MM_dd"
  check("format option changes new files", nav.journal_path(0) == root .. "/journals/" .. os.date("%Y_%m_%d") .. ".md")
  write(root .. "/journals/" .. today .. ".md", { "- existing" })
  idx.invalidate()
  check("existing journal in other format reused", nav.journal_path(0) == root .. "/journals/" .. today .. ".md")
  vim.fn.delete(root .. "/journals/" .. today .. ".md")
  idx.invalidate()
  cfg.options.journal_file_format = "yyyy-MM-dd"

  -- tasks -------------------------------------------------------------------------------
  local tasks = require("logseq.tasks")
  vim.cmd.edit(root .. "/journals/2026-10-07.md")
  set({ "- TODO a", "  - DOING b", "- DONE c", "- plain", "- NOW d", "- TODOS are not tasks", "- " })
  tasks.refresh(0)
  local icons = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("logseq_tasks"), 0, -1, { details = true })) do
    if m[4].conceal then
      icons[#icons + 1] = m[4].conceal
    end
  end
  check("task icons", table.concat(icons) == "☐◐☑◐", table.concat(icons))
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  local seq = {}
  for _ = 1, 4 do
    tasks.cycle()
    seq[#seq + 1] = vim.api.nvim_get_current_line()
  end
  check("cycle todo workflow", table.concat(seq, "|") == "- TODO plain|- DOING plain|- DONE plain|- plain", table.concat(seq, "|"))
  vim.api.nvim_win_set_cursor(0, { 7, 0 })
  tasks.cycle()
  check("cycle on empty bullet", vim.api.nvim_get_current_line() == "- TODO ")
  cfg.options.workflow = "now"
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  seq = {}
  for _ = 1, 4 do
    tasks.cycle()
    seq[#seq + 1] = vim.api.nvim_get_current_line()
  end
  check("cycle now workflow", table.concat(seq, "|") == "- LATER plain|- NOW plain|- DONE plain|- plain", table.concat(seq, "|"))
  cfg.options.workflow = "todo"

  -- block editing -----------------------------------------------------------------------
  local edit = require("logseq.edit")
  local base = { "title:: X", "", "- a", "  - a1", "- b", "  cont", "  - b1", "- c" }
  local base_s = table.concat(base, "\n")
  set(base)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  edit.move(1)
  check("move down", buf_text() == "title:: X\n\n- b\n  cont\n  - b1\n- a\n  - a1\n- c", buf_text())
  check("cursor follows block", vim.api.nvim_win_get_cursor(0)[1] == 6)
  edit.move(-1)
  check("move up restores", buf_text() == base_s)
  edit.move(-1)
  check("move up at top is a no-op", buf_text() == base_s)
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  edit.shift(1)
  check("indent block", buf_text() == "title:: X\n\n- a\n  - a1\n  - b\n    cont\n    - b1\n- c", buf_text())
  edit.shift(1)
  check("indent twice", buf_text() == "title:: X\n\n- a\n  - a1\n    - b\n      cont\n      - b1\n- c", buf_text())
  edit.shift(1)
  check("cannot indent past previous sibling", buf_text() == "title:: X\n\n- a\n  - a1\n    - b\n      cont\n      - b1\n- c")
  edit.shift(-1)
  edit.shift(-1)
  check("outdent restores", buf_text() == base_s, buf_text())
  edit.shift(-1)
  check("outdent at top level is a no-op", buf_text() == base_s)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  edit.shift(1)
  check("first bullet cannot indent", buf_text() == base_s)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  edit.move(1)
  edit.shift(1)
  check("property line untouched", buf_text() == base_s)
  set({ "- a", "\t- t1", "\t- t2" })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  edit.shift(1)
  check("tab-indented block keeps tabs", buf_text() == "- a\n\t- t1\n\t\t- t2", buf_text())

  -- auto-bullets ------------------------------------------------------------------------
  local function at(lines, row, col)
    set(lines)
    vim.api.nvim_win_set_cursor(0, { row, col })
  end
  at({ "- hello" }, 1, 7)
  check("CR handled", edit.newline() == true)
  check("CR at end: sibling", buf_text() == "- hello\n- " and vim.api.nvim_win_get_cursor(0)[1] == 2, buf_text())
  at({ "- hello world" }, 1, 8)
  edit.newline()
  check("CR mid-line splits", buf_text() == "- hello \n- world", buf_text())
  at({ "- parent", "  - child" }, 1, 8)
  edit.newline()
  check("CR on parent: first child", buf_text() == "- parent\n  - \n  - child", buf_text())
  at({ "- a", "  - b", "  - " }, 3, 4)
  edit.newline()
  check("CR on empty nested bullet outdents", buf_text() == "- a\n  - b\n- ", buf_text())
  at({ "- a", "- " }, 2, 2)
  edit.newline()
  check("CR on empty top bullet clears it", buf_text() == "- a\n", buf_text())
  at({ "- a", "  continuation" }, 2, 5)
  check("CR on continuation line not handled", edit.newline() == false)
  at({ "title:: X" }, 1, 5)
  check("CR on property line not handled", edit.newline() == false)
  at({ "- TODO task" }, 1, 11)
  edit.newline()
  check("CR after task: plain bullet", buf_text() == "- TODO task\n- ", buf_text())
  at({ "  - a", "  - b" }, 1, 0)
  check("o handled", edit.open_line(false) == true)
  vim.cmd("stopinsert")
  check("o: bullet below", buf_text() == "  - a\n  - \n  - b", buf_text())
  at({ "  - a", "  - b" }, 2, 0)
  edit.open_line(true)
  vim.cmd("stopinsert")
  check("O: bullet above", buf_text() == "  - a\n  - \n  - b", buf_text())
  at({ "- p", "  - c" }, 1, 0)
  edit.open_line(false)
  vim.cmd("stopinsert")
  check("o on parent: first child", buf_text() == "- p\n  - \n  - c", buf_text())
  at({ "plain text" }, 1, 0)
  check("o on non-bullet not handled", edit.open_line(false) == false)
  vim.cmd("edit!")

  -- completion --------------------------------------------------------------------------
  local src = require("logseq.integrations.blink").new({})
  vim.cmd.edit(root .. "/pages/PUI.md")
  check("source enabled in graph", src:enabled() == true)
  local res
  local function complete(line, col)
    src:get_completions({ line = line, cursor = { 1, col } }, function(r)
      res = r
    end)
    local by = {}
    for _, it in ipairs(res.items) do
      by[it.label] = it
    end
    return by
  end
  local by = complete("- see [[Med", 11)
  check("completes title", by["Medicine Festival"] ~= nil)
  check("completes alias", by["Provider UI"] ~= nil)
  check("never offers a slug", by["medicine-festival"] == nil and by["go-live"] == nil)
  check("closes brackets", by["Medicine Festival"].textEdit.newText == "Medicine Festival]]" and by["Medicine Festival"].textEdit.range.start.character == 8)
  by = complete("- see [[Med]]", 11)
  check("keeps existing brackets", by["Medicine Festival"].textEdit.newText == "Medicine Festival")
  complete("- plain text", 8)
  check("silent outside a link", #res.items == 0)
  by = complete("- a #dat", 8)
  check("tag completion: one word", by["database"] ~= nil and by["database"].textEdit.newText == "database")
  check("tag completion: title with a space", by["Medicine Festival"] ~= nil and by["Medicine Festival"].textEdit.newText == "[[Medicine Festival]]")
  check("tag completion: alias", by["Provider UI"] ~= nil)
  check("tag completion: name only used in tags::", by["Project"] ~= nil and by["Project"].textEdit.newText == "Project")
  check("tag completion: replaces what was typed", by["database"].textEdit.range.start.character == 5)
  check("tag completion: no journals", by["2026-10-06"] == nil)
  by = complete("#", 1)
  check("tag completion at line start", by["database"] ~= nil)
  by = complete("- (#", 4)
  check("tag completion after a bracket", by["database"] ~= nil)
  complete("- a#dat", 7)
  check("no tag completion inside a word", #res.items == 0)
  vim.cmd.edit(outside)
  check("source disabled outside", src:enabled() == false)

  -- backlinks ---------------------------------------------------------------------------
  if vim.fn.executable("rg") == 1 then
    local bl = require("logseq.backlinks")
    local done, entries
    bl.query({ "PUI", "Provider UI" }, root .. "/pages/PUI.md", function(e)
      entries, done = e, true
    end)
    vim.wait(5000, function()
      return done
    end)
    check("backlinks count", entries and #entries == 5, entries and #entries)
    local self_ref, crumb, tagged = false, false, false
    for _, e in ipairs(entries or {}) do
      self_ref = self_ref or e.file:match("pages/PUI%.md$") ~= nil
      crumb = crumb or (e.crumb == "parent" and e.text == "child with [[PUI]]")
      tagged = tagged or e.file:match("playwright%.md$") ~= nil
    end
    check("backlinks exclude self", not self_ref)
    check("backlinks carry parent breadcrumb", crumb)
    check("backlinks via alias", tagged)
    done = false
    bl.query({ "database" }, root .. "/pages/database.md", function(e)
      entries, done = e, true
    end)
    vim.wait(5000, function()
      return done
    end)
    check("backlinks via #tag", entries and #entries == 1 and entries[1].text == "detail #database", entries and #entries)

    vim.cmd.edit(root .. "/pages/PUI.md")
    vim.wait(3000, function()
      return vim.b.logseq_bl ~= nil
    end)
    local bns = vim.api.nvim_create_namespace("logseq_backlinks")
    local em = vim.api.nvim_buf_get_extmarks(0, bns, 0, -1, { details = true })
    check("inline backlinks rendered", #em == 1 and #em[1][4].virt_lines > 3, #em)
    check("inline backlinks do not modify buffer", not vim.bo.modified)
    bl.toggle()
    check("toggle hides them", #vim.api.nvim_buf_get_extmarks(0, bns, 0, -1, {}) == 0)
    bl.toggle()
  end

  -- symlinked graph ------------------------------------------------------------------------
  local link = vim.fs.normalize(vim.fn.tempname())
  if vim.uv.fs_symlink(root, link) then
    logseq.setup({ root = link })
    idx.invalidate()
    check("symlink: root canonical", cfg.options.root == root)
    check("symlink: path via link in graph", logseq.path_in_graph(link .. "/pages/PUI.md"))
    check("symlink: path via target in graph", logseq.path_in_graph(root .. "/pages/PUI.md"))
    check("symlink: by_file via link", idx.by_file(link .. "/pages/PUI.md") ~= nil)
    check("symlink: ft via link", vim.filetype.match({ filename = link .. "/pages/PUI.md" }) == "markdown.logseq")
    logseq.setup({ root = root })
  end

  -- commands ----------------------------------------------------------------------------
  vim.cmd("runtime plugin/logseq.lua")
  check(":Logseq exists", vim.fn.exists(":Logseq") == 2)
  check(":Logseq completion", vim.tbl_contains(vim.fn.getcompletion("Logseq to", "cmdline"), "today"))
  vim.cmd.edit(root .. "/pages/medicine-festival.md")
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.cmd("Logseq cycle_task")
  check(":Logseq cycle_task", vim.api.nvim_get_current_line() == "- DOING insurance", vim.api.nvim_get_current_line())
  vim.cmd("edit!")

  -- render-markdown options (pure function) ---------------------------------------------
  local rm = logseq.render_markdown_opts({ heading = { sign = false }, file_types = { "markdown", "norg" } })
  check("rm: keeps user opts", rm.heading.sign == false)
  check("rm: adds filetype", vim.deep_equal(rm.file_types, { "markdown", "norg", "markdown.logseq" }))
  local ov = rm.overrides.filetype["markdown.logseq"]
  check("rm: override", ov.anti_conceal.enabled == false and ov.win_options.conceallevel.rendered == 2 and ov.win_options.concealcursor.rendered == "nc")
  check("rm: plain markdown untouched", rm.overrides.filetype.markdown == nil and rm.anti_conceal == nil)

  -- nothing on disk changed -------------------------------------------------------------
  check("fixture files unchanged", vim.deep_equal(before, snapshot(root)))

  -- task list (writes to the fixture, so it runs after the check above) -----------------
  vim.cmd("silent! %bwipeout!")
  local ta = root .. "/pages/tasks-a.md"
  local ta_lines = {
    "title:: Alpha",
    "",
    "- Project",
    "  - TODO first",
    "    id:: 64f0c0de-0000-4000-8000-000000000001",
    "  - DONE finished",
    "- TODOS are not tasks",
    "- DOING second",
  }
  write(ta, ta_lines)
  write(root .. "/journals/2026-10-05.md", { "- TODO older" })
  write(root .. "/journals/2026_07_30.md", { "\t- TODO tabbed", "- CANCELLED nope" })
  idx.invalidate()
  local function bodies(list)
    return table.concat(vim.tbl_map(function(t)
      return t.body
    end, list), "|")
  end
  check("next_line adds", tasks.next_line("- a") == "- TODO a")
  check("next_line clears foreign keyword", tasks.next_line("- WAITING x") == "- x")
  check("next_line ignores non-bullets", tasks.next_line("plain text") == nil)
  local open = tasks.collect()
  check("collect: open tasks in order", bodies(open) == "second|first|insurance|older|tabbed", bodies(open))
  check("collect: page title and breadcrumb", open[2].page == "Alpha" and open[2].crumb == "Project", vim.inspect(open[2]))
  check("collect: with closed", bodies(tasks.collect({ closed = true })) == "second|first|insurance|older|tabbed|finished|nope")
  check("collect: one file", bodies(tasks.collect({ file = ta, closed = true })) == "second|first|finished")
  local jt = idx.by_file(root .. "/journals/2026_07_30.md").title
  check("filter by page: tasks written on a journal", bodies(tasks.collect({ page = jt, closed = true })) == "tabbed|nope", bodies(tasks.collect({ page = jt, closed = true })))
  check("journals stay out of the page list", not vim.tbl_contains(vim.tbl_map(function(p)
    return p.title
  end, tasks.pages_with_tasks()), jt))
  local row = vim.tbl_map(function(piece)
    return piece[1]
  end, tasks.row({ kw = "TODO", page = "P", body = "the task", crumb = "#Work › DONE long parent › plain", closed = false }))
  check("row: task before its parents, keywords dropped", row[#row - 1] == "the task" and row[#row] == "   #Work › long parent › plain", vim.inspect(row))

  vim.cmd.edit(root .. "/pages/database.md")
  set({ "title:: database", "", "- TODO unsaved" })
  check("collect: sees unsaved buffer", bodies(tasks.collect()):find("unsaved", 1, true) ~= nil)
  vim.cmd("edit!")
  check("collect: discarded edit gone", bodies(tasks.collect()):find("unsaved", 1, true) == nil)

  local first = open[2]
  local okc = tasks.set_state(first)
  local want = vim.deepcopy(ta_lines)
  want[4] = "  - DOING first"
  check("set_state: one line rewritten on disk", okc and vim.deep_equal(vim.fn.readfile(ta), want), table.concat(vim.fn.readfile(ta), "|"))
  local stale_ok = tasks.set_state(first) -- still carries the old line
  check("set_state: stale item refused", stale_ok == false and vim.deep_equal(vim.fn.readfile(ta), want))

  vim.cmd.edit(ta)
  vim.api.nvim_buf_set_lines(0, 6, 7, false, { "- edited, not saved" })
  local second = tasks.collect({ file = ta })[2] -- "first" is DOING now and comes before it
  check("set_state: target in dirty buffer", second.body == "second" and tasks.set_state(second))
  check("set_state: dirty buffer changed", vim.api.nvim_buf_get_lines(0, 7, 8, false)[1] == "- DONE second")
  check("set_state: dirty buffer not written", vim.deep_equal(vim.fn.readfile(ta), want))
  vim.cmd("edit!")

  -- task dates ---------------------------------------------------------------------------
  local now = os.time({ year = 2026, month = 10, day = 9, hour = 9 }) -- a Friday
  local function day(time)
    return time and os.date("%Y-%m-%d", time)
  end
  check("stamp", dates.stamp(os.time({ year = 2026, month = 10, day = 15, hour = 12 })) == "<2026-10-15 Thu>")
  check("parse_stamp", dates.parse_stamp("<2026-08-01 Sat>") == "20260801")
  check("parse_stamp with time and repeater", dates.parse_stamp("<2026-08-01 Sat 10:00 .+1w>") == "20260801")
  check("parse_stamp rejects text", dates.parse_stamp("soon") == nil)
  check("input iso", day(dates.parse_input("2026-10-15", now)) == "2026-10-15")
  check("input today", day(dates.parse_input("today", now)) == "2026-10-09")
  check("input tomorrow", day(dates.parse_input("Tomorrow", now)) == "2026-10-10")
  check("input +3d", day(dates.parse_input("+3d", now)) == "2026-10-12")
  check("input +2w over month end", day(dates.parse_input("+4w", now)) == "2026-11-06")
  check("input day name", day(dates.parse_input("mon", now)) == "2026-10-12")
  check("input same day name is next week", day(dates.parse_input("friday", now)) == "2026-10-16")
  check("input bad date", dates.parse_input("2026-02-30", now) == nil)
  check("input nonsense", dates.parse_input("soonish", now) == nil)
  check("days_until", dates.days_until("20261006", now) == -3 and dates.days_until("20261009", now) == 0)

  local td = root .. "/pages/tasks-d.md"
  local td_lines = {
    "title:: Dated",
    "",
    "- TODO parent",
    "  id:: 64f0c0de-0000-4000-8000-000000000002",
    "  - child",
    "\t- TODO tabbed",
    "- plain bullet",
    "- DONE closed one",
    "  SCHEDULED: <2026-08-01 Sat>",
  }
  write(td, td_lines)
  idx.invalidate()
  vim.cmd.edit(td)
  local function cur()
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end
  local function expect(change)
    local w = vim.deepcopy(td_lines)
    change(w)
    return vim.deep_equal(cur(), w)
  end
  local due = os.time({ year = 2026, month = 10, day = 15, hour = 12 })
  check("date: insert", tasks.apply_date(0, 3, "DEADLINE", due) and expect(function(w)
    table.insert(w, 4, "  DEADLINE: <2026-10-15 Thu>")
  end), table.concat(cur(), "|"))
  check("date: read back", tasks.planning(cur(), 3).deadline.date == "20261015")
  tasks.apply_date(0, 3, "DEADLINE", os.time({ year = 2026, month = 10, day = 16, hour = 12 }))
  check("date: replace, no duplicate", expect(function(w)
    table.insert(w, 4, "  DEADLINE: <2026-10-16 Fri>")
  end), table.concat(cur(), "|"))
  tasks.apply_date(0, 3, "SCHEDULED", due)
  check("date: both kinds", tasks.planning(cur(), 3).deadline.date == "20261016" and tasks.planning(cur(), 3).scheduled.date == "20261015")
  tasks.apply_date(0, 3, "SCHEDULED", nil)
  tasks.apply_date(0, 3, "DEADLINE", nil)
  check("date: remove restores the page", expect(function() end), table.concat(cur(), "|"))
  tasks.apply_date(0, 6, "DEADLINE", due)
  check("date: tab-indented task", cur()[7] == "\t  DEADLINE: <2026-10-15 Thu>", cur()[7])
  tasks.apply_date(0, 6, "DEADLINE", nil)
  check("date: refused on a plain bullet", tasks.apply_date(0, 7, "DEADLINE", due) == false and expect(function() end))
  check("date: not taken from the next block", tasks.planning(cur(), 7).scheduled == nil and tasks.planning(cur(), 8).scheduled.date == "20260801")

  local function d(offset)
    local t = os.date("*t")
    return os.time({ year = t.year, month = t.month, day = t.day + offset, hour = 12 })
  end
  set({
    "- TODO late",
    "  DEADLINE: " .. dates.stamp(d(-2)),
    "- TODO now",
    "  DEADLINE: " .. dates.stamp(d(0)),
    "- TODO later",
    "  SCHEDULED: " .. dates.stamp(d(5)),
    "- TODO started",
    "  SCHEDULED: " .. dates.stamp(d(-3)),
    "- TODO far",
    "  DEADLINE: " .. dates.stamp(d(30)),
    "- DONE old",
    "  DEADLINE: " .. dates.stamp(d(-9)),
    "- TODO undated",
  })
  tasks.refresh(0)
  local groups = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("logseq_tasks"), 0, -1, { details = true })) do
    if m[2] % 2 == 1 then
      groups[#groups + 1] = m[4].hl_group
    end
  end
  check("date highlights", table.concat(groups, ",") == "LogseqOverdue,LogseqDue,LogseqSoon,LogseqDue,LogseqLater,LogseqPlanned", table.concat(groups, ","))
  local dated = tasks.collect({ file = td, closed = true })
  check("collect: dated first, earliest first", bodies(dated) == "started|late|now|later|far|undated|old", bodies(dated))
  local function chip(i)
    local text, hl = tasks.chip(dated[i])
    return (text or "nil") .. "/" .. (hl or "nil")
  end
  check("chip past scheduled is not overdue", chip(1) == "sched 3d ago/LogseqDue", chip(1))
  check("chip overdue", chip(2) == "overdue 2d/LogseqOverdue", chip(2))
  check("chip today", chip(3) == "due today/LogseqDue", chip(3))
  check("chip soon", chip(4) == "sched " .. os.date("%a", d(5)) .. "/LogseqSoon", chip(4))
  check("chip later", chip(5):match("^due %d+ %a+/LogseqLater$") ~= nil, chip(5))
  check("chip none", tasks.chip(dated[6]) == nil)
  check("chip closed is not overdue", select(2, tasks.chip(dated[7])) == "LogseqPlanned")
  local mon = os.time({ year = 2026, month = 10, day = 12, hour = 12 }) -- a Monday
  local function at(deadline, scheduled)
    local due = (deadline and scheduled) and math.min(deadline, scheduled) .. "" or deadline or scheduled
    local text, hl = tasks.chip({ deadline = deadline, scheduled = scheduled, due = due }, mon)
    return text .. "/" .. hl
  end
  check("chip tomorrow", at("20261013") == "due tomorrow/LogseqSoon", at("20261013"))
  check("chip day name", at(nil, "20261018") == "sched Sun/LogseqSoon", at(nil, "20261018"))
  check("chip window edge", at(nil, "20261019") == "sched in 7d/LogseqSoon", at(nil, "20261019"))
  check("chip past the window", at("20261020") == "due 20 Oct/LogseqLater", at("20261020"))
  check("chip scheduled today", at(nil, "20261012") == "sched today/LogseqDue", at(nil, "20261012"))
  check("chip missed deadline beats an older scheduled date", at("20261011", "20261008") == "overdue 1d/LogseqOverdue", at("20261011", "20261008"))
  check("chip earlier date while the deadline is ahead", at("20261030", "20261014") == "sched Wed/LogseqSoon", at("20261030", "20261014"))
  vim.cmd("edit!")
  check("date tests left the file alone", vim.deep_equal(vim.fn.readfile(td), (function()
    local w = vim.deepcopy(td_lines)
    w[6] = "\t- TODO tabbed"
    return w
  end)()))
  check(":Logseq deadline registered", logseq.commands.deadline ~= nil and logseq.commands.scheduled ~= nil)

  -- task filters -------------------------------------------------------------------------
  vim.cmd("silent! %bwipeout!")
  write(root .. "/pages/work.md", { "title:: Work", "alias:: [[Job]]", "", "- TODO on the work page" })
  write(root .. "/pages/tagged.md", { "title:: Tagged", "tags:: [[Work]]", "", "- TODO via page tag", "  DEADLINE: " .. dates.stamp(d(40)) })
  write(root .. "/journals/2026-10-04.md", {
    "- Meeting [[Job]]",
    "  - TODO under a parent",
    "    DEADLINE: " .. dates.stamp(d(-1)),
    "- TODO inline #Work",
    "  SCHEDULED: " .. dates.stamp(d(3)),
    "- TODO hash list #[[Work]]",
    "- TODO unrelated homework #Workshop",
  })
  idx.invalidate()
  local refs = tasks.refs_of("a [[Job]] b #[[Medicine Festival]] (#database) ## heading x#no [[job]]")
  check("refs_of forms and aliases", table.concat(refs, "|") == "Work|Medicine Festival|database", table.concat(refs, "|"))
  local work = tasks.collect({ page = "job" })
  check("filter by page: all four ways", bodies(work) == "under a parent|inline #Work|via page tag|on the work page|hash list #[[Work]]", bodies(work))
  check("filter by page: non-member left out", not bodies(work):find("unrelated", 1, true))
  local soon = tasks.collect({ page = "Work", due_within = 7 })
  check("filter page + due soon", bodies(soon) == "under a parent|inline #Work", bodies(soon))
  check("due soon keeps overdue, drops far and undated", bodies(tasks.collect({ due_within = 7 })) == "under a parent|inline #Work", bodies(tasks.collect({ due_within = 7 })))
  local counts = {}
  for _, p in ipairs(tasks.pages_with_tasks()) do
    counts[p.title] = p.count
  end
  check("pages_with_tasks", counts.Work == 5 and counts.Tagged == 1 and counts.Workshop == 1 and counts["2026-10-04"] == nil, vim.inspect(counts))
  local got
  local orig_picker = tasks.picker
  tasks.picker = function(o)
    got = o
  end
  vim.cmd("Logseq tasks week Medicine Festival")
  check(":Logseq tasks week <page>", got.due == true and got.page == "Medicine Festival", vim.inspect(got))
  vim.cmd("Logseq tasks")
  check(":Logseq tasks without arguments", got.due == nil and got.page == nil)
  tasks.picker = orig_picker
  check(":Logseq tasks completion", vim.tbl_contains(vim.fn.getcompletion("Logseq tasks W", "cmdline"), "Work"))
  check("task picker keys for filters", cfg.options.tasks.keys.filter_page == "<c-l>" and cfg.options.tasks.keys.filter_due == "<c-e>" and cfg.options.tasks.due_days == 7)

  -- references: `#tag` is looked up exactly like `[[link]]` ----------------------------
  vim.cmd("silent! %bwipeout!")
  local links = require("logseq.links")
  local function scanned(line)
    return table.concat(vim.tbl_map(function(r)
      return r.kind .. ":" .. r.name
    end, links.scan(line)), "|")
  end
  check("scan: link and tag", scanned("see [[A B]] and #tag.") == "link:A B|tag:tag", scanned("see [[A B]] and #tag."))
  check("scan: #[[multi word]] is one tag", scanned("#[[Multi Word]] x") == "tag:Multi Word" and links.scan("#[[Multi Word]] x")[1].s == 1 and links.scan("#[[Multi Word]] x")[1].e == 15)
  check("scan: after brackets", scanned("(#paren) [#brk]") == "tag:paren|tag:brk", scanned("(#paren) [#brk]"))
  check("scan: heading markers are not tags", scanned("- ## heading #real") == "tag:real", scanned("- ## heading #real"))
  check("scan: not inside a word", scanned("a#b c https://x.y/#/z") == "")
  check("scan: code spans skipped", scanned("`#code [[no]]` #out") == "tag:out", scanned("`#code [[no]]` #out"))
  check("scan: non-ASCII tag", scanned("#café: done, #über") == "tag:café|tag:über", scanned("#café: done, #über"))
  check("scan: dots inside, not at the end", scanned("#v1.2. next") == "tag:v1.2", scanned("#v1.2. next"))
  check("scan: org directives are not tags", scanned("- #+BEGIN_QUERY") == "")
  check("scan: [[page|label]] refers to page", scanned("x [[work-todos|Work Todos]] y") == "link:work-todos" and links.rewrite("x [[Old|shown]] y", "old", "New") == "x [[New|shown]] y")
  check("at: on the # of #[[..]]", links.at("- x #[[Multi Word]]", 5).name == "Multi Word" and links.at("- x #[[Multi Word]]", 10).name == "Multi Word")
  check("at: tag in brackets", links.at("- (#tag)", 4).name == "tag" and links.at("- (#tag)", 3) == nil)
  check("as_tag", links.as_tag("database") == "#database" and links.as_tag("Two Words") == "#[[Two Words]]" and links.as_tag("café") == "#café")
  check("rewrite: one word", links.rewrite("a #Old, [[old]] #Older #[[Old]] `#Old`", "Old", "New") == "a #New, [[New]] #Older #New `#Old`", links.rewrite("a #Old, [[old]] #Older #[[Old]] `#Old`", "Old", "New"))
  check("rewrite: to several words", links.rewrite("a #Old. [[Old]]", "old", "New Name") == "a #[[New Name]]. [[New Name]]", links.rewrite("a #Old. [[Old]]", "old", "New Name"))

  write(root .. "/journals/2026-10-03.md", {
    "- one #Ghost",
    "- two (#ghost) and [[Phantom Page]] on [[2026-10-16]]",
    "- three #[[Job]] #über #[[Two Words]]",
    "- `#NotATag`",
  })
  idx.invalidate()
  -- the same lookup for each way of writing a reference
  vim.cmd.edit(root .. "/journals/2026-10-03.md")
  local function target(lnum, col)
    vim.api.nvim_win_set_cursor(0, { lnum, col })
    local name = nav.link_at_cursor()
    local e = name and idx.resolve(name)
    return e and e.title or name
  end
  check("follow: #[[alias]] resolves like [[alias]]", target(3, 8) == "Work" and target(3, 10) == "Work", tostring(target(3, 8)))
  check("follow: (#tag)", target(2, 8) == "ghost")
  check("follow: nothing in code", target(4, 4) == nil)
  check("task filter: tag forms resolve", table.concat(tasks.refs_of("(#Job) #[[Two Words]] #über"), "|") == "Work|Two Words|über")
  if vim.fn.executable("rg") == 1 then
    local bl = require("logseq.backlinks")
    local function hits(name)
      local n
      bl.query({ name }, nil, function(entries)
        n = #entries
      end)
      vim.wait(3000, function()
        return n ~= nil
      end)
      return n
    end
    check("backlinks: #tag and (#tag), any case", hits("Ghost") == 2, hits("Ghost"))
    check("backlinks: non-ASCII tag", hits("über") == 1, hits("über"))
    check("backlinks: #[[several words]]", hits("Two Words") == 1, hits("Two Words"))
    check("backlinks: not from code", hits("NotATag") == 0, hits("NotATag"))

    local referenced = {}
    for _, r in ipairs(idx.referenced()) do
      referenced[r.title] = r.count
    end
    check("referenced: tag-only page with count", referenced.Ghost == 2, vim.inspect(referenced))
    check("referenced: link-only page", referenced["Phantom Page"] == 1)
    check("referenced: tags:: value", referenced.Project ~= nil)
    check("referenced: pages with files, dates and code left out", referenced.Work == nil and referenced.Job == nil and referenced["2026-10-16"] == nil and referenced.NotATag == nil)
    by = complete("- #Gh", 5)
    check("completion offers a referenced-only page after #", by["Ghost"] ~= nil)
    by = complete("- [[Phan", 8)
    check("completion offers a referenced-only page after [[", by["Phantom Page"] ~= nil)

    nav.open("Ghost")
    check("page without a file: title", idx.title_of(0) == "Ghost" and vim.api.nvim_buf_get_name(0):match("pages/ghost%.md$") ~= nil)
    bl.refresh(0)
    vim.wait(3000, function()
      return vim.b.logseq_bl ~= nil
    end)
    check("page without a file: linked references", vim.b.logseq_bl and #vim.b.logseq_bl == 2, vim.inspect(vim.b.logseq_bl))
    check("page without a file: nothing written", vim.uv.fs_stat(root .. "/pages/ghost.md") == nil)
    vim.cmd("bwipeout!")
  end

  vim.cmd.edit(root .. "/journals/2026-10-03.md")
  set({ "- #one and #[[Two Words]] and [[link]]", "- ## heading a#b `#code`", "#start" })
  links.refresh(0)
  local spans = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("logseq_links"), 0, -1, { details = true })) do
    spans[#spans + 1] = ("%d:%d-%d:%s"):format(m[2], m[3], m[4].end_col, m[4].hl_group)
  end
  check("tag styling", table.concat(spans, " ") == "0:2-6:LogseqTag 0:11-25:LogseqTag 2:0-6:LogseqTag", table.concat(spans, " "))
  check("LogseqTag highlight defined", vim.fn.hlexists("LogseqTag") == 1)
  vim.cmd("edit!")

  check(":Logseq tasks registered", logseq.commands.tasks ~= nil and logseq.commands.page_tasks ~= nil)
  local mapped = false
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    mapped = mapped or m.desc == "All tasks"
  end
  check("global task map", mapped)
end, debug.traceback)

if not ok then
  fail[#fail + 1] = "ERROR " .. tostring(err)
end
print(("%d passed, %d failed"):format(pass, #fail))
for _, f in ipairs(fail) do
  print("  FAIL " .. f)
end
vim.cmd(#fail == 0 and "qa!" or "cq!")
