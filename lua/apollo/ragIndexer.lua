-- lua/apollo/ragIndexer.lua  – function-aware, Tree-sitter chunks + UI
local sqlite      = require('sqlite')
local scan        = require('plenary.scandir')
local ftd         = require('plenary.filetype')
local ts_utils    = require('nvim-treesitter.ts_utils')
local api, fn     = vim.api, vim.fn
local json_encode = vim.fn.json_encode
local hash        = fn.sha256

-- ── config ────────────────────────────────────────────────────────────────
local cfg = {
  projectName   = fn.fnamemodify(fn.getcwd(), ':t'),
  embedEndpoint = 'http://127.0.0.1:8080/v1/embeddings',
  tableName     = 'lsp_chunks',
  maxLines      = 200,   -- fallback split threshold
}

local function db_path()
  return ('%s/%s_rag.sqlite'):format(fn.stdpath('data'), cfg.projectName)
end

-- ── HTTP → JSON ------------------------------------------------------------
local function system_json(cmd)
  local raw = fn.system(cmd)
  if vim.v.shell_error ~= 0 then error(raw) end
  return fn.json_decode(raw)
end

local function embed(text)
  local payload = {
    model   = 'gemma3-embed',
    input   = { text },
    pooling = 'mean',
  }
  local res = system_json {
    'curl','-s','-X','POST', cfg.embedEndpoint,
    '-H','Content-Type: application/json',
    '-d', json_encode(payload),
  }
  if res.error then error(res.error.message) end
  return res.data[1].embedding
end

-- ── open DB & schema ──────────────────────────────────────────────────────
local DB
local function open_db()
  if DB and DB:isopen() then return DB end
  DB = sqlite {
    uri    = db_path(),
    create = true,
    opts   = { keep_open = true },
  }
  DB:execute(([[
    CREATE TABLE IF NOT EXISTS %s (
      id         TEXT   PRIMARY KEY,
      parent     TEXT,
      file       TEXT,
      lang       TEXT,
      start_ln   INTEGER,
      end_ln     INTEGER,
      text       TEXT,
      vec_json   TEXT
    );
  ]]):format(cfg.tableName))
  return DB
end

-- ── Tree-sitter function finder ------------------------------------------
local function get_functions(bufnr, lang)
  local parser = vim.treesitter.get_parser(bufnr, lang)
  if not parser then return {} end
  local tree, root = parser:parse()[1], nil
  root = tree:root()
  local defs = {}

  local query = vim.treesitter.query.parse(lang, [[
    [
      (function_definition) 
      (method_definition)
    ] @def
    ]])

  for _, match in query:iter_matches(root, bufnr, 0, -1) do
    local node = match[1]
    local sr, _, er, _ = node:range()
    table.insert(defs, { start_ln = sr+1, end_ln = er+1 })
  end

  return defs
end

-- ── insert one snippet into DB --------------------------------------------
local function insert_snippet(db, meta, body)
  local vec    = embed(body)
  local tok    = select(2, body:gsub('%S+', ''))
  local id     = hash(meta.file..meta.start_ln..meta.end_ln..body)
  db:insert(cfg.tableName, {
    id         = id,
    parent     = meta.parent or '',
    file       = meta.file,
    lang       = meta.lang,
    start_ln   = meta.start_ln,
    end_ln     = meta.end_ln,
    text       = body,
    vec_json   = json_encode(vec),
  })
end

