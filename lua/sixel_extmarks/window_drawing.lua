-- sixel_extmarks/window_drawing.lua
--
-- Gather information about current extmark positions, relative to the current window.

local config = require "sixel_extmarks.config"
local interface = require "sixel_extmarks.interface"

local window_drawing = {}

---@type fun(window_id: integer, y: text_height_params): { all: integer, fill: integer }
local text_height
if vim.api.nvim_win_text_height ~= nil then
  text_height = vim.api.nvim_win_text_height
else
  -- Polyfill that can't take virtual lines into account
  text_height = function(_, params)
    return { all = params.end_row - params.start_row + 1, fill = 0 }
  end
end


---@return window_dimensions
local function get_windims()
  local wininfo = vim.fn.getwininfo(vim.fn.win_getid())
  local saveview = vim.fn.winsaveview()

  return {
    height = wininfo[1].height,
    width = wininfo[1].width,
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
---@param start_row integer The row of the buffer to start drawing on
---@param windims window_dimensions The current dimensions of the window
---@param additional_row_offset? integer An optional row offset for drawing the extmark
---@return [integer, integer]
local function window_to_terminal(start_row, windims, additional_row_offset)
  -- default row, for things at the very top of the screen
  local row = windims.winrow
  local row_offset = 0
  if start_row >= windims.topline then
    row_offset = text_height(
      0,
      { start_row = windims.topline, end_row = start_row }
    ).all
  end

  return {
    row + windims.topfill  -- Virtual text lines
      + row_offset  -- Text height from the top of the window
      + (additional_row_offset or 0)  -- Virtual/inline offset
      - (vim.fn.foldclosed(windims.topline) ~= -1 and 1 or 0),  -- Correction for when a fold is at the top of the screen
    windims.wincol + windims.textoff
  }
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
  if end_row == nil or end_row + 1 <= windims.topline or start_row + 1 > windims.botline then
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
  local height = text_height(
    0,
    { start_row = start_row, end_row = end_row }
  ).all - 1
  if crop_row_end == height then return nil end

  extmark[4].id = extmark[1]
  extmark[4].ns_id = nil
  return {
    start_row = start_row,
    height = height,
    max_width = windims.width - windims.textoff,
    crop_row_start = crop_row_start,
    crop_row_end = crop_row_end,
    buffer_id = buffer_id,
    details = extmark[4],
    path = vim.b.image_extmark_to_path[tostring(extmark[1])],
    error = vim.b.image_extmark_to_error[tostring(extmark[1])],
    screen_position = window_to_terminal(
      start_row + crop_row_start,
      windims
    )
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
  local draw_offset = 1

  -- Not on screen
  if start_row + 1 < windims.topline - 1 then
    return nil
  elseif start_row + 1 == windims.topline - 1 then
    -- No filler lines from this
    if windims.topfill == 0 or windims.topfill == 1 then
      return nil
    end

    -- In very rare circumstances (multiple extmarks on the same line?),
    -- this won't work, but let's not worry about that
    crop_row_start = height - windims.topfill
    draw_offset = -windims.topfill

  -- Extmark at the bottom of the screen
  elseif start_row == windims.botline - 1 then
    -- Calculate the lines missing from the bottom
    local text_height_params = {
      start_row = windims.topline,
      end_row = windims.botline,
    }

    if windims.botline == vim.fn.line("$") then
      text_height_params.end_row = nil
    end
    local overdraw = text_height(
      0,
      text_height_params
    ).all

    crop_row_end = overdraw + windims.topfill - windims.height + 1
    -- No filler lines from this
    if crop_row_end >= height - 1 then
      return nil
    end
  -- Not on screen
  elseif start_row > windims.botline - 1 then
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
    max_width = windims.width - windims.textoff,
    crop_row_start = crop_row_start,
    crop_row_end = crop_row_end,
    buffer_id = buffer_id,
    details = extmark[4],
    path = vim.b.image_extmark_to_path[tostring(extmark[1])],
    error = vim.b.image_extmark_to_error[tostring(extmark[1])],
    screen_position = window_to_terminal(
      start_row,
      windims,
      draw_offset
    )
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
    ---@type wrapped_extmark | nil
    local ret
    if extmark[4].virt_lines ~= nil then
      ret = virt_lines_extmark(extmark, dims, buffer_id)
    else
      ret = inline_extmark(extmark, dims, buffer_id, cursor_line)
    end

    if ret then
      -- Is the image height drawable, as set by the user?
      local crop_size = ret.crop_row_start + ret.crop_row_end
      local image_height = ret.height - crop_size
      if
        image_height >= config.min_cropped_height
        and not (
          config.min_cropped_height < 0
          and crop_size > 0
        )
      then
        return ret
      end
    end
  end, extmarks)
end


---@param force boolean
---@return wrapped_extmark[], boolean
function window_drawing.extmarks_needing_update(force)
  if vim.b.image_extmark_to_path == nil then
    vim.b.image_extmark_to_path = vim.empty_dict()
  end

  if vim.b.image_extmark_to_error == nil then
    vim.b.image_extmark_to_error = vim.empty_dict()
  end

  -- Get current cached dimensions and newest dimensions
  local window_cache = vim.w.vim_image_window_cache
  local new_dims = get_windims()

  local visible_extmarks = vim.tbl_values(
    window_drawing.get_visible_extmarks(new_dims)
  )

  -- Update cache
  vim.w.vim_image_window_cache = new_dims

  local need_clear = force
    or #visible_extmarks > 0 and not vim.deep_equal(new_dims, window_cache) -- Window has moved

  return visible_extmarks, need_clear
end


return window_drawing
