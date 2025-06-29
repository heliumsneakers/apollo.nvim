-- plugin/apollo.lua ---------------------------------------------------------
if vim.g.loaded_apollo then return end
vim.g.loaded_apollo = true

-- enhanced loader: pass opts table when given
local function load(mod, opts)
  -------------------------------------------------------------------------
  -- 1. safely require the module; the table goes into `modtbl` (NOT `pack`)
  -------------------------------------------------------------------------
  local ok, modtbl = pcall(require, mod)
  if not ok then
    vim.notify('[apollo.nvim] '..modtbl, vim.log.levels.ERROR)
    return
  end

  -------------------------------------------------------------------------
  -- 2. run .setup(opts) if the module exposes it
  -------------------------------------------------------------------------
  if type(modtbl.setup) == 'function' then
    local ok2, err = pcall(modtbl.setup, opts)
    if not ok2 then
      vim.notify('[apollo.nvim] '..err, vim.log.levels.ERROR)
    end
  end
end

-- core UI pieces ------------------------------------------------------------
load('apollo')               -- main chat UI (:ApolloChat / :ApolloQuit)
load('apollo.apolloMenu')    -- floating command picker
load('apollo.implAgent')     -- implementation wizard

-- RAG indexer ---------------------------------------------------------------
load('apollo.ragIndexer', {
  projectName   = vim.fn.fnamemodify(vim.fn.getcwd(), ':t'), -- default: folder name
  embeddingDim  = 256,                                       -- Gemma-3 dim
  embedEndpoint = 'http://127.0.0.1:8080/v1/embeddings',     -- local embeddings
})
