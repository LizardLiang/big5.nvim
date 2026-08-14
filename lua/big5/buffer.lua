--- lua/big5/buffer.lua
--- Buffer-only raw byte I/O for the mixed Big5/UTF-8 tail-sync feature.
--- This is the ONLY module in the feature that touches nvim_buf_* / vim.bo.
--- Neither function here ever writes to disk -- write_content() leaves the
--- buffer modified-but-unsaved; the caller's next :w persists it.

local M = {}

--- The fileformat-aware line separator used to join/split buffer lines,
--- matching how Neovim itself would write the buffer to disk.
--- @param bufnr number Buffer handle
--- @return string sep "\r\n" for dos, "\r" for mac, "\n" otherwise (unix)
local function fileformat_sep(bufnr)
  local fileformat = vim.bo[bufnr].fileformat
  if fileformat == "dos" then
    return "\r\n"
  elseif fileformat == "mac" then
    return "\r"
  end
  return "\n"
end

--- Read the exact raw bytes of a buffer, byte-identical to what is
--- currently on disk for it.
---
--- Forces `:edit! ++enc=latin1`. `++enc=` is a hard override that bypasses
--- 'fileencodings' autodetection entirely; latin1 assigns every byte
--- 0x00-0xFF a defined codepoint, so the read cannot fail or substitute a
--- replacement character regardless of content. This is applied
--- unconditionally (no pre-check) -- it is safe and byte-identical even on
--- a pure-UTF-8 file with no Big5 tail, and even when fileencoding=utf-8
--- was already sticky-set on the buffer.
---
--- Neovim's internal buffer representation is always UTF-8: the latin1
--- load re-encodes each 0-255 codepoint into 1-2 internal UTF-8 bytes, and
--- vim.iconv() back to latin1 undoes that exactly, recovering the original
--- byte string.
---
--- WARNING: `:edit!` discards any unsaved changes in the buffer. This is
--- load-bearing, not incidental -- callers MUST guard against unsaved
--- modifications before calling this function.
---
--- @param bufnr number Buffer handle
--- @return string raw The exact original byte string
function M.read_raw_bytes(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("edit! ++enc=latin1")
  end)

  local sep = fileformat_sep(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local joined = table.concat(lines, sep)

  if vim.bo[bufnr].eol then
    joined = joined .. sep
  end

  return vim.iconv(joined, "utf-8", "latin1")
end

--- Write content back into a buffer without touching disk.
--- Splits on the same fileformat-aware separator used by read_raw_bytes(),
--- sets fileencoding=utf-8 (a passthrough at this point, since the
--- buffer's internal UTF-8 bytes already are the desired file bytes), and
--- leaves the buffer modified-but-unsaved. Does NOT call :write.
---
--- @param bufnr number Buffer handle
--- @param content string The UTF-8 content to write into the buffer
function M.write_content(bufnr, content)
  local sep = fileformat_sep(bufnr)

  local body = content
  local had_trailing_sep = #content > 0 and content:sub(-#sep) == sep
  if had_trailing_sep then
    body = content:sub(1, -(#sep) - 1)
  end

  local lines = vim.split(body, sep, { plain = true })

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].eol = had_trailing_sep
  -- 'fixeol' defaults to on and silently re-adds a trailing EOL on :w
  -- regardless of 'eol', which would corrupt the no-trailing-newline
  -- guarantee (and the byte length new_offset was computed from) the
  -- moment the user saves. Disable it whenever the content legitimately
  -- has no trailing separator so :w respects 'eol' as set above.
  vim.bo[bufnr].fixeol = had_trailing_sep
  vim.bo[bufnr].fileencoding = "utf-8"
end

return M
