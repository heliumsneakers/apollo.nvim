-- lua/apollo/impl-agent.lua
-- Implementation agent: collects user intent ➜ pseudocode ➜ final code, using
-- both LSP symbols *and* the contents of the CURRENT buffer (so the model can
-- infer where the snippet belongs – e.g. inside `main.cpp`).
-- Output is streamed and appended to a floating markdown window line-by-line,
-- mimicking ApolloChat’s flush logic.

local api, lsp = vim.api, vim.lsp
local M = {}

--------------------------------------------------
-- state
--------------------------------------------------
M.prompt_buf, M.prompt_win = nil, nil
M.resp_buf,   M.resp_win   = nil, nil
M.pending                    = "" -- for streaming flush

local endpoint = "http://127.0.0.1:8080/v1/chat/completions"

--------------------------------------------------
-- utils ----------------------------------------------------------------------
--------------------------------------------------
local function http_stream(payload, on_chunk)
  local cmd = {
    "curl", "-s", "-N", "-X", "POST", endpoint,
    "-H", "Content-Type: application/json", "-d", vim.fn.json_encode(payload)
  }
  vim.fn.jobstart(cmd, { stdout_buffered = false, on_stdout = on_chunk, on_stderr = on_chunk })
end

local function create_resp()
  local width  = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines   * 0.65)
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width ) / 2)

  M.resp_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(M.resp_buf, 'filetype', 'markdown')

  M.resp_win = api.nvim_open_win(M.resp_buf, true, {
    relative = 'editor', row = row, col = col,
    width = width, height = height,
    style = 'minimal', border = { "▛", "▀", "▜", "▐", "▟", "▄", "▙", "▌" },
  })
  api.nvim_win_set_option(M.resp_win, 'wrap', true)
end

