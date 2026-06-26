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

Converts the current file from Big5 to UTF-8 in place. Overwrites the file on disk and reloads the buffer.

> **Warning:** This operation is irreversible. The original Big5 file is overwritten with no backup. Back up any important files before running this command.

```
:Big5ToUtf8
```

Behavior:
1. If the buffer has unsaved changes, prompts before proceeding.
2. Checks if the file is Big5-encoded. If not, notifies and exits without changes.
3. Converts the file content from Big5 to UTF-8 in memory.
4. If the file contains invalid byte sequences (that cannot be converted), prompts for confirmation before writing.
5. Writes the UTF-8 content to disk and reloads the buffer.
6. Sets `fileencoding` to `utf-8` for the current buffer.

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

## License

[MIT](LICENSE)
