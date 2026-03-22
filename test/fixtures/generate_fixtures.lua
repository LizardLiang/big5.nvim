--- test/fixtures/generate_fixtures.lua
--- Programmatically generates all test fixture files with verified byte content.
--- Run this script once to create fixtures before running the test suite:
---   lua test/fixtures/generate_fixtures.lua
---
--- Fixtures must be binary-exact — do not edit them with a text editor.

local fixtures_dir = "test/fixtures"

local function write_binary(filename, bytes)
  local path = fixtures_dir .. "/" .. filename
  local f = assert(io.open(path, "wb"), "Cannot open " .. path .. " for writing")
  f:write(bytes)
  f:close()
  print("Created: " .. path .. " (" .. #bytes .. " bytes)")
end

-- ---------------------------------------------------------------------------
-- big5_sample.txt
-- Valid Big5-encoded Traditional Chinese text.
-- Content (UTF-8 meaning): "Taiwan Hello World Chinese Text Test"
-- The bytes below are the Big5 encoding of common Traditional Chinese chars.
-- Verified Big5 byte sequences:
--   0xA4 0xA4 = 中 (zhong, middle/China)
--   0xA4 0xE5 = 文 (wen, text/language)
--   0xB0 0xC5 = 測 (ce, test)
--   0xB8 0xD5 = 試 (shi, test/try)
--   0xA5 0x4E = 你 (ni, you)
--   0xA6 0x6E = 好 (hao, good/hello)
--   0xA5 0x60 = 台 (tai, Taiwan)
--   0xC6 0x57 = 灣 (wan, bay/Taiwan)
-- We repeat these sequences to create a >500 byte file with high Big5 ratio.
-- ---------------------------------------------------------------------------
do
  -- Build a block of valid Big5 sequences
  -- 中文測試你好台灣 repeated many times
  local block = ""
    .. "\xA4\xA4"  -- 中
    .. "\xA4\xE5"  -- 文
    .. "\xB0\xC5"  -- 測
    .. "\xB8\xD5"  -- 試
    .. "\xA5\x4E"  -- 你
    .. "\xA6\x6E"  -- 好
    .. "\xA5\x60"  -- 台
    .. "\xC6\x57"  -- 灣
    .. "\xA4\xA4"  -- 中
    .. "\xA4\xE5"  -- 文
    .. "\xB0\xC5"  -- 測
    .. "\xB8\xD5"  -- 試

  -- Repeat to reach >500 bytes
  local content = ""
  for _ = 1, 22 do
    content = content .. block
  end

  write_binary("big5_sample.txt", content)
end

-- ---------------------------------------------------------------------------
-- utf8_sample.txt
-- UTF-8 encoded Chinese text. Must NOT be detected as Big5.
-- Same semantic content: 中文測試你好台灣
-- ---------------------------------------------------------------------------
do
  local block = "中文測試你好台灣"
  local content = ""
  for _ = 1, 20 do
    content = content .. block .. "\n"
  end
  write_binary("utf8_sample.txt", content)
end

-- ---------------------------------------------------------------------------
-- ascii_only.txt
-- Pure ASCII text. No bytes above 0x7F.
-- ---------------------------------------------------------------------------
do
  local lines = {
    "This is a plain ASCII test file.\n",
    "It contains no characters above 0x7F.\n",
    "Hello, World! 1234567890\n",
    "The quick brown fox jumps over the lazy dog.\n",
    "No encoding detection should match this file as Big5.\n",
  }
  local content = ""
  for _ = 1, 8 do
    for _, line in ipairs(lines) do
      content = content .. line
    end
  end
  write_binary("ascii_only.txt", content)
end

-- ---------------------------------------------------------------------------
-- big5_with_invalid.txt
-- Valid Big5 sequences with injected invalid byte pairs.
-- Invalid pair: 0x81 followed by 0x80 (0x80 is NOT a valid Big5 trail byte).
-- We include enough valid sequences to stay above 80% ratio overall,
-- but include some invalid ones so had_invalid_bytes is triggered by iconv.
-- ---------------------------------------------------------------------------
do
  -- Valid Big5 sequences (~90% of pairs)
  local valid_pair = "\xA4\xA4"  -- 中
  -- Invalid Big5 pair (lead 0x81, trail 0x80 which is in the gap 0x80-0xA0)
  local invalid_pair = "\x81\x80"

  local content = ""
  -- 27 valid pairs, 3 invalid pairs = 30 high-byte candidates
  -- ratio = 27/30 = 90% valid (above 80% threshold, so detection returns true)
  -- iconv will produce U+FFFD for the invalid pairs
  for i = 1, 10 do
    content = content .. valid_pair .. valid_pair .. valid_pair .. invalid_pair
  end
  -- Pad to ensure > 300 bytes
  for _ = 1, 5 do
    content = content .. valid_pair .. valid_pair .. valid_pair .. valid_pair
  end

  write_binary("big5_with_invalid.txt", content)
end

-- ---------------------------------------------------------------------------
-- empty.txt
-- Zero bytes.
-- ---------------------------------------------------------------------------
write_binary("empty.txt", "")

-- ---------------------------------------------------------------------------
-- short_big5.txt
-- Very short Big5 file: a few Traditional Chinese characters (10-50 bytes).
-- ---------------------------------------------------------------------------
do
  -- 中文 = 4 bytes in Big5, 你好 = 4 bytes = 8 bytes total
  -- Repeat 3 times = 24 bytes
  local content = "\xA4\xA4\xA4\xE5\xA5\x4E\xA6\x6E\xA4\xA4\xA4\xE5\xA5\x4E\xA6\x6E\xA4\xA4\xA4\xE5\xA5\x4E\xA6\x6E"
  write_binary("short_big5.txt", content)
end

-- ---------------------------------------------------------------------------
-- binary_random.txt
-- Random-ish binary data that is neither valid UTF-8 nor high-ratio Big5.
-- We construct bytes that mix invalid UTF-8 starts with invalid Big5 trail bytes.
-- Pattern: byte sequences with lead bytes followed by out-of-range trail bytes.
-- This keeps Big5 ratio well below 80%.
-- ---------------------------------------------------------------------------
do
  -- Create bytes that look like high-byte sequences but with invalid trails
  -- Lead byte: 0x81-0xFE range; Trail byte: 0x80-0x9F range (invalid for Big5)
  -- This ensures high_byte_sequences > 0 but valid_big5_sequences is low
  local content = ""
  for i = 0, 249 do
    -- Lead byte in Big5 range (0x81-0xFE)
    local lead = 0x81 + (i % 0x7D)
    -- Trail byte in invalid range (0x7F-0x9F — mostly invalid for Big5)
    local trail = 0x7F + (i % 0x20)
    content = content .. string.char(lead) .. string.char(trail)
    -- Add some ASCII to pad
    content = content .. string.char(0x41 + (i % 26))
    content = content .. string.char(0x61 + (i % 26))
  end
  write_binary("binary_random.txt", content)
end

print("\nAll fixtures generated successfully.")
print("Run the test suite with:")
print("  nvim --headless -c \"PlenaryBustedDirectory test/ {minimal_init = 'test/minimal_init.lua'}\" -c \"qa\"")
