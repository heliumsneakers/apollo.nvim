-- lua/apollo/ragIndexer.lua  – stable, header-annotated chunks
local sqlite  = require 'sqlite'
local scan    = require 'plenary.scandir'
local ftd     = require 'plenary.filetype'
local api,fn  = vim.api, vim.fn
local hash    = fn.sha256

-- ── configuration ────────────────────────────────────────────────────────
local cfg = {
  projectName   = fn.fnamemodify(fn.getcwd(), ':t'),
  embedEndpoint = 'http://127.0.0.1:8080/v1/embeddings',
  tableName     = 'lsp_chunks',
}

local function db_path()
  return ('%s/%s_rag.sqlite'):format(fn.stdpath('data'), cfg.projectName)
end

-- ── lightweight helpers --------------------------------------------------
local function system_json(cmd)
  local raw = fn.system(cmd)
  if vim.v.shell_error ~= 0 then error(raw) end
  return fn.json_decode(raw)
end

local function embed(txt)
  local res = system_json{
    'curl','-s','-X','POST',cfg.embedEndpoint,
    '-H','Content-Type: application/json',
    '-d', fn.json_encode{ model='gemma3-embed', input={txt}, pooling='mean' }
  }
  if res.error then error(res.error.message) end
  return res.data[1].embedding
end

