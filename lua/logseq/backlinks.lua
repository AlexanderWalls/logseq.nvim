-- "Linked References": async ripgrep over the graph, shown as virtual lines under the
-- page. Nothing is ever written to the files.
local idx = require("logseq.index")
local M = {}

local ns = vim.api.nvim_create_namespace("logseq_backlinks")
local seq = {}
local timers = {}

M.enabled = nil -- nil: follow config until toggled

local function opts()
  return require("logseq.config").options
end

local function enabled()
  if M.enabled == nil then
    return opts().backlinks.enabled
  end
  return M.enabled
end

local function matches(line, names)
  local want = {}
  for _, n in ipairs(names) do
    want[n:lower()] = true
  end
  for _, r in ipairs(require("logseq.links").scan(line)) do
    if want[r.name:lower()] then
      return true
    end
  end
  return false
end

local function breadcrumb(lines, lnum)
  local line = lines[lnum]
  local ind = #line:match("^(%s*)")
  if not line:match("^%s*%-") then
    return nil, line -- page-level property line
  end
  local crumbs = {}
  for i = lnum - 1, 1, -1 do
    local l = lines[i]
    if l:match("^%s*%-") then
      local li = #l:match("^(%s*)")
      if li < ind then
        table.insert(crumbs, 1, (l:gsub("^%s*%-%s*", "")))
        ind = li
        if li == 0 then
          break
        end
      end
    end
  end
  return #crumbs > 0 and table.concat(crumbs, " › ") or nil, line
end
M.breadcrumb = breadcrumb

--- names: titles/aliases to look for. exclude_file: skip references from that file.
function M.query(names, exclude_file, cb)
  local o = opts()
  local root = o.root
  if exclude_file then
    exclude_file = vim.fs.normalize(exclude_file)
    exclude_file = vim.uv.fs_realpath(exclude_file) or exclude_file
  end
  local args = { "rg", "-n", "--no-heading", "-i", "-F", "-g", "*.md" }
  for _, n in ipairs(names) do
    vim.list_extend(args, { "-e", "[[" .. n .. "]]" })
    if not n:find("%s") then
      vim.list_extend(args, { "-e", "#" .. n })
    end
  end
  vim.list_extend(args, { root .. "/" .. o.pages_dir, root .. "/" .. o.journals_dir })
  if vim.fn.executable("rg") == 0 then
    if not M._warned then
      M._warned = true
      vim.notify("logseq.nvim: ripgrep (rg) not found; backlinks are disabled", vim.log.levels.WARN)
    end
    return cb({})
  end
  vim.system(args, { text = true }, function(res)
    vim.schedule(function()
      local entries, files = {}, {}
      for out in (res.stdout or ""):gmatch("[^\n]+") do
        local file, lnum, text = out:match("^(.-):(%d+):(.*)$")
        if file and file ~= exclude_file and matches(text, names) then
          if not files[file] then
            files[file] = vim.fn.readfile(file)
          end
          local crumb, line = breadcrumb(files[file], tonumber(lnum))
          local page = idx.by_file(file)
          entries[#entries + 1] = {
            file = file,
            lnum = tonumber(lnum),
            page = page and page.title or vim.fn.fnamemodify(file, ":t:r"),
            journal = page and page.kind == "journal" or false,
            crumb = crumb,
            text = (line or text):gsub("^%s*%-%s*", ""),
          }
        end
      end
      table.sort(entries, function(a, b)
        if a.journal ~= b.journal then
          return not a.journal
        end
        if a.page ~= b.page then
          if a.journal then
            return a.page > b.page
          end
          return a.page:lower() < b.page:lower()
        end
        return a.lnum < b.lnum
      end)
      cb(entries)
    end)
  end)
end

--- titles/aliases of the page in a buffer; works for a page that has no file yet
local function names_for(buf)
  local title, e = idx.title_of(buf)
  if not title or title == "" then
    return nil
  end
  local names = { title }
  vim.list_extend(names, e and e.aliases or {})
  return names, e
