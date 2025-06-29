-- lua/apollo/ragIndexer.lua  – FTS-only indexer, language-aware chunks
local sqlite  = require('sqlite')
local scan    = require('plenary.scandir')
local ftd     = require('plenary.filetype')
local api, fn = vim.api, vim.fn
local hash    = fn.sha256

-- ── configuration ────────────────────────────────────────────────────────
local cfg = {
  projectName   = fn.fnamemodify(fn.getcwd(), ':t'),
  embedEndpoint = 'http://127.0.0.1:8080/v1/embeddings',
  tableBase     = 'chunks',           -- chunks_fts / chunks_raw
  dim           = 256,                -- Gemma-3 embedding size (kept for raw)
}

-- ── DB helpers ────────────────────────────────────────────────────────────
local function db_path()
  return ('%s/%s_rag.sqlite'):format(fn.stdpath('data'), cfg.projectName)
end

local DB                                       -- cached handle
local function open_db()
  if DB and DB:isopen() then return DB end

  DB = sqlite { uri = db_path(), create = true, opts = { keep_open = true } }

  -- full-text table
  DB:execute(([[
    CREATE VIRTUAL TABLE IF NOT EXISTS %s_fts USING fts5(
      text, path UNINDEXED, lang UNINDEXED, library UNINDEXED,
      tokens UNINDEXED, content=''
    );
  ]]):format(cfg.tableBase))

  -- store raw vector blobs so you can migrate to VSS later
  DB:execute(([[
    CREATE TABLE IF NOT EXISTS %s_raw(
      rowid INTEGER PRIMARY KEY,
      vec   BLOB
    );
  ]]):format(cfg.tableBase))

  return DB
end

-- ── embedding utilities ───────────────────────────────────────────────────
local function system_json(cmd)
  local out = fn.system(cmd)
  if vim.v.shell_error ~= 0 then error(out) end
  return fn.json_decode(out)
end

local function embed(txt)
  local res = system_json({
    'curl','-s','-X','POST', cfg.embedEndpoint,
    '-H','Content-Type: application/json',
    '-d', fn.json_encode({
      model   = 'gemma3-embed',
      input   = { txt },
      pooling = 'mean',
    }),
  })
  if res.error then error(res.error.message) end
  return res.data[1].embedding
end

