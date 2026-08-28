local coder = require("coder")

coder.setup({
  max_concurrent_jobs = 1,
  keymaps = { enable = false },
  ui = { notify = false },
})

vim.cmd("runtime plugin/coder.lua")
local config = require("coder.config")
assert(config.options.max_concurrent_jobs == 1, "plugin loading must preserve an earlier setup")
assert(config.options.keymaps.enable == false, "plugin loading must preserve disabled mappings")

local function keymaps(enqueue, enabled)
  return {
    enable = enabled,
    enqueue = enqueue,
    enqueue_deep = false,
    enqueue_with_intent = false,
    enqueue_deep_with_intent = false,
    directory = false,
    directory_deep = false,
    directory_summary = false,
    review = false,
    status = false,
    diagnostics = false,
    explain = false,
    cancel = false,
  }
end

coder.setup({ keymaps = keymaps("<leader>zz", true), ui = { notify = false } })
local installed = vim.fn.maparg("\\zz", "n", false, true)
assert(installed.desc == "Coder enqueue parent scope fast", "expected configured Coder mapping")

coder.setup({ keymaps = { enable = false }, ui = { notify = false } })
assert(next(vim.fn.maparg("\\zz", "n", false, true)) == nil, "disabled setup must remove Coder mappings")

vim.keymap.set("n", "<leader>yy", "<cmd>echo 'user mapping'<CR>", { desc = "User mapping" })
coder.setup({ keymaps = keymaps("<leader>yy", true), ui = { notify = false } })
local preserved = vim.fn.maparg("\\yy", "n", false, true)
assert(preserved.desc == "User mapping", "Coder must not replace an existing user mapping")

local invalid_ok = pcall(coder.setup, { max_concurrent_jobs = 0 })
assert(not invalid_ok, "invalid configuration must be rejected")
assert(require("coder.config").options.max_concurrent_jobs == 8, "invalid setup must not replace valid configuration")

vim.cmd("qa!")
