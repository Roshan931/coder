require("coder").setup({
  keymaps = { enable = false },
  ui = { notify = false },
  edits = { mode = "auto_apply" },
})

assert(require("coder.config").options.edits.mode == "auto_apply", "expected auto apply config")
local profile_config = require("coder.config")
assert(profile_config.profile_name() == "fast", "expected fast default profile")
assert(profile_config.for_profile("fast").opencode.variant == "minimal", "expected fast minimal variant")
assert(profile_config.for_profile("fast").prompt.response_format == "diff_only", "expected fast diff-only response")
assert(profile_config.for_profile("fast").memory.max_recent_tasks == 6, "expected fast memory cap")
assert(
  profile_config.for_profile("fast").opencode.agent == "plan",
  "expected edit-restricted OpenCode agent by default"
)
assert(profile_config.for_profile("deep").opencode.variant == false, "expected deep profile to disable variant")
assert(profile_config.for_profile("deep").prompt.response_format == "diff_only", "expected deep diff-only response")
assert(profile_config.for_profile("deep").architecture.max_related_files == 12, "expected deep related file cap")

local selector = require("coder.selector")
local opencode = require("coder.opencode")
local patches = require("coder.patches")
local ui = require("coder.ui")

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "typescript"
vim.api.nvim_buf_set_name(bufnr, vim.fn.getcwd() .. "/sample.ts")
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "export function outer(value: string) {",
  "  if (value.length > 0) {",
  "    return value.toUpperCase()",
  "  }",
  "  return value",
  "}",
})
vim.api.nvim_win_set_cursor(0, { 3, 6 })

local selection = selector.capture_cursor()
assert(selection ~= nil, "expected cursor selection")
assert(selection.text:match("return value.toUpperCase"), "expected selected code")

local parsed = patches.parse([[
<CODER_SUMMARY>
Adds a semicolon.
</CODER_SUMMARY>
<CODER_DIFF>
diff --git a/sample.ts b/sample.ts
--- a/sample.ts
+++ b/sample.ts
@@ -1,3 +1,3 @@
-return value
+return value;
</CODER_DIFF>
<CODER_NOTES>
Run tests.
</CODER_NOTES>
]])

