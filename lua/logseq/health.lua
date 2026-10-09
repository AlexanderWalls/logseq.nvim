local M = {}

function M.check()
  local h = vim.health
  h.start("logseq.nvim")
  local logseq = require("logseq")
  if not logseq.did_setup then
    return h.error("setup() has not been called", { "require('logseq').setup({ root = '~/notes' })" })
  end
  local o = require("logseq.config").options
  local dates = require("logseq.dates")

  if vim.fn.isdirectory(o.root) == 1 then
    h.ok("graph: " .. o.root)
  else
    h.error("graph directory does not exist: " .. o.root)
  end
  for _, sub in ipairs({ o.pages_dir, o.journals_dir }) do
    if vim.fn.isdirectory(o.root .. "/" .. sub) == 0 then
      h.warn(("missing directory: %s/%s"):format(o.root, sub))
    end
  end

  if o.journal_format_error then
    h.error(("journal_file_format is invalid (%s); using %s"):format(o.journal_format_error, o.journal_file_format))
  else
    h.ok(("journal file format: %s (%s)"):format(o.journal_file_format, o.journal_format_source))
  end
  local logseq_fmt = o.edn["journal/file-name-format"] or dates.LOGSEQ_DEFAULT
  if logseq_fmt ~= o.journal_file_format then
    h.warn(
      ("Logseq itself expects journals named %s, but this plugin writes %s"):format(logseq_fmt, o.journal_file_format),
      { ('Set  :journal/file-name-format "%s"  in %s/logseq/config.edn'):format(o.journal_file_format, o.root) }
    )
  end

  local pages = require("logseq.index").list()
  local journals, undated = 0, 0
  for _, e in ipairs(pages) do
    if e.kind == "journal" then
      journals = journals + 1
      if not e.date then
        undated = undated + 1
      end
    end
  end
  h.ok(("%d pages, %d journals indexed"):format(#pages - journals, journals))
  if undated > 0 then
    h.warn(("%d journal file(s) are not named as a date; previous/next skips them"):format(undated))
  end

  if vim.fn.executable("rg") == 1 then
    h.ok("ripgrep found (backlinks, search)")
  else
    h.error("ripgrep (rg) not found: backlinks and search will not work")
  end

  if package.loaded["snacks"] or pcall(require, "snacks") then
    h.ok("snacks.nvim found (pickers)")
  else
    h.error("snacks.nvim not found: find/search/tags/backlinks pickers will not work")
  end

  local ok_blink, blink = pcall(require, "blink.cmp.config")
  if not ok_blink then
    h.warn("blink.cmp not found: no `[[` page completion")
  elseif blink.sources.providers.logseq then
    h.ok("blink.cmp source registered")
  else
    h.warn("blink.cmp found but the `logseq` source is not registered", { "See the README for the provider snippet" })
  end

  if not pcall(require, "render-markdown") then
    h.info("render-markdown.nvim not found (optional)")
  elseif require("logseq.integrations.render_markdown").applied then
    h.ok("render-markdown.nvim override for " .. o.filetype .. " is configured")
  else
    h.warn(
      "render-markdown.nvim has no override for " .. o.filetype .. ": the cursor line will show raw markdown",
      { "opts = function(_, opts) return require('logseq').render_markdown_opts(opts) end" }
    )
  end
end

return M
