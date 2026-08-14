--- lua/big5/detect.lua
--- Big5 encoding detection module.
--- No Neovim API dependency — uses only io.open and byte arithmetic.
--- This module can be unit-tested in isolation.

local M = {}

local SAMPLE_SIZE = 8192

-- Bounded window (bytes) used to revalidate a watermark's trusted region
-- in classify_mixed()'s Tier 1 fast path before trusting it -- see there
-- for why a raw byte-length comparison alone is not enough.
local TRUST_WINDOW = 1024

--- Find the length of the longest valid UTF-8 prefix of a byte sequence.
--- Scans bytes according to the UTF-8 multi-byte encoding rules. Unlike a
--- simple valid/invalid check, this returns the exact byte offset where
--- validity stops, so callers can locate a UTF-8/non-UTF-8 boundary inside
--- a buffer rather than only knowing whether one exists.
--- @param bytes string Raw bytes to scan
--- @return number length Byte length of the longest valid UTF-8 prefix.
---   Equal to #bytes when the entire sequence is valid UTF-8.
function M.utf8_prefix_length(bytes)
  local i = 1
  local len = #bytes
  while i <= len do
    local b = bytes:byte(i)
    if b <= 0x7F then
      -- Single-byte ASCII character
      i = i + 1
    elseif b >= 0xC2 and b <= 0xDF then
      -- Two-byte sequence
      if i + 1 > len then return i - 1 end
      local b2 = bytes:byte(i + 1)
      if b2 < 0x80 or b2 > 0xBF then return i - 1 end
      i = i + 2
    elseif b >= 0xE0 and b <= 0xEF then
      -- Three-byte sequence
      if i + 2 > len then return i - 1 end
      local b2 = bytes:byte(i + 1)
      local b3 = bytes:byte(i + 2)
      if b2 < 0x80 or b2 > 0xBF then return i - 1 end
      if b3 < 0x80 or b3 > 0xBF then return i - 1 end
      i = i + 3
    elseif b >= 0xF0 and b <= 0xF4 then
      -- Four-byte sequence
      if i + 3 > len then return i - 1 end
      local b2 = bytes:byte(i + 1)
      local b3 = bytes:byte(i + 2)
      local b4 = bytes:byte(i + 3)
      if b2 < 0x80 or b2 > 0xBF then return i - 1 end
      if b3 < 0x80 or b3 > 0xBF then return i - 1 end
      if b4 < 0x80 or b4 > 0xBF then return i - 1 end
      i = i + 4
    else
      -- 0xC0, 0xC1 (overlong), 0xF5-0xFF, or invalid: stop here
      return i - 1
    end
  end
  return len
end

--- Scan a byte sequence for Big5 double-byte candidates and report how many
--- were valid Big5 pairs. Shared by whole-file detection (M.is_big5) and
--- tail-only validation (M.classify_mixed) so there is exactly one
--- implementation of the Big5 lead/trail scanning rules.
--- @param bytes string Raw bytes to scan
--- @return table { ratio=number, valid_big5_sequences=number, high_byte_sequences=number }
function M.big5_ratio(bytes)
  local i = 1
  local len = #bytes
  local high_byte_sequences = 0
  local valid_big5_sequences = 0

  while i <= len do
    local b = bytes:byte(i)
    if b >= 0x81 and b <= 0xFE then
      -- Candidate Big5 lead byte
      high_byte_sequences = high_byte_sequences + 1
      if i + 1 <= len then
        local trail = bytes:byte(i + 1)
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

  local ratio = 0
  if high_byte_sequences > 0 then
    ratio = valid_big5_sequences / high_byte_sequences
  end

  return {
    ratio = ratio,
    valid_big5_sequences = valid_big5_sequences,
    high_byte_sequences = high_byte_sequences,
  }
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
  if M.utf8_prefix_length(sample) == #sample then
    info.is_valid_utf8 = true
    return false, info
  end

  -- Step 3: Big5 sequence scanning
  local ratio_info = M.big5_ratio(sample)
  info.high_byte_sequences = ratio_info.high_byte_sequences
  info.valid_big5_sequences = ratio_info.valid_big5_sequences

  -- Step 4: Threshold check
  if ratio_info.high_byte_sequences == 0 then
    -- Pure ASCII (all bytes were in 0x00-0x7F range or no high-byte sequences found)
    return false, info
  end

  info.ratio = ratio_info.ratio

  if ratio_info.ratio >= 0.80 then
    return true, info
  end

  return false, info
end

