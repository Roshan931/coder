local util = require("coder.util")

local M = {}

local function tag(output, name)
  local pattern = "<" .. name .. ">(.-)</" .. name .. ">"
  return util.trim((output or ""):match(pattern) or "")
end

local function fenced_diff(output)
  local diff = (output or ""):match("```diff%s*(.-)```")
  if diff then
    return util.trim(diff)
  end
  return nil
end

local function raw_diff(output)
  local lines = vim.split(output or "", "\n", { plain = true })
  local start = nil
  for index, line in ipairs(lines) do
    if line:match("^diff %-%-git ") or line:match("^%-%-%- ") then
      start = index
      break
    end
  end
  if not start then
    return ""
  end
  return util.trim(table.concat(vim.list_slice(lines, start), "\n"))
end

function M.parse(output)
  output = util.strip_ansi(output or "")
  local summary = tag(output, "CODER_SUMMARY")
  local diff = tag(output, "CODER_DIFF")
  local notes = tag(output, "CODER_NOTES")

  if diff == "" then
    diff = fenced_diff(output) or raw_diff(output)
  end
  local files = M.touched_files(diff)
  if summary == "" then
    if diff ~= "" then
      if #files > 0 then
        summary = "Patch touches " .. table.concat(files, ", ")
      else
        summary = "Patch ready"
      end
    else
      summary = util.trim((output:match("^(.-)\n%s*diff %-%-git") or output):sub(1, 1200))
    end
  end

  return {
    summary = summary,
    diff = diff,
    notes = notes,
    raw = output,
    files = files,
  }
end

function M.touched_files(diff)
  local seen = {}
  local files = {}
  for line in (diff or ""):gmatch("[^\n]+") do
    local file = line:match("^diff %-%-git a/(.-) b/") or line:match("^%+%+%+ b/(.+)") or line:match("^%-%-%- a/(.+)")
    if file and file ~= "/dev/null" and not seen[file] then
      seen[file] = true
      table.insert(files, file)
    end
  end
  return files
end

local function clean_diff_path(path)
  path = util.trim(path or "")
  path = path:gsub("^a/", ""):gsub("^b/", "")
  if path:sub(1, 2) == [["]] and path:sub(-1) == [["]] then
    path = path:sub(2, -2)
  end
  return path
end

local function parse_unified(diff)
  local files = {}
  local current_file = nil
  local current_hunk = nil

  for _, line in ipairs(vim.split(diff or "", "\n", { plain = true })) do
    local diff_path = line:match("^diff %-%-git a/.- b/(.+)")
    if diff_path then
      current_file = {
        path = clean_diff_path(diff_path),
        old_path = clean_diff_path(line:match("^diff %-%-git a/(.-) b/") or ""),
        is_new = false,
        is_delete = false,
        hunks = {},
      }
      table.insert(files, current_file)
      current_hunk = nil
    else
      local old_path = line:match("^%-%-%-%s+a/(.+)") or line:match("^%-%-%-%s+(.+)")
      if old_path and current_file then
        current_file.old_path = clean_diff_path(old_path)
        current_file.is_new = old_path == "/dev/null"
      end
      local new_path = line:match("^%+%+%+%s+b/(.+)") or line:match("^%+%+%+%s+(.+)")
      if new_path and current_file and new_path == "/dev/null" then
        current_file.is_delete = true
      elseif new_path and new_path ~= "/dev/null" then
        local cleaned = clean_diff_path(new_path)
        if not current_file or current_file.path ~= cleaned then
          current_file = {
            path = cleaned,
            old_path = "",
            is_new = false,
            is_delete = false,
            hunks = {},
          }
          table.insert(files, current_file)
        else
          current_file.path = cleaned
        end
        current_hunk = nil
      elseif current_file then
        local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
        if old_start then
          current_hunk = {
            index = #current_file.hunks + 1,
            old_start = tonumber(old_start),
            old_count = tonumber(old_count ~= "" and old_count or "1"),
            new_start = tonumber(new_start),
            new_count = tonumber(new_count ~= "" and new_count or "1"),
            old_lines = {},
            new_lines = {},
          }
          table.insert(current_file.hunks, current_hunk)
        elseif current_hunk then
          local prefix = line:sub(1, 1)
          local body = line:sub(2)
          if prefix == " " then
            table.insert(current_hunk.old_lines, body)
            table.insert(current_hunk.new_lines, body)
          elseif prefix == "-" then
            table.insert(current_hunk.old_lines, body)
          elseif prefix == "+" then
            table.insert(current_hunk.new_lines, body)
          end
        end
      end
    end
  end

  return files
end

local function line_lists_match(lines, start_index, old_lines)
  if #old_lines == 0 then
    return true
  end
  if start_index < 1 or start_index + #old_lines - 1 > #lines then
    return false
  end
  for index, old_line in ipairs(old_lines) do
    if lines[start_index + index - 1] ~= old_line then
      return false
    end
  end
  return true
end

