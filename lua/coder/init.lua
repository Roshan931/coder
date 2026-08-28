local config = require("coder.config")
local context = require("coder.context")
local lsp_watch = require("coder.lsp_watch")
local queue = require("coder.queue")
local util = require("coder.util")

local M = {}

local did_setup = false
local installed_keymaps = {}

local function parse_path_and_intent(args)
  args = vim.trim(args or "")
  if args == "" then
    return nil, nil
  end
  local current_path_intent = args:match("^%-%-%s+(.+)$")
  if current_path_intent then
    return nil, vim.trim(current_path_intent)
  end

  local path, intent = args:match("^(.-)%s+%-%-%s+(.+)$")
  if intent then
    path = vim.trim(path or "")
    return path ~= "" and path or nil, vim.trim(intent)
  end

  return args, nil
end

local function create_commands()
  vim.api.nvim_create_user_command("CoderEnqueue", function(opts)
    if opts.range and opts.range > 0 then
      queue.enqueue_range(opts.line1, opts.line2, { intent = opts.args ~= "" and opts.args or nil })
    else
      queue.enqueue_cursor({ intent = opts.args ~= "" and opts.args or nil })
    end
  end, {
    nargs = "*",
    range = true,
    desc = "Enqueue the current Coder scope or selected range",
  })

  vim.api.nvim_create_user_command("CoderEnqueueDeep", function(opts)
    local task_opts = {
      intent = opts.args ~= "" and opts.args or nil,
      profile = "deep",
    }
    if opts.range and opts.range > 0 then
      queue.enqueue_range(opts.line1, opts.line2, task_opts)
    else
      queue.enqueue_cursor(task_opts)
    end
  end, {
    nargs = "*",
    range = true,
    desc = "Enqueue the current Coder scope or selected range with deep context",
  })

  vim.api.nvim_create_user_command("CoderEnqueueDirectory", function(opts)
    local path, intent = parse_path_and_intent(opts.args)
    queue.enqueue_directory(path, { intent = intent })
  end, {
    nargs = "*",
    complete = "file",
    desc = "Enqueue a directory or netrw cursor path as a Coder blueprint task",
  })

  vim.api.nvim_create_user_command("CoderEnqueueDirectoryDeep", function(opts)
    local path, intent = parse_path_and_intent(opts.args)
    queue.enqueue_directory_deep(path, { intent = intent })
  end, {
    nargs = "*",
    complete = "file",
    desc = "Enqueue a directory or netrw cursor path as a deep Coder blueprint task",
  })

  vim.api.nvim_create_user_command("CoderReview", function()
    queue.review_next()
  end, { desc = "Review the latest completed Coder task" })

  vim.api.nvim_create_user_command("CoderStatus", function()
    queue.open_status()
  end, { desc = "Open Coder task status" })

  vim.api.nvim_create_user_command("CoderCancel", function()
    queue.cancel_current()
  end, { desc = "Cancel the latest queued or running Coder task" })

  vim.api.nvim_create_user_command("CoderFixDiagnostics", function()
    queue.enqueue_diagnostics()
  end, { desc = "Enqueue a Coder task for current buffer diagnostics" })

  local function explain(opts)
    if opts.range and opts.range > 0 then
      queue.explain_range(opts.line1, opts.line2)
    else
      queue.explain_cursor()
    end
  end

  vim.api.nvim_create_user_command("CoderExplain", explain, {
    range = true,
    desc = "Ask Coder for a terse summary of the current scope or range",
  })

  vim.api.nvim_create_user_command("CoderSummarize", explain, {
    range = true,
    desc = "Ask Coder for a terse summary of the current scope or range",
  })

  vim.api.nvim_create_user_command("CoderSummarizeDirectory", function(opts)
    local path, intent = parse_path_and_intent(opts.args)
    queue.explain_directory(path, { intent = intent })
  end, {
    nargs = "*",
    complete = "file",
    desc = "Ask Coder for a terse summary of a directory or netrw cursor path",
  })

  vim.api.nvim_create_user_command("CoderSummarizeDirectoryDeep", function(opts)
    local path, intent = parse_path_and_intent(opts.args)
    queue.explain_directory_deep(path, { intent = intent })
  end, {
    nargs = "*",
    complete = "file",
    desc = "Ask Coder for a deep summary of a directory or netrw cursor path",
  })
end

local function map_details(mode, lhs)
  local details = vim.fn.maparg(lhs, mode, false, true)
  return type(details) == "table" and details or {}
end

local function remove_keymaps()
  for _, mapping in ipairs(installed_keymaps) do
    local current = map_details(mapping.mode, mapping.lhs)
    if current.desc == mapping.desc then
      pcall(vim.keymap.del, mapping.mode, mapping.lhs)
    end
  end
  installed_keymaps = {}
end

local function set_keymap(mode, lhs, rhs, opts)
  if not lhs or lhs == false then
    return
  end

  if next(map_details(mode, lhs)) ~= nil then
    util.notify(("Coder did not replace existing %s mapping: %s"):format(mode, lhs), vim.log.levels.WARN)
    return
  end

  vim.keymap.set(mode, lhs, rhs, opts)
  table.insert(installed_keymaps, {
    mode = mode,
    lhs = lhs,
    desc = opts.desc,
  })
end

