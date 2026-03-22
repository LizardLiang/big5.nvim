--- lua/big5/init.lua
--- Public API for the Big5 to UTF-8 Neovim plugin.
--- Exposes setup(opts), registers :Big5Check and :Big5ToUtf8 user commands,
--- and optionally registers a BufReadPost autocmd for auto-detection.

local M = {}

local detect = require("big5.detect")
local convert = require("big5.convert")

--- Default configuration values.
local defaults = {
  auto_detect = false,       -- Do not auto-detect on file open by default
  confirm_conversion = true, -- Prompt user before converting files with invalid bytes
}

-- Module-level config (populated by setup())
local config = {}

--- Initialize the plugin with user configuration.
--- Registers :Big5Check and :Big5ToUtf8 commands.
--- Optionally registers a BufReadPost autocmd when auto_detect is enabled.
---
--- @param opts table|nil { auto_detect = boolean, confirm_conversion = boolean }
function M.setup(opts)
  config = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Register :Big5Check command
  vim.api.nvim_create_user_command("Big5Check", function()
    local filepath = vim.api.nvim_buf_get_name(0)

    if filepath == "" then
      vim.notify(
        "No file associated with current buffer. Save the buffer first.",
        vim.log.levels.ERROR
      )
      return
    end

    local is_big5, info = detect.is_big5(filepath)

    if is_big5 then
      vim.notify(
        string.format(
          "File appears to be Big5-encoded (ratio: %.0f%%, sequences: %d)",
          (info.ratio or 0) * 100,
          info.valid_big5_sequences or 0
        ),
        vim.log.levels.INFO
      )
    else
      vim.notify(
        "File does not appear to be Big5-encoded.",
        vim.log.levels.INFO
      )
    end
  end, { desc = "Check if the current file is Big5-encoded" })

  -- Register :Big5ToUtf8 command
  vim.api.nvim_create_user_command("Big5ToUtf8", function()
    local filepath = vim.api.nvim_buf_get_name(0)

    -- Guard: buffer must have an associated file
    if filepath == "" then
      vim.notify(
        "No file associated with current buffer. Save the buffer first.",
        vim.log.levels.ERROR
      )
      return
    end

    -- Step 1: Unsaved buffer check
    if vim.bo.modified then
      local answer = vim.fn.input("Buffer has unsaved changes that will be lost. Proceed? [y/N] ")
      if answer ~= "y" and answer ~= "Y" then
        vim.notify(
          "Conversion cancelled. No changes made.",
          vim.log.levels.INFO
        )
        return
      end
    end

    -- Step 2: Detection — only convert if the file is actually Big5
    local is_big5 = detect.is_big5(filepath)
    if not is_big5 then
      vim.notify(
        "File does not appear to be Big5-encoded. No conversion performed.",
        vim.log.levels.WARN
      )
      return
    end

    -- Step 3: Convert in memory (try phase — no disk write yet)
    local result = convert.try(filepath)
    if not result.ok then
      vim.notify(
        "Conversion failed: " .. (result.err or "unknown error"),
        vim.log.levels.ERROR
      )
      return
    end

    -- Step 4: Invalid byte warning and confirmation (if applicable)
    if result.had_invalid_bytes and config.confirm_conversion then
      local answer = vim.fn.input(
        "Warning: File contains byte sequences that could not be converted. Proceed anyway? [y/N] "
      )
      if answer ~= "y" and answer ~= "Y" then
        vim.notify(
          "Conversion cancelled. No changes made.",
          vim.log.levels.INFO
        )
        return
      end
    end

    -- Step 5: Write converted content to disk
    local write_result = convert.write(filepath, result.content)
    if not write_result.ok then
      vim.notify(
        "Write failed: " .. (write_result.err or "unknown error"),
        vim.log.levels.ERROR
      )
      return
    end

    -- Step 6: Reload buffer from disk
    vim.cmd("edit!")

    -- Step 7: Set fileencoding to utf-8 for this buffer
    vim.bo.fileencoding = "utf-8"

    -- Step 8: Success notification
    local filename = vim.fn.fnamemodify(filepath, ":t")
    vim.notify(
      string.format("Converted %s from Big5 to UTF-8.", filename),
      vim.log.levels.INFO
    )
  end, { desc = "Convert the current file from Big5 to UTF-8 in place" })

  -- Register auto-detect autocmd only when enabled
  if config.auto_detect then
    local augroup = vim.api.nvim_create_augroup("Big5AutoDetect", { clear = true })
    vim.api.nvim_create_autocmd("BufReadPost", {
      group = augroup,
      callback = function(args)
        local filepath = args.file
        if filepath == "" then return end
        local is_big5 = detect.is_big5(filepath)
        if is_big5 then
          vim.notify(
            "This file appears to be Big5-encoded. Use :Big5ToUtf8 to convert.",
            vim.log.levels.INFO
          )
        end
      end,
    })
  else
    -- Ensure the augroup is cleared if auto_detect is disabled
    -- (handles repeated setup() calls with different config)
    vim.api.nvim_create_augroup("Big5AutoDetect", { clear = true })
  end
end

return M