local function find_old_lines(lines, old_lines, expected)
  expected = math.max(1, math.min(expected or 1, #lines + 1))
  if #old_lines == 0 then
    return expected
  end

  for radius = 0, 8 do
    local before = expected - radius
    if line_lists_match(lines, before, old_lines) then
      return before
    end
    local after = expected + radius
    if after ~= before and line_lists_match(lines, after, old_lines) then
      return after
    end
  end

  for index = 1, math.max(#lines - #old_lines + 1, 1) do
    if line_lists_match(lines, index, old_lines) then
      return index
    end
  end

  return nil
end

local function hunk_conflict_id(file, hunk)
  return ("%s:%s:%s"):format(file.path or "", hunk.old_start or 0, hunk.index or 0)
end

local function slice(lines, start_index, end_index)
  local result = {}
  start_index = math.max(start_index or 1, 1)
  end_index = math.min(end_index or #lines, #lines)
  if end_index < start_index then
    return result
  end
  for index = start_index, end_index do
    table.insert(result, lines[index])
  end
  return result
end

local function find_line_near(lines, needle, expected, min_index)
  if not needle or needle == "" then
    return nil
  end

  expected = math.max(1, math.min(expected or 1, #lines))
  min_index = min_index or 1

  for radius = 0, 20 do
    local before = expected - radius
    if before >= min_index and lines[before] == needle then
      return before
    end

    local after = expected + radius
    if after ~= before and after >= min_index and after <= #lines and lines[after] == needle then
      return after
    end
  end

  for index = min_index, #lines do
    if lines[index] == needle then
      return index
    end
  end

  return nil
end

local function conflict_span(current, hunk, expected)
  local old_len = #hunk.old_lines
  local fallback_start = math.max(1, math.min(expected or 1, #current + 1))
  if old_len == 0 then
    return fallback_start, fallback_start - 1
  end

  local first_old = hunk.old_lines[1]
  local last_old = hunk.old_lines[old_len]
  local start_index = find_line_near(current, first_old, fallback_start) or fallback_start
  local fallback_end = math.min(#current, start_index + old_len - 1)
  local anchored_end = find_line_near(current, last_old, fallback_start + old_len - 1, start_index)

  return start_index, anchored_end or fallback_end
end

local function build_conflict(file, hunk, current, expected, bufnr, path)
  local start_index, user_end = conflict_span(current, hunk, expected)
  local user_lines = slice(current, start_index, user_end)

  return {
    id = hunk_conflict_id(file, hunk),
    file = file.path,
    path = path,
    bufnr = bufnr,
    hunk_index = hunk.index,
    old_start = hunk.old_start,
    expected_start = expected,
    user_start = start_index,
    user_end = user_end,
    base_lines = vim.deepcopy(hunk.old_lines),
    user_lines = user_lines,
    opencode_lines = vim.deepcopy(hunk.new_lines),
  }
end

local function apply_hunks_to_lines(lines, file, hunks, opts)
  local offset = 0
  local current = vim.deepcopy(lines)
  local resolutions = opts and opts.resolutions or {}

  for _, hunk in ipairs(hunks) do
    local expected = (hunk.old_start or 1) + offset
    local start_index = find_old_lines(current, hunk.old_lines, expected)
    if not start_index then
      local conflict = build_conflict(file, hunk, current, expected, opts and opts.bufnr, opts and opts.path)
      local resolution = resolutions[conflict.id]
      if not resolution then
        return nil, "conflict", conflict
      end

      local replacement = resolution == "opencode" and hunk.new_lines or conflict.user_lines
      for _ = 1, #conflict.user_lines do
        table.remove(current, conflict.user_start)
      end
      for index, line in ipairs(replacement) do
        table.insert(current, conflict.user_start + index - 1, line)
      end

      offset = offset + #replacement - #hunk.old_lines
    else
      for _ = 1, #hunk.old_lines do
        table.remove(current, start_index)
      end
      for index, new_line in ipairs(hunk.new_lines) do
        table.insert(current, start_index + index - 1, new_line)
      end

      offset = offset + #hunk.new_lines - #hunk.old_lines
    end
  end

  return current, nil
end

local function absolute_path(root, relative)
  if relative:sub(1, 1) == "/" then
    return relative
  end
  return util.path_join({ root, relative })
end

local function is_within(root, path)
  return vim.fs.relpath(root, path) ~= nil
end

local function resolve_existing_ancestor(path)
  local probe = path
  local suffix = {}

  while not vim.uv.fs_lstat(probe) do
    local parent = vim.fs.dirname(probe)
    if not parent or parent == probe then
      return nil
    end
    table.insert(suffix, 1, vim.fs.basename(probe))
    probe = parent
  end

  local resolved = vim.uv.fs_realpath(probe)
  if not resolved then
    return nil
  end
  for _, part in ipairs(suffix) do
    resolved = util.path_join({ resolved, part })
  end
  return vim.fs.normalize(resolved)
end

local function safe_absolute_path(root, relative)
  local path = vim.fs.normalize(absolute_path(root, relative))
  local normalized_root = vim.fs.normalize(root)
  if not is_within(normalized_root, path) then
    return nil, "diff path escapes workspace root: " .. relative
  end

  local real_root = vim.uv.fs_realpath(normalized_root)
  local resolved_path = resolve_existing_ancestor(path)
  if not real_root or not resolved_path then
    return nil, "could not resolve diff path safely: " .. relative
  end
  real_root = vim.fs.normalize(real_root)
  if not is_within(real_root, resolved_path) then
    return nil, "diff path resolves outside workspace root: " .. relative
  end

  return path, nil
end

local function buffer_for_file(root, file, opts)
  local target, target_err = safe_absolute_path(root, file)
  if not target then
    if target_err then
      return nil
    end
    return nil
  end
  local selection = opts and opts.selection
  if selection and selection.bufnr and vim.api.nvim_buf_is_valid(selection.bufnr) then
    local selected_name = vim.api.nvim_buf_get_name(selection.bufnr)
    if selected_name ~= "" and vim.fs.normalize(selected_name) == target then
      return selection.bufnr
    end
    if selection.relative_file == file then
      return selection.bufnr
    end
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and vim.fs.normalize(name) == target then
        return bufnr
      end
    end
  end

  return nil
end

function M.apply_unified(root, diff, opts)
  local parsed_files = parse_unified(diff)
  if #parsed_files == 0 then
    return false, "no unified diff hunks found"
  end

  local plan = {}

  for _, file in ipairs(parsed_files) do
    if not file.path or file.path == "" or #file.hunks == 0 then
      return false, "diff did not include applyable hunks"
    end

    local bufnr = buffer_for_file(root, file.path, opts)
    if bufnr then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local next_lines, err, conflict = apply_hunks_to_lines(
        lines,
        file,
        file.hunks,
        vim.tbl_extend("force", opts or {}, {
          bufnr = bufnr,
          path = vim.api.nvim_buf_get_name(bufnr),
        })
      )
      if not next_lines then
        if err == "conflict" then
          return false,
            "conflict",
            {
              kind = "conflict",
              conflict = conflict,
              conflicts = { conflict },
            }
        end
        return false, err
      end
      table.insert(plan, {
        kind = "buffer",
        bufnr = bufnr,
        file = file,
        next_lines = next_lines,
      })
    else
      local path, path_err = safe_absolute_path(root, file.path)
      if not path then
        return false, path_err
      end
      local next_lines
      if vim.fn.filereadable(path) ~= 1 then
        if file.is_delete then
          return false, "target file is not readable for deletion: " .. file.path
        end
        local err, conflict
        next_lines, err, conflict = apply_hunks_to_lines(
          {},
          file,
          file.hunks,
          vim.tbl_extend("force", opts or {}, {
            path = path,
          })
        )
        if not next_lines then
          if err == "conflict" then
            return false,
              "conflict",
              {
                kind = "conflict",
                conflict = conflict,
                conflicts = { conflict },
              }
          end
          return false, err
        end
      else
        local lines = vim.fn.readfile(path)
        local err, conflict
        next_lines, err, conflict = apply_hunks_to_lines(
          lines,
          file,
          file.hunks,
          vim.tbl_extend("force", opts or {}, {
            path = path,
          })
        )
        if not next_lines then
          if err == "conflict" then
            return false,
              "conflict",
              {
                kind = "conflict",
                conflict = conflict,
                conflicts = { conflict },
              }
          end
          return false, err
        end
      end
      table.insert(plan, {
        kind = "file",
        path = path,
        file = file,
        next_lines = next_lines,
      })
    end
  end

  for _, entry in ipairs(plan) do
    if entry.kind == "buffer" then
      vim.api.nvim_buf_set_lines(entry.bufnr, 0, -1, false, entry.next_lines)
    elseif entry.file.is_delete and #entry.next_lines == 0 then
      vim.fn.delete(entry.path)
    else
      util.ensure_dir(vim.fs.dirname(entry.path))
      vim.fn.writefile(entry.next_lines, entry.path)
    end
  end

  return true, nil
end

local function run_git_apply(root, diff, args, callback)
  local cmd = { "git", "apply" }
  for _, arg in ipairs(args or {}) do
    table.insert(cmd, arg)
  end
  vim.system(cmd, {
    cwd = root,
    text = true,
    stdin = diff,
  }, function(result)
    callback(result.code == 0, result.stderr or result.stdout or "")
  end)
end

function M.check(root, diff, callback)
  run_git_apply(root, diff, { "--check", "--whitespace=nowarn" }, callback)
end

function M.apply(root, diff, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  opts = opts or {}

  local direct_ok, direct_err, direct_meta = M.apply_unified(root, diff, opts)
  if direct_ok then
    callback(true, nil)
    return
  end
  if direct_meta and direct_meta.kind == "conflict" then
    callback(false, direct_err, direct_meta)
    return
  end

  M.check(root, diff, function(ok, err)
    if not ok then
      callback(false, (direct_err or "direct apply failed") .. "\n" .. (err or ""))
      return
    end
    run_git_apply(root, diff, { "--whitespace=nowarn" }, function(applied, apply_err)
      if applied then
        vim.schedule(function()
          vim.cmd("checktime")
        end)
      end
      callback(applied, apply_err)
    end)
  end)
end

return M
