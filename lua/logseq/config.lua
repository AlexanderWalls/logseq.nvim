local M = {}

M.defaults = {
  -- Graph directory (the folder that contains `pages/`, `journals/` and `logseq/`). Required.
  root = nil,
  -- "auto": read `:pages-directory` / `:journals-directory` from logseq/config.edn, else these names
  pages_dir = "auto",
  journals_dir = "auto",
  -- Journal file name, in Logseq's own `:journal/file-name-format` syntax (yyyy, MM, dd).
  -- "auto": read it from logseq/config.edn; if unset there, detect it from the existing
  -- journal files; if there are none, Logseq's default "yyyy_MM_dd".
  journal_file_format = "auto",
  -- "todo": TODO -> DOING -> DONE.  "now": LATER -> NOW -> DONE.
  -- "auto": read `:preferred-workflow` from logseq/config.edn.
  workflow = "todo",
  -- Filetype given to graph files. Compound so that everything markdown keeps working, while
  -- other plugins (render-markdown, ...) can be configured for the graph only.
  filetype = "markdown.logseq",
  keymaps = {
    enable = true,
    prefix = "<leader>j",
  },
  icons = {
    TODO = "☐",
    LATER = "☐",
    DOING = "◐",
    NOW = "◐",
    WAITING = "⧖",
    DONE = "☑",
    CANCELLED = "✗",
    CANCELED = "✗",
  },
  tasks = {
    -- keys inside the task picker; false leaves one unbound
    keys = { cycle = "<c-x>", toggle_closed = "<c-o>", filter_page = "<c-l>", filter_due = "<c-e>" },
    due_days = 7, -- window of the "due soon" filter, and of the dates coloured as soon
  },
  backlinks = {
    enabled = true, -- show "Linked References" under the page
    width = 110, -- truncate reference text to this many characters
  },
  -- Things that fight with an outline when left on. All scoped to graph buffers.
  buffer = {
    disable_diagnostics = true, -- markdownlint & co. assume prose documents
    disable_autoformat = true, -- LazyVim format-on-save (`vim.b.autoformat`)
    indent = 2,
    wrap = true,
    spell = nil, -- true/false to force 'spell' in graph windows; nil leaves it alone
  },
}

M.options = vim.deepcopy(M.defaults)

--- Minimal reader for the few scalar keys we need from logseq/config.edn.
local function read_edn(root)
  local out = {}
  local f = io.open(root .. "/logseq/config.edn", "r")
  if not f then
    return out
  end
  for line in f:lines() do
    local code = line:gsub(";.*$", "") -- comments
    for key, val in code:gmatch(":([%w%-/%.]+)%s+\"([^\"]*)\"") do
      out[key] = out[key] or val
    end
    for key, val in code:gmatch(":([%w%-/%.]+)%s+:([%w%-]+)") do
      out[key] = out[key] or val
    end
  end
  f:close()
  return out
end

function M.setup(opts)
  local o = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if not o.root or o.root == "" then
    error("logseq.nvim: `root` (path to your graph) is required")
  end
  -- `root` is the canonical (symlink-resolved) path; `roots` also keeps the path as
  -- given, because a buffer may be opened through either one
  local given = vim.fs.normalize(vim.fn.expand(o.root))
  o.root = vim.uv.fs_realpath(given) or given
  o.roots = { o.root }
  if given ~= o.root then
    o.roots[#o.roots + 1] = given
  end

  local edn = read_edn(o.root)
  o.edn = edn
  if o.pages_dir == "auto" then
    o.pages_dir = edn["pages-directory"] or "pages"
  end
  if o.journals_dir == "auto" then
    o.journals_dir = edn["journals-directory"] or "journals"
  end
  if o.workflow == "auto" then
    o.workflow = edn["preferred-workflow"] == "todo" and "todo" or "now"
  end

  local dates = require("logseq.dates")
  o.journal_format_source = "option"
  if o.journal_file_format == "auto" then
    if edn["journal/file-name-format"] then
      o.journal_file_format = edn["journal/file-name-format"]
      o.journal_format_source = "config.edn"
    else
      local detected = dates.detect(o.root .. "/" .. o.journals_dir)
      o.journal_file_format = detected or dates.LOGSEQ_DEFAULT
      o.journal_format_source = detected and "detected" or "default"
    end
  end
  local ok, err = dates.validate(o.journal_file_format)
  if not ok then
    o.journal_format_error = err
    o.journal_file_format = dates.LOGSEQ_DEFAULT
  end

  M.options = o
  return o
end

return M
