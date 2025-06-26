-- plugin/apollo.lua
if vim.g.loaded_apollo then return end
vim.g.loaded_apollo = true

local function load(mod)
  local ok, pack = pcall(require, mod)
  if not ok then
    vim.notify('[apollo.nvim] '..pack, vim.log.levels.ERROR)
    return
  end
  if type(pack.setup) == 'function' then
    local ok2, err = pcall(pack.setup)
    if not ok2 then
      vim.notify('[apollo.nvim] '..err, vim.log.levels.ERROR)
    end
  end
end

load('apollo')               -- main chat UI
load('apollo.apollo_menu')    -- menu (works)
load('apollo.impl_agent')     -- Implementation agent
