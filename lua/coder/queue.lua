local config = require("coder.config")
local context = require("coder.context")
local opencode = require("coder.opencode")
local patches = require("coder.patches")
local selector = require("coder.selector")
local ui = require("coder.ui")
local util = require("coder.util")

local M = {}

local tasks = {}
local order = {}
local running = 0

local function conflict_text(lines)
  if not lines or #lines == 0 then
    return "<empty>"
  end
  return table.concat(lines, "\n")
end

local function sorted_tasks()
  local result = {}
  for _, id in ipairs(order) do
    table.insert(result, tasks[id])
  end
  return result
end

local function update(task, fields)
  for key, value in pairs(fields or {}) do
    task[key] = value
  end
  task.updated_at = util.now()
  context.update_task(task)
end

local function maybe_start()
  local max = config.options.max_concurrent_jobs or 8
  if running >= max then
    return
  end

  for _, id in ipairs(order) do
    if running >= max then
      return
    end
    local task = tasks[id]
    if task and task.status == "queued" then
      running = running + 1
      update(task, { status = "running" })
      util.notify(("Coder task running [%s]: %s"):format(task.profile or "default", task.selection.label))

      task.handle = opencode.run(task, function(result)
        vim.schedule(function()
          running = math.max(running - 1, 0)
          task.handle = nil
          if task.status == "cancelled" then
            maybe_start()
            return
          end
          if result.code ~= 0 then
            local error_text = util.strip_ansi(result.stderr ~= "" and result.stderr or result.stdout)
            update(task, {
              status = "failed",
              error = util.trim(error_text),
            })
            util.notify("Coder task failed: " .. (task.error or task.id), vim.log.levels.ERROR)
            maybe_start()
            return
          end

          local parsed = patches.parse(result.stdout)
          local has_diff = parsed.diff and parsed.diff ~= ""
          local status
          if has_diff then
            status = "ready"
          elseif task.kind == "explain" then
            status = "answered"
          else
            status = "no_patch"
          end
          update(task, {
            status = status,
            result = parsed,
            summary = parsed.summary,
            patch_files = parsed.files,
          })

          if has_diff then
            if config.options.edits and config.options.edits.mode == "auto_apply" then
              update(task, { status = "applying" })
              util.notify(("Coder patch applying [%s]: %s"):format(task.profile or "default", task.selection.label))
              M.accept(task.id, { auto = true })
            else
              util.notify(("Coder patch ready [%s]: %s"):format(task.profile or "default", task.selection.label))
            end
          else
            local message = task.kind == "explain" and "Coder answer ready: " or "Coder returned no patch: "
            local level = task.kind == "explain" and vim.log.levels.INFO or vim.log.levels.WARN
            util.notify(message .. task.selection.label, level)
            if task.kind == "explain" and (config.options.answers or {}).auto_open ~= false then
              ui.open_review(task, {
                accept = function(selected)
                  M.accept(selected.id)
                end,
                reject = function(selected)
                  M.reject(selected.id)
                end,
              })
            end
          end
          maybe_start()
        end)
      end)
    end
  end
end

local function with_profile(opts, profile)
  return vim.tbl_extend("force", opts or {}, { profile = profile })
end

local function enqueue_selection(selection, opts)
  if not selection then
    util.notify("Coder could not find a scope to enqueue", vim.log.levels.WARN)
    return nil
  end

  opts = opts or {}
  local profile = config.profile_name(opts.profile)
  local task = {
    id = util.id("coder"),
    kind = opts.kind or "edit",
    intent = opts.intent,
    profile = profile,
    selection = selection,
    context = context.task_context(selection, { profile = profile }),
    root = selection.root,
    status = "queued",
    created_at = util.now(),
    updated_at = util.now(),
  }

  tasks[task.id] = task
  table.insert(order, task.id)
  context.record_task(task)
  util.notify(("Coder task queued [%s]: %s"):format(profile, selection.label))
  maybe_start()
  return task
end

