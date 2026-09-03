--[[
  Event Script: Control Panasonic AC from C-Bus
  Script Type: Event Script (Attach to tagged C-Bus AC objects or individual group addresses)
  Description: When a C-Bus switch, thermostat, or slider changes value, dispatch the command to Panasonic Cloud.
--]]

local panasonic = require("user.panasonic")

-- CONFIGURE YOUR DEVICE GUID AND CBUS OBJECT ADDRESSES HERE:
local DEVICE_GUID = "PASTE_YOUR_DEVICE_GUID_HERE"

local CBUS_OBJECTS = {
  power        = "1/1/1",  -- 01.001 Switch (0 = Off, 1 = On)
  target_temp  = "1/1/2",  -- 09.001 2-byte float
  mode         = "1/1/5",  -- 05.010 1-byte unsigned (0=Auto, 1=Dry, 2=Cool, 3=Heat, 4=Fan)
  fan_speed    = "1/1/6",  -- 05.010 1-byte unsigned (0=Auto, 1=Low, 2=LowMid, 3=Mid, 4=HighMid, 5=High)
  eco_mode     = "1/1/7"   -- 05.010 1-byte unsigned (0=Auto, 1=Powerful, 2=Quiet)
}

local src_addr = event.dst
local val = event.getvalue()

local params = {}

-- 1. Power On / Off
if src_addr == CBUS_OBJECTS.power then
  params.operate = (val == true or val == 1) and 1 or 0

-- 2. Target Temperature
elseif src_addr == CBUS_OBJECTS.target_temp then
  local temp = tonumber(val)
  if temp and temp >= 16.0 and temp <= 30.0 then
    params.temperatureSet = temp
  end

-- 3. Operation Mode
elseif src_addr == CBUS_OBJECTS.mode then
  local mode_val = tonumber(val)
  if mode_val and mode_val >= 0 and mode_val <= 4 then
    params.operationMode = mode_val
  end

-- 4. Fan Speed
elseif src_addr == CBUS_OBJECTS.fan_speed then
  local speed_val = tonumber(val)
  if speed_val and speed_val >= 0 and speed_val <= 5 then
    params.fanSpeed = speed_val
  end

-- 5. Eco / Quiet / Powerful Mode
elseif src_addr == CBUS_OBJECTS.eco_mode then
  local eco_val = tonumber(val)
  if eco_val and eco_val >= 0 and eco_val <= 2 then
    params.ecoMode = eco_val
  end
end

-- If we have parameter updates to send, dispatch to Panasonic API
if next(params) ~= nil then
  log("Sending Panasonic control parameters: " .. json.encode(params))
  local ok, err = panasonic.control_device(DEVICE_GUID, params)
  if not ok then
    log("Failed to control Panasonic AC: " .. tostring(err))
  else
    log("Panasonic AC command sent successfully.")
  end
end
