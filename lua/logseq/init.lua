-- Logseq-style editing for one graph directory. Everything is guarded by `M.in_graph(buf)`;
-- markdown files outside the graph are never touched.
local config = require("logseq.config")

local M = {}

M.did_setup = false

local function win_opts()
  local o = config.options
  local w = { conceallevel = 2, concealcursor = "nc", foldmethod = "indent", foldlevel = 99 }
  if o.buffer.wrap then
    w.wrap = true
    w.breakindent = true
    w.breakindentopt = "shift:" .. o.buffer.indent
  end
  if o.buffer.spell ~= nil then
    w.spell = o.buffer.spell
  end
  return w
end

--- Is this buffer a page or journal of the graph?
function M.in_graph(buf)
  if not M.did_setup then
    return false
  end
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return false
  end
  return M.path_in_graph(vim.api.nvim_buf_get_name(buf))
end

function M.path_in_graph(name)
  if name == "" or not name:match("%.md$") then
    return false
  end
  local o = config.options
  name = vim.fs.normalize(name)
  for _, root in ipairs(o.roots) do
    for _, sub in ipairs({ o.pages_dir, o.journals_dir }) do
      local dir = root .. "/" .. sub .. "/"
      if name:sub(1, #dir) == dir then
        return true
      end
    end
  end
  return false
end

-- Window options are saved and restored, so a window never keeps graph settings once it
-- shows a file from outside the graph.
local function apply_win(win, graph)
  if graph then
    local opts = win_opts()
    if not vim.w[win].logseq_saved then
      local saved = {}
      for k in pairs(opts) do
        saved[k] = vim.wo[win][k]
      end
      vim.w[win].logseq_saved = saved
    end
    for k, v in pairs(opts) do
      vim.wo[win][k] = v
    end
  elseif vim.w[win].logseq_saved then
    for k, v in pairs(vim.w[win].logseq_saved) do
      vim.wo[win][k] = v
    end
    vim.w[win].logseq_saved = nil
  end
end

function M.attach(buf, win)
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local graph = M.in_graph(buf)
  if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
    apply_win(win, graph)
  end
  if not graph then
    return
  end
  local o = config.options
  if not vim.b[buf].logseq_attached then
    vim.b[buf].logseq_attached = true
    local ft = vim.bo[buf].filetype
    if ft == "markdown" or ft == "" then
      -- opened before setup() registered the filetype, or a new file that detection skipped
      vim.bo[buf].filetype = o.filetype
    end
    if o.buffer.disable_autoformat then
      vim.b[buf].autoformat = false
    end
    if o.buffer.disable_diagnostics then
      vim.diagnostic.enable(false, { bufnr = buf })
    end
    require("logseq.edit").attach(buf)
    require("logseq.nav").attach(buf)
    require("logseq.tasks").attach(buf)
    require("logseq.backlinks").attach(buf)
  end
  require("logseq.tasks").refresh(buf)
  require("logseq.links").refresh(buf)
  require("logseq.backlinks").refresh(buf)
end

local function define_hl()
  local function fg(name)
    return vim.api.nvim_get_hl(0, { name = name, link = false }).fg
  end
  local function mix(a, b)
    if not (a and b) then
      return a or b
    end
    local out = 0
    for shift = 16, 0, -8 do
      local x, y = math.floor(a / 2 ^ shift) % 256, math.floor(b / 2 ^ shift) % 256
      out = out * 256 + math.floor((x + y) / 2)
    end
    return out
  end
  local function set(name, val)
    val.default = true
    vim.api.nvim_set_hl(0, name, val)
  end
  set("LogseqTodo", { fg = fg("DiagnosticWarn"), bold = true })
  set("LogseqDoing", { fg = fg("DiagnosticInfo"), bold = true })
  set("LogseqDone", { fg = fg("DiagnosticOk"), bold = true })
  set("LogseqCancelled", { fg = fg("Comment") })
  set("LogseqDoneText", { fg = fg("Comment"), strikethrough = true })
  set("LogseqOverdue", { fg = fg("DiagnosticError"), bold = true })
  set("LogseqDue", { fg = fg("DiagnosticWarn"), bold = true })
  set("LogseqSoon", { fg = fg("DiagnosticHint") })
  -- halfway between the soon colour and the comment grey: quieter, but not the grey of a breadcrumb
  set("LogseqLater", { fg = mix(fg("DiagnosticHint"), fg("Comment")) })
  set("LogseqPlanned", { fg = fg("Comment") })
  -- same colour treesitter gives `[[links]]`, so a `#tag` reads as the link it is
  set("LogseqTag", { fg = fg("@markup.link.label.markdown_inline") or fg("@markup.link.label") or fg("Special") })
  set("LogseqBacklinkHeader", { fg = fg("Title"), bold = true })
  set("LogseqBacklinkPage", { fg = fg("Directory"), bold = true })
  set("LogseqBacklinkCrumb", { fg = fg("Comment"), italic = true })
end

--- Options for render-markdown.nvim that keep the cursor line rendered in graph files only.
--- Use from your lazy spec:  opts = function(_, opts) return require("logseq").render_markdown_opts(opts) end
function M.render_markdown_opts(opts)
  return require("logseq.integrations.render_markdown").opts(opts)
end

function M.setup(opts)
  local o = config.setup(opts)
  M.did_setup = true
  M.root = o.root

  -- Graph files get a compound filetype: still markdown for treesitter/ftplugins, but
  -- addressable on its own by other plugins.
  local patterns = {}
  for _, root in ipairs(o.roots) do
    for _, sub in ipairs({ o.pages_dir, o.journals_dir }) do
      patterns[vim.pesc(root .. "/" .. sub) .. "/.*%.md"] = o.filetype
    end
  end
  vim.filetype.add({ pattern = patterns })

  define_hl()
  local group = vim.api.nvim_create_augroup("Logseq", { clear = true })

  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_hl })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = group,
    callback = function(ev)
      M.attach(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = group,
    callback = function(ev)
      if vim.b[ev.buf].logseq_attached then
        require("logseq.tasks").refresh(ev.buf)
        require("logseq.links").refresh(ev.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      if M.in_graph(ev.buf) then
        require("logseq.index").invalidate()
        require("logseq.backlinks").refresh_visible()
      end
    end,
  })

  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      require("logseq.index").invalidate()
      require("logseq.backlinks").refresh_visible()
    end,
  })

  require("logseq.nav").setup_global()
  require("logseq.tasks").setup_global()

  -- pick up buffers that were opened before setup ran
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if M.in_graph(buf) then
      M.attach(buf, win)
    end
  end
