-- nvim_image_extmarks.lua
--
-- Functions providing a consistent interface to the management of sixel extmarks.

local interface = require "nvim_image_extmarks.interface"
local sixel_raw = require "nvim_image_extmarks.sixel_raw"
local window_drawing = require "nvim_image_extmarks.window_drawing"
local blob_cache = require "nvim_image_extmarks.blob_cache"

local extmark_timer = nil
assert(
  (
    type(vim.g.image_extmarks_buffer_ms) == "number" or
    type(vim.g.image_extmarks_buffer_ms) == "nil"
  ),
  "g:image_extmarks_buffer_ms must be a number"
)


-- Namespace for plugin functions
--
---@diagnostic disable-next-line
sixel_extmarks = {}


-- Add autocommands which depend on buffer contents and window positions
--
local function bind_local_autocmds()
  vim.api.nvim_create_autocmd({ "CursorMoved", "TextChanged", "TextChangedI" }, {
    group = "ImageExtmarks",
    buffer = 0,
    callback = function() sixel_extmarks.redraw() end
  })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = "ImageExtmarks",
    buffer = 0,
    callback = function()
      if not vim.g.image_extmarks_slow_insert then
        return
      end

      sixel_raw.disable_drawing()
      sixel_raw.clear_screen()
    end
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = "ImageExtmarks",
    buffer = 0,
    callback = function()
      if not vim.g.image_extmarks_slow_insert then
        return
      end

      sixel_raw.enable_drawing()
    end
  })
  vim.b.bound_autocmds = true
end


-- Create a new image extmark in the current buffer.
--
---@param start_row integer The (0-indexed) row of the buffer that the image begins on
---@param end_row integer The (0-indexed) row of the buffer that the image ends on
---@param path string A path to the file content
---@return integer
function sixel_extmarks.create(start_row, end_row, path)
  local id = interface.create_image(start_row, end_row, path)

  -- Bind extmarks if we need to
  if (
    vim.b.image_extmark_to_path ~= nil and
    vim.tbl_count(vim.b.image_extmark_to_path) > 0 and
    not vim.b.bound_autocmds
  ) then
    bind_local_autocmds()
  end

  sixel_extmarks.redraw()

  return id
end


-- Create a new image extmark in the current buffer.
--
---@param start_row integer The (0-indexed) row of the buffer that the image begins on
---@param height integer The height of the extmark
---@param path string A path to the file content
---@return integer
function sixel_extmarks.create_virtual(start_row, height, path)
  local id = interface.create_image_virtual(start_row, height, path)

  -- Bind extmarks if we need to
  if (
    vim.b.image_extmark_to_path ~= nil and
    vim.tbl_count(vim.b.image_extmark_to_path) > 0 and
    not vim.b.bound_autocmds
  ) then
    bind_local_autocmds()
  end

  sixel_extmarks.redraw()

  return id
end


-- Create an "image" extmark in the current buffer which displays an error,
-- but can be updated later to hold an image.
--
---@param start_row integer The (0-indexed) row of the buffer that the image would end on
---@param end_row integer The (0-indexed) row of the buffer that the image would end on
---@param error_text string The error text to display
---@return integer
function sixel_extmarks.create_error(start_row, end_row, error_text)
  return interface.create_error(start_row, end_row, error_text)
end


-- Retrieve a list of extmarks in the current buffer between the given rows.
-- To retrieve all extmarks in the current buffer, use parameters (0, -1).
--
---@param start_row integer The (0-indexed) row to start searching from
---@param end_row integer
---@return image_extmark[]
function sixel_extmarks.get(start_row, end_row)
  return interface.get_image_extmarks(start_row, end_row)
end

-- Retrieve an extmark in the current buffer with the given id.
--
---@param id integer The id of the extmark
---@return image_extmark|nil
function sixel_extmarks.get_by_id(id)
  return interface.get_image_extmark_by_id(id)
end


-- Delete the extmark in the current buffer.
-- Note that this will NOT remove blobs from the cache.
--
---@param id integer The id of the extmark to remove
function sixel_extmarks.remove(id)
  local ret = interface.remove_image_extmark(id)
  sixel_extmarks.redraw()

  return ret
end


-- Delete all extmarks in the current buffer.
-- The same caveat about the cache applies here as well.
--
---@see sixel_extmarks.remove
function sixel_extmarks.remove_all()
  local ret = interface.remove_images()
  sixel_extmarks.redraw()

  return ret
end


-- Move the extmark identified by {id} so that the image stretches
-- starting at row {start_row} of the buffer and ends at {end_row}.
-- Be aware that this can resize the image.
--
---@param id integer
---@param start_row integer
---@param end_row integer
function sixel_extmarks.move(id, start_row, end_row)
  local ret = interface.move_extmark(id, start_row, end_row)
  sixel_extmarks.redraw()

  return ret
end


-- Change the content of an extmark.
--
---@param id integer The id of the extmark to modify.
---@param path string The path to the file containing the new content.
function sixel_extmarks.change_content(id, path)
  local ret = interface.change_extmark_content(id, path)
  sixel_extmarks.redraw()

  return ret
end


-- Clear the sixel cache.
-- If no arguments are supplied, the entire cache is cleared.
-- Otherwise, either a file path or list of file paths can be supplied.
-- If these paths have entries in the cache, they will be cleared.
--
---@param path? (string | string[])
function sixel_extmarks.clear_cache(path)
  interface.clear_cache(path)
end


-- Clear all content drawn to the screen. Unlike :mode in vim,
-- this has the additional guarantee of working inside a tmux session.
function sixel_extmarks.clear_screen()
  sixel_raw.clear_screen()
end


