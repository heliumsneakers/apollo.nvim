local api = vim.api

local Menu = {}

-- internal state
Menu.buf = nil
Menu.win = nil
Menu.items = {}   -- { label = "Apollo Chat", cmd = "ApolloChat" }

--------------------------------------------------
-- Declare commands to expose in the picker
--------------------------------------------------
local COMMANDS = {
  { cmd = "ApolloChat", label = "Apollo Chat"  },
  { cmd = "ApolloQuit", label = "Apollo Quit"  },
  -- add more here if you register new :Apollo* commands
}

--------------------------------------------------
-- Validate that each command exists before showing
--------------------------------------------------
local function _gather_items()
  Menu.items = {}
  local defined = api.nvim_get_commands({ builtin = false })
  for _, spec in ipairs(COMMANDS) do
    if defined[spec.cmd] then
      table.insert(Menu.items, spec)
    end
  end
end

--------------------------------------------------
-- Close buffer & window if they still exist
--------------------------------------------------
function Menu.close()
  if Menu.win and api.nvim_win_is_valid(Menu.win) then
    api.nvim_win_close(Menu.win, true)
  end
  if Menu.buf and api.nvim_buf_is_valid(Menu.buf) then
    api.nvim_buf_delete(Menu.buf, { force = true })
  end
  Menu.buf = nil
  Menu.win = nil
end

--------------------------------------------------
-- Run the command under cursor, then close
--------------------------------------------------
function Menu.execute()
  if not (Menu.buf and api.nvim_buf_is_valid(Menu.buf)) then return end
  local lnum   = api.nvim_win_get_cursor(Menu.win)[1]
  local entry  = Menu.items[lnum]
  if entry and entry.cmd then
    vim.cmd(entry.cmd)
  end
  Menu.close()
end

--------------------------------------------------
-- Show a centered floating window with Apollo commands
--------------------------------------------------
function Menu.open()
  if Menu.win and api.nvim_win_is_valid(Menu.win) then
    api.nvim_set_current_win(Menu.win)
    return
  end

  _gather_items()
  if #Menu.items == 0 then
    vim.notify('[Apollo] No commands found', vim.log.levels.WARN)
    return
  end

  -- scratch buffer (non-file, non-modifiable)
  Menu.buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(Menu.buf, 'buftype', 'nofile')
  api.nvim_buf_set_option(Menu.buf, 'bufhidden', 'wipe')
  api.nvim_buf_set_option(Menu.buf, 'filetype', 'apollo_menu')

  -- build the label list for display
  local labels = {}
  for _, it in ipairs(Menu.items) do table.insert(labels, it.label) end
  api.nvim_buf_set_lines(Menu.buf, 0, -1, false, labels)
  api.nvim_buf_set_option(Menu.buf, 'modifiable', false)

  -- window geometry
  local width  = math.max(18, math.floor(vim.o.columns * 0.20))
  local height = #labels
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width ) / 2)

  Menu.win = api.nvim_open_win(Menu.buf, true, {
    relative = 'editor',
    row      = row,
    col      = col,
    width    = width,
    height   = height,
    style    = 'minimal',
    border   = 'rounded',
  })

  api.nvim_win_set_option(Menu.win, 'cursorline', true)
  api.nvim_win_set_option(Menu.win, 'number', false)
  api.nvim_win_set_option(Menu.win, 'relativenumber', false)
  api.nvim_win_set_option(Menu.win, 'wrap', false)

  -- keymaps
  local map = function(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = Menu.buf, silent = true, nowait = true })
  end

  map('<CR>',        Menu.execute)
  map('<LeftMouse>', Menu.execute)
  map('q',           Menu.close)
  map('<Esc>',       Menu.close)
end

--------------------------------------------------
-- Public: add :ApolloMenu user command
--------------------------------------------------
function Menu.setup()
  api.nvim_create_user_command('ApolloMenu', function() Menu.open() end, {})
  vim.keymap.set('n', '<leader>|', Menu.open, { desc = 'Open Apollo menu' })
end

return Menu
