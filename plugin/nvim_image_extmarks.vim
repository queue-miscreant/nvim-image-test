if !has("nvim")
  echohl ErrorMsg
  echom "nvim-image-extmarks: Plugin not supported outside of nvim."
  echohl
  finish
endif

if exepath("tty") == ""
  echohl ErrorMsg
  echom "nvim-image-extmarks: Command `tty` not found. Cannot run plugin."
  echohl
  finish
endif

let g:image_extmarks_allow_virtual = 0
if has("nvim-0.10")
  let g:image_extmarks_allow_virtual = 1
endif

" Command used for invoking ImageMagick
let magick_default = "magick"
if exepath(magick_default) == ""
  let magick_default = "convert"
endif

" Can acquire TIOCGWINSZ from Python
let g:image_extmarks_ioctl_magic = get(g:, "image_extmarks_ioctl_magic", 1)
if g:image_extmarks_ioctl_magic
  let TIOCGWINSZ = 0
  if has("pythonx")
    let TIOCGWINSZ =
          \ str2nr(
          \   substitute(
          \     execute("python import termios; print(termios.TIOCGWINSZ)"),
          \     "\n",
          \     "",
          \     ""
          \   )
          \ )
  elseif exepath("python")
    let TIOCGWINSZ =
          \ str2nr(
          \   substitute(
          \     system("python -c 'import termios; print(termios.TIOCGWINSZ)'"),
          \     "\n",
          \     "",
          \     ""
          \   )
          \ )
  end

  if TIOCGWINSZ == 0
    echohl WarningMsg
    echom "nvim-image-extmarks: Failed to get value from ioctl magic!"
    echohl
  endif
endif

" Can ascend parent (pseudo)terminals
let g:image_extmarks_parent_tty_magic = get(g:, "image_extmarks_parent_tty_magic", 1)
if g:image_extmarks_parent_tty_magic
  let g:image_extmarks_parent_tty_magic =
        \ exepath("ps") != ""
        \ && exepath("pstree") != ""
        \ && finddir("/dev") != ""
endif

let g:image_extmarks_imagemagick_command = get(g:, "image_extmarks_imagemagick_command", magick_default)
if exepath(g:image_extmarks_imagemagick_command) == ""
  echohl WarningMsg
  echom "nvim-image-extmarks: ImageMagick command not found under `magick` or `convert`!"
  echohl
endif

let g:nvim_image_extmarks_loaded = 1
