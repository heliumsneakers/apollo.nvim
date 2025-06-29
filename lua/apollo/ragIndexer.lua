-- lua/apollo/ragIndexer.lua  — minimal single-file embed with JSON vectors
local sqlite = require('sqlite')
local scan   = require('plenary.scandir')
local ftd    = require('plenary.filetype')
local fn     = vim.fn
local api    = vim.api

-- ── config ────────────────────────────────────────────────────────────────
local cfg = {
  projectName   = fn.fnamemodify(fn.getcwd(), ':t'),
  embedEndpoint = 'http://127.0.0.1:8080/v1/embeddings',
  tableName     = 'lsp_chunks',
}

local function db_path()
  return string.format('%s/%s_rag.sqlite', fn.stdpath('data'), cfg.projectName)
end

-- ── HTTP + JSON helpers ───────────────────────────────────────────────────
local function system_json(cmd)
  local raw = fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    error('curl failed: '..raw)
  end
  return fn.json_decode(raw)
end

-- one-shot embedding call -------------------------------------------------
local function embed(text)
  local payload = {
    model   = 'gemma3-embed',
    input   = { text },
    pooling = 'mean',
  }
  local res = system_json({
    'curl','-s','-X','POST', cfg.embedEndpoint,
    '-H','Content-Type: application/json',
    '-d', fn.json_encode(payload),
  })
  if res.error then
    error(string.format('embedding error %s: %s', res.error.code or '', res.error.message or 'unknown'))
  end
  local vec = res.data and res.data[1] and res.data[1].embedding
  assert(vec and #vec > 0, 'empty embedding')
  return vec
end

local function vec_json(vec)
  -- store vector as JSON text
  return fn.json_encode(vec)
end

-- ── DB init ───────────────────────────────────────────────────────────────
local function open_db()
  local db = sqlite{
    uri    = db_path(),
    create = true,
    opts   = { keep_open = true },
  }
  db:execute(string.format([[
    CREATE TABLE IF NOT EXISTS %s (
      hash   TEXT PRIMARY KEY,
      file   TEXT,
      symbol TEXT,
      kind   INTEGER,
      text   TEXT,
      vec    TEXT        -- JSON-encoded vector
    );
  ]], cfg.tableName))
  return db
end

-- ── adaptive chunk embedder ─────────────────────────────────────────────────
local function embed_file(path)
  local lines = fn.readfile(path)
  if not lines[1] then
    vim.notify('[RAG] cannot read '..path, vim.log.levels.WARN)
    return
  end
  local db = open_db()

  local function try_insert(slice, start_ln, stop_ln)
    local key = fn.sha256(path..start_ln..stop_ln..slice)
    if db:eval('SELECT 1 FROM '..cfg.tableName..' WHERE hash = ?', key)[1] then
      return true
    end
    local ok, vec_or_err = pcall(embed, slice)
    if not ok then
      local err = vec_or_err
      if tostring(err):match('input is too large') and (stop_ln - start_ln) > 0 then
        return false
      end
      vim.notify('[RAG] embed failed: '..err, vim.log.levels.ERROR)
      return true
    end
    db:insert(cfg.tableName, {
      hash   = key,
      file   = path,
      symbol = string.format('%s:%d-%d', path, start_ln, stop_ln),
      kind   = 0,
      text   = slice,
      vec    = vec_json(vec_or_err),
    })
    return true
  end

  local function embed_range(s, e)
    local slice = table.concat(lines, '\n', s, e)
    if try_insert(slice, s, e) then return end
    local mid = math.floor((s + e) / 2)
    if mid <= s then mid = s + 1 end
    embed_range(s, mid - 1)
    embed_range(mid, e)
  end

  embed_range(1, #lines)
  vim.notify('[RAG] finished embedding '..path)
end

-- ── LSP-aware filetype filter ─────────────────────────────────────────────
local function active_ft()
  local set = {}
  for _, client in pairs(vim.lsp.get_active_clients()) do
    for _, ft in ipairs(client.config.filetypes or {}) do
      set[ft] = true
    end
  end
  return set
end

-- ── :ApolloRagEmbed command ────────────────────────────────────────────────
vim.api.nvim_create_user_command('ApolloRagEmbed', function()
  local want_ft = active_ft()
  if vim.tbl_isempty(want_ft) then
    vim.notify('[RAG] no LSP clients attached', vim.log.levels.WARN)
    return
  end
  local paths = scan.scan_dir(fn.getcwd(), { hidden=true, add_dirs=false, depth=8, respect_gitignore=true })
  local files = {}
  for _, p in ipairs(paths) do
    local ft = ftd.detect_from_extension(p) or ftd.detect(p, {})
    if ft and want_ft[ft] then table.insert(files, p) end
  end
  if vim.tbl_isempty(files) then
    vim.notify('[RAG] no source files match active LSP types', vim.log.levels.INFO)
    return
  end
  table.sort(files)
  vim.ui.select(files, { prompt = 'Pick a file to embed' }, function(choice)
    if choice then embed_file(choice) end
  end)
end, {})

return M
