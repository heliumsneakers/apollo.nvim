-- lua/apollo/impl-agent.lua  –  RAG Q-and-A assistant
local api, fn = vim.api, vim.fn
local sqlite  = require('sqlite')

-- ── config ---------------------------------------------------------------
local cfg = {
  projectName   = fn.fnamemodify(fn.getcwd(), ':t'),
  embedEndpoint = 'http://127.0.0.1:8080/v1/embeddings',
  chatEndpoint  = 'http://127.0.0.1:8080/v1/chat/completions',
  dbName        = 'lsp_chunks',
  topK          = 6,
}

local function db_path()
  return ('%s/%s_rag.sqlite'):format(fn.stdpath('data'), cfg.projectName)
end

-- ── http helpers ---------------------------------------------------------
local function system_json(cmd)
  local raw = fn.system(cmd)
  if vim.v.shell_error ~= 0 then error(raw) end
  return fn.json_decode(raw)
end

local function embed(text)
  local res = system_json{
    'curl','-s','-X','POST',cfg.embedEndpoint,
    '-H','Content-Type: application/json',
    '-d', fn.json_encode{ model='gemma3-embed',input={text},pooling='mean' }
  }
  if res.error then error(res.error.message) end
  return res.data[1].embedding
end

-- ── cosine ---------------------------------------------------------------
local function cosine(a,b)
  local dot,na,nb = 0,0,0
  for i=1,#a do
    dot = dot + a[i]*b[i]; na = na + a[i]^2; nb = nb + b[i]^2
  end
  return dot / (math.sqrt(na)*math.sqrt(nb) + 1e-8)
end

