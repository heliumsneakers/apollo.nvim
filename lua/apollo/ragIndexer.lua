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

local function system_json(cmd_tbl)
  local raw = vim.fn.system(cmd_tbl)
  if vim.v.shell_error ~= 0 then
    error('curl failed: '..raw)
  end
  return vim.fn.json_decode(raw)
end

-- one-shot embed call -------------------------------------------------------
local function embed(text)
  local payload = {
    model   = 'gemma3-embed',
    input   = { text },
    pooling = 'mean',           -- required for llama-server
    -- encoding_format = 'float', -- remove: let server decide
  }

  local res = system_json({
    'curl','-s','-X','POST', cfg.embedEndpoint,
    '-H','Content-Type: application/json',
    '-d', vim.fn.json_encode(payload),
  })

  -- If Server sent an error block, surface it
  if res.error then
    error(('embedding error %s: %s')
          :format(res.error.code or '', res.error.message or 'unknown'))
  end

  local vec = res
           and res.data and res.data[1]
           and res.data[1].embedding

  assert(vec and #vec > 0,
         ('empty embedding (response keys: %s)')
         :format(table.concat(vim.tbl_keys(res), ', ')))
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

local CHUNK_SIZE = 8 * 1024        -- 8 KB per request (adjust if needed)

-- ── embed one file (chunk-aware) ───────────────────────────────────────────
local function embed_file(path)
  --------------------------------------------------------------------------
  -- read file -------------------------------------------------------------
  --------------------------------------------------------------------------
  local lines = vim.fn.readfile(path)
  if not lines[1] then
    vim.notify('[RAG] cannot read '..path, vim.log.levels.WARN)
    return
  end

  --------------------------------------------------------------------------
  -- slice into ~8 KB chunks on line boundaries ----------------------------
  --------------------------------------------------------------------------
  local chunks = {}
  local acc, bytes, from = {}, 0, 1
  for i, ln in ipairs(lines) do
    bytes = bytes + #ln + 1          -- +1 for newline
    acc[#acc+1] = ln
    if bytes >= CHUNK_SIZE then
      chunks[#chunks+1] = { start=from, stop=i,
                            txt=table.concat(acc, '\n') }
      acc, bytes, from = {}, 0, i + 1
    end
  end
  if #acc > 0 then
    chunks[#chunks+1] = { start=from, stop=#lines,
                          txt=table.concat(acc, '\n') }
  end

  if vim.tbl_isempty(chunks) then return end

  --------------------------------------------------------------------------
  -- open DB once ----------------------------------------------------------
  --------------------------------------------------------------------------
  local db = open_db()

  --------------------------------------------------------------------------
  -- iterate chunks --------------------------------------------------------
  --------------------------------------------------------------------------
  for _, ck in ipairs(chunks) do
    local key = hash(path..ck.start..ck.stop..ck.txt)

    -- skip if already there
    local row = db:eval('SELECT 1 FROM '..cfg.tableName..' WHERE hash = ?', key)
    if type(row) == 'table' and row[1] then goto continue end

    -- embed
    local ok, vec_or_err = pcall(embed, ck.txt)
    if not ok then
      vim.notify('[RAG] embed failed: '..vec_or_err, vim.log.levels.ERROR)
      goto continue
    end

    -- insert
    db:insert(cfg.tableName, {
      hash   = key,
      file   = path,
      symbol = ('%s:%d-%d'):format(path, ck.start, ck.stop),
      kind   = 0,
      text   = ck.txt,
      vec    = f32bin(vec_or_err),
    })
    ::continue::
  end

  vim.notify('[RAG] finished embedding '..path)
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
