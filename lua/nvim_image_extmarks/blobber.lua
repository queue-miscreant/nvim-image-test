-- nvim_image_extmarks/blobber.lua
--
-- Helper functions for creating and drawing blobs.
--
-- Implements a naive two-layer cache for sixel blobs.
-- Blobs are cached by the following characteristics:
--
-- - Layer 1 keys:
--      - Content hash
-- - Layer 2 keys:
--      - Height, in rows
--      - Crop from top of image, in rows
--      - Crop from bottom of image (i.e., number of rows removed, as a full image)
--
-- Running cache semantics:
--
-- If the cache entry is nil, then no process is currently generating that blob
-- If the cache entry is {}, then a runner is generating the blob, but no positions will be drawn with it

local sixel_raw = require "nvim_image_extmarks.sixel_raw"
local interface = require "nvim_image_extmarks.interface"

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
---@field path string | nil
---@field error string | nil
---@field screen_position [integer, integer]

---@alias blob_path string
---@alias cache_id string
---@alias extmark_coords number[]

---@class callback_details
---@field screen_position extmark_coords
---@field extmark_id integer
---@field buffer_id integer
---@field retry_number? integer

local blobber = {
  ---@type {[blob_path]: {[cache_id]: string}}
  blob_cache = {},
  ---@type {[blob_path]: {[cache_id]: (nil | callback_details[]) }}
  running_cache = {},
  ---@type {[blob_path]: {[cache_id]: (nil | callback_details[]) }}
  error_cache = {},
  max_retry_count = 5
}


---@param extmark wrapped_extmark
---@return callback_details
local function as_callback_details(extmark)
  return {
    buffer_id = extmark.buffer_id,
    extmark_id = extmark.details.id,
    screen_position = extmark.screen_position
  } --[[@as callback_details]]
end


---@param extmarks callback_details[]
local function fire_pre_draw(extmarks)
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


---@param index cache_id
local function cache_id_to_table(index)
  local height, crop_row_start, crop_row_end = index:match("(%d),(%d),(%d)")
  return {
    height = height,
    crop_row_start = crop_row_start,
    crop_row_end = crop_row_end
  }
end


-- Convert extmark parameters into a sixel blob by starting an ImageMagick subprocess.
--
---@param extmark wrapped_extmark A wrapped extmark, containing height and crop data (in rows)
---@param callback fun(extmark: wrapped_extmark, blob: string): any A callback function which is called with the generated blob
---@param error_callback? fun(extmark: wrapped_extmark, errors: string): any An optional callback function, called with error information
function blobber.blobify(
  extmark,
  callback,
  error_callback
)
  -- Resize to a suitable height
  local resize = ("x%d"):format(extmark.height * sixel_raw.char_pixel_height)
  -- Crop to the right size
  local crop = ("x%d+0+%d"):format(
    (extmark.height - extmark.crop_row_start - extmark.crop_row_end) * sixel_raw.char_pixel_height,
    extmark.crop_row_start * sixel_raw.char_pixel_height
  )

  local stdout = vim.loop.new_pipe()
  local stderr = vim.loop.new_pipe()
  -- Run ImageMagick command
  vim.loop.spawn("magick", {
    args = {
      extmark.path .. "[0]",
      "-resize",
      resize,
      "-crop",
      crop,
      "sixel:-"
    },
    stdio = {nil, stdout, stderr},
    detached = true
  })

  local sixel = ""
  stdout:read_start(function(err, data)
    assert(not err, err)
    if data == nil then callback(extmark, sixel) return end
    sixel = sixel .. data
  end)

  local error_ = ""
  stderr:read_start(function(err, data)
    assert(not err, err)
    if data == nil then
      if error_callback ~= nil then error_callback(extmark, error_) end
      return
    end
    error_ = error_ .. data
  end)
end


---@param extmark wrapped_extmark
---@param blob string
function blobber.store_and_draw_blob(extmark, blob)
  local index = extmark_to_cache_id(extmark)
  local path = extmark.path
  local locations = blobber.running_cache[path][index]

  if
    locations == nil
    or path == nil
    or blob == ""
  then
    pcall(function()
      blobber.running_cache[path][index] = nil
    end)
    return
  end

  -- Insert blob into cache
  if blobber.blob_cache[path] ~= nil then
    blobber.blob_cache[path][index] = blob
  else
    local temp = {}
    temp[index] = blob
    blobber.blob_cache[path] = temp
  end

  fire_pre_draw(locations)

  sixel_raw.draw_sixels(
    vim.tbl_map(
      ---@param callback_details callback_details
      function(callback_details)
        return { blob, callback_details.screen_position } ---[[@as return [ string, number[] ] ]]
      end,
      locations
    ) --[[@as [ string, number[] ][] ]]
  )

  -- Blobber no longer running
  blobber.running_cache[path][index] = nil
end


