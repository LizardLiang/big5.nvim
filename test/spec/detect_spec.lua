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

describe("detect.utf8_prefix_length", function()

  it("returns the full length for pure ASCII", function()
    assert.equal(5, detect.utf8_prefix_length("hello"))
  end)

  it("returns the full length for a valid multi-byte UTF-8 string", function()
    -- 中文測試 = 4 chars * 3 bytes = 12 bytes, all valid UTF-8
    local s = "中文測試"
    assert.equal(#s, detect.utf8_prefix_length(s))
  end)

  it("returns 0 for an empty string", function()
    assert.equal(0, detect.utf8_prefix_length(""))
  end)

  it("stops before a truncated multi-byte lead byte with no trail", function()
    -- 0xC2 is a valid 2-byte lead but has no trail byte following it
    assert.equal(0, detect.utf8_prefix_length("\xC2"))
  end)

  it("stops before an invalid trail byte, rejecting the whole sequence", function()
    -- 0xE4 0xB8 is a valid partial 3-byte lead+trail, but the final trail
    -- byte 0x00 is invalid -- the entire 3-byte sequence is rejected, so
    -- the prefix stops at the position BEFORE the lead byte (0), not
    -- partway through it.
    assert.equal(0, detect.utf8_prefix_length("\xE4\xB8\x00"))
  end)

  it("returns the byte offset of the longest valid prefix when a Big5 tail follows", function()
    -- A Big5 lead byte (0xA4) is never a valid standalone UTF-8 lead byte,
    -- so the prefix must stop exactly at the boundary.
    local prefix = "hello\n"
    local raw = prefix .. "\xA4\xA4\xA4\xE5"
    assert.equal(#prefix, detect.utf8_prefix_length(raw))
  end)

  it("returns 0 when the very first byte is not valid UTF-8", function()
    assert.equal(0, detect.utf8_prefix_length("\xA4\xA4\xA4\xE5"))
  end)

end)

describe("detect.big5_ratio", function()

  it("returns ratio=1 and correct counts for all-valid Big5 pairs", function()
    local r = detect.big5_ratio("\xA4\xA4\xA4\xE5") -- 中文
    assert.equal(1, r.ratio)
    assert.equal(2, r.valid_big5_sequences)
    assert.equal(2, r.high_byte_sequences)
  end)

  it("returns ratio=0 and high_byte_sequences=0 for pure ASCII", function()
    local r = detect.big5_ratio("hello world")
    assert.equal(0, r.ratio)
    assert.equal(0, r.valid_big5_sequences)
    assert.equal(0, r.high_byte_sequences)
  end)

  it("returns a fractional ratio when some pairs are invalid", function()
    -- 3 valid pairs + 1 invalid pair (trail 0x80 is not a valid Big5 trail)
    local content = "\xA4\xA4\xA4\xA4\xA4\xA4\x81\x80"
    local r = detect.big5_ratio(content)
    assert.equal(4, r.high_byte_sequences)
    assert.equal(3, r.valid_big5_sequences)
    assert.equal(0.75, r.ratio)
  end)

  it("returns high_byte_sequences=0 for an empty string", function()
    local r = detect.big5_ratio("")
    assert.equal(0, r.high_byte_sequences)
    assert.equal(0, r.ratio)
  end)

end)

describe("detect.classify_mixed", function()

  local BIG5_BLOCK = "\xA4\xA4\xA4\xE5\xB0\xC5\xB8\xD5" -- 中文測試, 4 valid pairs
  local BIG5_TAIL = string.rep(BIG5_BLOCK, 6) -- 48 bytes, well above the 80% threshold

  -- Helper: read a fixture's raw bytes
  local function read_fixture(name)
    local f = assert(io.open("test/fixtures/" .. name, "rb"))
    local content = f:read("*a")
    f:close()
    return content
  end

  describe("Tier 2 (bootstrap: no known_offset)", function()

    it("classifies a clean UTF-8-prefix + Big5-tail file as mixed, boundary at the Big5 start", function()
      local raw = read_fixture("mixed_utf8_then_big5.txt")
      local result = detect.classify_mixed(raw, nil)

      assert.equal("mixed", result.status)
      assert.equal(BIG5_TAIL, result.tail)
      -- The prefix (everything before the boundary) must be byte-identical
      -- to the original UTF-8 header.
      assert.equal(raw:sub(1, result.boundary), raw:sub(1, #raw - #BIG5_TAIL))
    end)

    it("never splits a CRLF pair across the boundary", function()
      local raw = read_fixture("mixed_crlf.txt")
      local result = detect.classify_mixed(raw, nil)

      assert.equal("mixed", result.status)
      -- Boundary must land immediately after a \n, never after a lone \r.
      assert.equal(0x0A, raw:byte(result.boundary))
      assert.equal(BIG5_TAIL, result.tail)
    end)

    it("locks in the harmless prefix-scan overshoot into a pure-ASCII appended run", function()
      local raw = read_fixture("mixed_ascii_tail_overshoot.txt")
      local result = detect.classify_mixed(raw, nil)

      assert.equal("mixed", result.status)
      -- The boundary overshoots past the UTF-8 header into the ASCII-only
      -- "appended" lines, since ASCII parses as valid UTF-8 too. This is
      -- harmless: the tail is still exactly the Big5 block, byte-identical.
      assert.equal(BIG5_TAIL, result.tail)
      assert.is_true(result.boundary > #"Header 標頭\n")
    end)

    it("classifies a file with no trailing newline correctly", function()
      local raw = read_fixture("mixed_no_trailing_newline.txt")
      local result = detect.classify_mixed(raw, nil)

      assert.equal("mixed", result.status)
      local expected_tail = string.rep(BIG5_BLOCK, 4)
      assert.equal(expected_tail, result.tail)
    end)

    it("classifies a fully valid UTF-8 file as up_to_date with boundary at EOF", function()
      local raw = read_fixture("utf8_sample.txt")
      local result = detect.classify_mixed(raw, nil)

      assert.equal("up_to_date", result.status)
      assert.equal(#raw, result.boundary)
      assert.is_nil(result.tail)
    end)

    it("classifies a whole-file Big5 blob (no UTF-8 prefix at all) as mixed, boundary=0", function()
      -- boundary == 0 just means the "prefix" to preserve is empty -- the
      -- caller treats this exactly like any other "mixed" result.
      local raw = string.rep(BIG5_BLOCK, 6)
      local result = detect.classify_mixed(raw, nil)

      assert.equal("mixed", result.status)
      assert.equal(0, result.boundary)
      assert.equal(raw, result.tail)
    end)

    it("returns unclassifiable (Tier 2 failure) when the tail has no Big5-lead-byte candidates but is not valid UTF-8", function()
      local raw = "hello\n" .. "\x80" .. "world"
      local result = detect.classify_mixed(raw, nil)

      assert.equal("unclassifiable", result.status)
    end)

    it("returns unclassifiable (Tier 2 failure) when the tail has high-byte candidates below the 80% ratio", function()
      local raw = "hello\n" .. string.rep("\x81\x80", 10) -- invalid trail byte
      local result = detect.classify_mixed(raw, nil)

      assert.equal("unclassifiable", result.status)
    end)

    it("resolves a pure-ASCII appended tail to up_to_date, not mixed", function()
      -- No Big5 bytes were appended at all -- just plain ASCII (e.g. an
      -- English log line). The whole file is still genuinely valid UTF-8,
      -- so this must never be misclassified as "mixed".
      local raw = "Header 標頭\n" .. "LOG: worker heartbeat ok\n"
      local result = detect.classify_mixed(raw, nil)

      assert.equal("up_to_date", result.status)
      assert.equal(#raw, result.boundary)
      assert.is_nil(result.tail)
    end)

  end)

  describe("Tier 1 (fast path: known_offset present)", function()

    it("returns up_to_date when known_offset equals the raw length", function()
      -- The trust window ending at known_offset must be genuinely valid
      -- UTF-8 for this to legitimately fast-path -- mixed_utf8_then_big5.txt
      -- would NOT qualify here (its last bytes are raw, unconverted Big5),
      -- so this uses fully-converted UTF-8 content instead, matching what
      -- a real "already fully synced" buffer actually looks like.
      local raw = "UTF-8 Header 中文測試\n" .. "Second line 你好台灣\n"
      local result = detect.classify_mixed(raw, #raw)

      assert.equal("up_to_date", result.status)
      assert.equal(#raw, result.boundary)
      assert.is_nil(result.tail)
    end)

    it("validates only the slice after known_offset and reports mixed", function()
      local raw = read_fixture("mixed_utf8_then_big5.txt")
      local prefix_len = #raw - #BIG5_TAIL

      local result = detect.classify_mixed(raw, prefix_len)

      assert.equal("mixed", result.status)
      assert.equal(prefix_len, result.boundary)
      assert.equal(BIG5_TAIL, result.tail)
    end)

    it("falls through to Tier 2 when known_offset is stale (content shrank)", function()
      -- Simulates truncation/rotation: the recorded watermark is now
      -- larger than the current file, so it must be discarded rather than
      -- trusted, and Tier 2 must produce the same result as a bootstrap run.
      local raw = read_fixture("mixed_utf8_then_big5.txt")
      local stale_offset = #raw + 500

      local stale_result = detect.classify_mixed(raw, stale_offset)
      local bootstrap_result = detect.classify_mixed(raw, nil)

      assert.equal(bootstrap_result.status, stale_result.status)
      assert.equal(bootstrap_result.boundary, stale_result.boundary)
      assert.equal(bootstrap_result.tail, stale_result.tail)
    end)

    -- REGRESSION TEST for BLOCKER 3: the shrinkage test above proves a
    -- *shorter* replacement file correctly falls through to Tier 2 (the
    -- known_offset > len size check catches it). This proves the
    -- complementary case a pure length comparison CANNOT catch: the file
    -- is replaced by unrelated content that is the SAME LENGTH OR LONGER
    -- than known_offset. known_offset <= len still holds, exactly as it
    -- would for a genuine append, so without a content revalidation of
    -- the trusted region, Tier 1 would blindly trust
    -- raw:sub(1, known_offset) as still-good UTF-8 and only ratio-scan
    -- past it.
    it("falls through to Tier 2 when the watermark's trusted region no longer validates (rotation/replacement, same-or-larger)", function()
      local watermark = 1000
      -- Entirely unrelated content, pure Big5 throughout, no genuine
      -- UTF-8 prefix anywhere -- as if the original UTF-8-prefixed file
      -- had been replaced wholesale (e.g. log rotation swapping in a
      -- fresh, still-unconverted Big5 file) while the old watermark from
      -- the previous file stuck around.
      local rotated_raw = string.rep(BIG5_BLOCK, 200) -- 1600 bytes
      assert.is_true(#rotated_raw >= watermark, "Fixture must be same-or-larger than the watermark to reproduce the bug")

      local rotated_result = detect.classify_mixed(rotated_raw, watermark)
      local bootstrap_result = detect.classify_mixed(rotated_raw, nil)

      -- Must NOT fast-path-trust the stale watermark boundary.
      assert.not_equal(watermark, rotated_result.boundary)
      -- Must fall through and match a full Tier 2 bootstrap instead.
      assert.equal(bootstrap_result.status, rotated_result.status)
      assert.equal(bootstrap_result.boundary, rotated_result.boundary)
      assert.equal(bootstrap_result.tail, rotated_result.tail)
    end)

    it("reports tail_not_big5 (Tier 1 failure) when the newly appended slice fails the ratio check", function()
      local raw = "hello\n" .. string.rep("\x81\x80", 10)
      local result = detect.classify_mixed(raw, 6)

      assert.equal("tail_not_big5", result.status)
      assert.equal(6, result.boundary)
    end)

    it("reports mixed (boundary=0) when known_offset is 0 and the whole raw is Big5", function()
      local raw = string.rep(BIG5_BLOCK, 6)
      local result = detect.classify_mixed(raw, 0)

      assert.equal("mixed", result.status)
      assert.equal(0, result.boundary)
      assert.equal(raw, result.tail)
    end)

  end)

end)

describe("detect.looks_mixed_bounded", function()

  -- Mirrors detect.lua's private SAMPLE_SIZE constant.
  local SAMPLE_SIZE = 8192
  local BIG5_PAIR = "\xA4\xA4" -- 中, a single valid Big5 pair (100% ratio when repeated)

  it("returns false for a non-existent file without raising an error", function()
    local ok, result = pcall(detect.looks_mixed_bounded, "/path/that/does/not/exist.txt")
    assert.is_true(ok, "looks_mixed_bounded raised an error on missing file: " .. tostring(result))
    assert.is_false(result)
  end)

  it("returns false for an empty file", function()
    local path = write_tempfile("")
    local result = detect.looks_mixed_bounded(path)
    rm(path)
    assert.is_false(result)
  end)

  describe("small file (<= 2*SAMPLE_SIZE): delegates to classify_mixed for exact precision", function()

    it("returns true for a small mixed UTF-8-prefix + Big5-tail file", function()
      local raw = "UTF-8 Header 中文測試\n" .. string.rep(BIG5_PAIR, 30)
      assert.is_true(#raw <= 2 * SAMPLE_SIZE)
      local path = write_tempfile(raw)
      local result = detect.looks_mixed_bounded(path)
      rm(path)
      assert.is_true(result)
    end)

    it("returns false for a small pure-UTF-8 file", function()
      local raw = "Just plain UTF-8 text, nothing appended.\n"
      local path = write_tempfile(raw)
      local result = detect.looks_mixed_bounded(path)
      rm(path)
      assert.is_false(result)
    end)

  end)

  describe("large file (> 2*SAMPLE_SIZE): bounded two-window check, constant I/O", function()

    it("returns true when the first window is valid UTF-8 and the last window scores Big5", function()
      -- Pure ASCII padding so the head window is trivially valid UTF-8
      -- regardless of exactly where the SAMPLE_SIZE cut lands.
      local ascii_padding = string.rep("A", 3 * SAMPLE_SIZE)
      -- A long run of a single repeated valid Big5 pair so the tail
      -- window -- wherever it lands inside this run -- is 100% valid
      -- Big5 regardless of byte alignment.
      local big5_run = string.rep(BIG5_PAIR, SAMPLE_SIZE) -- 2 * SAMPLE_SIZE bytes
      local raw = ascii_padding .. big5_run
      assert.is_true(#raw > 2 * SAMPLE_SIZE)

      local path = write_tempfile(raw)
      local result = detect.looks_mixed_bounded(path)
      rm(path)
      assert.is_true(result)
    end)

    it("returns false for a large file that is pure ASCII/UTF-8 throughout", function()
      local raw = string.rep("A", 4 * SAMPLE_SIZE)
      assert.is_true(#raw > 2 * SAMPLE_SIZE)

      local path = write_tempfile(raw)
      local result = detect.looks_mixed_bounded(path)
      rm(path)
      assert.is_false(result)
    end)

    it("returns false for a large file that is entirely Big5 (no valid UTF-8 head window)", function()
      local raw = string.rep(BIG5_PAIR, 3 * SAMPLE_SIZE)
      assert.is_true(#raw > 2 * SAMPLE_SIZE)

      local path = write_tempfile(raw)
      local result = detect.looks_mixed_bounded(path)
      rm(path)
      assert.is_false(result)
    end)

    -- REGRESSION TEST for a false-negative bug: the head window is a hard
    -- SAMPLE_SIZE-byte cut with no knowledge of character boundaries. For a
    -- pure-CJK (3-byte-per-char) UTF-8 prefix, SAMPLE_SIZE = 8192 =
    -- 3*2730 + 2 is never a multiple of 3, so the cut lands mid-character
    -- EVERY time -- leaving a 2-byte dangling partial character at the
    -- window edge. A strict "the whole window must be valid UTF-8" check
    -- would then report the (genuinely valid) prefix as invalid, and the
    -- auto-detect notify would silently never fire for exactly the
    -- audience this feature targets: large files with Chinese text in the
    -- already-converted prefix.
    it("REGRESSION: returns true for a large pure-CJK UTF-8 prefix where the 8192-byte window cut lands mid-character", function()
      local cjk_char = "\xE4\xB8\xAD" -- 中, 3 bytes
      local prefix = string.rep(cjk_char, 5000) -- 15000 bytes, safely covers the cut

      -- Self-check: confirm this test setup genuinely reproduces the
      -- window-boundary truncation -- if it didn't, the test wouldn't be
      -- exercising the bug at all.
      local head = prefix:sub(1, SAMPLE_SIZE)
      local head_valid_len = detect.utf8_prefix_length(head)
      assert.is_true(
        head_valid_len < SAMPLE_SIZE,
        "Test setup error: the window cut must land mid-character to reproduce the bug"
      )
      assert.is_true(
        (SAMPLE_SIZE - head_valid_len) <= 3,
        "Test setup error: the dangling partial character must be at most 3 bytes (UTF-8's max char length minus 1)"
      )

      local big5_tail = string.rep(BIG5_PAIR, SAMPLE_SIZE) -- pure valid Big5, well past SAMPLE_SIZE
      local raw = prefix .. big5_tail
      assert.is_true(#raw > 2 * SAMPLE_SIZE)

      local path = write_tempfile(raw)
      local result = detect.looks_mixed_bounded(path)
      rm(path)
      assert.is_true(result)
    end)

    -- Companion to the regression test above: proves the tolerance added
    -- for a truncated trailing character does NOT also let a genuinely
    -- Big5 head window pass as valid UTF-8. A real Big5 head fails
    -- utf8_prefix_length() within the first byte or two (Big5 lead/trail
    -- byte ranges essentially never form valid UTF-8 sequences), so the
    -- gap between the window length and the valid length is in the
    -- thousands -- nowhere near the <=3-byte slack.
    it("returns false for a large file whose head is genuinely Big5 from byte one (slack does not blind the check)", function()
      local raw = string.rep(BIG5_PAIR, 3 * SAMPLE_SIZE)
      assert.is_true(#raw > 2 * SAMPLE_SIZE)

      local path = write_tempfile(raw)
      local result = detect.looks_mixed_bounded(path)
      rm(path)
      assert.is_false(result)
    end)

    it("only ever reads at most 2*SAMPLE_SIZE bytes for a large file (constant I/O)", function()
      -- Build a huge file whose middle section, if read, would be
      -- expensive to scan -- prove the function doesn't touch it by
      -- making the middle section deliberately invalid/misleading and
      -- confirming the result is still governed only by the head/tail
      -- windows.
      local ascii_padding = string.rep("A", 3 * SAMPLE_SIZE)
      local misleading_middle = string.rep("\x81\x80", 50000) -- huge invalid-Big5 blob
      local big5_run = string.rep(BIG5_PAIR, SAMPLE_SIZE)
      local raw = ascii_padding .. misleading_middle .. big5_run

      local path = write_tempfile(raw)
      local result = detect.looks_mixed_bounded(path)
      rm(path)
      -- Despite the huge, "ugly" middle section, the head window is pure
      -- ASCII and the tail window is pure valid Big5, so this must still
      -- report true -- proving the middle was never read/considered.
      assert.is_true(result)
    end)

  end)

end)
