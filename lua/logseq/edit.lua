-- Outline editing for graph buffers: block-aware move/indent, auto-bullets, 2-space indent.
local M = {}

local function opts()
  return require("logseq.config").options
end

local function indent_of(l)
  return #l:match("^(%s*)")
end

local function is_bullet(l)
  return l:match("^%s*%-%s") ~= nil or l:match("^%s*%-$") ~= nil
end

--- 1-based start/end/indent of the block (bullet + all deeper lines) containing lnum
local function block_range(lines, lnum)
  local s = lnum
  while s > 1 and not is_bullet(lines[s]) do
    s = s - 1
  end
  if not is_bullet(lines[s]) then
    return nil
  end
  local ind = indent_of(lines[s])
  local e = s
  while e < #lines do
    local nx = lines[e + 1]
    if nx:match("^%s*$") or indent_of(nx) <= ind then
      break
    end
    e = e + 1
  end
  return s, e, ind
end

function M.move(dir)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local s, e, ind = block_range(lines, row)
  if not s then
    return
  end
  if dir > 0 then
    local n = lines[e + 1]
    if not n or not is_bullet(n) or indent_of(n) ~= ind then
      return
    end
    local _, e2 = block_range(lines, e + 1)
    local new = vim.list_extend(vim.list_slice(lines, e + 1, e2), vim.list_slice(lines, s, e))
    vim.api.nvim_buf_set_lines(0, s - 1, e2, false, new)
    vim.api.nvim_win_set_cursor(0, { row + (e2 - e), col })
  else
    local p = s - 1
    while p >= 1 and not lines[p]:match("^%s*$") and (indent_of(lines[p]) > ind or not is_bullet(lines[p])) do
      p = p - 1
    end
    if p < 1 or not is_bullet(lines[p]) or indent_of(lines[p]) ~= ind then
      return
    end
    local new = vim.list_extend(vim.list_slice(lines, s, e), vim.list_slice(lines, p, s - 1))
    vim.api.nvim_buf_set_lines(0, p - 1, e, false, new)
    vim.api.nvim_win_set_cursor(0, { row - (s - p), col })
  end
end

--- indent unit: tab if the block is already tab-indented (older pages), else spaces
local function unit_for(line)
  return line:match("^\t") and "\t" or (" "):rep(opts().buffer.indent)
end