---@param extmark wrapped_extmark
---@param error_ string
function blobber.update_errors(extmark, error_)
  local index = extmark_to_cache_id(extmark)
  local path = extmark.path
  local locations = blobber.running_cache[path][index]

  if error_ == "" then
    pcall(function()
      blobber.error_cache[path][index] = nil
    end)
    return
  end

  -- Find out how many failures we had
  local max_retry_number = 0
  for _, location in ipairs(locations) do
    max_retry_number = math.max(max_retry_number, location.retry_number or 0)
  end

  if max_retry_number <= blobber.max_retry_count then
    blobber.try_generate_blob(extmark)

    -- Add the other locations
    blobber.running_cache[path][index] = locations
    for _, location in ipairs(locations) do
      location.retry_number = (location.retry_number or 0) + 1
    end

    return
  end

  -- Too many errors occurred.
  -- Set errors on the extmarks that were awaiting being drawn
  vim.defer_fn(function()
    for _, location in ipairs(blobber.error_cache[path][index]) do
      vim.api.nvim_buf_call(location.buffer_id, function()
        interface.set_extmark_error(
          location.extmark_id,
          "Failed to convert extmark to blob!"
        )
      end)
    end

    blobber.error_cache[path][index] = nil
    vim.notify("ImageMagick failure occurred: " .. error_)
  end, 0)
end


-- Attempt to generate a blob, if necessary, given an extmark.
---
-- If the blob is already generating, the extmark position
-- will be remembered until the blobber finishes.
---
-- When the blobber finishes, all remembered extmarks since
-- the last `blob_cache.clear_running` will be drawn.
--
---@param extmark wrapped_extmark
function blobber.try_generate_blob(extmark)
  local index = extmark_to_cache_id(extmark)

  if blobber.running_cache[extmark.path] == nil then
    blobber.running_cache[extmark.path] = {}
  end

  if blobber.error_cache[extmark.path] == nil then
    blobber.error_cache[extmark.path] = {}
  end

  if blobber.running_cache[extmark.path][index] ~= nil then
    -- Blob is being generated, just remember to draw it later
    table.insert(
      blobber.running_cache[extmark.path][index],
      as_callback_details(extmark)
    )
    return
  end
  if blobber.error_cache[extmark.path][index] == nil then
    blobber.error_cache[extmark.path][index] = {}
  end

  blobber.blobify(
    extmark,
    blobber.store_and_draw_blob,
    blobber.update_errors
  )

  blobber.running_cache[extmark.path][index] = { as_callback_details(extmark) }
end


-- Forget about all extmark positions from calls to `blob_cache.try_generate_blob`
-- No extmarks will be drawn when the blobber finishes.
--
function blobber.clear_running()
  for path, layer2 in pairs(blobber.running_cache) do
    if blobber.error_cache[path] == nil then
      blobber.error_cache[path] = {}
    end

    for index, data in pairs(layer2) do
      -- Drop data from being called when the blobber finishes
      blobber.running_cache[path][index] = {}

      -- Append to the error cache
      if blobber.error_cache[path][index] == nil then
        blobber.error_cache[path][index] = {}
      end
      for _, datum in ipairs(data or {}) do
        table.insert(blobber.error_cache[path][index], datum)
      end
    end
  end
end


-- Either retrieve a blob from the cache, or start blobifying and return nil.
--
---@param extmark wrapped_extmark
---@return [string, [number, number]] | nil
function blobber.lookup_or_generate_blob(extmark)
  return vim.api.nvim_buf_call(extmark.buffer_id, function()
    if extmark.error ~= nil then
      interface.set_extmark_error(
        extmark.details.id,
        extmark.error,
        false
      )
      return nil
    end
    if extmark.path == nil then
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

    local cache_lookup = blobber.get(extmark.path, extmark)

    if cache_lookup == nil then
      -- Try to find the file
      if vim.fn.filereadable(extmark.path) == 0 then
        interface.set_extmark_error(
          extmark.details.id,
          ("Cannot read file `%s`!"):format(extmark.path)
        )
        return nil
      end

      blobber.try_generate_blob(extmark)
      return nil
    end

    return {
      cache_lookup,
      extmark.screen_position
    }
  end)
end

---@param extmarks wrapped_extmark[]
function blobber.draw(extmarks)
  blobber.clear_running()

  local blobs = vim.tbl_map(
    blobber.lookup_or_generate_blob,
    extmarks
  )

  fire_pre_draw(
    vim.tbl_map(as_callback_details, extmarks)
  )
  sixel_raw.draw_sixels(blobs)
end


---@param path string
---@param extmark wrapped_extmark
function blobber.get(path, extmark)
  local cached = blobber.blob_cache[path]
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
function blobber.clear_cache(path)
  if path == nil then
    blobber.blob_cache = {}
  elseif type(path) == "table" then
    for _, path_ in ipairs(path) do
      blobber.blob_cache[path_] = {}
    end
  elseif type(path) == "string" then
    blobber.blob_cache[path] = {}
  else
    assert(false, "Invalid argument")
  end

  collectgarbage()
end


function blobber.dump_cache()
  return vim.tbl_map(
    function(x)
      return vim.tbl_map(cache_id_to_table, vim.tbl_keys(x))
    end,
    blobber.blob_cache
  )
end


return blobber
