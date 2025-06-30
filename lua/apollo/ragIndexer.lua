-- lua/apollo/ragIndexer.lua  – function-aware, Tree-sitter chunks + UI
local sqlite  = require('sqlite')
local scan    = require('plenary.scandir')
local ftd     = require('plenary.filetype')
local ts      = vim.treesitter
local api,fn  = vim.api, vim.fn
local hash    = fn.sha256
local encode  = fn.json_encode

--------------------------------------------------------------------- cfg --
local cfg = {
  projectName   = fn.fnamemodify(fn.getcwd(), ':t'),
  embedEndpoint = 'http://127.0.0.1:8080/v1/embeddings',
  tableName     = 'lsp_chunks',
  maxLines      = 200,
}

local function db_path()
  return ('%s/%s_rag.sqlite'):format(fn.stdpath('data'), cfg.projectName)
end

----------------------------------------------------------------- embed ----
local function system_json(cmd)
  local out = fn.system(cmd)
  if vim.v.shell_error ~= 0 then error(out) end
  return fn.json_decode(out)
end

local function embed(txt)
  local res = system_json{
    'curl','-s','-X','POST',cfg.embedEndpoint,
    '-H','Content-Type: application/json',
    '-d', encode{ model='gemma3-embed', input={txt}, pooling='mean' }
  }
  if res.error then error(res.error.message) end
  return res.data[1].embedding
end

local function try_embed(txt)
  local ok, res = pcall(embed, txt)
  if ok then
    return res            -- vec table
  end
  return nil, tostring(res)
end

local function _sort_by_start(t)
  table.sort(t, function(a,b) return a.start_ln < b.start_ln end)
  return t
end

-- fill the gaps between function-definitions so line-coverage == 100 %
local function cover_whole_file(func_ranges, last_line)
  if vim.tbl_isempty(func_ranges) then
    return { { start_ln = 1, end_ln = last_line } }
  end

  local out   = {}
  local prev  = 1                         -- first un-covered line

  for _,r in ipairs(_sort_by_start(func_ranges)) do
    if r.start_ln > prev then             -- gap *before* this function
      table.insert(out, { start_ln = prev, end_ln = r.start_ln - 1 })
    end
    table.insert(out, r)                  -- the function itself
    prev = r.end_ln + 1                   -- first line after it
  end

  if prev <= last_line then               -- tail of file not in a func
    table.insert(out, { start_ln = prev, end_ln = last_line })
  end
  return out
end

----------------------------------------------------------------- sqlite ---
local DB
local function open_db()
  if DB and DB:isopen() then return DB end
  DB = sqlite{ uri=db_path(), create=true, opts={keep_open=true} }
  DB:execute(([[
    CREATE TABLE IF NOT EXISTS %s(
      id       TEXT PRIMARY KEY,
      parent   TEXT,
      file     TEXT,
      lang     TEXT,
      start_ln INT,
      end_ln   INT,
      text     TEXT,
      vec_json TEXT
    );
  ]]):format(cfg.tableName))
  return DB
end

local function row_exists(db, id)
  -- sqlite.lua returns a boolean when zero-rows; otherwise it is a table.
  local r = db:eval('SELECT 1 FROM '..cfg.tableName..' WHERE id=? LIMIT 1', id)
  return type(r) == 'table' and r[1] ~= nil
end

local function insert_row(db, meta, body, vec)
  local id = hash(meta.file .. meta.start_ln .. meta.end_ln .. body)
  if row_exists(db, id) then          -- idempotent
    return id
  end

  db:insert(cfg.tableName, {          -- one *table* → all params bound
    id         = id,
    parent     = meta.parent or '',
    file       = meta.file,
    lang       = meta.lang,
    start_ln   = meta.start_ln,
    end_ln     = meta.end_ln,
    text       = body,
    vec_json   = encode(vec),
  })
  return id
end

