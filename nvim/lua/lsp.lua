local lsp = {
	servers = {
		lua_ls = {
			Lua = {
				workspace = { checkThirdParty = false },
				telemetry = { enable = false },
				diagnostics = {
					globals = {
						"vim",
						"describe",
						"it",
						"before_each",
						"before_all",
						"after_each",
						"after_all",
						"use",
					},
				},
			},
		},
	},
}

function lsp.create_capabilities()
	local cmp_nvim_lsp = require("cmp_nvim_lsp")
	local capabilities = vim.lsp.protocol.make_client_capabilities()
	capabilities = cmp_nvim_lsp.default_capabilities(capabilities)

	return capabilities
end

function lsp.setup_server(server_name, capabilities)
	local lspconfig = require("lspconfig")

	lspconfig[server_name].setup({
		capabilities = capabilities,
		on_attach = function(_, bufnr)
			vim.api.nvim_buf_create_user_command(bufnr, "Format", function()
				vim.lsp.buf.format()
			end, { desc = "Format current buffer with LSP" })
		end,
		settings = lsp.servers[server_name],
	})
end

function lsp.setup_completion()
	local cmp = require("cmp")

	cmp.setup({
		mapping = cmp.mapping.preset.insert({
			["<C-d>"] = cmp.mapping.scroll_docs(-4),
			["<C-f>"] = cmp.mapping.scroll_docs(4),
			["<C-Space>"] = cmp.mapping.complete({}),
			["<CR>"] = cmp.mapping.confirm({
				behavior = cmp.ConfirmBehavior.Replace,
				select = true,
			}),
			["<Tab>"] = cmp.mapping(function(fallback)
				if cmp.visible() then
					return cmp.select_next_item()
				end
				fallback()
			end, { "i", "s" }),
			["<S-Tab>"] = cmp.mapping(function(fallback)
				if cmp.visible() then
					return cmp.select_prev_item()
				end
				fallback()
			end, { "i", "s" }),
		}),
		sources = {
			{ name = "nvim_lsp" },
		},
	})
end

function lsp.init()
	require("mason").setup()
	local mason_lspconfig = require("mason-lspconfig")
	mason_lspconfig.setup({ ensure_installed = {} })

	local capabilities = lsp.create_capabilities()

	mason_lspconfig.setup_handlers({
		function(server_name)
			lsp.setup_server(server_name, capabilities)
		end,
	})

	lsp.setup_completion()
end

return lsp
