-- lua/apollo/impl-agent.lua
-- Implementation agent – prompt → pseudocode → final code block.
-- Uses LSP workspace symbols **and** current‑file excerpt for context.
-- Streams output like ApolloChat and guarantees step‑2 runs even if the
-- first stream lacks a `[DONE]` marker.

local api, lsp = vim.api, vim.lsp
local M = {}

-- state -----------------------------------------------------------------
M.prompt_buf, M.prompt_win = nil, nil
M.resp_buf,   M.resp_win   = nil, nil
M.pending                    = "" -- streaming scratch

local endpoint = "http://127.0.0.1:8080/v1/chat/completions"

-- helpers ---------------------------------------------------------------
local function http_stream(payload, on_chunk)
  vim.fn.jobstart({
    "curl", "-s", "-N", "-X", "POST", endpoint,
    "-H", "Content-Type: application/json",
    "-d", vim.fn.json_encode(payload)
  }, { stdout_buffered = false, on_stdout = on_chunk, on_stderr = on_chunk })
end

local function create_resp()
  local w  = math.floor(vim.o.columns * 0.8)
  local h  = math.floor(vim.o.lines   * 0.65)
  local row = math.floor((vim.o.lines   - h) / 2)
  local col = math.floor((vim.o.columns - w) / 2)
  M.resp_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(M.resp_buf, 'filetype', 'markdown')
  M.resp_win = api.nvim_open_win(M.resp_buf, true, {
    relative='editor', row=row, col=col, width=w, height=h,
    style='minimal', border={"▛","▀","▜","▐","▟","▄","▙","▌"}
  })
  api.nvim_win_set_option(M.resp_win, 'wrap', true)
end

local function flush(text)
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

