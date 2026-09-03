--[[
  Resident Polling Script for Panasonic Comfort Cloud AC
  Script Type: Resident Script (Sleep interval: 60 seconds)
  Description: Periodically polls live AC status and writes values to C-Bus group addresses.
               Credentials & Device GUID are automatically read from user.secrets.
--]]

local panasonic = require("user.panasonic")

-- CONFIGURE YOUR CBUS OBJECT ADDRESSES HERE:
local config = {
  -- (Optional) If omitted, device_guid will be loaded automatically from user.secrets
  -- device_guid = "YOUR_DEVICE_GUID",

  cbus_objects = {
    power        = "1/1/1",  -- 01.001 Switch (0 = Off, 1 = On)
    target_temp  = "1/1/2",  -- 09.001 2-byte float (e.g. 23.0)
    inside_temp  = "1/1/3",  -- 09.001 2-byte float (e.g. 21.5)
    outside_temp = "1/1/4",  -- 09.001 2-byte float (e.g. 18.0)
    mode         = "1/1/5",  -- 05.010 1-byte unsigned (0=Auto, 1=Dry, 2=Cool, 3=Heat, 4=Fan)
    fan_speed    = "1/1/6",  -- 05.010 1-byte unsigned (0=Auto, 1=Low, 2=LowMid, 3=Mid, 4=HighMid, 5=High)
    eco_mode     = "1/1/7"   -- 05.010 1-byte unsigned (0=Auto, 1=Powerful, 2=Quiet)
  },

  -- (Optional) Map to named C-Bus UserParams if defined in your C-Bus project
  cbus_params = {
    -- power       = "AC_Living_Power",
    -- inside_temp = "AC_Living_InsideTemp",
    -- target_temp = "AC_Living_TargetTemp"
  }
}

-- Execute standardized poll
panasonic.Resident_Poll(config)
