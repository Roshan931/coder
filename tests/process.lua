vim.opt.runtimepath:prepend(vim.fn.getcwd())

local config = require("coder.config")
local opencode = require("coder.opencode")
local command = vim.fn.getcwd() .. "/tests/fixtures/fake-opencode"

local function task(id)
  return {
    id = id,
    kind = "edit",
    profile = "fast",
    root = vim.fn.getcwd(),
    selection = {
      root = vim.fn.getcwd(),
      relative_file = "example.lua",
      mode = "cursor",
      source = "test",
      filetype = "lua",
      text = "return false",
      file_snapshot = "return false",
      display_range = {
        start_line = 1,
        start_col = 1,
        end_line = 1,
        end_col = 12,
      },
    },
    context = {
      workspace = {
        style = "clean",
        files = {},
        total_files = 0,
        manifests = {},
        related_files = {},
      },
    },
  }
end

local function run(id, timeout_ms)
  config.setup({
    keymaps = { enable = false },
    opencode = {
      command = command,
      timeout_ms = timeout_ms,
    },
  })

  local result = nil
  local handle = opencode.run(task(id), function(value)
    result = value
  end)
  assert(handle ~= nil, "expected an OpenCode process handle")
  vim.wait(3000, function()
    return result ~= nil
  end)
  assert(result ~= nil, "expected OpenCode process completion")
  return result
end

local success = run("coder-success", 1000)
assert(success.code == 0, "expected successful process result")
assert(success.stdout:match("diff %-%-git"), "expected captured process stdout")

local failed = run("coder-fail", 1000)
assert(failed.code == 7, "expected process exit code")
assert(failed.stderr:match("fake OpenCode failure"), "expected captured process stderr")

local timed_out = run("coder-timeout", 50)
assert(timed_out.code == -1, "expected timeout result")
assert(timed_out.stderr:match("timed out"), "expected timeout message")

vim.cmd("qa!")
