---@alias blob_path string
---@alias cache_id string
---@alias extmark_coords number[]

---@class text_height_params Parameters for the second argument to nvim_win_text_height
---@field start_row integer
---@field end_row integer

---@class extmark_details Parameters for the details argument to nvim_buf_set_extmark
---@field id integer
---@field end_row? integer
---@field virt_lines? [string, string][][]

---@class wrapped_extmark Internal representation of an extmark,
---including "local" information from its position in the window.
---
---@field start_row integer
---@field height integer
---@field crop_row_start integer
---@field crop_row_end integer
---@field buffer_id integer
---@field details extmark_details
---@field path string | nil
---@field error string | nil
---@field screen_position [integer, integer]

---@class image_extmark Information about an image extmark, including its range and height
---@field id integer
---@field start_row integer
---@field end_row? integer
---@field height? integer
---@field type "inline"|"virtual"
---@field path string|nil
---@field error string|nil

---@class callback_details Helper object for blobbing extmarks and drawing them to the
---right place on the screen
---
---@field screen_position extmark_coords
---@field extmark_id integer
---@field buffer_id integer
---@field retry_number? integer

---@class window_dimensions Helper object accumulating window information for drawing
---
---@field height integer
---@field topline integer Top line of the buffer
---@field botline integer Bottom line of the buffer
---@field winrow integer Start row of the current tabpage
---@field wincol integer Start column of  the current tabpage
---@field textoff integer Sign/number column offset
---@field topfill integer Filler (extmark) lines included at the top of the window