-------------------------------------------------------- Tree-sitter -------
local function get_funcs(bufnr, lang)
  local ok, parser = pcall(ts.get_parser, bufnr, lang)
  if not ok or not parser then return {} end
  local root = parser:parse()[1]:root()

  local nts = { "function_definition" }
  if lang=="javascript" or lang=="typescript" then nts[#nts+1]="method_definition" end
  local pat = {}
  for _,n in ipairs(nts) do pat[#pat+1]=('(%s) @def'):format(n) end
  local query = ts.query.parse(lang, table.concat(pat,"\n"))

  local defs={}
  for id,node in query:iter_captures(root, bufnr, 0, -1) do
    if query.captures[id]=="def" then
      local sr,_,er,_ = node:range()
      defs[#defs+1]={start_ln=sr+1,end_ln=er+1}
    end
  end
  return defs
end

-- ── recursive split-and-ingest (returns the chunk's id) ------------------
local function split_and_ingest(db, meta, lines)
  local joined      = table.concat(lines, '\n')
  local vec, err    = try_embed(joined)

  -- -- a) success ---------------------------------------------------------
  if vec then
    meta.id = insert_row(db, meta, joined, vec)   -- keep id for children
    return meta.id
  end

  -- -- b) “too large” fallback -------------------------------------------
  if err and err:match('too large') and #lines > 8 then
    local mid   = math.floor(#lines / 2)
    local left  = vim.list_slice(lines, 1, mid)
    local right = vim.list_slice(lines, mid + 1, #lines)

    -- first half becomes parent anchor
    local left_id = split_and_ingest(db, vim.tbl_extend('force', meta, {
      end_ln = meta.start_ln + mid - 1,
    }), left)

    -- second half points back to the parent
    split_and_ingest(db, vim.tbl_extend('force', meta, {
      start_ln = meta.start_ln + mid,
      parent   = left_id,
    }), right)

    return left_id
  end

  -- -- c) irrecoverable failure ------------------------------------------
  vim.notify('[RAG] failed to embed chunk '..meta.file..':'..meta.start_ln..
             ' — '..(err or 'unknown error'), vim.log.levels.WARN)
  return nil
end

------------------------------------------------- per-file ingester -------
local function embed_file(path)
  local lines = fn.readfile(path)
  if not lines[1] then return end

  local bufnr = fn.bufadd(path); fn.bufload(bufnr)
  local lang  = ftd.detect_from_extension(path) or ftd.detect(path,{}) or 'txt'
  local defs  = get_funcs(bufnr, lang)
  defs = cover_whole_file(defs, #lines)

  local db = open_db()
  for _,d in ipairs(defs) do
    local slice = vim.list_slice(lines,d.start_ln,d.end_ln)
    split_and_ingest(db,{
        file=path,lang=lang,start_ln=d.start_ln,end_ln=d.end_ln
    }, slice)
  end
  vim.notify(('RAG: %s (%d chunk%s) ✓'):format(
              fn.fnamemodify(path,':~:.'),
              #defs, #defs==1 and '' or 's'))
end

------------------------------------------------------ UI / commands ------
local function active_ft()
  local s={}; for _,c in pairs(vim.lsp.get_active_clients()) do
    for _,ft in ipairs(c.config.filetypes or {}) do s[ft]=true end end
  return s
end

local function embed_one()
  local want=active_ft()
  if vim.tbl_isempty(want) then return vim.notify('No LSP',vim.log.levels.WARN) end
  local files={}
  for _,p in ipairs(scan.scan_dir(fn.getcwd(),{hidden=true,depth=8,respect_gitignore=true})) do
    local ft=ftd.detect_from_extension(p) or ftd.detect(p,{})
    if want[ft] then files[#files+1]=p end
  end
  table.sort(files)
  vim.ui.select(files,{prompt='Embed file'},function(f) if f then embed_file(f) end end)
end
api.nvim_create_user_command('ApolloRagEmbed',embed_one,{})

-- simple dir picker (unchanged UI skeleton) -------------------------------
local picker={win=nil,buf=nil,dirs={},mark={}}
local function refresh()
  local l={}; for _,d in ipairs(picker.dirs) do l[#l+1]=(picker.mark[d]and'✓ 'or'  ')..d end
  l[#l+1]='-- <CR> to embed --'
  api.nvim_buf_set_option(picker.buf,'modifiable',true)
  api.nvim_buf_set_lines(picker.buf,0,-1,false,l)
  api.nvim_buf_set_option(picker.buf,'modifiable',false)
end
local function toggle() local i=fn.line('.'); local d=picker.dirs[i]
  if d then picker.mark[d]=not picker.mark[d]; refresh() end end
local function close()
  if picker.win and api.nvim_win_is_valid(picker.win) then api.nvim_win_close(picker.win,true) end
  if picker.buf and api.nvim_buf_is_valid(picker.buf) then api.nvim_buf_delete(picker.buf,{force=true}) end
  picker.win,picker.buf=nil,nil
end
local function commit()
  close()
  local want=active_ft()
  for dir,sel in pairs(picker.mark) do
    if sel then
      for _,p in ipairs(scan.scan_dir(dir,{hidden=true,depth=8,respect_gitignore=true})) do
        local ft=ftd.detect_from_extension(p) or ftd.detect(p,{})
        if want[ft] then embed_file(p) end
      end
    end
  end
  vim.notify('[RAG] bulk embed ✓')
end
api.nvim_create_user_command('ApolloRagEmbedDirs',function()
  picker.dirs=scan.scan_dir(fn.getcwd(),{only_dirs=true,depth=3,respect_gitignore=true})
  table.sort(picker.dirs); picker.mark={}
  picker.buf=api.nvim_create_buf(false,true); refresh()
  local h,w=math.min(#picker.dirs,math.floor(vim.o.lines*0.6)), math.floor(vim.o.columns*0.45)
  picker.win=api.nvim_open_win(picker.buf,true,{relative='editor',
    row=(vim.o.lines-h)/2,col=(vim.o.columns-w)/2,width=w,height=h,
    style='minimal',border='rounded'})
  vim.keymap.set('n','e',toggle,{buffer=picker.buf})
  vim.keymap.set('n','<CR>',commit,{buffer=picker.buf})
  vim.keymap.set('n','q',close,{buffer=picker.buf})
end,{})

return {}
