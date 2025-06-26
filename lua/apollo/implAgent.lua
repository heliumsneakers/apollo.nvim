-- lua/apollo/impl-agent.lua
-- Implementation agent v2
-- 1. Ask user for feature ► text prompt
-- 2. Ask which file to update (via vim.ui.select over project files)
-- 3. Send [request, pseudocode, selected-file contents, workspace symbols] to model
-- 4. Stream pseudocode then final fenced code block

local api, lsp, fn, ui = vim.api, vim.lsp, vim.fn, vim.ui
local M = {}

-- state -----------------------------------------------------------------
M.prompt_buf = nil
M.prompt_win = nil
M.resp_buf   = nil
M.resp_win   = nil
M.pending    = ""

local endpoint = "http://127.0.0.1:8080/v1/chat/completions"

-- helper ----------------------------------------------------------------
local function http_stream(payload, cb)
  fn.jobstart({
    "curl","-s","-N","-X","POST",endpoint,
    "-H","Content-Type: application/json",
    "-d",fn.json_encode(payload)
  },{stdout_buffered=false,on_stdout=cb,on_stderr=cb})
end

local function create_resp()
  local w = math.floor(vim.o.columns*0.8)
  local h = math.floor(vim.o.lines*0.65)
  local row,col = math.floor((vim.o.lines-h)/2), math.floor((vim.o.columns-w)/2)
  M.resp_buf = api.nvim_create_buf(false,true)
  api.nvim_buf_set_option(M.resp_buf,'filetype','markdown')
  M.resp_win = api.nvim_open_win(M.resp_buf,true,{relative='editor',row=row,col=col,width=w,height=h,style='minimal',border={'▛','▀','▜','▐','▟','▄','▙','▌'}})
  api.nvim_win_set_option(M.resp_win,'wrap',true)
end

