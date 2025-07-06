-- lua/apollo/context_chat.lua  –  RAG Q-and-A assistant (json-vec) with SQL prefilter
local M    = {}
local api, fn = vim.api, vim.fn
local ffi  = require('ffi')

-- ── configuration ────────────────────────────────────────────────────────
local cfg = {
  projectName  = fn.fnamemodify(fn.getcwd(), ':t'),
  embedEndpoint= 'http://127.0.0.1:8080/v1/embeddings',
  chatEndpoint = 'http://127.0.0.1:8080/v1/chat/completions',
  topK         = 12, -- number of top ranking results
}

-- ── UI state ─────────────────────────────────────────────────────────────
local UI = { resp_buf=nil, resp_win=nil, input_buf=nil, input_win=nil }
local H  = { history_lines = {}, pending = '' }

-- ── load C index library ─────────────────────────────────────────────────
local this_file   = debug.getinfo(1,'S').source:sub(2)
local plugin_root = fn.fnamemodify(this_file, ':p:h:h:h')
local lib_path    = plugin_root .. '/lib/chunks.dylib'
local chunks_c    = ffi.load(lib_path)

ffi.cdef[[
  typedef struct ChunkIndex ChunkIndex;
  ChunkIndex* ci_load(const char *filename);
  void         ci_free(ChunkIndex *ci);
  uint32_t ci_search(
    ChunkIndex *ci,
    const float *qemb,
    uint32_t     dim,
    uint32_t     K,
    uint32_t    *out_idxs,
    double      *out_scores
  );
  const char* ci_get_file (ChunkIndex*, uint32_t idx);
  const char* ci_get_text (ChunkIndex*, uint32_t idx);
  const char* ci_get_parent (ChunkIndex*, uint32_t idx);
  uint32_t    ci_get_start  (ChunkIndex*, uint32_t idx);
  uint32_t    ci_get_end    (ChunkIndex*, uint32_t idx);
]]

-- ── load binary index ─────────────────────────────────────────────────────
local bin_path = fn.stdpath('data') .. '/' .. cfg.projectName .. '_chunks.bin'
local ci
local has_index = false

if fn.filereadable(bin_path) == 1 then
  ci = chunks_c.ci_load(bin_path)
  if ci then
    has_index = true
    vim.notify('[Apollo] Retrieved chunks.bin, semantic search enabled.')
  else
    vim.notify('[Apollo] Failed to load chunks.bin, semantic search disabled.', vim.log.levels.WARN)
  end
else
  vim.notify('[Apollo] No chunks.bin found, semantic search disabled.', vim.log.levels.INFO)
end

-- ── embedding helper ──────────────────────────────────────────────────────
local function system_json(cmd)
  local out = fn.system(cmd)
  if vim.v.shell_error ~= 0 then error(out) end
  return fn.json_decode(out)
end

local function embed(text)
  local res = system_json{
    'curl','-s','-X','POST',cfg.embedEndpoint,
    '-H','Content-Type: application/json',
    '-d', fn.json_encode{ model='gemma3-embed', input={text}, pooling='mean' }
  }
  if res.error then error(res.error.message) end
  return res.data[1].embedding
end

-- simplify query
local function simplify_query(full_q)
  local payload = {
    model    = 'gemma3-4b-it',
    messages = {
      { role = 'system',
        content = 'You are a helpful assistant. Given a user question, return a one-phrase summary that captures the core search intent. Keep it under 5 words, no punctuation.' },
      { role = 'user', content = full_q },
    },
    stream = false,
  }

  local res = system_json{
    'curl','-s','-X','POST', cfg.chatEndpoint,
    '-H','Content-Type: application/json',
    '-d', fn.json_encode(payload)
  }
  if res.error then error(res.error.message) end

  -- assume the assistant responds in choices[1].message.content
  return vim.trim(res.choices[1].message.content)
end


