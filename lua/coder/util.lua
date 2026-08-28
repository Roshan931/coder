local M = {}

local root_markers = { ".git", "package.json", "go.mod", "Cargo.toml", "pyproject.toml" }

local function root_from_start(start)
  local marker = vim.fs.find(root_markers, {
    upward = true,
    path = start,
  })[1]

  if marker then
    return vim.fs.dirname(marker)
  end

  return nil
end

function M.notify(message, level)
  local cfg = require("coder.config").options
  if cfg.ui and cfg.ui.notify == false then
    return
  end
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO, { title = "Coder" })
  end)
end

function M.path_join(parts)
  local path = table.concat(parts, "/"):gsub("//+", "/")
  return path
end

function M.ensure_dir(path)
  vim.fn.mkdir(path, "p")
end

function M.state_dir()
  local dir = M.path_join({ vim.fn.stdpath("state"), "coder" })
  M.ensure_dir(dir)
  return dir
end

function M.workspace_root(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)
  local start = file ~= "" and file or vim.loop.cwd()

  if file ~= "" and vim.fn.isdirectory(file) ~= 1 then
    start = vim.fs.dirname(file)
  end

  local marker_root = root_from_start(start)
  if marker_root then
    return marker_root
  end

  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  for _, client in ipairs(clients) do
    if client.config and client.config.root_dir then
      return client.config.root_dir
    end
  end

  return vim.loop.cwd()
end

function M.workspace_root_for_path(path)
  path = path and path ~= "" and vim.fs.normalize(vim.fn.fnamemodify(path, ":p")) or vim.loop.cwd()
  local start = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
  return root_from_start(start) or start or vim.loop.cwd()
end

function M.relative_path(path, root)
  if not path or path == "" then
    return ""
  end
  root = root or M.workspace_root()
  if path:sub(1, #root) == root then
    local rel = path:sub(#root + 2)
    return rel ~= "" and rel or vim.fs.basename(path)
  end
  return path
end

function M.workspace_id(root)
  root = root or M.workspace_root()
  local ok, hash = pcall(vim.fn.sha256, root)
  if ok and hash and hash ~= "" then
    return hash
  end
  return root:gsub("[^%w%-_]", "_")
end

function M.read_json(path, fallback)
  if vim.fn.filereadable(path) ~= 1 then
    return fallback
  end
  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read then
    return fallback
  end
  local raw = table.concat(lines, "\n")
  if raw == "" then
    return fallback
  end
  local ok_decode, data = pcall(vim.json.decode, raw)
  if not ok_decode then
    return fallback
  end
  return data
end

function M.write_json(path, value)
  M.ensure_dir(vim.fs.dirname(path))
  local ok_encode, raw = pcall(vim.json.encode, value)
  if not ok_encode then
    return false
  end
  return pcall(vim.fn.writefile, vim.split(raw, "\n", { plain = true }), path)
end

function M.now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function M.id(prefix)
  prefix = prefix or "task"
  local seed = ("%s-%s-%s"):format(prefix, tostring(vim.loop.hrtime()), tostring(math.random(100000, 999999)))
  local ok, hash = pcall(vim.fn.sha256, seed)
  if ok then
    return prefix .. "-" .. hash:sub(1, 12)
  end
  return prefix .. "-" .. tostring(vim.loop.hrtime())
end

function M.buf_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

function M.buf_text(bufnr)
  return table.concat(M.buf_lines(bufnr), "\n")
end

function M.line_count(bufnr)
  return vim.api.nvim_buf_line_count(bufnr)
end

function M.trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.strip_ansi(value)
  value = value or ""
  value = value:gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
  return value
end

function M.first_non_empty(...)
  local values = { ... }
  for _, value in ipairs(values) do
    if value and value ~= "" then
      return value
    end
  end
  return nil
end

function M.safe_buf_call(bufnr, fn)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local current = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  local ok, result = pcall(fn)
  if vim.api.nvim_buf_is_valid(current) then
    vim.api.nvim_set_current_buf(current)
  end
  if ok then
    return result
  end
  return nil
end

function M.table_values(tbl)
  local values = {}
  for _, value in pairs(tbl or {}) do
    table.insert(values, value)
  end
  return values
end

return M
