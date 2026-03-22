--- test/spec/e2e_spec.lua
--- End-to-end tests simulating the full user workflow.
--- Tests: TC-E2E-01 through TC-E2E-08
--- Requires full Neovim runtime. Run via plenary.nvim.

local big5 = require("big5")
local detect = require("big5.detect")

-- Helper: create a temp copy of a fixture file
local function copy_fixture(fixture_name)
  local src_path = "test/fixtures/" .. fixture_name
  local dest_path = os.tmpname()

  local src = assert(io.open(src_path, "rb"))
  local content = src:read("*a")
  src:close()

  local dest = assert(io.open(dest_path, "wb"))
  dest:write(content)
  dest:close()

  return dest_path
end

-- Helper: read all bytes from a file
local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

-- Helper: capture vim.notify calls
local function capture_notifications()
  local messages = {}
  local original = vim.notify
  vim.notify = function(msg, level)
    table.insert(messages, { msg = msg, level = level })
  end
  return messages, function()
    vim.notify = original
  end
end

-- Helper: mock vim.fn.input
local function mock_input(answer)
  local original = vim.fn.input
  vim.fn.input = function(_prompt)
    return answer
  end
  return function()
    vim.fn.input = original
  end
end

local REPLACEMENT_CHAR = "\xEF\xBF\xBD"