assert(parsed.summary:match("semicolon"), "expected summary")
assert(parsed.diff:match("diff %-%-git"), "expected diff")
assert(#parsed.files == 1 and parsed.files[1] == "sample.ts", "expected touched file")

local raw_parsed = patches.parse([[
diff --git a/raw.ts b/raw.ts
--- a/raw.ts
+++ b/raw.ts
@@ -1,1 +1,1 @@
-const value = 1
+const value = 2
]])
assert(raw_parsed.summary == "Patch touches raw.ts", "expected local summary for raw diff")
assert(raw_parsed.diff:match("diff %-%-git"), "expected raw diff parsing")

local prompt = opencode.build_prompt({
  id = "coder-prompt-test",
  kind = "edit",
  profile = "fast",
  intent = nil,
  selection = selection,
  context = {
    workspace = {
      style = "clean",
      files = { "src/user.service.ts", "src/user.model.ts" },
      total_files = 2,
      manifests = {},
      related_files = {},
    },
  },
})
assert(prompt:match("Do not respond that implementation cannot be inferred"), "expected completion-biased prompt")
assert(prompt:match("module%-local in%-memory array"), "expected minimal local storage guidance")
assert(prompt:match("Return one unified diff that may touch multiple files"), "expected multi-file diff guidance")
assert(prompt:match("selected code as the intent anchor"), "expected intent anchor guidance")
assert(prompt:match("Project file outline"), "expected repo outline section")
assert(prompt:match("Coder profile:\nfast"), "expected fast profile in prompt")
assert(prompt:match("Fast profile:"), "expected fast profile guidance")
assert(prompt:match("Return only a unified diff"), "expected diff-only response guidance")
assert(not prompt:match("<CODER_SUMMARY>"), "expected no summary tags in fast edit prompt")

local blueprint_root = vim.fn.tempname()
vim.fn.mkdir(blueprint_root .. "/src/models", "p")
vim.fn.mkdir(blueprint_root .. "/src/services", "p")
vim.fn.writefile({ '{"type":"module"}' }, blueprint_root .. "/package.json")
vim.fn.writefile({
  "export interface User {",
  "  // first name, last name, email",
  "}",
}, blueprint_root .. "/src/models/user.ts")
vim.fn.writefile({
  "export function createUser(input: User): void",
}, blueprint_root .. "/src/services/userService.ts")
vim.fn.writefile({}, blueprint_root .. "/src/services/memoryUserRepository.ts")

local directory_selection = selector.capture_directory(blueprint_root .. "/src", { profile = "deep" })
assert(directory_selection ~= nil, "expected directory selection")
assert(directory_selection.mode == "directory", "expected directory mode")
assert(directory_selection.relative_file == "src", "expected project-relative directory target")
assert(directory_selection.text:match("Directory blueprint snapshot"), "expected directory snapshot header")
assert(directory_selection.text:match("FILE src/models/user%.ts"), "expected model file marker")
assert(
  directory_selection.text:match("FILE src/services/memoryUserRepository%.ts %[%empty%]"),
  "expected empty file marker"
)

local directory_prompt = opencode.build_prompt({
  id = "coder-directory-test",
  kind = "edit",
  profile = "deep",
  intent = "Implement this blueprint.",
  selection = directory_selection,
  context = {
    workspace = {
      style = "clean",
      files = { "src/models/user.ts", "src/services/userService.ts" },
      total_files = 2,
      manifests = {},
      related_files = {},
    },
  },
})
assert(directory_prompt:match("Directory blueprint rules"), "expected directory rules")
assert(directory_prompt:match("Target path:\nsrc"), "expected target path label")
assert(directory_prompt:match("Directory blueprint snapshot:"), "expected directory snapshot prompt label")
assert(
  not directory_prompt:match("Full file snapshot at enqueue time"),
  "expected directory prompt to avoid duplicate file snapshot"
)

local netrw_bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(netrw_bufnr)
vim.bo[netrw_bufnr].filetype = "netrw"
vim.api.nvim_buf_set_name(netrw_bufnr, blueprint_root)
vim.b[netrw_bufnr].netrw_curdir = blueprint_root
vim.api.nvim_buf_set_lines(netrw_bufnr, 0, -1, false, {
  '" Netrw Directory Listing',
  "src/",
})
vim.fn.setpos("'<", { 0, 2, 1, 0 })
vim.fn.setpos("'>", { 0, 2, 4, 0 })
local netrw_directory_selection = selector.capture_directory_visual({ profile = "deep" })
assert(netrw_directory_selection ~= nil, "expected visual netrw directory selection")
assert(netrw_directory_selection.source == "netrw_visual", "expected netrw visual source")
assert(netrw_directory_selection.mode == "directory", "expected selected netrw directory mode")
assert(netrw_directory_selection.relative_file == "src", "expected selected netrw target")
assert(
  netrw_directory_selection.text:match("FILE src/models/user%.ts"),
  "expected selected netrw directory file marker"
)

vim.api.nvim_buf_set_lines(netrw_bufnr, 0, -1, false, {
  '" Netrw Directory Listing',
  "docs/        src/        tmp/",
})
vim.fn.setpos("'<", { 0, 2, 14, 0 })
vim.fn.setpos("'>", { 0, 2, 17, 0 })
local netrw_wide_selection = selector.capture_directory_visual({ profile = "deep" })
assert(netrw_wide_selection ~= nil, "expected visual netrw wide-list selection")
assert(netrw_wide_selection.relative_file == "src", "expected wide-list selected target")
assert(netrw_wide_selection.text:match("FILE src/services/userService%.ts"), "expected wide-list directory file marker")

local summary_prompt = opencode.build_prompt({
  id = "coder-summary-test",
  kind = "explain",
  profile = "fast",
  intent = "Summarize this implementation in 3-6 concise bullets. No fluff. No patch.",
  selection = selection,
  context = {
    workspace = {
      style = "clean",
      files = {},
      total_files = 0,
      manifests = {},
      related_files = {},
    },
  },
})
assert(summary_prompt:match("Do not return a patch"), "expected no-patch summary rule")
assert(summary_prompt:match("Three to six concise bullets"), "expected concise summary format")
assert(summary_prompt:match("<CODER_SUMMARY>"), "expected summary tag for parser")
assert(not summary_prompt:match("Return only a unified diff"), "expected no diff-only response for summary")

local directory_summary_prompt = opencode.build_prompt({
  id = "coder-directory-summary-test",
  kind = "explain",
  profile = "deep",
  intent = "Summarize this directory architecture in 3-6 concise bullets. No fluff. No patch.",
  selection = directory_selection,
  context = {
    workspace = {
      style = "clean",
      files = {},
      total_files = 0,
      manifests = {},
      related_files = {},
    },
  },
})
assert(
  directory_summary_prompt:match("selected directory architecture snapshot"),
  "expected directory summary guidance"
)
vim.fn.delete(blueprint_root, "rf")

local review_ok, review_err = pcall(ui.open_review, {
  id = "coder-review-multiline",
  kind = "explain",
  status = "answered",
  profile = "fast",
  selection = {
    relative_file = "models/user.ts",
    label = "const userSchema = new Schema({",
  },
  result = {
    summary = table.concat({
      "- Defines a Mongoose user schema.",
      "- Derives the TypeScript User type.",
      "- Notes validation risks.",
    }, "\n"),
  },
}, {
  accept = function() end,
  reject = function() end,
})
assert(review_ok, review_err or "expected multiline summary review to open")
vim.cmd("bdelete")

local close_review_task = {
  id = "coder-review-close",
  kind = "explain",
  status = "answered",
  profile = "fast",
  selection = {
    relative_file = "models/user.ts",
    label = "const userSchema = new Schema({",
  },
  result = {
    summary = "- Short answer.",
  },
}
local close_review_bufnr = nil
local close_review_winid = nil
ui.open_review(close_review_task, {
  accept = function() end,
  reject = function() end,
})
close_review_bufnr = vim.api.nvim_get_current_buf()
close_review_winid = vim.api.nvim_get_current_win()
vim.api.nvim_feedkeys("a", "mx", false)
vim.wait(1000, function()
  return not vim.api.nvim_win_is_valid(close_review_winid)
end)
assert(not vim.api.nvim_win_is_valid(close_review_winid), "expected accept to close review window")
assert(not vim.api.nvim_buf_is_valid(close_review_bufnr), "expected accept to wipe review buffer")

local status_ok, status_err = pcall(function()
  ui.open_status({}, { queued = 0, running = 0, applying = 0, conflict = 0, ready = 0, failed = 0 })
  ui.open_status({}, { queued = 0, running = 0, applying = 0, conflict = 0, ready = 0, failed = 0 })
end)
assert(status_ok, status_err or "expected repeated status opens to reuse the status buffer")
vim.cmd("bdelete")

local apply_bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(apply_bufnr)
vim.bo[apply_bufnr].filetype = "typescript"
vim.api.nvim_buf_set_name(apply_bufnr, vim.fn.getcwd() .. "/index.ts")
vim.api.nvim_buf_set_lines(apply_bufnr, 0, -1, false, {
  "interface User {",
  "  // first name, last name, email, password, and date of birth",
  "}",
  "",
  "function createUser(user: User): void {",
  "  // code to create a user",
  "}",
})

local apply_ok = nil
local apply_err = nil
patches.apply(
  vim.fn.getcwd(),
  [[
diff --git a/index.ts b/index.ts
--- a/index.ts
+++ b/index.ts
@@ -1,1 +1,1 @@
 interface User {
-  // first name, last name, email, password, and date of birth
+  firstName: string;
+  lastName: string;
+  email: string;
+  password: string;
+  dateOfBirth: string;
 }
 
+const users: User[] = [];
+
 function createUser(user: User): void {
-  // code to create a user
+  users.push(user);
 }
]],
  {
    selection = {
      bufnr = apply_bufnr,
      relative_file = "index.ts",
    },
  },
  function(ok, err)
    apply_ok = ok
    apply_err = err
  end
)

vim.wait(1000, function()
  return apply_ok ~= nil
end)
assert(apply_ok, apply_err or "expected direct patch apply")
local applied_text = table.concat(vim.api.nvim_buf_get_lines(apply_bufnr, 0, -1, false), "\n")
assert(applied_text:match("firstName: string;"), "expected interface fields")
assert(applied_text:match("const users: User%[%] = %[%];"), "expected local users storage")
assert(applied_text:match("users.push%(user%);"), "expected function implementation")

local tmp_root = vim.fn.tempname()
vim.fn.mkdir(tmp_root .. "/src", "p")
local service_bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(service_bufnr)
vim.bo[service_bufnr].filetype = "typescript"
vim.api.nvim_buf_set_name(service_bufnr, tmp_root .. "/src/user.service.ts")
vim.api.nvim_buf_set_lines(service_bufnr, 0, -1, false, {
  "export function createUser(user: User): void {",
  "  // code to create a user",
  "}",
})

local multi_ok = nil
local multi_err = nil
patches.apply(
  tmp_root,
  [[
diff --git a/src/user.service.ts b/src/user.service.ts
--- a/src/user.service.ts
+++ b/src/user.service.ts
@@ -1,3 +1,5 @@
+import { users, type User } from "./user.model";
+
 export function createUser(user: User): void {
-  // code to create a user
+  users.push(user);
 }
diff --git a/src/user.model.ts b/src/user.model.ts
new file mode 100644
--- /dev/null
+++ b/src/user.model.ts
@@ -0,0 +1,8 @@
+export interface User {
+  firstName: string;
+  lastName: string;
+  email: string;
+  password: string;
+  dateOfBirth: string;
+}
+
+export const users: User[] = [];
]],
  {
    selection = {
      bufnr = service_bufnr,
      relative_file = "src/user.service.ts",
    },
  },
  function(ok, err)
    multi_ok = ok
    multi_err = err
  end
)

vim.wait(1000, function()
  return multi_ok ~= nil
end)
assert(multi_ok, multi_err or "expected multi-file patch apply")
local service_text = table.concat(vim.api.nvim_buf_get_lines(service_bufnr, 0, -1, false), "\n")
assert(service_text:match('from "%./user%.model"'), "expected service import")
assert(service_text:match("users.push%(user%);"), "expected service implementation")
local model_text = table.concat(vim.fn.readfile(tmp_root .. "/src/user.model.ts"), "\n")
assert(model_text:match("export interface User"), "expected new model file")
assert(model_text:match("export const users: User%[%] = %[%];"), "expected exported storage")
vim.fn.delete(tmp_root, "rf")

local symlink_root = vim.fn.tempname()
local symlink_outside = vim.fn.tempname()
vim.fn.mkdir(symlink_root, "p")
vim.fn.mkdir(symlink_outside, "p")
local linked, link_err = vim.uv.fs_symlink(symlink_outside, symlink_root .. "/escape")
assert(linked, link_err or "expected test symlink")
local escaped_ok, escaped_err = patches.apply_unified(
  symlink_root,
  [[
diff --git a/escape/generated.lua b/escape/generated.lua
new file mode 100644
--- /dev/null
+++ b/escape/generated.lua
@@ -0,0 +1,1 @@
+return true
]],
  {}
)
assert(not escaped_ok, "expected a symlink path outside the workspace to be rejected")
assert(escaped_err:match("outside workspace root"), "expected a symlink containment error")
assert(vim.fn.filereadable(symlink_outside .. "/generated.lua") == 0, "expected no file outside the workspace")
vim.fn.delete(symlink_root, "rf")
vim.fn.delete(symlink_outside, "rf")

local conflict_bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(conflict_bufnr)
vim.bo[conflict_bufnr].filetype = "typescript"
vim.api.nvim_buf_set_name(conflict_bufnr, vim.fn.getcwd() .. "/conflict.ts")
vim.api.nvim_buf_set_lines(conflict_bufnr, 0, -1, false, {
  "function createUser(user: User): void {",
  "  console.info(user.email);",
  "}",
})

local conflict_ok = nil
local conflict_err = nil
local conflict_meta = nil
local conflict_diff = [[
diff --git a/conflict.ts b/conflict.ts
--- a/conflict.ts
+++ b/conflict.ts
@@ -1,3 +1,3 @@
 function createUser(user: User): void {
-  // code to create a user
+  users.push(user);
 }
]]

patches.apply(vim.fn.getcwd(), conflict_diff, {
  selection = {
    bufnr = conflict_bufnr,
    relative_file = "conflict.ts",
  },
}, function(ok, err, meta)
  conflict_ok = ok
  conflict_err = err
  conflict_meta = meta
end)

vim.wait(1000, function()
  return conflict_ok ~= nil
end)
assert(conflict_ok == false, "expected conflict")
assert(conflict_err == "conflict", "expected conflict error kind")
assert(conflict_meta and conflict_meta.kind == "conflict", "expected conflict metadata")
assert(conflict_meta.conflict.user_lines[2] == "  console.info(user.email);", "expected user-side conflict lines")
assert(conflict_meta.conflict.opencode_lines[2] == "  users.push(user);", "expected opencode-side conflict lines")
local unchanged_conflict_text = table.concat(vim.api.nvim_buf_get_lines(conflict_bufnr, 0, -1, false), "\n")
assert(unchanged_conflict_text:match("console%.info"), "expected transactional conflict to keep buffer unchanged")

local resolved_ok = nil
local resolved_err = nil
patches.apply(vim.fn.getcwd(), conflict_diff, {
  selection = {
    bufnr = conflict_bufnr,
    relative_file = "conflict.ts",
  },
  resolutions = {
    [conflict_meta.conflict.id] = "opencode",
  },
}, function(ok, err)
  resolved_ok = ok
  resolved_err = err
end)

vim.wait(1000, function()
  return resolved_ok ~= nil
end)
assert(resolved_ok, resolved_err or "expected resolved conflict apply")
local resolved_conflict_text = table.concat(vim.api.nvim_buf_get_lines(conflict_bufnr, 0, -1, false), "\n")
assert(resolved_conflict_text:match("users.push%(user%);"), "expected opencode conflict choice")

local inserted_line_bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(inserted_line_bufnr)
vim.bo[inserted_line_bufnr].filetype = "typescript"
vim.api.nvim_buf_set_name(inserted_line_bufnr, vim.fn.getcwd() .. "/inserted-conflict.ts")
vim.api.nvim_buf_set_lines(inserted_line_bufnr, 0, -1, false, {
  "function createUser(user: User): void {",
  "  console.info(user.email);",
  "  // code to create a user",
  "}",
})

local inserted_conflict_ok = nil
local inserted_conflict_meta = nil
patches.apply(
  vim.fn.getcwd(),
  [[
diff --git a/inserted-conflict.ts b/inserted-conflict.ts
--- a/inserted-conflict.ts
+++ b/inserted-conflict.ts
@@ -1,3 +1,3 @@
 function createUser(user: User): void {
-  // code to create a user
+  users.push(user);
 }
]],
  {
    selection = {
      bufnr = inserted_line_bufnr,
      relative_file = "inserted-conflict.ts",
    },
  },
  function(ok, _, meta)
    inserted_conflict_ok = ok
    inserted_conflict_meta = meta
  end
)

vim.wait(1000, function()
  return inserted_conflict_ok ~= nil
end)
assert(inserted_conflict_ok == false, "expected inserted-line conflict")
assert(
  #inserted_conflict_meta.conflict.user_lines == 4,
  "expected conflict span to include inserted user line and trailing context"
)

local inserted_resolved_ok = nil
local inserted_resolved_err = nil
patches.apply(
  vim.fn.getcwd(),
  [[
diff --git a/inserted-conflict.ts b/inserted-conflict.ts
--- a/inserted-conflict.ts
+++ b/inserted-conflict.ts
@@ -1,3 +1,3 @@
 function createUser(user: User): void {
-  // code to create a user
+  users.push(user);
 }
]],
  {
    selection = {
      bufnr = inserted_line_bufnr,
      relative_file = "inserted-conflict.ts",
    },
    resolutions = {
      [inserted_conflict_meta.conflict.id] = "opencode",
    },
  },
  function(ok, err)
    inserted_resolved_ok = ok
    inserted_resolved_err = err
  end
)

vim.wait(1000, function()
  return inserted_resolved_ok ~= nil
end)
assert(inserted_resolved_ok, inserted_resolved_err or "expected inserted-line conflict resolution")
local inserted_resolved_text = table.concat(vim.api.nvim_buf_get_lines(inserted_line_bufnr, 0, -1, false), "\n")
local _, closing_count = inserted_resolved_text:gsub("\n}", "")
assert(closing_count == 1, "expected no duplicated trailing context line")
assert(inserted_resolved_text == table.concat({
  "function createUser(user: User): void {",
  "  users.push(user);",
  "}",
}, "\n"), "expected opencode replacement without duplicated lines")

local cmd = opencode.command_for({
  id = "coder-test",
  root = vim.fn.getcwd(),
  profile = "fast",
}, "CODER TASK PROMPT")

for _, arg in ipairs(cmd) do
  assert(not arg:match("^%-%-file"), "Coder should pass the prompt as the message, not through OpenCode --file")
end
assert(vim.tbl_contains(cmd, "--variant"), "expected fast command to pass OpenCode variant")
assert(vim.tbl_contains(cmd, "minimal"), "expected fast command to use minimal variant")
assert(vim.tbl_contains(cmd, "--agent"), "expected command to select an edit-restricted OpenCode agent")
assert(vim.tbl_contains(cmd, "plan"), "expected command to use the OpenCode plan agent")
assert(cmd[#cmd] == "CODER TASK PROMPT", "expected Coder task prompt as final message arg")

require("coder.config").setup({
  keymaps = { enable = false },
  opencode = {
    attach = "http://127.0.0.1:4096",
    pure = true,
  },
})

local attached_cmd = opencode.command_for({
  id = "coder-attached-test",
  root = vim.fn.getcwd(),
  profile = "fast",
}, "CODER ATTACHED TASK PROMPT")
assert(vim.tbl_contains(attached_cmd, "--attach"), "expected attach flag")
assert(vim.tbl_contains(attached_cmd, "http://127.0.0.1:4096"), "expected attach url")
assert(vim.tbl_contains(attached_cmd, "--pure"), "expected pure flag")

require("coder.config").setup({
  keymaps = { enable = false },
  ui = { notify = false },
  edits = { mode = "auto_apply" },
})

local deep_cmd = opencode.command_for({
  id = "coder-deep-test",
  root = vim.fn.getcwd(),
  profile = "deep",
}, "CODER DEEP TASK PROMPT")
assert(not vim.tbl_contains(deep_cmd, "--variant"), "expected deep command to omit OpenCode variant")
assert(deep_cmd[#deep_cmd] == "CODER DEEP TASK PROMPT", "expected deep prompt as final message arg")

vim.cmd("qa!")
