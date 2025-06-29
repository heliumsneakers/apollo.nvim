-- lua/apollo/impl-agent.lua – RAG QA assistant (fts + vss schema aware)
local api, fn = vim.api, vim.fn
local sqlite  = require 'sqlite'

-- ── config ────────────────────────────────────────────────────────────────
local cfg = {
  projectName   = fn.fnamemodify(fn.getcwd(), ':t'),
  chatEndpoint  = 'http://127.0.0.1:8080/v1/chat/completions',
  embedEndpoint = 'http://127.0.0.1:8080/v1/embeddings',
  tableBase     = 'chunks',        -- chunks_raw / chunks_fts
  dim           = 256,             -- must match indexer
  topK          = 6,
}

local function db_path()
  return ('%s/%s_rag.sqlite'):format(fn.stdpath('data'), cfg.projectName)
end

-- ── emb helper (only for query vector) ────────────────────────────────────
local function system_json(cmd)
  local out = fn.system(cmd)
  if vim.v.shell_error ~= 0 then error(out) end
  return fn.json_decode(out)
end
local function embed(txt)
  local res = system_json{
    'curl','-s','-X','POST',cfg.embedEndpoint,
    '-H','Content-Type: application/json',
    '-d', fn.json_encode{ model='gemma3-embed',input={txt},pooling='mean'}
  }
  if res.error then error(res.error.message) end
  return res.data[1].embedding
end

-- ── cosine ---------------------------------------------------------------
local function cosine(a,b)
  local dot,na,nb=0,0,0
  for i=1,#a do
    dot=dot+a[i]*b[i]; na=na+a[i]^2; nb=nb+b[i]^2
  end
  return dot/(math.sqrt(na)*math.sqrt(nb)+1e-8)
end

-- ── memoised corpus load --------------------------------------------------
local VEC, TXT, META
local function unpack_vec(blob)
  local t,off={},1
  for i=1,cfg.dim do
    t[i],off = string.unpack('<f', blob, off)
  end
  return t
end