-- context ----------------------------------------------------------------
local function collect_symbols(words, per_word, max_total)
  if not (lsp and lsp.buf and lsp.buf.dynamic_workspace_symbols) then return "" end
  local added, seen, out = 0, {}, {}
  for _, w in ipairs(words) do
    local ok, syms = pcall(lsp.buf.dynamic_workspace_symbols, { query = w })
    if ok and syms then
      local c = 0
      for _, s in ipairs(syms) do
        if not seen[s.name] then
          out[#out+1] = s.name; seen[s.name] = true; c=c+1; added=added+1
          if c>=per_word or added>=max_total then break end
        end
      end
    end
    if added>=max_total then break end
  end
  return table.concat(out, "\n")
end

local function buffer_excerpt(max_lines)
  local buf = api.nvim_get_current_buf()
  local total = api.nvim_buf_line_count(buf)
  if total==0 then return "" end
  local lines = api.nvim_buf_get_lines(buf, 0, math.min(total,max_lines), false)
  return table.concat(lines, "\n")
end

-- step 2 ------------------------------------------------------------------
local function step2(prompt, pseudo)
  -- keywords from pseudo
  local kw_map, kws = {}, {}
  for w in pseudo:gmatch("[%w_]+") do if #w>3 then kw_map[w]=true end end
  for k in pairs(kw_map) do kws[#kws+1]=k end

  local symbols = collect_symbols(kws,5,60)
  local filectx = buffer_excerpt(400)

  local payload = {
    model='gemma3-4b-it', stream=true,
    messages={
      {role='system', content=[[You are CodeGenGPT. Using pseudocode, workspace symbols, and the current file excerpt, output ONLY ONE fenced markdown code block implementing the feature (or a diff). No comments outside the block.]]},
      {role='user', content="User request:\n"..prompt},
      {role='user', content="Pseudocode:\n"..pseudo},
      {role='user', content="Workspace symbols:\n"..symbols},
      {role='user', content="Current file excerpt (first 400 lines):\n"..filectx},
    }
  }

  http_stream(payload, function(_, data)
    if not data then return end
    for _, raw in ipairs(data) do
      if type(raw)=='string' and raw:sub(1,6)=='data: ' then
        local js = raw:sub(7)
        if js=='[DONE]' then api.nvim_buf_set_option(M.resp_buf,'modifiable',false); return end
        local ok, chunk = pcall(vim.fn.json_decode, js)
        if ok and chunk.choices then
          local c = chunk.choices[1].delta.content
          if type(c)=='string' then flush(c) end
        end
      end
    end
  end)
end

-- step 1 ------------------------------------------------------------------
local function step1(prompt)
  local acc, finished = {}, false
  local payload = {
    model='gemma3-4b-it', stream=true,
    messages={
      {role='system', content=[[You are PseudoGPT. Produce concise pseudocode (no comments). Output ONLY pseudocode.]]},
      {role='user',   content=prompt},
    }
  }

  local function conclude()
    if finished then return end
    finished=true
    if M.pending~='' then flush("\n") acc[#acc+1]=M.pending M.pending='' end
    step2(prompt, table.concat(acc, ""))
  end

  http_stream(payload, function(_, data)
    if not data then conclude(); return end
    for _, raw in ipairs(data) do
      if type(raw)=='string' and raw:sub(1,6)=='data: ' then
        local js = raw:sub(7)
        if js=='[DONE]' then conclude(); return end
        local ok, chunk = pcall(vim.fn.json_decode, js)
        if ok and chunk.choices then
          local t = chunk.choices[1].delta.content
          if type(t)=='string' then acc[#acc+1]=t; flush(t) end
        end
      end
    end
  end)
end

-- prompt UI ---------------------------------------------------------------
local function on_submit()
  local text = table.concat(api.nvim_buf_get_lines(M.prompt_buf,0,-1,false),"\n"):gsub("^Impl ▶ ","")
  if text=='' then M.close(); return end
  if M.prompt_win and api.nvim_win_is_valid(M.prompt_win) then api.nvim_win_close(M.prompt_win,true) end
  if M.prompt_buf and api.nvim_buf_is_valid(M.prompt_buf) then api.nvim_buf_delete(M.prompt_buf,{force=true}) end
  M.prompt_buf, M.prompt_win = nil,nil
  create_resp(); step1(text)
end

function M.open()
  if M.prompt_win and api.nvim_win_is_valid(M.prompt_win) then api.nvim_set_current_win(M.prompt_win) return end
  local w = math.floor(vim.o.columns*0.6)
  local row = math.floor(vim.o.lines/2-1)
  local col = math.floor((vim.o.columns-w)/2)
  M.prompt_buf = api.nvim_create_buf(false,true)
  api.nvim_buf_set_option(M.prompt_buf,'buftype','prompt')
  vim.fn.prompt_setprompt(M.prompt_buf,'Impl ▶ ')
  M.prompt_win = api.nvim_open_win(M.prompt_buf,true,{relative='editor',row=row,col=col,width=w,height=3,style='minimal',border='single'})
  api.nvim_command('startinsert')
  vim.keymap.set('i','<CR>',on_submit,{buffer=M.prompt_buf,silent=true})
end

-- cleanup ----------------------------------------------------------------
function M.close()
  if M.resp_win and api.nvim_win_is_valid(M.resp_win) then api.nvim_win_close(M.resp_win,true) end
  if M.resp_buf and api.nvim_buf_is_valid(M.resp_buf) then api.nvim_buf_delete(M.resp_buf,{force=true}) end
  if M.prompt_win and api.nvim_win_is_valid(M.prompt_win) then api.nvim_win_close(M.prompt_win,true) end
  if M.prompt_buf and api.nvim_buf_is_valid(M.prompt_buf) then api.nvim_buf_delete(M.prompt_buf,{force=true}) end
  M.prompt_buf,M.prompt_win,M.resp_buf,M.resp_win,M.pending=nil,nil,nil,nil,""
end

function M.setup() api.nvim_create_user_command('ApolloImpl', function() M.open() end,{}) end
return M
