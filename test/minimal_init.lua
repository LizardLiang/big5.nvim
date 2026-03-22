--- test/minimal_init.lua
--- Minimal Neovim configuration for running the test suite via plenary.nvim.
--- This file is the entry point for all automated test runs.
---
--- Usage:
---   nvim --headless -c "PlenaryBustedDirectory test/ {minimal_init = 'test/minimal_init.lua'}" -c "qa"

-- Determine the plugin root (two levels up from test/)
local plugin_root = vim.fn.fnamemodify(vim.fn.expand("<sfile>:p"), ":h:h")

-- Add the plugin's lua/ directory to runtimepath so require("big5") works
vim.opt.runtimepath:prepend(plugin_root)

-- Locate plenary.nvim — try common plugin manager paths
-- Users should ensure plenary is on their runtimepath when running tests.
-- For CI or standalone test runs, you can set PLENARY_PATH env var.
local plenary_path = os.getenv("PLENARY_PATH")
if plenary_path then
  vim.opt.runtimepath:prepend(plenary_path)
else
  -- Attempt to find plenary in common locations
  local candidates = {
    vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
    vim.fn.expand("~/.local/share/nvim/site/pack/packer/start/plenary.nvim"),
    vim.fn.expand("~/.config/nvim/pack/plugins/start/plenary.nvim"),
    vim.fn.expand("~/AppData/Local/nvim-data/lazy/plenary.nvim"),
  }
  for _, candidate in ipairs(candidates) do
    if vim.fn.isdirectory(candidate) == 1 then
      vim.opt.runtimepath:prepend(candidate)
      break
    end
  end
end

-- Set the working directory to the plugin root so fixture paths resolve correctly
vim.fn.chdir(plugin_root)

-- Disable swap files and startup messages for clean test output
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false

-- Set fileencoding default to utf-8
vim.opt.encoding = "utf-8"
vim.opt.fileencoding = "utf-8"