function M.enqueue_cursor(opts)
  return enqueue_selection(selector.capture_cursor(), opts or {})
end

function M.enqueue_visual(opts)
  return enqueue_selection(selector.capture_visual(), opts or {})
end

local function directory_intent(selection)
  return table.concat({
    "Implement the selected directory blueprint as a coherent multi-file change.",
    "Treat empty files, stubs, interfaces, function signatures, comments, and high-level architecture notes as the blueprint.",
    "Fill missing implementations, wire imports/exports/references, keep code DRY, and follow the existing project conventions.",
    "If a function/type belongs in a different module, move or create it there and update callsites so the final implementation is clean.",
    "Keep changes scoped to the selected directory unless correct wiring requires touching adjacent project files.",
    "Use LSP/type correctness as a hard constraint.",
    "Target: " .. (selection and selection.relative_file or "selected directory"),
  }, " ")
end

local function enqueue_directory_selection(selection, opts)
  if not selection then
    return nil
  end
  opts = opts or {}
  opts = vim.tbl_extend("force", opts, {
    intent = opts.intent or directory_intent(selection),
    profile = config.profile_name(opts.profile),
  })
  return enqueue_selection(selection, opts)
end

function M.enqueue_directory(path, opts)
  opts = opts or {}
  local profile = config.profile_name(opts.profile)
  local selection = selector.capture_directory(path, { profile = profile })
  return enqueue_directory_selection(selection, vim.tbl_extend("force", opts, { profile = profile }))
end

function M.enqueue_directory_visual(opts)
  opts = opts or {}
  local profile = config.profile_name(opts.profile)
  local selection = selector.capture_directory_visual({ profile = profile })
  return enqueue_directory_selection(selection, vim.tbl_extend("force", opts, { profile = profile }))
end

local function enqueue_with_intent_opts(capture, opts)
  opts = opts or {}
  vim.ui.input({ prompt = "Coder intent: " }, function(input)
    input = util.trim(input or "")
    if input == "" then
      return
    end
    enqueue_selection(capture(), vim.tbl_extend("force", opts, { intent = input }))
  end)
end

function M.enqueue_cursor_deep(opts)
  return M.enqueue_cursor(with_profile(opts, "deep"))
end

function M.enqueue_visual_deep(opts)
  return M.enqueue_visual(with_profile(opts, "deep"))
end

function M.enqueue_directory_deep(path, opts)
  return M.enqueue_directory(path, with_profile(opts, "deep"))
end

function M.enqueue_directory_visual_deep(opts)
  return M.enqueue_directory_visual(with_profile(opts, "deep"))
end

function M.enqueue_cursor_with_intent(opts)
  enqueue_with_intent_opts(selector.capture_cursor, opts)
end

function M.enqueue_visual_with_intent(opts)
  enqueue_with_intent_opts(selector.capture_visual, opts)
end

function M.enqueue_cursor_deep_with_intent(opts)
  enqueue_with_intent_opts(selector.capture_cursor, with_profile(opts, "deep"))
end

function M.enqueue_visual_deep_with_intent(opts)
  enqueue_with_intent_opts(selector.capture_visual, with_profile(opts, "deep"))
end

local function enqueue_directory_with_intent(path, opts)
  opts = opts or {}
  vim.ui.input({ prompt = "Coder directory intent: " }, function(input)
    input = util.trim(input or "")
    if input == "" then
      return
    end
    M.enqueue_directory(path, vim.tbl_extend("force", opts, { intent = input }))
  end)
end

function M.enqueue_directory_with_intent(path, opts)
  enqueue_directory_with_intent(path, opts)
end

function M.enqueue_directory_deep_with_intent(path, opts)
  enqueue_directory_with_intent(path, with_profile(opts, "deep"))
end

function M.enqueue_range(line1, line2, opts)
  return enqueue_selection(selector.capture_range(line1, line2), opts or {})
end