-- ── recursive fallback split if too large -------------------------------
local function split_and_ingest(db, meta, lines)
  if #lines <= cfg.maxLines then
    insert_snippet(db, meta, table.concat(lines, '\n'))
  else
    local mid = math.floor(#lines/2)
    local a   = vim.list_slice(lines, 1, mid)
    local b   = vim.list_slice(lines, mid+1, #lines)
    local meta_a = vim.tbl_extend('force', meta, {
      end_ln = meta.start_ln + mid - 1,
      parent = meta.id,
    })
    local meta_b = vim.tbl_extend('force', meta, {
      start_ln = meta.start_ln + mid,
      parent   = meta.id,
    })
    split_and_ingest(db, meta_a, a)
    split_and_ingest(db, meta_b, b)
  end
end

-- ── main file embedder ----------------------------------------------------
local function embed_file(path)
  local lines = fn.readfile(path)
  if not lines[1] then
    vim.notify('[RAG] cannot read '..path, vim.log.levels.WARN)
    return
  end

  local lang  = ftd.detect_from_extension(path)
  or ftd.detect(path, {}) or 'txt'
  local db    = open_db()
  local bufnr = fn.bufnr(path, true)
  if not api.nvim_buf_is_loaded(bufnr) then
    fn.bufload(bufnr)
  end
  -- find all top-level functions
  local funcs = get_functions(bufnr, lang)
  if vim.tbl_isempty(funcs) then
    funcs = {{ start_ln = 1, end_ln = #lines }}
  end

  for _, def in ipairs(funcs) do
    local snippet_lines = vim.list_slice(lines, def.start_ln, def.end_ln)
    local meta = {
      file     = path,
      lang     = lang,
      start_ln = def.start_ln,
      end_ln   = def.end_ln,
    }
    split_and_ingest(db, meta, snippet_lines)
  end

  vim.notify(('[RAG] embedded %d snippet(s) from %s'):format(#funcs, path))
end

-- ── LSP-aware filetype filter --------------------------------------------
local function active_ft()
  local s = {}
  for _, c in pairs(vim.lsp.get_active_clients()) do
    for _, ft in ipairs(c.config.filetypes or {}) do s[ft] = true end
  end
  return s
end

-- ── single-file picker ----------------------------------------------------
local function embed_one_prompt()
  local want = active_ft()
  if vim.tbl_isempty(want) then
    vim.notify('[RAG] no LSP clients attached', vim.log.levels.WARN)
    return
  end

  local all = scan.scan_dir(fn.getcwd(), {
    hidden            = true,
    add_dirs          = false,
    depth             = 8,
    respect_gitignore = true,
  })
  table.sort(all)

  local files = vim.tbl_filter(function(p)
    local ft = ftd.detect_from_extension(p) or ftd.detect(p, {})
    return want[ft]
  end, all)

  vim.ui.select(files, { prompt = 'Pick a file to embed' }, function(ch)
    if ch then embed_file(ch) end
  end)
end
api.nvim_create_user_command('ApolloRagEmbed', embed_one_prompt, {})

-- ── directory-picker UI ---------------------------------------------------
local picker = { win=nil, buf=nil, dirs={}, mark={} }

local function refresh()
  local lines = {}
  for _, d in ipairs(picker.dirs) do
    lines[#lines+1] = (picker.mark[d] and '✓ ' or '  ') .. d
  end
  lines[#lines+1] = '-- <Enter> to start embedding --'
  api.nvim_buf_set_option(picker.buf, 'modifiable', true)
  api.nvim_buf_set_lines(picker.buf, 0, -1, false, lines)
  api.nvim_buf_set_option(picker.buf, 'modifiable', false)
end

local function toggle()
  local row = fn.line('.')
  local d   = picker.dirs[row]
  if d then picker.mark[d] = not picker.mark[d]; refresh() end
end

local function close()
  if picker.win and api.nvim_win_is_valid(picker.win) then
    api.nvim_win_close(picker.win, true)
  end
  if picker.buf and api.nvim_buf_is_valid(picker.buf) then
    api.nvim_buf_delete(picker.buf, { force = true })
  end
  picker.win, picker.buf = nil, nil
end

local function commit()
  close()
  local want = active_ft()
  for dir, sel in pairs(picker.mark) do
    if sel then
      vim.notify('[RAG] indexing '..dir)
      for _, p in ipairs(scan.scan_dir(dir, {
        hidden            = true,
        add_dirs          = false,
        depth             = 8,
        respect_gitignore = true,
      })) do
        local ft = ftd.detect_from_extension(p) or ftd.detect(p,{})
        if want[ft] then embed_file(p) end
      end
    end
  end
  vim.notify('[RAG] bulk indexing complete')
end

api.nvim_create_user_command('ApolloRagEmbedDirs', function()
  picker.dirs = scan.scan_dir(fn.getcwd(), {
    only_dirs         = true,
    depth             = 3,
    respect_gitignore = true,
  })
  table.sort(picker.dirs)
  if vim.tbl_isempty(picker.dirs) then
    vim.notify('[RAG] no sub-directories found', vim.log.levels.WARN)
    return
  end

  picker.mark = {}
  picker.buf  = api.nvim_create_buf(false, true)
  refresh()

  local h = math.min(#picker.dirs, math.floor(vim.o.lines * 0.6))
  local w = math.floor(vim.o.columns * 0.45)
  picker.win = api.nvim_open_win(picker.buf, true, {
    relative = 'editor',
    row      = (vim.o.lines - h) / 2,
    col      = (vim.o.columns - w) / 2,
    width    = w,
    height   = h,
    style    = 'minimal',
    border   = 'rounded',
  })

  api.nvim_buf_set_option(picker.buf, 'filetype', 'rag_picker')
  vim.keymap.set('n', 'e', toggle,  { buffer = picker.buf })
  vim.keymap.set('n', '<CR>', commit, { buffer = picker.buf })
  vim.keymap.set('n', 'q', close,   { buffer = picker.buf })
end, {})

return M
