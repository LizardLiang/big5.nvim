--- test/spec/integration_spec.lua
--- Integration tests verifying init.lua, detect.lua, and convert.lua working together.
--- Tests: TC-INT-01 through TC-INT-10
--- Requires full Neovim runtime. Run via plenary.nvim.

local big5 = require("big5")

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

  return dest_path, content
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

-- Helper: capture vim.fn.input and return a preset answer
local function mock_input(answer)
  local original = vim.fn.input
  vim.fn.input = function(_prompt)
    return answer
  end
  return function()
    vim.fn.input = original
  end
end

-- Helper: check if converted content is valid UTF-8 (no lone high bytes)
local function is_valid_utf8_content(content)
  local i = 1
  local len = #content
  while i <= len do
    local b = content:byte(i)
    if b <= 0x7F then
      i = i + 1
    elseif b >= 0xC2 and b <= 0xDF then
      if i + 1 > len then return false end
      local b2 = content:byte(i + 1)
      if b2 < 0x80 or b2 > 0xBF then return false end
      i = i + 2
    elseif b >= 0xE0 and b <= 0xEF then
      if i + 2 > len then return false end
      local b2 = content:byte(i + 1)
      local b3 = content:byte(i + 2)
      if b2 < 0x80 or b2 > 0xBF then return false end
      if b3 < 0x80 or b3 > 0xBF then return false end
      i = i + 3
    elseif b >= 0xF0 and b <= 0xF4 then
      if i + 3 > len then return false end
      local b2 = content:byte(i + 1)
      local b3 = content:byte(i + 2)
      local b4 = content:byte(i + 3)
      if b2 < 0x80 or b2 > 0xBF then return false end
      if b3 < 0x80 or b3 > 0xBF then return false end
      if b4 < 0x80 or b4 > 0xBF then return false end
      i = i + 4
    else
      return false
    end
  end
  return true
end

local REPLACEMENT_CHAR = "\xEF\xBF\xBD"