local function pack_vec(v)              -- little-endian f32 blob
  return string.pack('<' .. #v .. 'f', table.unpack(v))
end

local function n_lines(s)               -- quick line count
  return select(2, s:gsub('\n', '')) + 1
end

-- ── chunker ───────────────────────────────────────────────────────────────
local function split_chunks(lines, lang)
  local out, cur = {}, {}
  local push = function()
    if #cur > 0 then
      out[#out+1] = table.concat(cur, '\n')
      cur = {}
    end
  end

  local function is_boundary(l)
    if l:match('^%s*$') then return true end
    if lang == 'c' or lang == 'cpp' then
      return l:match('^%s*[%w_][%w_%*%s]-[%w_]%s*%(') or l:match('^%s*struct%s')
    elseif lang == 'lua' then
      return l:match('^%s*function%s')
    elseif lang == 'javascript' or lang == 'typescript' then
      return l:match('class%s') or l:match('function%s')
    end
  end

  for _, ln in ipairs(lines) do
    if #cur > 120 or is_boundary(ln) then push() end
    cur[#cur+1] = ln
  end
  push()
  return out
end

-- ── ingest helpers ────────────────────────────────────────────────────────
local function insert_chunk(db, rowid, chunk, meta)
  --------------------------------------------------------------------------
  -- 1. embed first (could throw → caller pcall-wrapped)
  --------------------------------------------------------------------------
  local vec = embed(chunk)

  --------------------------------------------------------------------------
  -- 2. derive token-count (≈ “words”)
  --------------------------------------------------------------------------
  local _, tok = chunk:gsub('%S+', '')      -- tok = #non-space runs

  --------------------------------------------------------------------------
  -- 3. FTS row  +  raw-vector row
  --------------------------------------------------------------------------
  db:eval(
    'INSERT INTO '..cfg.tableBase..'_fts ' ..
    '(rowid,text,path,lang,library,tokens) VALUES(?,?,?,?,?,?)',
    rowid, chunk, meta.path, meta.lang, meta.lib or '', tok
  )

  db:eval(
    'INSERT INTO '..cfg.tableBase..'_raw(rowid,vec) VALUES(?,?)',
    rowid, pack_vec(vec)
  )
end

local function embed_file(path, library)
  local lines = fn.readfile(path); if not lines[1] then return end
  local lang  = ftd.detect_from_extension(path) or ftd.detect(path,{}) or 'txt'
  local db    = open_db()

  local function ingest(chunk)
    local rowid = tonumber('0x'..hash(path..chunk):sub(1,15))  -- 53-bit safe
    if db:eval('SELECT 1 FROM '..cfg.tableBase..'_fts WHERE rowid=?', rowid)[1] then
      return                                       -- already indexed
    end

    local ok, err = pcall(insert_chunk, db, rowid, chunk, {
      path = path, lang = lang, lib = library,
    })
    if not ok and tostring(err):match('too large') and n_lines(chunk) > 8 then
      local parts = vim.split(chunk, '\n')
      local mid   = math.floor(#parts / 2)
      ingest(table.concat(parts, '\n', 1, mid))
      ingest(table.concat(parts, '\n', mid + 1))
    elseif not ok then
      vim.notify('[RAG] '..err, vim.log.levels.WARN)
    end
  end

  for _, c in ipairs(split_chunks(lines, lang)) do ingest(c) end
end

-- ── LSP-aware helpers & user commands (unchanged) ─────────────────────────
local function active_ft()
  local s = {}; for _,c in pairs(vim.lsp.get_active_clients()) do
    for _,ft in ipairs(c.config.filetypes or {}) do s[ft] = true end
  end; return s
end

local function embed_one_prompt()
  local fts = active_ft()
  if vim.tbl_isempty(fts) then
    vim.notify('[RAG] no LSP clients', vim.log.levels.WARN); return
  end
  local paths = scan.scan_dir(fn.getcwd(), { hidden=true, depth=8, respect_gitignore=true })
  local files = {}
  for _, p in ipairs(paths) do
    local ft = ftd.detect_from_extension(p) or ftd.detect(p,{})
    if ft and fts[ft] then files[#files+1] = p end
  end
  table.sort(files)
  vim.ui.select(files, { prompt = 'Pick file to embed' }, function(ch)
    if ch then embed_file(ch) end
  end)
end
api.nvim_create_user_command('ApolloRagEmbed', embed_one_prompt, {})

-- directory picker (UI logic untouched, calls embed_file) ------------------
local picker = { win=nil, buf=nil, dirs={}, mark={} }
local function refresh()
  local l = {}; for _,d in ipairs(picker.dirs) do
    l[#l+1] = (picker.mark[d] and '✓ ' or '  ') .. d
  end
  l[#l+1] = '-- <Enter> to start embedding --'
  api.nvim_buf_set_option(picker.buf,'modifiable',true)
  api.nvim_buf_set_lines(picker.buf,0,-1,false,l)
  api.nvim_buf_set_option(picker.buf,'modifiable',false)
end
local function toggle()
  local idx = fn.line('.'); local d = picker.dirs[idx]
  if d then picker.mark[d] = not picker.mark[d]; refresh() end
end
local function close()
  if picker.win and api.nvim_win_is_valid(picker.win) then api.nvim_win_close(picker.win,true) end
  if picker.buf and api.nvim_buf_is_valid(picker.buf) then api.nvim_buf_delete(picker.buf,{force=true}) end
  picker.win, picker.buf = nil, nil
end
local function commit()
  close()
  local want, fts = {}, active_ft()
  for d,m in pairs(picker.mark) do if m then want[#want+1] = d end end
  if #want == 0 then return end
  for _, dir in ipairs(want) do
    vim.notify('[RAG] indexing '..dir)
    for _, p in ipairs(scan.scan_dir(dir, { hidden=true, depth=8, respect_gitignore=true })) do
      local ft = ftd.detect_from_extension(p) or ftd.detect(p,{})
      if ft and fts[ft] then embed_file(p, fn.fnamemodify(dir, ':t')) end
    end
  end
  vim.notify('[RAG] done ✓')
end
api.nvim_create_user_command('ApolloRagEmbedDirs', function()
  picker.dirs = scan.scan_dir(fn.getcwd(), { only_dirs=true, depth=3, respect_gitignore=true })
  table.sort(picker.dirs); picker.mark = {}
  picker.buf = api.nvim_create_buf(false,true); refresh()
  local h = math.min(#picker.dirs, math.floor(vim.o.lines*0.6))
  local w = math.floor(vim.o.columns*0.45)
  picker.win = api.nvim_open_win(picker.buf,true,{
    relative='editor', row=(vim.o.lines-h)/2, col=(vim.o.columns-w)/2,
    width=w,height=h, style='minimal', border='rounded'
  })
  api.nvim_buf_set_option(picker.buf,'filetype','rag_picker')
  vim.keymap.set('n','e',toggle,{buffer=picker.buf})
  vim.keymap.set('n','<CR>',commit,{buffer=picker.buf})
  vim.keymap.set('n','q',close,{buffer=picker.buf})
end,{})

-- expose helpers for retriever
local M = {}
function M.open_db() return open_db() end
function M.embed_file(p,lib) embed_file(p,lib) end
return M
