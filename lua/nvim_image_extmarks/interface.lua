-- nvim_image_extmarks/interface.lua
--
-- Functions which wrap nvim's native extmark interface.
-- They are generally "dumber" than the functions exposed to the user, and
-- are focused primarily on buffer-local storage of extmark and file data.

---@class image_extmark
---@field id integer
---@field start_row integer
---@field end_row? integer
---@field height? integer
---@field type "inline"|"virtual"
---@field path string|nil
---@field error string|nil

local interface = {
  namespace = vim.api.nvim_create_namespace("Nvim-image"),
}

---@type fun(path: string): string
local path_normalizer
if vim.fs ~= nil then
  path_normalizer = vim.fs.normalize
else
  path_normalizer = vim.fn.expandcmd
end

---@param id integer
---@param path string
---@return boolean
local function set_path_dict(id, path)
  path = path_normalizer(path)
  if vim.fn.filereadable(path) == 0 then
    return false
  end

  pcall(function()
    vim.cmd(("unlet b:image_extmark_to_error[%d]"):format(id))
  end)

  vim.cmd(("let b:image_extmark_to_path[%d] = '%s'"):format(
    id,
    vim.fn.escape(path, "'\\")
  ))
  return true
end


---@param id integer
---@param error_text string|nil
local function set_error_dict(id, error_text)
  if error_text == nil then
    pcall(function() vim.cmd(("unlet b:image_extmark_to_error[%d]"):format(id)) end)
    return
  end

  vim.cmd(("let b:image_extmark_to_error[%d] = \"%s\""):format(
    id,
    vim.fn.escape(error_text:gsub("\n", "\\n"), "\"\\")
  ))
end


---@param start_row integer
---@param end_row integer
---@param path string
---@return integer
function interface.create_image(start_row, end_row, path)
  local id = vim.api.nvim_buf_set_extmark(
    0,
    interface.namespace,
    start_row,
    0,
    { end_row = end_row }
  )

  if vim.b.image_extmark_to_path == nil then
    vim.b.image_extmark_to_path = vim.empty_dict()
  end

  if not set_path_dict(id, path) then
    interface.set_extmark_error(
      id,
      ("Cannot read file `%s`!"):format(path)
    )
  end
  return id
end


---@param start_row integer
---@param height integer
---@param path string
---@return integer
function interface.create_image_virtual(start_row, height, path)
  local virt_lines = {}
  for _ = 1, height do
    table.insert(virt_lines, {{"", ""}})
  end

  local id = vim.api.nvim_buf_set_extmark(
    0,
    interface.namespace,
    start_row,
    0,
    { virt_lines = virt_lines }
  )

  if vim.b.image_extmark_to_path == nil then
    vim.b.image_extmark_to_path = vim.empty_dict()
  end

  if not set_path_dict(id, path) then
    interface.set_extmark_error(
      id,
      ("Cannot read file `%s`!"):format(path)
    )
  end
  return id
end


---@param start_row integer The (0-indexed) row of the buffer that the image would end on
---@param end_row integer The (0-indexed) row of the buffer that the image would end on
---@param error_text string The error text to display
---@return integer
function interface.create_error(start_row, end_row, error_text)
  local id = vim.api.nvim_buf_set_extmark(
    0,
    interface.namespace,
    start_row,
    0,
    {
      end_row = end_row,
      virt_text = { { error_text, "ErrorMsg" } }
    }
  )

  if vim.b.image_extmark_to_error == nil then
    vim.b.image_extmark_to_error = vim.empty_dict()
  end

  set_error_dict(id, error_text)
  return id
end


-- Convert extmark from nvim_buf_get_extmark{_by_id,s} to idiomatic form
--
---@param extmark [integer, integer, integer, {end_row?: integer, virt_lines?: string[][][] }]|nil
---@return image_extmark|nil
local function convert_extmark(extmark)
  if extmark == nil then return nil end

  local _, content, errors = pcall(function()
    return
      vim.b.image_extmark_to_path[tostring(extmark[1])],
      vim.b.image_extmark_to_error[tostring(extmark[1])]
  end)

  local type = "inline"
  local end_row = extmark[4].end_row
  local height = nil
  if extmark[4].virt_lines ~= nil then
    type = "virtual"
    end_row = nil
    height = #(extmark[4].virt_lines)
  end

  return {
    id = extmark[1],
    start_row = extmark[2],
    end_row = end_row,
    height = height,
    type = type,
    path = content,
    error = errors
  }
