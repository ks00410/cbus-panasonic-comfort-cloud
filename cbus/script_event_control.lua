--[[
  Event Script: Control Panasonic AC from C-Bus
  Script Type: Event Script (Attach to tagged C-Bus AC objects or individual group addresses)
  Description: Dispatches changes from C-Bus wall switches, touchscreens, or UserParams
               directly to Panasonic Comfort Cloud.
               Credentials & Device GUID are automatically read from user.secrets.
--]]

local panasonic = require("user.panasonic")

-- =============================================================================
-- CONFIGURATION
-- =============================================================================
local config = {
  param_prefix = "AC_",     -- Prefix for C-Bus UserParams (e.g. AC_Power, AC_TargetTemp)

  -- (Optional) Map native C-Bus lighting Group Addresses (integers 0..255 or strings):
  cbus_objects = {
    -- power       = 10,    -- C-Bus Group Address 10 (Lighting App 56)
    -- target_temp = 11,
    -- mode        = 12,
    -- fan_speed   = 13,
  },

  -- (Optional) Map C-Bus zone damper Group Addresses:
  cbus_zones = {
    -- [1] = { power = 21, damper = 31 },
    -- [2] = { power = 22, damper = 32 },
    -- [3] = { power = 23, damper = 33 }
  }
}

-- Execute event handler passing the event directly
panasonic.Event_Control(config, event)
