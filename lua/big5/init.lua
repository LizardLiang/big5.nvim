--- lua/big5/init.lua
--- Public API for the Big5 to UTF-8 Neovim plugin.
--- Exposes setup(opts), registers :Big5Check and :Big5ToUtf8 user commands,
--- and optionally registers a BufReadPost autocmd for auto-detection.

local M = {}

local detect = require("big5.detect")
local convert = require("big5.convert")
local buffer = require("big5.buffer")

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

    -- Step 2: Detection.
    -- Recover the buffer's raw bytes and classify them BEFORE trusting
    -- detect.is_big5()'s whole-file verdict alone. is_big5() samples only
    -- the first 8192 bytes; for a small mixed file (whole file fits in
    -- that sample) a genuine UTF-8 CJK prefix can misread as quasi-Big5-
    -- valid pairs when combined with a real Big5 tail in the same sample,
    -- pushing the combined ratio over 80% even though the prefix is
    -- perfectly valid UTF-8. Trusting is_big5() alone in that case would
    -- route the file into the destructive whole-file branch below, which
    -- would then iconv the valid CJK prefix as if it were Big5 and
    -- silently corrupt it on disk.
    --
    -- INVARIANT: the destructive whole-file disk branch below must NEVER
    -- run on a file that has a meaningful (non-empty) valid UTF-8 prefix.
    -- classify_mixed's boundary is the real disambiguator and overrides
    -- is_big5()'s verdict whenever it finds one. detect.is_big5() itself
    -- is not modified and still governs every other case exactly as
    -- before (its own tests are unaffected) -- it is no longer the SOLE
    -- gate, but it is still consulted for the genuinely-whole-file case
    -- (classify_mixed boundary == 0, i.e. no real UTF-8 prefix at all).
    --
    -- This gates on `classification.boundary` alone, NOT on
    -- `classification.status`. Every status that classify_mixed can
    -- return -- "mixed", "tail_not_big5", and "unclassifiable" -- carries
    -- a boundary that already passed UTF-8 validation; only the tail
    -- verdict differs between them. Gating on status == "mixed" would
    -- leave "tail_not_big5" and "unclassifiable" (both of which still
    -- point at a genuine, already-validated UTF-8 prefix) falling through
    -- to is_big5()'s crude whole-sample scan -- the exact misread this
    -- invariant exists to prevent. "up_to_date" is unaffected by widening
    -- this to boundary-only: is_big5() already returns false on a fully
    -- valid UTF-8 sample on its own, so skipping the call for that case
    -- changes nothing observable.
    local bufnr = vim.api.nvim_get_current_buf()
    local raw = buffer.read_raw_bytes(bufnr)
    local had_prior_sync = vim.b[bufnr].big5_synced_offset ~= nil
    local classification = detect.classify_mixed(raw, vim.b[bufnr].big5_synced_offset)
    local has_meaningful_utf8_prefix = classification.boundary ~= nil and classification.boundary > 0

    local is_big5 = (not has_meaningful_utf8_prefix) and detect.is_big5(filepath)

    if not is_big5 then
      -- Fallback: today's whole-file heuristic gives up here (or is
      -- overridden above by a detected UTF-8 prefix), but the file may
      -- still be a UTF-8 prefix with a Big5 tail appended afterwards (e.g.
      -- an external producer still writing Big5 bytes to a file already
      -- converted to UTF-8). This branch NEVER writes to disk — it only
      -- fixes the buffer, which is left modified-but-unsaved.
      if classification.status == "mixed" then
        local tail_result = convert.convert_tail_bytes(raw, classification.boundary)
        if not tail_result.ok then
          vim.cmd("edit!")
          vim.notify(
            "Conversion failed: " .. (tail_result.err or "unknown error"),
            vim.log.levels.ERROR
          )
          return
        end

        if tail_result.had_invalid_bytes and config.confirm_conversion then
          local answer = vim.fn.input(
            "Warning: The appended part contains byte sequences that could not be converted. Proceed anyway? [y/N] "
          )
          if answer ~= "y" and answer ~= "Y" then
            vim.cmd("edit!")
            vim.notify(
              "Conversion cancelled. No changes made.",
              vim.log.levels.INFO
            )
            return
          end
        end

        buffer.write_content(bufnr, tail_result.content)
        vim.b[bufnr].big5_synced_offset = tail_result.new_offset

        local filename = vim.fn.fnamemodify(filepath, ":t")
        vim.notify(
          string.format(
            "Converted %d new Big5 byte(s) to UTF-8 in the buffer. "
              .. "The file on disk is still unchanged. Save with :w to write %s.",
            #classification.tail,
            filename
          ),
          vim.log.levels.INFO
        )
        return
      elseif classification.status == "up_to_date" then
        -- Heal the watermark so the next run takes the fast path, then
        -- restore the buffer's normal display (read_raw_bytes forced a
        -- latin1 reload purely to recover raw bytes; nothing was
        -- converted, so undo that reload).
        vim.b[bufnr].big5_synced_offset = classification.boundary
        vim.cmd("edit!")
        if had_prior_sync then
          vim.notify(
            "No new Big5 content found. The buffer is already up to date.",
            vim.log.levels.INFO
          )
        else
          vim.notify(
            "File does not appear to be Big5-encoded. No conversion performed.",
            vim.log.levels.WARN
          )
        end
        return
      else
        -- "tail_not_big5" or "unclassifiable": never guess, never write.
        vim.cmd("edit!")
        vim.notify(
          "Found appended bytes that do not look like Big5 text. No changes made.",
          vim.log.levels.WARN
        )
        return
      end
    end

    -- Step 3: Convert in memory (try phase — no disk write yet)
    -- NOTE: buffer.read_raw_bytes() above already forced an
    -- ++enc=latin1 reload on this buffer (unconditionally, on every
    -- invocation, so the mixed-tail classification above could run before
    -- deciding which branch to take). Every return from here on that does
    -- NOT go on to successfully convert.write() + edit! (Step 5/6 below)
    -- must restore the buffer with edit! first, or the user is left
    -- looking at a raw latin1 byte-dump instead of their file.
    -- No dedicated integration-level test discriminates this restore path
    -- (unlike Step 4's, see TC-INT-02B in integration_spec.lua): reliably
    -- triggering convert.try() failure here requires the file to still be
    -- readable when buffer.read_raw_bytes() ran moments earlier (Step 2)
    -- but not by the time this io.open() runs -- a race window with no
    -- deterministic, portable way to hit it in a test (as opposed to
    -- exploiting a coincidental fileencodings quirk, which is what made
    -- TC-INT-02B's environment-controlled comparison work at all). Fixed
    -- on the same reasoning as Step 4/5's restores regardless.
    local result = convert.try(filepath)
    if not result.ok then
      vim.cmd("edit!")
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
        vim.cmd("edit!")
        vim.notify(
          "Conversion cancelled. No changes made.",
          vim.log.levels.INFO
        )
        return
      end
    end

    -- Step 5: Write converted content to disk
    -- Also without a dedicated discriminating integration test: reliably
    -- triggering convert.write() failure needs the file to become
    -- unwritable (e.g. a read-only attribute) between Step 3's read and
    -- this write, which is only reliably settable via a platform-specific
    -- mechanism (e.g. Windows `attrib +r`) with no equivalent portable
    -- across the OSes this suite targets. Fixed on the same reasoning as
    -- Step 3/4's restores regardless.
    local write_result = convert.write(filepath, result.content)
    if not write_result.ok then
      vim.cmd("edit!")
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

    -- Record the sync watermark so a subsequent mixed-tail run (if this
    -- file gets Big5 bytes appended to it again later) can take the fast
    -- path instead of re-scanning the whole file.
    vim.b[vim.api.nvim_get_current_buf()].big5_synced_offset = #result.content

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
          return
        end

        -- Notify-only mixed-tail check: a plain disk read, no buffer
        -- reload, no prompt, no conversion -- just an extra heads-up on
        -- top of the read-only inspection is_big5() already does here.
        -- Uses the bounded check (constant I/O, at most 2 * SAMPLE_SIZE
        -- bytes) rather than classify_mixed() directly, since this runs on
        -- every buffer open when auto_detect is enabled and must not scale
        -- with file size.
        if detect.looks_mixed_bounded(filepath) then
          vim.notify(
            "This file has new Big5 content appended. Use :Big5ToUtf8 to convert it in the buffer.",
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