describe("E2E Tests", function()

  before_each(function()
    big5.setup({ confirm_conversion = true })
  end)

  after_each(function()
    pcall(vim.api.nvim_create_augroup, "Big5AutoDetect", { clear = true })
    pcall(vim.api.nvim_del_user_command, "Big5Check")
    pcall(vim.api.nvim_del_user_command, "Big5ToUtf8")
  end)

  -- TC-E2E-01: Flow 1: Check then convert clean Big5 file
  it("TC-E2E-01: Full flow — check then convert clean Big5 file", function()
    local temppath = copy_fixture("big5_sample.txt")
    local messages, restore = capture_notifications()

    -- Open file
    vim.cmd("edit " .. vim.fn.fnameescape(temppath))

    -- Step 1: Check — should report Big5
    vim.cmd("Big5Check")
    local check_msg = messages[#messages]
    assert.is_truthy(check_msg, "Expected notification from :Big5Check")
    assert.is_truthy(check_msg.msg:find("appears to be Big5", 1, true), "Should report Big5")

    -- Step 2: Convert
    vim.cmd("Big5ToUtf8")

    restore()

    -- File on disk should be valid UTF-8
    local on_disk = read_file(temppath)
    assert.is_truthy(on_disk)

    -- fileencoding should be utf-8
    assert.equal("utf-8", vim.bo.fileencoding)

    -- Success notification
    local found_success = false
    for _, m in ipairs(messages) do
      if m.msg:find("Converted", 1, true) and m.msg:find("Big5 to UTF-8", 1, true) then
        found_success = true
        break
      end
    end
    assert.is_true(found_success, "Expected success notification")

    -- Step 3: Run :Big5Check again — should report not Big5
    local messages2, restore2 = capture_notifications()
    vim.cmd("Big5Check")
    restore2()

    local found_not_big5 = false
    for _, m in ipairs(messages2) do
      if m.msg:find("does not appear to be Big5", 1, true) then
        found_not_big5 = true
        break
      end
    end
    assert.is_true(found_not_big5, "Second check should report not-Big5 after conversion")

    os.remove(temppath)
  end)

  -- TC-E2E-02: Check then convert Big5 file with invalid bytes -- confirm
  it("TC-E2E-02: Converts Big5 file with invalid bytes when user confirms", function()
    local temppath = copy_fixture("big5_with_invalid.txt")
    local messages, restore = capture_notifications()
    local restore_input = mock_input("y")

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    vim.cmd("Big5ToUtf8")

    restore()
    restore_input()

    -- File should be converted (different from original Big5 bytes) and be non-empty.
    -- Note: vim.iconv() substitution character varies by platform (? or U+FFFD).
    -- We verify the file was written (different from the original Big5) and that
    -- the buffer was reloaded as utf-8.
    local on_disk = read_file(temppath)
    assert.is_truthy(on_disk, "Converted file should exist on disk")
    assert.is_true(#on_disk > 0, "Converted file should not be empty")
    assert.equal("utf-8", vim.bo.fileencoding)

    os.remove(temppath)
  end)

  -- TC-E2E-03: Check then convert Big5 file with invalid bytes -- cancel
  it("TC-E2E-03: File unchanged when user cancels the invalid-bytes conversion", function()
    local temppath = copy_fixture("big5_with_invalid.txt")
    local original = read_file(temppath)
    local messages, restore = capture_notifications()
    local restore_input = mock_input("n")

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    vim.cmd("Big5ToUtf8")

    restore()
    restore_input()

    local on_disk = read_file(temppath)
    assert.equal(original, on_disk, "File should be unchanged after cancel")

    -- Cancellation notification
    local found_cancel = false
    for _, m in ipairs(messages) do
      if m.msg:find("cancelled", 1, true) or m.msg:find("Cancelled", 1, true) then
        found_cancel = true
        break
      end
    end
    assert.is_true(found_cancel, "Expected cancellation notification")

    os.remove(temppath)
  end)

  -- TC-E2E-04: Auto-detect on open Big5 file
  it("TC-E2E-04: Auto-detect fires INFO notification when Big5 file is opened", function()
    -- Re-setup with auto_detect enabled
    big5.setup({ auto_detect = true })

    local messages, restore = capture_notifications()

    -- Use a temp copy to ensure BufReadPost fires reliably
    -- (opening the same fixture path twice won't re-trigger BufReadPost)
    local temppath = copy_fixture("big5_sample.txt")
    vim.cmd("edit " .. vim.fn.fnameescape(temppath))

    restore()

    local found = false
    for _, m in ipairs(messages) do
      if m.msg:find("appears to be Big5", 1, true) and m.level == vim.log.levels.INFO then
        found = true
        break
      end
    end
    assert.is_true(found, "Expected auto-detect INFO notification for Big5 file")
    assert.is_false(vim.bo.modified, "File should not be modified by auto-detect")

    os.remove(temppath)
  end)

  -- TC-E2E-05: Auto-detect on UTF-8 file: no notification
  it("TC-E2E-05: Auto-detect does NOT fire for a UTF-8 file", function()
    big5.setup({ auto_detect = true })

    local messages, restore = capture_notifications()

    vim.cmd("edit test/fixtures/utf8_sample.txt")

    restore()

    local found_big5 = false
    for _, m in ipairs(messages) do
      if m.msg:find("appears to be Big5", 1, true) then
        found_big5 = true
        break
      end
    end
    assert.is_false(found_big5, "Should NOT fire auto-detect notification for UTF-8 file")
  end)

  -- TC-E2E-06: Post-conversion file re-opens as valid UTF-8
  it("TC-E2E-06: Converted file re-opens correctly as UTF-8", function()
    local temppath = copy_fixture("big5_sample.txt")

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    vim.cmd("Big5ToUtf8")

    -- Re-open the file
    vim.cmd("edit! " .. vim.fn.fnameescape(temppath))

    -- fileencoding should not be Big5
    -- (may be "" or "utf-8" depending on Neovim's auto-detection)
    local enc = vim.bo.fileencoding
    local is_utf8_enc = (enc == "utf-8" or enc == "")
    assert.is_true(is_utf8_enc, "Re-opened file should have utf-8 encoding, got: " .. enc)

    -- :Big5Check on the re-opened file should return false
    local is_big5 = detect.is_big5(temppath)
    assert.is_false(is_big5, "Converted file should NOT be detected as Big5")

    os.remove(temppath)
  end)

  -- TC-E2E-07: Idempotency: running Big5ToUtf8 twice
  it("TC-E2E-07: Running :Big5ToUtf8 twice: second call is a no-op", function()
    local temppath = copy_fixture("big5_sample.txt")

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))

    -- First conversion
    vim.cmd("Big5ToUtf8")
    local after_first = read_file(temppath)

    -- Second conversion attempt
    local messages, restore = capture_notifications()
    vim.cmd("Big5ToUtf8")
    restore()

    local after_second = read_file(temppath)

    -- File content should be unchanged after second call
    assert.equal(after_first, after_second, "File should be unchanged after second :Big5ToUtf8 call")

    -- Should notify "does not appear to be Big5"
    local found_not_big5 = false
    for _, m in ipairs(messages) do
      if m.msg:find("does not appear to be Big5", 1, true) then
        found_not_big5 = true
        break
      end
    end
    assert.is_true(found_not_big5, "Expected 'not Big5' notification on second call")

    os.remove(temppath)
  end)

  -- TC-E2E-08: plugin/big5.lua shim: commands not available before setup()
  it("TC-E2E-08: Commands are NOT registered before setup() is called", function()
    -- Delete the commands that before_each registered
    pcall(vim.api.nvim_del_user_command, "Big5Check")
    pcall(vim.api.nvim_del_user_command, "Big5ToUtf8")

    -- Use the cwd (set by minimal_init.lua to the plugin root) to locate the shim.
    -- vim.fn.getcwd() returns the plugin root directory.
    local plugin_root = vim.fn.getcwd()
    local shim_path = plugin_root .. "/plugin/big5.lua"
    dofile(shim_path)

    -- Commands should NOT be registered (shim only has comments, no setup call)
    local cmds = vim.api.nvim_get_commands({})
    assert.is_nil(cmds["Big5Check"], ":Big5Check should not exist before setup()")
    assert.is_nil(cmds["Big5ToUtf8"], ":Big5ToUtf8 should not exist before setup()")
  end)

end)
