# big5.nvim

[![Neovim 0.8+](https://img.shields.io/badge/Neovim-0.8%2B-green?logo=neovim)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-blue?logo=lua&logoColor=white)](https://www.lua.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](#license)

A Neovim plugin that detects Big5-encoded files and converts them to UTF-8 in place.

## Why big5.nvim?

Legacy **Big5** files are everywhere in the Traditional Chinese (`zh-TW`) world — documents from Taiwan-era software, older websites, and government records were saved in Big5 long before UTF-8 became the norm. When you open one in Neovim, the **encoding detection** falls back to UTF-8 and you get mojibake (garbled text) instead of readable Chinese.

big5.nvim fixes this: it heuristically detects Big5-encoded files, converts them to UTF-8 in place via Neovim's built-in `vim.iconv()`, and sets the buffer `fileencoding` correctly — with **zero external dependencies**.

## Features

- 🔍 Automatic **Big5 encoding detection** using a byte-level heuristic
- 🔄 In-place **Big5 → UTF-8** conversion (`:Big5ToUtf8`)
- 🧵 Fixes a **Big5 tail appended to an already-converted UTF-8 file** — entirely in the buffer, never touching disk (`:Big5ToUtf8`)
- ✅ Non-destructive encoding check (`:Big5Check`)
- 🪶 Zero dependencies — pure Lua, no `iconv` binary required at runtime
- 🇹🇼 Built for legacy **Traditional Chinese** (`zh-TW`) files

## Requirements

- Neovim 0.8.0 or later
- No external dependencies

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "LizardLiang/big5.nvim",
  config = function()
    require("big5").setup()
  end,
}
```

Using [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'LizardLiang/big5.nvim'
" After plug#end(), in your Lua config:
" require("big5").setup()
```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  "LizardLiang/big5.nvim",
  config = function()
    require("big5").setup()
  end,
}
```

Using [pckr.nvim](https://github.com/lewis6991/pckr.nvim):

```lua
{
  "LizardLiang/big5.nvim",
  config = function()
    require("big5").setup()
  end,
}
```

Manual installation: clone `LizardLiang/big5.nvim` and add the directory to your `runtimepath`, then call `require("big5").setup()` in your Neovim configuration.

## Configuration

```lua
require("big5").setup({
  -- Enable automatic detection notification when a Big5 file is opened.
  -- Default: false
  auto_detect = false,

  -- Prompt for confirmation when converting a file that contains byte sequences
  -- that cannot be converted. Invalid bytes are replaced with a substitution
  -- character whose exact value is platform-dependent: U+FFFD on Linux/macOS,
  -- "?" on Windows.
  -- Default: true
  confirm_conversion = true,
})
```

## Commands

### `:Big5Check`

Reports whether the current file appears to be Big5-encoded. Reads raw bytes from disk (does not modify the file or buffer).

```
:Big5Check
```

Output examples:
- `File appears to be Big5-encoded (ratio: 95%, sequences: 248)`
- `File does not appear to be Big5-encoded.`

### `:Big5ToUtf8`

Converts the current file from Big5 to UTF-8. It has two branches, chosen automatically depending on what the file looks like — the notification text after running the command always tells you which one ran.

#### Whole-file branch: the file is entirely Big5

If the whole file is detected as Big5-encoded, `:Big5ToUtf8` overwrites the file on disk and reloads the buffer, exactly as before.

> **Warning:** This operation is irreversible. The original Big5 file is overwritten with no backup. Back up any important files before running this command.

```
:Big5ToUtf8
```

Behavior:
1. If the buffer has unsaved changes, prompts before proceeding.
2. Checks if the file is Big5-encoded. If not, falls through to the mixed-tail branch below.
3. Converts the file content from Big5 to UTF-8 in memory.
4. If the file contains invalid byte sequences (that cannot be converted), prompts for confirmation before writing.
5. Writes the UTF-8 content to disk and reloads the buffer.
6. Sets `fileencoding` to `utf-8` for the current buffer.

Success notification: `Converted <filename> from Big5 to UTF-8.`

#### Mixed-tail branch: a UTF-8 file with a Big5 tail appended

If a file was already converted to UTF-8 but something external (e.g. a legacy tool or process) keeps appending Big5-encoded bytes to it, the file becomes a valid UTF-8 prefix followed by a Big5 tail. `:Big5ToUtf8` detects this shape and fixes **only the newly-appended tail** — and it does so **entirely in the buffer**. It never touches the file on disk.

```
:Big5ToUtf8
```

Behavior:
1. If the buffer has unsaved changes, prompts before proceeding (this reload is load-bearing for the next step, not just a courtesy — see below).
2. Reads the buffer's exact underlying bytes and finds the boundary between the already-good UTF-8 prefix and the appended Big5 tail.
3. If the tail contains invalid byte sequences, prompts for confirmation before converting, same as the whole-file branch.
4. Converts only the tail to UTF-8 and writes the result back into the buffer. The prefix is copied through byte-for-byte, untouched.
5. Leaves the buffer **modified but unsaved** — run `:w` when you're ready to persist the fix to disk.

Success notification: `Converted <N> new Big5 byte(s) to UTF-8 in the buffer. The file on disk is still unchanged. Save with :w to write <filename>.`

Because this branch never writes to disk, it's fully undo-able (`u`) and safe to inspect before saving. Reading either success message on its own — without comparing the two — tells you unambiguously which branch ran: the whole-file message names only the file and never mentions saving; the mixed-tail message explicitly says the disk file is unchanged and tells you to `:w`.

If nothing new has been appended since the last sync, `:Big5ToUtf8` reports that and makes no changes (`No new Big5 content found. The buffer is already up to date.`). If the appended bytes can't be confidently classified as Big5, it warns and makes no changes either (`Found appended bytes that do not look like Big5 text. No changes made.`).

## Detection Algorithm

Detection uses a sample-based heuristic:

1. Reads the first 8 KB of the file.
2. If the sample is valid UTF-8, the file is classified as not-Big5.
3. Scans for Big5 double-byte sequences (lead byte 0x81-0xFE followed by a valid trail byte 0x40-0x7E or 0xA1-0xFE).
4. If at least 80% of candidate high-byte sequences are valid Big5 pairs, the file is classified as Big5.

## Running Tests

The test suite uses [busted](https://lunarmodules.github.io/busted/) via [plenary.nvim](https://github.com/nvim-lua/plenary.nvim).

First, generate the test fixtures:

```sh
lua test/fixtures/generate_fixtures.lua
```

Then run the tests (ensure plenary.nvim is available):

```sh
nvim --headless -c "PlenaryBustedDirectory test/ {minimal_init = 'test/minimal_init.lua'}" -c "qa"
```

Or set `PLENARY_PATH` if plenary is not in a standard location:

```sh
PLENARY_PATH=/path/to/plenary.nvim nvim --headless \
  -c "PlenaryBustedDirectory test/ {minimal_init = 'test/minimal_init.lua'}" \
  -c "qa"
```

## Scope

This plugin handles standard Big5 encoding only. The following are explicitly out of scope for v1:

- Big5-HKSCS (Hong Kong variant)
- Batch/directory conversion
- Other encodings (GB2312, GBK, Shift_JIS, etc.)
- UTF-8 to Big5 reverse conversion
- Backup file creation before conversion
- Binary content: Neovim's buffer model swaps an on-disk NUL byte (`0x00`) for an internal NL when loading a line, so files with embedded NUL bytes do not round-trip faithfully through the mixed-tail buffer branch. This only affects binary content, which was already out of scope.

## License

[MIT](LICENSE)
