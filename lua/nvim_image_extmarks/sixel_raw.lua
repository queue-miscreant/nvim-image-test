-- nvim_image_extmarks/sixel_raw.lua
--
-- "Low-level" sixel functions, such as creating blobs, drawing them to the tty,
-- clearing the screen safely, and getting the character height for drawing.

local ffi = require "ffi"

---@class extmark_details
---@field id integer
---@field end_row? integer
---@field virt_lines? [string, string][][]

---@class wrapped_extmark
---@field start_row integer
---@field height integer
---@field crop_row_start integer
---@field crop_row_end integer
---@field buffer_id integer
---@field details extmark_details
---@field screen_position [integer, integer]

local sixel_raw = {
  tty = nil,
  char_pixel_height = 0,
  screen_cleared = true
}

-- Ideally, this would be imported, but alas
local TIOCGWINSZ = 0x5413

-- ioctl definition
ffi.cdef [[
struct winsize {
  unsigned short ws_row;
  unsigned short ws_col;
  unsigned short ws_xpixel;
  unsigned short ws_ypixel;
};
int ioctl(int fd, int cmd, ...);
]]


-- Perform the above ioctl operation and calculate the height of a character in pixels
--
---@return number
function sixel_raw.get_pixel_height()
  local buf = ffi.new("struct winsize")
  ffi.C.ioctl(1, TIOCGWINSZ, buf)

  if buf.ws_ypixel > 2 then
    sixel_raw.char_pixel_height = math.floor(buf.ws_ypixel / buf.ws_row)
  end
  return 28
end


-- Acquire the tty filename and store it for use later
function sixel_raw.get_tty()
  local proc = assert(io.popen("tty"))
  local tty_name = proc:read()
  proc:close()

  sixel_raw.tty = tty_name
end


-- Draw a sixel to the display
-- Move the cursor to (row, column) (1-indexed), draw the blob, then reset the cursor position
--
---@param blob string
---@param winpos [integer, integer]
function sixel_raw.draw_sixel(blob, winpos)
  if sixel_raw.tty == nil then
    sixel_raw.get_tty()
  end

  pcall(function()
    local stdout = assert(io.open(sixel_raw.tty, "ab"))
    stdout:write(("\x1b[s\x1b[%d;%dH"):format(winpos[1], winpos[2]))
    stdout:write(blob)
    stdout:write("\x1b[u")
    stdout:close()
  end)

  sixel_raw.screen_cleared = false
end


-- The same thing as draw_sixel, but operating on a table of blob, position pairs
--
---@param blob_ranges [string, [integer, integer]][]
function sixel_raw.draw_sixels(blob_ranges)
  if sixel_raw.tty == nil then
    vim.notify("Could not find the terminal device!", 3, {})
    return
  end

  pcall(function()
    local stdout = assert(io.open(sixel_raw.tty, "ab"))
    stdout:write("\x1b[s")

    for _, blob_range in pairs(blob_ranges) do
      local winpos = blob_range[2]
      stdout:write(("\x1b[%d;%dH"):format(winpos[1], winpos[2]))
      stdout:write(blob_range[1])
    end

    stdout:write("\x1b[u")
    stdout:close()
  end)

  sixel_raw.screen_cleared = false
end


-- Clear the screen of all sixel characters
-- This should also work in tmux, where sixel images can appear "sticky"
--
function sixel_raw.clear_screen()
  if sixel_raw.screen_cleared then return end
  -- clear screen with :mode
  vim.cmd("mode")
  -- clear tmux with tmux detach -E "tmux attach -t (session number)"
  local _, _, _, tmux_pid, tmux_session = tostring(vim.env.TMUX):find("(.+),(%d+),(%d+)")
  if tmux_session ~= nil then
    vim.fn.system(("tmux detach -E 'tmux attach -t %s'"):format(tmux_session))
  end
  sixel_raw.screen_cleared = true
end


-- Convert extmark parameters into a sixel blob by starting an ImageMagick subprocess.
--
---@param extmark wrapped_extmark A wrapped extmark, containing height and crop data (in rows)
---@param filepath string A path to a file, from which the image blob is generated
---@param callback fun(blob: string): any A callback function which is called with the generated blob
---@param error_callback? fun(errors: string): any An optional callback function, called with error information
function sixel_raw.blobify(
  extmark,
  filepath,
  callback,
  error_callback
)
  -- resize to a suitable height
  local resize = ("x%d"):format(extmark.height * sixel_raw.char_pixel_height)
  -- crop to the right size
  local crop = ("x%d+0+%d"):format(
    (extmark.height - extmark.crop_row_start - extmark.crop_row_end) * sixel_raw.char_pixel_height,
    extmark.crop_row_start * sixel_raw.char_pixel_height
  )

  local stdout = vim.loop.new_pipe()
  local stderr = vim.loop.new_pipe()
  vim.loop.spawn("magick", {
    args = {
      filepath .. "[0]",
      "-resize",
      resize,
      "-crop",
      crop,
      "sixel:-"
    },
    stdio = {nil, stdout, stderr},
    detached = true
  })

  -- Run ImageMagick command
  local sixel = {}
  stdout:read_start(function(err, data)
    assert(not err, err)
    if data == nil then
      callback(table.concat(sixel, ""))
      return
    end
    table.insert(sixel, data)
  end)

  local error_ = ""
  stderr:read_start(function(err, data)
    assert(not err, err)
    if data == nil then
      if error_callback ~= nil then error_callback(data) end
      return
    end
    error_ = error_ .. "\n" .. data
  end)
end

return sixel_raw
