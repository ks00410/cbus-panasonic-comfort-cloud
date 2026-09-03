--[[
  Resident Polling Script for Panasonic Comfort Cloud AC
  Script Type: Resident Script (Sleep interval: 60 seconds)
  Description: Periodically polls live AC status, zone dampers, and energy telemetry,
               writing values directly to C-Bus UserParams and optional Group Addresses.
               Credentials & Device GUID are automatically read from user.secrets.
--]]

local panasonic = require("user.panasonic")

-- =============================================================================
-- CONFIGURATION
-- =============================================================================
--
-- C-Bus UserParams created automatically with prefix (e.g. "AC_"):
--   AC_Power, AC_TargetTemp, AC_InsideTemp, AC_OutsideTemp
--   AC_Mode, AC_Mode_Text, AC_FanSpeed, AC_FanSpeed_Text
--   AC_EcoMode, AC_EcoMode_Text, AC_SwingUD, AC_SwingUD_Text, AC_SwingLR, AC_SwingLR_Text
--   AC_Nanoe, AC_HVACAction, AC_HVACAction_Text, AC_ActiveZones, AC_LastUpdated
--   AC_Zone1_Power, AC_Zone1_Damper, AC_Zone1_Temp
--   AC_Zone2_Power, AC_Zone2_Damper, AC_Zone2_Temp
--   AC_Zone3_Power, AC_Zone3_Damper, AC_Zone3_Temp
--   AC_Daily_kWh, AC_Heating_kWh, AC_Cooling_kWh, AC_CurrentPower_W
--
local config = {
  cbus_network = 0,         -- C-Bus Network ID (Default: 0)
  param_prefix = "AC_",     -- Prefix for C-Bus UserParams
  enable_energy = true,     -- Fetch daily energy telemetry (kWh)

  -- (Optional) Map native C-Bus lighting / trigger Group Addresses (integers 0..255 or strings):
  cbus_objects = {
    -- power        = 10,   -- C-Bus Group Address 10 (Lighting App 56)
    -- target_temp  = 11,
    -- mode         = 12,
    -- fan_speed    = 13,
    -- hvac_action  = 14,
  },

  -- (Optional) Map C-Bus zone damper Group Addresses:
  cbus_zones = {
    -- [1] = { power = 21, damper = 31 },
    -- [2] = { power = 22, damper = 32 },
    -- [3] = { power = 23, damper = 33 }
  }
}

-- Execute poll
panasonic.Resident_Poll(config)