end

-- :Logseq <subcommand> ------------------------------------------------------------------

M.commands = {
  today = function()
    require("logseq.nav").journal(0)
  end,
  yesterday = function()
    require("logseq.nav").journal(-1)
  end,
  tomorrow = function()
    require("logseq.nav").journal(1)
  end,
  find = function()
    require("logseq.nav").find()
  end,
  search = function()
    require("logseq.nav").search()
  end,
  tags = function()
    require("logseq.nav").tags()
  end,
  new = function()
    require("logseq.nav").new()
  end,
  rename = function()
    require("logseq.nav").rename()
  end,
  backlinks = function()
    require("logseq.backlinks").picker()
  end,
  toggle_backlinks = function()
    require("logseq.backlinks").toggle()
  end,
  cycle_task = function()
    require("logseq.tasks").cycle()
  end,
  deadline = function()
    require("logseq.tasks").set_date("DEADLINE")
  end,
  scheduled = function()
    require("logseq.tasks").set_date("SCHEDULED")
  end,
  -- :Logseq tasks [week] [page title]
  tasks = function(args)
    args = vim.deepcopy(args or {})
    local o = {}
    if args[1] and args[1]:lower() == "week" then
      o.due = true
      table.remove(args, 1)
    end
    if #args > 0 then
      o.page = table.concat(args, " ")
    end
    require("logseq.tasks").picker(o)
  end,
  page_tasks = function()
    require("logseq.tasks").page_picker()
  end,
  reindex = function()
    require("logseq.index").invalidate()
    require("logseq.backlinks").refresh_visible()
  end,
}

function M.command(name, args)
  if not M.did_setup then
    return vim.notify("logseq.nvim: call require('logseq').setup({ root = ... }) first", vim.log.levels.ERROR)
  end
  local fn = M.commands[name]
  if not fn then
    return vim.notify("Logseq: unknown command '" .. tostring(name) .. "'", vim.log.levels.ERROR)
  end
  fn(args or {})
end

return M
