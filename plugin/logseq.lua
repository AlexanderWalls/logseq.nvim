if vim.g.loaded_logseq_nvim then
  return
end
vim.g.loaded_logseq_nvim = true

vim.api.nvim_create_user_command("Logseq", function(a)
  require("logseq").command(a.fargs[1], vim.list_slice(a.fargs, 2))
end, {
  nargs = "+",
  desc = "Logseq graph commands",
  complete = function(lead, line)
    local names
    if line:match("^%s*%S+%s+tasks%s") then
      -- :Logseq tasks [week] [page title]
      names = { "week" }
      for _, p in ipairs(require("logseq.tasks").pages_with_tasks()) do
        names[#names + 1] = p.title
      end
    elseif line:match("^%s*%S+%s+%S+%s") then
      return {}
    else
      names = vim.tbl_keys(require("logseq").commands)
      table.sort(names)
    end
    return vim.tbl_filter(function(n)
      return n:sub(1, #lead):lower() == lead:lower()
    end, names)
  end,
})
