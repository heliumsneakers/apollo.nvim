-- plugin/apollo.lua  (tiny shim – runs automatically)

if vim.g.loaded_apollo then return end
vim.g.loaded_apollo = true

pcall(function()
	-- main chat UI
	require('apollo').setup({})

	-- floating-menu picker
	require('apollo.apollo-menu').setup()

	-- code snippet implementation agent
	require('apollo.impl-agent').setup()
end
)
