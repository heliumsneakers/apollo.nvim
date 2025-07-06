-- plugin/apollo.lua ---------------------------------------------------------
if vim.g.loaded_apollo then return end
vim.g.loaded_apollo = true

-- enhanced loader: pass opts table when given
local function load(mod, opts)
  local ok, modret = pcall(require, mod)      -- <- renamed to modret

  if not ok then
    vim.notify('[apollo.nvim] '..modret, vim.log.levels.ERROR)
    return
  end

  if type(modret) == 'table' and type(modret.setup) == 'function' then
    local ok2, err = pcall(modret.setup, opts)
    if not ok2 then
      vim.notify('[apollo.nvim] '..err, vim.log.levels.ERROR)
    end
  end
end

-- core UI pieces ------------------------------------------------------------
load('apollo')               -- main chat UI (:ApolloChat / :ApolloQuit)
load('apollo.menu')    -- floating command picker
load('apollo.context_chat')     -- implementation wizard
load('apollo.documenter')

-- RAG indexer ---------------------------------------------------------------
load('apollo.indexer', {
  projectName   = vim.fn.fnamemodify(vim.fn.getcwd(), ':t'), -- default: folder name
  embeddingDim  = 256,                                       -- Gemma-3 dim
  embedEndpoint = 'http://127.0.0.1:8080/v1/embeddings',     -- local embeddings
})
