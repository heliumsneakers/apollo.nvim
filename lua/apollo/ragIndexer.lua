-- lua/apollo/ragIndexer.lua  — minimal single-file embed
local sqlite = require('sqlite')
local scan   = require('plenary.scandir')
local ftd    = require('plenary.filetype')
local hash   = vim.fn.sha256
local M      = {}

-- ── config ────────────────────────────────────────────────────────────────
local cfg = {
  projectName   = vim.fn.fnamemodify(vim.fn.getcwd(), ':t'),
  embedEndpoint = 'http://127.0.0.1:8080/v1/embeddings',
  tableName     = 'lsp_chunks',
}

local function db_path()
  return ('%s/%s_rag.sqlite'):format(vim.fn.stdpath('data'), cfg.projectName)
end

-- ── 1-shot embedding call ─────────────────────────────────────────────────
local function embed(text)
  local payload = {
    model = 'gemma3-embed',
    input = { text },
    pooling = 'mean',
    encoding_format = 'float',
  }
  local ok, res = pcall(vim.fn.systemjson, {
    'curl','-s','-X','POST', cfg.embedEndpoint,
    '-H','Content-Type: application/json',
    '-d', vim.fn.json_encode(payload),
  })
  if not ok then error('curl failed: '..res) end
  local vec = res and res.data and res.data[1] and res.data[1].embedding
  assert(vec and #vec > 0, 'empty embedding')
  return vec
end

local function f32bin(tbl)
  local out = {}; for _,v in ipairs(tbl) do out[#out+1] = string.pack('<f',v) end
  return table.concat(out)
end

-- ── DB helpers ────────────────────────────────────────────────────────────
local function open_db()
  local db = sqlite{ uri=db_path(), create=true, opts={ keep_open=true } }
  db:execute(([[
    CREATE TABLE IF NOT EXISTS %s(
      hash TEXT PRIMARY KEY, file TEXT, symbol TEXT, kind INT,
      text TEXT, vec BLOB);]]):format(cfg.tableName))
  return db
end

-- ── embed one file ────────────────────────────────────────────────────────
local function embed_file(path)
  local lines = vim.fn.readfile(path)
  if not lines[1] then
    vim.notify('[RAG] cannot read '..path, vim.log.levels.WARN); return
  end
  local text = table.concat(lines, '\n')
  local h    = hash(text)

  ----------------------------------------------------------------
  -- FIX: create DB first, then query it -------------------------
  ----------------------------------------------------------------
  local db   = open_db()
  local row  = db:eval('SELECT 1 FROM '..cfg.tableName..' WHERE hash = ?', h)
  if type(row) == 'table' and row[1] then
    vim.notify('[RAG] already indexed '..path, vim.log.levels.INFO)
    return
  end
  ----------------------------------------------------------------

  vim.notify('[RAG] embedding '..path)
  local vec = f32bin(embed(text))
  db:insert(cfg.tableName, {
    hash   = h,
    file   = path,
    symbol = path,
    kind   = 0,
    text   = text,
    vec    = vec,
  })
  vim.notify('[RAG] inserted '..path)
end

-- ── collect active-LSP filetypes ──────────────────────────────────────────
local function active_ft_set()
  local set = {}
  for _,c in pairs(vim.lsp.get_active_clients()) do
    for _,ft in ipairs(c.config.filetypes or {}) do set[ft]=true end
  end
  return set
end

-- ── user command :ApolloRagEmbed ──────────────────────────────────────────
vim.api.nvim_create_user_command('ApolloRagEmbed', function()
  local want_ft = active_ft_set()
  if vim.tbl_isempty(want_ft) then
    vim.notify('[RAG] no LSP clients attached', vim.log.levels.WARN); return
  end

  -- scan workspace
  local paths = scan.scan_dir(vim.fn.getcwd(), {
    hidden=true, add_dirs=false, depth=8, respect_gitignore=true,
  })

  -- keep only files whose detected filetype matches active LSPs
  local files = {}
  for _,p in ipairs(paths) do
    local ft = ftd.detect_from_extension(p) or ftd.detect(p, {})
    if ft and want_ft[ft] then files[#files+1]=p end
  end

  if vim.tbl_isempty(files) then
    vim.notify('[RAG] no source files match active LSP types', vim.log.levels.INFO)
    return
  end
  table.sort(files)

  vim.ui.select(files,{prompt='Pick a file to embed'}, function(choice)
    if choice then embed_file(choice) end
  end)
end,{})

return M
