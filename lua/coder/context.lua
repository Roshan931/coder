local util = require("coder.util")

local M = {}

local state = nil
local state_path = nil

local function default_state(root)
  return {
    version = 1,
    root = root,
    tasks = {},
    task_order = {},
    suggestions = {},
  }
end

local function save()
  if state_path and state then
    util.write_json(state_path, state)
  end
end

local function truncate(value, max)
  value = value or ""
  max = max or 40000
  if #value <= max then
    return value
  end
  return value:sub(1, max) .. "\n...[truncated]"
end

function M.setup()
  state = nil
  state_path = nil
end

function M.load(root)
  root = root or util.workspace_root()
  local dir = util.path_join({ util.state_dir(), "workspaces", util.workspace_id(root) })
  util.ensure_dir(dir)
  state_path = util.path_join({ dir, "memory.json" })
  state = util.read_json(state_path, default_state(root)) or default_state(root)
  state.version = state.version or 1
  state.root = root
  state.tasks = state.tasks or {}
  state.task_order = state.task_order or {}
  state.suggestions = state.suggestions or {}
  save()
  return state
end

function M.current(root)
  if not state then
    return M.load(root)
  end
  if root and state.root ~= root then
    return M.load(root)
  end
  return state
end

function M.record_task(task)
  local current = M.current(task.root)
  current.tasks[task.id] = {
    id = task.id,
    created_at = task.created_at,
    updated_at = task.updated_at,
    status = task.status,
    kind = task.kind,
    profile = task.profile,
    mode = task.selection and task.selection.mode,
    source = task.selection and task.selection.source,
    file = task.selection and task.selection.relative_file,
    range = task.selection and task.selection.display_range,
    label = task.selection and task.selection.label,
    summary = task.summary,
  }
  table.insert(current.task_order, task.id)
  save()
end

function M.update_task(task)
  local current = M.current(task.root)
  local entry = current.tasks[task.id] or { id = task.id }
  entry.updated_at = task.updated_at or util.now()
  entry.status = task.status
  entry.profile = task.profile
  entry.summary = task.summary
  entry.error = task.error
  entry.patch_files = task.patch_files
  if task.conflict then
    entry.conflict = {
      id = task.conflict.id,
      file = task.conflict.file,
      user_start = task.conflict.user_start,
      user_end = task.conflict.user_end,
    }
  else
    entry.conflict = nil
  end
  entry.conflict_prompt = task.conflict_prompt
  if task.result then
    entry.diff = truncate(task.result.diff, 40000)
    entry.notes = truncate(task.result.notes, 10000)
    entry.raw = truncate(task.result.raw, 60000)
  end
  entry.reviewed_at = task.reviewed_at
  entry.review_status = task.review_status
  current.tasks[task.id] = entry
  save()
end

function M.mark_review(task, review_status)
  task.reviewed_at = util.now()
  task.review_status = review_status
  M.update_task(task)
end

function M.recent(root, limit, profile)
  local current = M.current(root)
  local profile_config = require("coder.config").for_profile(profile)
  limit = limit or profile_config.memory.max_recent_tasks or 20
  local result = {}
  for i = #current.task_order, 1, -1 do
    local task = current.tasks[current.task_order[i]]
    if task then
      table.insert(result, task)
      if #result >= limit then
        break
      end
    end
  end
  return result
end

function M.diagnostics_for_selection(selection)
  local diagnostics = {}
  if not selection or not selection.bufnr or not vim.api.nvim_buf_is_valid(selection.bufnr) then
    return diagnostics
  end

  for _, diagnostic in ipairs(vim.diagnostic.get(selection.bufnr)) do
    if diagnostic.lnum >= selection.range.start_line and diagnostic.lnum <= selection.range.end_line then
      table.insert(diagnostics, {
        line = diagnostic.lnum + 1,
        col = (diagnostic.col or 0) + 1,
        severity = diagnostic.severity,
        message = diagnostic.message,
        source = diagnostic.source,
        code = diagnostic.code,
      })
    end
  end

  return diagnostics
end

function M.imports_for_buffer(bufnr)
  local imports = {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return imports
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, math.min(vim.api.nvim_buf_line_count(bufnr), 120), false)
  for index, line in ipairs(lines) do
    if line:match("^%s*import%s") or line:match("^%s*from%s+[%w_%.]+%s+import") or line:match("require%(") then
      table.insert(imports, { line = index, text = line })
    end
  end
  return imports
end

local ignored_path_parts = {
  [".git"] = true,
  ["node_modules"] = true,
  ["vendor"] = true,
  ["dist"] = true,
  ["build"] = true,
  ["coverage"] = true,
  ["target"] = true,
  [".next"] = true,
  [".turbo"] = true,
  [".cache"] = true,
  ["__pycache__"] = true,
}

local manifest_names = {
  "package.json",
  "tsconfig.json",
  "jsconfig.json",
  "deno.json",
  "deno.jsonc",
  "go.mod",
  "Cargo.toml",
  "pyproject.toml",
  "requirements.txt",
  "pom.xml",
  "build.gradle",
  "settings.gradle",
  "composer.json",
  "Gemfile",
}

local architecture_terms = {
  "model",
  "models",
  "schema",
  "schemas",
  "entity",
  "entities",
  "domain",
  "repository",
  "repositories",
  "service",
  "services",
  "usecase",
  "usecases",
  "controller",
  "controllers",
  "handler",
  "handlers",
  "adapter",
  "adapters",
}

local function should_ignore_file(path)
  for part in path:gmatch("[^/]+") do
    if ignored_path_parts[part] then
      return true
    end
  end
  return false
end

local function extension(path)
  return path:match("%.([^%.%/]+)$") or ""
