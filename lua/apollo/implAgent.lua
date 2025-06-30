-- lua/apollo/impl-agent.lua  –  RAG Q-and-A assistant (json-vec) with SQL prefilter

local api, fn = vim.api, vim.fn
local sqlite  = require('sqlite')

-- ── configuration ────────────────────────────────────────────────────────
local cfg = {
  projectName  = fn.fnamemodify(fn.getcwd(), ':t'),
  embedEndpoint= 'http://127.0.0.1:8080/v1/embeddings',
  chatEndpoint = 'http://127.0.0.1:8080/v1/chat/completions',
  dbTable      = 'lsp_chunks',   -- matches ragIndexer.lua
  topK         = 6,
  sqlLimit     = 200,            -- pull at most 200 candidates per query
}

local function db_path()
  return ('%s/%s_rag.sqlite'):format(fn.stdpath('data'), cfg.projectName)
end

-- ── persistent DB handle ─────────────────────────────────────────────────
local DB
local function get_db()
  if DB and DB:isopen() then return DB end
  DB = sqlite{ uri=db_path(), create=false, opts={ keep_open=true } }
  return DB
end

-- ── misc helpers ─────────────────────────────────────────────────────────
local function system_json(cmd)
  local out = fn.system(cmd)
  if vim.v.shell_error ~= 0 then error(out) end
  return fn.json_decode(out)
end

local function embed(text)
  local res = system_json{
    'curl','-s','-X','POST',cfg.embedEndpoint,
    '-H','Content-Type: application/json',
    '-d', fn.json_encode{ model='gemma3-embed', input={text}, pooling='mean' }
  }
  if res.error then error(res.error.message) end
  return res.data[1].embedding
end

local function cosine(a,b)
  local dot, na, nb = 0,0,0
  for i=1,#a do
    dot = dot + a[i]*b[i]
    na  = na  + a[i]*a[i]
    nb  = nb  + b[i]*b[i]
  end
  return dot / (math.sqrt(na)*math.sqrt(nb) + 1e-8)
end

