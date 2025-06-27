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
  local payload = { model = 'gemma3-embed', input = { text } }
  local j = vim.fn.systemjson({ 'curl','-s','-X','POST', cfg.embedEndpoint,
                               '-H','Content-Type: application/json',
                               '-d', vim.fn.json_encode(payload) })
  return j.data[1].embedding  -- table<float>
end

local function f32bin(vec)
  local out = {}
  for _,v in ipairs(vec) do out[#out+1] = string.pack('<f', v) end
  return table.concat(out)
end

-- ── DB init ────────────────────────────────────────────────────────────────
local function open_db()
  -- sqlite.lua constructor: call the module like a function
  -- (creates file if it doesn't exist)
  local db = require('sqlite') {
    uri    = db_path(),
    create = true,
  }

  db:exec(string.format([[
    CREATE TABLE IF NOT EXISTS %s (
      hash   TEXT PRIMARY KEY,
      file   TEXT,
      symbol TEXT,
      kind   INT,
      text   TEXT,
      vec    BLOB
    );
  ]], cfg.tableName))

  db:exec('PRAGMA journal_mode=WAL;')
  return db
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
  client.request('textDocument/documentSymbol',{ textDocument={uri=uri_of(buf)} },
    function(err, res)
      if err or not res then return end
      local function walk(sym)
        if wanted[sym.kind] then
          local code = slice(buf, sym.range)
          local chunk = ('/// %s:%d-%d\n%s'):format(file, sym.range.start.line+1, sym.range['end'].line+1, code)
          local h = hash(chunk)
          if not db:select('SELECT 1 FROM '..cfg.tableName..' WHERE hash=?',{h})[1] then
            local vec = f32bin(embed(chunk))
            db:insert(cfg.tableName,{hash=h,file=file,symbol=sym.name,kind=sym.kind,text=chunk,vec=vec})
          end
        end
        if sym.children then for _,c in ipairs(sym.children) do walk(c) end end
      end
      for _,s in ipairs(res) do walk(s) end
    end,
    buf)
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
