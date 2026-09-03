--[[
  Event Script: Control Panasonic AC from C-Bus
  Script Type: Event Script (Attach to tagged C-Bus AC objects or individual group addresses)
  Description: When a C-Bus switch, thermostat, or slider changes value, dispatch the command to Panasonic Cloud.
               Supports core climate controls, swing directions, presets, and zone dampers.
               Credentials & Device GUID are automatically read from user.secrets.
--]]

local panasonic = require("user.panasonic")

-- CONFIGURE YOUR CBUS OBJECT ADDRESSES HERE:
local config = {
  -- (Optional) If omitted, device_guid will be loaded automatically from user.secrets
  -- device_guid = "YOUR_DEVICE_GUID",

  -- 1. Core Climate Objects
  cbus_objects = {
    power           = "1/1/1",  -- 01.001 Switch (0 = Off, 1 = On)
    target_temp     = "1/1/2",  -- 09.001 2-byte float (16.0 - 30.0)
    mode            = "1/1/5",  -- 05.010 1-byte unsigned (0=Auto, 1=Dry, 2=Cool, 3=Heat, 4=Fan)
    fan_speed       = "1/1/6",  -- 05.010 1-byte unsigned (0=Auto, 1=Low, 2=LowMid, 3=Mid, 4=HighMid, 5=High)
    eco_mode        = "1/1/7",  -- 05.010 1-byte unsigned (0=Auto, 1=Powerful, 2=Quiet)
    air_swing_ud    = "1/1/8",  -- 05.010 1-byte unsigned / signed (-1=Auto, 0=Up, 1=Down, 2=Mid, 5=Swing)
    air_swing_lr    = "1/1/9",  -- 05.010 1-byte unsigned / signed (-1=Auto, 0=Right, 1=Left, 2=Mid)
    nanoe           = "1/1/10", -- 05.010 1-byte unsigned (0=Off, 2=On, 3=ModeG, 4=All)
    eco_navi        = "1/1/11", -- 01.001 Switch (0=Off, 2=On)
    iauto_x         = "1/1/12", -- 01.001 Switch (0=Off, 2=On)
    inside_cleaning = "1/1/13"  -- 01.001 Switch (0=Off, 1=On)
  },

  -- 2. Zone Damper Controls (Optional)
  cbus_zones = {
    [1] = {
      power  = "1/2/1",   -- 01.001 Switch (Zone 1 On/Off)
      damper = "1/2/11"   -- 05.001 Scaling 0..100% (Damper Position)
    },
    [2] = {
      power  = "1/2/2",   -- 01.001 Switch (Zone 2 On/Off)
      damper = "1/2/12"   -- 05.001 Scaling 0..100% (Damper Position)
    },
    [3] = {
      power  = "1/2/3",   -- 01.001 Switch (Zone 3 On/Off)
      damper = "1/2/13"   -- 05.001 Scaling 0..100% (Damper Position)
    }
  }
}

-- Execute event handler
panasonic.Event_Control(config, event.dst, event.getvalue())
