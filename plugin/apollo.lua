-- plugin/apollo.lua  (tiny shim – runs automatically)

if vim.g.loaded_apollo then return end
vim.g.loaded_apollo = true

pcall(function()
  -- main chat UI
  require('apollo').setup({})

  -- new floating-menu picker  ← add this
  require('apollo.apollo-menu').setup()
end)
