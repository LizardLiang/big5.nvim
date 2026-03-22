--- test/spec/detect_spec.lua
--- Unit tests for lua/big5/detect.lua
--- Tests: TC-UNIT-D-01 through TC-UNIT-D-10

local detect = require("big5.detect")

-- Helper: create a temporary file with given binary content
local function write_tempfile(content)
  local path = os.tmpname()
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
  return path
end

-- Helper: remove a temp file
local function rm(path)
  os.remove(path)
end

describe("detect.is_big5", function()

  -- TC-UNIT-D-01: Valid Big5 file returns true
  it("TC-UNIT-D-01: returns true for a valid Big5 file", function()
    local is_big5, info = detect.is_big5("test/fixtures/big5_sample.txt")
    assert.is_true(is_big5)
    assert.is_true(info.ratio >= 0.80)
    assert.is_false(info.is_valid_utf8)
    assert.is_true(info.valid_big5_sequences > 0)
  end)

  -- TC-UNIT-D-02: UTF-8 file returns false
  it("TC-UNIT-D-02: returns false for a UTF-8 file", function()
    local is_big5, info = detect.is_big5("test/fixtures/utf8_sample.txt")
    assert.is_false(is_big5)
    assert.is_true(info.is_valid_utf8)
  end)

  -- TC-UNIT-D-03: Pure ASCII file returns false
  it("TC-UNIT-D-03: returns false for a pure ASCII file", function()
    local is_big5, info = detect.is_big5("test/fixtures/ascii_only.txt")
    assert.is_false(is_big5)
    assert.equal(0, info.high_byte_sequences)
  end)

  -- TC-UNIT-D-04: Empty file returns false without error
  it("TC-UNIT-D-04: returns false for an empty file without raising an error", function()
    local ok, err = pcall(function()
      local is_big5 = detect.is_big5("test/fixtures/empty.txt")
      assert.is_false(is_big5)
    end)
    assert.is_true(ok, "detect.is_big5 raised an error on empty file: " .. tostring(err))
  end)

  -- TC-UNIT-D-05: Non-existent file returns false without error
  it("TC-UNIT-D-05: returns false for a non-existent file without raising an error", function()
    local ok, err = pcall(function()
      local is_big5 = detect.is_big5("/path/that/does/not/exist/fixture.txt")
      assert.is_false(is_big5)
    end)
    assert.is_true(ok, "detect.is_big5 raised an error on missing file: " .. tostring(err))
  end)

  -- TC-UNIT-D-06: Short Big5 file (< 100 bytes) returns true
  it("TC-UNIT-D-06: returns true for a short Big5 file (< 100 bytes)", function()
    local is_big5, info = detect.is_big5("test/fixtures/short_big5.txt")
    assert.is_true(is_big5)
    assert.is_true(info.sample_size < 100)
    assert.is_true(info.ratio >= 0.80)
  end)

  -- TC-UNIT-D-07: File larger than 8192 bytes only samples first 8192 bytes
  it("TC-UNIT-D-07: samples only the first 8192 bytes for a large file", function()
    -- First 8192 bytes = valid Big5 sequences; the rest = garbage that would fail
    local big5_block = ""
    while #big5_block < 8192 do
      big5_block = big5_block .. "\xA4\xA4\xA4\xE5\xB0\xC5\xB8\xD5"
    end
    -- Trim to exactly 8192 bytes
    big5_block = big5_block:sub(1, 8192)
    -- Append garbage bytes that would lower the ratio if sampled
    local garbage = string.rep("\xFE\x80\xFE\x80\xFE\x80\xFE\x80", 200)
    local content = big5_block .. garbage

    local path = write_tempfile(content)
    local is_big5, info = detect.is_big5(path)
    rm(path)

    assert.is_true(is_big5)
    assert.equal(8192, info.sample_size)
  end)

  -- TC-UNIT-D-08: Big5 ratio at 75% (below threshold) returns false
  it("TC-UNIT-D-08: returns false when valid Big5 ratio is 75% (below 80% threshold)", function()
    -- Construct: 3 valid Big5 pairs + 1 invalid pair = 75% ratio
    -- Repeat enough times so high_byte_sequences is meaningful
    local valid_pair = "\xA4\xA4"    -- valid Big5: 中
    local invalid_pair = "\x81\x80"  -- invalid trail byte 0x80

    local content = ""
    for _ = 1, 50 do
      -- 3 valid, 1 invalid => 75% ratio
      content = content .. valid_pair .. valid_pair .. valid_pair .. invalid_pair
    end

    local path = write_tempfile(content)
    local is_big5, info = detect.is_big5(path)
    rm(path)

    assert.is_false(is_big5)
    -- Verify ratio is around 75%
    assert.is_true(info.ratio < 0.80, "Expected ratio < 0.80, got " .. tostring(info.ratio))
  end)

  -- TC-UNIT-D-09: Big5 ratio at 82% (above threshold) returns true
  it("TC-UNIT-D-09: returns true when valid Big5 ratio is 82% (above 80% threshold)", function()
    -- Construct: 82 valid + 18 invalid = 82% out of 100
    -- Use pairs: 41 valid, 9 invalid per 50-pair block
    local valid_pair = "\xA4\xA4"    -- valid Big5: 中
    local invalid_pair = "\x81\x80"  -- invalid trail byte

    local content = ""
    for _ = 1, 5 do
      -- Build 41 valid pairs + 9 invalid pairs per iteration
      for _ = 1, 41 do
        content = content .. valid_pair
      end
      for _ = 1, 9 do
        content = content .. invalid_pair
      end
    end

    local path = write_tempfile(content)
    local is_big5, info = detect.is_big5(path)
    rm(path)

    assert.is_true(is_big5)
    assert.is_true(info.ratio >= 0.80, "Expected ratio >= 0.80, got " .. tostring(info.ratio))
  end)

  -- TC-UNIT-D-10: Random binary data returns false
  it("TC-UNIT-D-10: returns false for random binary data", function()
    local is_big5 = detect.is_big5("test/fixtures/binary_random.txt")
    assert.is_false(is_big5)
  end)

end)
