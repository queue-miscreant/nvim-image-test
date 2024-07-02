-- nvim_image_extmarks/blob_cache.lua
--
-- A naive two-layer cache for sixel blobs.
-- Blobs are cached by the following characteristics:
--
-- - Layer 1 keys:
--      - Content hash
-- - Layer 2 keys:
--      - Height, in rows
--      - Crop from top of image, in rows
--      - Crop from bottom of image (i.e., number of rows removed, as a full image)

local sixel_raw = require "nvim_image_extmarks.sixel_raw"
local interface = require "nvim_image_extmarks.interface"

---@alias blob_path string
---@alias cache_id string
---@alias extmark_coords number[]

---@class callback_details
---@field screen_position extmark_coords
---@field extmark_id integer
---@field buffer_id integer

local blob_cache = {
  ---@type {[blob_path]: {[cache_id]: string}}
  contents = {},
  ---@type {[blob_path]: {[cache_id]: (nil | callback_details[]) }}
  running = {}
}


---@param extmarks callback_details[]
function blob_cache.fire_pre_draw(extmarks)
  local errored = pcall(function()
    vim.api.nvim_exec_autocmds("User", {
      group = "ImageExtmarks#pre_draw",
      data = extmarks
    })
  end)
  if errored then
    vim.api.nvim_exec_autocmds("User", {
      group = "ImageExtmarks#pre_draw",
    })
  end
end


---@param extmark wrapped_extmark
---@return cache_id
local function extmark_to_cache_id(extmark)
  return ("%d,%d,%d"):format(
    extmark.height,
    extmark.crop_row_start,
    extmark.crop_row_end
  )
end

-- Running cache semantics:
-- If the cache entry is nil, then no process is currently generating that blob
-- If the cache entry is {}, then a runner is generating the blob, but no positions will be drawn with it


-- Forget about all extmark positions from calls to `blob_cache.generate_blob`
-- No extmarks will be drawn when the blobber finishes.
--
function blob_cache.clear_running()
  -- XXX Still need to set the extmark error, even if the running cache doesn't remember it!
  for path, layer2 in pairs(blob_cache.running) do
    for index, _ in pairs(layer2) do
      blob_cache.running[path][index] = nil
    end
  end
end

-- Attempt to generate a blob, if necessary, given an extmark.
---
-- If the blob is already generating, the extmark position
-- will be remembered until the blobber finishes.
---
-- When the blobber finishes, all remembered extmarks since
-- the last `blob_cache.clear_running` will be drawn.
--
---@param path string
---@param extmark wrapped_extmark
function blob_cache.generate_blob(path, extmark)
  local index = extmark_to_cache_id(extmark)

  if blob_cache.running[path] == nil then
    blob_cache.running[path] = {}
  end
  if blob_cache.running[path][index] ~= nil then
    -- Blob is being generated, just remember to draw it later
    table.insert(
      blob_cache.running[path][index],
      {
        buffer_id = extmark.buffer_id,
        extmark_id = extmark.details.id,
        screen_position = extmark.screen_position
      } --[[@as callback_details]]
    )
    return
  end

  sixel_raw.blobify(
    extmark,
    path,
    function(blob)
      -- TODO: occasional quiet ImageMagick failure
      if blob:len() == 0 then
        vim.print(vim.inspect{extmark, path})

        -- Blobber no longer running
        blob_cache.running[path][index] = nil
        return
      end

      -- Insert blob into cache
      if blob_cache.contents[path] ~= nil then
        blob_cache.contents[path][index] = blob
      else
        local temp = {}
        temp[index] = blob
        blob_cache.contents[path] = temp
      end

      blob_cache.fire_pre_draw(blob_cache.running[path][index])

      sixel_raw.draw_sixels(
        vim.tbl_map(
          ---@param callback_details callback_details
          ---@return [ string, number[] ]
          function(callback_details)
            return { blob, callback_details.screen_position }
          end,
          blob_cache.running[path][index]
        ) --[[@as [ string, number[] ][] ]]
      )

      -- Blobber no longer running
      blob_cache.running[path][index] = nil
    end,
    function(error_)
      if error_ == nil then return end

      -- Set errors on the extmarks that were awaiting being drawn
      -- XXX Still need to set the extmark error, even if the running cache doesn't remember it!
      vim.defer_fn(function()
        for _, callback_details in ipairs(blob_cache.running[path][index]) do
          vim.api.nvim_buf_call(function()
            interface.set_extmark_error(
              callback_details.extmark_id,
              error_
            )
          end, callback_details.buffer_id)
        end
      end, 0)
    end
  )

  blob_cache.running[path][index] = {
    {
      buffer_id = extmark.buffer_id,
      extmark_id = extmark.details.id,
      screen_position = extmark.screen_position
    } --[[@as callback_details]]
  }
end


---@param extmark wrapped_extmark
---@return [string, [number, number]] | nil
function blob_cache.lookup_or_generate_blob(extmark)
  return vim.api.nvim_buf_call(extmark.buffer_id, function()
    if vim.b.image_extmark_to_path == nil then
      vim.b.image_extmark_to_path = vim.empty_dict()
    end

    if vim.b.image_extmark_to_error == nil then
      vim.b.image_extmark_to_error = vim.empty_dict()
    end

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

    -- Get rid of the error text, if there is any
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
  end)
end


---@param path string
---@param extmark wrapped_extmark
function blob_cache.get(path, extmark)
  local cached = blob_cache.contents[path]
  if cached == nil then
    return nil
  end

  local index = extmark_to_cache_id(extmark)
  if cached[index] == nil then
    return nil
  end

  return cached[index]
end

---@param path? (string | string[])
function blob_cache.clear(path)
  if path == nil then
    blob_cache.contents = {}
  elseif type(path) == "table" then
    for _, path_ in ipairs(path) do
      blob_cache.contents[path_] = {}
    end
  elseif type(path) == "string" then
    blob_cache.contents[path] = {}
  else
    assert(false, "Invalid argument")
  end

  collectgarbage()
end


function blob_cache.dump()
  return vim.tbl_map(
    function(x)
      return vim.tbl_map(
        ---@param y string
        function(y)
          local height, crop_row_start, crop_row_end = y:match("(%d),(%d),(%d)")
          return {
            height = height,
            crop_row_start = crop_row_start,
            crop_row_end = crop_row_end
          }
        end,
        vim.tbl_keys(x)
      )
    end,
    blob_cache.contents
  )
end


return blob_cache
