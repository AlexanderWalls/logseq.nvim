-- render-markdown.nvim, configured through its documented options only: the graph filetype
-- is added to `file_types` and gets its own `overrides.filetype` entry. Nothing here touches
-- render-markdown at runtime, and plain markdown buffers keep the user's settings.
local M = {}

M.applied = false -- for :checkhealth

function M.opts(opts)
  opts = opts or {}
  M.applied = true
  local ft = require("logseq.config").options.filetype

  local types = opts.file_types or { "markdown" }
  if not vim.tbl_contains(types, ft) then
    types = vim.list_extend(vim.deepcopy(types), { ft })
  end
  opts.file_types = types

  opts.overrides = opts.overrides or {}
  opts.overrides.filetype = opts.overrides.filetype or {}
  opts.overrides.filetype[ft] = vim.tbl_deep_extend("force", {
    -- keep the line under the cursor rendered (icons, links) instead of showing raw markup
    anti_conceal = { enabled = false },
    win_options = {
      -- 2, not 3: level 3 also hides replacement characters, which blanks the task icons
      conceallevel = { rendered = 2 },
      -- conceal the cursor line in normal mode; insert mode still shows the raw text
      concealcursor = { rendered = "nc" },
    },
  }, opts.overrides.filetype[ft] or {})
  return opts
end

return M