end

local function render(buf, entries)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if not enabled() or #entries == 0 then
    return
  end
  local width = opts().backlinks.width
  local function cut(s)
    s = s:gsub("%s+", " ")
    if vim.fn.strchars(s) > width then
      s = vim.fn.strcharpart(s, 0, width - 1) .. "…"
    end
    return s
  end
  local virt = {
    { { "", "Normal" } },
    { { ("↩ Linked References (%d)"):format(#entries), "LogseqBacklinkHeader" } },
  }
  local last
  for _, en in ipairs(entries) do
    if en.page ~= last then
      last = en.page
      virt[#virt + 1] = { { "  " .. en.page, "LogseqBacklinkPage" } }
    end
    local line = { { "    • ", "Comment" } }
    if en.crumb then
      line[#line + 1] = { cut(en.crumb) .. " › ", "LogseqBacklinkCrumb" }
    end
    line[#line + 1] = { cut(en.text), "Normal" }
    virt[#virt + 1] = line
  end
  local last_row = math.max(vim.api.nvim_buf_line_count(buf) - 1, 0)
  vim.api.nvim_buf_set_extmark(buf, ns, last_row, 0, { virt_lines = virt })
end

function M.refresh(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) or not vim.b[buf].logseq_attached then
    return
  end
  if not enabled() then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    return
  end
  if timers[buf] then
    timers[buf]:stop()
  end
  timers[buf] = vim.defer_fn(function()
    timers[buf] = nil
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local file = vim.api.nvim_buf_get_name(buf)
    local names = names_for(buf)
    if not names then
      return
    end
    seq[buf] = (seq[buf] or 0) + 1
    local my = seq[buf]
    M.query(names, file, function(entries)
      if seq[buf] == my then
        vim.b[buf].logseq_bl = entries
        render(buf, entries)
      end
    end)
  end, 80)
end

function M.refresh_visible()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    M.refresh(vim.api.nvim_win_get_buf(win))
  end
end

function M.toggle()
  M.enabled = not enabled()
  M.refresh_visible()
  if not M.enabled then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      end
    end
  end
  vim.notify("Inline backlinks " .. (M.enabled and "on" or "off"), vim.log.levels.INFO, { title = "Logseq" })
end

function M.picker_for(names, exclude_file, title)
  M.query(names, exclude_file, function(entries)
    if #entries == 0 then
      return vim.notify("No references", vim.log.levels.INFO, { title = "Logseq" })
    end
    local items = {}
    for _, en in ipairs(entries) do
      items[#items + 1] = {
        text = en.page .. " " .. en.text,
        file = en.file,
        pos = { en.lnum, 0 },
        page = en.page,
        body = en.text,
        crumb = en.crumb,
      }
    end
    Snacks.picker.pick({
      title = title or "Linked References",
      items = items,
      format = function(item)
        local r = { { item.page, "LogseqBacklinkPage" }, { "  " } }
        if item.crumb then
          r[#r + 1] = { item.crumb .. " › ", "LogseqBacklinkCrumb" }
        end
        r[#r + 1] = { item.body }
        return r
      end,
      preview = "file",
    })
  end)
end

function M.picker()
  local file = vim.api.nvim_buf_get_name(0)
  local names = require("logseq").in_graph(0) and names_for(0) or nil
  if not names then
    return vim.notify("Not a graph page", vim.log.levels.WARN, { title = "Logseq" })
  end
  M.picker_for(names, file, "Linked References: " .. names[1])
end

function M.attach(buf)
  local km = opts().keymaps
  if not km.enable then
    return
  end
  vim.keymap.set("n", km.prefix .. "b", M.picker, { buffer = buf, desc = "Backlinks" })
  vim.keymap.set("n", "gb", M.picker, { buffer = buf, desc = "Backlinks" })
  vim.keymap.set("n", km.prefix .. "B", M.toggle, { buffer = buf, desc = "Toggle inline backlinks" })
end

return M
