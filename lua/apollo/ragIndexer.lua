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

local function vec_json(tbl)
  return vim.fn.json_encode(tbl)  -- returns a compact '[0.12,-0.34,...]'
end

-- ── DB helpers ────────────────────────────────────────────────────────────
local function open_db()
  local db = sqlite{
    uri   = db_path(),
    create = true,
    opts  = { keep_open = true },
  }

  db:execute(([[
    CREATE TABLE IF NOT EXISTS %s (
      hash   TEXT PRIMARY KEY,
      file   TEXT,
      symbol TEXT,
      kind   INT,
      text   TEXT,
      vec    TEXT   -- store as JSON string
    );]]):format(cfg.tableName))

  return db
end

-- ── embed one file (adaptive chunk size) ───────────────────────────────────
local function embed_file(path)
  local lines = vim.fn.readfile(path)
  if not lines[1] then
    vim.notify('[RAG] cannot read '..path, vim.log.levels.WARN); return
  end

  local db = open_db()

  local function try_insert(slice, start_ln, stop_ln)
    local key = hash(path..start_ln..stop_ln..slice)
    if type(db:eval('SELECT 1 FROM '..cfg.tableName..' WHERE hash=?', key))=='table' then
      return true  -- already there
    end
    local ok, vec = pcall(embed, slice)
    if not ok then
      if tostring(vec):match('input is too large') and (stop_ln - start_ln) > 0 then
        return false  -- tell caller to split further
      end
      vim.notify('[RAG] embed failed: '..vec, vim.log.levels.ERROR)
      return true  -- give up on this slice but continue others
    end
    db:insert(cfg.tableName, {
      hash   = key,
      file   = path,
      symbol = ('%s:%d-%d'):format(path,start_ln,stop_ln),
      kind   = 0,
      text   = slice,
      vec    = vec_json(vec),   -- <- use JSON string
    })
    return true
  end

  -- recursive splitter -----------------------------------------------------
  local function embed_range(s, e)
    local slice = table.concat(lines, '\n', s, e)
    if try_insert(slice, s, e) then return end
    local mid = math.floor((s+e)/2)
    if mid <= s then mid = s end
    if mid >= e then mid = e-1 end
    embed_range(s, mid)
    embed_range(mid+1, e)
  end

  embed_range(1, #lines)
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

-- ── UI helper (simple multi-select) ----------------------------------------
local function pick_dirs(candidates, callback)
  local marked, order = {}, {}
  local function build_display()
    local out = {}
    for i,p in ipairs(candidates) do
      out[#out+1] = (marked[p] and '✓ ' or '  ') .. p
    end
    out[#out+1] = '-- Done --'
    return out
  end

  local function redraw()
    vim.ui.select(build_display(), { prompt = 'Toggle folders (CR), Tab = Done' },
      function(choice, idx)
        if not choice then return end
        if choice == '-- Done --' or idx == #build_display() then
          local sel = {}
          for _,p in ipairs(order) do if marked[p] then sel[#sel+1]=p end end
          callback(sel)
          return
        end
        local real = candidates[idx]
        marked[real] = not marked[real]
        if not marked[real] then
          -- remove from order
          for k,v in ipairs(order) do if v==real then table.remove(order,k);break end end
        else order[#order+1]=real end
        redraw()  -- recurse to re-open
      end)
  end
  redraw()
end

-- ── command :ApolloRagEmbedDirs -------------------------------------------
vim.api.nvim_create_user_command('ApolloRagEmbedDirs', function()
  --------------------------------------------------------------------------
  -- 1. collect candidate dirs (depth ≤ 3) ---------------------------------
  --------------------------------------------------------------------------
  local raw_dirs = scan.scan_dir(vim.fn.getcwd(), {
    only_dirs = true, depth = 3, respect_gitignore = true, hidden = false,
  })
  table.sort(raw_dirs)

  if vim.tbl_isempty(raw_dirs) then
    vim.notify('[RAG] no sub-directories found', vim.log.levels.WARN)
    return
  end

  --------------------------------------------------------------------------
  -- 2. let user pick which dirs to index ----------------------------------
  --------------------------------------------------------------------------
  pick_dirs(raw_dirs, function(selected)
    if vim.tbl_isempty(selected) then
      vim.notify('[RAG] nothing selected', vim.log.levels.INFO); return
    end

    ------------------------------------------------------------------------
    -- 3. derive desired filetypes from active LSPs ------------------------
    ------------------------------------------------------------------------
    local want_ft = active_ft_set()
    if vim.tbl_isempty(want_ft) then
      vim.notify('[RAG] no LSP clients attached', vim.log.levels.WARN); return
    end

    ------------------------------------------------------------------------
    -- 4. for each dir, recursively embed matching files ------------------
    ------------------------------------------------------------------------
    for _,dir in ipairs(selected) do
      vim.notify('[RAG] indexing '..dir)
      local paths = scan.scan_dir(dir, {
        hidden=true, add_dirs=false, depth=8, respect_gitignore=true,
      })
      for _,p in ipairs(paths) do
        local ft = ftd.detect_from_extension(p) or ftd.detect(p,{})
        if ft and want_ft[ft] then
          embed_file(p)             -- adaptive chunk embedder
        end
      end
    end
    vim.notify('[RAG] bulk indexing complete')
  end)
end, {})

return M
