if !has("nvim")
  echo "Plugin not supported outside of nvim"
  finish
endif

let g:image_extmarks_allow_virtual = 0
if has("nvim-0.10")
  let g:image_extmarks_allow_virtual = 1
endif

lua require "nvim_image_extmarks"

let g:nvim_image_extmarks_loaded = 1
