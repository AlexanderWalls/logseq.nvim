-- Title/alias/slug -> file index of the graph, built by reading the page properties.
local M = {}
local uv = vim.uv
local cache

function M.invalidate()
  cache = nil
end

function M.slugify(title)
  local s = title:lower():gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  return s ~= "" and s or "untitled"
end

local function parse_list(v)
  local out = {}
  local found = false
  for x in v:gmatch("%[%[(.-)%]%]") do
    out[#out + 1] = x
    found = true
  end
  if not found then
    for x in v:gmatch("[^,]+") do
      x = vim.trim(x)
      if x ~= "" then
        out[#out + 1] = x
      end
    end
  end
  return out
end

local function build()
  local o = require("logseq.config").options
  local dates = require("logseq.dates")
  local root = o.root
  local c = { pages = {}, by_key = {}, by_file = {}, tags = {} }
  for _, sub in ipairs({ o.pages_dir, o.journals_dir }) do
    local dir = root .. "/" .. sub
    local is_journal = sub == o.journals_dir
    local handle = uv.fs_scandir(dir)
    while handle do
      local name = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if name:match("%.md$") and not name:match("^%.") then
        local path = dir .. "/" .. name
        local slug = name:gsub("%.md$", "")
        local entry = { title = slug, slug = slug, file = path, kind = is_journal and "journal" or "page", aliases = {}, tags = {} }
        if is_journal then
          -- sort key; files that are not dates still index, after the dated ones
          entry.date = dates.parse_any(o.journal_file_format, slug)
        end
        local f = io.open(path, "r")
        if f then
          for _ = 1, 30 do
            local line = f:read("*l")
            if not line then
              break
            end
            local k, v = line:match("^([%w_-]+):: ?(.*)$")
            if k then
              k = k:lower()
              if k == "title" and vim.trim(v) ~= "" then
                entry.title = vim.trim(v)
              elseif k == "alias" then
                entry.aliases = parse_list(v)
              elseif k == "tags" then
                entry.tags = parse_list(v)
              end
            elseif line:match("^%s*%-") then
              break -- page properties end at the first bullet
            end
          end
          f:close()
        end
        c.pages[#c.pages + 1] = entry
        c.by_file[path] = entry
        for _, t in ipairs(entry.tags) do
          c.tags[t] = (c.tags[t] or 0) + 1
        end
      end
    end
  end
  -- titles and aliases win over slugs
  for _, e in ipairs(c.pages) do
    c.by_key[e.title:lower()] = c.by_key[e.title:lower()] or e
    for _, a in ipairs(e.aliases) do
      c.by_key[a:lower()] = c.by_key[a:lower()] or e
    end
  end
  for _, e in ipairs(c.pages) do
    c.by_key[e.slug:lower()] = c.by_key[e.slug:lower()] or e
  end
  table.sort(c.pages, function(a, b)
    if a.kind ~= b.kind then
      return a.kind == "page"
    end
    if a.kind == "journal" then
      return (a.date or "") .. a.slug > (b.date or "") .. b.slug
    end
    return a.title:lower() < b.title:lower()
  end)
  return c
end

function M.get()
  cache = cache or build()
  return cache
end

function M.resolve(name)
  return M.get().by_key[vim.trim(name):lower()]
end

function M.by_file(path)
  if not path or path == "" then
    return nil
  end
  local c = M.get()
  path = vim.fs.normalize(path)
  return c.by_file[path] or c.by_file[vim.uv.fs_realpath(path) or path]
end

--- Title of the page in a buffer, also for a page that has no file yet.
function M.title_of(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local e = M.by_file(name)
  if e then
    return e.title, e
  end
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, 20, false)) do
    local t = l:match("^title:: ?(.-)%s*$")
    if t and t ~= "" then
      return t
    end
    if l:match("^%s*%-") then
      break
    end
  end
  return vim.fn.fnamemodify(name, ":t:r")
end

--- Pages that are referenced (`[[X]]`, `#X`, `tags::`) but have no file, most referenced
--- first: { { title, count }, ... }. Logseq lists these as pages too.
function M.referenced()
  local c = M.get()
  if c.referenced then
    return c.referenced
  end
  local o = require("logseq.config").options
  local dates = require("logseq.dates")
  local links = require("logseq.links")
  local found, order = {}, {}
  local function add(name)
    local key = name:lower()
    if c.by_key[key] or dates.parse_any(o.journal_file_format, name) then
      return
    end
    if not found[key] then
      found[key] = { title = name, count = 0 }
      order[#order + 1] = found[key]
    end
    found[key].count = found[key].count + 1
  end
  if vim.fn.executable("rg") == 1 then
    local res = vim
      .system({ "rg", "--no-filename", "--no-line-number", "-g", "*.md", "-e", [[\[\[|#]], o.root .. "/" .. o.pages_dir, o.root .. "/" .. o.journals_dir }, { text = true })
      :wait()
    for line in (res.stdout or ""):gmatch("[^\n]+") do
      for _, r in ipairs(links.scan(line)) do
        add(r.name)
      end
    end
  end
  for tag in pairs(c.tags) do
    if not found[tag:lower()] then
      add(tag)
    end
  end
  table.sort(order, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.title:lower() < b.title:lower()
  end)
  c.referenced = order
  return order
end

function M.list()
  return M.get().pages
end

return M
