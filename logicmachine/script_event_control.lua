--[[
  Event Script: Control Panasonic AC from C-Bus
  Script Type: Event Script (Attach to tagged C-Bus AC objects or individual group addresses)
  Description: When a C-Bus switch, thermostat, or slider changes value, dispatch the command to Panasonic Cloud.
               Credentials & Device GUID are automatically read from user.secrets.
--]]

local panasonic = require("user.panasonic")

-- CONFIGURE YOUR CBUS OBJECT ADDRESSES HERE:
local config = {
  -- (Optional) If omitted, device_guid will be loaded automatically from user.secrets
  -- device_guid = "YOUR_DEVICE_GUID",

  cbus_objects = {
    power        = "1/1/1",  -- 01.001 Switch (0 = Off, 1 = On)
    target_temp  = "1/1/2",  -- 09.001 2-byte float
    mode         = "1/1/5",  -- 05.010 1-byte unsigned (0=Auto, 1=Dry, 2=Cool, 3=Heat, 4=Fan)
    fan_speed    = "1/1/6",  -- 05.010 1-byte unsigned (0=Auto, 1=Low, 2=LowMid, 3=Mid, 4=HighMid, 5=High)
    eco_mode     = "1/1/7"   -- 05.010 1-byte unsigned (0=Auto, 1=Powerful, 2=Quiet)
  }
}

-- Execute event handler
panasonic.Event_Control(config, event.dst, event.getvalue())