end

local function list_project_files(root, max_files)
  local files = {}

  if vim.fn.executable("git") == 1 then
    local output = vim.fn.systemlist({ "git", "-C", root, "ls-files" })
    if vim.v.shell_error == 0 then
      for _, file in ipairs(output) do
        if file ~= "" and not should_ignore_file(file) then
          table.insert(files, file)
        end
      end
    end
  end

  if #files == 0 then
    local function walk(dir, prefix)
      if #files >= max_files then
        return
      end
      for name, type_ in vim.fs.dir(dir) do
        local rel = prefix ~= "" and (prefix .. "/" .. name) or name
        if not should_ignore_file(rel) then
          if type_ == "file" then
            table.insert(files, rel)
            if #files >= max_files then
              return
            end
          elseif type_ == "directory" then
            walk(util.path_join({ dir, name }), rel)
          end
        end
      end
    end
    walk(root, "")
  end

  table.sort(files)
  local capped = {}
  for index, file in ipairs(files) do
    if index > max_files then
      break
    end
    table.insert(capped, file)
  end
  return capped, #files
end

local function manifest_snippets(root)
  local snippets = {}
  for _, name in ipairs(manifest_names) do
    local path = util.path_join({ root, name })
    if vim.fn.filereadable(path) == 1 then
      local lines = vim.fn.readfile(path, "", 80)
      table.insert(snippets, {
        file = name,
        text = table.concat(lines, "\n"),
      })
    end
  end
  return snippets
end

local function file_score(selection, file)
  if file == selection.relative_file then
    return -1
  end

  local score = 0
  local selected_dir = vim.fs.dirname(selection.relative_file or "") or ""
  local file_dir = vim.fs.dirname(file) or ""

  if extension(file) ~= "" and extension(file) == extension(selection.relative_file or "") then
    score = score + 8
  end
  if selected_dir ~= "" and file_dir == selected_dir then
    score = score + 7
  end
  for _, term in ipairs(architecture_terms) do
    if file:lower():match(term) then
      score = score + 5
    end
  end

  local label = (selection.label or ""):lower()
  for word in label:gmatch("[%w_]+") do
    if #word >= 4 and file:lower():match(word) then
      score = score + 3
    end
  end

  return score
end

local function interesting_lines(path, max_lines)
  local lines = vim.fn.readfile(path, "", math.max(max_lines * 3, 120))
  local selected = {}
  for index, line in ipairs(lines) do
    local trimmed = util.trim(line)
    if
      trimmed:match("^import%s")
      or trimmed:match("^from%s+[%w_%.]+%s+import")
      or trimmed:match("require%(")
      or trimmed:match("^export%s")
      or trimmed:match("^class%s")
      or trimmed:match("^interface%s")
      or trimmed:match("^type%s")
      or trimmed:match("^struct%s")
      or trimmed:match("^enum%s")
      or trimmed:match("^func%s")
      or trimmed:match("^function%s")
      or trimmed:match("^def%s")
      or trimmed:match("schema")
      or trimmed:match("Schema")
      or trimmed:match("service")
      or trimmed:match("Service")
      or trimmed:match("repository")
      or trimmed:match("Repository")
    then
      table.insert(selected, ("%d: %s"):format(index, line))
      if #selected >= max_lines then
        break
      end
    end
  end
  return table.concat(selected, "\n")
end

local function related_files(selection, files, max_files, max_lines)
  local ranked = {}
  for _, file in ipairs(files) do
    local score = file_score(selection, file)
    if score > 0 then
      table.insert(ranked, { file = file, score = score })
    end
  end
  table.sort(ranked, function(a, b)
    if a.score == b.score then
      return a.file < b.file
    end
    return a.score > b.score
  end)

  local result = {}
  for _, item in ipairs(ranked) do
    if #result >= max_files then
      break
    end
    local path = util.path_join({ selection.root, item.file })
    if vim.fn.filereadable(path) == 1 then
      table.insert(result, {
        file = item.file,
        score = item.score,
        outline = interesting_lines(path, max_lines),
      })
    end
  end
  return result
end

function M.workspace_context(selection, opts)
  opts = opts or {}
  local cfg = require("coder.config").for_profile(opts.profile).architecture or {}
  if cfg.enabled == false then
    return {}
  end

  local max_files = cfg.max_files or 120
  local files, total = list_project_files(selection.root, max_files)
  return {
    style = cfg.style or "clean",
    files = cfg.include_repo_outline ~= false and files or {},
    total_files = total,
    manifests = cfg.include_manifest_snippets ~= false and manifest_snippets(selection.root) or {},
    related_files = cfg.include_related_files ~= false
        and related_files(selection, files, cfg.max_related_files or 10, cfg.max_related_lines or 80)
      or {},
  }
end

function M.task_context(selection, opts)
  opts = opts or {}
  return {
    recent_tasks = M.recent(selection.root, nil, opts.profile),
    diagnostics = M.diagnostics_for_selection(selection),
    imports = M.imports_for_buffer(selection.bufnr),
    workspace = M.workspace_context(selection, opts),
  }
end

function M.add_suggestion(root, key, suggestion)
  local current = M.current(root)
  if current.suggestions[key] then
    return false
  end
  current.suggestions[key] = vim.tbl_extend("force", suggestion, { created_at = util.now() })
  save()
  return true
end

function M.accepted_tasks_for_file(root, relative_file)
  local current = M.current(root)
  local result = {}
  for _, id in ipairs(current.task_order or {}) do
    local task = current.tasks[id]
    if task and task.file == relative_file and task.review_status == "accepted" then
      table.insert(result, task)
    end
  end
  return result
end

return M