describe("Integration: :Big5ToUtf8", function()

  -- Snapshotted/restored for every test in this describe block (not just
  -- TC-INT-02B, which is the only one that currently mutates it) so the
  -- restore is unconditional: after_each runs even if a test body throws,
  -- unlike an inline restore at the end of the test, which a failing
  -- assertion or error partway through would skip -- leaking the override
  -- into every subsequent spec in the run.
  local saved_fileencodings

  before_each(function()
    big5.setup({ confirm_conversion = true })
    saved_fileencodings = vim.o.fileencodings
  end)

  after_each(function()
    vim.o.fileencodings = saved_fileencodings
    pcall(vim.api.nvim_create_augroup, "Big5AutoDetect", { clear = true })
    pcall(vim.api.nvim_del_user_command, "Big5Check")
    pcall(vim.api.nvim_del_user_command, "Big5ToUtf8")
  end)

  -- TC-INT-01: Big5ToUtf8 on clean Big5 buffer: full happy path
  it("TC-INT-01: converts a clean Big5 file to UTF-8 successfully", function()
    local temppath, original = copy_fixture("big5_sample.txt")
    local messages, restore_notify = capture_notifications()

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    vim.cmd("Big5ToUtf8")

    restore_notify()

    -- File on disk should now be valid UTF-8
    local on_disk = read_file(temppath)
    assert.is_truthy(on_disk, "File should exist after conversion")
    assert.is_true(is_valid_utf8_content(on_disk), "Converted file should be valid UTF-8")

    -- File content should differ from original Big5
    assert.not_equal(original, on_disk)

    -- Buffer fileencoding should be utf-8
    assert.equal("utf-8", vim.bo.fileencoding)

    -- Success notification
    local found_success = false
    for _, m in ipairs(messages) do
      if m.msg:find("Converted", 1, true) and m.msg:find("Big5 to UTF-8", 1, true) then
        found_success = true
        break
      end
    end
    assert.is_true(found_success, "Expected success notification, got: " .. vim.inspect(messages))

    os.remove(temppath)
  end)

  -- TC-INT-02: Big5ToUtf8 with invalid bytes — Substep A: user confirms
  it("TC-INT-02A: shows warning prompt and converts when user confirms", function()
    local temppath = copy_fixture("big5_with_invalid.txt")
    local original = read_file(temppath)
    local messages, restore_notify = capture_notifications()
    local restore_input = mock_input("y")

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    vim.cmd("Big5ToUtf8")

    restore_notify()
    restore_input()

    -- File should be written (different from original Big5)
    local on_disk = read_file(temppath)
    assert.is_truthy(on_disk)
    -- Content should differ from original Big5 (conversion happened)
    -- Note: vim.iconv() substitution character varies by platform (? or U+FFFD).
    assert.not_equal(original, on_disk, "Converted file should differ from original Big5")

    -- Buffer reloaded, fileencoding utf-8
    assert.equal("utf-8", vim.bo.fileencoding)

    os.remove(temppath)
  end)

  -- TC-INT-02: Big5ToUtf8 with invalid bytes — Substep B: user cancels
  it("TC-INT-02B: cancels conversion when user declines the invalid-bytes prompt", function()
    local temppath = copy_fixture("big5_with_invalid.txt")
    local original = read_file(temppath)
    local messages, restore_notify = capture_notifications()
    local restore_input = mock_input("n")

    -- (BLOCKER 2): buffer.read_raw_bytes() forces an ++enc=latin1 reload on
    -- every :Big5ToUtf8 invocation now, including ones that end up on this
    -- whole-file branch. Declining here must restore the buffer (edit!)
    -- exactly like every other cancel path does, so the buffer's final
    -- fileencoding/modified state matches a plain, independent :edit of
    -- the same (unchanged) file -- not an artifact of our internal
    -- ++enc=latin1 detour.
    --
    -- On this box's default 'fileencodings' (ucs-bom,utf-8,default,
    -- latin1), a *correctly restored* buffer and an *unrestored* one are
    -- indistinguishable here: this fixture's content isn't valid UTF-8,
    -- 'default' also fails for it, so natural detection lands on "latin1"
    -- too -- the exact same value the forced override produces. Control
    -- the variable: drop "latin1" from the candidate list for this test.
    -- With "latin1" excluded, a properly-restored buffer re-detects to
    -- whatever this box's remaining candidates resolve to (empirically,
    -- "" here, since this fixture's invalid bytes also fail cp950
    -- validation -- but any value other than "latin1" makes the point:
    -- the forced override never runs 'fileencodings' at all, so an
    -- unrestored buffer stays stuck at "latin1" regardless), while an
    -- unrestored buffer stays stuck at "latin1" from the forced override
    -- -- now genuinely observable. Restoration is NOT inline here -- the
    -- describe block's after_each above restores 'fileencodings'
    -- unconditionally, so it can't leak into later specs even if this
    -- test throws before reaching its own assertions.
    vim.o.fileencodings = "utf-8,cp950"

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    local bufnr = vim.api.nvim_get_current_buf()
    vim.cmd("Big5ToUtf8")

    restore_notify()
    restore_input()

    local original_fileencoding = vim.bo[bufnr].fileencoding
    local original_modified = vim.bo[bufnr].modified

    vim.cmd("bwipeout!")
    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    local control_fileencoding = vim.bo.fileencoding
    vim.cmd("bwipeout!")

    -- File on disk should be unchanged
    local on_disk = read_file(temppath)
    assert.equal(original, on_disk, "File should be unchanged when user cancels")

    -- Cancellation notification
    local found_cancel = false
    for _, m in ipairs(messages) do
      if m.msg:find("cancelled", 1, true) or m.msg:find("Cancelled", 1, true) then
        found_cancel = true
        break
      end
    end
    assert.is_true(found_cancel, "Expected cancellation notification, got: " .. vim.inspect(messages))

    assert.is_false(original_modified, "Buffer must be restored to unmodified after declining")
    assert.equal(
      control_fileencoding,
      original_fileencoding,
      "Buffer's fileencoding after declining must match a plain, independent edit of the same file"
    )

    os.remove(temppath)
  end)

  -- TC-INT-07: Big5ToUtf8 on UTF-8 file: no conversion, user notified
  it("TC-INT-07: notifies user and skips conversion for a non-Big5 file", function()
    local temppath = copy_fixture("utf8_sample.txt")
    local original = read_file(temppath)
    local messages, restore_notify = capture_notifications()

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    vim.cmd("Big5ToUtf8")

    restore_notify()

    -- File on disk should be unchanged
    local on_disk = read_file(temppath)
    assert.equal(original, on_disk)

    -- Should notify that file is not Big5
    local found_not_big5 = false
    for _, m in ipairs(messages) do
      if m.msg:find("does not appear to be Big5", 1, true) then
        found_not_big5 = true
        break
      end
    end
    assert.is_true(found_not_big5, "Expected 'not Big5' notification, got: " .. vim.inspect(messages))

    os.remove(temppath)
  end)

  -- TC-INT-08: Big5ToUtf8 with unsaved buffer changes — Substep A: user cancels
  it("TC-INT-08A: shows unsaved-changes prompt and cancels when user declines", function()
    local temppath = copy_fixture("big5_sample.txt")
    local original = read_file(temppath)
    local messages, restore_notify = capture_notifications()
    local restore_input = mock_input("n")

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    -- Dirty the buffer without saving
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "modified line" })
    assert.is_true(vim.bo.modified)

    vim.cmd("Big5ToUtf8")

    restore_notify()
    restore_input()

    -- File on disk should be unchanged
    local on_disk = read_file(temppath)
    assert.equal(original, on_disk)

    -- Cancellation notification
    local found_cancel = false
    for _, m in ipairs(messages) do
      if m.msg:find("cancelled", 1, true) or m.msg:find("Cancelled", 1, true) then
        found_cancel = true
        break
      end
    end
    assert.is_true(found_cancel, "Expected cancellation notification, got: " .. vim.inspect(messages))

    os.remove(temppath)
  end)

  -- TC-INT-08: Big5ToUtf8 with unsaved buffer changes — Substep B: user confirms
  it("TC-INT-08B: proceeds with conversion when user confirms despite unsaved changes", function()
    local temppath = copy_fixture("big5_sample.txt")
    local messages, restore_notify = capture_notifications()
    local restore_input = mock_input("y")

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "modified line" })
    assert.is_true(vim.bo.modified)

    vim.cmd("Big5ToUtf8")

    restore_notify()
    restore_input()

    -- File on disk should now be UTF-8
    local on_disk = read_file(temppath)
    assert.is_true(is_valid_utf8_content(on_disk), "Converted file should be valid UTF-8")
    assert.equal("utf-8", vim.bo.fileencoding)

    os.remove(temppath)
  end)