--- Check whether `window` is valid UTF-8, tolerating up to 3 leading bytes
--- that may be an incomplete fragment of a multi-byte character whose lead
--- byte fell before the start of the window (the window is a bounded
--- slice cut out of a larger buffer at an arbitrary byte offset, with no
--- knowledge of character boundaries -- the same class of edge case as
--- looks_mixed_bounded()'s head window, but at the window's leading edge
--- here instead of its trailing edge). Tries skipping 0-3 leading bytes
--- and accepts if any skip amount makes the remainder fully valid UTF-8.
--- This cannot be fooled by genuinely non-UTF-8 (e.g. Big5) content:
--- skipping at most 3 bytes forward still lands within the same non-UTF-8
--- byte stream, which fails validation almost immediately regardless of
--- where it resumes.
--- @param window string
--- @return boolean
local function is_valid_utf8_with_leading_slack(window)
  local max_skip = math.min(3, #window)
  for skip = 0, max_skip do
    local candidate = window:sub(skip + 1)
    if M.utf8_prefix_length(candidate) == #candidate then
      return true
    end
  end
  return false
end

--- Classify raw bytes (typically the exact contents of a buffer or file) as
--- pure Big5, a UTF-8 prefix followed by an appended Big5 tail ("mixed"),
--- already fully UTF-8 ("up_to_date"), or a tail that cannot be confidently
--- classified as Big5. Pure Lua — takes a raw byte string, not a filepath,
--- so it has no Neovim API dependency and is directly unit-testable.
---
--- This is the detection half of the mixed Big5/UTF-8 tail-sync feature: an
--- external producer that keeps appending Big5 bytes to a file already
--- converted to UTF-8 leaves the file as a valid UTF-8 prefix plus a Big5
--- tail. Big5 trail bytes (0x40-0x7E, 0xA1-0xFE) never fall in the UTF-8
--- continuation-byte range (0x80-0xBF), so "longest valid UTF-8 prefix" is a
--- reliable boundary between the two regions, not a guess.
---
--- @param raw string Raw bytes to classify
--- @param known_offset number|nil Byte offset already synced to UTF-8 by a
---   previous run (vim.b[bufnr].big5_synced_offset), if any
--- @return table { status = "mixed"|"up_to_date"|"tail_not_big5"|"unclassifiable",
---   boundary = number|nil, tail = string|nil }
---   boundary is the byte offset splitting the untouched prefix from the
---   tail (prefix = raw:sub(1, boundary)); tail is raw:sub(boundary + 1).
---   A "mixed" result with boundary == 0 means there is no genuine UTF-8
---   prefix at all (the whole of `raw` is the Big5 region) -- the caller
---   treats this exactly like any other "mixed" result, since the prefix
---   slice is simply empty.
---   The failure statuses are tier-based, not reason-based: "tail_not_big5"
---   means the Tier 1 fast path (a known watermark) found the newly
---   appended slice does not pass the ratio check; "unclassifiable" means
---   Tier 2 (bootstrap, no reliable watermark) could not find a confident
---   Big5 tail at all. Callers currently treat both identically (warn, no
---   write), but the distinct labels keep the reasoning traceable in tests.
function M.classify_mixed(raw, known_offset)
  local len = #raw

  -- Tier 1 (fast path): a previously-recorded watermark tells us exactly
  -- where the last confirmed UTF-8 boundary was, so we only need to
  -- validate the bytes appended since then.
  --
  -- Before trusting known_offset at all, revalidate that the bytes
  -- immediately preceding it are still genuinely valid UTF-8, using a
  -- bounded trailing window (TRUST_WINDOW bytes, not a full prefix
  -- rescan -- that would defeat the point of the watermark on large
  -- files). A raw byte-length comparison alone (known_offset <= len)
  -- cannot detect the file having been rotated or replaced: if it was
  -- swapped for unrelated content at least known_offset bytes long, the
  -- length check passes exactly as it would for a genuine append, and
  -- without this window check Tier 1 would blindly trust
  -- raw:sub(1, known_offset) as known-good UTF-8 and only ratio-scan past
  -- it -- silently treating unconverted Big5 as an already-synced prefix.
  if known_offset ~= nil and known_offset <= len then
    local window_start = math.max(1, known_offset - TRUST_WINDOW + 1)
    local trust_window = raw:sub(window_start, known_offset)
    local watermark_trustworthy = is_valid_utf8_with_leading_slack(trust_window)

    if watermark_trustworthy then
      if known_offset == len then
        -- Nothing has been appended since the last sync.
        return { status = "up_to_date", boundary = known_offset, tail = nil }
      end

      local tail = raw:sub(known_offset + 1)
      local ratio_info = M.big5_ratio(tail)
      if ratio_info.ratio >= 0.80 then
        return { status = "mixed", boundary = known_offset, tail = tail }
      else
        return { status = "tail_not_big5", boundary = known_offset, tail = tail }
      end
    end
    -- else: the trusted region no longer validates (e.g. the file was
    -- rotated or replaced) -- fall through to the Tier 2 bootstrap below
    -- instead of trusting known_offset.
  end

  -- Tier 2 (bootstrap): no watermark, or the watermark is stale (the
  -- content shrank — e.g. the file was truncated or rotated — so the old
  -- offset no longer means anything). Find the boundary from scratch.
  local prefix_len = M.utf8_prefix_length(raw)

  if prefix_len == len then
    -- The whole file is already valid UTF-8 — nothing to convert.
    return { status = "up_to_date", boundary = len, tail = nil }
  end

  -- Snap the boundary backward to the last newline (0x0A) at or before the
  -- raw UTF-8 boundary, so a line — and any CRLF pair — is never split.
  local boundary = prefix_len
  while boundary > 0 and raw:byte(boundary) ~= 0x0A do
    boundary = boundary - 1
  end
  if boundary == 0 then
    -- No newline to snap to (e.g. one long unterminated line): use the
    -- raw UTF-8 boundary as-is.
    boundary = prefix_len
  end

  local tail = raw:sub(boundary + 1)
  local ratio_info = M.big5_ratio(tail)
  if ratio_info.ratio >= 0.80 then
    return { status = "mixed", boundary = boundary, tail = tail }
  else
    return { status = "unclassifiable", boundary = boundary, tail = tail }
  end
end

--- Bounded-cost heads-up check for whether a file looks like a UTF-8
--- prefix with a Big5 tail appended, without ever reading the whole file.
--- Reads at most 2 * SAMPLE_SIZE bytes total regardless of file size --
--- appropriate for a notify-only check that may run on every buffer open
--- (e.g. a BufReadPost autocmd), where classify_mixed()'s full-file read
--- would be too expensive to repeat on every open of a large file.
---
--- When the file is small enough that reading it whole is itself already
--- within that same bound, this delegates to classify_mixed() for exact
--- precision. Only for genuinely large files does it fall back to
--- comparing two fixed-size windows (the first SAMPLE_SIZE bytes must be
--- valid UTF-8; the last SAMPLE_SIZE bytes must score as Big5) -- a
--- heuristic that trades precision for the hard I/O bound: it can produce
--- a false negative if the true UTF-8/Big5 boundary falls in the unread
--- middle section of a large file, but it never reads more than the bound.
--- This is notify-only (see M.classify_mixed for the real, precise
--- boundary computation used to actually convert anything) so an
--- occasional false negative here is an acceptable trade -- it only costs
--- a missed notification, never a wrong conversion.
---
--- Known imprecision: the tail window's start offset (file_size -
--- SAMPLE_SIZE) is an arbitrary byte cut with no knowledge of character
--- boundaries, so it can land mid-multi-byte-sequence, making the first
--- byte or two of that window read as unrelated single bytes rather than
--- as part of whatever character they were originally part of. This does
--- NOT produce a false "invalid" verdict: M.big5_ratio() only ever scores
--- a ratio over the window (it has no notion of "invalid input" to fail
--- on), and a couple of skewed leading bytes out of SAMPLE_SIZE cannot
--- move that ratio enough to matter.
---
--- @param filepath string Absolute path to the file on disk
--- @return boolean looks_mixed
function M.looks_mixed_bounded(filepath)
  local f = io.open(filepath, "rb")
  if not f then return false end

  local file_size = f:seek("end")
  if not file_size or file_size == 0 then
    f:close()
    return false
  end

  if file_size <= 2 * SAMPLE_SIZE then
    -- Small enough that a full read is itself bounded by the same cap.
    f:seek("set", 0)
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then return false end
    local classification = M.classify_mixed(raw, nil)
    return classification.status == "mixed"
  end

  -- Large file: bound the read to two fixed-size windows instead of
  -- reading the whole thing.
  f:seek("set", 0)
  local head = f:read(SAMPLE_SIZE)
  f:seek("set", file_size - SAMPLE_SIZE)
  local tail = f:read(SAMPLE_SIZE)
  f:close()

  if not head or head == "" then return false end

  -- The head window is a hard SAMPLE_SIZE-byte cut with no knowledge of
  -- character boundaries, so it can land mid-multi-byte-character (e.g. a
  -- pure-CJK prefix: 8192 is never a multiple of 3, so a 3-byte-per-char
  -- run always leaves a dangling partial character at the edge). Requiring
  -- the whole window to validate would make that a false negative -- a
  -- genuinely valid UTF-8 prefix reported as invalid purely because of
  -- where the read happened to stop. A UTF-8 character is at most 4 bytes,
  -- so tolerate up to 3 bytes left dangling at the end of the window. This
  -- slack cannot hide a genuinely Big5 head: real Big5 bytes fail
  -- utf8_prefix_length() within the first byte or two (Big5's lead/trail
  -- ranges essentially never form valid UTF-8), leaving a gap in the
  -- thousands, nowhere near this 3-byte tolerance.
  local head_valid_len = M.utf8_prefix_length(head)
  local head_is_valid_utf8 = (#head - head_valid_len) <= 3
  local ratio_info = M.big5_ratio(tail or "")
  local tail_looks_big5 = ratio_info.high_byte_sequences > 0 and ratio_info.ratio >= 0.80

  return head_is_valid_utf8 and tail_looks_big5
end

return M
