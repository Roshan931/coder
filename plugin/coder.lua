if vim.g.loaded_coder == 1 then
  return
end

vim.g.loaded_coder = 1
local coder = require("coder")
if not coder.is_setup() then
  coder.setup()
end
