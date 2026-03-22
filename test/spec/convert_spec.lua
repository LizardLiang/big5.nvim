--- test/spec/convert_spec.lua
--- Unit tests for lua/big5/convert.lua
--- Tests: TC-UNIT-C-01 through TC-UNIT-C-07
--- Requires Neovim runtime (vim.iconv). Run via plenary.nvim.

local convert = require("big5.convert")

-- Helper: create a temporary file with given binary content
local function write_tempfile(content)
  local path = os.tmpname()
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
  return path
end

-- Helper: read all bytes from a file
local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

-- Helper: remove a temp file
local function rm(path)
  os.remove(path)
end

-- UTF-8 encoding of U+FFFD (Unicode Replacement Character)
local REPLACEMENT_CHAR = "\xEF\xBF\xBD"

describe("convert.try", function()

  -- TC-UNIT-C-01: try() converts valid Big5 to UTF-8
  it("TC-UNIT-C-01: converts valid Big5 file to UTF-8 in memory", function()
    local result = convert.try("test/fixtures/big5_sample.txt")

    assert.is_true(result.ok, "Expected ok=true, got err: " .. tostring(result.err))
    assert.is_nil(result.err)
    assert.is_false(result.had_invalid_bytes)
    assert.is_truthy(result.content)
    assert.is_true(#result.content > 0)
    -- Must not contain U+FFFD
    assert.is_falsy(
      result.content:find(REPLACEMENT_CHAR, 1, true),
      "Content should not contain U+FFFD replacement character"
    )
  end)

  -- TC-UNIT-C-02: try() on UTF-8 file returns some result (no crash)
  it("TC-UNIT-C-02: does not crash when called on a UTF-8 file", function()
    local ok, err = pcall(function()
      local result = convert.try("test/fixtures/utf8_sample.txt")
      -- Key constraint: no crash, result is a table
      assert.is_table(result)
      -- ok may be true or false depending on iconv behavior with UTF-8-as-Big5
      -- The important thing is that no Lua error is raised
    end)
    assert.is_true(ok, "convert.try raised a Lua error on UTF-8 file: " .. tostring(err))
  end)

  -- TC-UNIT-C-03: try() on unreadable file returns ok=false with error
  it("TC-UNIT-C-03: returns ok=false with error message for non-existent file", function()
    local result = convert.try("/nonexistent/path/does_not_exist.txt")

    assert.is_false(result.ok)
    assert.is_truthy(result.err, "Expected an error message")
    assert.is_truthy(
      result.err:find("Cannot read file", 1, true),
      "Error message should contain 'Cannot read file', got: " .. tostring(result.err)
    )
    assert.is_nil(result.content)
  end)

  -- TC-UNIT-C-04: try() on Big5 file with invalid sequences sets had_invalid_bytes=true
  it("TC-UNIT-C-04: sets had_invalid_bytes=true when invalid byte sequences are present", function()
    local result = convert.try("test/fixtures/big5_with_invalid.txt")

    assert.is_true(result.ok, "Expected ok=true, got err: " .. tostring(result.err))
    assert.is_true(result.had_invalid_bytes, "Expected had_invalid_bytes=true")
    assert.is_truthy(result.content)
    -- The content should be non-empty (valid Big5 sequences were converted)
    assert.is_true(#result.content > 0, "Converted content should be non-empty")
    -- Note: had_invalid_bytes is detected by pre-scanning raw Big5 bytes, not
    -- by checking for U+FFFD in the converted output. This is because vim.iconv()
    -- substitution character behavior varies by platform.
  end)

  -- TC-UNIT-C-05: try() on empty file returns ok=false or empty content, no crash
  it("TC-UNIT-C-05: handles empty file gracefully without raising an error", function()
    local ok, err = pcall(function()
      local result = convert.try("test/fixtures/empty.txt")
      assert.is_table(result)
      -- Either ok=false with error, or ok=true with empty content
      if result.ok then
        assert.equal("", result.content or "")
      else
        assert.is_truthy(result.err, "Expected an error message for empty file")
      end
    end)
    assert.is_true(ok, "convert.try raised a Lua error on empty file: " .. tostring(err))
  end)

end)

describe("convert.write", function()

  -- TC-UNIT-C-06: write() writes content to disk correctly
  it("TC-UNIT-C-06: writes provided content to disk exactly", function()
    local path = os.tmpname()
    local content = "Hello, UTF-8 world: \xe4\xb8\xad\xe6\x96\x87"

    local result = convert.write(path, content)

    assert.is_true(result.ok, "Expected ok=true, got err: " .. tostring(result.err))
    assert.is_nil(result.err)

    -- Read back and verify byte-for-byte equality
    local on_disk = read_file(path)
    rm(path)

    assert.equal(content, on_disk)
  end)

  -- TC-UNIT-C-07: write() on unwritable path returns ok=false with error
  it("TC-UNIT-C-07: returns ok=false with error message for unwritable path", function()
    -- Use a path that cannot be created (directory doesn't exist)
    local result = convert.write("/nonexistent/directory/cannot_write.txt", "content")

    assert.is_false(result.ok)
    assert.is_truthy(result.err, "Expected an error message")
    assert.is_truthy(
      result.err:find("Cannot write file", 1, true),
      "Error message should contain 'Cannot write file', got: " .. tostring(result.err)
    )
  end)

  -- Additional: write() creates the file if it does not exist
  it("creates a new file when path does not yet exist", function()
    local path = os.tmpname()
    os.remove(path)  -- Ensure it doesn't exist

    local content = "new file content"
    local result = convert.write(path, content)

    assert.is_true(result.ok)
    local on_disk = read_file(path)
    rm(path)
    assert.equal(content, on_disk)
  end)

  -- Additional: write() overwrites existing file content
  it("overwrites an existing file with new content", function()
    local path = write_tempfile("original content")

    local new_content = "replacement content"
    local result = convert.write(path, new_content)

    assert.is_true(result.ok)
    local on_disk = read_file(path)
    rm(path)
    assert.equal(new_content, on_disk)
  end)

end)