local function load_corpus()
  if VEC then return VEC,TXT,META end
  local db = sqlite{ uri=db_path(), create=false, opts={keep_open=true}}
  local rows = db:eval([[
      SELECT raw.rowid AS id,
             fts.text     AS txt,
             raw.vec      AS vec,
             fts.path     AS path,
             fts.library  AS lib
        FROM ]]..cfg.tableBase..[[_raw  AS raw
   INNER JOIN ]]..cfg.tableBase..[[_fts  AS fts
          ON fts.rowid = raw.rowid
  ]]) or {}

  VEC, TXT, META = {}, {}, {}
  for _,r in ipairs(rows) do
    VEC[#VEC+1]  = unpack_vec(r.vec)
    TXT[#TXT+1]  = r.txt
    META[#META+1]= { path=r.path or '', lib=r.lib or '' }
  end
  return VEC, TXT, META
end

-- ── retrieval -------------------------------------------------------------
local function retrieve(q)
  local qkw, total_kw = {},0
  for w in q:lower():gmatch('%w+') do
    if #w>3 then
      if not qkw[w] then total_kw=total_kw+1; qkw[w]=true end
    end
  end
  if total_kw==0 then return {} end

  local qvec           = embed(q)
  local vecs, texts, meta = load_corpus()
  if #vecs==0 then return {} end

  local scored={}
  for i,vec in ipairs(vecs) do
    local txtL = texts[i]:lower()
    local hits = 0
    for kw in pairs(qkw) do if txtL:find(kw,1,true) then hits=hits+1 end end
    if hits < math.ceil(total_kw/2) then goto continue end

    local bonus=0
    for kw in pairs(qkw) do
      if meta[i].path:find(kw,1,true) then bonus=bonus+0.25; break end
    end
    for kw in pairs(qkw) do
      if meta[i].lib:find(kw,1,true) then bonus=bonus+0.15; break end
    end

    local score = cosine(qvec,vec)*(hits/total_kw)*(1.0+bonus)
    scored[#scored+1]={idx=i,score=score}
    ::continue::
  end
  table.sort(scored,function(a,b) return a.score>b.score end)

  local out={}
  for i=1,math.min(cfg.topK,#scored) do
    out[#out+1]=texts[scored[i].idx]
  end
  return out
end

-- ── streaming chat --------------------------------------------------------
local function stream_chat(prompt, out_buf)
  local pend=''
  api.nvim_buf_set_option(out_buf,'modifiable',true)

  fn.jobstart({
    'curl','-s','-N','-X','POST',cfg.chatEndpoint,
    '-H','Content-Type: application/json',
    '-d', fn.json_encode{
      model='gemma3-4b-it',stream=true,
      messages={{role='user',content=prompt}}
    }},{
    stdout_buffered=false,
    on_stdout=function(_,data)
      for _,ln in ipairs(data or {}) do
        if ln:sub(1,6)~='data: ' then goto cont end
        local js=ln:sub(7)
        if js=='[DONE]' then
          if #pend>0 then api.nvim_buf_set_lines(out_buf,-1,-1,false,{pend}) end
          api.nvim_buf_set_option(out_buf,'modifiable',false); return
        end
        local ok,obj=pcall(fn.json_decode,js)
        if ok and obj.choices then
          local d=obj.choices[1].delta.content
          if d then
            pend=pend..d
            local flush={}
            for line in pend:gmatch('(.-)\n') do flush[#flush+1]=line end
            if #flush>0 then
              api.nvim_buf_set_lines(out_buf,-1,-1,false,flush)
              pend=pend:match('.*\n(.*)') or ''
            end
          end
        end
        ::cont::
      end
    end})
end

-- ── tiny UI (prompt → result) --------------------------------------------
local S={pbuf=nil,pwin=nil,rbuf=nil,rwin=nil}
local function close_all()
  for _,w in ipairs{S.pwin,S.rwin} do if w and api.nvim_win_is_valid(w) then api.nvim_win_close(w,true) end end
  for _,b in ipairs{S.pbuf,S.rbuf} do if b and api.nvim_buf_is_valid(b) then api.nvim_buf_delete(b,{force=true}) end end
  S={pbuf=nil,pwin=nil,rbuf=nil,rwin=nil}
end
local function open_prompt()
  local w=math.floor(vim.o.columns*0.6)
  local row,col=math.floor(vim.o.lines/2-1),math.floor((vim.o.columns-w)/2)
  S.pbuf=api.nvim_create_buf(false,true)
  api.nvim_buf_set_option(S.pbuf,'buftype','prompt')
  fn.prompt_setprompt(S.pbuf,'Ask ▶ ')
  S.pwin=api.nvim_open_win(S.pbuf,true,{relative='editor',row=row,col=col,width=w,height=3,style='minimal',border='single'})
  api.nvim_command('startinsert')
  vim.keymap.set('i','<CR>',function()
    local q=table.concat(api.nvim_buf_get_lines(S.pbuf,0,-1,false),'\n'):gsub('^Ask ▶ ','')
    if q=='' then close_all();return end
    close_all();                       -- hide prompt
    local rw=math.floor(vim.o.columns*0.8)
    local rh=math.floor(vim.o.lines*0.65)
    S.rbuf=api.nvim_create_buf(false,true)
    api.nvim_buf_set_option(S.rbuf,'filetype','markdown')
    S.rwin=api.nvim_open_win(S.rbuf,true,{relative='editor',
      row=(vim.o.lines-rh)/2,col=(vim.o.columns-rw)/2,width=rw,height=rh,
      style='minimal',border={'▛','▀','▜','▐','▟','▄','▙','▌'}})

    local ctx=retrieve(q)
    if #ctx==0 then
      api.nvim_buf_set_lines(S.rbuf,0,-1,false,{'⚠️  No relevant context in RAG DB.'})
      return
    end
    local prompt="Use the following API/library snippets to answer concisely:\n\n"
    for i,c in ipairs(ctx) do prompt=prompt..('--- snippet %d ---\n%s\n\n'):format(i,c) end
    prompt=prompt.."Q: "..q.."\nA:"
    stream_chat(prompt,S.rbuf)
  end,{buffer=S.pbuf})
end

-- ── public ----------------------------------------------------------------
local M={}
function M.open() open_prompt() end
function M.setup()
  api.nvim_create_user_command('ApolloAsk',function() M.open() end,{})
end
return M
