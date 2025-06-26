-- lua/apollo.lua
local api = vim.api

local M = { history_lines = {} }

--------------------------------------------------
-- Utility: flatten any accidental newlines in the
-- prompt buffer so the user always edits a single
-- logical line (even after a paste).
--------------------------------------------------
local function _flatten_prompt(buf)
  if not api.nvim_buf_is_valid(buf) then return end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines > 1 then
    local joined = table.concat(lines, ' '):gsub('%s+$', '')
    api.nvim_buf_set_lines(buf, 0, -1, false, { joined })
    -- move cursor to end of line
    local win = api.nvim_get_current_win()
    api.nvim_win_set_cursor(win, { 1, #joined })
  end
end

--------------------------------------------------
-- Utility: horizontally center text inside a
-- floating window of `total_width` columns.
--------------------------------------------------
local function _center(lines, total_width)
  -- remove only trailing spaces when computing len
  local max_len = 0
  for _, ln in ipairs(lines) do
    local l = ln:gsub('%s+$', '')
    local w = vim.fn.strdisplaywidth and vim.fn.strdisplaywidth(l) or #l
    if w > max_len then max_len = w end
  end
  local pad = math.max(math.floor((total_width - max_len) / 2), 0)
  local pref = string.rep(' ', pad)

  local out = {}
  for _, ln in ipairs(lines) do
    table.insert(out, pref .. ln)
  end
  return out
end
--- Close both windows; save=true resets history, save=false preserves
function M.quit(save)
  if M.input_buf and api.nvim_buf_is_valid(M.input_buf) then
    api.nvim_buf_set_option(M.input_buf, 'modified', false)
  end
  if M.resp_buf and api.nvim_buf_is_valid(M.resp_buf) then
    api.nvim_buf_set_option(M.resp_buf, 'modified', false)
  end
  if M.resp_win and api.nvim_win_is_valid(M.resp_win) then
    api.nvim_win_close(M.resp_win, true)
  end
  if M.input_win and api.nvim_win_is_valid(M.input_win) then
    api.nvim_win_close(M.input_win, true)
  end
  if save then
    M.history_lines = {}
  end
end

--- ASCII splash art!! 
local function splash()
  return {
      "                                                    ",
      "                                                    ",
      "  █████╗ ██████╗  ██████╗ ██╗     ██╗      ██████╗  ",
      " ██╔══██╗██╔══██╗██╔═══██╗██║     ██║     ██╔═══██╗ ",
      " ███████║██████╔╝██║   ██║██║     ██║     ██║   ██║ ",
      " ██╔══██║██╔═══╝ ██║   ██║██║     ██║     ██║   ██║ ",
      " ██║  ██║██║     ╚██████╔╝███████╗███████╗╚██████╔╝ ",
      " ╚═╝  ╚═╝╚═╝      ╚═════╝ ╚══════╝╚══════╝ ╚═════╝  ",
      "╔█████████████████████████████████████████████████╗ ",
      "╚═════════════════════════════════════════════════╝ ",
  }
end

--- Open UI with conversation loaded
function M.open_ui()
  local total_lines = vim.o.lines
  local resp_h = math.floor(total_lines * 0.65)
  local input_h = total_lines - resp_h - 10
  local width = math.floor(vim.o.columns * 0.8)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Create or reuse response buffer
  if not (M.resp_buf and api.nvim_buf_is_valid(M.resp_buf)) then
    M.resp_buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_option(M.resp_buf, 'filetype', 'markdown')
  end

  -- Open response window
  M.resp_win = api.nvim_open_win(M.resp_buf, true, {
    relative = 'editor', row = 1, col = col,
    width = width, height = resp_h,
    style = 'minimal',
    border = { "▛", "▀", "▜", "▐", "▟", "▄", "▙", "▌" },
  })
  api.nvim_win_set_option(M.resp_win, 'wrap', true)
  api.nvim_buf_set_keymap(M.resp_buf, 'n', '<leader>q', [[<Cmd>lua require('apollo').quit(false)<CR>]], { noremap = true, silent = true })

  -- Populate with splash or history (centered if fresh)
  api.nvim_buf_set_option(M.resp_buf, 'modifiable', true)
  local content
  if #M.history_lines == 0 then
    content = _center(splash(), width)
  else
    content = M.history_lines
  end
  api.nvim_buf_set_lines(M.resp_buf, 0, -1, false, content)
  api.nvim_buf_set_option(M.resp_buf, 'modifiable', false)

  -- Create or reuse input buffer
  if not (M.input_buf and api.nvim_buf_is_valid(M.input_buf)) then
    M.input_buf = api.nvim_create_buf(false, false)
    api.nvim_buf_set_option(M.input_buf, 'buftype', 'prompt')
    api.nvim_buf_set_option(M.input_buf, 'bufhidden', 'hide')
    api.nvim_buf_set_option(M.input_buf, 'buflisted', false)
    api.nvim_buf_set_option(M.input_buf, 'filetype', 'text')
  end

  -- Clear input if fresh
  if #M.history_lines == 0 then
    api.nvim_buf_set_lines(M.input_buf, 0, -1, false, {})
  end

  -- Open input window
  M.input_win = api.nvim_open_win(M.input_buf, true, {
    relative = 'editor', row = resp_h + 2, col = col,
    width = width, height = input_h,
    style = 'minimal',
    border = { "▛", "▀", "▜", "▐", "▟", "▄", "▙", "▌" },
  })
  api.nvim_win_set_option(M.input_win, 'wrap', true)
  api.nvim_win_set_option(M.input_win, 'linebreak', true)

  vim.fn.prompt_setprompt(M.input_buf, '→ ')
  api.nvim_buf_set_option(M.input_buf, 'modified', false)
  api.nvim_command('startinsert')
  api.nvim_buf_set_keymap(M.input_buf, 'i', '<CR>', [[<Cmd>lua require('apollo').send_prompt()<CR>]], { noremap = true, silent = true })
  api.nvim_buf_set_keymap(M.input_buf, 'n', '<leader>q', [[<Cmd>lua require('apollo').quit(false)<CR>]], { noremap = true, silent = true })

  -- auto-flatten pasted newlines
  api.nvim_create_autocmd({ 'TextChangedI', 'TextChangedP' }, {
    buffer = M.input_buf,
    callback = function() _flatten_prompt(M.input_buf) end,
  })
end

--- Send prompt and stream response
function M.send_prompt()
  local raw = api.nvim_buf_get_lines(M.input_buf, 0, -1, false)
  local prompt = table.concat(raw, ' '):gsub('^→ ', '')
  api.nvim_buf_set_lines(M.input_buf, 0, -1, false, {})

  local payload = vim.fn.json_encode({ model = 'gemma3-4b-it', messages = { { role = 'user', content = prompt } }, stream = true })
  local cmd = { 'curl', '-s', '-N', '-X', 'POST', 'http://127.0.0.1:8080/v1/chat/completions', '-H', 'Content-Type: application/json', '-d', payload }

  M.pending = ''
  api.nvim_buf_set_option(M.resp_buf, 'modifiable', true)

  local function handle_chunk(_, data)
    if not data then return end
    for _, raw in ipairs(data) do
      if type(raw) == 'string' and raw:match('^data: ') then
        local js = raw:sub(7)
        if js == '[DONE]' then
          api.nvim_buf_set_option(M.resp_buf, 'modifiable', false)
          return
        end
        local ok, chunk = pcall(vim.fn.json_decode, js)
        if ok and chunk.choices then
          local c = chunk.choices[1].delta.content
          if type(c) == 'string' then
            M.pending = M.pending .. c
            local flush = {}
            for line in M.pending:gmatch("(.-)\n") do table.insert(flush, line) end
            if #flush > 0 then
              api.nvim_buf_set_lines(M.resp_buf, -1, -1, false, flush)
              vim.list_extend(M.history_lines, flush)
              M.pending = M.pending:match(".*\n(.*)") or ''
            end
          end
        end
      end
    end
  end
  vim.fn.jobstart(cmd, { stdout_buffered = false, on_stdout = handle_chunk, on_stderr = handle_chunk })
end

--- Explicit quit command resets history
function M.ApolloQuit()
  M.quit(true)
end

--- Setup commands
function M.setup()
  api.nvim_create_user_command('ApolloChat', M.open_ui, {})
  api.nvim_create_user_command('ApolloQuit', M.ApolloQuit, {})
end

return M
