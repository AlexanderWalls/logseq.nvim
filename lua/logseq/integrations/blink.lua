-- blink.cmp source: complete `[[` with page TITLES (not filenames) and `#` with titles,
-- aliases and tags.
local source = {}

function source.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = source })
end

function source:enabled()
  return require("logseq").in_graph(0)
end

function source:get_trigger_characters()
  return { "[", "#" }
end

function source:get_completions(ctx, callback)
  local line = ctx.line
  local col = ctx.cursor[2] -- 0-based byte col of cursor
  local before = line:sub(1, col)
  local after = line:sub(col + 1)
  local idx = require("logseq.index")
  local items = {}
  local kinds = vim.lsp.protocol.CompletionItemKind

  local typed = before:match("%[%[([^%[%]]*)$")
  if typed then
    local start = col - #typed
    local has_close = after:sub(1, 2) == "]]"
    local entries = vim.list_extend({}, idx.list())
    for _, r in ipairs(idx.referenced()) do
      entries[#entries + 1] = { title = r.title, aliases = {}, kind = "page" } -- referenced, no file yet
    end
    for _, e in ipairs(entries) do
      local labels = { e.title }
      vim.list_extend(labels, e.aliases)
      for _, label in ipairs(labels) do
        items[#items + 1] = {
          label = label,
          kind = e.kind == "journal" and kinds.Event or kinds.File,
          filterText = label,
          textEdit = {
            newText = has_close and label or (label .. "]]"),
            range = {
              start = { line = ctx.cursor[1] - 1, character = start },
              ["end"] = { line = ctx.cursor[1] - 1, character = col },
            },
          },
        }
      end
    end
  else
    -- a `#` at the start of the line or after a space or bracket, not one inside a word
    local tag = before:match("^#([%w_/%-]*)$") or before:match("[%s%(]#([%w_/%-]*)$")
    if tag then
      -- every page title, alias and `tags::` value; names with a space become `#[[Name]]`
      local start = col - #tag
      local seen = {}
      local function add(name)
        if name == "" or seen[name:lower()] then
          return
        end
        seen[name:lower()] = true
        items[#items + 1] = {
          label = name,
          kind = kinds.Keyword,
          filterText = name,
          textEdit = {
            newText = require("logseq.links").as_tag(name):sub(2),
            range = {
              start = { line = ctx.cursor[1] - 1, character = start },
              ["end"] = { line = ctx.cursor[1] - 1, character = col },
            },
          },
        }
      end
      for _, e in ipairs(idx.list()) do
        if e.kind == "page" then
          add(e.title)
          for _, alias in ipairs(e.aliases) do
            add(alias)
          end
        end
      end
      for _, r in ipairs(idx.referenced()) do
        add(r.title) -- includes `tags::` values and pages that are only referenced so far
      end
    end
  end
  callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
end

return source
