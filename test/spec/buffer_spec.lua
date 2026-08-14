--- test/spec/buffer_spec.lua
--- Tests for lua/big5/buffer.lua using plenary's real-buffer harness, plus
--- the buffer-only mixed-tail conversion contract exercised through the
--- real :Big5ToUtf8 command.
--- Requires full Neovim runtime. Run via plenary.nvim.

local buffer = require("big5.buffer")
local convert = require("big5.convert")
local detect = require("big5.detect")
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

-- Helper: write arbitrary raw bytes to a fresh temp file
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

-- Helper: mock vim.fn.input and return a preset answer
local function mock_input(answer)
  local original = vim.fn.input
  vim.fn.input = function(_prompt)
    return answer
  end
  return function()
    vim.fn.input = original
  end
end

local BIG5_BLOCK = "\xA4\xA4\xA4\xE5\xB0\xC5\xB8\xD5" -- 中文測試
local BIG5_TAIL = string.rep(BIG5_BLOCK, 6) -- matches mixed_utf8_then_big5.txt / mixed_crlf.txt

-- detect.is_big5() samples only the first 8192 bytes of the file (see
-- detect.lua's SAMPLE_SIZE). It is locked/untouched by this feature (see
-- lua/big5/init.lua's dispatcher comment), and its whole-file byte-pair
-- scan cannot distinguish genuine Big5 pairs from UTF-8 multi-byte
-- sequences that coincidentally look like them -- a short mixed file can
-- score a spuriously high "Big5 ratio" over its *combined* prefix+tail
-- sample and get misclassified as fully Big5. Any fixture that must be
-- classified via the real `:Big5ToUtf8` command (as opposed to calling
-- detect.classify_mixed()/convert.convert_tail_bytes() directly on raw
-- bytes) is padded well past SAMPLE_SIZE so the sample never reaches the
-- tail -- this also matches the feature's realistic target scenario: a
-- large pre-existing UTF-8 file with a newly-appended tail.
local SAMPLE_SIZE = 8192
local ASCII_FILLER_LINE =
  "This is a realistic ASCII log line, used purely to push the file safely past the is_big5() 8KB sample window.\n"

local function pad_prefix(prefix)
  local padded = prefix
  while #padded < SAMPLE_SIZE + 256 do
    padded = padded .. ASCII_FILLER_LINE
  end
  return padded
end

local function count_lines(text)
  local n = 0
  for _ in text:gmatch("\n") do
    n = n + 1
  end
  return n
end

describe("buffer.read_raw_bytes", function()

  it("recovers the exact original bytes from a mixed UTF-8+Big5 buffer", function()
    local temppath, original = copy_fixture("mixed_utf8_then_big5.txt")

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    local bufnr = vim.api.nvim_get_current_buf()

    local raw = buffer.read_raw_bytes(bufnr)

    assert.equal(original, raw)

    vim.cmd("bwipeout!")
    os.remove(temppath)
  end)

  it("recovers exact bytes even when fileencoding=utf-8 was sticky-set beforehand", function()
    local temppath, original = copy_fixture("mixed_utf8_then_big5.txt")

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    local bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].fileencoding = "utf-8"

    local raw = buffer.read_raw_bytes(bufnr)

    assert.equal(original, raw)

    vim.cmd("bwipeout!")
    os.remove(temppath)
  end)

  it("recovers exact bytes from a pure UTF-8 file with no Big5 tail", function()
    local temppath, original = copy_fixture("utf8_sample.txt")

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    local bufnr = vim.api.nvim_get_current_buf()

    local raw = buffer.read_raw_bytes(bufnr)

    assert.equal(original, raw)

    vim.cmd("bwipeout!")
    os.remove(temppath)
  end)

  it("recovers exact bytes from a CRLF mixed file", function()
    local temppath, original = copy_fixture("mixed_crlf.txt")

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    local bufnr = vim.api.nvim_get_current_buf()

    local raw = buffer.read_raw_bytes(bufnr)

    assert.equal(original, raw)
    assert.equal("dos", vim.bo[bufnr].fileformat)

    vim.cmd("bwipeout!")
    os.remove(temppath)
  end)

end)

