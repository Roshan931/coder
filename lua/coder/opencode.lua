local M = {}

local function truncate(value, max)
  value = value or ""
  if not max or max <= 0 or #value <= max then
    return value
  end
  return value:sub(1, max) .. "\n...[truncated]"
end

local function profile_guidance(name)
  if name == "deep" then
    return "Deep profile: use the supplied architecture context and consider clean multi-file boundaries when the intent calls for it."
  end
  return "Fast profile: solve the selected task with the smallest correct patch. Avoid broad exploration unless the intent clearly requires cross-file design."
end

local function is_directory_selection(selection)
  return selection and (selection.mode == "directory" or selection.mode == "file_set")
end

local function response_format_lines(task, profile)
  if task.kind == "explain" then
    return {
      "Response format, exactly:",
      "<CODER_SUMMARY>",
      "- Three to six concise bullets.",
      "- No fluff, no praise, no generic advice.",
      "- Focus on behavior, data flow, side effects, and notable design risks.",
      "</CODER_SUMMARY>",
    }
  end

  if task.kind ~= "explain" and profile.prompt.response_format == "diff_only" then
    return {
      "Response format:",
      "- Return only a unified diff.",
      "- The first output line must be `diff --git ...` unless there is no valid patch.",
      "- Use repo-relative paths with a/ and b/ prefixes.",
      "- Do not wrap the diff in markdown fences.",
      "- Do not include summaries, notes, analysis, explanations, headings, or tag blocks.",
      "- For edit tasks, prefer a concrete non-empty diff whenever the selected code, placeholder, signature, or intent is actionable.",
      "- If no valid patch can be produced, return exactly CODER_NO_PATCH.",
    }
  end

  return {
    "Response format, exactly:",
    "<CODER_SUMMARY>",
    "One to five concise sentences.",
    "</CODER_SUMMARY>",
    "<CODER_DIFF>",
    "Unified diff here. Use repo-relative paths with a/ and b/ prefixes.",
    "</CODER_DIFF>",
    "<CODER_NOTES>",
    "Optional short notes, risks, or test suggestions.",
    "</CODER_NOTES>",
  }
end

local function format_recent_tasks(tasks)
  if not tasks or #tasks == 0 then
    return "- none"
  end
  local lines = {}
  for _, task in ipairs(tasks) do
    table.insert(
      lines,
      ("- [%s] %s %s:%s %s"):format(
        task.status or "unknown",
        task.review_status or "unreviewed",
        task.file or "",
        task.range and task.range.start_line or "?",
        task.summary or task.label or ""
      )
    )
  end
  return table.concat(lines, "\n")
end

local function format_diagnostics(diagnostics)
  if not diagnostics or #diagnostics == 0 then
    return "- none"
  end
  local lines = {}
  for _, diagnostic in ipairs(diagnostics) do
    table.insert(
      lines,
      ("- line %s:%s %s %s"):format(
        diagnostic.line or "?",
        diagnostic.col or "?",
        diagnostic.source or "diagnostic",
        diagnostic.message or ""
      )
    )
  end
  return table.concat(lines, "\n")
end

local function format_imports(imports)
  if not imports or #imports == 0 then
    return "- none"
  end
  local lines = {}
  for _, import in ipairs(imports) do
    table.insert(lines, ("- %s: %s"):format(import.line, import.text))
  end
  return table.concat(lines, "\n")
end