local function flush(txt)
  M.pending=M.pending..txt
  local out={}
  for ln in M.pending:gmatch("(.-)\n") do out[#out+1]=ln end
  if #out>0 then
    api.nvim_buf_set_option(M.resp_buf,'modifiable',true)
    api.nvim_buf_set_lines(M.resp_buf,-1,-1,false,out)
    api.nvim_buf_set_option(M.resp_buf,'modifiable',false)
    M.pending=M.pending:match(".*\n(.*)") or ''
  end
end

-- gather project files ---------------------------------------------------
local function project_files(max)
  local root = fn.getcwd()
  local files = fn.systemlist("git -C "..root.." ls-files")
  if vim.v.shell_error~=0 or #files==0 then
    files = fn.systemlist("rg --files")
  end
  if max and #files>max then
    -- simple trim
    local sub={}
    for i=1,max do sub[i]=files[i] end
    files=sub
  end
  table.sort(files)
  return files
end

-- LSP & file context -----------------------------------------------------
local function symbols_for(words)
  if not (lsp and lsp.buf and lsp.buf.dynamic_workspace_symbols) then return "" end
  local added,seen,out=0,{},{}
  for _,w in ipairs(words) do
    local ok,syms=pcall(lsp.buf.dynamic_workspace_symbols,{query=w})
    if ok and syms then
      for i=1,math.min(#syms,5) do
        local n=syms[i].name
        if not seen[n] then out[#out+1]=n;seen[n]=true;added=added+1 end
        if added>=60 then break end
      end
    end
    if added>=60 then break end
  end
  return table.concat(out,"\n")
end

local function read_file(path,max_lines)
  local ok,lines = pcall(fn.readfile,path)
  if not ok then return "" end
  if max_lines and #lines>max_lines then
    local sub={}
    for i=1,max_lines do sub[i]=lines[i] end
    lines=sub
  end
  return table.concat(lines,"\n")
end

-- step2 ------------------------------------------------------------------
local function step2(user_prompt,pseudo,file_path)
  local kwm,words={},{}
  for w in pseudo:gmatch("[%w_]+") do if #w>3 then kwm[w]=true end end
  for w in pairs(kwm) do words[#words+1]=w end
  local symbols = symbols_for(words)
  local file_ctx = read_file(file_path, 1000)
  local payload={
    model='gemma3-4b-it',stream=true,
    messages={
      {role='system',content=[[You are CodeGenGPT. Using the provided pseudocode, workspace symbols, and the selected file's content, output ONLY one fenced markdown code block (or unified diff) implementing the feature the code block should be in the language reflected in the file. NO other text.]]},
      {role='user',content='User request:\n'..user_prompt},
      {role='user',content='Pseudocode:\n'..pseudo},
      {role='user',content='Workspace symbols:\n'..symbols},
      {role='user',content='Target file ('..file_path..') first 400 lines:\n'..file_ctx},
    }
  }
  http_stream(payload,function(_,data)
    if not data then return end
    for _,raw in ipairs(data or {}) do
      if type(raw)=='string' and raw:sub(1,6)=='data: ' then
        local js=raw:sub(7)
        if js=='[DONE]' then api.nvim_buf_set_option(M.resp_buf,'modifiable',false);return end
        local ok,chunk=pcall(fn.json_decode,js)
        if ok and chunk.choices then
          local c=chunk.choices[1].delta.content
          if type(c)=='string' then flush(c) end
        end
      end
    end
  end)
end

-- step1 pseudocode --------------------------------------------------------
local function step1(prompt,file_path)
  local acc,done={},false
  local payload={model='gemma3-4b-it',stream=true,messages={{role='system',content='You are PseudoGPT. Output ONLY concise pseudocode.'},{role='user',content=prompt}}}
  http_stream(payload,function(_,data)
    if not data then return end
    for _,raw in ipairs(data) do
      if type(raw)=='string' and raw:sub(1,6)=='data: ' then
        local js=raw:sub(7)
        if js=='[DONE]' then if not done then done=true; step2(prompt,table.concat(acc,''),file_path) end; return end
        local ok,ch=pcall(fn.json_decode,js)
        if ok and ch.choices then
          local t=ch.choices[1].delta.content
          if type(t)=='string' then acc[#acc+1]=t; flush(t) end
        end
      end
    end
  end)
end

-- prompt & file select ----------------------------------------------------
local function after_user_prompt(user_text)
  -- choose file
  ui.select(project_files(500),{prompt='Select file to modify'},function(choice)
    if not choice then M.close(); return end
    create_resp()
    step1(user_text,choice)
  end)
end

local function on_submit()
  local txt=table.concat(api.nvim_buf_get_lines(M.prompt_buf,0,-1,false),'\n'):gsub('^Impl ▶ ','')
  if txt=='' then M.close();return end
  if M.prompt_win and api.nvim_win_is_valid(M.prompt_win) then api.nvim_win_close(M.prompt_win,true) end
  if M.prompt_buf and api.nvim_buf_is_valid(M.prompt_buf) then api.nvim_buf_delete(M.prompt_buf,{force=true}) end
  M.prompt_buf,M.prompt_win=nil,nil
  after_user_prompt(txt)
end

function M.open()
  if M.prompt_win and api.nvim_win_is_valid(M.prompt_win) then api.nvim_set_current_win(M.prompt_win) return end
  local w=math.floor(vim.o.columns*0.6)
  local row,col=math.floor(vim.o.lines/2-1),math.floor((vim.o.columns-w)/2)
  M.prompt_buf=api.nvim_create_buf(false,true)
  api.nvim_buf_set_option(M.prompt_buf,'buftype','prompt')
  vim.fn.prompt_setprompt(M.prompt_buf,'Impl ▶ ')
  M.prompt_win=api.nvim_open_win(M.prompt_buf,true,{relative='editor',row=row,col=col,width=w,height=3,style='minimal',border='single'})
  api.nvim_command('startinsert')
  vim.keymap.set('i','<CR>',on_submit,{buffer=M.prompt_buf,silent=true})
end

function M.close()
  if M.resp_win and api.nvim_win_is_valid(M.resp_win) then api.nvim_win_close(M.resp_win,true) end
  if M.resp_buf and api.nvim_buf_is_valid(M.resp_buf) then api.nvim_buf_delete(M.resp_buf,{force=true}) end
  if M.prompt_win and api.nvim_win_is_valid(M.prompt_win) then api.nvim_win_close(M.prompt_win,true) end
  if M.prompt_buf and api.nvim_buf_is_valid(M.prompt_buf) then api.nvim_buf_delete(M.prompt_buf,{force=true}) end
  M.prompt_buf,M.prompt_win,M.resp_buf,M.resp_win,M.pending=nil,nil,nil,nil,''
end

function M.setup() api.nvim_create_user_command('ApolloImpl',function() M.open() end,{}) end
return M
