-- sixel_extmarks/redraw.lua
--
-- Primary redraw function. Implements general caching for each tabpage
-- for lazy redraws which minimize screen clears.

local sixel_raw = require "sixel_extmarks.sixel_raw"
local blobber = require "sixel_extmarks.blobber"
local window_drawing = require "sixel_extmarks.window_drawing"

local loop = vim.uv
if loop == nil then loop = vim.loop end

local redraw_timer = nil

-- Format extmark parameters which influence sixel data.
-- This is the identifier (extmark_id) along with data which can change as windows move
-- around, such as crops.
--
---@param window_id integer
---@param extmark wrapped_extmark
local function extmark_cache_entry(window_id, extmark)
  return ("%d.%d.%d.%d"):format(
    window_id,
    extmark.details.id,
    extmark.crop_row_start,
    extmark.crop_row_end
  )
end

-- Draw all extmark content on the screen.
--
---@param force? boolean Force redraw
---@param resized? boolean Reacquire terminal height
local function redraw(force, resized)
  -- Update the pixel height if this is a forced redraw
  if resized then
    sixel_raw.fetch_height()
  end

  local windows = vim.api.nvim_tabpage_list_wins(0)

  local queued_extmarks = vim.t.image_extmarks_queued or {}
  local previous_extmarks = vim.t.image_extmarks_drawn or {}

  local need_clear = false
  ---@type {[string]: wrapped_extmark}
  local new_extmarks = {}
  local new_count = 0

  for _, window in pairs(windows) do
    vim.api.nvim_win_call(window, function()
      local extmarks_to_draw, need_clear_window = window_drawing.extmarks_needing_update(
        force or false
      )
      need_clear = need_clear or need_clear_window

      for _, extmark in pairs(extmarks_to_draw) do
        local cache_entry = extmark_cache_entry(window, extmark)
        new_extmarks[cache_entry] = extmark

        -- Add to the lazy list if we didn't draw it previously
        if previous_extmarks[cache_entry] == nil and queued_extmarks[cache_entry] == nil then
          queued_extmarks[cache_entry] = extmark
          -- table.insert(lazy_accumulator, extmark)
          new_count = new_count + 1
        end
      end
    end)
  end

  for cache_entry, _ in pairs(previous_extmarks) do
    -- If we're not drawing an extmark that was drawn previously, clear the screen
    need_clear = need_clear or new_extmarks[cache_entry] == nil
  end

  local timer = tonumber(vim.g.image_extmarks_buffer_ms) or 0
  if need_clear then
    blobber.clear_running()
    sixel_raw.clear_screen()
  -- Nothing to draw, and not about to draw
  elseif new_count == 0 then
    return
  -- elseif redraw_timer == nil then
  --   timer = 0
  end

  -- Update the queued extmarks for future redraws
  vim.t.image_extmarks_queued = queued_extmarks

  -- "Renew" the timer by cancelling it first
  if redraw_timer ~= nil then
    pcall(function()
      redraw_timer:stop()
      redraw_timer:close()
    end)
  end
  redraw_timer = loop.new_timer()

  local current_tabpage = vim.api.nvim_get_current_tabpage()
  redraw_timer:start(
    timer,
    0,
    vim.schedule_wrap(function()
      pcall(function()
        redraw_timer:stop()
        redraw_timer:close()
      end)

      local new_drawn
      local drawn_synchronous
      if sixel_raw.screen_cleared then
        drawn_synchronous = blobber.draw(new_extmarks, redraw)
        new_drawn = {}
      else
        drawn_synchronous = blobber.draw(queued_extmarks, redraw)
        local ok
        ok, new_drawn = pcall(function() return vim.api.nvim_tabpage_get_var(current_tabpage, "image_extmarks_drawn") end)
        if not ok then new_drawn = {} end
      end

      for i = 1, #drawn_synchronous do
        new_drawn[drawn_synchronous[i]] = true
      end
      -- Push updates to variable
      vim.api.nvim_tabpage_set_var(current_tabpage, "image_extmarks_drawn", new_drawn)
      pcall(function() vim.api.nvim_tabpage_del_var(current_tabpage, "image_extmarks_queued") end)
    end)
  )
end

return redraw
