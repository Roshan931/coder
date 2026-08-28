local util = require("coder.util")

local M = {}

local scope_nodes = {
  function_declaration = true,
  function_definition = true,
  function_item = true,
  function_statement = true,
  method_declaration = true,
  method_definition = true,
  method_signature = true,
  method_spec = true,
  arrow_function = true,
  lambda_expression = true,
  class_declaration = true,
  class_definition = true,
  interface_declaration = true,
  type_alias_declaration = true,
  enum_declaration = true,
  struct_item = true,
  impl_item = true,
  trait_item = true,
  object = true,
  object_pattern = true,
  if_statement = true,
  else_clause = true,
  for_statement = true,
  for_in_statement = true,
  while_statement = true,
  do_statement = true,
  repeat_statement = true,
  switch_statement = true,
  switch_expression = true,
  try_statement = true,
  catch_clause = true,
}

local declaration_wrappers = {
  lexical_declaration = true,
  variable_declaration = true,
  variable_declarator = true,
  assignment_statement = true,
  pair = true,
}

local directory_ignored_path_parts = {
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

local function node_range(node)
  local sr, sc, er, ec = node:range()
  return {
    start_line = sr,
    start_col = sc,
    end_line = er,
    end_col = ec,
  }
end

local function range_text(bufnr, range)
  local lines = vim.api.nvim_buf_get_lines(bufnr, range.start_line, range.end_line + 1, false)
  if #lines == 0 then
    return ""
  end
  if #lines == 1 then
    lines[1] = lines[1]:sub(range.start_col + 1, range.end_col)
  else
    lines[1] = lines[1]:sub(range.start_col + 1)
    lines[#lines] = lines[#lines]:sub(1, range.end_col)
  end
  return table.concat(lines, "\n")
end

local function line_range_text(bufnr, start_line, end_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
  return table.concat(lines, "\n")
end

local function label_from_text(text, fallback)
  local first = text:match("([^\r\n]+)") or fallback or "selection"
  first = util.trim(first)
  if #first > 100 then
    first = first:sub(1, 97) .. "..."
  end
  return first ~= "" and first or fallback or "selection"
end

local function should_ignore_directory_path(path)
  for part in (path or ""):gmatch("[^/]+") do
    if directory_ignored_path_parts[part] then
      return true
    end
  end
  return false
end

local function extension(path)
  return path:match("%.([^%.%/]+)$") or ""
end

local function resolve_path(path)
  path = util.trim(path or "")
  if path == "" then
    return nil
  end
  path = vim.fn.expand(path)
  if path:sub(1, 1) ~= "/" then
    path = util.path_join({ vim.loop.cwd(), path })
  end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function is_readable_path(path)
  return path and (vim.fn.isdirectory(path) == 1 or vim.fn.filereadable(path) == 1)
end

local function normalize_readable_path(path)
  if not path or path == "" then
    return nil
  end
  local normalized = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if is_readable_path(normalized) then
    return normalized
  end
  return nil
end

local netrw_path_from_candidate

local function netrw_cursor_path()
  local curdir = vim.b.netrw_curdir
  if not curdir or curdir == "" then
    curdir = vim.api.nvim_buf_get_name(0)
  end
  if not curdir or curdir == "" then
    return nil
  end

  local candidate = util.trim(vim.fn.expand("<cfile>") or "")
  if candidate == "" or candidate:sub(1, 1) == '"' then
    return curdir
  end

  return netrw_path_from_candidate(curdir, candidate) or curdir
end

local function clean_netrw_candidate(value)
  local candidate = util.trim(value or "")
  if candidate == "" or candidate:sub(1, 1) == '"' then
    return nil
  end
  if
    candidate:match("^Netrw")
    or candidate:match("^Sorted by")
    or candidate:match("^Sort sequence")
    or candidate:match("^Quick Help")
  then
    return nil
  end

  candidate = candidate:gsub("^%s*[|`+%-\\]+%s*", "")
  candidate = candidate:gsub("^[%s│├└─]+", "")
  candidate = candidate:gsub("^%d+:%s*", "")
  candidate = util.trim(candidate)
  if candidate == "" then
    return nil
  end

  candidate = candidate:gsub("[/@*|=]+$", "")
  return candidate ~= "" and candidate or nil
end

local function netrw_call_file(candidate)
  local ok, value = pcall(vim.fn["netrw#Call"], "NetrwFile", candidate)
  if ok and type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

netrw_path_from_candidate = function(curdir, candidate)
  candidate = clean_netrw_candidate(candidate)
  if not candidate then
    return nil
  end

  if candidate == "." then
    return normalize_readable_path(curdir)
  end
  if candidate == ".." then
    return normalize_readable_path(vim.fs.dirname(curdir))
  end

  local via_netrw = normalize_readable_path(netrw_call_file(candidate))
  if via_netrw then
    return via_netrw
  end

  if candidate:sub(1, 1) == "/" then
    return normalize_readable_path(candidate)
  end

  local from_curdir = normalize_readable_path(util.path_join({ curdir, candidate }))
  if from_curdir then
    return from_curdir
  end

  return normalize_readable_path(candidate)
end

local function candidate_segments(line)
  local cleaned = clean_netrw_candidate(line)
  if not cleaned then
    return {}
  end

  local result = { cleaned }

  for segment in cleaned:gmatch("[^%s][^%s]*") do
    table.insert(result, segment)
  end

  for segment in (cleaned .. "  "):gmatch("(.-)%s%s+") do
    segment = util.trim(segment)
    if segment ~= "" then
      table.insert(result, segment)
    end
  end

  return result
end

local function netrw_paths_from_text(curdir, text)
  local paths = {}
  local seen = {}

  for _, candidate in ipairs(candidate_segments(text)) do
    local path = netrw_path_from_candidate(curdir, candidate)
    if path and not seen[path] then
      seen[path] = true
      table.insert(paths, path)
    end
  end

  return paths
end

local function netrw_path_from_line(curdir, line)
  local paths = netrw_paths_from_text(curdir, line)
  if #paths > 0 then
    return paths[1]
  end
  return nil
end

local function visual_bounds()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = math.max(start_pos[2] - 1, 0)
  local end_line = math.max(end_pos[2] - 1, start_line)
  local start_col = math.max(start_pos[3] - 1, 0)
  local end_col = math.max(end_pos[3], start_col + 1)
  if start_line > end_line then
    start_line, end_line = end_line, start_line
    start_col, end_col = end_col, start_col
  end
  return start_line, end_line, start_col, end_col
end

local function visual_netrw_line_texts(bufnr)
  local start_line, end_line, start_col, end_col = visual_bounds()
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
  local mode = vim.fn.visualmode()

  if mode == "V" then
    return lines
  end

  if #lines == 1 then
    return { (lines[1] or ""):sub(start_col + 1, end_col) }
  end

  local selected = {}
  for index, line in ipairs(lines) do
    if index == 1 then
      table.insert(selected, line:sub(start_col + 1))
    elseif index == #lines then
      table.insert(selected, line:sub(1, end_col))
    else
      table.insert(selected, line)
    end
  end
  return selected
end

local function netrw_visual_paths()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "netrw" then
    return {}
  end

  local curdir = vim.b[bufnr].netrw_curdir
  if not curdir or curdir == "" then
    curdir = vim.api.nvim_buf_get_name(bufnr)
  end
  if not curdir or curdir == "" then
    return {}
  end

  local lines = visual_netrw_line_texts(bufnr)
  local paths = {}
  local seen = {}
  for _, line in ipairs(lines) do
    for _, path in ipairs(netrw_paths_from_text(curdir, line)) do
      if not seen[path] then
        seen[path] = true
        table.insert(paths, path)
      end
    end
  end
  return paths
end

local function current_directory_path()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype == "netrw" then
    return netrw_cursor_path()
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" then
    if vim.fn.isdirectory(name) == 1 then
      return name
    end
    return vim.fs.dirname(name)
  end

  return vim.loop.cwd()
end

local function list_directory_files(target, root, max_files)
  local files = {}
  local function add_file(path)
    local rel = util.relative_path(path, root)
    if rel ~= "" and not should_ignore_directory_path(rel) then
      table.insert(files, {
        path = path,
        relative = rel,
      })
    end
  end

  if vim.fn.filereadable(target) == 1 then
    add_file(target)
  elseif vim.fn.isdirectory(target) == 1 then
    local function walk(dir)
      if #files >= max_files then
        return
      end
      local entries = {}
      for name, type_ in vim.fs.dir(dir) do
        table.insert(entries, { name = name, type = type_ })
      end
      table.sort(entries, function(a, b)
        if a.type == b.type then
          return a.name < b.name
        end
        return a.type == "directory"
      end)
      for _, entry in ipairs(entries) do
        if #files >= max_files then
          return
        end
        local path = util.path_join({ dir, entry.name })
        local rel = util.relative_path(path, root)
        if not should_ignore_directory_path(rel) then
          if entry.type == "file" then
            add_file(path)
          elseif entry.type == "directory" then
            walk(path)
          end
        end
      end
    end
    walk(target)
  end

  table.sort(files, function(a, b)
    return a.relative < b.relative
  end)
  return files
end

local function collect_directory_files(targets, root, max_files)
  local files = {}
  local seen = {}
  for _, target in ipairs(targets) do
    if #files >= max_files then
      break
    end
    local listed = list_directory_files(target, root, max_files - #files)
    for _, file in ipairs(listed) do
      if not seen[file.relative] then
        seen[file.relative] = true
        table.insert(files, file)
      end
      if #files >= max_files then
        break
      end
    end
  end
  table.sort(files, function(a, b)
    return a.relative < b.relative
  end)
  return files
end

local function read_file_for_snapshot(path, max_chars)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return "", "unreadable"
  end
  local text = table.concat(lines, "\n")
  if #text > max_chars then
    return text:sub(1, max_chars) .. "\n...[file truncated]", "truncated"
  end
  if text == "" then
    return "", "empty"
  end
  return text, nil
end

local function directory_text(root, target_label, files, limits)
  local parts = {
    "Directory blueprint snapshot",
    "Workspace root: " .. root,
    "Target path: " .. target_label,
    "Markers like FILE and END FILE are not part of the files.",
    "",
    "Files:",
  }

  for _, file in ipairs(files) do
    table.insert(parts, "- " .. file.relative)
  end
  table.insert(parts, "")

  local total = #table.concat(parts, "\n")
  local max_total = limits.max_total_chars or 120000
  for _, file in ipairs(files) do
    if total >= max_total then
      table.insert(parts, "...[directory snapshot truncated]")
      break
    end

    local remaining = math.max(max_total - total, 0)
    local max_file = math.min(limits.max_file_chars or 12000, remaining)
    local body, state = read_file_for_snapshot(file.path, max_file)
    local header = ("FILE %s%s"):format(file.relative, state and (" [" .. state .. "]") or "")
    local block = table.concat({
      header,
      body,
      "END FILE " .. file.relative,
      "",
    }, "\n")
    table.insert(parts, block)
    total = total + #block
  end

  return table.concat(parts, "\n")
end

local function capture_directory_paths(paths, opts, source)
  opts = opts or {}
  local profile = require("coder.config").for_profile(opts.profile)
  local resolved = {}
  local seen = {}
  for _, path in ipairs(paths or {}) do
    local target = resolve_path(path)
    if target and (vim.fn.isdirectory(target) == 1 or vim.fn.filereadable(target) == 1) and not seen[target] then
      seen[target] = true
      table.insert(resolved, target)
    end
  end

  if #resolved == 0 then
    util.notify("Coder could not resolve a readable netrw selection", vim.log.levels.WARN)
    return nil
  end

  local root = util.workspace_root_for_path(resolved[1])
  local limits = profile.directory or {}
  local files = collect_directory_files(resolved, root, limits.max_files or 120)
  if #files == 0 then
    util.notify("Coder found no readable files under the selected path", vim.log.levels.WARN)
    return nil
  end

  local target_labels = vim.tbl_map(function(target)
    return util.relative_path(target, root)
  end, resolved)
  local target_label = #target_labels == 1 and target_labels[1] or table.concat(target_labels, ", ")
  local only_one_directory = #resolved == 1 and vim.fn.isdirectory(resolved[1]) == 1
  local mode = only_one_directory and "directory" or "file_set"
  local text = directory_text(root, target_label, files, limits)

  return {
    mode = mode,
    source = source or "directory",
    bufnr = nil,
    file = resolved[1],
    relative_file = target_label,
    root = root,
    filetype = "text",
    range = {
      start_line = 0,
      start_col = 0,
      end_line = math.max(#files - 1, 0),
      end_col = 0,
    },
    display_range = {
      start_line = 1,
      start_col = 1,
      end_line = #files,
      end_col = 1,
    },
    text = text,
    label = (mode == "directory" and "directory " or "paths ") .. target_label,
    node_type = mode,
    file_snapshot = text,
    changedtick = nil,
    directory_files = vim.tbl_map(function(file)
      return file.relative
    end, files),
  }
end

local function expand_declaration(node)
  local selected = node
  local parent = node:parent()
  while parent and declaration_wrappers[parent:type()] do
    selected = parent
    parent = parent:parent()
  end
  return selected
end

local function selection_payload(bufnr, mode, source, range, text, node_type)
  local file = vim.api.nvim_buf_get_name(bufnr)
  local root = util.workspace_root(bufnr)
  return {
    mode = mode,
    source = source,
    bufnr = bufnr,
    file = file,
    relative_file = util.relative_path(file, root),
    root = root,
    filetype = vim.bo[bufnr].filetype,
    range = range,
    display_range = {
      start_line = range.start_line + 1,
      start_col = range.start_col + 1,
      end_line = range.end_line + 1,
      end_col = range.end_col,
    },
    text = text,
    label = label_from_text(text, node_type or source),
    node_type = node_type,
    file_snapshot = util.buf_text(bufnr),
    changedtick = vim.b[bufnr].changedtick,
  }
end

local function treesitter_selection(bufnr)
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1] - 1
  local col = math.max(cursor[2], 0)

  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col } })
  if not ok or not node then
    return nil
  end

  local current = node
  while current do
    local node_type = current:type()
    if scope_nodes[node_type] then
      local selected = expand_declaration(current)
      local range = node_range(selected)
      local text = range_text(bufnr, range)
      return selection_payload(bufnr, "cursor", "treesitter", range, text, selected:type())
    end
    current = current:parent()
  end

  return nil
end

local function lsp_symbol_selection(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return nil
  end

  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local responses = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, 600)
  if not responses then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local best = nil

  local function consider(symbol)
    local range = symbol.range or symbol.location and symbol.location.range
    if not range then
      return
    end
    local sr = range.start.line
    local er = range["end"].line
    if row < sr or row > er then
      return
    end
    local size = er - sr
    if not best or size < best.size then
      best = {
        size = size,
        name = symbol.name,
        range = {
          start_line = sr,
          start_col = range.start.character or 0,
          end_line = er,
          end_col = range["end"].character or #vim.api.nvim_buf_get_lines(bufnr, er, er + 1, false)[1],
        },
      }
    end
  end

  local function walk(symbols)
    for _, symbol in ipairs(symbols or {}) do
      consider(symbol)
      if symbol.children then
        walk(symbol.children)
      end
    end
  end

  for _, response in pairs(responses) do
    if response.result then
      walk(response.result)
    end
  end

  if not best then
    return nil
  end

  local text = range_text(bufnr, best.range)
  local payload = selection_payload(bufnr, "cursor", "lsp", best.range, text, "documentSymbol")
  payload.label = best.name or payload.label
  return payload
end

local function indent_fallback_selection(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1] - 1
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 0 then
    return nil
  end

  local current = lines[line + 1] or ""
  local indent = #(current:match("^%s*") or "")
  local start_line = line
  while start_line > 0 do
    local prev = lines[start_line] or ""
    if util.trim(prev) ~= "" and #(prev:match("^%s*") or "") < indent then
      break
    end
    start_line = start_line - 1
  end

  local end_line = line
  while end_line + 1 < #lines do
    local next_line = lines[end_line + 2] or ""
    if util.trim(next_line) ~= "" and #(next_line:match("^%s*") or "") < indent then
      break
    end
    end_line = end_line + 1
  end

  local range = {
    start_line = start_line,
    start_col = 0,
    end_line = end_line,
    end_col = #(lines[end_line + 1] or ""),
  }
  return selection_payload(
    bufnr,
    "cursor",
    "indent",
    range,
    line_range_text(bufnr, start_line, end_line),
    "indent_block"
  )
end

function M.capture_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  return treesitter_selection(bufnr) or lsp_symbol_selection(bufnr) or indent_fallback_selection(bufnr)
end

function M.capture_range(line1, line2)
  local bufnr = vim.api.nvim_get_current_buf()
  line1 = math.max((line1 or 1) - 1, 0)
  line2 = math.max((line2 or line1 + 1) - 1, line1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, line2, line2 + 1, false)
  local range = {
    start_line = line1,
    start_col = 0,
    end_line = line2,
    end_col = #(lines[1] or ""),
  }
  return selection_payload(bufnr, "visual", "range", range, line_range_text(bufnr, line1, line2), "line_range")
end

function M.capture_visual()
  local bufnr = vim.api.nvim_get_current_buf()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local mode = vim.fn.visualmode()

  local start_line = math.max(start_pos[2] - 1, 0)
  local end_line = math.max(end_pos[2] - 1, start_line)
  local start_col = math.max(start_pos[3] - 1, 0)
  local end_col = math.max(end_pos[3], start_col + 1)

  if start_line > end_line or (start_line == end_line and start_col > end_col) then
    start_line, end_line = end_line, start_line
    start_col, end_col = end_col, start_col
  end

  if mode == "V" then
    start_col = 0
    local line = vim.api.nvim_buf_get_lines(bufnr, end_line, end_line + 1, false)[1] or ""
    end_col = #line
  end

  local range = {
    start_line = start_line,
    start_col = start_col,
    end_line = end_line,
    end_col = end_col,
  }
  local text = range_text(bufnr, range)
  return selection_payload(bufnr, "visual", "visual", range, text, mode == "V" and "line_selection" or "char_selection")
end

function M.capture_directory(path, opts)
  opts = opts or {}
  local target = resolve_path(path) or resolve_path(current_directory_path())
  if not target then
    util.notify("Coder could not resolve a directory path", vim.log.levels.WARN)
    return nil
  end
  if vim.fn.isdirectory(target) ~= 1 and vim.fn.filereadable(target) ~= 1 then
    util.notify("Coder path is not readable: " .. target, vim.log.levels.WARN)
    return nil
  end

  local source = path and path ~= "" and "argument" or (vim.bo.filetype == "netrw" and "netrw" or "current_directory")
  return capture_directory_paths({ target }, opts, source)
end

function M.capture_directory_visual(opts)
  opts = opts or {}
  local paths = netrw_visual_paths()
  if #paths == 0 then
    util.notify("Coder visual directory mode only supports selected netrw entries", vim.log.levels.WARN)
    return nil
  end
  return capture_directory_paths(paths, opts, "netrw_visual")
end

return M