function M.enqueue_diagnostics(opts)
  local diagnostics = vim.diagnostic.get(0)
  if #diagnostics == 0 then
    util.notify("Coder found no diagnostics in the current buffer")
    return nil
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local selected = {}
  for _, diagnostic in ipairs(diagnostics) do
    if diagnostic.lnum == cursor_line then
      table.insert(selected, diagnostic)
    end
  end
  if #selected == 0 then
    selected = diagnostics
  end

  local min_line = selected[1].lnum
  local max_line = selected[1].lnum
  for _, diagnostic in ipairs(selected) do
    min_line = math.min(min_line, diagnostic.lnum)
    max_line = math.max(max_line, diagnostic.lnum)
  end

  local start_line = min_line + 1
  local end_line = max_line + 1
  return M.enqueue_range(
    start_line,
    end_line,
    vim.tbl_extend("force", {
      intent = "Fix the LSP diagnostics in this selected range. Keep the patch minimal and preserve surrounding behavior.",
    }, opts or {})
  )
end

local function explain_opts(opts)
  return vim.tbl_extend("force", {
    kind = "explain",
    intent = "Summarize this implementation in 3-6 concise bullets. Focus on behavior, data flow, side effects, and notable design risks. No fluff. No patch.",
    profile = "fast",
  }, opts or {})
end

function M.explain_cursor(opts)
  return M.enqueue_cursor(explain_opts(opts))
end

function M.explain_visual(opts)
  return M.enqueue_visual(explain_opts(opts))
end

function M.explain_range(line1, line2, opts)
  return M.enqueue_range(line1, line2, explain_opts(opts))
end

function M.explain_directory(path, opts)
  opts = explain_opts(vim.tbl_extend("force", {
    intent = "Summarize this directory architecture in 3-6 concise bullets. Focus on module responsibilities, cross-file data flow, missing implementation risk, and misplaced abstractions. No fluff. No patch.",
  }, opts or {}))
  local profile = config.profile_name(opts.profile)
  local selection = selector.capture_directory(path, { profile = profile })
  if not selection then
    return nil
  end
  opts.profile = profile
  return enqueue_selection(selection, opts)
end

function M.explain_directory_visual(opts)
  opts = explain_opts(vim.tbl_extend("force", {
    intent = "Summarize this directory architecture in 3-6 concise bullets. Focus on module responsibilities, cross-file data flow, missing implementation risk, and misplaced abstractions. No fluff. No patch.",
  }, opts or {}))
  local profile = config.profile_name(opts.profile)
  local selection = selector.capture_directory_visual({ profile = profile })
  if not selection then
    return nil
  end
  opts.profile = profile
  return enqueue_selection(selection, opts)
end

function M.explain_directory_deep(path, opts)
  return M.explain_directory(path, with_profile(opts, "deep"))
end

function M.explain_directory_visual_deep(opts)
  return M.explain_directory_visual(with_profile(opts, "deep"))
end

function M.cancel_current()
  for i = #order, 1, -1 do
    local task = tasks[order[i]]
    if task and (task.status == "queued" or task.status == "running") then
      if task.handle then
        task.handle:kill(15)
      end
      update(task, { status = "cancelled" })
      util.notify("Coder task cancelled: " .. task.id)
      return task
    end
  end
  util.notify("Coder has no queued or running tasks")
  return nil
end

function M.review_next()
  for i = #order, 1, -1 do
    local task = tasks[order[i]]
    if
      task
      and (
        task.status == "ready"
        or task.status == "answered"
        or task.status == "apply_failed"
        or task.status == "no_patch"
        or task.status == "conflict"
      )
    then
      ui.open_review(task, {
        accept = function(selected)
          M.accept(selected.id)
        end,
        reject = function(selected)
          M.reject(selected.id)
        end,
      })
      return task
    end
  end
  util.notify("Coder has no completed task to review")
  return nil
end

local function open_conflict(task, meta)
  task.conflict = meta.conflict
  update(task, {
    status = "conflict",
    conflict = task.conflict,
    error = nil,
  })
  util.notify("Coder conflict: press 1 for your change or 2 for OpenCode", vim.log.levels.WARN)
  ui.open_conflict(task, task.conflict, {
    choose = function(selected_task, conflict, choice, prompt)
      M.resolve_conflict(selected_task.id, conflict.id, choice, prompt)
    end,
  })
