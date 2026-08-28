local M = {}

M.defaults = {
  opencode = {
    command = "opencode",
    timeout_ms = 120000,
    format = "default",
    agent = "plan",
    model = nil,
    variant = nil,
    attach = nil,
    pure = false,
    extra_args = {},
  },
  max_concurrent_jobs = 8,
  memory = {
    max_recent_tasks = 20,
  },
  edits = {
    mode = "review_patch",
  },
  answers = {
    auto_open = true,
  },
  architecture = {
    enabled = true,
    style = "clean",
    include_repo_outline = true,
    include_manifest_snippets = true,
    include_related_files = true,
    max_files = 120,
    max_related_files = 10,
    max_related_lines = 80,
  },
  directory = {
    max_files = 120,
    max_file_chars = 12000,
    max_total_chars = 120000,
  },
  prompt = {
    response_format = "diff_only",
    full_file_max_chars = 60000,
  },
  profiles = {
    default = "fast",
    fast = {
      opencode = {
        variant = "minimal",
      },
      memory = {
        max_recent_tasks = 6,
      },
      architecture = {
        max_files = 60,
        max_related_files = 4,
        max_related_lines = 35,
      },
      directory = {
        max_files = 60,
        max_file_chars = 6000,
        max_total_chars = 60000,
      },
      prompt = {
        response_format = "diff_only",
        full_file_max_chars = 20000,
      },
    },
    deep = {
      opencode = {
        variant = false,
      },
      memory = {
        max_recent_tasks = 20,
      },
      architecture = {
        max_files = 160,
        max_related_files = 12,
        max_related_lines = 100,
      },
      directory = {
        max_files = 220,
        max_file_chars = 20000,
        max_total_chars = 240000,
      },
      prompt = {
        response_format = "diff_only",
        full_file_max_chars = 100000,
      },
    },
  },
  keymaps = {
    enable = false,
    enqueue = "<leader>aa",
    enqueue_deep = "<leader>aA",
    enqueue_with_intent = "<leader>ai",
    enqueue_deep_with_intent = "<leader>aI",
    directory = "<leader>ap",
    directory_deep = "<leader>aP",
    directory_summary = "<leader>aQ",
    review = "<leader>ar",
    status = "<leader>as",
    diagnostics = "<leader>ad",
    explain = "<leader>aq",
    cancel = "<leader>ac",
  },
  ui = {
    notify = true,
    status_title = "Coder Tasks",
    review_title = "Coder Review",
  },
}

M.options = vim.deepcopy(M.defaults)

local function config_error(path, message)
  error(("coder: invalid configuration for %s: %s"):format(path, message), 3)
end

local function validate_type(path, value, expected, optional)
  if optional and value == nil then
    return
  end
  if type(value) ~= expected then
    config_error(path, ("expected %s, got %s"):format(expected, type(value)))
  end
end

local function validate(options)
  validate_type("opencode", options.opencode, "table")
  validate_type("edits", options.edits, "table")
  validate_type("answers", options.answers, "table")
  validate_type("keymaps", options.keymaps, "table")
  validate_type("profiles", options.profiles, "table")

  validate_type("opencode.command", options.opencode.command, "string")
  if options.opencode.command == "" then
    config_error("opencode.command", "must not be empty")
  end

  validate_type("opencode.timeout_ms", options.opencode.timeout_ms, "number")
  if options.opencode.timeout_ms <= 0 then
    config_error("opencode.timeout_ms", "must be greater than zero")
  end

  if options.opencode.agent ~= nil and options.opencode.agent ~= false then
    validate_type("opencode.agent", options.opencode.agent, "string")
  end
  if options.opencode.model ~= nil and options.opencode.model ~= false then
    validate_type("opencode.model", options.opencode.model, "string")
  end
  if options.opencode.variant ~= nil and options.opencode.variant ~= false then
    validate_type("opencode.variant", options.opencode.variant, "string")
  end
  if options.opencode.attach ~= nil and options.opencode.attach ~= false then
    validate_type("opencode.attach", options.opencode.attach, "string")
  end
  validate_type("opencode.pure", options.opencode.pure, "boolean")
  validate_type("opencode.extra_args", options.opencode.extra_args, "table")
  for index, value in ipairs(options.opencode.extra_args) do
    validate_type(("opencode.extra_args[%d]"):format(index), value, "string")
  end

  validate_type("max_concurrent_jobs", options.max_concurrent_jobs, "number")
  if options.max_concurrent_jobs < 1 or options.max_concurrent_jobs % 1 ~= 0 then
    config_error("max_concurrent_jobs", "must be a positive integer")
  end

  local edit_modes = { review_patch = true, auto_apply = true }
  if not edit_modes[options.edits.mode] then
    config_error("edits.mode", "expected review_patch or auto_apply")
  end

  validate_type("answers.auto_open", options.answers.auto_open, "boolean")
  validate_type("keymaps.enable", options.keymaps.enable, "boolean")

  local mapping_names = {
    "enqueue",
    "enqueue_deep",
    "enqueue_with_intent",
    "enqueue_deep_with_intent",
    "directory",
    "directory_deep",
    "directory_summary",
    "review",
    "status",
    "diagnostics",
    "explain",
    "cancel",
  }
  for _, name in ipairs(mapping_names) do
    local value = options.keymaps[name]
    if value ~= nil and value ~= false and type(value) ~= "string" then
      config_error("keymaps." .. name, "expected a string or false")
    end
  end

  validate_type("profiles.default", options.profiles.default, "string")
  if type(options.profiles[options.profiles.default]) ~= "table" then
    config_error("profiles.default", "must name a configured profile")
  end
end

function M.setup(opts)
  if opts ~= nil and type(opts) ~= "table" then
    config_error("setup", "expected a table or nil")
  end
  local candidate = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  validate(candidate)
  M.options = candidate
  return M.options
end

function M.profile_name(name)
  local profiles = M.options.profiles or {}
  local fallback = profiles.default or "fast"
  local candidate = name or fallback

  if type(profiles[candidate]) == "table" then
    return candidate
  end
  if type(profiles[fallback]) == "table" then
    return fallback
  end
  return candidate
end

function M.for_profile(name)
  local profile_name = M.profile_name(name)
  local profile = (M.options.profiles or {})[profile_name] or {}

  return {
    name = profile_name,
    opencode = vim.tbl_deep_extend(
      "force",
      vim.deepcopy(M.options.opencode or {}),
      vim.deepcopy(profile.opencode or {})
    ),
    memory = vim.tbl_deep_extend("force", vim.deepcopy(M.options.memory or {}), vim.deepcopy(profile.memory or {})),
    architecture = vim.tbl_deep_extend(
      "force",
      vim.deepcopy(M.options.architecture or {}),
      vim.deepcopy(profile.architecture or {})
    ),
    directory = vim.tbl_deep_extend(
      "force",
      vim.deepcopy(M.options.directory or {}),
      vim.deepcopy(profile.directory or {})
    ),
    prompt = vim.tbl_deep_extend("force", vim.deepcopy(M.options.prompt or {}), vim.deepcopy(profile.prompt or {})),
  }
end

return M