local function pack_vec(v)          -- little-endian float32 binary blob
  return string.pack('<'..#v..'f', table.unpack(v))
end

-- ── open DB once per session --------------------------------------------
local DB
local function open_db()
  if DB and DB:isopen() then return DB end
  DB = sqlite{ uri=db_path(), create=true, opts={keep_open=true} }
  DB:execute(([[
    CREATE TABLE IF NOT EXISTS %s(
      hash    TEXT PRIMARY KEY,
      file    TEXT,
      text    TEXT,
      tokens  INTEGER,
      vec     BLOB
    );
  ]]):format(cfg.tableName))
  return DB
end

-- ── tiny chunker (120-line blocks, heuristics per language) --------------
local function split_chunks(lines, lang)
  local out, cur = {}, {}
  local push = function() if #cur>0 then
      out[#out+1]=table.concat(cur,'\n'); cur={} end end

  local function is_boundary(l)
    if l:match('^%s*$') then return true end
    if lang=='c' or lang=='cpp' then
      return l:match('^%s*[%w_][%w_%*%s]-[%w_]%s*%(') or l:match('^%s*struct%s')
    elseif lang=='lua' then
      return l:match('^%s*function%s')
    elseif lang=='javascript' or lang=='typescript' then
      return l:match('class%s') or l:match('function%s')
    end
  end

  for _,ln in ipairs(lines) do
    if #cur>120 or is_boundary(ln) then push() end
    cur[#cur+1]=ln
  end
  push()
  return out
end

-- ── ingestion ------------------------------------------------------------
local function already(db,key)
  local r=db:eval('SELECT 1 FROM '..cfg.tableName..' WHERE hash=? LIMIT 1',key)
  return type(r)=='table' and r[1]
end

local function insert_snippet(db,rowid,snippet,file)
  local vec = embed(snippet)
  local _,tok = snippet:gsub('%S+','')
  db:insert(cfg.tableName,{
    hash   = rowid,
    file   = file,
    text   = snippet,
    tokens = tok,
    vec    = pack_vec(vec),
  })
end

local function embed_file(path)
  local lines = fn.readfile(path)
  if not lines[1] then
    vim.notify('[RAG] cannot read '..path, vim.log.levels.WARN); return
  end
  local lang = ftd.detect_from_extension(path) or ftd.detect(path,{}) or 'txt'
  local db   = open_db()

  local function ingest(start_ln,stop_ln)
    local body = table.concat(lines,'\n',start_ln,stop_ln)
    local snip = ('/// %s:%d-%d\n%s'):format(path,start_ln,stop_ln,body)
    local key  = hash(snip)
    if already(db,key) then return end

    local ok,err = pcall(insert_snippet,db,key,snip,path)
    if ok then return end
    if tostring(err):match('too large') and (stop_ln-start_ln)>8 then
      local mid = math.floor((start_ln+stop_ln)/2)
      ingest(start_ln,mid); ingest(mid+1,stop_ln)
    else
      vim.notify('[RAG] '..err,vim.log.levels.WARN)
    end
  end

  for _,chunk in ipairs(split_chunks(lines,lang)) do
    local first = 1
    local cnt   = vim.tbl_count(vim.split(chunk,'\n'))
    ingest(first,first+cnt-1)
  end
  vim.notify('[RAG] finished embedding '..path)
end

-- ── misc helpers / commands (mostly unchanged) ---------------------------
local function active_ft()
  local s={}; for _,c in pairs(vim.lsp.get_active_clients()) do
    for _,ft in ipairs(c.config.filetypes or {}) do s[ft]=true end end
  return s
end

local function embed_one_prompt()
  local want=active_ft()
  if vim.tbl_isempty(want) then
    vim.notify('[RAG] no LSP clients',vim.log.levels.WARN);return end
  local files={}
  for _,p in ipairs(scan.scan_dir(fn.getcwd(),{hidden=true,depth=8,respect_gitignore=true})) do
    local ft=ftd.detect_from_extension(p) or ftd.detect(p,{})
    if ft and want[ft] then files[#files+1]=p end
  end
  table.sort(files)
  vim.ui.select(files,{prompt='Pick file to embed'},function(ch) if ch then embed_file(ch) end end)
end
api.nvim_create_user_command('ApolloRagEmbed',embed_one_prompt,{})

-- directory-picker ui from previous versions ------------------------------
-- (unchanged except it calls embed_file) ----------------------------------
local picker={win=nil,buf=nil,dirs={},mark={}}
local function refresh()
  local l={}; for _,d in ipairs(picker.dirs) do
    l[#l+1]=(picker.mark[d]and'✓ 'or'  ')..d end
  l[#l+1]='-- <Enter> to start embedding --'
  api.nvim_buf_set_option(picker.buf,'modifiable',true)
  api.nvim_buf_set_lines(picker.buf,0,-1,false,l)
  api.nvim_buf_set_option(picker.buf,'modifiable',false)
end
local function toggle() local i=fn.line('.'); local d=picker.dirs[i]
  if d then picker.mark[d]=not picker.mark[d];refresh() end end
local function close()
  if picker.win and api.nvim_win_is_valid(picker.win) then api.nvim_win_close(picker.win,true) end
  if picker.buf and api.nvim_buf_is_valid(picker.buf) then api.nvim_buf_delete(picker.buf,{force=true}) end
  picker.win,picker.buf=nil,nil
end
local function commit()
  close()
  local want_ft=active_ft(); local dirs={}
  for d,m in pairs(picker.mark) do if m then dirs[#dirs+1]=d end end
  for _,dir in ipairs(dirs) do
    vim.notify('[RAG] indexing '..dir)
    for _,p in ipairs(scan.scan_dir(dir,{hidden=true,depth=8,respect_gitignore=true})) do
      local ft=ftd.detect_from_extension(p) or ftd.detect(p,{})
      if ft and want_ft[ft] then embed_file(p, fn.fnamemodify(dir,':t')) end
    end
  end
  vim.notify('[RAG] done ✓')
end
api.nvim_create_user_command('ApolloRagEmbedDirs',function()
  picker.dirs=scan.scan_dir(fn.getcwd(),{only_dirs=true,depth=3,respect_gitignore=true})
  table.sort(picker.dirs); picker.mark={}
  picker.buf=api.nvim_create_buf(false,true); refresh()
  local h=math.min(#picker.dirs,math.floor(vim.o.lines*0.6))
  local w=math.floor(vim.o.columns*0.45)
  picker.win=api.nvim_open_win(picker.buf,true,{
    relative='editor',row=(vim.o.lines-h)/2,col=(vim.o.columns-w)/2,
    width=w,height=h,style='minimal',border='rounded'})
  api.nvim_buf_set_option(picker.buf,'filetype','rag_picker')
  vim.keymap.set('n','e',toggle,{buffer=picker.buf})
  vim.keymap.set('n','<CR>',commit,{buffer=picker.buf})
  vim.keymap.set('n','q',close,{buffer=picker.buf})
end,{})

return M  -- expose if you want; safe to delete otherwise