-- ── retrieve via C index ─────────────────────────────────────────────────
local function retrieve(query)

  if not has_index then
    return {}  -- or maybe warn once
  end

  -- embed query → C float array
  local qv  = embed(query)
  local dim = #qv
  local q_c = ffi.new("float[?]", dim, qv)

  -- prepare output buffers
  local K     = cfg.topK
  local out_i = ffi.new("uint32_t[?]", K)
  local out_s = ffi.new("double[?]",   K)

  -- call C search
  local cnt = tonumber(chunks_c.ci_search(ci, q_c, dim, K, out_i, out_s))

  -- collect results
  local results = {}
  for i = 0, cnt-1 do
    local txt   = ffi.string(chunks_c.ci_get_text(ci, out_i[i]))
    results[#results+1] = txt
  end

  return results
end

local function retrieve_meta(query)

  if not has_index then
    return {}  -- or maybe warn once
  end

  local qv  = embed(query)
  local dim = #qv
  local q_c = ffi.new("float[?]", dim, qv)

  local K     = cfg.topK
  local out_i = ffi.new("uint32_t[?]", K)
  local out_s = ffi.new("double[?]",   K)

  local cnt = tonumber(chunks_c.ci_search(ci, q_c, dim, K, out_i, out_s))
  local results = {}
  for i = 0, cnt-1 do
    local idx   = out_i[i]
    results[#results+1] = {
      score    = out_s[i] * 100,
      file     = ffi.string(chunks_c.ci_get_file(ci, idx)),
      parent   = ffi.string(chunks_c.ci_get_parent(ci, idx)),
      start_ln = tonumber(chunks_c.ci_get_start(ci, idx)),
      end_ln   = tonumber(chunks_c.ci_get_end(ci, idx)),
      text     = ffi.string(chunks_c.ci_get_text(ci, idx)),
    }
  end

  table.sort(results, function(a,b)
    return a.score > b.score
  end)

  return results
end

-- ── cleanup on exit ───────────────────────────────────────────────────────
api.nvim_create_autocmd('VimLeavePre', {
  callback = function() chunks_c.ci_free(ci) end,
})

local function _flatten(buf)
  if not api.nvim_buf_is_valid(buf) then return end
  local l = api.nvim_buf_get_lines(buf, 0, -1, false)
  if #l > 1 then
    local j = table.concat(l, ' '):gsub('%s+$','')
    api.nvim_buf_set_lines(buf, 0, -1, false, { j })
    api.nvim_win_set_cursor(0, {1, #j})
  end
end

local function _center(lines, total_w)
  local max = 0
  for _,ln in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(ln:gsub('%s+$',''))
    if w>max then max=w end
  end
  local pad  = math.max(math.floor((total_w-max)/2),0)
  local pref = (' '):rep(pad)
  local out  = {}
  for _,ln in ipairs(lines) do out[#out+1] = pref..ln end
  return out
end

local function _splash()
  return {
    "                                                    ",
    "  █████╗ ██████╗  ██████╗ ██╗     ██╗      ██████╗  ",
    " ██╔══██╗██╔══██╗██╔═══██╗██║     ██║     ██╔═══██╗ ",
    " ███████║██████╔╝██║   ██║██║     ██║     ██║   ██║ ",
    " ██╔══██║██╔═══╝ ██║   ██║██║     ██║     ██║   ██║ ",
    " ██║  ██║██║     ╚██████╔╝███████╗███████╗╚██████╔╝ ",
    " ╚═╝  ╚╝ ╚═╝      ╚═════╝ ╚══════╝╚══════╝ ╚═════╝  ",
    "                                                    ",
  }
end

local function _close(reset_history)
  for _,w in pairs{UI.resp_win, UI.input_win} do
    if w and api.nvim_win_is_valid(w) then api.nvim_win_close(w,true) end
  end
  for _,b in pairs{UI.resp_buf, UI.input_buf} do
    if b and api.nvim_buf_is_valid(b) then api.nvim_buf_delete(b,{force=true}) end
  end
  UI = { resp_buf=nil, resp_win=nil, input_buf=nil, input_win=nil }
  if reset_history then H.history_lines = {} end
end

local function _stream(prompt)
  H.pending = ''
  api.nvim_buf_set_option(UI.resp_buf, 'modifiable', true)

  fn.jobstart({
    'curl','-s','-N','-X','POST', cfg.chatEndpoint,
    '-H','Content-Type: application/json',
    '-d', fn.json_encode({
      model   = 'gemma3-4b-it',
      stream  = true,
      messages = { { role = 'user', content = prompt } },
    })
  }, {
      stdout_buffered = false,
      on_stdout = function(_, data)
        for _, raw in ipairs(data or {}) do
          if not raw:match('^data: ') then goto continue end
          local js = raw:sub(7)

          -- ── stream finished ─────────────────────────────────────────────
          if js == '[DONE]' then
            if #H.pending > 0 then
              api.nvim_buf_set_lines(UI.resp_buf, -1, -1, false, { H.pending })
              vim.list_extend(H.history_lines, { H.pending })
              H.pending = ''
            end
            api.nvim_buf_set_option(UI.resp_buf, 'modifiable', false)
            return
          end

          -- ── normal chunk ───────────────────────────────────────────────
          local ok, chunk = pcall(fn.json_decode, js)
          if ok and chunk.choices then
            local delta = chunk.choices[1].delta.content      -- may be nil | userdata
            if type(delta) ~= 'string' then
              delta = ''                                      -- ignore non-text
            end

            if #delta > 0 then
              H.pending = H.pending .. delta

              -- flush complete lines
              local flush = {}
              for line in H.pending:gmatch('(.-)\n') do
                flush[#flush + 1] = line
              end
              if #flush > 0 then
                api.nvim_buf_set_lines(UI.resp_buf, -1, -1, false, flush)
                vim.list_extend(H.history_lines, flush)
                H.pending = H.pending:match('.*\n(.*)') or ''
              end
            end
          end
          ::continue::
        end
      end,
    })
end

-- ── minimal UI layer (same as before) ────────────────────────────────────
local function _open_ui()
  local tot    = vim.o.lines
  local resp_h = math.floor(tot*0.65)
  local in_h   = tot - resp_h - 10
  local width  = math.floor(vim.o.columns*0.8)
  local col    = math.floor((vim.o.columns-width)/2)

  -- response buffer / window
  if not (UI.resp_buf and api.nvim_buf_is_valid(UI.resp_buf)) then
    UI.resp_buf = api.nvim_create_buf(false,true)
    api.nvim_buf_set_option(UI.resp_buf,'filetype','markdown')
  end
  UI.resp_win = api.nvim_open_win(UI.resp_buf,true,{
    relative='editor',row=1,col=col,width=width,height=resp_h,
    style='minimal',border={'▛','▀','▜','▐','▟','▄','▙','▌'},
  })
  api.nvim_win_set_option(UI.resp_win,'wrap',true)

  api.nvim_buf_set_option(UI.resp_buf,'modifiable',true)
  local init = (#H.history_lines==0) and _center(_splash(),width)
  or  H.history_lines
  api.nvim_buf_set_lines(UI.resp_buf,0,-1,false,init)
  api.nvim_buf_set_option(UI.resp_buf,'modifiable',false)

  -- prompt buffer / window
  if not (UI.input_buf and api.nvim_buf_is_valid(UI.input_buf)) then
    UI.input_buf = api.nvim_create_buf(false,false)
    api.nvim_buf_set_option(UI.input_buf,'buftype','prompt')
    api.nvim_buf_set_option(UI.input_buf,'bufhidden','hide')
  end
  if #H.history_lines==0 then
    api.nvim_buf_set_lines(UI.input_buf,0,-1,false,{})
  end
  UI.input_win = api.nvim_open_win(UI.input_buf,true,{
    relative='editor',row=resp_h+2,col=col,
    width=width,height=in_h,
    style='minimal',border={'▛','▀','▜','▐','▟','▄','▙','▌'},
  })
  vim.fn.prompt_setprompt(UI.input_buf,'→ ')
  api.nvim_command('startinsert')

  api.nvim_buf_set_keymap(UI.input_buf,'i','<CR>',
    [[<Cmd>lua require('apollo.implAgent')._send()<CR>]],
    {noremap=true,silent=true})

  api.nvim_create_autocmd({'TextChangedI','TextChangedP'},{
    buffer=UI.input_buf, callback=function() _flatten(UI.input_buf) end,
  })
end

--- DEBUGGING ---

-- Live‐search UI state
local SUI = { res_buf=nil, res_win=nil, inp_buf=nil, inp_win=nil }

local function render_live(results)
  if not (SUI.res_buf and api.nvim_buf_is_valid(SUI.res_buf)) then return end
  local lines = {}
  for i, r in ipairs(results) do
    table.insert(lines, string.format(
      "%2d. [%.1f%%] %s:%d–%d  parent=%s",
      i, r.score, r.file, r.start_ln, r.end_ln, r.parent=="" and "<file>" or r.parent
    ))
    for _, ln in ipairs(vim.split(r.text, "\n")) do
      table.insert(lines, "     " .. ln)
    end
    table.insert(lines, "")  -- blank line between hits
  end
  api.nvim_buf_set_option(SUI.res_buf,'modifiable',true)
  api.nvim_buf_set_lines(SUI.res_buf,0,-1,false,lines)
  api.nvim_buf_set_option(SUI.res_buf,'modifiable',false)
end

local function _open_live_search()
  -- results window
  local h = math.floor(vim.o.lines*0.6)
  local w = math.floor(vim.o.columns*0.8)
  SUI.res_buf = api.nvim_create_buf(false,true)
  api.nvim_buf_set_option(SUI.res_buf,'filetype','markdown')
  SUI.res_win = api.nvim_open_win(SUI.res_buf,true,{
    relative='editor', row=1, col=2, width=w, height=h,
    style='minimal', border='rounded',
  })
  api.nvim_win_set_option(SUI.res_win,'wrap',true)

  -- input window
  local ih = 3
  SUI.inp_buf = api.nvim_create_buf(false,false)
  api.nvim_buf_set_option(SUI.inp_buf,'buftype','prompt')
  SUI.inp_win = api.nvim_open_win(SUI.inp_buf,true,{
    relative='editor', row=h+2, col=2, width=w, height=ih,
    style='minimal', border='rounded',
  })
  vim.fn.prompt_setprompt(SUI.inp_buf,'Search→ ')
  api.nvim_command('startinsert')

  -- on every change, re-render
  api.nvim_create_autocmd({'TextChangedI','TextChangedP'},{
    buffer=SUI.inp_buf,
    callback = function()
      local l = api.nvim_buf_get_lines(SUI.inp_buf,0,-1,false)[1] or ""
      local q = l:gsub('^Search→%s*','')
      if #q > 0 then
        local hits = retrieve_meta(q)
        render_live(hits)
      else
        api.nvim_buf_set_lines(SUI.res_buf,0,-1,false,{})
      end
    end,
  })
end

function M.live_search()
  _open_live_search()
end
--- DEBUGGING ---

function M._send()
  local raw = api.nvim_buf_get_lines(UI.input_buf,0,-1,false)
  local query = table.concat(raw,' '):gsub('^→ ','')
  api.nvim_buf_set_lines(UI.input_buf,0,-1,false,{})
  if query=='' then return end

  local simple_q = simplify_query(query)

  -- build RAG prompt
  local meta = retrieve_meta(simple_q)

  local prompt = [[
 You are a helpful code implementation AI trained on a users local codebase.  You will be given:
  1) The user's original question.
  2) A set of context snippets retrieved from semantic search.
  Filter through these results and pick only the most relevant options.
  Choose and combine the most relevant snippets, then answer the user's full question with code snippets as needed but *ONLY* pertaining to the question at hand.
  Keep replies short and simple, but straight to the point.

 Original question:
 ]] .. query .. [[

 Retrieved snippets:
 ]]

  for i,hit in ipairs(meta) do
    prompt = prompt
    .. ("----- snippet %2d [%.1f%%] -----\n"):format(i, hit.score)
    .. hit.text .. "\n\n"
  end

  prompt = prompt.."Q: "..query.."\nA: "
  _stream(prompt)
end

-- ── command wiring ───────────────────────────────────────────────────────
function M.open() _open_ui() end
function M.quit() _close(true) end
function M.setup()
  api.nvim_create_user_command('ApolloAsk', M.open, {})
  api.nvim_create_user_command('ApolloAskQuit', M.quit, {})
  api.nvim_create_user_command('ApolloLive', M.live_search, {})
end
return M