end)

describe("Integration: :Big5Check", function()

  before_each(function()
    big5.setup()
  end)

  after_each(function()
    pcall(vim.api.nvim_del_user_command, "Big5Check")
    pcall(vim.api.nvim_del_user_command, "Big5ToUtf8")
  end)

  -- TC-INT-03: Big5Check on Big5 file shows positive result
  it("TC-INT-03: notifies 'appears to be Big5-encoded' for a Big5 file", function()
    local messages, restore = capture_notifications()

    vim.cmd("edit test/fixtures/big5_sample.txt")
    vim.cmd("Big5Check")

    restore()

    local found = false
    for _, m in ipairs(messages) do
      if m.msg:find("appears to be Big5", 1, true) then
        found = true
        break
      end
    end
    assert.is_true(found, "Expected Big5 detection message, got: " .. vim.inspect(messages))
  end)

  -- TC-INT-04: Big5Check on UTF-8 file shows negative result
  it("TC-INT-04: notifies 'does not appear to be Big5-encoded' for a UTF-8 file", function()
    local messages, restore = capture_notifications()

    vim.cmd("edit test/fixtures/utf8_sample.txt")
    vim.cmd("Big5Check")

    restore()

    local found = false
    for _, m in ipairs(messages) do
      if m.msg:find("does not appear to be Big5", 1, true) then
        found = true
        break
      end
    end
    assert.is_true(found, "Expected non-Big5 message, got: " .. vim.inspect(messages))
  end)

  -- TC-INT-09: Big5Check reads from disk, not buffer
  it("TC-INT-09: check result reflects on-disk content, not in-memory buffer modifications", function()
    -- Use a temp copy to avoid dirtying the shared fixture file.
    -- Opening the fixture directly and modifying the buffer without cleanup
    -- risks corrupting the fixture if Neovim writes the dirty buffer on exit.
    local temppath = copy_fixture("big5_sample.txt")
    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    -- Modify the buffer in memory without saving
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "this is ASCII content now" })

    local messages, restore = capture_notifications()
    vim.cmd("Big5Check")
    restore()

    -- The check should still report Big5 (reading from disk, not buffer)
    local found_big5 = false
    for _, m in ipairs(messages) do
      if m.msg:find("appears to be Big5", 1, true) then
        found_big5 = true
        break
      end
    end
    assert.is_true(found_big5, "Check should read from disk (Big5), got: " .. vim.inspect(messages))

    -- Clean up: wipe the dirty buffer and remove the temp file
    vim.cmd("bwipeout!")
    os.remove(temppath)
  end)

  -- TC-INT-10: Big5Check does not modify file or buffer
  it("TC-INT-10: does not modify the file or buffer after checking", function()
    local temppath = copy_fixture("big5_sample.txt")
    local original = read_file(temppath)

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    local was_modified = vim.bo.modified
    vim.cmd("Big5Check")

    -- File bytes should be identical
    local after = read_file(temppath)
    assert.equal(original, after, "File bytes should be unchanged after :Big5Check")

    -- Buffer's modified flag should be same as before (not dirtied by check)
    assert.equal(was_modified, vim.bo.modified)

    os.remove(temppath)
  end)

