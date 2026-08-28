local M = {}

local required_run_flags = {
  "--agent",
  "--dir",
  "--format",
  "--title",
  "--variant",
}

local function check_opencode(command, options)
  if vim.fn.executable(command) ~= 1 then
    vim.health.error(("OpenCode executable not found: %s"):format(command))
    return
  end

  local version = vim.system({ command, "--version" }, { text = true }):wait(3000)
  if version.code == 0 then
    local value = vim.trim(version.stdout or version.stderr or "")
    vim.health.ok("OpenCode executable found" .. (value ~= "" and (": " .. value) or ""))
  else
    vim.health.warn("OpenCode was found but its version could not be read")
  end

  local help = vim.system({ command, "run", "--help" }, { text = true }):wait(3000)
  if help.code ~= 0 then
    vim.health.error("`opencode run --help` failed; this OpenCode version is not compatible")
    return
  end

  local output = (help.stdout or "") .. (help.stderr or "")
  local missing = {}
  for _, flag in ipairs(required_run_flags) do
    if not output:find(flag, 1, true) then
      table.insert(missing, flag)
    end
  end
  if options.attach and options.attach ~= "" and not output:find("--attach", 1, true) then
    table.insert(missing, "--attach")
  end
  if options.pure and not output:find("--pure", 1, true) then
    table.insert(missing, "--pure")
  end

  if #missing == 0 then
    vim.health.ok("OpenCode run command exposes all required flags")
  else
    vim.health.error("OpenCode run command is missing required flags: " .. table.concat(missing, ", "))
  end
end

function M.check()
  vim.health.start("coder.nvim")

  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim 0.11 or newer")
  else
    vim.health.error("Neovim 0.11 or newer is required")
  end

  local coder = require("coder")
  if coder.is_setup() then
    vim.health.ok("Coder is initialized")
  else
    vim.health.warn('Coder is not initialized; call require("coder").setup()')
  end

  local options = require("coder.config").options.opencode
  check_opencode(options.command or "opencode", options)

  if vim.fn.executable("git") == 1 then
    vim.health.ok("Git executable found")
  else
    vim.health.warn("Git was not found; patches that require the git-apply fallback cannot be accepted")
  end
end

return M
