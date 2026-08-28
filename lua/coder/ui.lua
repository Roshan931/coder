local M = {}

local function named_buffer(name)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local current_name = vim.api.nvim_buf_get_name(bufnr)
      if current_name == name or vim.fs.basename(current_name) == name then
        return bufnr
      end
    end
  end
  return nil
end

local function scratch_buffer(name, filetype)
  local bufnr = named_buffer(name)
  if not bufnr then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, name)
  end
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = filetype or ""
  vim.bo[bufnr].modifiable = true
  return bufnr
end

local function open_split(bufnr, width_ratio)
  vim.cmd("botright vertical split")
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.cmd("vertical resize " .. math.max(40, math.floor(vim.o.columns * (width_ratio or 0.45))))
  return vim.api.nvim_get_current_win()
end

local function focus_or_open(bufnr, width_ratio)
  local winid = vim.fn.bufwinid(bufnr)
  if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_set_current_win(winid)
    return winid
  end
  return open_split(bufnr, width_ratio)
end

local function append_block(lines, text)
  text = text or ""
  if text == "" then
    table.insert(lines, "")
    return
  end
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(lines, line)
  end
end

function M.open_status(tasks, counts)
  local cfg = require("coder.config").options
  local bufnr = scratch_buffer("[" .. cfg.ui.status_title .. "]", "coderstatus")
  local lines = {
    "Coder",
    "",
    ("queued: %d  running: %d  applying: %d  conflict: %d  ready: %d  failed: %d"):format(
      counts.queued or 0,
      counts.running or 0,
      counts.applying or 0,
      counts.conflict or 0,
      counts.ready or 0,
      counts.failed or 0
    ),
    "",
  }

  for _, task in ipairs(tasks) do
    table.insert(
      lines,
      ("[%s/%s] %s %s %s"):format(
        task.status,
        task.profile or "default",
        task.id,
        task.selection and task.selection.relative_file or "",
        task.selection and task.selection.label or ""
      )
    )
    if task.summary and task.summary ~= "" then
      table.insert(lines, "  " .. task.summary:gsub("\n", " "))
    end
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  focus_or_open(bufnr, 0.36)
  vim.keymap.set("n", "q", "<cmd>bd<CR>", { buffer = bufnr, silent = true })
end

local function numbered_code_lines(number, title, conflict, lines)
  local result = {
    ("%s %s"):format(number, title),
    "",
    ("file: %s"):format(conflict.file or ""),
    ("lines: %s-%s"):format(conflict.user_start or "?", conflict.user_end or "?"),
    "",
  }

  if not lines or #lines == 0 then
    table.insert(result, "<empty>")
  else
    for index, line in ipairs(lines) do
      table.insert(result, ("%4d  %s"):format((conflict.user_start or 1) + index - 1, line))
    end
  end

  return result
end

local function prompt_text(prompt_bufnr)
  local lines = vim.api.nvim_buf_get_lines(prompt_bufnr, 1, -1, false)
  return table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.open_conflict(task, conflict, callbacks)
  local filetype = task.selection and task.selection.filetype or ""
  vim.cmd("tabnew")

  local left = scratch_buffer("[Coder Conflict " .. task.id .. " 1 Yours]", filetype)
  vim.api.nvim_win_set_buf(0, left)
  vim.api.nvim_buf_set_lines(left, 0, -1, false, numbered_code_lines("1", "YOUR CHANGE", conflict, conflict.user_lines))
  vim.bo[left].modifiable = false

  vim.cmd("rightbelow vertical split")
  local right = scratch_buffer("[Coder Conflict " .. task.id .. " 2 OpenCode]", filetype)
  vim.api.nvim_win_set_buf(0, right)
  vim.api.nvim_buf_set_lines(
    right,
    0,
    -1,
    false,
    numbered_code_lines("2", "OPENCODE", conflict, conflict.opencode_lines)
  )
  vim.bo[right].modifiable = false

  vim.cmd("botright 6split")
  local prompt = scratch_buffer("[Coder Conflict " .. task.id .. " Prompt]", "markdown")
  vim.api.nvim_win_set_buf(0, prompt)
  vim.bo[prompt].modifiable = true
  vim.api.nvim_buf_set_lines(prompt, 0, -1, false, {
    "Optional prompt. Leave empty for immediate 1/2 resolution; type guidance here to enqueue an AI merge task.",
    "",
  })

  local function close_tab()
    pcall(vim.cmd, "tabclose!")
  end

  local function choose(choice)
    local text = prompt_text(prompt)
    close_tab()
    callbacks.choose(task, conflict, choice, text)
  end

  for _, bufnr in ipairs({ left, right, prompt }) do
    vim.keymap.set("n", "1", function()
      choose("1")
    end, { buffer = bufnr, silent = true, desc = "Coder keep your change" })
    vim.keymap.set("n", "2", function()
      choose("2")
    end, { buffer = bufnr, silent = true, desc = "Coder apply OpenCode change" })
    vim.keymap.set("n", "q", function()
      close_tab()
    end, { buffer = bufnr, silent = true, desc = "Coder close conflict resolver" })
  end

  local prompt_win = vim.fn.bufwinid(prompt)
  if prompt_win ~= -1 then
    vim.api.nvim_set_current_win(prompt_win)
  end
end

function M.open_review(task, callbacks)
  local cfg = require("coder.config").options
  local bufnr = scratch_buffer("[" .. cfg.ui.review_title .. " " .. task.id .. "]", "diff")
  local result = task.result or {}
  local lines = {
    "# Coder Review " .. task.id,
    "",
    "file: " .. (task.selection and task.selection.relative_file or ""),
    "scope: " .. (task.selection and task.selection.label or ""),
    "status: " .. task.status,
    "profile: " .. (task.profile or "default"),
    "",
    "Summary:",
  }
  append_block(lines, result.summary or task.summary or "")
  table.insert(lines, "")

  if task.error and task.error ~= "" then
    table.insert(lines, "Error:")
    append_block(lines, task.error)
    table.insert(lines, "")
  end

  if result.notes and result.notes ~= "" then
    table.insert(lines, "Notes:")
    append_block(lines, result.notes)
    table.insert(lines, "")
  end

  table.insert(
    lines,
    task.kind == "explain" and "Keys: a accept answer, r reject, q close" or "Keys: a accept patch, r reject, q close"
  )
  table.insert(lines, "")
  append_block(lines, result.diff or "")

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  local winid = open_split(bufnr, 0.5)

  local function close_review()
    if vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.cmd, "silent! bdelete " .. bufnr)
    end
  end

  vim.keymap.set("n", "a", function()
    callbacks.accept(task)
    close_review()
  end, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "r", function()
    callbacks.reject(task)
    close_review()
  end, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "q", close_review, { buffer = bufnr, silent = true })
end

function M.statusline()
  local ok, queue = pcall(require, "coder.queue")
  if not ok then
    return ""
  end
  local counts = queue.counts()
  local active = (counts.queued or 0) + (counts.running or 0) + (counts.applying or 0)
  local ready = counts.ready or 0
  local conflict = counts.conflict or 0
  if conflict > 0 then
    return ("Coder conflict %d  1:yours 2:opencode"):format(conflict)
  end
  if active == 0 and ready == 0 then
    return ""
  end
  return ("Coder %d/%d"):format(active, ready)
end

return M