end


---@param id integer
---@return image_extmark|nil
function interface.get_image_extmark_by_id(id)
  local extmark = vim.api.nvim_buf_get_extmark_by_id(
    0,
    interface.namespace,
    id,
    { details = true }
  )
  if #extmark == 0 then return nil end

  return convert_extmark{id, unpack(extmark)} ---@diagnostic disable-line
end


---@param start_row integer
---@param end_row integer
---@return image_extmark[]
function interface.get_image_extmarks(start_row, end_row)
  local extmarks = vim.api.nvim_buf_get_extmarks(
    0,
    interface.namespace,
    {start_row, 0},
    {end_row, -1},
    { details = true }
  )

  return vim.tbl_map(convert_extmark, extmarks)
end


---@param id integer
function interface.remove_image_extmark(id)
  pcall(function()
    vim.cmd(("unlet b:image_extmark_to_path[%d]"):format(id))
  end)
  pcall(function()
    vim.cmd(("unlet b:image_extmark_to_error[%d]"):format(id))
  end)

  return vim.api.nvim_buf_del_extmark(
    0,
    interface.namespace,
    id
  )
end


function interface.remove_images()
  vim.b.image_extmark_to_path = vim.empty_dict()
  vim.b.image_extmark_to_error = vim.empty_dict()
  return vim.api.nvim_buf_clear_namespace(
    0,
    interface.namespace,
    0,
    -1
  )
end


---@param id integer
---@param start_row integer
---@param end_row? integer
function interface.move_extmark(id, start_row, end_row)
  local extmark = vim.api.nvim_buf_get_extmark_by_id(
    0,
    interface.namespace,
    id,
    { details = true }
  )
  if #extmark == 0 then return end

  local settings = { id = id, end_row = end_row }
  if extmark[3].virt_lines ~= nil then
    settings.end_row = nil

    local virt_lines = {}
    if end_row ~= nil then
      for _ = 1, end_row do
        table.insert(virt_lines, {{"", ""}})
      end
      settings.virt_lines = virt_lines
    end
  end

  vim.api.nvim_buf_set_extmark(
    0,
    interface.namespace,
    start_row,
    0,
    settings
  )
end


---@param id integer
---@param path string
function interface.change_extmark_content(id, path)
  local map = vim.b.image_extmark_to_path
  if map == nil then return end

  local extmark = vim.api.nvim_buf_get_extmark_by_id(
    0,
    interface.namespace,
    id,
    {}
  )
  if #extmark == 0 or map[tostring(id)] == nil then return end

  if not set_path_dict(id, path) then
    interface.set_extmark_error(
      id,
      ("Cannot read file `%s`!"):format(path)
    )
  end
end


---@param id integer
---@param error_text string|nil
---@param remember? boolean
function interface.set_extmark_error(id, error_text, remember)
  print("HERE 1")
  if remember or remember == nil then
    if vim.b.image_extmark_to_error == nil then
      vim.b.image_extmark_to_error = vim.empty_dict()
    end

    set_error_dict(id, error_text)
  end

  local data = interface.get_image_extmark_by_id(id)
  print("HERE 2")
  if data == nil then return end

  local error_display = { { error_text, "ErrorMsg" } }
  local details = {
    id = id,
  }
  if data.type == "inline" then
    details["end_row"] = data.end_row
    details["virt_text"] = error_display
  else
    local virt_lines = { error_display }
    for _ = 1, data.height - 1 do
      table.insert(virt_lines, {{"", ""}})
    end
    details["virt_lines"] = virt_lines

    print("HERE")
  end

  vim.api.nvim_buf_set_extmark(
    0,
    interface.namespace,
    data.start_row,
    0,
    details
  )
end

return interface
