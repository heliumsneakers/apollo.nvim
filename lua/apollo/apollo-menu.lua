local api = vim.api

local Menu = {}

-- internal state
Menu.buf = nil
Menu.win = nil
Menu.items = {}

--------------------------------------------------
-- Collect every :Apollo* user command lazily
--------------------------------------------------
local function _gather_items()
  Menu.items = {}
  for name, _ in pairs(api.nvim_get_commands({ builtin = false })) do
    if name:match('^Apollo') then
      table.insert(Menu.items, name)
    end
  end
  table.sort(Menu.items)
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
  local cmd = api.nvim_get_current_line():match('^%s*(.-)%s*$')
  if cmd ~= '' then
    vim.cmd(cmd)
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

  -- insert command names then lock
  api.nvim_buf_set_lines(Menu.buf, 0, -1, false, Menu.items)
  api.nvim_buf_set_option(Menu.buf, 'modifiable', false)

  -- window geometry
  local width  = math.max(22, math.floor(vim.o.columns * 0.25))
  local height = #Menu.items + 2
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
  local opts = { noremap = true, silent = true, nowait = true, buffer = Menu.buf }
  api.nvim_buf_set_keymap(Menu.buf, 'n', '<CR>',        "<Cmd>lua require('apollo.menu').execute()<CR>", opts)
  api.nvim_buf_set_keymap(Menu.buf, 'n', '<LeftMouse>', "<Cmd>lua require('apollo.menu').execute()<CR>", opts)
  api.nvim_buf_set_keymap(Menu.buf, 'n', 'q',           "<Cmd>lua require('apollo.menu').close()<CR>",   opts)
  api.nvim_buf_set_keymap(Menu.buf, 'n', '<Esc>',       "<Cmd>lua require('apollo.menu').close()<CR>",   opts)
end

--------------------------------------------------
-- Public: add :ApolloMenu user command
--------------------------------------------------
function Menu.setup()
  api.nvim_create_user_command('ApolloMenu', function() Menu.open() end, {})
end

return Menu
