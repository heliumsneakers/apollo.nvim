-- lua/apollo/ragIndexer.lua -------------------------------------------------
-- Build & update a local SQLite vector store (<project>_rag.sqlite) with one
-- row per *symbol* harvested via the active LSP servers.
--
-- How it works
--   • Walk every file returned by ripgrep --files (i.e. in the workspace).
--   • Ask each attached LSP for `textDocument/documentSymbol`.
--   • For every symbol of interesting kinds (functions, methods, structs…):
--       - Slice exact source lines (range).
--       - Embed that text with Gemma‑3 embeddings running at localhost.
--       - Store {hash, file, symbol, kind, text, vec} if not already cached.
--   • DB filename is `<projectName>_rag.sqlite` inside stdpath('data').
--
-- Expose `:ApolloRagReindex` to (re)build.
-----------------------------------------------------------------------------

local sqlite = require('sqlite')
local hash   = vim.fn.sha256
local uri_of = vim.uri_from_bufnr
local M      = {}

-- ── configuration ──────────────────────────────────────────────────────────
local cfg = {
  projectName   = vim.fn.fnamemodify(vim.fn.getcwd(), ':t'),
  embeddingDim  = 256,                   -- Gemma‑3 embedding dim
  embedEndpoint = 'http://127.0.0.1:8080/v1/embeddings',
  tableName     = 'lsp_chunks',
}

-- allow user overrides via .setup{}
local function apply(opts)
  if not opts then return end
  for k,v in pairs(opts) do cfg[k]=v end
end

-- final DB path
local function db_path()
  return string.format('%s/%s_rag.sqlite', vim.fn.stdpath('data'), cfg.projectName)
end

-- ── embedding helpers ──────────────────────────────────────────────────────
local function embed(text)
  -- build the payload exactly like test.sh
  local payload = {
    model            = 'gemma3-embed',  -- any id works for llama-server
    input            = { text },
    pooling          = 'mean',          -- REQUIRED or server throws 400
    encoding_format  = 'float',         -- returns plain float32 numbers
  }

  -- make the request
  local ok, res = pcall(vim.fn.systemjson, {
    'curl', '-s', '-X', 'POST', cfg.embedEndpoint,
    '-H',   'Content-Type: application/json',
    '-d',   vim.fn.json_encode(payload),
  })

  if not ok then
    error('curl failed: '..res)
  end

  -- basic sanity check
  if not res or not res.data or not res.data[1]
     or not res.data[1].embedding or #res.data[1].embedding == 0
  then
    error('embedding response malformed or empty')
  end

  return res.data[1].embedding   -- table<float>
end

local function f32bin(vec)
  local out = {}
  for _,v in ipairs(vec) do out[#out+1] = string.pack('<f', v) end
  return table.concat(out)
end

-- ── DB init ────────────────────────────────────────────────────────────────
local function open_db()
  local sqlite = require('sqlite')

  -- create handle
  local db = sqlite {
    uri   = db_path(),
    create = true,
    opts  = { keep_open = true },  -- <- keeps connection open
  }

  -- connection guaranteed open here
  db:execute(string.format([[
    CREATE TABLE IF NOT EXISTS %s (
      hash   TEXT PRIMARY KEY,
      file   TEXT,
      symbol TEXT,
      kind   INT,
      text   TEXT,
      vec    BLOB
    );
  ]], cfg.tableName))

  db:execute('PRAGMA journal_mode=WAL;')
  return db           -- still open for inserts
end

-- ── symbol harvesting ──────────────────────────────────────────────────────
local SymbolKind = vim.lsp.protocol.SymbolKind
local wanted = {
  [SymbolKind.Function]=true,  [SymbolKind.Method]=true,
  [SymbolKind.Struct]=true,    [SymbolKind.Enum]=true,
  [SymbolKind.Interface]=true, [SymbolKind.Constructor]=true,
}

local function slice(buf, range)
  return table.concat(
    vim.api.nvim_buf_get_lines(buf, range.start.line, range['end'].line+1, false),
    '\n')
end

---@param client table LSP client
---@param buf    integer
---@param file   string
local function index_symbols(client, buf, file, db)
  -- quick helper so logging never blocks UI
  local function log(msg)
    vim.schedule(function()
      vim.notify('[RAG] '..msg, vim.log.levels.DEBUG)   -- :set loglevel=debug to see
    end)
  end

  client.request(
    'textDocument/documentSymbol',
    { textDocument = { uri = uri_of(buf) } },
    function(err, res)
      if err then
        log(('LSP error on %s: %s'):format(file, err.message or err))
        return
      end
      if not res then
        log(('No symbols returned for %s'):format(file))
        return
      end

      local inserted = 0

      local function walk(sym)
        if wanted[sym.kind] then
          local code  = slice(buf, sym.range)
          local chunk = ('/// %s:%d-%d\n%s')
                         :format(file, sym.range.start.line + 1,
                                 sym.range['end'].line + 1, code)
          local h = hash(chunk)

          if not db:select('SELECT 1 FROM '..cfg.tableName..' WHERE hash=?', { h })[1] then
            log(('embedding %s (%s)'):format(sym.name, file))
            local ok, vec = pcall(function() return f32bin(embed(chunk)) end)
            if ok then
              db:insert(cfg.tableName, {
                hash   = h,
                file   = file,
                symbol = sym.name,
                kind   = sym.kind,
                text   = chunk,
                vec    = vec,
              })
              inserted = inserted + 1
            else
              log(('embed failed: %s'):format(vec))  -- ‘vec’ holds the error message here
            end
          end
        end
        if sym.children then
          for _, c in ipairs(sym.children) do walk(c) end
        end
      end

      for _, s in ipairs(res) do walk(s) end
      if inserted > 0 then
        log(('↑ added %d symbol%s from %s')
            :format(inserted, inserted == 1 and '' or 's', file))
      end
    end,
    buf
  )
end

-- ── main reindex routine ───────────────────────────────────────────────────
function M.reindex()
  local db = open_db()
  local files = vim.fn.systemlist('rg --files')
  for _,file in ipairs(files) do
    local buf = vim.fn.bufadd(file); vim.fn.bufload(buf)
    for _,client in pairs(vim.lsp.get_active_clients({bufnr=buf})) do
      if client.supports_method('textDocument/documentSymbol') then
        index_symbols(client, buf, file, db)
      end
    end
  end
  print('[Apollo] RAG DB updated → '..db_path())
end

-- ── setup / user command ───────────────────────────────────────────────────
vim.api.nvim_create_user_command('ApolloRagReindex', function()
  -- run on next event-loop tick (non-blocking, same Lua state)
  vim.schedule(function()
    local ok, err = pcall(M.reindex)
    if not ok then
      vim.notify('[Apollo] RAG reindex failed: '..err, vim.log.levels.ERROR)
    end
  end)
end, {})

return M
