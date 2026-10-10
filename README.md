# logseq.nvim

Edit a [Logseq](https://logseq.com) markdown graph in Neovim: outliner editing, title-based
links, inline backlinks, journals and task states. Files stay plain Logseq markdown, so the
graph keeps working in Logseq itself.

It only acts on files inside the graph's `pages/` and `journals/` folders. Other markdown
files are not touched.

This is an independent, community-driven plugin and is not officially affiliated with Logseq or LazyVim.

## Requirements

- Neovim 0.10+
- [ripgrep](https://github.com/BurntSushi/ripgrep) for backlinks and search
- [snacks.nvim](https://github.com/folke/snacks.nvim) for the pickers
- Optional: [blink.cmp](https://github.com/saghen/blink.cmp) for `[[` and `#` completion,
  [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) for rendering

Run `:checkhealth logseq` to see what is missing.

## Install (lazy.nvim / LazyVim)

```lua
return {
  {
    "AlexanderWalls/logseq.nvim", -- or: dir = "~/repos/logseq.nvim"
    lazy = false, -- registers the graph filetype, so it must load before files open
    dependencies = { "folke/snacks.nvim" },
    opts = { root = "~/notes" },
  },

  -- keep the cursor line rendered in graph files
  {
    "MeanderingProgrammer/render-markdown.nvim",
    optional = true,
    ft = { "markdown.logseq" },
    opts = function(_, opts)
      return require("logseq").render_markdown_opts(opts)
    end,
  },

  -- `[[` completes page titles, `#` completes tags
  {
    "saghen/blink.cmp",
    optional = true,
    opts = function(_, opts)
      opts.sources = opts.sources or {}
      opts.sources.providers = opts.sources.providers or {}
      opts.sources.providers.logseq = { name = "Logseq", module = "logseq.integrations.blink", score_offset = 100 }
      local base = opts.sources.default
      opts.sources.default = function(ctx)
        local list = type(base) == "function" and base(ctx) or vim.deepcopy(base or { "lsp", "path", "snippets", "buffer" })
        if require("logseq").in_graph(0) then
          table.insert(list, 1, "logseq")
        end
        return list
      end
    end,
  },
}
```

## Options

```lua
{
  root = nil,                    -- required: the graph folder
  pages_dir = "auto",            -- "auto" reads :pages-directory from logseq/config.edn, else "pages"
  journals_dir = "auto",         -- same for :journals-directory, else "journals"
  journal_file_format = "auto",  -- see below
  workflow = "todo",             -- "todo": TODO/DOING/DONE, "now": LATER/NOW/DONE, "auto": read config.edn
  filetype = "markdown.logseq",
  keymaps = { enable = true, prefix = "<leader>j" },
  icons = { TODO = "☐", LATER = "☐", DOING = "◐", NOW = "◐", WAITING = "⧖", DONE = "☑", CANCELLED = "✗" },
  tasks = {
    keys = { cycle = "<c-x>", toggle_closed = "<c-o>", filter_page = "<c-l>", filter_due = "<c-e>" }, -- in the task picker
    due_days = 7, -- window of the "due soon" filter
  },
  backlinks = { enabled = true, width = 110 },
  buffer = { disable_diagnostics = true, disable_autoformat = true, indent = 2, wrap = true, spell = nil },
}
```

### Journal file names

`journal_file_format` uses Logseq's own `:journal/file-name-format` syntax. Supported tokens
are `yyyy`, `MM` and `dd` with any separators, for example `"yyyy_MM_dd"` or `"yyyy-MM-dd"`.

With `"auto"` the plugin uses, in order: the value in `logseq/config.edn`, the format most
existing journal files use, then Logseq's default `yyyy_MM_dd`. Journals in another known
format are still read, and a day that already has a file never gets a second one.

Logseq only finds journals named the way its own config says. If the two differ,
`:checkhealth logseq` tells you which line to add to `logseq/config.edn`.

## Keys

Global (prefix `<leader>j`):

| Key | Action |
|---|---|
| `f` / `s` | find page by title / search the graph |
| `t` / `y` / `m` | today's / yesterday's / tomorrow's journal |
| `n` / `T` | new page / tags |
| `a` | all open tasks of the graph (see below) |

In graph files:

| Key | Action |
|---|---|
| `<CR>`, `gd` | follow the `[[link]]` or `#tag` under the cursor |
| `[j` / `]j` | previous / next journal |
| `<Tab>` / `<S-Tab>`, `<A-l>` / `<A-h>` | indent / outdent the bullet with its children |
| `<A-j>` / `<A-k>` | move the bullet with its children down / up |
| insert `<CR>`, `o`, `O` | new bullet (a first child when the bullet has children; an empty bullet outdents) |
| `<leader>jx` | cycle the task state |
| `<leader>jA` | tasks belonging to this page, closed ones included |
| `<leader>jd` / `<leader>jD` | set the task's due date / scheduled date |
| `<leader>jb`, `gb` | backlinks picker |
| `<leader>jB` | toggle the inline "Linked References" |
| `<leader>jr` | rename the page (`title::`), optionally rewriting `[[links]]` after confirmation |
| `<leader>jz` | scroll the block to the top |

Every action is also available as `:Logseq <name>` (`today`, `find`, `backlinks`, ...). Set
`keymaps.enable = false` to map them yourself.

## Tasks

`<leader>ja` (or `:Logseq tasks`) lists every open task of the graph in a picker: in-progress
first, then to-do, then waiting; pages before journals, newest journal first.

| Key in the picker | Action |
|---|---|
| `<CR>` | jump to the task |
| `<C-x>` | move the task to its next state in its file; the list stays open |
| `<C-o>` | show / hide DONE and CANCELLED tasks |
| `<C-l>` | choose a page and show only its tasks |
| `<C-e>` | only tasks overdue or dated within the next 7 days |

`<C-x>` saves the file, unless it is open with other unsaved changes; then only the buffer
is changed.

A task belongs to a page when the task itself, one of its parent bullets, the page it is on
or that page's `tags::` mention it. So every task on a page tagged `[[Work]]` is a Work task,
and so is `- TODO ... [[Work]]` in a journal. Three ways to use that:

- type `#work` in the picker,
- `<C-l>` in the picker, or `:Logseq tasks Work` (`:Logseq tasks week Work` adds the due filter),
- `<leader>jA` (`:Logseq page_tasks`) for the page you are on, closed tasks included.

### Dates

`<leader>jd` on a task asks for a due date and writes Logseq's own line under it;
`<leader>jD` does the same for `SCHEDULED:`.

```
- TODO Finalise insurance policies
  DEADLINE: <2026-10-15 Thu>
```

The prompt takes `2026-10-15`, `today`, `tomorrow`, a day name (`fri` is the next Friday),
`+3d` or `+2w`. An empty answer removes the date. On the page the line is red when overdue
and yellow when due today. In the task picker, dated tasks come first within each state,
earliest first, with a `due 15 Oct` / `overdue 3d` label.

## Notes

- Links resolve by `title::`, then `alias::`, then file name. A page needs neither property.
- `#tag` and `#[[Several Words]]` are page links, exactly like `[[tag]]`: same lookup, same
  backlinks, same colour.
- A page that is only referenced so far (a tag nobody has written a page for) still shows in
  the page finder and in completion. Opening it shows its linked references; the file is
  created when you save.
- Backlinks are virtual text. Nothing is written to your files.
- Rename changes the `title::` line only; files are never renamed.
- Tab-indented pages keep their tabs; new indentation uses spaces.

## Tests

```sh
nvim --headless -u NONE -l tests/run.lua
```