local function create_keymaps()
  local maps = config.options.keymaps
  if not maps or maps.enable == false then
    return
  end

  if maps.enqueue then
    set_keymap("n", maps.enqueue, function()
      queue.enqueue_cursor()
    end, { desc = "Coder enqueue parent scope fast" })

    set_keymap("x", maps.enqueue, [[:<C-U>lua require("coder").enqueue_visual()<CR>]], {
      desc = "Coder enqueue visual selection fast",
      silent = true,
    })
  end

  if maps.enqueue_deep then
    set_keymap("n", maps.enqueue_deep, function()
      queue.enqueue_cursor_deep()
    end, { desc = "Coder enqueue parent scope deep" })

    set_keymap("x", maps.enqueue_deep, [[:<C-U>lua require("coder").enqueue_visual_deep()<CR>]], {
      desc = "Coder enqueue visual selection deep",
      silent = true,
    })
  end

  if maps.enqueue_with_intent then
    set_keymap("n", maps.enqueue_with_intent, function()
      queue.enqueue_cursor_with_intent()
    end, { desc = "Coder enqueue parent scope fast with intent" })

    set_keymap("x", maps.enqueue_with_intent, [[:<C-U>lua require("coder").enqueue_visual_with_intent()<CR>]], {
      desc = "Coder enqueue visual selection fast with intent",
      silent = true,
    })
  end

  if maps.enqueue_deep_with_intent then
    set_keymap("n", maps.enqueue_deep_with_intent, function()
      queue.enqueue_cursor_deep_with_intent()
    end, { desc = "Coder enqueue parent scope deep with intent" })

    set_keymap(
      "x",
      maps.enqueue_deep_with_intent,
      [[:<C-U>lua require("coder").enqueue_visual_deep_with_intent()<CR>]],
      {
        desc = "Coder enqueue visual selection deep with intent",
        silent = true,
      }
    )
  end

  if maps.directory then
    set_keymap("n", maps.directory, function()
      queue.enqueue_directory()
    end, { desc = "Coder enqueue current/netrw directory fast" })

    set_keymap("x", maps.directory, [[:<C-U>lua require("coder").enqueue_directory_visual()<CR>]], {
      desc = "Coder enqueue selected netrw entries fast",
      silent = true,
    })
  end

  if maps.directory_deep then
    set_keymap("n", maps.directory_deep, function()
      queue.enqueue_directory_deep()
    end, { desc = "Coder enqueue current/netrw directory deep" })

    set_keymap("x", maps.directory_deep, [[:<C-U>lua require("coder").enqueue_directory_visual_deep()<CR>]], {
      desc = "Coder enqueue selected netrw entries deep",
      silent = true,
    })
  end

  if maps.directory_summary then
    set_keymap("n", maps.directory_summary, function()
      queue.explain_directory()
    end, { desc = "Coder summarize current/netrw directory" })

    set_keymap("x", maps.directory_summary, [[:<C-U>lua require("coder").explain_directory_visual()<CR>]], {
      desc = "Coder summarize selected netrw entries",
      silent = true,
    })
  end

  if maps.review then
    set_keymap("n", maps.review, function()
      queue.review_next()
    end, { desc = "Coder review next task" })
  end

  if maps.status then
    set_keymap("n", maps.status, function()
      queue.open_status()
    end, { desc = "Coder task status" })
  end

  if maps.diagnostics then
    set_keymap("n", maps.diagnostics, function()
      queue.enqueue_diagnostics()
    end, { desc = "Coder fix diagnostics" })
  end

  if maps.explain then
    set_keymap("n", maps.explain, function()
      queue.explain_cursor()
    end, { desc = "Coder summarize current scope" })

    set_keymap("x", maps.explain, [[:<C-U>lua require("coder").explain_visual()<CR>]], {
      desc = "Coder summarize visual selection",
      silent = true,
    })
  end

  if maps.cancel then
    set_keymap("n", maps.cancel, function()
      queue.cancel_current()
    end, { desc = "Coder cancel task" })
  end
end

function M.setup(opts)
  config.setup(opts)

  if not did_setup then
    context.setup()
    queue.setup()
    lsp_watch.setup()
    create_commands()
    did_setup = true
  end

  remove_keymaps()
  create_keymaps()
end

function M.is_setup()
  return did_setup
end

function M.enqueue_cursor(opts)
  return queue.enqueue_cursor(opts)
end

function M.enqueue_visual(opts)
  return queue.enqueue_visual(opts)
end

function M.enqueue_cursor_deep(opts)
  return queue.enqueue_cursor_deep(opts)
end

function M.enqueue_visual_deep(opts)
  return queue.enqueue_visual_deep(opts)
end

function M.enqueue_directory(path, opts)
  return queue.enqueue_directory(path, opts)
end

function M.enqueue_directory_deep(path, opts)
  return queue.enqueue_directory_deep(path, opts)
end

function M.enqueue_directory_visual(opts)
  return queue.enqueue_directory_visual(opts)
end

function M.enqueue_directory_visual_deep(opts)
  return queue.enqueue_directory_visual_deep(opts)
end

function M.enqueue_cursor_with_intent(opts)
  return queue.enqueue_cursor_with_intent(opts)
end

function M.enqueue_visual_with_intent(opts)
  return queue.enqueue_visual_with_intent(opts)
end

function M.enqueue_cursor_deep_with_intent(opts)
  return queue.enqueue_cursor_deep_with_intent(opts)
end

function M.enqueue_visual_deep_with_intent(opts)
  return queue.enqueue_visual_deep_with_intent(opts)
end

function M.explain_cursor(opts)
  return queue.explain_cursor(opts)
end

function M.explain_visual(opts)
  return queue.explain_visual(opts)
end

function M.explain_directory(path, opts)
  return queue.explain_directory(path, opts)
end

function M.explain_directory_deep(path, opts)
  return queue.explain_directory_deep(path, opts)
end

function M.explain_directory_visual(opts)
  return queue.explain_directory_visual(opts)
end

function M.explain_directory_visual_deep(opts)
  return queue.explain_directory_visual_deep(opts)
end

function M.review()
  return queue.review_next()
end

function M.status()
  return queue.open_status()
end

function M.statusline()
  return require("coder.ui").statusline()
end

return M
