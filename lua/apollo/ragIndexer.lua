-- lua/apollo/ragIndexer.lua
-- Build a binary `chunks.bin` via Tree-sitter + embedding, with directory-picker UI

local scan   = require('plenary.scandir')
local ftd    = require('plenary.filetype')
local ts     = require('vim.treesitter')
local bit = require('bit')
local ffi = require('ffi')
local api, fn= vim.api, vim.fn
local pack   = string.pack
local encode = fn.json_encode

---------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------
local cfg = {
  projectName   = fn.fnamemodify(fn.getcwd(), ':t'),
  embedEndpoint = 'http://127.0.0.1:8080/v1/embeddings',
  maxLines      = 200,
}

local out_path = fn.stdpath('data')..'/'..cfg.projectName..'_chunks.bin'

---------------------------------------------------------------------
-- Embedding helper
---------------------------------------------------------------------

-- pack a 32-bit unsigned little-endian
local function pack_u32(n)
  return string.char(
    bit.band(n, 0xFF),
    bit.band(bit.rshift(n, 8), 0xFF),
    bit.band(bit.rshift(n, 16), 0xFF),
    bit.band(bit.rshift(n, 24), 0xFF)
  )
end

-- reuse ffi to pack float32 array
local function pack_floats(tbl)
  local n   = #tbl
  local buf = ffi.new("float[?]", n, tbl)
  return ffi.string(buf, n * 4)
end

local function system_json(cmd)
  local out = fn.system(cmd)
  if vim.v.shell_error ~= 0 then error(out) end
  return fn.json_decode(out)
end

local function embed(text)
  local res = system_json{
    'curl','-s','-X','POST',cfg.embedEndpoint,
    '-H','Content-Type: application/json',
    '-d', encode{ model='gemma3-embed', input={text}, pooling='mean' }
  }
  if res.error then error(res.error.message) end
  return res.data[1].embedding
end

local function try_embed(text)
  local ok, vec = pcall(embed, text)
  if ok then return vec end
  return nil, tostring(vec)
end

---------------------------------------------------------------------
-- Tree-sitter chunk splitting
---------------------------------------------------------------------
local function get_function_ranges(bufnr, lang)
  local ok, parser = pcall(ts.get_parser, bufnr, lang)
  if not ok then return {} end
  local root = parser:parse()[1]:root()

  local types = { 'function_definition' }
  if lang=='javascript' or lang=='typescript' then
    table.insert(types,'method_definition')
  end
  local pats = vim.tbl_map(function(n) return ('(%s) @def'):format(n) end, types)
  local query = ts.query.parse(lang, table.concat(pats, '\n'))

  local ranges = {}
  for id, node in query:iter_captures(root, bufnr, 0, -1) do
    if query.captures[id]=='def' then
      local sr,_,er,_ = node:range()
      table.insert(ranges,{ start_ln=sr+1, end_ln=er+1 })
    end
  end
  return ranges
end

local function cover_whole_file(ranges, last_line)
  if vim.tbl_isempty(ranges) then
    return { { start_ln=1, end_ln=last_line } }
  end
  table.sort(ranges, function(a,b) return a.start_ln<b.start_ln end)
  local out, prev = {}, 1
  for _, r in ipairs(ranges) do
    if r.start_ln>prev then
      table.insert(out,{ start_ln=prev, end_ln=r.start_ln-1 })
    end
    table.insert(out, r)
    prev = r.end_ln + 1
  end
  if prev<=last_line then
    table.insert(out,{ start_ln=prev, end_ln=last_line })
  end
  return out
end

---------------------------------------------------------------------
-- Collect & write chunks
---------------------------------------------------------------------
local chunks = {}

