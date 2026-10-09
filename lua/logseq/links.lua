-- The one place that knows what a page reference looks like: `[[Page]]`, `#[[Page]]` and
-- `#tag`. Following, backlinks, task filters, rename and styling all go through `scan`,
-- so a tag is looked up exactly like a link.
local M = {}
local ns = vim.api.nvim_create_namespace("logseq_links")

-- characters that end a `#tag`
local TAG = "[^%s#%[%]%(%){}<>\"'`,;!%?]+"

local function blank(s)
  return (" "):rep(#s)
end

--- Every reference on a line: { name, s, e, kind = "link" | "tag" }, `s`/`e` are 1-based
--- byte columns of the whole reference (brackets and `#` included), in line order.
--- `[[page|shown text]]` refers to `page`; the `|shown text` part is kept in `label`.
function M.scan(line)
  local out = {}
  if not (line:find("[[", 1, true) or line:find("#", 1, true)) then
    return out
  end
  local text = line:gsub("`[^`]*`", blank) -- nothing inside `code` is a reference
  for s, name, e in text:gmatch("()%[%[(.-)%]%]()") do
    local kind = "link"
    if s > 1 and text:sub(s - 1, s - 1) == "#" and (s == 2 or text:sub(s - 2, s - 2):match("[%s%(%[{]")) then
      s, kind = s - 1, "tag"
    end
    local label
    name, label = name:match("^([^|]*)(.*)$")
    name = vim.trim(name)
    if name ~= "" then
      out[#out + 1] = { name = name, s = s, e = e - 1, kind = kind, label = label ~= "" and label or nil }
    end
  end
  text = text:gsub("#?%[%[.-%]%]", blank)
  for s, name in text:gmatch("()#(" .. TAG .. ")") do
    local before = s > 1 and text:sub(s - 1, s - 1) or " "
    name = name:gsub("[%.:]+$", "") -- sentence punctuation is not part of the tag
    -- `#+BEGIN_QUERY` and friends are org directives, not tags
    if name ~= "" and name:sub(1, 1) ~= "+" and before:match("[%s%(%[{]") then
      out[#out + 1] = { name = name, s = s, e = s + #name, kind = "tag" }
    end
  end
  table.sort(out, function(a, b)
    return a.s < b.s
  end)
  return out
end

--- The reference under a 1-based byte column, or nil.
function M.at(line, col)
  for _, r in ipairs(M.scan(line)) do
    if col >= r.s and col <= r.e then
      return r
    end
  end
end

--- How a page name is written as a tag: `#word` or `#[[Several Words]]`.
function M.as_tag(name)
  if name:match("^" .. TAG .. "$") and not name:match("[%.:]$") then
    return "#" .. name
  end
  return "#[[" .. name .. "]]"
end

--- Rewrite every reference to `old` (case-insensitive) on a line so it points to `new`.
function M.rewrite(line, old, new)
  local refs = M.scan(line)
  for i = #refs, 1, -1 do
    local r = refs[i]
    if r.name:lower() == old:lower() then
      local repl = (r.kind == "tag" and not r.label) and M.as_tag(new) or ("[[" .. new .. (r.label or "") .. "]]")
      if r.kind == "tag" and r.label then
        repl = "#" .. repl
      end
      line = line:sub(1, r.s - 1) .. repl .. line:sub(r.e + 1)
    end
  end
  return line
end

--- Draw `#tags` like links (render-markdown already does that for `[[links]]`).
function M.refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    for _, r in ipairs(M.scan(line)) do
      if r.kind == "tag" then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, r.s - 1, { end_col = r.e, hl_group = "LogseqTag" })
      end
    end
  end
end

return M