describe("buffer.write_content", function()

  it("writes converted content into the buffer, sets fileencoding, and marks it modified", function()
    local temppath = copy_fixture("mixed_utf8_then_big5.txt")

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    local bufnr = vim.api.nvim_get_current_buf()

    local raw = buffer.read_raw_bytes(bufnr)
    local result = convert.convert_tail_bytes(raw, #raw - #BIG5_TAIL)
    assert.is_true(result.ok, "Expected ok=true, got err: " .. tostring(result.err))

    buffer.write_content(bufnr, result.content)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local expected_lines = vim.split(result.content, "\n", { plain = true })
    assert.same(expected_lines, lines)
    assert.equal("utf-8", vim.bo[bufnr].fileencoding)
    assert.is_true(vim.bo[bufnr].modified)

    -- Saving must reproduce result.content byte-for-byte, including not
    -- silently adding a trailing newline this fixture never had.
    vim.cmd("w")
    local saved = read_file(temppath)
    assert.equal(result.content, saved)

    vim.cmd("bwipeout!")
    os.remove(temppath)
  end)

  it("preserves eol=false for a file with no trailing newline", function()
    local temppath = copy_fixture("mixed_no_trailing_newline.txt")

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_false(vim.bo[bufnr].eol)

    local raw = buffer.read_raw_bytes(bufnr)
    assert.is_false(vim.bo[bufnr].eol, "read_raw_bytes must not disturb eol")

    local tail_len = 32 -- 4 reps of the 8-byte Big5 block, per generate_fixtures.lua
    local result = convert.convert_tail_bytes(raw, #raw - tail_len)
    assert.is_true(result.ok)

    buffer.write_content(bufnr, result.content)
    -- The converted content still has no trailing newline, so eol must
    -- still read false after the round trip.
    assert.is_false(vim.bo[bufnr].eol)

    -- Regression check: 'fixeol' defaults to on and silently re-adds a
    -- trailing newline on :w regardless of 'eol', unless write_content
    -- also disables it. Verify the actual on-disk bytes after a real save
    -- match result.content exactly -- not just the in-buffer eol flag.
    vim.cmd("w")
    local saved = read_file(temppath)
    assert.equal(result.content, saved, "Saving must not silently add a trailing newline")

    vim.cmd("bwipeout!")
    os.remove(temppath)
  end)

  it("sets eol=true and preserves the trailing newline through an actual save when content does end in one", function()
    local temppath = write_tempfile("placeholder\n")
    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    local bufnr = vim.api.nvim_get_current_buf()

    local content = "converted line one\n" .. "converted line two\n"
    buffer.write_content(bufnr, content)

    assert.is_true(vim.bo[bufnr].eol)

    vim.cmd("w")
    local saved = read_file(temppath)
    assert.equal(content, saved)

    vim.cmd("bwipeout!")
    os.remove(temppath)
  end)

end)

describe("Integration: :Big5ToUtf8 mixed-tail buffer branch", function()

  before_each(function()
    big5.setup({ confirm_conversion = true })
  end)

  after_each(function()
    pcall(vim.api.nvim_create_augroup, "Big5AutoDetect", { clear = true })
    pcall(vim.api.nvim_del_user_command, "Big5Check")
    pcall(vim.api.nvim_del_user_command, "Big5ToUtf8")
  end)

  -- REGRESSION TEST for BLOCKER 1: gating the invariant on
  -- `classification.status == "mixed"` is too narrow. classify_mixed()
  -- also returns "tail_not_big5"/"unclassifiable" with a genuine,
  -- non-zero boundary when it found a real UTF-8 prefix but couldn't
  -- confidently classify the tail as Big5 -- that boundary is JUST as
  -- real as a "mixed" one, so it must ALSO override is_big5()'s crude
  -- whole-sample verdict. Otherwise a file like this one -- a genuine
  -- 600-byte CJK UTF-8 prefix + a 240-byte tail that is deliberately too
  -- diluted to itself read as confidently Big5 (ratio 0.667, correctly
  -- "unclassifiable") -- still manages to push detect.is_big5()'s cruder
  -- combined-sample scan over its 80% threshold (0.875), since the
  -- misread-as-quasi-Big5 CJK prefix bytes inflate the sample ratio. The
  -- destructive whole-file branch must not run on it regardless.
  it("REGRESSION: never runs the destructive branch when classify_mixed finds a genuine prefix but calls the tail unclassifiable, even if is_big5 disagrees", function()
    local prefix = string.rep("\xE4\xB8\x80", 200) -- 一 x200, 600 bytes, genuine valid UTF-8
    local valid_pair = "\xA4\xA4"
    local invalid_pair = "\x81\x80"
    -- Tail ratio = 80/120 = 0.667 -- correctly below the 0.80 threshold on
    -- its own (classify_mixed calls this "unclassifiable"), but combined
    -- with the prefix's misread contribution, is_big5()'s sample ratio is
    -- (200+80)/(200+120) = 0.875 -- comfortably over 0.80.
    local tail = string.rep(valid_pair, 80) .. string.rep(invalid_pair, 40)
    local original_raw = prefix .. tail

    -- Self-check: confirm this fixture genuinely reproduces the
    -- conflicting-verdicts setup the fix depends on, not just by
    -- assertion but by exercising the real functions.
    local classification = detect.classify_mixed(original_raw, nil)
    assert.equal("unclassifiable", classification.status)
    assert.is_true(classification.boundary > 0)

    local temppath = write_tempfile(original_raw)
    assert.is_true(detect.is_big5(temppath), "Test setup error: is_big5 must disagree with classify_mixed for this to reproduce the bug")

    local stat_before = vim.loop.fs_stat(temppath)

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    local bufnr = vim.api.nvim_get_current_buf()

    local messages, restore = capture_notifications()
    vim.cmd("Big5ToUtf8")
    restore()

    -- The destructive whole-file branch must not have run: disk
    -- byte-for-byte unchanged, size and mtime unchanged.
    local on_disk = read_file(temppath)
    assert.equal(original_raw, on_disk, "The whole-file disk branch must not run -- disk must be byte-for-byte untouched")
    local stat_after = vim.loop.fs_stat(temppath)
    assert.equal(stat_before.size, stat_after.size, "File size on disk must be unchanged")
    assert.equal(stat_before.mtime.sec, stat_after.mtime.sec, "File mtime must be unchanged")

    -- The CJK prefix, as held in the buffer, must be untouched too --
    -- the buffer must have been restored (edit!) rather than left as a
    -- raw latin1 dump, and never converted.
    assert.is_false(vim.bo[bufnr].modified)

    local found_no_write_msg = false
    for _, m in ipairs(messages) do
      if m.msg == "Found appended bytes that do not look like Big5 text. No changes made." then
        found_no_write_msg = true
        break
      end
    end
    assert.is_true(
      found_no_write_msg,
      "Expected the no-write warn message, got: " .. vim.inspect(messages)
    )

    vim.cmd("bwipeout!")
    os.remove(temppath)
  end)

  -- REGRESSION TEST for a real corruption bug: detect.is_big5() samples
  -- only the first 8192 bytes. For a SMALL mixed file (whole file fits in
  -- that sample), a genuine UTF-8 CJK prefix can misread as quasi-Big5-
  -- valid pairs when combined with a real Big5 tail in the same sample,
  -- pushing the combined ratio over 80% even though the prefix is
  -- perfectly valid UTF-8. Routing on is_big5() alone sends this file into
  -- the destructive whole-file disk branch, which then iconv's the valid
  -- CJK prefix as if it were Big5 -- silently corrupting it on disk. This
  -- fixture is deliberately NOT padded past 8192 bytes (unlike the padded
  -- fixtures used elsewhere in this file) specifically to reproduce that.
  it("REGRESSION: routes a small (unpadded) mixed file to the buffer branch, never the destructive disk branch", function()
    local temppath, original_raw = copy_fixture("mixed_utf8_then_big5.txt")
    assert.is_true(#original_raw < 8192, "Fixture must stay well under the 8192-byte is_big5() sample window")

    local stat_before = vim.loop.fs_stat(temppath)
    local prefix_expected = original_raw:sub(1, #original_raw - #BIG5_TAIL)

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    local bufnr = vim.api.nvim_get_current_buf()

    local messages, restore = capture_notifications()
    vim.cmd("Big5ToUtf8")
    restore()

    -- Must have routed to the (non-destructive) buffer branch.
    assert.is_true(vim.bo[bufnr].modified, "Expected the buffer branch to run (buffer left modified)")

    -- The destructive whole-file disk branch must never have run: disk
    -- bytes, size, and mtime must all be exactly as before.
    local on_disk = read_file(temppath)
    assert.equal(
      original_raw,
      on_disk,
      "The whole-file disk branch must not run on this file -- disk must be byte-for-byte untouched"
    )
    local stat_after = vim.loop.fs_stat(temppath)
    assert.equal(stat_before.size, stat_after.size, "File size on disk must be unchanged")
    assert.equal(stat_before.mtime.sec, stat_after.mtime.sec, "File mtime must be unchanged")

    -- The CJK UTF-8 prefix must survive character-for-character (not
    -- mangled by an errant Big5->UTF-8 iconv pass over valid UTF-8 bytes).
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local buf_content = table.concat(buf_lines, "\n")
    assert.equal(prefix_expected, buf_content:sub(1, #prefix_expected))

    -- The notification must be the buffer-branch wording, not the
    -- disk-branch "Converted <file> from Big5 to UTF-8." wording.
    local found_buffer_msg = false
    for _, m in ipairs(messages) do
      if m.msg:find("in the buffer", 1, true) and m.msg:find("disk is still unchanged", 1, true) then
        found_buffer_msg = true
        break
      end
    end
    assert.is_true(found_buffer_msg, "Expected the buffer-branch notification, got: " .. vim.inspect(messages))

    vim.cmd("bwipeout!")
    os.remove(temppath)
  end)

  it("converts only the Big5 tail in the buffer, leaving the prefix lines and disk untouched", function()
    local header = "UTF-8 Header 中文測試\n" .. "Second line 你好台灣\n"
    local prefix = pad_prefix(header)
    local original_raw = prefix .. BIG5_TAIL
    local original_lines = vim.split(original_raw, "\n", { plain = true })
    local boundary_line_count = count_lines(prefix)

    local temppath = write_tempfile(original_raw)
    local stat_before = vim.loop.fs_stat(temppath)

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    local bufnr = vim.api.nvim_get_current_buf()

    local messages, restore = capture_notifications()
    vim.cmd("Big5ToUtf8")
    restore()

    -- Critical assertion: every buffer line before the boundary line must
    -- compare EQUAL by string equality to what it was before conversion.
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i = 1, boundary_line_count do
      assert.equal(
        original_lines[i],
        buf_lines[i],
        string.format("Line %d changed after tail conversion", i)
      )
    end

    -- The buffer-only branch must never write to disk.
    local on_disk = read_file(temppath)
    assert.equal(original_raw, on_disk, "Buffer branch must never write to disk")

    local stat_after = vim.loop.fs_stat(temppath)
    assert.equal(stat_before.size, stat_after.size, "File size on disk must be unchanged")
    assert.equal(stat_before.mtime.sec, stat_after.mtime.sec, "File mtime must be unchanged")

    -- Buffer must be left modified-but-unsaved.
    assert.is_true(vim.bo[bufnr].modified)

    -- The notification must unambiguously indicate the buffer-only,
    -- unsaved outcome (never confusable with the disk-writing branch),
    -- using the exact wording specified for this branch.
    local expected_msg = string.format(
      "Converted %d new Big5 byte(s) to UTF-8 in the buffer. "
        .. "The file on disk is still unchanged. Save with :w to write %s.",
      #BIG5_TAIL,
      vim.fn.fnamemodify(temppath, ":t")
    )
    local found = false
    for _, m in ipairs(messages) do
      if m.msg == expected_msg then
        found = true
        break
      end
    end
    assert.is_true(found, "Expected exact buffer-branch notification, got: " .. vim.inspect(messages))

    vim.cmd("bwipeout!")
    os.remove(temppath)
  end)

  it("reports 'already up to date' (not the generic not-Big5 message) once the buffer-branch fix has been saved and re-run", function()
    -- The watermark is a buffer-space offset (it includes the *converted*
    -- tail's UTF-8 byte length, not the raw Big5 tail's byte length), so it
    -- only lines up with a fresh disk read once the fix has actually been
    -- saved with :w. Before that, disk and buffer lengths differ and a
    -- re-run legitimately falls back to Tier 2 and reconverts (harmless,
    -- since the disk bytes haven't changed) rather than reporting
    -- "up to date". This test exercises the post-:w path specifically.
    local header = "UTF-8 Header 中文測試\n" .. "Second line 你好台灣\n"
    local prefix = pad_prefix(header)
    local original_raw = prefix .. BIG5_TAIL
    local path = write_tempfile(original_raw)

    vim.cmd("edit " .. vim.fn.fnameescape(path))

    -- First run: converts the tail in the buffer and records the watermark.
    vim.cmd("Big5ToUtf8")
    vim.cmd("w")

    -- Second run: the fix is now saved, so disk bytes match the watermark
    -- and nothing new has been appended since.
    local messages, restore = capture_notifications()
    vim.cmd("Big5ToUtf8")
    restore()

    local found = false
    for _, m in ipairs(messages) do
      if m.msg == "No new Big5 content found. The buffer is already up to date." then
        found = true
        break
      end
    end
    assert.is_true(found, "Expected the had-prior-sync up-to-date message, got: " .. vim.inspect(messages))

    vim.cmd("bwipeout!")
    os.remove(path)
  end)

  it("prompts for confirmation when the tail has invalid Big5 sequences, and converts in the buffer on confirm", function()
    local prefix = pad_prefix("Header\n")
    local valid_pairs = string.rep("\xA4\xA4", 20) -- 20 valid pairs
    local invalid_pair = "\x81\x80" -- invalid trail byte
    local content = prefix .. valid_pairs .. invalid_pair
    local path = write_tempfile(content)

    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()

    local restore_input = mock_input("y")
    local messages, restore_notify = capture_notifications()
    vim.cmd("Big5ToUtf8")
    restore_notify()
    restore_input()

    assert.is_true(vim.bo[bufnr].modified)
    local on_disk = read_file(path)
    assert.equal(content, on_disk, "Disk must remain untouched even when invalid bytes are present")

    vim.cmd("bwipeout!")
    os.remove(path)
  end)

  it("cancels the buffer-branch conversion and restores the buffer when the user declines the invalid-bytes prompt", function()
    local prefix = pad_prefix("Header\n")
    local valid_pairs = string.rep("\xA4\xA4", 20)
    local invalid_pair = "\x81\x80"
    local content = prefix .. valid_pairs .. invalid_pair
    local path = write_tempfile(content)

    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()

    local restore_input = mock_input("n")
    local messages, restore_notify = capture_notifications()
    vim.cmd("Big5ToUtf8")
    restore_notify()
    restore_input()

    local on_disk = read_file(path)
    assert.equal(content, on_disk)
    assert.is_false(vim.bo[bufnr].modified, "Buffer should be restored to a clean state on cancel")

    local found_cancel = false
    for _, m in ipairs(messages) do
      if m.msg:find("cancelled", 1, true) or m.msg:find("Cancelled", 1, true) then
        found_cancel = true
        break
      end
    end
    assert.is_true(found_cancel, "Expected cancellation notification, got: " .. vim.inspect(messages))

    vim.cmd("bwipeout!")
    os.remove(path)
  end)

  it("heals the watermark and leaves an already-converted UTF-8 file untouched", function()
    local temppath, original = copy_fixture("utf8_sample.txt")

    vim.cmd("edit " .. vim.fn.fnameescape(temppath))
    local bufnr = vim.api.nvim_get_current_buf()

    local messages, restore = capture_notifications()
    vim.cmd("Big5ToUtf8")
    restore()

    assert.equal(#original, vim.b[bufnr].big5_synced_offset)
    assert.is_false(vim.bo[bufnr].modified)

    local on_disk = read_file(temppath)
    assert.equal(original, on_disk)

    local found_not_big5 = false
    for _, m in ipairs(messages) do
      if m.msg:find("does not appear to be Big5", 1, true) then
        found_not_big5 = true
        break
      end
    end
    assert.is_true(found_not_big5, "Expected 'not Big5' notification, got: " .. vim.inspect(messages))

    vim.cmd("bwipeout!")
    os.remove(temppath)
  end)

end)
