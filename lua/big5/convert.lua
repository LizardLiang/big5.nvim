--- lua/big5/convert.lua
--- Big5 to UTF-8 conversion module.
--- Depends on vim.iconv() (Neovim 0.8+) for encoding conversion.
--- Uses io.open for raw binary file I/O.
--- Does NOT register commands or autocmds.

local M = {}

--- Pre-scan raw bytes to detect invalid Big5 byte sequences.
--- A Big5 lead byte (0x81-0xFE) followed by an invalid trail byte
--- (i.e., NOT in 0x40-0x7E or 0xA1-0xFE) is an invalid sequence.
--- This pre-scan approach is used because vim.iconv()'s substitution
--- character for invalid bytes varies by platform (? on some systems,
--- U+FFFD on others). Pre-scanning the raw input gives consistent results.
---
--- @param bytes string Raw bytes to scan
--- @return boolean True if any invalid Big5 sequences are found
local function has_invalid_big5_sequences(bytes)
  local i = 1
  local len = #bytes
  while i <= len do
    local b = bytes:byte(i)
    if b >= 0x81 and b <= 0xFE then
      -- Big5 lead byte: check trail byte
      if i + 1 <= len then
        local trail = bytes:byte(i + 1)
        if (trail >= 0x40 and trail <= 0x7E) or (trail >= 0xA1 and trail <= 0xFE) then
          -- Valid Big5 double-byte sequence
          i = i + 2
        else
          -- Invalid trail byte: this is an invalid Big5 sequence
          return true
        end
      else
        -- Lead byte at end of file with no trail byte: invalid
        return true
      end
    else
      i = i + 1
    end
  end
  return false
end

--- Read and convert a Big5-encoded file to UTF-8 in memory (no disk write).
--- This is the first phase of the two-phase convert approach.
--- Call write() after confirming the result to persist the conversion.
---
--- @param filepath string Absolute path to the file on disk
--- @return table result { ok=boolean, err=string|nil, had_invalid_bytes=boolean, content=string|nil }
function M.try(filepath)
  -- Step 1: Read raw bytes from disk
  local f, open_err = io.open(filepath, "rb")
  if not f then
    return {
      ok = false,
      err = "Cannot read file: " .. (open_err or filepath),
      had_invalid_bytes = false,
      content = nil,
    }
  end

  local raw = f:read("*a")
  f:close()

  -- Handle empty file case
  if not raw or raw == "" then
    return {
      ok = false,
      err = "File is empty or unreadable: " .. filepath,
      had_invalid_bytes = false,
      content = nil,
    }
  end

  -- Step 2: Pre-scan for invalid Big5 sequences before calling iconv.
  -- This is more reliable than scanning the iconv output for substitution
  -- characters, because vim.iconv()'s substitution varies by platform.
  local had_invalid_bytes = has_invalid_big5_sequences(raw)

  -- Step 3: Convert using vim.iconv
  local converted = vim.iconv(raw, "big5", "utf-8")

  if converted == nil then
    return {
      ok = false,
      err = "Conversion failed: input may not be valid Big5",
      had_invalid_bytes = false,
      content = nil,
    }
  end

  -- Edge case: if input was non-empty but output is empty, treat as failure
  if #converted == 0 and #raw > 0 then
    return {
      ok = false,
      err = "Conversion failed: iconv returned empty output for non-empty input",
      had_invalid_bytes = false,
      content = nil,
    }
  end

  return {
    ok = true,
    err = nil,
    had_invalid_bytes = had_invalid_bytes,
    content = converted,
  }
end

--- Convert only the Big5 tail of a raw byte string to UTF-8, leaving
--- everything at or before `boundary` copied through byte-for-byte
--- untouched. Pure byte-string function -- no disk I/O, no filepath. This
--- is the conversion half of the mixed Big5/UTF-8 tail-sync feature: the
--- caller supplies the exact raw bytes of a buffer (see big5.buffer) and
--- the boundary found by detect.classify_mixed().
---
--- @param raw string Raw bytes: a UTF-8 prefix followed by a Big5 tail
--- @param boundary number Byte offset separating the prefix from the tail
--- @return table result { ok=boolean, err=string|nil, had_invalid_bytes=boolean,
---   content=string|nil, new_offset=number|nil }
---   content is prefix .. converted_tail; new_offset is #content, the value
---   to store as the new big5_synced_offset watermark.
---   boundary == #raw (empty tail) is a no-op success: content == raw.
function M.convert_tail_bytes(raw, boundary)
  local prefix = raw:sub(1, boundary)
  local tail_raw = raw:sub(boundary + 1)

  if tail_raw == "" then
    return {
      ok = true,
      err = nil,
      had_invalid_bytes = false,
      content = prefix,
      new_offset = #prefix,
    }
  end

  -- Pre-scan for invalid Big5 sequences in the tail only -- the prefix is
  -- already known-good UTF-8 and must never be touched.
  local had_invalid_bytes = has_invalid_big5_sequences(tail_raw)

  local converted_tail = vim.iconv(tail_raw, "big5", "utf-8")

  if converted_tail == nil then
    return {
      ok = false,
      err = "Conversion failed: tail may not be valid Big5",
      had_invalid_bytes = false,
      content = nil,
      new_offset = nil,
    }
  end

  -- Edge case: if the tail was non-empty but output is empty, treat as failure
  if #converted_tail == 0 and #tail_raw > 0 then
    return {
      ok = false,
      err = "Conversion failed: iconv returned empty output for non-empty tail",
      had_invalid_bytes = false,
      content = nil,
      new_offset = nil,
    }
  end

  local content = prefix .. converted_tail

  return {
    ok = true,
    err = nil,
    had_invalid_bytes = had_invalid_bytes,
    content = content,
    new_offset = #content,
  }
end

--- Write content to a file path in binary mode (overwrites existing file).
--- This is the second phase of the two-phase convert approach.
--- Only call this after try() succeeds and the user has confirmed.
---
--- @param filepath string Absolute path to the file on disk
--- @param content string The UTF-8 content to write
--- @return table result { ok=boolean, err=string|nil }
function M.write(filepath, content)
  local f, open_err = io.open(filepath, "wb")
  if not f then
    return {
      ok = false,
      err = "Cannot write file: " .. (open_err or filepath),
    }
  end

  local write_ok, write_err = f:write(content)
  if not write_ok then
    f:close()
    return {
      ok = false,
      err = "Write failed: " .. (write_err or "unknown error"),
    }
  end

  f:close()

  return { ok = true, err = nil }
end

return M
