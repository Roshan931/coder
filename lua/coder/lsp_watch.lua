local context = require("coder.context")
local util = require("coder.util")

local M = {}

local augroup = nil

local function diagnostic_key(root, file, diagnostic)
  return table.concat({
    root,
    file,
    tostring(diagnostic.lnum),
    tostring(diagnostic.col),
    diagnostic.message or "",
  }, "|")
end

local function overlaps(task, diagnostic)
  if not task.range then
    return false
  end
  local line = diagnostic.lnum + 1
  return line >= task.range.start_line and line <= task.range.end_line
end

function M.setup()
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
  end
  augroup = vim.api.nvim_create_augroup("CoderLspWatch", { clear = true })

  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = augroup,
    callback = function(args)
      local bufnr = args.buf
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local file = vim.api.nvim_buf_get_name(bufnr)
      if file == "" then
        return
      end
      local root = util.workspace_root(bufnr)
      local rel = util.relative_path(file, root)
      local accepted = context.accepted_tasks_for_file(root, rel)
      if #accepted == 0 then
        return
      end

      for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
        for _, task in ipairs(accepted) do
          if overlaps(task, diagnostic) then
            local key = diagnostic_key(root, rel, diagnostic)
            local added = context.add_suggestion(root, key, {
              file = rel,
              task_id = task.id,
              diagnostic = diagnostic.message,
              line = diagnostic.lnum + 1,
            })
            if added then
              util.notify(
                ("Coder noticed a diagnostic in an accepted task range: %s:%d"):format(rel, diagnostic.lnum + 1),
                vim.log.levels.WARN
              )
            end
          end
        end
      end
    end,
  })
end

return M
