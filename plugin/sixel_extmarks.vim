if !has("nvim")
  echohl ErrorMsg
  echom "nvim-image-extmarks: Plugin not supported outside of nvim."
  echohl
  finish
endif

autocmd VimEnter * lua if not package.loaded.lazy then require("sixel_extmarks").setup({}) end
