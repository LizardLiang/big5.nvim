--- test/spec/init_spec.lua
--- Unit tests for lua/big5/init.lua (setup and configuration)
--- Tests: TC-UNIT-I-01 through TC-UNIT-I-05
--- Requires full Neovim runtime. Run via plenary.nvim.

local big5 = require("big5")

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

-- Helper: check if a user command exists
local function command_exists(name)
  local ok = pcall(vim.api.nvim_get_commands, {})
  if not ok then return false end
  local cmds = vim.api.nvim_get_commands({})
  return cmds[name] ~= nil
end

-- Helper: check if the Big5AutoDetect augroup has autocmds registered
local function autodetect_augroup_has_autocmds()
  local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = "Big5AutoDetect" })
  if not ok then return false end
  return #autocmds > 0
end

describe("big5.setup", function()

  after_each(function()
    -- Clean up: clear the augroup to prevent leakage between tests
    pcall(vim.api.nvim_create_augroup, "Big5AutoDetect", { clear = true })
    -- Delete commands to reset state between tests
    pcall(vim.api.nvim_del_user_command, "Big5Check")
    pcall(vim.api.nvim_del_user_command, "Big5ToUtf8")
  end)

  -- TC-UNIT-I-01: setup() with no args applies defaults
  it("TC-UNIT-I-01: setup() with no args registers commands and does not register autocmd", function()
    big5.setup()

    assert.is_true(command_exists("Big5Check"), ":Big5Check command should be registered")
    assert.is_true(command_exists("Big5ToUtf8"), ":Big5ToUtf8 command should be registered")
    assert.is_false(
      autodetect_augroup_has_autocmds(),
      "BufReadPost autocmd should NOT be registered when auto_detect=false (default)"
    )
  end)

  -- TC-UNIT-I-02: setup() with auto_detect=true registers autocmd
  it("TC-UNIT-I-02: setup() with auto_detect=true registers BufReadPost autocmd", function()
    big5.setup({ auto_detect = true })

    assert.is_true(
      autodetect_augroup_has_autocmds(),
      "BufReadPost autocmd should be registered in Big5AutoDetect augroup"
    )
  end)

  -- TC-UNIT-I-03: setup() with auto_detect=false does not register autocmd
  it("TC-UNIT-I-03: setup() with auto_detect=false does not register autocmd", function()
    big5.setup({ auto_detect = false })

    assert.is_false(
      autodetect_augroup_has_autocmds(),
      "BufReadPost autocmd should NOT be registered when auto_detect=false"
    )
  end)

  -- TC-UNIT-I-04: Big5Check on unsaved buffer with no filepath shows error
  it("TC-UNIT-I-04: :Big5Check on a buffer with no file path shows an error notification", function()
    big5.setup()

    local messages, restore = capture_notifications()

    -- Open a new unsaved buffer with no file path
    vim.cmd("enew")
    -- The new buffer should have no file name
    assert.equal("", vim.api.nvim_buf_get_name(0))

    -- Run the command
    vim.cmd("Big5Check")

    restore()

    assert.is_true(#messages > 0, "Expected at least one notification")
    local found_error = false
    for _, m in ipairs(messages) do
      if m.msg:find("No file associated", 1, true) then
        found_error = true
        break
      end
    end
    assert.is_true(found_error, "Expected 'No file associated' error message, got: " .. vim.inspect(messages))
  end)

  -- TC-UNIT-I-05: Big5ToUtf8 on unsaved buffer with no filepath shows error
  it("TC-UNIT-I-05: :Big5ToUtf8 on a buffer with no file path shows an error notification", function()
    big5.setup()

    local messages, restore = capture_notifications()

    vim.cmd("enew")
    assert.equal("", vim.api.nvim_buf_get_name(0))

    vim.cmd("Big5ToUtf8")

    restore()

    assert.is_true(#messages > 0, "Expected at least one notification")
    local found_error = false
    for _, m in ipairs(messages) do
      if m.msg:find("No file associated", 1, true) then
        found_error = true
        break
      end
    end
    assert.is_true(found_error, "Expected 'No file associated' error message, got: " .. vim.inspect(messages))
  end)

  -- Additional: setup() can be called multiple times without error
  it("can be called multiple times without raising an error", function()
    local ok, err = pcall(function()
      big5.setup()
      big5.setup({ auto_detect = true })
      big5.setup({ auto_detect = false })
    end)
    assert.is_true(ok, "Repeated setup() calls raised an error: " .. tostring(err))
  end)

end)
