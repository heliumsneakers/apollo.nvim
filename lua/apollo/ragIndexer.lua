-- lua/apollo/ragIndexer.lua  – function-aware, Tree-sitter chunks + UI
local sqlite      = require('sqlite')
local scan        = require('plenary.scandir')
local ftd         = require('plenary.filetype')
local api, fn     = vim.api, vim.fn
local json_encode = vim.fn.json_encode
local hash        = fn.sha256
local ts           = vim.treesitter

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

-- ── safe wrapper: returns vec or nil+err ──────────────────────────────────
local function try_embed(text)
  local ok, vec_or_err = pcall(embed, text)
  if ok then return vec_or_err end
  return nil, tostring(vec_or_err)
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

-- ── Tree-sitter function finder ──────────────────────────────────────────
local function get_functions(bufnr, lang)
  local parser = ts.get_parser(bufnr, lang)
  if not parser then return {} end

  local tree = parser:parse()[1]
  local root = tree:root()

  local node_types = { "function_definition" }
  if lang == "javascript" or lang == "typescript" then
    table.insert(node_types, "method_definition")
  end

  local pats = {}
  for _, n in ipairs(node_types) do
    pats[#pats+1] = string.format("(%s) @def", n)
  end
  local query = ts.query.parse(lang, table.concat(pats, "\n"))

  local defs = {}
  for id, node in query:iter_captures(root, bufnr, 0, -1) do
    if query.captures[id] == "def" and node and node:range() then
      local sr, _, er, _ = node:range()
      defs[#defs+1] = { start_ln = sr + 1, end_ln = er + 1 }
    end
  end

  return defs
end

local function exists(db, id)
  local row = db:eval('SELECT 1 FROM '..cfg.tableName..' WHERE id=? LIMIT 1', id)
  return type(row) == 'table' and row[1] ~= nil
end

-- insert one snippet (idempotent) ---------------------------------------------
local function insert_snippet(db, meta, body)
  local id = hash(meta.file .. meta.start_ln .. meta.end_ln .. body)
  if exists(db, id) then return end        -- already stored → skip

  local vec, err = try_embed(body)
  if not vec then error(err) end

  db:eval(
    'INSERT OR IGNORE INTO '..cfg.tableName..
    ' (id,parent,file,lang,start_ln,end_ln,text,vec_json) VALUES (?,?,?,?,?,?,?,?)',
    id, meta.parent or '', meta.file, meta.lang,
    meta.start_ln, meta.end_ln, body, json_encode(vec)
  )
end

-- ── recursive fallback split if too large -------------------------------
local function split_and_ingest(db, meta, lines)
  local joined = table.concat(lines, '\n')

  local vec, err = try_embed(joined)
  if not vec and err:match('too large') and #lines > 8 then
    local mid = math.floor(#lines / 2)
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
    return
  end

  insert_snippet(db, meta, joined)
end

-- ── main file embedder ----------------------------------------------------
local function embed_file(path)
  local lines = fn.readfile(path)
  if not lines[1] then
    vim.notify('[RAG] cannot read '..path, vim.log.levels.WARN)
    return
  end

  local bufnr = fn.bufnr(path, true)
  fn.bufload(bufnr)

  local lang  = ftd.detect_from_extension(path) or ftd.detect(path,{}) or 'txt'
  local db    = open_db()
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

-- ── LSP-aware filetype filter & UI commands -----------------------------
local function active_ft()
  local s = {}
  for _, c in pairs(vim.lsp.get_active_clients()) do
    for _, ft in ipairs(c.config.filetypes or {}) do s[ft] = true end
  end
  return s
end

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
    local ft = ftd.detect_from_extension(p) or ftd.detect(p,{})
    return want[ft]
  end, all)

  vim.ui.select(files, { prompt = 'Pick a file to embed' }, function(ch)
    if ch then embed_file(ch) end
  end)
end
api.nvim_create_user_command('ApolloRagEmbed', embed_one_prompt, {})

local picker = { win=nil, buf=nil, dirs={}, mark={} }
local function refresh()
  local lines = {}
  for _, d in ipairs(picker.dirs) do
    lines[#lines+1] = (picker.mark[d] and '✓ ' or '  ') .. d
  end
  lines[#lines+1] = '-- <Enter> to start embedding --'
  api.nvim_buf_set_option(picker.buf,'modifiable',true)
  api.nvim_buf_set_lines(picker.buf,0,-1,false,lines)
  api.nvim_buf_set_option(picker.buf,'modifiable',false)
end
local function toggle()
  local row = fn.line('.'); local d = picker.dirs[row]
  if d then picker.mark[d]=not picker.mark[d]; refresh() end
end
local function close()
  if picker.win and api.nvim_win_is_valid(picker.win) then api.nvim_win_close(picker.win,true) end
  if picker.buf and api.nvim_buf_is_valid(picker.buf) then api.nvim_buf_delete(picker.buf,{force=true}) end
  picker.win,picker.buf = nil,nil
end
local function commit()
  close()
  local want = active_ft()
  for dir, sel in pairs(picker.mark) do
    if sel then
      vim.notify('[RAG] indexing '..dir)
      for _, p in ipairs(scan.scan_dir(dir,{hidden=true,add_dirs=false,depth=8,respect_gitignore=true})) do
        local ft = ftd.detect_from_extension(p) or ftd.detect(p,{})
        if want[ft] then embed_file(p) end
      end
    end
  end
  vim.notify('[RAG] bulk indexing complete')
end
api.nvim_create_user_command('ApolloRagEmbedDirs', function()
  picker.dirs = scan.scan_dir(fn.getcwd(),{only_dirs=true,depth=3,respect_gitignore=true})
  table.sort(picker.dirs); picker.mark={}
  picker.buf=api.nvim_create_buf(false,true); refresh()
  local h,w = math.min(#picker.dirs,math.floor(vim.o.lines*0.6)), math.floor(vim.o.columns*0.45)
  picker.win=api.nvim_open_win(picker.buf,true,{
    relative='editor',row=(vim.o.lines-h)/2,col=(vim.o.columns-w)/2,
    width=w,height=h,style='minimal',border='rounded'})
  vim.keymap.set('n','e',toggle,{buffer=picker.buf}); vim.keymap.set('n','<CR>',commit,{buffer=picker.buf}); vim.keymap.set('n','q',close,{buffer=picker.buf})
end, {})

return M