-- ── load vectors once per session ---------------------------------------
local VEC, TXT
local function load_vectors()
  if VEC then return VEC, TXT end

  -- open connection immediately and keep it open
  local db = require('sqlite'){
    uri   = db_path(),
    create = false,                 -- DB already exists
    opts  = { keep_open = true },   -- <<< important
  }

  local rows = db:eval('SELECT text, vec FROM '..cfg.dbName) or {}
  VEC, TXT = {}, {}
  for _,r in ipairs(rows) do
    local v = fn.json_decode(r.vec)  -- we stored JSON
    VEC[#VEC+1] = v
    TXT[#TXT+1] = r.text
  end
  return VEC, TXT
end

-- ── retrieve top-K --------------------------------------------------------
local function retrieve(question)
  local qvec          = embed(question)
  local vecs, texts   = load_vectors()

  -- Build keyword set from the question (length >3, lowercase)
  local kw = {}
  for w in question:lower():gmatch('%w+') do
    if #w > 3 then kw[w] = true end
  end

  local scored = {}
  for i, v in ipairs(vecs) do
    local base   = cosine(qvec, v)          -- semantic score
    local bonus  = 0                        -- keyword hit boost
    local t_low  = texts[i]:lower()

    for w in pairs(kw) do
      if t_low:find(w, 1, true) then
        bonus = bonus + 0.10               -- +0.10 per hit (tweakable)
      end
    end

    if bonus > 0 then                       -- ignore zero-overlap chunks
      scored[#scored+1] = { idx = i, score = base + bonus }
    end
  end

  table.sort(scored, function(a,b) return a.score > b.score end)

  local out = {}
  for i = 1, math.min(cfg.topK, #scored) do
    out[#out+1] = texts[scored[i].idx]
  end
  return out
end

-- ── streaming chat 
local function chat(prompt, out_buf)
  local pending = ''

  -- open for writing once
  api.nvim_buf_set_option(out_buf, 'modifiable', true)

  fn.jobstart({
    'curl','-s','-N','-X','POST',cfg.chatEndpoint,
    '-H','Content-Type: application/json',
    '-d', fn.json_encode{
      model='gemma3-4b-it',
      stream=true,
      messages={{role='user',content=prompt}}
    }
  },{
    stdout_buffered=false,
    on_stdout=function(_,data)
      if not data then return end
      for _,ln in ipairs(data) do
        if ln:sub(1,6) ~= 'data: ' then goto continue end
        local js = ln:sub(7)
        if js == '[DONE]' then
          -- flush tail fragment
          if #pending > 0 then
            api.nvim_buf_set_lines(out_buf, -1, -1, false, { pending })
          end
          api.nvim_buf_set_option(out_buf, 'modifiable', false)
          return
        end
        local ok, obj = pcall(fn.json_decode, js)
        if ok and obj.choices then
          local delta = obj.choices[1].delta.content
          if type(delta) == 'string' then
            pending = pending .. delta
            local flush = {}
            for line in pending:gmatch('(.-)\n') do
              flush[#flush+1] = line
            end
            if #flush > 0 then
              api.nvim_buf_set_lines(out_buf, -1, -1, false, flush)
              pending = pending:match('.*\n(.*)') or ''
            end
          end
        end
        ::continue::
      end
    end
  })
end


-- ── UI: prompt & output windows -----------------------------------------
local State = { prompt_buf=nil,prompt_win=nil, resp_buf=nil,resp_win=nil }

local function close_all()
  for _,k in ipairs{'resp_win','prompt_win'} do
    if State[k] and api.nvim_win_is_valid(State[k]) then
      api.nvim_win_close(State[k], true)
    end
  end
  for _,k in ipairs{'resp_buf','prompt_buf'} do
    if State[k] and api.nvim_buf_is_valid(State[k]) then
      api.nvim_buf_delete(State[k], {force=true})
    end
  end
  State = { prompt_buf=nil,prompt_win=nil,resp_buf=nil,resp_win=nil }
end

local function open_prompt()
  if State.prompt_win and api.nvim_win_is_valid(State.prompt_win) then
    api.nvim_set_current_win(State.prompt_win); return
  end
  local w = math.floor(vim.o.columns*0.6)
  local row,col = math.floor(vim.o.lines/2-1), math.floor((vim.o.columns-w)/2)
  State.prompt_buf = api.nvim_create_buf(false,true)
  api.nvim_buf_set_option(State.prompt_buf,'buftype','prompt')
  fn.prompt_setprompt(State.prompt_buf,'Ask ▶ ')
  State.prompt_win = api.nvim_open_win(State.prompt_buf,true,{
    relative='editor',row=row,col=col,width=w,height=3,
    style='minimal',border='single'
  })
  api.nvim_command('startinsert')
end

local function open_output()
  local w = math.floor(vim.o.columns*0.8)
  local h = math.floor(vim.o.lines*0.65)
  local row,col = math.floor((vim.o.lines-h)/2), math.floor((vim.o.columns-w)/2)
  State.resp_buf = api.nvim_create_buf(false,true)
  api.nvim_buf_set_option(State.resp_buf,'filetype','markdown')
  State.resp_win = api.nvim_open_win(State.resp_buf,true,{
    relative='editor',row=row,col=col,width=w,height=h,
    style='minimal',border={'▛','▀','▜','▐','▟','▄','▙','▌'}
  })
end

-- ── main flow -------------------------------------------------------------
local function handle_submit()
  local q = table.concat(api.nvim_buf_get_lines(
            State.prompt_buf,0,-1,false),'\n'):gsub('^Ask ▶ ','')
  if q=='' then close_all(); return end
  close_all()                   -- close prompt
  open_output()

  -- build augmented prompt
  local ctx = retrieve(q)
  local prompt = "Use the snippets below to answer the question.\n\n"
  for i,c in ipairs(ctx) do
    prompt = prompt..("----- snippet %d -----\n%s\n\n"):format(i,c)
  end
  prompt = prompt.."Q: "..q.."\nA: "

  chat(prompt, State.resp_buf)
end

-- ── public setup ----------------------------------------------------------
local M = {}
function M.open() open_prompt() end
function M.setup()
  vim.api.nvim_create_user_command('ApolloAsk', function() M.open() end, {})
  -- map <CR> inside prompt buffer once it exists
  vim.api.nvim_create_autocmd('BufWinEnter',{
    pattern='*',
    callback=function(a)
      if a.buf==State.prompt_buf then
        vim.keymap.set('i','<CR>',handle_submit,{buffer=a.buf})
      end
    end
  })
end

return M