local function format_file_list(files, total)
  if not files or #files == 0 then
    return "- none"
  end
  local lines = {}
  for _, file in ipairs(files) do
    table.insert(lines, "- " .. file)
  end
  if total and total > #files then
    table.insert(lines, ("- ...%d more files omitted"):format(total - #files))
  end
  return table.concat(lines, "\n")
end

local function format_manifests(manifests)
  if not manifests or #manifests == 0 then
    return "- none"
  end
  local lines = {}
  for _, manifest in ipairs(manifests) do
    table.insert(lines, "### " .. manifest.file)
    table.insert(lines, "```")
    table.insert(lines, manifest.text)
    table.insert(lines, "```")
  end
  return table.concat(lines, "\n")
end

local function format_related_files(files)
  if not files or #files == 0 then
    return "- none"
  end
  local lines = {}
  for _, file in ipairs(files) do
    table.insert(lines, "### " .. file.file)
    if file.outline and file.outline ~= "" then
      table.insert(lines, "```")
      table.insert(lines, file.outline)
      table.insert(lines, "```")
    else
      table.insert(lines, "- no high-signal declarations found")
    end
  end
  return table.concat(lines, "\n")
end

function M.build_prompt(task)
  local selection = task.selection
  local ctx = task.context or {}
  local workspace = ctx.workspace or {}
  local profile = require("coder.config").for_profile(task.profile)
  local intent = task.intent
    or "Complete the selected code from the names, type signatures, placeholder comments, surrounding file, diagnostics, and project context. Produce a small, concrete implementation patch."
  local file_snapshot = truncate(selection.file_snapshot, profile.prompt.full_file_max_chars or 60000)
  local response_lines = response_format_lines(task, profile)
  local is_explain = task.kind == "explain"
  local is_directory = is_directory_selection(selection)

  local lines = is_explain
      and {
        "You are OpenCode running inside the Coder Neovim plugin.",
        "",
        "Task rules:",
        "- Do not edit files directly.",
        "- Do not run commands.",
        "- Do not return a patch.",
        is_directory and "- Summarize only the selected directory architecture snapshot."
          or "- Summarize only the selected implementation or parent scope.",
        "- Be terse and specific.",
        "",
      }
    or {
      "You are OpenCode running inside the Coder Neovim plugin.",
      "",
      "Operating rules:",
      "- Do not edit files directly.",
      "- Do not run mutating commands.",
      "- Return a proposed patch for the engineer to review.",
      "- Return one unified diff that may touch multiple files and may create new files.",
      "- Do not inspect unrelated files unless the supplied context is insufficient for a correct patch.",
      "- This is a code completion task, not a requirements review.",
      "- Treat TODOs, placeholder comments, empty bodies, empty interfaces, and incomplete definitions as instructions to implement.",
      "- Do not respond that implementation cannot be inferred when there is a clear placeholder, signature, or nearby comment. Choose the smallest reasonable implementation.",
      "- Treat the selected code as the intent anchor, not as a restriction to one file.",
      "- If clean design requires a model, schema, repository, adapter, service, helper, or module boundary, create or update the right file for that responsibility.",
      "- If the project already has conventions for models, schemas, services, repositories, controllers, handlers, packages, modules, or layers, follow those conventions.",
      "- If no convention exists, choose a small, idiomatic structure for the detected language/framework and wire imports/exports/callsites.",
      "- Keep domain types/entities separate from persistence schemas/adapters when the ecosystem supports that distinction.",
      "- Keep business logic in service/application modules rather than in data model/schema files unless the existing project does otherwise.",
      "- If a persistence mechanism, collection, helper, or support declaration is missing and no stronger architecture is implied, add the minimal local implementation.",
      "- For TypeScript interfaces, convert natural-language field comments into idiomatic camelCase properties.",
      "- For void creation-style functions in isolated files, a module-local in-memory array is a valid minimal implementation.",
      "- Keep the patch as small as possible while preserving clear boundaries and complete wiring.",
      "- Preserve the existing style and architecture.",
      "- Prefer simple, maintainable code over broad rewrites.",
      "- For edit tasks, the response must contain a unified diff. Only explain/question tasks may omit a patch.",
      "",
    }

  if is_directory then
    vim.list_extend(lines, {
      "Directory blueprint rules:",
      "- The selected directory snapshot contains FILE and END FILE markers; those markers are not part of the files.",
      "- Treat empty files, stubs, signatures, interfaces, types, comments, and architecture notes as senior-engineer blueprint input.",
      "- Implement the blueprint across the right modules, not necessarily in the file where a placeholder appears.",
      "- Move misplaced responsibilities into cleaner modules when needed and wire imports/exports/callsites.",
      "- Keep changes scoped to the target directory unless correct integration requires adjacent project files.",
      "- Prefer cohesive module boundaries, DRY helpers, and LSP/type-correct references over literal placeholder placement.",
      "",
    })
  end

  vim.list_extend(lines, response_lines)
  vim.list_extend(lines, {
    "",
    "Task intent:",
    intent,
    "",
    "Task kind:",
    task.kind or "edit",
    "",
    "Coder profile:",
    profile.name,
    "",
    "Profile guidance:",
    profile_guidance(profile.name),
    "",
    "Workspace root:",
    selection.root,
    "",
    is_directory and "Target path:" or "Target file:",
    selection.relative_file,
    "",
    "Selection mode:",
    selection.mode .. " / " .. selection.source,
    "",
    "Selected range:",
    ("%s:%s-%s:%s"):format(
      selection.display_range.start_line,
      selection.display_range.start_col,
      selection.display_range.end_line,
      selection.display_range.end_col
    ),
    "",
    is_directory and "Directory blueprint snapshot:" or "Selected code:",
    "```" .. (selection.filetype or ""),
    selection.text,
    "```",
  })

  if not is_directory then
    vim.list_extend(lines, {
      "",
      "Full file snapshot at enqueue time:",
      "```" .. (selection.filetype or ""),
      file_snapshot,
      "```",
    })
  end

  vim.list_extend(lines, {
    "",
    "Relevant imports/requires near the top of the file:",
    format_imports(ctx.imports),
    "",
    "Diagnostics inside the selected range:",
    format_diagnostics(ctx.diagnostics),
    "",
    "Recent Coder workspace memory:",
    format_recent_tasks(ctx.recent_tasks),
    "",
    "Architecture style:",
    workspace.style or "clean",
    "",
    "Project file outline:",
    format_file_list(workspace.files, workspace.total_files),
    "",
    "Project manifest snippets:",
    format_manifests(workspace.manifests),
    "",
    "Related file outlines:",
    format_related_files(workspace.related_files),
    "",
  })

  return table.concat(lines, "\n")
end

function M.command_for(task, prompt)
  local opencode = require("coder.config").for_profile(task.profile).opencode
  local cmd = { opencode.command or "opencode", "run" }

  if opencode.format then
    table.insert(cmd, "--format")
    table.insert(cmd, opencode.format)
  end
  if opencode.pure then
    table.insert(cmd, "--pure")
  end
  if opencode.model then
    table.insert(cmd, "--model")
    table.insert(cmd, opencode.model)
  end
  if opencode.agent then
    table.insert(cmd, "--agent")
    table.insert(cmd, opencode.agent)
  end
  if type(opencode.variant) == "string" and opencode.variant ~= "" then
    table.insert(cmd, "--variant")
    table.insert(cmd, opencode.variant)
  end
  if type(opencode.attach) == "string" and opencode.attach ~= "" then
    table.insert(cmd, "--attach")
    table.insert(cmd, opencode.attach)
  end

  table.insert(cmd, "--dir")
  table.insert(cmd, task.root)
  table.insert(cmd, "--title")
  table.insert(cmd, "Coder " .. task.id)

  for _, arg in ipairs(opencode.extra_args or {}) do
    table.insert(cmd, arg)
  end

  table.insert(cmd, prompt)
  return cmd
end

function M.run(task, on_exit)
  local prompt = M.build_prompt(task)
  local cmd = M.command_for(task, prompt)
  local cfg = require("coder.config").options
  local timeout_ms = cfg.opencode.timeout_ms or 120000
  local killed = false

  local handle
  local timer = vim.loop.new_timer()
  timer:start(timeout_ms, 0, function()
    killed = true
    if handle then
      handle:kill(15)
    end
  end)

  local ok, system_handle = pcall(vim.system, cmd, {
    cwd = task.root,
    text = true,
  }, function(result)
    timer:stop()
    timer:close()
    if killed then
      on_exit({
        code = -1,
        stdout = result.stdout or "",
        stderr = "OpenCode timed out after " .. tostring(timeout_ms) .. "ms",
      })
      return
    end
    on_exit({
      code = result.code,
      stdout = result.stdout or "",
      stderr = result.stderr or "",
    })
  end)

  if not ok then
    timer:stop()
    timer:close()
    on_exit({
      code = -1,
      stdout = "",
      stderr = tostring(system_handle),
    })
    return nil
  end

  handle = system_handle
  return handle
end

return M
