-- plugin/apollo.lua  – tiny shim so the repo “just works”
if vim.g.loaded_apollo then return end
vim.g.loaded_apollo = true

-- Safe-load with defaults; users can override via lazy.nvim `opts = {…}`
pcall(function() require('apollo').setup({}) end)
pcall(function() require('apollo.menu').setup({}) end)