-- Draw all extmark content on the screen.
--
---@param force? boolean Force redraw
function sixel_extmarks.redraw(force)
  -- Update the pixel height if this is a forced redraw
  if force then
    sixel_raw.get_pixel_height()
  end

  local windows = vim.api.nvim_tabpage_list_wins(0)

  local previous_extmarks = vim.t.previous_extmarks
  if previous_extmarks == nil then
    previous_extmarks = {}
  end

  local need_clear = false
  local new_extmarks = {}
  local new_count = 0

  ---@type wrapped_extmark[]
  local draw_accum = {}
  ---@type wrapped_extmark[]
  local lazy_draw_accum = {}

  for _, window in pairs(windows) do
    vim.api.nvim_win_call(window, function()
      local extmarks_to_draw, need_clear_window = window_drawing.extmarks_needing_update(
        force or false
      )
      need_clear = need_clear or need_clear_window

      for _, extmark in pairs(extmarks_to_draw) do
        local cache_entry = window_drawing.extmark_cache_entry(window, extmark)
        new_extmarks[cache_entry] = true
        table.insert(draw_accum, extmark)

        -- Add to the lazy list if we didn't draw it previously
        if previous_extmarks[cache_entry] == nil then
          table.insert(lazy_draw_accum, extmark)
          new_count = new_count + 1
        end
      end
    end)
  end

  for cache_entry, _ in pairs(previous_extmarks) do
    -- If we're not drawing an extmark that was drawn previously, clear the screen
    need_clear = need_clear or new_extmarks[cache_entry] == nil
  end

  local timer = vim.g.image_extmarks_buffer_ms or 0
  if need_clear then
    sixel_raw.clear_screen()
  -- Nothing to draw, and not about to draw
  elseif new_count == 0 then
    return
  elseif extmark_timer == nil then
    timer = 0
  end

  -- Update the drawn extmarks now, for future redraws
  vim.t.previous_extmarks = new_extmarks

  -- "Renew" the timer by cancelling it first
  if extmark_timer ~= nil then
    pcall(function()
      extmark_timer:stop()
      extmark_timer:close()
    end)
  end
  extmark_timer = vim.loop.new_timer()

  extmark_timer:start(
    timer,
    0,
    vim.schedule_wrap(function()
      pcall(function()
        extmark_timer:stop()
        extmark_timer:close()
      end)

      if sixel_raw.screen_cleared then
        blob_cache.draw(draw_accum)
      else
        blob_cache.draw(lazy_draw_accum)
      end
    end)
  )
end


-- Set error text on an extmark.
--
---@param id integer The id of the extmark
---@param error_text string The error text to display
function sixel_extmarks.set_extmark_error(id, error_text)
  interface.set_extmark_error(id, error_text)
  sixel_extmarks.redraw()
end


-- Disable drawing blobs.
-- Blobs will still be generated in the background, but the contents will not
-- be pushed to the screen.
--
function sixel_extmarks.disable_drawing()
  sixel_raw.disable_drawing()
end


-- Enable drawing blobs, after having disabled them with `sixel_extmarks.disable_drawing`.
--
---@param redraw? boolean Whether or not to redraw the screen afterward. True if not given.
function sixel_extmarks.enable_drawing(redraw)
  sixel_raw.enable_drawing()
  if redraw == nil or redraw then
    sixel_extmarks.redraw(true)
  end
end


-- Generate a snapshot of the blob cache.
-- Rather than the cache, the first two layers of keys are returned, i.e.,
-- a table with filenames as keys and buffer ranges as values.
--
function sixel_extmarks.dump_blob_cache()
  return blob_cache.dump()
end


vim.api.nvim_create_user_command(
  'CreateImage',
  function(opts)
    sixel_extmarks.create(
      opts.line1 - 1,
      opts.line2 - 1,
      opts.args
    )
  end,
  { nargs = 1, range = 2, complete = "file" }
)

vim.api.nvim_create_augroup("ImageExtmarks", { clear = false })
vim.api.nvim_create_augroup("ImageExtmarks#pre_draw", { clear = false })

vim.api.nvim_create_autocmd(
  "WinScrolled",
  {
    group = "ImageExtmarks",
    callback = function() sixel_extmarks.redraw() end
  }
)

vim.api.nvim_create_autocmd(
  "WinResized",
  {
    group = "ImageExtmarks",
    callback = function()
      local total = 0
      for _, win in pairs(vim.v.event.windows) do
        total = total + #vim.api.nvim_buf_get_extmarks(
          vim.api.nvim_win_get_buf(win),
          interface.namespace,
          0,
          -1,
          {}
        )
      end
      if total > 0 then
        sixel_extmarks.redraw(true)
      end
    end
  }
)

vim.api.nvim_create_autocmd(
  {
    "VimEnter",
    "VimResized",
  },
  {
    group = "ImageExtmarks",
    callback = function() sixel_extmarks.redraw(true) end
  }
)

-- Vim quirk: attempting to redraw at TabEnter after TabNew will use the
-- previous buffer (but the new window), since BufEnter has not happened yet
--
-- So don't bother redrawing a new tab is created
vim.api.nvim_create_autocmd(
  "TabNew",
  {
    group = "ImageExtmarks",
    callback = function() sixel_extmarks.creating_tab = true end
  }
)
vim.api.nvim_create_autocmd(
  {
    "TabEnter",
    "TabClosed"
  },
  {
    group = "ImageExtmarks",
    callback = function()
      if sixel_extmarks.creating_tab ~= nil then
        sixel_extmarks.creating_tab = nil
        return
      end

      sixel_extmarks.redraw(true)
    end
  }
)

vim.api.nvim_create_autocmd(
  {
    "TabLeave",
    "ExitPre"
  },
  {
    group = "ImageExtmarks",
    callback = function() sixel_extmarks.clear_screen() end
  }
)
