-- nvim_image_extmarks/window_drawing.lua
--
-- Sixel drawing functionality, relative to the current window state.


local sixel_raw = require "nvim_image_extmarks.sixel_raw"
local interface = require "nvim_image_extmarks.interface"
local blob_cache = require "nvim_image_extmarks.blob_cache"

pcall(sixel_raw.get_tty)

---@class debounce_data
---@field extmark wrapped_extmark
---@field draw_number integer

local window_drawing = {
  ---@type table<string, debounce_data>
  debounce = {},
  enabled = true,
  just_enabled = true
}


-- Format extmark parameters which influence sixel data.
-- This is the identifier (extmark_id) along with data which can change as windows move
-- around, such as crops.
--
---@param window_id integer
---@param extmark wrapped_extmark
function window_drawing.extmark_cache_entry(window_id, extmark)
  return ("%d.%d.%d.%d"):format(
    window_id,
    extmark.details.id,
    extmark.crop_row_start,
    extmark.crop_row_end
  )
end


---@class window_dimensions
---@field height integer
---@field topline integer Top line of the buffer
---@field botline integer Bottom line of the buffer
---@field winrow integer Start row of the current tabpage
---@field wincol integer Start column of  the current tabpage
---@field textoff integer Sign/number column offset
---@field topfill integer Filler (extmark) lines included at the top of the window

---@return window_dimensions
local function get_windims()
  local wininfo = vim.fn.getwininfo(vim.fn.win_getid())
  local saveview = vim.fn.winsaveview()

  return {
    height = wininfo[1].height,
    topline = wininfo[1].topline,
    botline = wininfo[1].botline,
    winrow = wininfo[1].winrow,
    wincol = wininfo[1].wincol,
    textoff = wininfo[1].textoff,
    topfill = saveview.topfill,
  }
end


-- Convert window coordinates (start_row, end_row) to terminal coordinates
--
---@param start_row wrapped_extmark The row of the buffer to start drawing on
---@param windims window_dimensions The current dimensions of the window
---@param additional_row_offset? integer An optional row offset for drawing the extmark
---@return [integer, integer]
local function window_to_terminal(start_row, windims, additional_row_offset)
  -- default row, for things at the very top of the screen
  local row = 1
  if start_row >= windims.topline then
    local row_offset = vim.api.nvim_win_text_height(
      0,
      { start_row = windims.topline, end_row = start_row }
    ).all
    row = windims.winrow + windims.topfill + row_offset + (additional_row_offset or 0)
  end
  local column = windims.wincol + windims.textoff

  return { row, column }
end


-- Convert inline extmark (with `end_row` set) to `wrapped_extmark`.
-- If the extmark is not visible given the current window window dimensions, returns nil.
--
---@param extmark any Raw extmark object that I don't care to type
---@param windims window_dimensions Window dimensions
---@param buffer_id integer Buffer ID
---@param cursor_line integer Current cursor position
---@return wrapped_extmark | nil
local function inline_extmark(extmark, windims, buffer_id, cursor_line)
  local start_row, end_row = extmark[2], extmark[4].end_row

  -- Not on screen
  if end_row + 1 <= windims.topline or start_row + 1 > windims.botline then
    return nil
  end

  local crop_row_start = math.max(0, windims.topline - 1 - start_row)
  local crop_row_end = math.max(0, end_row - windims.botline + 1)

  local bad_fold = vim.fn.foldclosed(start_row + 1) ~= -1 or vim.fn.foldclosed(end_row + 1) ~= -1
  local cursor_in_extmark = start_row <= cursor_line and cursor_line <= end_row

  if
    (cursor_in_extmark or bad_fold)
    and ( -- No error exists
      vim.b.image_extmark_to_error == nil
      or vim.b.image_extmark_to_error[tostring(extmark[1])] == nil
    )
  then
    return nil
  end

  -- Adjust height by folds and virtual text
  local height = vim.api.nvim_win_text_height(
    0,
    { start_row = start_row, end_row = end_row }
  ).all - 1
  if crop_row_end == height then return nil end

  extmark[4].id = extmark[1]
  extmark[4].ns_id = nil
  return {
    start_row = start_row,
    height = height,
    crop_row_start = crop_row_start,
    crop_row_end = crop_row_end,
    buffer_id = buffer_id,
    details = extmark[4],
    screen_position = window_to_terminal(start_row + crop_row_start, windims)
  }
end


