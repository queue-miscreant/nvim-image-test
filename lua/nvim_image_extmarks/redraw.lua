local sixel_raw = require "nvim_image_extmarks.sixel_raw"
local blobber = require "nvim_image_extmarks.blobber"
local window_drawing = require "nvim_image_extmarks.window_drawing"

local loop = vim.uv
if loop == nil then loop = vim.loop end

local redraw_timer = nil
local lazy_accumulator = {}

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
  local new_extmarks = {}
  local new_count = 0

  -- TODO: lazy drawing needs to accumulate!

  ---@type wrapped_extmark[]
  local draw_accum = {}

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
        if previous_extmarks[cache_entry] == nil and queued_extmarks[cache_entry] == nil then
          queued_extmarks[cache_entry] = true
          table.insert(lazy_accumulator, extmark)
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

      if sixel_raw.screen_cleared then
        blobber.draw(draw_accum)
      else
        blobber.draw(lazy_accumulator)
      end
      lazy_accumulator = {}
      vim.api.nvim_tabpage_set_var(current_tabpage, "image_extmarks_drawn", new_extmarks)
      pcall(function() vim.api.nvim_tabpage_del_var(current_tabpage, "image_extmarks_queued") end)
    end)
  )
end

return redraw
