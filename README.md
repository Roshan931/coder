# coder.nvim

Coder is a Neovim plugin for focused AI coding tasks through [OpenCode](https://opencode.ai/). It captures a code scope or directory blueprint, runs the task asynchronously, and returns a unified diff for review instead of interrupting the editing flow.

## Features

- Captures the nearest function, class, type, conditional, or other meaningful parent scope with Treesitter or LSP fallback.
- Captures exact visual and command ranges.
- Turns a directory or selected netrw entries into a capped multi-file blueprint task.
- Runs multiple OpenCode jobs asynchronously with configurable concurrency.
- Provides fast and deep context profiles.
- Reviews multi-file patches before applying them, or optionally auto-applies clean patches.
- Resolves conflicts against edits made while a task was running.
- Stores workspace-scoped task memory under Neovim state.
- Watches LSP diagnostics after accepted AI changes.
- Uses OpenCode's edit-restricted `plan` agent by default.

## Requirements

- Neovim 0.11 or newer.
- OpenCode installed, authenticated, and available on `$PATH`.
- An OpenCode version whose `opencode run --help` includes `--agent`, `--dir`, `--format`, `--title`, and `--variant`. Coder is tested with OpenCode 1.18.20.
- Git is recommended for the fallback used when Coder cannot directly apply a unified diff.
- Treesitter parsers are recommended for the best scope selection.
- LSP is optional and improves symbol fallback and diagnostic tasks.

Run `:checkhealth coder` after installation to verify the local environment.

## Installation

### lazy.nvim

```lua
{
  "mozok-git/coder.nvim",
  opts = {
    keymaps = { enable = true },
  },
}
```

Coder creates commands automatically. Global mappings are disabled by default; the example opts into the mapping preset described below.

### vim.pack

On a Neovim version that provides `vim.pack`:

```lua
vim.pack.add({
  {
    src = "https://github.com/mozok-git/coder.nvim",
    version = vim.version.range("*"),
  },
})

require("coder").setup({
  keymaps = { enable = true },
})
```

### Native packages

```sh
git clone https://github.com/mozok-git/coder.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/coder.nvim
```

Then configure it in `init.lua`:

```lua
require("coder").setup({
  keymaps = { enable = true },
})
```

## Configuration

The default configuration is usable without calling `setup()`. Call it to customize behavior or enable mappings:

```lua
require("coder").setup({
  opencode = {
    command = "opencode",
    timeout_ms = 120000,
    format = "default",
    agent = "plan", -- Read-only built-in agent. Use false to omit --agent.
    model = nil,
    variant = nil,
    attach = nil, -- For example, "http://127.0.0.1:4096".
    pure = false,
    extra_args = {},
  },
  max_concurrent_jobs = 8,
  edits = { mode = "review_patch" }, -- Or "auto_apply".
  answers = { auto_open = true },
  keymaps = { enable = false },
  profiles = {
    default = "fast",
    fast = {
      opencode = { variant = "minimal" },
      memory = { max_recent_tasks = 6 },
      architecture = {
        max_files = 60,
        max_related_files = 4,
        max_related_lines = 35,
      },
      directory = {
        max_files = 60,
        max_file_chars = 6000,
        max_total_chars = 60000,
      },
      prompt = { full_file_max_chars = 20000 },
    },
    deep = {
      opencode = { variant = false },
      memory = { max_recent_tasks = 20 },
      architecture = {
        max_files = 160,
        max_related_files = 12,
        max_related_lines = 100,
      },
      directory = {
        max_files = 220,
        max_file_chars = 20000,
        max_total_chars = 240000,
      },
      prompt = { full_file_max_chars = 100000 },
    },
  },
  architecture = {
    enabled = true,
    style = "clean",
    include_repo_outline = true,
    include_manifest_snippets = true,
    include_related_files = true,
  },
})
```

`setup()` is safe to call again. It preserves queued work, updates Coder-owned mappings, and does not overwrite an existing user mapping.

## Commands

- `:CoderEnqueue [intent]` enqueues the current parent scope or command range.
- `:CoderEnqueueDeep [intent]` uses the deep profile.
- `:CoderEnqueueDirectory [path] [-- intent]` enqueues a directory blueprint.
- `:CoderEnqueueDirectoryDeep [path] [-- intent]` uses deep directory context.
- `:CoderReview` reviews the latest completed result.
- `:CoderStatus` opens or refreshes the task panel.
- `:CoderCancel` cancels the latest queued or running task.
- `:CoderFixDiagnostics` enqueues a task for current-buffer diagnostics.
- `:CoderExplain` summarizes the current scope or command range.
- `:CoderSummarize` aliases `:CoderExplain`.
- `:CoderSummarizeDirectory [path] [-- intent]` summarizes directory architecture.
- `:CoderSummarizeDirectoryDeep [path] [-- intent]` uses the deep profile.

## Mapping preset

Set `keymaps.enable = true` to install these global mappings. Existing mappings are preserved.

- `<leader>aa`: enqueue the scope or visual selection with the fast profile.
- `<leader>ai`: prompt for intent, then enqueue with the fast profile.
- `<leader>aA`: enqueue with the deep profile.
- `<leader>aI`: prompt for intent, then enqueue with the deep profile.
- `<leader>ap`: enqueue the current/netrw directory or selected netrw entries.
- `<leader>aP`: enqueue a directory with the deep profile.
- `<leader>aQ`: summarize a directory or selected netrw entries.
- `<leader>ar`: review the next result.
- `<leader>as`: open task status.
- `<leader>ad`: fix diagnostics.
- `<leader>aq`: summarize a scope or selection.
- `<leader>ac`: cancel the latest task.

Individual mappings accept a string or `false`:

```lua
require("coder").setup({
  keymaps = {
    enable = true,
    enqueue = "<leader>ce",
    directory = false,
  },
})
```

## Directory blueprints

In netrw, place the cursor on a directory or visually select entries, then run `<leader>ap` or `<leader>aP` when the mapping preset is enabled. From command mode:

```vim
:CoderEnqueueDirectoryDeep src/users -- implement the stubs, wire imports, and keep domain models separate from persistence
```

Coder snapshots the selected tree and capped file contents, including empty files, then asks OpenCode for one multi-file unified diff.

## Persistent OpenCode server

Attaching avoids repeated OpenCode startup and MCP cold-start overhead:

```sh
opencode serve --port 4096
```

```lua
require("coder").setup({
  opencode = {
    attach = "http://127.0.0.1:4096",
  },
})
```

Set `opencode.pure = true` to skip external OpenCode plugins for Coder tasks.

## Review and conflicts

Edit tasks request raw unified diffs. With the default `review_patch` mode, press `a` in a review window to apply a patch or `r` to reject it.

If the target changed and a hunk cannot be applied cleanly, Coder opens a focused resolver:

- `1`: keep the current code.
- `2`: use OpenCode's proposed code.
- Add optional guidance in the bottom buffer before choosing to enqueue a focused merge task.

Generated paths are normalized and resolved through existing symlinks before writes. A patch that resolves outside the workspace root is rejected.

## Data and permissions

Coder sends the following prompt context to the OpenCode process and therefore to the model/provider configured in OpenCode:

- The selected code and a capped full-file snapshot.
- Diagnostics and nearby imports.
- A capped repository outline, manifest snippets, and related-file outlines.
- Recent task metadata.
- For directory tasks, capped contents of selected files.

OpenCode runs with the workspace as `--dir` and can use tools according to the user's OpenCode permissions. Coder selects OpenCode's edit-restricted `plan` agent by default and never passes `--auto`. The plan agent may still have shell access, and a user's OpenCode agent configuration can override its permissions; prompts are not a security boundary.

Task metadata, raw model output, and diffs are stored under:

```lua
vim.fn.stdpath("state") .. "/coder"
```

Review provider policy and repository sensitivity before enqueueing code. Generated patches are untrusted input and should be reviewed before acceptance.

## Statusline

```lua
require("coder").statusline()
```

It returns an empty string when no work is active or ready.

## Development

Run the deterministic test suite:

```sh
nvim --headless -u tests/minimal_init.lua -i NONE -c "luafile tests/smoke.lua"
nvim --headless -u NONE -i NONE -c "set runtimepath^=." -c "luafile tests/setup_lifecycle.lua"
nvim --headless -u NONE -i NONE -c "luafile tests/process.lua"
```

CI tests Neovim 0.11, stable, and nightly and verifies formatting with StyLua. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
