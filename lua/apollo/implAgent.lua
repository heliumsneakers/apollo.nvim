-- lua/apollo/impl-agent.lua
-- Implementation agent: prompt ➜ pseudocode ➜ targeted code generation.
-- Picks LSP workspace symbols that match tokens in the pseudocode to build context.

local api, lsp = vim.api, vim.lsp
local M = {}

-- state
M.prompt_buf, M.prompt_win = nil, nil
M.resp_buf,   M.resp_win   = nil, nil

local endpoint = "http://127.0.0.1:8080/v1/chat/completions"

--------------------------------------------------
-- lightweight HTTP streaming via curl
--------------------------------------------------
local function http_stream(payload, on_chunk)
  local cmd = {
    "curl", "-s", "-N", "-X", "POST", endpoint,
    "-H", "Content-Type: application/json", "-d", vim.fn.json_encode(payload)
  }
  vim.fn.jobstart(cmd, { stdout_buffered = false, on_stdout = on_chunk, on_stderr = on_chunk })
end

--------------------------------------------------
-- floating response window
--------------------------------------------------
local function create_resp()
  local width  = math.floor(vim.o.columns * 0.75)
  local height = math.floor(vim.o.lines   * 0.60)
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width ) / 2)

  M.resp_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(M.resp_buf, 'filetype', 'markdown')

  M.resp_win = api.nvim_open_win(M.resp_buf, true, {
    relative = 'editor', row = row, col = col,
    width = width, height = height, style = 'minimal', border = 'rounded'
  })
  api.nvim_win_set_option(M.resp_win, 'wrap', true)
end

--------------------------------------------------
-- Helper: harvest LSP workspace symbols matching a set of keywords
--------------------------------------------------
local function collect_symbol_context(keywords, max_per_word, max_total)
  if not lsp or not lsp.buf or not lsp.buf.dynamic_workspace_symbols then return "" end
  local seen, lines, total = {}, {}, 0
  for _, word in ipairs(keywords) do
    local ok, symbols = pcall(lsp.buf.dynamic_workspace_symbols, { query = word })
    if ok and symbols then
      local added = 0
      for _, sym in ipairs(symbols) do
        if not seen[sym.name] then
          table.insert(lines, sym.name)
          seen[sym.name] = true
          added = added + 1
          total = total + 1
          if added >= max_per_word or total >= max_total then break end
        end
      end
    end
    if total >= max_total then break end
  end
  return table.concat(lines, "\n")
end

--------------------------------------------------
-- STEP 2: code generation with targeted context
--------------------------------------------------
local function step2(user_prompt, pseudocode)
  -- derive keywords from pseudocode (simple split + filter)
  local kw = {}
  for w in pseudocode:gmatch("[%w_]+") do
    if #w > 3 then kw[#kw+1] = w end
  end
  -- de-dup
  local uniq = {}
  for _, w in ipairs(kw) do uniq[w] = true end
  kw = {}
  for w in pairs(uniq) do kw[#kw+1] = w end

  local context = collect_symbol_context(kw, 5, 60)

  local payload = {
    model = 'gemma3-4b-it', stream = true,
    messages = {
      { role = 'system', content = [[You are CodeGenGPT. Using the pseudocode and workspace symbols, output ONLY one fenced markdown code block implementing the feature. No extra text.]] },
      { role = 'user', content = "User request:\n" .. user_prompt },
      { role = 'user', content = "Pseudocode:\n" .. pseudocode },
      { role = 'user', content = "Workspace symbols:\n" .. context },
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
          if type(c) == 'string' then
            api.nvim_buf_set_option(M.resp_buf, 'modifiable', true)
            api.nvim_buf_set_lines(M.resp_buf, -1, -1, false, { c })
            api.nvim_buf_set_option(M.resp_buf, 'modifiable', false)
          end
        end
      end
    end
  end)
end

--------------------------------------------------
-- STEP 1: pseudocode generation
--------------------------------------------------
local function step1(user_prompt)
  local pseudo_acc = {}

  local payload = {
    model = 'gemma3-4b-it', stream = true,
    messages = {
      { role = 'system', content = [[You are PseudoGPT. Produce concise pseudocode (no comments) for the request. Output only pseudocode.]] },
      { role = 'user', content = user_prompt },
    }
  }

  http_stream(payload, function(_, data)
    if not data then return end
    for _, raw in ipairs(data) do
      if type(raw) == 'string' and raw:sub(1,6) == 'data: ' then
        local js = raw:sub(7)
        if js == '[DONE]' then
          local pseudo = table.concat(pseudo_acc, "")
          step2(user_prompt, pseudo)
          return
        end
        local ok, chunk = pcall(vim.fn.json_decode, js)
        if ok and chunk.choices then
          local c = chunk.choices[1].delta.content
          if type(c) == 'string' then
            table.insert(pseudo_acc, c)
            api.nvim_buf_set_option(M.resp_buf, 'modifiable', true)
            api.nvim_buf_set_lines(M.resp_buf, -1, -1, false, { c })
            api.nvim_buf_set_option(M.resp_buf, 'modifiable', false)
          end
        end
      end
    end
  end)
end

--------------------------------------------------
-- prompt handling
--------------------------------------------------
local function on_prompt_submit()
  local user_lines = api.nvim_buf_get_lines(M.prompt_buf, 0, -1, false)
  local prompt     = table.concat(user_lines, "\n"):gsub("^Impl ▶ ", "")
  if prompt == '' then M.close() return end

  -- destroy prompt UI
  if M.prompt_win and api.nvim_win_is_valid(M.prompt_win) then
    api.nvim_win_close(M.prompt_win, true)
  end
  if M.prompt_buf and api.nvim_buf_is_valid(M.prompt_buf) then
    api.nvim_buf_delete(M.prompt_buf, { force = true })
  end
  M.prompt_buf, M.prompt_win = nil, nil

  -- create response window and begin stage 1
  create_resp()
  step1(prompt)
end

function M.open()
  if M.prompt_win and api.nvim_win_is_valid(M.prompt_win) then
    api.nvim_set_current_win(M.prompt_win)
    return
  end

  local width  = math.floor(vim.o.columns * 0.6)
  local height = 3
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width ) / 2)

  M.prompt_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(M.prompt_buf, 'buftype', 'prompt')
  vim.fn.prompt_setprompt(M.prompt_buf, 'Impl ▶ ')

  M.prompt_win = api.nvim_open_win(M.prompt_buf, true, {
    relative = 'editor', row = row, col = col, width = width, height = height,
    style = 'minimal', border = 'single'
  })

  api.nvim_command('startinsert')
  vim.keymap.set('i', '<CR>', on_prompt_submit, { buffer = M.prompt_buf, silent = true })
end

function M.close()
  if M.resp_win and api.nvim_win_is_valid(M.resp_win) then api.nvim_win_close(M.resp_win, true) end
  if M.resp_buf and api.nvim_buf_is_valid(M.resp_buf) then api.nvim_buf_delete(M.resp_buf, { force = true }) end
  if M.prompt_win and api.nvim_win_is_valid(M.prompt_win) then api.nvim_win_close(M.prompt_win, true) end
  if M.prompt_buf and api.nvim_buf_is_valid(M.prompt_buf) then api.nvim_buf_delete(M.prompt_buf, { force = true }) end
  M.prompt_buf, M.prompt_win, M.resp_buf, M.resp_win = nil, nil, nil, nil
end

function M.setup()
  api.nvim_create_user_command('ApolloImpl', function() M.open() end, {})
end

return M