-- Convert virtual lines extmark (with `virt_lines` set) to `wrapped_extmark`.
-- If the extmark is not visible given the current window window dimensions, returns nil.
--
---@param extmark any Raw extmark object that I don't care to type
---@param windims window_dimensions Window dimensions
---@param buffer_id integer Window ID
---@return wrapped_extmark | nil
local function virt_lines_extmark(extmark, windims, buffer_id)
  local start_row, height = extmark[2], #extmark[4].virt_lines

  local crop_row_start = 0
  local crop_row_end = 0

  -- Not on screen
  if start_row + 1 < windims.topline - 1 then
    return nil
  elseif start_row + 1 == windims.topline - 1 then
    -- No filler lines from this
    if windims.topfill == 0 then
      return nil
    end
    -- In very rare circumstances (multiple extmarks on the same line?),
    -- this won't work, but let's not worry about that
    crop_row_start = height - windims.topfill
  -- Extmark at the bottom of the screen
  elseif start_row + 1 == windims.botline then
    -- Calculate the lines missing from the bottom
    local text_height_params = {
      start_row = windims.topline,
      end_row = windims.botline,
    }
    if windims.botline == vim.fn.line("$") then
      text_height_params.end_row = nil
    end
    local overdraw = vim.api.nvim_win_text_height(
      0,
      text_height_params
    ).all

    crop_row_end = overdraw + windims.topfill - windims.height
  -- Not on screen
  elseif start_row + 1 > windims.botline then
    return nil
  end

  local bad_fold = vim.fn.foldclosed(start_row + 1) ~= -1

  if
    bad_fold
    and ( -- No error exists
      vim.b.image_extmark_to_error == nil
      or vim.b.image_extmark_to_error[tostring(extmark[1])] == nil
    )
  then
    return nil
  end
  if crop_row_end == height then return nil end

  extmark[4].id = extmark[1]
  extmark[4].ns_id = nil
  return {
    start_row = start_row,
    height = height - 1,
    crop_row_start = crop_row_start,
    crop_row_end = crop_row_end,
    buffer_id = buffer_id,
    details = extmark[4],
    screen_position = window_to_terminal(start_row + crop_row_start, windims, 1)
  }
end


---@param dims window_dimensions
---@return (wrapped_extmark | nil)[]
function window_drawing.get_visible_extmarks(dims)
  local extmarks = vim.api.nvim_buf_get_extmarks(
    0,
    interface.namespace,
    0,
    -1,
    { details = true }
  )
  local cursor_line = vim.fn.line(".") - 1
  local buffer_id = vim.api.nvim_get_current_buf()

  return vim.tbl_map(function(extmark)
    if extmark[4].virt_lines ~= nil then
      return virt_lines_extmark(extmark, dims, buffer_id)
    else
      return inline_extmark(extmark, dims, buffer_id, cursor_line)
    end
  end, extmarks)
end


---@param extmark wrapped_extmark
---@return [string, [number, number]] | nil
local function lookup_or_generate_blob(extmark)
  local error = vim.b.image_extmark_to_error[tostring(extmark.details.id)]
  local path = vim.b.image_extmark_to_path[tostring(extmark.details.id)]

  if error ~= nil then
    interface.set_extmark_error(
      extmark.details.id,
      error,
      false
    )
    return nil
  end
  if path == nil then
    interface.set_extmark_error(
      extmark.details.id,
      "Could not match extmark to content!"
    )
    return nil
  end

  -- Get rid of the text
  vim.api.nvim_buf_set_extmark(
    0,
    interface.namespace,
    extmark.start_row,
    0,
    extmark.details
  )

  local cache_lookup = blob_cache.get(path, extmark)

  if cache_lookup == nil then
    -- Try to find the file
    if vim.fn.filereadable(path) == 0 then
      interface.set_extmark_error(
        extmark.details.id,
        ("Cannot read file `%s`!"):format(path)
      )
      return nil
    end

    blob_cache.generate_blob(path, extmark)
    return nil
  end

  return {
    cache_lookup,
    extmark.screen_position
  }
end


---@param force boolean
---@return wrapped_extmark[], boolean
function window_drawing.extmarks_needing_update(force)
  -- Get current cached dimensions and newest dimensions
  local window_cache = vim.w.vim_image_window_cache
  local new_dims = get_windims()

  local visible_extmarks = vim.tbl_values(
    window_drawing.get_visible_extmarks(new_dims)
  )

  -- Update cache
  vim.w.vim_image_window_cache = new_dims

  -- TODO: move this outside this function
  if window_drawing.just_enabled then
    window_drawing.just_enabled = false
  end

  local need_clear = force
    or #visible_extmarks > 0 and not vim.deep_equal(new_dims, window_cache) -- Window has moved

  return visible_extmarks, need_clear
end


---@param extmarks (wrapped_extmark | nil)[]
function window_drawing.draw_blobs(extmarks)
  if vim.b.image_extmark_to_path == nil then
    vim.b.image_extmark_to_path = vim.empty_dict()
  end

  if vim.b.image_extmark_to_error == nil then
    vim.b.image_extmark_to_error = vim.empty_dict()
  end

  local blobs = vim.tbl_map(
    lookup_or_generate_blob,
    extmarks
  )

  if window_drawing.enabled then
    blob_cache.fire_pre_draw(extmarks)
    sixel_raw.draw_sixels(blobs)
  end
end


-- Disable drawing blobs.
-- Blobs will still be generated in the background, but the contents will not
-- be pushed to the screen.
--
function window_drawing.disable_drawing()
  window_drawing.enabled = false
  window_drawing.just_enabled = false
end


-- Enable drawing blobs, after having disabled them with `disable_drawing`.
--
function window_drawing.enable_drawing()
  window_drawing.enabled = true
  window_drawing.just_enabled = true
end

return window_drawing
