-- plugin/apollo.lua ---------------------------------------------------------
if vim.g.loaded_apollo then return end
vim.g.loaded_apollo = true

-- enhanced loader: pass opts table when given
local function load(mod, opts)
  local ok, pack = pcall(require, mod)
  if not ok then
    vim.notify('[apollo.nvim] '..pack, vim.log.levels.ERROR)
    return
  end
  if type(pack.setup) == 'function' then
    local ok2, err = pcall(pack.setup, opts)
    if not ok2 then
      vim.notify('[apollo.nvim] '..err, vim.log.levels.ERROR)
    end
  end
end

-- core UI pieces ------------------------------------------------------------
load('apollo')               -- main chat UI (:ApolloChat / :ApolloQuit)
load('apollo.apolloMenu')    -- floating command picker
load('apollo.implAgent')     -- implementation wizard
load('apollo.howto-agent')   -- “How-to” outline helper  (add if not already)

-- RAG indexer ---------------------------------------------------------------
load('apollo.ragIndexer', {
  projectName   = vim.fn.fnamemodify(vim.fn.getcwd(), ':t'), -- default: folder name
  embeddingDim  = 256,                                       -- Gemma-3 dim, exposing this so it can be changed later if new models release.
  embedEndpoint = 'http://127.0.0.1:8080/v1/embeddings',     -- local embeddings
})
