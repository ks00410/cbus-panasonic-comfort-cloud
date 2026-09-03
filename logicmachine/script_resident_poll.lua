--[[
  Resident Polling Script for Panasonic Comfort Cloud AC
  Script Type: Resident Script (Sleep interval: 60 seconds)
  Description: Periodically polls live AC status and writes values to C-Bus/LogicMachine group addresses.
--]]

local panasonic = require("user.panasonic")

-- CONFIGURE YOUR DEVICE GUID AND CBUS OBJECT ADDRESSES HERE:
local DEVICE_GUID = "PASTE_YOUR_DEVICE_GUID_HERE"

local CBUS_OBJECTS = {
  power        = "1/1/1",  -- 01.001 Switch (0 = Off, 1 = On)
  target_temp  = "1/1/2",  -- 09.001 2-byte float (e.g. 23.0)
  inside_temp  = "1/1/3",  -- 09.001 2-byte float (e.g. 21.5)
  outside_temp = "1/1/4",  -- 09.001 2-byte float (e.g. 18.0)
  mode         = "1/1/5",  -- 05.010 1-byte unsigned (0=Auto, 1=Dry, 2=Cool, 3=Heat, 4=Fan)
  fan_speed    = "1/1/6",  -- 05.010 1-byte unsigned (0=Auto, 1=Low, 2=LowMid, 3=Mid, 4=HighMid, 5=High)
  eco_mode     = "1/1/7"   -- 05.010 1-byte unsigned (0=Auto, 1=Powerful, 2=Quiet)
}

-- Fetch live status
local status, err = panasonic.get_device_status(DEVICE_GUID)

if status then
  -- Power (1 = On, 0 = Off)
  if CBUS_OBJECTS.power and status.operate ~= nil then
    local is_on = (status.operate == 1)
    grp.checkupdate(CBUS_OBJECTS.power, is_on)
  end

  -- Target Temperature (deg C)
  if CBUS_OBJECTS.target_temp and status.temperatureSet ~= nil and status.temperatureSet > 0 then
    grp.checkupdate(CBUS_OBJECTS.target_temp, status.temperatureSet)
  end

  -- Inside Ambient Temperature (deg C)
  if CBUS_OBJECTS.inside_temp and status.insideTemperature ~= nil and status.insideTemperature ~= 126 and status.insideTemperature ~= 255 then
    grp.checkupdate(CBUS_OBJECTS.inside_temp, status.insideTemperature)
  end

  -- Outside Ambient Temperature (deg C)
  if CBUS_OBJECTS.outside_temp and status.outTemperature ~= nil and status.outTemperature ~= 126 and status.outTemperature ~= 255 then
    grp.checkupdate(CBUS_OBJECTS.outside_temp, status.outTemperature)
  end

  -- Operating Mode
  if CBUS_OBJECTS.mode and status.operationMode ~= nil then
    grp.checkupdate(CBUS_OBJECTS.mode, status.operationMode)
  end

  -- Fan Speed
  if CBUS_OBJECTS.fan_speed and status.fanSpeed ~= nil then
    grp.checkupdate(CBUS_OBJECTS.fan_speed, status.fanSpeed)
  end

  -- Eco / Preset Mode
  if CBUS_OBJECTS.eco_mode and status.ecoMode ~= nil then
    grp.checkupdate(CBUS_OBJECTS.eco_mode, status.ecoMode)
  end
else
  log("Panasonic Poll Warning: " .. tostring(err))
end