local function collect_chunk(meta, lines)
  local text = table.concat(lines, '\n')
  local vec, err = try_embed(text)
  if not vec then
    if err:match('too large') and #lines>8 then
      local mid = math.floor(#lines/2)
      collect_chunk(vim.tbl_extend('force', meta, { end_ln=meta.start_ln+mid-1 }),
                    vim.list_slice(lines,1,mid))
      collect_chunk(vim.tbl_extend('force', meta, { start_ln=meta.start_ln+mid }),
                    vim.list_slice(lines,mid+1,#lines))
    else
      vim.notify(('[RAG] embed failed %s:%d — %s')
        :format(meta.file,meta.start_ln,err),vim.log.levels.WARN)
    end
    return
  end

  local id = fn.sha256(meta.file..meta.start_ln..meta.end_ln..text)
  table.insert(chunks,{
    id       = id,
    parent   = meta.parent or '',
    file     = meta.file,
    ext      = fn.fnamemodify(meta.file,':e'),
    start_ln = meta.start_ln,
    end_ln   = meta.end_ln,
    text     = text,
    vec      = vec,
  })
end

local function write_chunks_bin()
  local fh = io.open(out_path, 'wb')
  assert(fh, 'Could not open ' .. out_path)

  -- header: number of chunks
  fh:write(pack_u32(#chunks))

  for _, c in ipairs(chunks) do
    -- length-prefixed strings
    for _, field in ipairs({ 'id','parent','file','ext' }) do
      local s = c[field]
      fh:write(pack_u32(#s), s)
    end

    -- start_ln, end_ln
    fh:write(pack_u32(c.start_ln), pack_u32(c.end_ln))

    -- text
    fh:write(pack_u32(#c.text), c.text)

    -- dimension
    local dim = #c.vec
    fh:write(pack_u32(dim))

    -- raw float32 values
    fh:write(pack_floats(c.vec))
  end

  fh:close()
  vim.notify(('[RAG] wrote %d chunks → %s'):format(#chunks, out_path),
             vim.log.levels.INFO)
end

local function embed_project(roots)
  chunks = {}
  local want = {}
  for _,c in pairs(vim.lsp.get_active_clients()) do
    for _,ft in ipairs(c.config.filetypes or {}) do want[ft]=true end
  end
  if vim.tbl_isempty(want) then
    return vim.notify('[RAG] no active LSP',vim.log.levels.WARN)
  end

  local files = scan.scan_dir(fn.getcwd(),{
    hidden=true, depth=8, respect_gitignore=true,
  })
  table.sort(files)
  for _,path in ipairs(files) do
    if (not roots) or vim.tbl_contains(roots, vim.fn.fnamemodify(path, ':h')) then
      local ft = ftd.detect_from_extension(path) or ftd.detect(path,{})
      if want[ft] then
        local lines = fn.readfile(path)
        if #lines>0 then
          local ranges = cover_whole_file(
            get_function_ranges(fn.bufadd(path),ft), #lines)
          for _,r in ipairs(ranges) do
            collect_chunk({
              file=path,
              parent='',
              start_ln=r.start_ln,
              end_ln=r.end_ln,
            }, vim.list_slice(lines,r.start_ln,r.end_ln))
          end
        end
      end
    end
  end

  write_chunks_bin()
end

---------------------------------------------------------------------
-- Directory-picker UI
---------------------------------------------------------------------
local picker = { dirs={}, mark={} }
local ui_buf, ui_win

local function refresh()
  local lines = {}
  for _,d in ipairs(picker.dirs) do
    lines[#lines+1] = (picker.mark[d] and '✓ ' or '  ')..d
  end
  lines[#lines+1] = '-- <CR> to build --'
  api.nvim_buf_set_option(ui_buf,'modifiable',true)
  api.nvim_buf_set_lines(ui_buf,0,-1,false,lines)
  api.nvim_buf_set_option(ui_buf,'modifiable',false)
end

local function toggle()
  local i = api.nvim_win_get_cursor(0)[1]
  local d = picker.dirs[i]
  if d then
    picker.mark[d] = not picker.mark[d]
    refresh()
  end
end

local function close_ui()
  if ui_win and api.nvim_win_is_valid(ui_win) then api.nvim_win_close(ui_win,true) end
  if ui_buf and api.nvim_buf_is_valid(ui_buf) then api.nvim_buf_delete(ui_buf,{force=true}) end
  ui_buf, ui_win = nil, nil
end

local function commit()
  local roots = {}
  for d,sel in pairs(picker.mark) do
    if sel then roots[#roots+1] = d end
  end
  close_ui()
  embed_project(roots)
end

api.nvim_create_user_command('ApolloBuildChunksDirs', function()
  picker.dirs = scan.scan_dir(fn.getcwd(),{only_dirs=true,depth=3,respect_gitignore=true})
  table.sort(picker.dirs)
  picker.mark = {}
  ui_buf = api.nvim_create_buf(false,true)
  refresh()
  local h = math.min(#picker.dirs+1, math.floor(vim.o.lines*0.6))
  local w = math.floor(vim.o.columns*0.45)
  ui_win = api.nvim_open_win(ui_buf,true,{
    relative='editor',
    row=(vim.o.lines-h)/2,
    col=(vim.o.columns-w)/2,
    width=w,
    height=h,
    style='minimal',
    border='rounded',
  })
  api.nvim_buf_set_keymap(ui_buf,'n','e','<Cmd>lua require"apollo.ragIndexer"._toggle()<CR>',{nowait=true,noremap=true,silent=true})
  api.nvim_buf_set_keymap(ui_buf,'n','<CR>','<Cmd>lua require"apollo.ragIndexer"._commit()<CR>',{nowait=true,noremap=true,silent=true})
  api.nvim_buf_set_keymap(ui_buf,'n','q','<Cmd>lua require"apollo.ragIndexer"._close_ui()<CR>',{nowait=true,noremap=true,silent=true})
end,{})

---------------------------------------------------------------------
-- Simple project-level cmd
---------------------------------------------------------------------
api.nvim_create_user_command('ApolloBuildChunks', function()
  embed_project()
end,{})

-- expose UI fns
local M = {}
M._toggle   = toggle
M._commit   = commit
M._close_ui = close_ui
return M