local function flush_stream(text)
  M.pending = M.pending .. text
  local lines = {}
  for ln in M.pending:gmatch("(.-)\n") do lines[#lines+1] = ln end
  if #lines > 0 then
    api.nvim_buf_set_option(M.resp_buf, 'modifiable', true)
    api.nvim_buf_set_lines(M.resp_buf, -1, -1, false, lines)
    api.nvim_buf_set_option(M.resp_buf, 'modifiable', false)
    M.pending = M.pending:match(".*\n(.*)") or ''
  end
end

--------------------------------------------------
-- context helpers -------------------------------------------------------------
--------------------------------------------------
local function collect_symbol_context(words, per_word, max_total)
  if not lsp or not lsp.buf or not lsp.buf.dynamic_workspace_symbols then return "" end
  local added, seen, out = 0, {}, {}
  for _, w in ipairs(words) do
    local ok, syms = pcall(lsp.buf.dynamic_workspace_symbols, { query = w })
    if ok and syms then
      local c = 0
      for _, s in ipairs(syms) do
        if not seen[s.name] then
          out[#out+1] = s.name
          seen[s.name] = true
          c, added = c+1, added+1
          if c >= per_word or added >= max_total then break end
        end
      end
    end
    if added >= max_total then break end
  end
  return table.concat(out, "\n")
end

local function current_buffer_excerpt(max_lines)
  local buf = api.nvim_get_current_buf()
  local total = api.nvim_buf_line_count(buf)
  if total == 0 then return "" end
  local lines = api.nvim_buf_get_lines(buf, 0, math.min(total, max_lines), false)
  return table.concat(lines, "\n")
end

--------------------------------------------------
-- STEP 2: code generation -----------------------------------------------------
--------------------------------------------------
local function step2(user_prompt, pseudocode)
  local kw_map = {}
  for w in pseudocode:gmatch("[%w_]+") do if #w > 3 then kw_map[w] = true end end
  local keywords = {}
  for w in pairs(kw_map) do keywords[#keywords+1] = w end

  local symbols  = collect_symbol_context(keywords, 5, 60)
  local file_ctx = current_buffer_excerpt(128000)

  local payload = {
    model = 'gemma3-4b-it', stream = true,
    messages = {
      { role = 'system', content = [[You are CodeGenGPT. Using pseudocode, workspace symbols, and the current file excerpt, output ONLY a single fenced markdown code block with the implementation inserted (or a diff/patch) so the user can paste it directly. No explanations.]] },
      { role = 'user', content = "User request:\n" .. user_prompt },
      { role = 'user', content = "Pseudocode:\n" .. pseudocode },
      { role = 'user', content = "Workspace symbols:\n" .. symbols },
      { role = 'user', content = "Current file excerpt (first 400 lines):\n" .. file_ctx },
    }
  }

  http_stream(payload, function(_, data)
    if not data then return end
    for _, raw in ipairs(data) do
      if type(raw) == 'string' and raw:sub(1,6) == 'data: ' then
        local js = raw:sub(7)
        if js == '[DONE]' then
          api.nvim_buf_set_option(M.resp_buf, 'modifiable', false)
          return
        end
        local ok, chunk = pcall(vim.fn.json_decode, js)
        if ok and chunk.choices then
          local c = chunk.choices[1].delta.content
          if type(c) == 'string' then flush_stream(c) end
        end
      end
    end
  end)
end

--------------------------------------------------
-- STEP 1: pseudocode ----------------------------------------------------------
--------------------------------------------------
local function step1(prompt)
  local acc = {}
  local payload = {
    model = 'gemma3-4b-it', stream = true,
    messages = {
      { role = 'system', content = [[You are PseudoGPT. Produce concise pseudocode (no comments) for the request. Output only pseudocode.]] },
      { role = 'user', content = prompt },
    }
  }

  http_stream(payload, function(_, data)
    if not data then return end
    for _, raw in ipairs(data) do
      if type(raw) == 'string' and raw:sub(1,6) == 'data: ' then
        local js = raw:sub(7)
        if js == '[DONE]' then
          step2(prompt, table.concat(acc, ""))
          return
        end
        local ok, chunk = pcall(vim.fn.json_decode, js)
        if ok and chunk.choices then
          local txt = chunk.choices[1].delta.content
          if type(txt) == 'string' then
            acc[#acc+1] = txt
            flush_stream(txt)
          end
        end
      end
    end
  end)
end

--------------------------------------------------
-- prompt UI -------------------------------------------------------------------
--------------------------------------------------
local function on_prompt_submit()
  local user_text = table.concat(api.nvim_buf_get_lines(M.prompt_buf, 0, -1, false), "\n"):gsub("^Impl ▶ ", "")
  if user_text == '' then M.close() return end

  -- remove prompt window
  if M.prompt_win and api.nvim_win_is_valid(M.prompt_win) then api.nvim_win_close(M.prompt_win, true) end
  if M.prompt_buf and api.nvim_buf_is_valid(M.prompt_buf) then api.nvim_buf_delete(M.prompt_buf, { force = true }) end
  M.prompt_buf, M.prompt_win = nil, nil

  create_resp()
  step1(user_text)
end

function M.open()
  if M.prompt_win and api.nvim_win_is_valid(M.prompt_win) then
    api.nvim_set_current_win(M.prompt_win)
    return
  end

  local width  = math.floor(vim.o.columns * 0.6)
  local row    = math.floor(vim.o.lines/2 - 1)
  local col    = math.floor((vim.o.columns - width)/2)

  M.prompt_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(M.prompt_buf, 'buftype', 'prompt')
  vim.fn.prompt_setprompt(M.prompt_buf, 'Impl ▶ ')

  M.prompt_win = api.nvim_open_win(M.prompt_buf, true, {
    relative='editor', row=row, col=col, width=width, height=3,
    style='minimal', border='single'
  })

  api.nvim_command('startinsert')
  vim.keymap.set('i', '<CR>', on_prompt_submit, { buffer = M.prompt_buf, silent = true })
end

--------------------------------------------------
-- cleanup ---------------------------------------------------------------------
--------------------------------------------------
function M.close()
  if M.resp_win and api.nvim_win_is_valid(M.resp_win) then api.nvim_win_close(M.resp_win, true) end
  if M.resp_buf and api.nvim_buf_is_valid(M.resp_buf) then api.nvim_buf_delete(M.resp_buf, { force = true }) end
  if M.prompt_win and api.nvim_win_is_valid(M.prompt_win) then api.nvim_win_close(M.prompt_win, true) end
  if M.prompt_buf and api.nvim_buf_is_valid(M.prompt_buf) then api.nvim_buf_delete(M.prompt_buf, { force = true }) end
  M.prompt_buf, M.prompt_win, M.resp_buf, M.resp_win, M.pending = nil, nil, nil, nil, ""
end

function M.setup()
  api.nvim_create_user_command('ApolloImpl', function() M.open() end, {})
end

return M