end)

describe("Integration: Auto-detect", function()

  after_each(function()
    pcall(vim.api.nvim_create_augroup, "Big5AutoDetect", { clear = true })
    pcall(vim.api.nvim_del_user_command, "Big5Check")
    pcall(vim.api.nvim_del_user_command, "Big5ToUtf8")
  end)

  -- TC-INT-05: Auto-detect on opening Big5 file triggers notification
  it("TC-INT-05: fires INFO notification when Big5 file is opened with auto_detect=true", function()
    big5.setup({ auto_detect = true })

    local messages, restore = capture_notifications()

    -- Use a temp copy to ensure BufReadPost fires (file not already in buffer list)
    local temppath = copy_fixture("big5_sample.txt")

    -- Opening the file triggers BufReadPost
    vim.cmd("edit " .. vim.fn.fnameescape(temppath))

    restore()

    local found = false
    for _, m in ipairs(messages) do
      if m.msg:find("appears to be Big5", 1, true) and m.level == vim.log.levels.INFO then
        found = true
        break
      end
    end
    assert.is_true(found, "Expected INFO auto-detect notification, got: " .. vim.inspect(messages))

    -- File should not be modified
    assert.is_false(vim.bo.modified)

    os.remove(temppath)
  end)

  -- TC-INT-06: Auto-detect on UTF-8 file does NOT trigger notification
  it("TC-INT-06: does NOT fire notification when UTF-8 file is opened with auto_detect=true", function()
    big5.setup({ auto_detect = true })

    local messages, restore = capture_notifications()

    -- Use a temp copy to ensure BufReadPost fires reliably
    local temppath = copy_fixture("utf8_sample.txt")
    vim.cmd("edit " .. vim.fn.fnameescape(temppath))

    restore()

    local found_big5_notice = false
    for _, m in ipairs(messages) do
      if m.msg:find("appears to be Big5", 1, true) then
        found_big5_notice = true
        break
      end
    end
    assert.is_false(found_big5_notice, "Should NOT receive Big5 notification for UTF-8 file")

    os.remove(temppath)
  end)

  -- Auto-detect on a mixed UTF-8-prefix + Big5-tail file: notify-only,
  -- never converts, never touches the buffer/disk.
  it("fires an INFO notification for a mixed file, without converting it", function()
    big5.setup({ auto_detect = true })

    -- Pad the UTF-8 prefix well past is_big5()'s 8192-byte sample window so
    -- the whole-file heuristic reliably sees only prefix bytes (matching
    -- the realistic large-file scenario this feature targets) and defers
    -- to the mixed-tail check instead of misreading the combined sample.
    local filler = "This is a realistic ASCII log line, used to push the file past the 8KB sample window.\n"
    local prefix = "UTF-8 Header 中文測試\n"
    while #prefix < 8192 + 256 do
      prefix = prefix .. filler
    end
    local big5_tail = string.rep("\xA4\xA4\xA4\xE5\xB0\xC5\xB8\xD5", 6)
    local content = prefix .. big5_tail

    local temppath = os.tmpname()
    local f = assert(io.open(temppath, "wb"))
    f:write(content)
    f:close()

    local messages, restore = capture_notifications()
    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    restore()

    local found = false
    for _, m in ipairs(messages) do
      if m.msg == "This file has new Big5 content appended. Use :Big5ToUtf8 to convert it in the buffer."
        and m.level == vim.log.levels.INFO
      then
        found = true
        break
      end
    end
    assert.is_true(found, "Expected mixed-tail auto-detect notification, got: " .. vim.inspect(messages))

    -- Purely notify-only: no buffer mutation, no disk write.
    assert.is_false(vim.bo.modified)
    local on_disk = read_file(temppath)
    assert.equal(content, on_disk)

    os.remove(temppath)
  end)

  -- Proves the autocmd path itself (not just detect.looks_mixed_bounded in
  -- isolation) never scales with file size: opens a LARGE file (well past
  -- the 2*8192-byte cutoff where the bounded check switches from exact
  -- classify_mixed to the two-window heuristic) with a huge, deliberately
  -- "wrong-looking" middle section between the head and tail windows. If
  -- BufReadPost read (or scanned) the whole file, the misleading middle
  -- would suppress the notification; if it only reads the two bounded
  -- windows, the middle is never even looked at and the notification
  -- fires exactly as it would without the middle section present.
  it("bounds its I/O even through the real BufReadPost autocmd for a large file with a misleading middle", function()
    big5.setup({ auto_detect = true })

    local ascii_padding = string.rep("A", 3 * 8192) -- valid UTF-8 head window
    local misleading_middle = string.rep("\x81\x80", 100000) -- huge invalid-Big5 blob
    local big5_tail_run = string.rep("\xA4\xA4", 8192) -- valid Big5 tail window
    local content = ascii_padding .. misleading_middle .. big5_tail_run
    assert.is_true(#content > 2 * 8192)

    local temppath = os.tmpname()
    local f = assert(io.open(temppath, "wb"))
    f:write(content)
    f:close()

    local messages, restore = capture_notifications()
    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    restore()

    local found = false
    for _, m in ipairs(messages) do
      if m.msg == "This file has new Big5 content appended. Use :Big5ToUtf8 to convert it in the buffer."
        and m.level == vim.log.levels.INFO
      then
        found = true
        break
      end
    end
    assert.is_true(
      found,
      "Expected the notification despite the misleading middle -- if this fails, the autocmd path is reading (or being influenced by) more than the bounded head/tail windows"
    )

    assert.is_false(vim.bo.modified)
    local on_disk = read_file(temppath)
    assert.equal(content, on_disk)

    os.remove(temppath)
  end)

end)