-- ── load & pre-filter corpus via SQL ────────────────────────────────────
local function load_candidates(keywords)
  local db = get_db()

  -- 1. WHERE-clause for keyword pre-filter -------------------------------
  local clauses, args = {}, {}
  for kw, _ in pairs(keywords) do
    clauses[#clauses+1] = "text LIKE ?"
    args[#args+1]       = "%%"..kw.."%%"
  end

  -- 2. build SQL ----------------------------------------------------------
  local sql
  if #clauses > 0 then
    sql = string.format(
      "SELECT text, vec_json AS vec FROM %s WHERE %s LIMIT %d",
      cfg.dbTable, table.concat(clauses, " OR "), cfg.sqlLimit
    )
  else
    sql = string.format(
      "SELECT text, vec_json AS vec FROM %s LIMIT %d",
      cfg.dbTable, cfg.sqlLimit
    )
  end

  -- 3. execute safely -----------------------------------------------------
  local rows
  if #args > 0 then
    rows = db:eval(sql, table.unpack(args))
  else
    rows = db:eval(sql)          -- no placeholders ⇒ no args
  end
  if rows == true then rows = {} end   -- SQLite returns boolean when empty

  -- 4. re-hydrate vectors -------------------------------------------------
  local vecs, texts = {}, {}
  for _, r in ipairs(rows) do
    local v = fn.json_decode(r.vec)    -- alias lets us keep using “vec”
    if type(v) == "table" then
      vecs[#vecs+1]  = v
      texts[#texts+1] = r.text
    end
  end
  return vecs, texts
end

-- ── hybrid retriever ─────────────────────────────────────────────────────
local function retrieve(query)
  -- 1) extract keywords (>3 chars) ----------------------------------------
  local kw, total = {},0
  for w in query:lower():gmatch('%w+') do
    if #w>3 and not kw[w] then
      kw[w]=true; total=total+1
    end
  end

  -- 2) load prefiltered candidates ----------------------------------------
  local vecs, texts = load_candidates(kw)
  if #vecs==0 then return {} end

  -- 3) embed query once --------------------------------------------------
  local qv = embed(query)

  -- 4) score & sort -------------------------------------------------------
  local scored = {}
  for i,v in ipairs(vecs) do
    local txt   = texts[i]:lower()
    local hits  = 0
    for k in pairs(kw) do
      if txt:find(k,1,true) then hits=hits+1 end
    end
    if hits>0 then
      -- path-boost if your header “/// file…” contains the keyword
      local path = txt:match('^///%s*([^\n]+)') or ''
      local path_hit = 0
      for k in pairs(kw) do
        if path:find(k,1,true) then path_hit=1; break end
      end
      -- hybrid score: semantic × coverage × (1 + path_boost)
      local cover = hits/total
      local score = cosine(qv,v)*cover*(1 + 0.2*path_hit)
      scored[#scored+1] = { idx=i, score=score }
    end
  end
  table.sort(scored, function(a,b) return a.score>b.score end)

  -- 5) return top-K snippets ---------------------------------------------
  local out = {}
  for i=1, math.min(cfg.topK, #scored) do
    out[#out+1] = texts[scored[i].idx]
  end
  return out
end

-- ── chat streamer (unchanged) ────────────────────────────────────────────
local function stream_chat(prompt, buf)
  local pending = ""
  api.nvim_buf_set_option(buf,'modifiable',true)
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
    on_stdout = function(_, data)
      for _, ln in ipairs(data or {}) do
        if not ln:match('^data: ') then goto continue end
        local js = ln:sub(7)
        if js=='[DONE]' then
          if #pending>0 then api.nvim_buf_set_lines(buf,-1,-1,false,{pending}) end
          api.nvim_buf_set_option(buf,'modifiable',false)
          return
        end
        local ok, obj = pcall(fn.json_decode, js)
        if ok and obj.choices then
          local delta = obj.choices[1].delta.content or ""
          pending = pending .. delta
          local flush = {}
          for line in pending:gmatch('(.-)\n') do
            flush[#flush+1] = line
          end
          if #flush>0 then
            api.nvim_buf_set_lines(buf, -1, -1, false, flush)
            pending = pending:match('.*\n(.*)') or ""
          end
        end
        ::continue::
      end
    end
  })
end

-- ── minimal UI layer (same as before) ────────────────────────────────────
local UI = { prompt_buf=nil, prompt_win=nil, resp_buf=nil, resp_win=nil }

local function close_ui()
  for _, w in ipairs{UI.resp_win, UI.prompt_win} do
    if w and api.nvim_win_is_valid(w) then api.nvim_win_close(w,true) end
  end
  for _, b in ipairs{UI.resp_buf, UI.prompt_buf} do
    if b and api.nvim_buf_is_valid(b) then api.nvim_buf_delete(b,{force=true}) end
  end
  UI = { prompt_buf=nil, prompt_win=nil, resp_buf=nil, resp_win=nil }
end

local function open_prompt()
  if UI.prompt_win and api.nvim_win_is_valid(UI.prompt_win) then
    api.nvim_set_current_win(UI.prompt_win); return
  end
  local w = math.floor(vim.o.columns*0.6)
  UI.prompt_buf = api.nvim_create_buf(false,true)
  api.nvim_buf_set_option(UI.prompt_buf,'buftype','prompt')
  fn.prompt_setprompt(UI.prompt_buf,'Ask ▶ ')
  UI.prompt_win = api.nvim_open_win(UI.prompt_buf,true,{
    relative='editor',
    row=math.floor(vim.o.lines/2-1),
    col=math.floor((vim.o.columns-w)/2),
    width=w, height=3,
    style='minimal', border='single',
  })
  api.nvim_command('startinsert')
end

local function open_resp()
  local w,h = math.floor(vim.o.columns*0.8), math.floor(vim.o.lines*0.65)
  UI.resp_buf = api.nvim_create_buf(false,true)
  api.nvim_buf_set_option(UI.resp_buf,'filetype','markdown')
  UI.resp_win = api.nvim_open_win(UI.resp_buf,true,{
    relative='editor',
    row=math.floor((vim.o.lines-h)/2),
    col=math.floor((vim.o.columns-w)/2),
    width=w, height=h,
    style='minimal',
    border={'▛','▀','▜','▐','▟','▄','▙','▌'},
  })
end

local function on_submit()
  local q = table.concat(api.nvim_buf_get_lines(UI.prompt_buf,0,-1,false),'\n')
            :gsub('^Ask ▶ ','')
  if q=='' then return close_ui() end
  close_ui(); open_resp()

  local ctx    = retrieve(q)
  local prompt = "Answer the question using only the context snippets below.\n\n"
  for i,c in ipairs(ctx) do
    prompt = prompt..("----- snippet %d -----\n%s\n\n"):format(i,c)
  end
  prompt = prompt.."Q: "..q.."\nA: "

  stream_chat(prompt, UI.resp_buf)
end

-- ── command wiring ───────────────────────────────────────────────────────
local M = {}
function M.open() open_prompt() end
function M.setup()
  api.nvim_create_user_command('ApolloAsk', M.open, {})
  api.nvim_create_autocmd('BufWinEnter', {
    callback = function(ev)
      if ev.buf == UI.prompt_buf then
        vim.keymap.set('i','<CR>', on_submit, { buffer = ev.buf })
      end
    end,
  })
end
return M