end

local function apply_task_patch(task, opts)
  opts = opts or {}
  update(task, { status = "applying" })
  patches.apply(task.root, task.result.diff, {
    selection = task.selection,
    resolutions = task.conflict_resolutions or {},
  }, function(ok, err, meta)
    vim.schedule(function()
      if ok then
        update(task, {
          status = "accepted",
          auto_applied = opts.auto or nil,
          conflict = nil,
          error = nil,
        })
        context.mark_review(task, "accepted")
        util.notify(opts.auto and "Coder patch auto-applied" or "Coder patch applied")
      elseif meta and meta.kind == "conflict" then
        open_conflict(task, meta)
      else
        update(task, { status = "apply_failed", error = err })
        util.notify("Coder patch did not apply: " .. util.trim(err), vim.log.levels.ERROR)
      end
    end)
  end)
end

function M.resolve_conflict(id, conflict_id, choice, prompt)
  local task = tasks[id]
  if not task or not task.result or not task.conflict then
    return
  end

  prompt = util.trim(prompt or "")
  local conflict = task.conflict
  local resolution = choice == "2" and "opencode" or "user"

  if prompt ~= "" then
    local preferred = choice == "2" and "OpenCode" or "your current code"
    local intent = table.concat({
      "Resolve this Coder patch conflict.",
      "Prefer " .. preferred .. " as the starting point, then apply this guidance:",
      prompt,
      "",
      "Conflict file: " .. (conflict.file or ""),
      "",
      "Option 1, current user code:",
      "```",
      conflict_text(conflict.user_lines),
      "```",
      "",
      "Option 2, OpenCode proposed code:",
      "```",
      conflict_text(conflict.opencode_lines),
      "```",
      "",
      "Return a unified diff that resolves the conflict cleanly.",
    }, "\n")

    update(task, {
      status = "conflict_followup",
      conflict_prompt = prompt,
    })
    enqueue_selection(task.selection, { intent = intent, profile = task.profile })
    util.notify("Coder queued conflict follow-up with your prompt")
    return
  end

  task.conflict_resolutions = task.conflict_resolutions or {}
  task.conflict_resolutions[conflict_id] = resolution
  apply_task_patch(task, { auto = true })
end

function M.accept(id, opts)
  local task = tasks[id]
  if not task or not task.result then
    return
  end
  if not task.result.diff or task.result.diff == "" then
    update(task, { status = "accepted" })
    context.mark_review(task, "accepted")
    util.notify("Coder answer accepted")
    return
  end

  apply_task_patch(task, opts or {})
end

function M.reject(id)
  local task = tasks[id]
  if not task then
    return
  end
  update(task, { status = "rejected" })
  context.mark_review(task, "rejected")
  util.notify("Coder task rejected: " .. id)
end

function M.open_status()
  ui.open_status(sorted_tasks(), M.counts())
end

function M.counts()
  local counts = {
    queued = 0,
    running = 0,
    applying = 0,
    conflict = 0,
    ready = 0,
    failed = 0,
  }
  for _, task in pairs(tasks) do
    if task.status == "queued" then
      counts.queued = counts.queued + 1
    elseif task.status == "running" then
      counts.running = counts.running + 1
    elseif task.status == "applying" then
      counts.applying = counts.applying + 1
    elseif task.status == "conflict" then
      counts.conflict = counts.conflict + 1
    elseif task.status == "ready" or task.status == "answered" then
      counts.ready = counts.ready + 1
    elseif task.status == "failed" or task.status == "apply_failed" or task.status == "no_patch" then
      counts.failed = counts.failed + 1
    end
  end
  return counts
end

function M.tasks()
  return sorted_tasks()
end

function M.setup()
  tasks = {}
  order = {}
  running = 0
end

return M
