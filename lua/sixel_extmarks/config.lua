local default_config = {
  -- Allow virtual extmarks
  allow_virtual = vim.fn.has("nvim-0.10"),
  -- Can acquire TIOCGWINSZ from Python
  ioctl_magic = true,
  -- System ioctl value for TIOCGWINSZ
  -- This is the default value in Linux (and other kernels),
  -- but can also be derived from the Python installation via ioctl_magic
  TIOCGWINSZ = 0x5413,
  -- Can ascend pseudoterminals
  parent_tty_magic = true,

  -- ImageMagick command used to convert images into sixels
  imagemagick_command = "magick" and vim.fn.exepath("magick") or "convert",

  -- Minimum height of cropped images
  -- 0 means all crops are valid, -1 means no cropped images are valid
  min_cropped_height = 0,

  -- Do NOT rebind fold keys to redraw sixels
  ignore_fold_remaps = false,

  -- Disable drawing after entering insert mode
  slow_insert = false,

  -- Do not automatically clear the screen inside tmux
  tmux_detach_clears = false,
}

-- Configuration settings which can be partially updated from user config
local table_configs = {}
local GLOBAL_PREFIX = "image_extmarks_"

-- Start with defaults
local config = vim.deepcopy(default_config) or default_config

-- Additional updates to config
local function update_config()
  -- Unset this so config can fetch it later
  if config.ioctl_magic then
    config.TIOCGWINSZ = nil
  end

  -- Make sure the commands are actually there for magic
  if config.parent_tty_magic then
    config.parent_tty_magic = (
      vim.fn.exepath("ps") ~= ""
      and vim.fn.exepath("pstree") ~= ""
      and vim.fn.finddir("/dev") ~= ""
    )
  end

  if vim.fn.exepath(config.imagemagick_command) == "" then
    vim.fn.notify(
      "nvim-image-extmarks: ImageMagick command not found under `magick` or `convert`!",
      vim.log.levels.WARN
    )
  end
end

-- Load options from global variables and argument options
function config.load_globals(opts)
  -- Load the new options or global variables
  for option, default_value in pairs(default_config) do
    local global_value = vim.g[GLOBAL_PREFIX .. option]
    -- Convert Vim global from truthy number to boolean
    if type(global_value) == "number" and type(default_value) == "boolean" then
      global_value = global_value ~= 0
    end
    local lazy_value = opts[option]

    if global_value ~= nil then
      config[option] = global_value
    -- Only set lazy-configured options when table_configs
    elseif lazy_value ~= nil and table_configs[option] == nil then
      config[option] = lazy_value
    end

    if config[option] == nil then
      config[option] = vim.deepcopy(default_value)
    end
  end

  -- Load tableized options
  for _, option in ipairs(table_configs) do
    ---@diagnostic disable-next-line
    for suboption, _ in pairs(default_config[option] or {}) do
      local global_value = vim.g[GLOBAL_PREFIX .. option .. "_" .. suboption]
      -- Convert Vim global from truthy number to boolean
      if type(global_value) == "number" and type(default_config[option][suboption]) == "boolean" then
        global_value = global_value ~= 0
      end
      local lazy_value = (opts[option] or {})[suboption]

      if global_value ~= nil then
        config[option][suboption] = global_value
      end
      if lazy_value ~= nil then
        config[option][suboption] = lazy_value
      end
    end
  end

  update_config()
end

return config
