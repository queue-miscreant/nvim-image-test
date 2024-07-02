-- nvim_image_extmarks/sixel_raw.lua
--
-- "Low-level" sixel functions, such as creating blobs, drawing them to the tty,
-- clearing the screen safely, and getting the character height for drawing.

local ffi = require "ffi"

local sixel_raw = {
  tty = nil,
  char_pixel_height = 0,
  screen_cleared = true,
  drawing_enabled = true
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
  if not sixel_raw.drawing_enabled then return end

  pcall(function()
    if sixel_raw.tty == nil then
      sixel_raw.get_tty()
    end

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
  if not sixel_raw.drawing_enabled then return end

  pcall(function()
    if sixel_raw.tty == nil then
      sixel_raw.get_tty()
    end

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


-- Disable drawing blobs.
-- Blobs will still be generated in the background, but the contents will not
-- be pushed to the screen.
--
function sixel_raw.disable_drawing()
  sixel_raw.drawing_enabled = false
end


-- Enable drawing blobs, after having disabled them with `disable_drawing`.
--
function sixel_raw.enable_drawing()
  sixel_raw.drawing_enabled = true
end

return sixel_raw
