-- generate_docs.lua
-- Module to generate Markdown documentation from chunks.bin.
-- Usage: require('apollo.generate_docs').generate()

local M = {}
local ffi = require('ffi')
local fn  = vim.fn
local api = vim.api

-- CONFIGURATION -----------------------------------------------------------
local bin_dir   = fn.stdpath('data')             -- default chunks.bin directory
local project   = fn.fnamemodify(fn.getcwd(), ':t')
local bin_path  = bin_dir .. '/' .. project .. '_chunks.bin'
local out_md    = bin_dir .. '/' .. project .. '_docs.md'
local chatEndpoint = 'http://127.0.0.1:8080/v1/chat/completions'

-- FFI C INDEX LOADING ----------------------------------------------------
local this_file   = debug.getinfo(1,'S').source:sub(2)
local plugin_root = fn.fnamemodify(this_file, ':p:h:h:h')
local lib_path    = plugin_root .. '/lib/chunks.dylib'
local chunks_c    = ffi.load(lib_path)

ffi.cdef[[
  typedef struct ChunkIndex ChunkIndex;
  struct ChunkIndex { uint8_t *arena_base; size_t arena_sz; uint32_t N; void *chunks; };
  ChunkIndex* ci_load(const char *filename);
  void         ci_free(ChunkIndex *ci);
  uint32_t ci_search(ChunkIndex*, const float*, uint32_t, uint32_t, uint32_t*, double*);
  const char* ci_get_file   (ChunkIndex*, uint32_t);
  const char* ci_get_ext    (ChunkIndex*, uint32_t);
  uint32_t    ci_get_start  (ChunkIndex*, uint32_t);
  const char* ci_get_text   (ChunkIndex*, uint32_t);
]]

-- HELPER: JSON system call ------------------------------------------------
local function system_json(cmd)
  local out = fn.system(cmd)
  if vim.v.shell_error ~= 0 then error(out) end
  return vim.json.decode(out)
end

-- HELPER: choose fence language from extension
local function fence_lang(ext)
  local e = ext:gsub('^%.','')
  local map = { c='c', h='c', cpp='cpp', hpp='cpp', lua='lua', py='python', js='javascript', ts='typescript' }
  return map[e] or ''
end

-- HELPER: document a single chunk via LLM, includes previous block
local function doc_chunk(prev_text, curr_text, lang)
  -- Build prompt for explanation only, without fences
  local prev_section = prev_text and table.concat({ 'Previous snippet (for context):', prev_text, '' }, '\n') or ''
  local curr_section = curr_text
  local prompt = table.concat({
    'You are a documentation assistant.',
    'Given the following code snippet and its immediate previous snippet for context,',
    'write a concise explanation of what the snippet does.',
    prev_section,
    'Snippet for explanation:',
    curr_section,
    'Provide the explanation only, no markdown fences.'
  }, '\n')

  local payload = {
    model       = 'gemma3-E2B-it',
    messages    = {
      { role='system', content='You are a helpful assistant specialized in code documentation.' },
      { role='user',   content=prompt }
    },
    temperature = 0.2,
  }
  local res = system_json{ 'curl','-s','-X','POST',chatEndpoint, '-H','Content-Type: application/json', '-d', vim.fn.json_encode(payload) }
  if res.error then error(res.error.message) end
  return res.choices[1].message.content
end

-- MAIN GENERATOR ----------------------------------------------------------
function M.document()
  if fn.filereadable(bin_path) == 0 then
    error('No chunks.bin found at ' .. bin_path)
  end

  local idx = chunks_c.ci_load(bin_path)
  if not idx then error('Failed to load chunks.bin at ' .. bin_path) end

  -- collect entries
  local total = tonumber(idx.N)
  local entries = {}
  for i=0,total-1 do
    entries[#entries+1] = {
      file = ffi.string(chunks_c.ci_get_file(idx,i)),
      ext  = ffi.string(chunks_c.ci_get_ext(idx,i)),
      start= chunks_c.ci_get_start(idx,i),
      text = ffi.string(chunks_c.ci_get_text(idx,i))
    }
  end

  table.sort(entries, function(a,b)
    if a.file~=b.file then return a.file<b.file end
    return a.start<b.start
  end)

  local out_f = io.open(out_md,'w')
  out_f:write('# Project Documentation\nGenerated on '..os.date()..'\n\n')
  local last_file, prev_text = nil, nil

  for _,e in ipairs(entries) do
    if e.file~=last_file then
      out_f:write('## '..e.file..'\n\n')
      last_file, prev_text = e.file, nil
    end

    local lang = fence_lang(e.ext)
    -- write code fence with snippet
    out_f:write('```'..lang..'\n'..e.text..'\n```\n')

    -- generate and write explanation
    local explanation = doc_chunk(prev_text, e.text)
    out_f:write(explanation..'\n\n')

    -- throttle to reduce CPU/heat
    os.execute('sleep ' .. throttle_sec)

    prev_text = e.text
  end

  out_f:close()
  chunks_c.ci_free(idx)
  print('Documentation generated at '..out_md)
end

function M.setup()
  api.nvim_create_user_command('ApolloDocument', M.document, {})
end

return M