--- Indent (dir = 1) or outdent (dir = -1) the bullet under the cursor with its children.
function M.shift(dir)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local s, e = block_range(lines, row)
  if not s then
    return
  end
  local unit = unit_for(lines[s])
  if dir > 0 then
    -- Logseq only indents under a previous sibling; a first child cannot go deeper
    local prev = s - 1
    while prev >= 1 and not is_bullet(lines[prev]) do
      prev = prev - 1
    end
    if prev < 1 or indent_of(lines[prev]) < indent_of(lines[s]) then
      return
    end
  end
  local out = {}
  for i = s, e do
    local l = lines[i]
    if dir > 0 then
      out[#out + 1] = l == "" and l or (unit .. l)
    else
      if l ~= "" and l:sub(1, #unit) ~= unit then
        return -- already at top level
      end
      out[#out + 1] = l:sub(#unit + 1)
    end
  end
  vim.api.nvim_buf_set_lines(0, s - 1, e, false, out)
  vim.api.nvim_win_set_cursor(0, { row, math.max(0, col + #unit * dir) })
end

--- Scroll so the current block sits at the top-left of the window.
function M.hoist()
  vim.cmd("normal! ^ztzs")
end

-- auto-bullets ---------------------------------------------------------------------------

--- Prefix for a new bullet after line `row`: a first child when the block has children
--- (as Logseq does), otherwise a sibling.
local function next_prefix(row, lines)
  local line = lines[row]
  local indent = line:match("^(%s*)%- ") or line:match("^(%s*)%-$")
  if not indent then
    return nil
  end
  local nx = lines[row + 1]
  if nx and is_bullet(nx) and indent_of(nx) > #indent then
    return nx:match("^(%s*)") .. "- "
  end
  return indent .. "- "
end

local function set_line_and_cursor(row, text, col)
  vim.api.nvim_buf_set_lines(0, row - 1, row, false, { text })
  vim.api.nvim_win_set_cursor(0, { row, col })
end

--- Insert-mode <CR>. Returns true when it handled the key.
function M.newline()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local line = lines[row]
  local indent = line:match("^(%s*)%- ?$")
  if indent then
    -- empty bullet: outdent it, or remove it at the top level
    if #indent > 0 then
      local unit = unit_for(line)
      local new = (indent:sub(1, #unit) == unit and indent:sub(#unit + 1) or "") .. "- "
      set_line_and_cursor(row, new, #new)
    else
      set_line_and_cursor(row, "", 0)
    end
    return true
  end
  local own = line:match("^(%s*%- )")
  if not own or col < #own then
    return false -- not on a bullet (continuation/property line), or cursor before the text
  end
  local head, tail = line:sub(1, col), line:sub(col + 1)
  -- splitting mid-line makes a sibling; at the end of a parent it makes a first child
  local prefix = tail == "" and next_prefix(row, lines) or own
  vim.api.nvim_buf_set_lines(0, row - 1, row, false, { head, prefix .. tail })
  vim.api.nvim_win_set_cursor(0, { row + 1, #prefix })
  return true
end

--- Normal-mode o / O
function M.open_line(above)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local line = lines[row]
  local own = line:match("^(%s*)%- ") or line:match("^(%s*)%-$")
  if not own then
    return false
  end
  local prefix, at
  if above then
    prefix, at = own .. "- ", row - 1
  else
    prefix, at = next_prefix(row, lines), row
  end
  vim.api.nvim_buf_set_lines(0, at, at, false, { prefix })
  vim.api.nvim_win_set_cursor(0, { at + 1, #prefix })
  vim.cmd("startinsert!")
  return true
end

function M.attach(buf)
  local o = opts()
  local bo = vim.bo[buf]
  bo.expandtab = true
  bo.shiftwidth = o.buffer.indent
  bo.tabstop = o.buffer.indent
  bo.softtabstop = o.buffer.indent
  bo.fixendofline = false -- don't add a trailing newline to files that lack one

  if not o.keymaps.enable then
    return
  end
  local function map(mode, lhs, fn, desc, extra)
    vim.keymap.set(mode, lhs, fn, vim.tbl_extend("force", { buffer = buf, desc = desc }, extra or {}))
  end
  local ni = { "n", "i" }
  map(ni, "<A-j>", function()
    M.move(1)
  end, "Move block down")
  map(ni, "<A-k>", function()
    M.move(-1)
  end, "Move block up")
  map(ni, "<A-l>", function()
    M.shift(1)
  end, "Indent block")
  map(ni, "<A-h>", function()
    M.shift(-1)
  end, "Outdent block")
  map("n", "<Tab>", function()
    M.shift(1)
  end, "Indent block")
  map("n", "<S-Tab>", function()
    M.shift(-1)
  end, "Outdent block")
  map("n", o.keymaps.prefix .. "z", M.hoist, "Scroll block to top")

  map("i", "<CR>", function()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local line = vim.api.nvim_get_current_line()
    local own = line:match("^(%s*%- )")
    if line:match("^%s*%- ?$") or (own and col >= #own) then
      -- <Cmd> runs right here in the key sequence (an expr mapping may not edit the
      -- buffer itself), so fast typing, macros and pastes stay in order
      return "<C-g>u<Cmd>lua require('logseq.edit').newline()<CR>"
    end
    return "<CR>"
  end, "New bullet", { expr = true })
  map("n", "o", function()
    if not M.open_line(false) then
      vim.api.nvim_feedkeys("o", "in", false)
    end
  end, "New bullet below")
  map("n", "O", function()
    if not M.open_line(true) then
      vim.api.nvim_feedkeys("O", "in", false)
    end
  end, "New bullet above")
end

return M
