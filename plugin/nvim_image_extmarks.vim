if !has("nvim")
  echo "Plugin not supported outside of nvim"
  finish
endif

let g:image_extmarks_allow_virtual = 0
if has("nvim-0.10")
  let g:image_extmarks_allow_virtual = 1
endif

" Command used for invoking ImageMagick
let magick_default = "magick"
if system(["which", magick_default])[0] != "/"
  let magick_default = "convert"
endif

let g:image_extmarks_imagemagick_command = get(g:, "image_extmarks_imagemagick_command", magick_default)
if system(["which", g:image_extmarks_imagemagick_command])[0] != "/"
  echohl WarningMsg
  echom "ImageMagick command not found under `magick` or `convert`!"
  echohl
endif

lua require "nvim_image_extmarks"

let g:nvim_image_extmarks_loaded = 1
