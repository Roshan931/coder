# Contributing

Issues and pull requests are welcome.

## Development

Requirements:

- Neovim 0.11 or newer
- Git
- OpenCode for manual integration testing

Run the deterministic tests from the repository root:

```sh
nvim --headless -u tests/minimal_init.lua -i NONE -c "luafile tests/smoke.lua"
nvim --headless -u NONE -i NONE -c "set runtimepath^=." -c "luafile tests/setup_lifecycle.lua"
nvim --headless -u NONE -i NONE -c "luafile tests/process.lua"
```

Run `stylua --check lua plugin tests` before opening a pull request. Keep tests deterministic; do not require a configured model or network access in CI.
