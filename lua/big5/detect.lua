--- lua/big5/detect.lua
--- Big5 encoding detection module.
--- No Neovim API dependency — uses only io.open and byte arithmetic.
--- This module can be unit-tested in isolation.

local M = {}

local SAMPLE_SIZE = 8192

--- Check whether a byte sequence is valid UTF-8.
--- Scans bytes according to the UTF-8 multi-byte encoding rules.
--- @param bytes string Raw bytes to validate
--- @return boolean True if the entire sequence is valid UTF-8
local function is_valid_utf8(bytes)
  local i = 1
  local len = #bytes
  while i <= len do
    local b = bytes:byte(i)
    if b <= 0x7F then
      -- Single-byte ASCII character
      i = i + 1
    elseif b >= 0xC2 and b <= 0xDF then
      -- Two-byte sequence
      if i + 1 > len then return false end
      local b2 = bytes:byte(i + 1)
      if b2 < 0x80 or b2 > 0xBF then return false end
      i = i + 2
    elseif b >= 0xE0 and b <= 0xEF then
      -- Three-byte sequence
      if i + 2 > len then return false end
      local b2 = bytes:byte(i + 1)
      local b3 = bytes:byte(i + 2)
      if b2 < 0x80 or b2 > 0xBF then return false end
      if b3 < 0x80 or b3 > 0xBF then return false end
      i = i + 3
    elseif b >= 0xF0 and b <= 0xF4 then
      -- Four-byte sequence
      if i + 3 > len then return false end
      local b2 = bytes:byte(i + 1)
      local b3 = bytes:byte(i + 2)
      local b4 = bytes:byte(i + 3)
      if b2 < 0x80 or b2 > 0xBF then return false end
      if b3 < 0x80 or b3 > 0xBF then return false end
      if b4 < 0x80 or b4 > 0xBF then return false end
      i = i + 4
    else
      -- 0xC0, 0xC1 (overlong), 0xF5-0xFF, or invalid: not valid UTF-8
      return false
    end
  end
  return true
end

--- Detect whether a file is Big5-encoded.
--- Algorithm:
---   1. Read up to 8192 bytes from the file (sample-based).
---   2. If the sample is valid UTF-8, return false (not Big5).
---   3. Scan for Big5 lead bytes (0x81-0xFE) and check their trail bytes.
---   4. If >= 80% of lead-byte candidates are valid Big5 sequences, return true.
---
--- @param filepath string Absolute path to the file on disk
--- @return boolean is_big5 True if the file appears to be Big5-encoded
--- @return table info { high_byte_sequences=number, valid_big5_sequences=number, ratio=number, sample_size=number, is_valid_utf8=boolean }
function M.is_big5(filepath)
  local info = {
    high_byte_sequences = 0,
    valid_big5_sequences = 0,
    ratio = 0,
    sample_size = 0,
    is_valid_utf8 = false,
  }

  -- Step 1: Read sample
  local f, err = io.open(filepath, "rb")
  if not f then
    return false, info
  end
  local sample = f:read(SAMPLE_SIZE)
  f:close()

  if not sample or sample == "" then
    return false, info
  end

  info.sample_size = #sample

  -- Step 2: UTF-8 validation — if valid UTF-8, it is not Big5
  if is_valid_utf8(sample) then
    info.is_valid_utf8 = true
    return false, info
  end

  -- Step 3: Big5 sequence scanning
  local i = 1
  local len = #sample
  local high_byte_sequences = 0
  local valid_big5_sequences = 0

  while i <= len do
    local b = sample:byte(i)
    if b >= 0x81 and b <= 0xFE then
      -- Candidate Big5 lead byte
      high_byte_sequences = high_byte_sequences + 1
      if i + 1 <= len then
        local trail = sample:byte(i + 1)
        -- Valid trail byte: 0x40-0x7E or 0xA1-0xFE
        if (trail >= 0x40 and trail <= 0x7E) or (trail >= 0xA1 and trail <= 0xFE) then
          valid_big5_sequences = valid_big5_sequences + 1
          i = i + 2
        else
          -- Invalid trail byte — advance past lead byte only
          i = i + 1
        end
      else
        -- Lead byte at end of sample with no trail byte
        i = i + 1
      end
    else
      -- ASCII byte (0x00-0x7F) or out-of-range byte: skip
      i = i + 1
    end
  end

  info.high_byte_sequences = high_byte_sequences
  info.valid_big5_sequences = valid_big5_sequences

  -- Step 4: Threshold check
  if high_byte_sequences == 0 then
    -- Pure ASCII (all bytes were in 0x00-0x7F range or no high-byte sequences found)
    return false, info
  end

  local ratio = valid_big5_sequences / high_byte_sequences
  info.ratio = ratio

  if ratio >= 0.80 then
    return true, info
  end

  return false, info
end

return M
