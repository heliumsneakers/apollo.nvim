-- lua/apollo/impl-agent.lua  –  RAG Q-and-A assistant (json-vec) with SQL prefilter
local M = {}

local api, fn = vim.api, vim.fn
local sqlite  = require('sqlite')

local UI  = { resp_buf=nil, resp_win=nil, input_buf=nil, input_win=nil }
local H   = { history_lines = {}, pending = '' }   -- per-session state

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

-- THIS is the meat of semantic search. Maybe find a way to SIMD this with a kernel written in C. 
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

local function _flatten(buf)
  if not api.nvim_buf_is_valid(buf) then return end
  local l = api.nvim_buf_get_lines(buf, 0, -1, false)
  if #l > 1 then
    local j = table.concat(l, ' '):gsub('%s+$','')
    api.nvim_buf_set_lines(buf, 0, -1, false, { j })
    api.nvim_win_set_cursor(0, { 1, #j })
  end
end

local function _center(lines, total_w)
  local max = 0
  for _,ln in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(ln:gsub('%s+$',''))
    if w>max then max=w end
  end
  local pad  = math.max(math.floor((total_w-max)/2),0)
  local pref = (' '):rep(pad)
  local out  = {}
  for _,ln in ipairs(lines) do out[#out+1] = pref..ln end
  return out
end

local function _splash()
  return {
    "                                                    ",
    "  █████╗ ██████╗  ██████╗ ██╗     ██╗      ██████╗  ",
    " ██╔══██╗██╔══██╗██╔═══██╗██║     ██║     ██╔═══██╗ ",
    " ███████║██████╔╝██║   ██║██║     ██║     ██║   ██║ ",
    " ██╔══██║██╔═══╝ ██║   ██║██║     ██║     ██║   ██║ ",
    " ██║  ██║██║     ╚██████╔╝███████╗███████╗╚██████╔╝ ",
    " ╚═╝  ╚╝ ╚═╝      ╚═════╝ ╚══════╝╚══════╝ ╚═════╝  ",
    "                                                    ",
  }
end

local function _close(reset_history)
  for _,w in pairs{UI.resp_win, UI.input_win} do
    if w and api.nvim_win_is_valid(w) then api.nvim_win_close(w,true) end
  end
  for _,b in pairs{UI.resp_buf, UI.input_buf} do
    if b and api.nvim_buf_is_valid(b) then api.nvim_buf_delete(b,{force=true}) end
  end
  UI = { resp_buf=nil, resp_win=nil, input_buf=nil, input_win=nil }
  if reset_history then H.history_lines = {} end
end

local function _stream(prompt)
  H.pending = ''
  api.nvim_buf_set_option(UI.resp_buf,'modifiable',true)
  fn.jobstart({
    'curl','-s','-N','-X','POST',cfg.chatEndpoint,
    '-H','Content-Type: application/json',
    '-d', fn.json_encode{
      model='gemma3-4b-it',
      stream=true,
      messages={{role='user',content=prompt}},
    }
  },{
    stdout_buffered=false,
    on_stdout=function(_,d)
      for _,raw in ipairs(d or {}) do
        if not raw:match('^data: ') then goto continue end
        local js = raw:sub(7)
        if js=='[DONE]' then
          if #H.pending>0 then
            api.nvim_buf_set_lines(UI.resp_buf,-1,-1,false,{H.pending})
            vim.list_extend(H.history_lines,{H.pending})
          end
          api.nvim_buf_set_option(UI.resp_buf,'modifiable',false); return
        end
        local ok,chunk = pcall(fn.json_decode,js)
        if ok and chunk.choices then
          local c = chunk.choices[1].delta.content
          if c then
            H.pending = H.pending .. c
            local flush={}
            for l in H.pending:gmatch('(.-)\n') do flush[#flush+1]=l end
            if #flush>0 then
              api.nvim_buf_set_lines(UI.resp_buf,-1,-1,false,flush)
              vim.list_extend(H.history_lines,flush)
              H.pending = H.pending:match('.*\n(.*)') or ''
            end
          end
        end
        ::continue::
      end
    end
  })
end

-- ── minimal UI layer (same as before) ────────────────────────────────────
local function _open_ui()
  local tot    = vim.o.lines
  local resp_h = math.floor(tot*0.65)
  local in_h   = tot - resp_h - 10
  local width  = math.floor(vim.o.columns*0.8)
  local col    = math.floor((vim.o.columns-width)/2)

  -- response buffer / window
  if not (UI.resp_buf and api.nvim_buf_is_valid(UI.resp_buf)) then
    UI.resp_buf = api.nvim_create_buf(false,true)
    api.nvim_buf_set_option(UI.resp_buf,'filetype','markdown')
  end
  UI.resp_win = api.nvim_open_win(UI.resp_buf,true,{
    relative='editor',row=1,col=col,width=width,height=resp_h,
    style='minimal',border={'▛','▀','▜','▐','▟','▄','▙','▌'},
  })
  api.nvim_win_set_option(UI.resp_win,'wrap',true)

  api.nvim_buf_set_option(UI.resp_buf,'modifiable',true)
  local init = (#H.history_lines==0) and _center(_splash(),width)
                                   or  H.history_lines
  api.nvim_buf_set_lines(UI.resp_buf,0,-1,false,init)
  api.nvim_buf_set_option(UI.resp_buf,'modifiable',false)

  -- prompt buffer / window
  if not (UI.input_buf and api.nvim_buf_is_valid(UI.input_buf)) then
    UI.input_buf = api.nvim_create_buf(false,false)
    api.nvim_buf_set_option(UI.input_buf,'buftype','prompt')
    api.nvim_buf_set_option(UI.input_buf,'bufhidden','hide')
  end
  if #H.history_lines==0 then
    api.nvim_buf_set_lines(UI.input_buf,0,-1,false,{})
  end
  UI.input_win = api.nvim_open_win(UI.input_buf,true,{
    relative='editor',row=resp_h+2,col=col,
    width=width,height=in_h,
    style='minimal',border={'▛','▀','▜','▐','▟','▄','▙','▌'},
  })
  vim.fn.prompt_setprompt(UI.input_buf,'→ ')
  api.nvim_command('startinsert')

  api.nvim_buf_set_keymap(UI.input_buf,'i','<CR>',
    [[<Cmd>lua require('apollo.implAgent')._send()<CR>]],
    {noremap=true,silent=true})

  api.nvim_create_autocmd({'TextChangedI','TextChangedP'},{
    buffer=UI.input_buf, callback=function() _flatten(UI.input_buf) end,
  })
end

function M._send()
  local raw = api.nvim_buf_get_lines(UI.input_buf,0,-1,false)
  local query = table.concat(raw,' '):gsub('^→ ','')
  api.nvim_buf_set_lines(UI.input_buf,0,-1,false,{})
  if query=='' then return end

  -- build RAG prompt
  local ctx = retrieve(query)
  local prompt = "Answer the question using only the context snippets below.\n\n"
  for i,c in ipairs(ctx) do
    prompt = prompt..("----- snippet %d -----\n%s\n\n"):format(i,c)
  end
  prompt = prompt.."Q: "..query.."\nA: "

  _stream(prompt)
end

-- ── command wiring ───────────────────────────────────────────────────────
function M.open() _open_ui() end
function M.quit() _close(true) end
function M.setup()
  api.nvim_create_user_command('ApolloAsk', M.open, {})
  api.nvim_create_user_command('ApolloAskQuit', M.quit, {})
end
return M
