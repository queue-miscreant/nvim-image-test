-- nvim_image_extmarks/sixel_raw.lua
--
-- Low-level terminal functions. Primarily involves drawing sixels to the tty,
-- clearing the screen safely, and getting the character height for drawing.

local ffi = require "ffi"

local sixel_raw = {
  ---@type string|nil
  tty = nil,
  ---@type string[]|nil
  parent_ttys = nil,
  ---@type string|nil
  tmux_pid = nil,
  ---@type string|nil
  tmux_session = nil,
  ---@type integer
  char_pixel_height = 0,
  ---@type boolean
  screen_cleared = true,
  ---@type boolean
  drawing_enabled = true,
}

-- This is the default value in Linux (and other kernels),
-- but can also be derived from the Python installation
local TIOCGWINSZ = vim.g.image_extmarks_TIOCGWINSZ
if TIOCGWINSZ == nil then
  TIOCGWINSZ =  0x5413
end

-- ioctl definition
ffi.cdef [[
struct winsize {
  unsigned short ws_row;
  unsigned short ws_col;
  unsigned short ws_xpixel;
  unsigned short ws_ypixel;
};
int ioctl(int fd, int cmd, ...);

int fileno(struct FILE* stream);
]]

-- Get the parent terminals of the current process
--
---@param exclude_tty string TTY device to exclude from the returned list
---@return string[]
local function get_parent_terminals(exclude_tty)
  -- Call pstree to get parent processes (and their PIDs)
  local file = io.popen("pstree $$ -s -p -A")
  if file == nil then return {} end
  local pstree = file:read("l")
  file:close()

  local tree = vim.split(pstree, "---")
  local pids = {}
  for _, process in ipairs(tree) do
    local pid = process:match(".+%((%d+)%)")
    if pid then
      table.insert(pids, pid)
    end
  end

  local ptys = {}
  local last_tty = ""
  -- Ascend the process tree and request its TTY device
  for i = #pids, 1, -1 do
    file = io.popen("ps -o tty= -p " .. pids[i])
    if file ~= nil then
      local ps = file:read("l")
      file:close()

      if ps and ps ~= "?" then
        ps = "/dev/" .. ps
        if ps ~= last_tty and ps ~= exclude_tty then
          table.insert(ptys, ps)
          last_tty = ps
        end
      end
    end
  end

  return ptys
end


-- Acquire the tty filename and store it for use later
-- Also acquires parent terminals, in case pixel heights of 0 are reported.
--
function sixel_raw.fetch_ttys()
  local proc = assert(io.popen("tty"))
  local tty_name = proc:read()
  proc:close()

  sixel_raw.tty = tty_name

  -- Find tmux process
  local _, _, _, tmux_pid, tmux_session = tostring(vim.env.TMUX):find("(.+),(%d+),(%d+)")
  sixel_raw.tmux_pid = tmux_pid
  sixel_raw.tmux_session = tmux_session

  -- Option turned off
  if vim.g.image_extmarks_parent_tty_magic == 0 then
    return
  end
  -- Find parent terminals
  sixel_raw.parent_ttys = get_parent_terminals(tty_name)
end


-- Perform an ioctl operation and calculate the height of a character in pixels
--
---@param fd integer The file descriptor to perform the operation on
---@return integer
local function get_pixel_height(fd)
  local buf = ffi.new("struct winsize")
  ffi.C.ioctl(fd, TIOCGWINSZ, buf)

  if buf.ws_ypixel > 2 then
    return math.floor(buf.ws_ypixel / buf.ws_row)
  end
  return 0
end


-- Grab the terminal height, either naively on stdout, or by looking on parent terminals
function sixel_raw.fetch_height()
  if sixel_raw.tty == nil then
    sixel_raw.fetch_ttys()
  end

  -- Get height from stdout
  local naive = get_pixel_height(1)
  if naive ~= 0 then
    sixel_raw.char_pixel_height = naive
    return
  end

  -- Option turned off
  if sixel_raw.parent_ttys == nil then
    return
  end

  -- Open each parent (pseudo)terminal, send ioctl
  for _, terminal in ipairs(sixel_raw.parent_ttys) do
    local device = io.open(terminal)
    if device ~= nil then
      local fd = ffi.C.fileno(device)
      local height = get_pixel_height(fd)
      device:close()
      if height ~= 0 then
        sixel_raw.char_pixel_height = height
        return
      end
    end
  end
end


-- Draw a sixel blob to the display
-- Move the cursor to (row, column) (1-indexed), draw the blob, then reset the cursor position
--
---@param blob string
---@param winpos [integer, integer]
function sixel_raw.draw_sixel(blob, winpos)
  if not sixel_raw.drawing_enabled then return end

  pcall(function()
    if sixel_raw.tty == nil then
      sixel_raw.fetch_ttys()
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
      sixel_raw.fetch_tty()
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
  if sixel_raw.tmux_session ~= nil then
    vim.fn.system(("tmux detach -E 'tmux attach -t %s'"):format(sixel_raw.tmux_session))
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
