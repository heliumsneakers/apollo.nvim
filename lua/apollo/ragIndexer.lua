-- lua/apollo/ragIndexer.lua  (minimal single-file embed w/ plenary.scandir)
local sqlite = require('sqlite')
local scan   = require('plenary.scandir')
local hash   = vim.fn.sha256
local M      = {}

-- ── configuration ──────────────────────────────────────────────────────────
local cfg = {
  projectName   = vim.fn.fnamemodify(vim.fn.getcwd(), ':t'),
  embedEndpoint = 'http://127.0.0.1:8080/v1/embeddings',
  tableName     = 'lsp_chunks',
}

local function db_path()
  return string.format('%s/%s_rag.sqlite',
                       vim.fn.stdpath('data'), cfg.projectName)
end

-- ── one-shot embed call ────────────────────────────────────────────────────
local function embed(text)
  local payload = {
    model           = 'gemma3-embed',
    input           = { text },
    pooling         = 'mean',
    encoding_format = 'float',
  }
  local ok, res = pcall(vim.fn.systemjson, {
    'curl','-s','-X','POST', cfg.embedEndpoint,
    '-H','Content-Type: application/json',
    '-d', vim.fn.json_encode(payload),
  })
  if not ok then error('curl failed: '..res) end
  local e = res and res.data and res.data[1] and res.data[1].embedding
  assert(e and #e > 0, 'empty embedding')
  return e
end

local function f32bin(vec)
  local out = {}
  for _,v in ipairs(vec) do out[#out+1] = string.pack('<f', v) end
  return table.concat(out)
end

-- ── open (and auto-create) the DB ──────────────────────────────────────────
local function open_db()
  local db = sqlite { uri = db_path(), create = true, opts = { keep_open = true } }
  db:execute(string.format([[
    CREATE TABLE IF NOT EXISTS %s (
      hash   TEXT PRIMARY KEY,
      file   TEXT,
      symbol TEXT,
      kind   INT,
      text   TEXT,
      vec    BLOB
    );]], cfg.tableName))
  return db
end

-- ── embed a single file ────────────────────────────────────────────────────
local function embed_file(path)
  local lines = vim.fn.readfile(path)
  if not lines[1] then
    vim.notify('[RAG] cannot read '..path, vim.log.levels.WARN); return
  end
  local text = table.concat(lines, '\n')
  local h    = hash(text)

  local db = open_db()
  if db:eval('SELECT 1 FROM '..cfg.tableName..' WHERE hash = ?', h)[1] then
    vim.notify('[RAG] already indexed '..path, vim.log.levels.INFO)
    return
  end

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

-- ── user-facing command ────────────────────────────────────────────────────
vim.api.nvim_create_user_command('ApolloRagEmbed', function()
  -------------------------------------------------------------
  -- Gather files with plenary.scandir (no external `rg` need) -
  -------------------------------------------------------------
  local files = scan.scan_dir(vim.fn.getcwd(), {
    hidden            = true,  -- include dot-files
    add_dirs          = false,
    depth             = 8,     -- stop after 8 directory levels
    respect_gitignore = true,  -- skip paths ignored by .gitignore
  })

  table.sort(files)
  if vim.tbl_isempty(files) then
    vim.notify('[RAG] no files found in workspace', vim.log.levels.WARN)
    return
  end

  vim.ui.select(files, { prompt = 'Pick a file to embed' }, function(choice)
    if choice then embed_file(choice) end
  end)
end, {})

return M   -- no setup() needed for this minimal example
