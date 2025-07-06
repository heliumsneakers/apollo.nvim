-- generate_docs.lua
-- Walk through a pre-built chunks.bin and generate a single Markdown documentation file
-- capturing every chunk (snippet) in source order, maintaining immediate context by including the previous block.

local ffi    = require('ffi')
local fn     = vim.fn  -- if running under Neovim; otherwise replace with os.getenv or similar

-- CONFIGURATION -----------------------------------------------------------
local bin_dir   = fn.stdpath('data')             -- default chunks.bin directory
local project   = fn.fnamemodify(fn.getcwd(), ':t')
local bin_path  = bin_dir .. '/' .. project .. '_chunks.bin'
local out_md    = bin_dir .. '/' .. project .. '_docs.md'

local chatEndpoint  = 'http://127.0.0.1:8080/v1/chat/completions'

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
  const char* ci_get_id     (ChunkIndex*, uint32_t);
  const char* ci_get_parent (ChunkIndex*, uint32_t);
  const char* ci_get_file   (ChunkIndex*, uint32_t);
  const char* ci_get_ext    (ChunkIndex*, uint32_t);
  uint32_t    ci_get_start  (ChunkIndex*, uint32_t);
  uint32_t    ci_get_end    (ChunkIndex*, uint32_t);
  const char* ci_get_text   (ChunkIndex*, uint32_t);
]]

-- HELPER: JSON system call ------------------------------------------------
local function system_json(cmd)
  local out = fn.system(cmd)
  if vim.v.shell_error ~= 0 then error(out) end
  return vim.json.decode(out)
end

-- HELPER: document a single chunk via LLM, includes previous block
local function doc_chunk(prev_text, curr_text)
  local context_section = prev_text and ("Previous snippet:\n```c\n" .. prev_text .. "\n```\n") or ""
  local prompt = table.concat({
    "You are a documentation assistant.",
    "Given the following code snippet and its immediate previous snippet for context, write a concise Markdown section describing what it does.",
    context_section,
    "Current snippet:\n```c\n" .. curr_text .. "\n```\n",
    "Output:",
  }, "\n")

  local payload = {
    model    = 'gemma3-4b-it',
    messages = {
      { role = 'system',  content = 'You are a helpful assistant specialized in code documentation.' },
      { role = 'user',    content = prompt },
    },
    temperature = 0.2,
  }
  local res = system_json{
    'curl','-s','-X','POST',chatEndpoint,
    '-H','Content-Type: application/json',
    '-d', vim.fn.json_encode(payload)
  }
  if res.error then error(res.error.message) end
  return res.choices[1].message.content
end

-- MAIN: load index --------------------------------------------------------
local idx = chunks_c.ci_load(bin_path)
if not idx then error('Failed to load chunks.bin at ' .. bin_path) end

-- gather all entries ------------------------------------------------------
local total = tonumber(idx.N)
local entries = {}
for i = 0, total-1 do
  entries[#entries+1] = {
    id     = ffi.string(chunks_c.ci_get_id(idx, i)),
    file   = ffi.string(chunks_c.ci_get_file(idx, i)),
    parent = ffi.string(chunks_c.ci_get_parent(idx, i)),
    start  = chunks_c.ci_get_start(idx, i),
    end_ln = chunks_c.ci_get_end(idx, i),
    text   = ffi.string(chunks_c.ci_get_text(idx, i)),
  }
end

-- sort by file, then parent, then start ----------------------------------
table.sort(entries, function(a,b)
  if a.file ~= b.file then return a.file < b.file end
  if a.parent ~= b.parent then return a.parent < b.parent end
  return a.start < b.start
end)

-- walk and document, keeping only immediate context -----------------------
local out_f = io.open(out_md, 'w')
out_f:write('# Project Documentation\nGenerated on ' .. os.date() .. '\n\n')

local last_file = nil
local prev_text = nil

for _, e in ipairs(entries) do
  if e.file ~= last_file then
    out_f:write('## ' .. e.file .. '\n\n')
    prev_text = nil
    last_file = e.file
  end

  -- generate documentation with previous snippet as context
  local doc = doc_chunk(prev_text, e.text)
  out_f:write(doc .. '\n\n')

  -- update prev_text to current
  prev_text = e.text
end

out_f:close()
chunks_c.ci_free(idx)
print('Documentation generated at ' .. out_md)
